--[[
  lib/roster.lua : corrections to the alliance list, for the people the client cannot see.

  THE PROBLEM. An FFXI alliance holds eighteen. An HNM camp routinely holds more, and the rest are
  standing in the same zone doing the same work: a second alliance, someone's mule holding a spot,
  the person who zoned out for thirty seconds to reapply a buff. `windower.ffxi.get_party()` reports
  eighteen names at most, so without a correction those extra people earn nothing all night and
  there is no way to fix it from inside the game. The HideOut Raid Tracker addon solves this with
  `+Name` / `-Name` arguments on each logging command, and the idea is right.

  WHAT IS DIFFERENT HERE, and why. HRT applies the adjustment to ONE typed command. This addon takes
  automatic snapshots every few minutes for the length of an event, so a per-command adjustment
  would have to be retyped on every capture, which in practice means the auto loop keeps reporting
  the wrong roster. The adjustment here is therefore a SESSION-LEVEL correction: set once, applied
  to every capture until cleared or until the addon is reloaded.

  That makes visibility the whole design problem, because a standing adjustment that nobody can see
  is a silent modifier on other people's DKP. So it is deliberately loud: every snapshot reply says
  how many names were added and removed, `//lootryx status` prints the full list, and it is held in
  memory ONLY. It is never written to settings.xml, so `//lua reload lootryx` clears it. A
  correction that outlived the night it was made for would eventually credit someone who went home.

  PROVENANCE. An added name is a person an OFFICER asserted was there, not one the client observed,
  and those two things should not be indistinguishable in the record: "verified attendance" is the
  whole point of reading the party list in the first place. The snapshot therefore carries added
  names in BOTH `characters` (so credit flows through the ordinary path) and `assertedCharacters`,
  which the server records as `Presence.source = 'ADDON_ASSERTED'`. Re-sending a name in both lists
  is harmless because Presence dedupes on (snapshotId, membershipId).

  One consequence worth knowing: an asserted name does NOT satisfy the reporter's own self-presence
  requirement server-side. Without that, `roster +Yourself` would clear the single check that ties a
  report to a checkable self-claim, and a keyholder could sit in town asserting a party they were
  never in. Asserting covers the people eighteen alliance slots cannot show; it is not a way to
  vouch for yourself.

  Note this grants an officer nothing they did not already have: the website has manual attendance
  marking and PIN check-in. It moves an existing power in-game, where the camp is.

  PURE POLICY. No require, no Windower API, no transport, no I/O, no clock. Same shape as
  lib/hud.lua and lib/queue.lua.
]]

local M = {}

-- How many names a correction may ADD.
--
-- Bounded because the server bounds it: `ingestSnapshotSchema` caps `characters` at 64, and a
-- payload over that is rejected WHOLE, so one name too many would cost the entire alliance their
-- credit rather than just the extra person. 32 leaves comfortable room beside a full eighteen-slot
-- alliance while keeping this side of the wire provably inside the other side's limit. Refusing the
-- 33rd here, with a message, is strictly better than building a payload that will bounce.
M.MAX_ADDED = 32

--- FFXI renders names as `Talvos`, and players type them every other way. One canonical form so
--- `-talvos`, `-TALVOS` and `-Talvos` all mean the same person.
function M.normalize(name)
  if type(name) ~= 'string' then
    return nil
  end
  local trimmed = name:match('^%s*(.-)%s*$')
  if trimmed == '' then
    return nil
  end
  return trimmed:sub(1, 1):upper() .. trimmed:sub(2):lower()
end

function M.new()
  return { added = {}, removed = {} }
end

local function index_of(list, value)
  for i, item in ipairs(list) do
    if item == value then
      return i
    end
  end
  return nil
end

local function remove_value(list, value)
  local at = index_of(list, value)
  if at then
    table.remove(list, at)
  end
end

--[[
  Applies one `+A,B` or `-C` token. Returns the list it went onto and the normalized name, so the
  caller can report exactly what it understood rather than echoing what was typed.

  A name may only be on ONE list at a time: `+Fahad` after `-Fahad` moves him rather than leaving
  him on both, because "added and removed" has no meaningful answer and silently picking one is how
  a roster ends up wrong in a way nobody can explain.
]]
function M.apply_token(adjustment, sign, raw_name)
  local name = M.normalize(raw_name)
  if not name then
    return nil, nil
  end
  if sign == '+' then
    remove_value(adjustment.removed, name)
    if not index_of(adjustment.added, name) then
      if #adjustment.added >= M.MAX_ADDED then
        return 'full', name
      end
      adjustment.added[#adjustment.added + 1] = name
    end
    return 'added', name
  end
  remove_value(adjustment.added, name)
  if not index_of(adjustment.removed, name) then
    adjustment.removed[#adjustment.removed + 1] = name
  end
  return 'removed', name
end

--[[
  Parses `+Fahad,Night -Greysoul` into the adjustment, HRT's syntax exactly.

  Commas AND separate tokens both work, because both are what people type under pressure. A bare
  word with no sign is an error rather than a guess: silently assuming `+` would let a typo add
  someone to the payroll.
]]
function M.parse_into(adjustment, args)
  local touched, rejected = {}, {}
  for _, arg in ipairs(args or {}) do
    local token = tostring(arg)
    local sign = token:sub(1, 1)
    if sign == '+' or sign == '-' then
      local body = token:sub(2)
      for piece in body:gmatch('([^,]+)') do
        local list, name = M.apply_token(adjustment, sign, piece)
        if list then
          touched[#touched + 1] = { list = list, name = name }
        end
      end
    else
      rejected[#rejected + 1] = token
    end
  end
  return touched, rejected
end

--[[
  The corrected roster.

  Removals are applied AFTER additions and win outright, which matters when the same name reaches
  both lists through different routes. Dropping a name is the conservative outcome: failing to
  credit someone is a thing they will notice and can raise, while crediting someone who was not
  there is a thing nobody notices.

  Returns the corrected list, the names actually added (those not already read from the party), and
  the names actually removed (those that WERE present to remove). Reporting the effective counts
  rather than the requested ones is what makes a typo visible: `-Grey` when you meant `-Greysoul`
  removes nobody, and the reply says so.
]]
function M.apply(names, adjustment)
  local out, seen = {}, {}
  for _, name in ipairs(names or {}) do
    local canonical = M.normalize(name) or name
    if not seen[canonical] then
      seen[canonical] = true
      out[#out + 1] = name
    end
  end

  local added = {}
  for _, name in ipairs(adjustment and adjustment.added or {}) do
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
      added[#added + 1] = name
    end
  end

  local removed = {}
  for _, name in ipairs(adjustment and adjustment.removed or {}) do
    local at = nil
    for i, present in ipairs(out) do
      if (M.normalize(present) or present) == name then
        at = i
        break
      end
    end
    if at then
      table.remove(out, at)
      removed[#removed + 1] = name
    end
  end

  return out, added, removed
end

function M.is_empty(adjustment)
  return #(adjustment and adjustment.added or {}) == 0 and #(adjustment and adjustment.removed or {}) == 0
end

--- One line for `//lootryx status` and the snapshot reply, or nil when there is nothing to say.
--- Never silent when an adjustment is live: that is the entire safeguard.
function M.describe(adjustment)
  if M.is_empty(adjustment) then
    return nil
  end
  local parts = {}
  if #adjustment.added > 0 then
    parts[#parts + 1] = 'adding ' .. table.concat(adjustment.added, ', ')
  end
  if #adjustment.removed > 0 then
    parts[#parts + 1] = 'excluding ' .. table.concat(adjustment.removed, ', ')
  end
  return table.concat(parts, '; ')
end

-- Build a replacement without mutating the active adjustment on validation failure.
function M.from_fields(include, exclude)
  local adjustment=M.new()
  for i,field in ipairs({include or '',exclude or ''}) do
    for raw in field:gmatch('[^,%s]+') do
      if not raw:match('^[A-Za-z]+$') then
        return nil, 'Use character names only, separated by commas or spaces.'
      end
      local name=M.normalize(raw)
      if i==2 and index_of(adjustment.added,name) then
        return nil, name..' is in both lists. Choose Include or Exclude.'
      end
      local result=M.apply_token(adjustment,i==1 and '+' or '-',name)
      if result=='full' then return nil,'Include up to '..M.MAX_ADDED..' players.' end
    end
  end
  return adjustment
end

return M
