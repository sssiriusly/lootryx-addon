--[[
  json.lua · minimal pure-Lua JSON DECODER (Windower4, Lua 5.1, no deps).

  EPIC MACRO M4: `//lootryx macros pull` (lootryx.lua) needs to parse the server's
  `/api/ingest/macros/pull` response, a nested shape (books -> pages -> macros -> lines) that
  lib/errors.lua's single-field string match cannot handle (that module intentionally only ever
  pulls a flat top-level "code"/"message" off an error body, see its own header comment). This
  file adds decode only; lootryx.lua's existing `json_encode` (unchanged) still builds every
  outgoing request body, so there remains exactly one JSON encoder and now exactly one decoder,
  no second way to do either.

  Standard recursive-descent parser over strings/numbers/booleans/null/objects/arrays. Not a
  fully spec-complete decoder (only a literal ASCII passthrough for \uXXXX escapes, mapping
  anything else to "?" rather than mangling the byte stream, no surrogate pair handling; see
  json.test.ts, which pins this as the documented current behaviour, not an oversight).
  R12-TEXT (2026-08-02) correction: this is NOT because the API only ever returns ASCII macro
  text (a macro name/line/title CAN be non-ASCII since packages/validators/src/schema/macros.ts
  bounds them by BYTES, not by character set) — it is safe in PRACTICE because a plain
  `JSON.stringify` (what apps/api's `ctx.json()` uses) never emits a \uXXXX escape for a
  character it can send as a raw UTF-8 byte sequence instead, so real non-ASCII macro content
  takes the untouched literal-byte-copy branch below, never the "?" fallback. The fallback would
  only fire if some future server-side change started emitting \u escapes for non-ASCII (e.g. a
  different JSON serializer), so it is a real, if currently unreachable, decode gap, kept as the
  safer of two unverified choices (a visible "?" vs. guessing UTF-8 encoding arithmetic that has
  never run against a real client). `decode` raises a plain Lua `error()` on malformed input;
  every caller wraps it in `pcall` (never trust a network response to parse cleanly).

  API:
    local json = loadfile(windower.addon_path .. 'lib/json.lua')()
    json.decode(text) -> value  (raises on malformed input, wrap in pcall)
]]

local M = {}

local function skip_ws(s, i)
  local _, j = s:find('^%s*', i)
  return j + 1
end

local decode_value -- forward declaration, mutually recursive with array/object below

local function decode_string(s, i)
  -- s:sub(i, i) is the opening quote; i + 1 is the first content byte.
  local j = i + 1
  local out = {}
  local ESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
  while true do
    local c = s:sub(j, j)
    if c == '' then
      error('json: unterminated string starting at ' .. i)
    elseif c == '"' then
      return table.concat(out), j + 1
    elseif c == '\\' then
      local esc = s:sub(j + 1, j + 1)
      if ESCAPES[esc] then
        out[#out + 1] = ESCAPES[esc]
        j = j + 2
      elseif esc == 'u' then
        local code = tonumber(s:sub(j + 2, j + 5), 16) or 63 -- '?' fallback
        out[#out + 1] = (code < 128) and string.char(code) or '?'
        j = j + 6
      else
        out[#out + 1] = esc
        j = j + 2
      end
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
end

local function decode_number(s, i)
  local text = s:match('^%-?%d+%.?%d*[eE]?[+%-]?%d*', i)
  if not text or text == '' then
    error('json: invalid number at ' .. i)
  end
  return tonumber(text), i + #text
end

local function decode_array(s, i)
  local arr = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == ']' then
    return arr, i + 1
  end
  while true do
    local value
    value, i = decode_value(s, i)
    arr[#arr + 1] = value
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == ',' then
      i = skip_ws(s, i + 1)
    elseif c == ']' then
      return arr, i + 1
    else
      error('json: expected , or ] at ' .. i)
    end
  end
end

local function decode_object(s, i)
  local obj = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == '}' then
    return obj, i + 1
  end
  while true do
    if s:sub(i, i) ~= '"' then
      error('json: expected a string key at ' .. i)
    end
    local key
    key, i = decode_string(s, i)
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ':' then
      error('json: expected : at ' .. i)
    end
    i = skip_ws(s, i + 1)
    local value
    value, i = decode_value(s, i)
    obj[key] = value -- a JSON `null` decodes to Lua nil, i.e. the key is simply absent afterward
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == ',' then
      i = skip_ws(s, i + 1)
    elseif c == '}' then
      return obj, i + 1
    else
      error('json: expected , or } at ' .. i)
    end
  end
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    return decode_string(s, i)
  elseif c == '{' then
    return decode_object(s, i)
  elseif c == '[' then
    return decode_array(s, i)
  elseif s:sub(i, i + 3) == 'true' then
    return true, i + 4
  elseif s:sub(i, i + 4) == 'false' then
    return false, i + 5
  elseif s:sub(i, i + 3) == 'null' then
    return nil, i + 4
  elseif c:match('[%-%d]') then
    return decode_number(s, i)
  else
    error('json: unexpected character "' .. c .. '" at ' .. i)
  end
end

--- decode(s) -> value. Raises a Lua error on malformed input; callers should wrap in pcall.
function M.decode(s)
  if not s or s == '' then
    error('json: empty input')
  end
  local value = decode_value(s, 1)
  return value
end

return M
