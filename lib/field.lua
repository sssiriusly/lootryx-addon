--[[
  lib/field.lua - the one text input in this addon, and the ONE place it ever calls
  windower.send_command.

  ── Why this file exists at all, and why it is the only one like it ──────────────────────────────

  Seven of this addon's commands take an argument you have to type: an item name, a character name,
  a setup code, a bid amount. Until now the window could only PRINT those commands for you to type
  again into the chat box, which is not an interface, it is a reminder.

  Taking typed input in a Windower addon needs one thing that nothing else here needs. Returning
  `true` from the `keyboard` event consumes the key EVENT, but FFXI also polls DirectInput's
  keyboard state directly, so without a second measure the letters you type into a box would still
  walk your character forward and fire your macros. `keyboard_blockinput` is Windower's switch for
  exactly that, and it is reachable only as a console command.

  So this file calls `windower.send_command`, which the compliance suite otherwise forbids outright
  (README §2, COMPLIANCE.md §3). The forbidding is not softened, it is narrowed, and the narrowing
  is mechanical rather than a promise:

    * `send_command` appears exactly twice in the whole addon, both in this file.
    * Both arguments are STRING LITERALS: 'keyboard_blockinput 1' and 'keyboard_blockinput 0'.
      Never a variable, never a concatenation, never a format. A test fails the build otherwise, so
      no future edit can turn this into a general command dispatch without that test going red.
    * Neither is a game command. They do not reach the game server, do not produce an action, and
      cannot be made to: they tell WINDOWER to stop handing keystrokes to FFXI.

  It is worth being plain about the direction of the risk here. Blocking is the SAFE half. A text
  box without it is the dangerous thing, because then typing "Ridill" really would run whatever your
  R, I, D and L keys are bound to.

  ── Releasing it ────────────────────────────────────────────────────────────────────────────────

  A keyboard left blocked is a player who cannot move, cannot fight and cannot type, and who has no
  idea why. That is far worse than any bug in the field itself, so the release is defended from
  several directions at once: on blur, on Escape, on Enter, on a click anywhere else, on the window
  closing, on unload, and (`F.guard`) on ANY error thrown inside a handler while focus is held.
  `F.blocked()` lets a test assert the lock is not still on after each of those.

  The module is pure apart from that one call and is driven entirely by `F.key`, so its editing
  behaviour is testable without a keyboard.
]]

-- An alternate loader supplies only keyboard capture/release and clipboard access.
-- Omitted for Windower, whose two literal commands remain deliberately constrained.
local driver = ...
if driver ~= nil then
  assert(type(driver) == 'table' and type(driver.block) == 'function'
    and type(driver.release) == 'function', 'invalid field input driver')
end
local F = {}

-- DirectInput scan codes. The keyboard event reports these, not characters, so the mapping has to
-- live somewhere; this is the standard US layout.
local PRINTABLE = {
  [2] = '1', [3] = '2', [4] = '3', [5] = '4', [6] = '5',
  [7] = '6', [8] = '7', [9] = '8', [10] = '9', [11] = '0',
  [12] = '-', [13] = '=',
  [16] = 'q', [17] = 'w', [18] = 'e', [19] = 'r', [20] = 't',
  [21] = 'y', [22] = 'u', [23] = 'i', [24] = 'o', [25] = 'p',
  [26] = '[', [27] = ']',
  [30] = 'a', [31] = 's', [32] = 'd', [33] = 'f', [34] = 'g',
  [35] = 'h', [36] = 'j', [37] = 'k', [38] = 'l', [39] = ';',
  [40] = "'", [41] = '`', [43] = '\\',
  [44] = 'z', [45] = 'x', [46] = 'c', [47] = 'v', [48] = 'b',
  [49] = 'n', [50] = 'm', [51] = ',', [52] = '.', [53] = '/',
  [57] = ' ',
  -- The numeric keypad, which is where a lot of people type an amount.
  [71] = '7', [72] = '8', [73] = '9', [75] = '4', [76] = '5',
  [77] = '6', [79] = '1', [80] = '2', [81] = '3', [82] = '0',
  [83] = '.', [55] = '*', [74] = '-', [78] = '+',
}

local SHIFTED = {
  ['1'] = '!', ['2'] = '@', ['3'] = '#', ['4'] = '$', ['5'] = '%',
  ['6'] = '^', ['7'] = '&', ['8'] = '*', ['9'] = '(', ['0'] = ')',
  ['-'] = '_', ['='] = '+', ['['] = '{', [']'] = '}', [';'] = ':',
  ["'"] = '"', ['`'] = '~', ['\\'] = '|', [','] = '<', ['.'] = '>', ['/'] = '?',
}

local ESCAPE, BACKSPACE, TAB, ENTER = 1, 14, 15, 28
local PAD_ENTER, LCTRL, RCTRL = 156, 29, 157
local LSHIFT, RSHIFT, LALT, RALT = 42, 54, 56, 184
local HOME, LEFT, RIGHT, END_KEY, DELETE = 199, 203, 205, 207, 211
local KEY_A, KEY_V = 30, 47

-- The maximum a field will hold. An item name is nowhere near this; the cap exists so a stuck key
-- cannot grow a string without bound.
F.MAX = 120

local state = nil
local held = {}
local blocked = false

--- Whether the game's keyboard is currently blocked by this addon. For tests and `//lootryx status`.
function F.blocked()
  return blocked
end

--- The field being edited, or nil. `{ id, value, caret, select_all }`.
function F.state()
  return state
end

function F.value()
  return state and state.value or ''
end

function F.id()
  return state and state.id or nil
end

--- What to draw: the value with a caret marker, or the placeholder when it is empty and unfocused.
function F.display(placeholder)
  if not state then
    return placeholder or ''
  end
  if state.select_all and state.value ~= '' then
    return '[' .. state.value .. ']'
  end
  return state.value:sub(1, state.caret) .. '|' .. state.value:sub(state.caret + 1)
end

local function block()
  if not blocked then
    blocked = true
    -- LITERAL. See the header: a test rejects any other argument, so this cannot become a dispatch.
    if driver then driver.block()
    else windower.send_command('keyboard_blockinput 1') end
  end
end

local function release()
  if blocked then
    blocked = false
    -- LITERAL, and the counterpart to the line above. Runs from every teardown path there is.
    if driver then driver.release()
    else windower.send_command('keyboard_blockinput 0') end
  end
end

--- Give a field focus and take the keyboard. Re-focusing the SAME field selects all, so clicking a
--- filled box and typing replaces it rather than appending to it.
function F.focus(id, value)
  if state and state.id == id then value = state.value end
  value = tostring(value or '')
  state = { id = id, value = value, caret = #value, select_all = value ~= '' }
  block()
  return state
end

--- Drop focus and give the keyboard back. Safe to call when nothing is focused.
function F.blur()
  state = nil
  held = {}
  release()
end

--[[
  Wrap a handler so that an error inside it cannot leave the keyboard blocked.

  This is the whole reason the player can trust the feature. A Lua error in a draw or click path is
  survivable; the same error with the keyboard still locked leaves somebody unable to move or type
  in the middle of a fight, with nothing on screen explaining why. The error still propagates, it
  just does not take the keyboard with it.
]]
function F.guard(fn)
  return function(...)
    local ok, result = pcall(fn, ...)
    if not ok then
      F.blur()
      error(result, 0)
    end
    return result
  end
end

--[[
  One key. Returns true when the field consumed it, which is what stops it reaching the game.

  `submit` is called with the final value on Enter, `cancel` on Escape. Both blur first, so a
  handler that throws still cannot strand the lock.
]]
function F.key(dik, down, submit, cancel)
  if not state then
    return false
  end
  held[dik] = down or nil

  -- The release half of a key we swallowed has to be swallowed too, or the game sees a key going up
  -- that it never saw go down.
  if not down then
    return true
  end

  local ctrl = held[LCTRL] or held[RCTRL]
  local shift = held[LSHIFT] or held[RSHIFT]
  local alt = held[LALT] or held[RALT]

  if dik == ESCAPE then
    local id = state.id
    F.blur()
    if cancel then
      cancel(id)
    end
    return true
  end

  if dik == ENTER or dik == PAD_ENTER then
    -- Read both out BEFORE blurring: blur clears the state, and the handler needs to know which box
    -- it is being told about, not just what was in it.
    local value, id = state.value, state.id
    F.blur()
    if submit then
      submit(value, id)
    end
    return true
  end

  if ctrl and dik == KEY_A then
    state.select_all = true
    return true
  end

  if dik == LEFT or dik == RIGHT or dik == HOME or dik == END_KEY then
    if dik == HOME then
      state.caret = 0
    elseif dik == END_KEY then
      state.caret = #state.value
    else
      state.caret = math.max(0, math.min(#state.value, state.caret + (dik == LEFT and -1 or 1)))
    end
    state.select_all = false
    return true
  end

  if dik == BACKSPACE or dik == DELETE then
    if state.select_all then
      state.value, state.caret = '', 0
    elseif dik == BACKSPACE and state.caret > 0 then
      state.value = state.value:sub(1, state.caret - 1) .. state.value:sub(state.caret + 1)
      state.caret = state.caret - 1
    elseif dik == DELETE then
      state.value = state.value:sub(1, state.caret) .. state.value:sub(state.caret + 2)
    end
    state.select_all = false
    return true
  end

  -- Tab and the modifier keys themselves are swallowed rather than acted on: while a box has focus,
  -- Tab must not cycle the game's target.
  if dik == TAB or dik == LSHIFT or dik == RSHIFT or dik == LCTRL or dik == RCTRL then
    return true
  end

  local char = PRINTABLE[dik]
  local clipboard = driver and driver.clipboard or (not driver and windower.get_from_clipboard)
  if ctrl and dik == KEY_V and clipboard then
    local ok, pasted = pcall(clipboard)
    char = (ok and type(pasted) == 'string') and pasted or nil
  elseif ctrl or alt then
    char = nil
  elseif char and shift then
    char = SHIFTED[char] or char:upper()
  end

  if char then
    if state.select_all then
      state.value, state.select_all = '', false
      state.caret = 0
    end
    if #state.value + #char <= F.MAX then
      state.value = state.value:sub(1, state.caret) .. char .. state.value:sub(state.caret + 1)
      state.caret = state.caret + #char
    end
  end

  -- Every key is consumed while a box has focus, printable or not. Letting the unhandled ones
  -- through is what would fire a macro mid-word.
  return true
end

--[[
  The best matches for what has been typed, ranked so the obvious answer is first.

  A prefix match beats a word-start match beats a match anywhere, because somebody typing "rid" for
  Ridill should not have to read past every item with "rid" buried in it. Case-insensitive, and
  plain `find` (no patterns) so an item with a `-` in it cannot behave like a character class.
]]
function F.suggest(query, names, limit)
  limit = limit or 6
  query = tostring(query or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
  if query == '' then
    return {}
  end

  local exact, word, loose = {}, {}, {}
  for _, name in ipairs(names or {}) do
    local lower = tostring(name):lower()
    local at = lower:find(query, 1, true)
    if at == 1 then
      exact[#exact + 1] = name
    elseif at then
      -- A match that begins a word reads as intentional; one mid-word usually does not.
      local before = lower:sub(at - 1, at - 1)
      if before == ' ' or before == "'" or before == '-' then
        word[#word + 1] = name
      else
        loose[#loose + 1] = name
      end
    end
  end

  local out = {}
  for _, bucket in ipairs({ exact, word, loose }) do
    table.sort(bucket)
    for _, name in ipairs(bucket) do
      if #out >= limit then
        return out
      end
      out[#out + 1] = name
    end
  end
  return out
end

return F
