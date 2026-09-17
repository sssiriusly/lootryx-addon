--[[
  Lootryx addon · human-readable ingest error mapping.

  Turns an ingest HTTP response (status number-or-nil, raw JSON body) into ONE short,
  actionable chat line. Pure logic, no Windower API calls, so it is easy to read and
  audit on its own (loaded the same way as lib/sha2.lua).

  The mapping is read off the REAL server response shape, not guessed:
    apps/api/src/errors/utils.ts    -> the `code` -> HTTP status table
    apps/api/src/errors/handler.ts  -> the JSON body shape: {message, code, status, ...}
    apps/api/src/lib/hmac.ts        -> every `ingest:invalid_signature` throw site
    apps/api/src/modules/ingest/handlers.ts + packages/database/addon-snapshot.ts
                                     -> the `business:rule_violation` throw sites

  IMPORTANT: the server uses ONE code, `ingest:invalid_signature` (401), for every HMAC
  failure: missing headers, an unknown/revoked key, a non-ACTIVE membership, a deleted
  shell, a bad signature, AND a timestamp outside the +/-300s window. The status code
  and `code` field alone cannot tell a clock-skew problem apart from a wrong secret, so
  this module matches on the `message` text (also server-controlled, not addon-guessed)
  to give a genuinely different answer for each cause.
]]

local M = {}

local json = ...
local function extract_json_field(body, field)
  if type(body) ~= 'string' then return nil end
  local ok, decoded = pcall(json.decode, body)
  local value = ok and type(decoded) == 'table' and decoded[field]
  if type(value) ~= 'string' then return nil end
  return value:gsub('[%c]', ' '):sub(1, 500)
end

local function contains(s, needle)
  return s ~= nil and s:find(needle, 1, true) ~= nil
end

--- describe_failure(status, body) -> human-readable string.
--- `status` is the HTTP status number, or nil on a transport-level failure (no response
--- at all, e.g. DNS/connection error), matching what post() in lootryx.lua returns.
--- `body` is the raw response text (JSON on a real server response, or the LuaSocket
--- error message on a transport failure).
function M.describe_failure(status, body)
  if status == nil then
    return 'Could not reach the Lootryx server (' .. tostring(body) .. '). Check your internet connection and the api_base setting.'
  end

  local code = extract_json_field(body, 'code')
  local message = extract_json_field(body, 'message')

  if code == 'ingest:invalid_signature' then
    if contains(message, 'Timestamp outside') then
      return 'Your PC clock looks off from the server. Check your system time.'
    end
    if contains(message, 'membership is not active') then
      return 'Your membership on this linkshell is not active. Ask an officer to check your roster status.'
    end
    if contains(message, 'Shell is not active') then
      return 'This linkshell is no longer active on Lootryx. Ask an officer or the shell owner.'
    end
    -- Missing headers, an unknown/revoked key, or a bad signature: all mean the local
    -- credentials in settings.xml are wrong, stale, or were revoked from the website.
    --
    -- Names the ONE-COMMAND fix, and says ON THIS CHARACTER deliberately. Windower stores settings
    -- per character, so an alt inherits whatever sits in the shared <global> block, which is often a
    -- key that was revoked or replaced long ago. The addon looks connected on that alt and fails
    -- every request silently, and the remedy is not to go regenerate anything: it is to pair THIS
    -- character, which writes a key into this character own settings section.
    return 'Your addon credentials were rejected (revoked, replaced, or belonging to another character).'
      .. ' Get a code at lootryx.com and run //lootryx setup <code> on this character.'
  end

  if code == 'ingest:replay' then
    return 'That request was already sent (duplicate). If this keeps happening, reload the addon (//lua reload lootryx).'
  end

  if code == 'business:rule_violation' then
    if contains(message, 'No event has an open check-in') or contains(message, 'There is no open check-in') then
      return 'No open check-in right now. Ask an officer to start check-in on the event.'
    end
    if contains(message, 'link code') then
      return 'That link code is invalid or expired. Get a fresh one from your My Characters page.'
    end
    if contains(message, 'world') or contains(message, 'region') then
      return 'Your shell has no FFXI world set. Ask an officer to set it in shell settings.'
    end
    return message or 'That is not allowed right now.'
  end

  if code == 'database:not_found' then
    return (message and message ~= 'Not found.' and message) or 'That could not be found on the server. It may have expired or already been removed.'
  end

  if code == 'validation:invalid' then
    return 'The addon sent a request the server could not understand. This is a bug, please report it.'
  end

  return message or ('Request failed with status ' .. tostring(status) .. '.')
end

return M
