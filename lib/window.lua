--[[
  Lootryx addon · the window MODEL. Pure logic, zero Windower calls.

  This module decides everything about the window except how pixels reach the screen: which tabs
  exist for the player's tier, what rows are in the active tab, where every rectangle and label
  sits, and which rectangles are clickable. It returns a plain description, and a renderer turns
  that into `windower.prim` rectangles and `texts` labels.

  The split is the point. lib/hud.lua already works this way, which is why the overlay is fully
  testable without a game. Here it buys something extra: the addon ships on Windower and (planned)
  Ashita, whose drawing layers are completely different (primitives and text objects vs ImGui), so
  keeping layout and hit regions in one pure module means the port rewrites the renderer only.

  TEXT IS MEASURED, NOT GUESSED. The first version estimated widths from character counts and the
  tabs visibly overlapped in game. `measure(text, size)` is injected by the caller: the renderer
  passes one backed by the real font metrics, and tests pass a deterministic one. A layout module
  that cannot measure can only ever approximate, and approximate layout is what that screenshot was.

  Coordinates are PANEL-RELATIVE. The renderer adds the window's own origin, so dragging never
  touches this module.
]]

local M = {}

-- ── metrics ──────────────────────────────────────────────────────────────────
-- Generous on purpose. The first pass packed rows 34px apart with 8px padding and read as a wall
-- of text; nothing here is decoration, it is the difference between scanning and squinting.
-- Narrower reading column; measured tabs wrap without shrinking the type.
M.WIDTH = 620
M.MIN_HEIGHT = 560
local TITLE_H = 32
local STATUS_H = 26
local TAB_H = 28
-- A listing row: title, subtitle, a chip and a countdown. It was 52, which read as generous with a
-- 604px window and as wasteful at 700: a full Settings tab stopped fitting a 720p client, and rows
-- trimmed away are worse than rows drawn a little tighter.
local ROW_H = 44
local FOOT_H = 28
local PAD = 16
local GAP = 6
-- Air inside a button, either side of its label. Generous on purpose: this is the number that
-- decides whether a control looks deliberate or looks like the text escaped it.
local BTN_PAD = 26
-- Tabs are padded and spaced tighter than buttons. They carry the same weight as a row of buttons
-- at BTN_PAD, and a member's nine of them wrapped onto a second line, which cost a row of height to
-- say nothing. A tab is a label you click, not a control that needs to look pressable.
local TAB_PAD = 22
local TAB_GAP = 6
-- A section label is a row too, just a short one. Making it a row kind rather than a special case
-- keeps one list, one loop, and one place that knows how tall anything is.
local HEADER_H = 26
-- A form control and one of its options. Both are shorter than a list row on purpose: a listing
-- row carries a title, a subtitle, a chip and a countdown, and a form control carries a label and a
-- value. Giving them the same 52px made a five-field form scroll off a screen it should not have
-- come close to filling.
local FORM_H = 44
local OPTION_H = 26
local CHIP_H = 18

local SIZE_TITLE = 12
local SIZE_TAB = 10
local SIZE_ROW = 11
local SIZE_SUB = 10
local SIZE_FOOT = 9

--[[
  Themes.

  Every colour a row or a chrome element can ask for is a NAME, never an RGB triple, so a theme is
  one table and adding another costs nothing anywhere else in the addon. The palette keys are
  semantic (`accent`, `info`, `good`, `bad`) rather than literal (`gold`, `blue`), which is what
  lets San d'Oria's red and Windurst's green both be "accent" without either looking wrong.

  The FFXI-native looks are drawn from the game's own furniture: Vana'diel is the classic menu, a
  deep translucent navy with a pale border and gold selection, and the three nation themes take
  their colours from the nations themselves.
]]
M.THEMES = {
  vanadiel = {
    label = "Vana'diel",
    panel = { 12, 18, 44 }, panel_alpha = 226,
    chrome = { 26, 38, 82 },
    line = { 96, 128, 200 },
    hot = { 44, 66, 132 },
    bright = { 248, 249, 253 },
    accent = { 255, 214, 122 },
    dim = { 156, 170, 202 },
    good = { 140, 226, 156 },
    bad = { 255, 126, 116 },
    info = { 150, 205, 255 },
    btn = { 52, 78, 152 },
    btn_hi = { 74, 104, 190 },
    btn_edge = { 132, 168, 240 },
  },
  lootryx = {
    label = 'Lootryx',
    panel = { 14, 13, 10 }, panel_alpha = 232,
    chrome = { 36, 30, 19 },
    line = { 86, 74, 48 },
    hot = { 58, 47, 24 },
    bright = { 246, 244, 239 },
    accent = { 255, 200, 90 },
    dim = { 158, 150, 134 },
    good = { 130, 220, 140 },
    bad = { 255, 105, 97 },
    info = { 130, 200, 255 },
    btn = { 72, 58, 30 },
    btn_hi = { 104, 84, 42 },
    btn_edge = { 214, 176, 96 },
  },
  sandoria = {
    label = "San d'Oria",
    panel = { 34, 12, 14 }, panel_alpha = 230,
    chrome = { 66, 20, 24 },
    line = { 158, 74, 66 },
    hot = { 96, 30, 32 },
    bright = { 250, 242, 238 },
    accent = { 236, 196, 128 },
    dim = { 188, 152, 146 },
    good = { 150, 214, 150 },
    bad = { 255, 140, 120 },
    info = { 226, 176, 150 },
    btn = { 112, 36, 38 },
    btn_hi = { 148, 52, 52 },
    btn_edge = { 226, 138, 118 },
  },
  bastok = {
    label = 'Bastok',
    panel = { 20, 22, 24 }, panel_alpha = 232,
    chrome = { 40, 44, 48 },
    line = { 104, 112, 120 },
    hot = { 62, 68, 74 },
    bright = { 240, 242, 244 },
    accent = { 232, 168, 72 },
    dim = { 156, 164, 172 },
    good = { 138, 206, 148 },
    bad = { 240, 118, 104 },
    info = { 168, 196, 216 },
    btn = { 74, 80, 88 },
    btn_hi = { 100, 108, 118 },
    btn_edge = { 186, 196, 208 },
  },
  windurst = {
    label = 'Windurst',
    panel = { 16, 30, 20 }, panel_alpha = 230,
    chrome = { 28, 56, 34 },
    line = { 92, 150, 100 },
    hot = { 42, 82, 50 },
    bright = { 244, 250, 240 },
    accent = { 246, 224, 138 },
    dim = { 158, 186, 160 },
    good = { 152, 226, 152 },
    bad = { 252, 138, 120 },
    info = { 196, 232, 168 },
    btn = { 52, 98, 60 },
    btn_hi = { 74, 130, 84 },
    btn_edge = { 158, 214, 160 },
  },
  jeuno = {
    label = 'Jeuno',
    panel = { 24, 18, 38 }, panel_alpha = 230,
    chrome = { 46, 34, 72 },
    line = { 130, 108, 180 },
    hot = { 68, 52, 110 },
    bright = { 246, 244, 252 },
    accent = { 214, 196, 240 },
    dim = { 166, 156, 190 },
    good = { 148, 220, 168 },
    bad = { 252, 130, 130 },
    info = { 182, 190, 246 },
    btn = { 82, 64, 130 },
    btn_hi = { 110, 88, 166 },
    btn_edge = { 186, 168, 232 },
  },
}

M.THEME_ORDER = { 'vanadiel', 'lootryx', 'sandoria', 'bastok', 'windurst', 'jeuno' }
M.DEFAULT_THEME = 'vanadiel'

--[[
  What colour a content category reads as.

  A board is scanned, not read: the eye should be able to pick out the BCNMs without parsing every
  line. These are semantic palette names, so each theme decides the actual hue and none of them can
  end up illegible against their own background.
]]
M.CATEGORY_COLOUR = {
  EXP = 'good',
  MISSION = 'info',
  BCNM = 'bad',
  MENTOR = 'accent',
  CRAFT = 'dim',
  OTHER = 'dim',
}

function M.category_colour(category)
  return M.CATEGORY_COLOUR[tostring(category or ''):upper()] or 'dim'
end

function M.theme(name)
  return M.THEMES[name] or M.THEMES[M.DEFAULT_THEME]
end

function M.theme_names()
  local names = {}
  for _, id in ipairs(M.THEME_ORDER) do
    names[#names + 1] = id
  end
  return names
end

-- ── tabs ─────────────────────────────────────────────────────────────────────
--[[
  Which tabs exist, by tier.

  Three tiers, and the difference is not decoration. A guest has no account: the world board and
  the linkshell directory are public reads, so those work and nothing else does. Somebody signed in
  with no linkshell gets the same. A member additionally gets the shell-scoped boards, because only
  then is there a shell to scope them to.

  Labels are SHORT because they sit in a row that has to fit. "Looking for Group" and "Recruiting"
  spelled out ran past the window edge and collided; LFG and LFM are what an FFXI player would say
  out loud anyway.
]]
function M.tabs_for(tier, counts)
  counts = counts or {}
  local tabs = {
    { id = 'home', label = 'Home' },
    { id = 'lfg', label = 'LFG', count = counts.lfg },
    { id = 'lfm', label = 'LFM', count = counts.lfm },
    { id = 'shells', label = 'Linkshells', count = counts.shells },
  }

  -- The linkshell half, and the reason a guest sees a shorter strip. All three read shell data an
  -- IngestKey is required to fetch, so without one there is nothing behind them to show.
  if tier == 'member' then
    tabs[#tabs + 1] = { id = 'auctions', label = 'Auctions', count = counts.auctions }
    tabs[#tabs + 1] = { id = 'windows', label = 'Windows', count = counts.windows }
    tabs[#tabs + 1] = { id = 'shell', label = 'Shell' }
  end

  -- Then the two that are about YOU rather than about the world, pinned to the end so they keep
  -- the same place whether or not the linkshell tabs are there. Me was in the middle of the strip,
  -- which meant joining a linkshell moved it. Everything about the character you are on lives in
  -- it: split out of Home because link state is a one-time chore, and a banner about it on the
  -- front page every login nags rather than informs.
  tabs[#tabs + 1] = { id = 'me', label = 'Me' }
  tabs[#tabs + 1] = { id = 'settings', label = 'Settings' }
  return tabs
end

--- The tab actually shown: the requested one when the tier allows it, Home otherwise. A guest who
--- had Auctions open and then signed out must not be left staring at a tab that cannot load.
function M.resolve_tab(tier, wanted, counts)
  for _, tab in ipairs(M.tabs_for(tier, counts)) do
    if tab.id == wanted then
      return wanted
    end
  end
  return 'home'
end

-- ── the immediate-mode builder ───────────────────────────────────────────────
-- Draw calls and hit regions are emitted together, from one place, so they cannot drift apart.

local function canvas_for(theme, measure, hover)
  return {
    rects = {}, labels = {}, regions = {}, icons = {},
    theme = theme,
    hover = hover,
    measure = measure or function(text, size)
      -- Fallback only, for a caller with no font metrics (tests that do not care about pixels).
      return math.floor(#tostring(text or '') * (size or 10) * 0.78) + 10
    end,
  }
end

local function rgb(c, name)
  return c.theme[name] or c.theme.bright
end

local function rect(c, id, x, y, w, h, colour, alpha)
  c.rects[#c.rects + 1] = { id = id, x = x, y = y, w = w, h = h, colour = colour, alpha = alpha or 240 }
end

--[[
  An icon.

  Bundled icons include theme-tinted controls and authored full-colour objects.
  Objects use a white tint to preserve their artwork. See assets/ARTWORK.md.
]]
local function icon(c, id, name, x, y, size, colour, alpha)
  c.icons[#c.icons + 1] = {
    id = id, name = name, x = x, y = y, size = size, colour = colour, alpha = alpha or 255,
  }
end

local function label(c, id, x, y, text, colour, size)
  c.labels[#c.labels + 1] = { id = id, x = x, y = y, text = tostring(text or ''), colour = colour, size = size }
end

--[[
  Object art for navigation concepts; explicit text badges remain for states such
  as CONFIRM and LOCK, where replacing the word would obscure the action's meaning.
]]
local ART_TAGS = {
  LFG = 'pennant', LFM = 'pennant', LFS = 'pennant', SEEK = 'pennant',
  DROP = 'drop', EYE = 'alliance', TOP = 'standings', BTY = 'bounty', POLL = 'poll', FIND = 'lookup',
  DKP = 'coins', JOB = 'jobs', MCR = 'macrobook', WISH = 'wishlist', OWNER = 'character', ADD = 'claim',
  LS = 'pearl', BID = 'envelope', GIL = 'coffer', LOOT = 'recent',
  CAL = 'calendar', SNAP = 'alliance', HNM = 'clock',
}

local function tag(c, id, x, y, text, colour)
  local w = c.measure(text, SIZE_FOOT) + 12
  rect(c, 'tag_' .. id, x, y, w, 18, rgb(c, colour), 60)
  rect(c, 'tagl_' .. id, x, y, 2, 18, rgb(c, colour), 220)
  label(c, 'tag_' .. id, x + 7, y + 3, text, rgb(c, colour), SIZE_FOOT)
  return w
end


--[[
  Cut a string to the space it actually has.

  Rows carry text nobody sized: a linkshell's own blurb, a listing comment, the setup line. Drawing
  it and hoping was how "then run //lootryx setup <code>" ended up printed through the Steps button
  beside it. The width is known here and the measurement is real, so the string is trimmed to fit
  with a marker rather than allowed to run.
]]
local function clip(c, text, max_width, size)
  text = tostring(text or '')
  if max_width <= 0 then return '' end
  if c.measure(text, size) <= max_width then
    return text
  end
  -- Binary search rather than a character loop: measure() may be a real font call, and a long
  -- blurb would otherwise cost dozens of them every rebuild.
  local low, high = 0, #text
  while low < high do
    local mid = math.floor((low + high + 1) / 2)
    if c.measure(text:sub(1, mid) .. '...', size) <= max_width then
      low = mid
    else
      high = mid - 1
    end
  end
  return text:sub(1, low) .. '...'
end

--[[
  A clickable rectangle: drawn AND registered in one call, so a button you can see but not click
  (or click but not see) is not expressible.

  Three parts, because a control needs all three to read as one. A FACE lighter than the surface it
  sits on, so it looks raised rather than punched out; the first version filled buttons darker than
  the panel and they read as holes. A one-pixel BORDER, which is what gives an edge instead of a
  smudge. And a hover face, so the pointer confirms the thing is live before you commit to clicking.
]]
local function button(c, id, x, y, w, h, text, colour, size, art, switch)
  local hovered = c.hover == id
  local variant=(c.action_variants or {})[id] or 'secondary'
  local visual=id..'_'..tostring(#c.regions+1)
  -- Switch face and indicator do not overlap: Windower retains primitive creation order.
  local inset_left=switch==false and 10 or 0
  rect(c, 'btn_' .. visual, x+inset_left, y, switch~=nil and w-10 or w, h, rgb(c, hovered and 'btn_hi' or (variant=='primary' and 'btn' or 'chrome')))
  if switch~=nil then rect(c,'switch_'..visual,x+(switch and w-8 or 2),y+2,6,h-4,rgb(c,switch and 'good' or 'dim'),200) end
  local edge = rgb(c, variant=='danger' and 'bad' or (variant=='primary' and 'accent' or 'line'))
  if variant=='danger' then colour=rgb(c,'bad') end
  local edge_alpha = hovered and 255 or 170
  rect(c, 'btnT_' .. visual, x, y, w, 1, edge, edge_alpha)
  rect(c, 'btnB_' .. visual, x, y + h - 1, w, 1, edge, edge_alpha)
  rect(c, 'btnL_' .. visual, x, y, 1, h, edge, edge_alpha)
  rect(c, 'btnR_' .. visual, x + w - 1, y, 1, h, edge, edge_alpha)
  local inset = art and 22 or 0
  if art then icon(c, 'cta_' .. visual, 'art-' .. art, x+5, y+2, 20, {255,255,255}) end
  local tw = c.measure(text, size or SIZE_TAB)
  label(c, 'btn_' .. visual, x + inset + math.max(4, math.floor((w - inset - tw) / 2)), y + math.floor((h - (size or SIZE_TAB) - 4) / 2),
    text, hovered and rgb(c, 'bright') or (colour or rgb(c, 'accent')), size or SIZE_TAB)
  c.regions[#c.regions + 1] = { id = id, x = x, y = y, w = w, h = h, enabled = true }
end

-- ── sections ─────────────────────────────────────────────────────────────────

local function draw_title(c, state)
  rect(c, 'title', 0, 0, M.WIDTH, TITLE_H, rgb(c, 'chrome'))
  rect(c, 'titleline', 0, TITLE_H - 1, M.WIDTH, 1, rgb(c, 'line'))
  label(c, 'title', PAD, 7, 'Lootryx', rgb(c, 'accent'), SIZE_TITLE)

  local size = 22
  local x = M.WIDTH - PAD - size
  for _, ico in ipairs({ { 'close', 'close' }, { 'mini', 'minimise' }, { 'refresh', 'refresh', 'good' }, { 'settings', 'gear', 'accent' }, { 'notifications', 'notification', 'accent' } }) do
    local top = math.floor((TITLE_H - size) / 2)
    local hovered = c.hover == ico[1]
    rect(c, 'btn_' .. ico[1], x, top, size, size, rgb(c, hovered and 'btn_hi' or 'btn'), hovered and 240 or 150)
    icon(c, ico[1], ico[2], x + 5, top + 5, size - 10, rgb(c, hovered and 'bright' or (ico[3] or 'dim')))
    c.regions[#c.regions + 1] = { id = ico[1], x = x, y = top, w = size, h = size, enabled = true }
    if ico[1]=='notifications' and (tonumber(state.unread_notifications) or 0)>0 then
      rect(c,'unread_notifications',x+size-6,top+1,5,5,rgb(c,'good'),255)
    end
    x = x - size - 5
  end
  if state.surface_layout then
    local left=PAD+c.measure('Lootryx',SIZE_TITLE)+18
    local identity=table.concat({state.name or '',state.world or '',state.shell or ''},' / ')
    label(c,'identity',left,11,clip(c,identity,x-left-4,SIZE_FOOT),rgb(c,'dim'),SIZE_FOOT)
  end
end

--[[
  The primary action for the tab you are on, or nothing.

  There used to be one button in the top-right that read "Post listing" whatever you were looking
  at, so a Party Finder action sat above the auction board and above Settings. An action belongs to
  the thing it acts on; a tab with nothing to do gets no button, and the bar is just a heading.
]]
local function status_action(state)
  if state.surface_layout or state.focused_view or state.find_layout then return nil,nil end
  if state.tab == 'lfm' or state.tab == 'lfg' then
    if state.registered then
      return 'withdraw', 'Withdraw'
    end
    return 'post', 'Post listing'
  elseif state.tab == 'me' and state.tier ~= 'member' then
    return 'signin', 'How to link'
  elseif state.tab == 'shell' then
    return 'cmd:snap', 'Post snapshot'
  elseif state.tab == 'auctions' and state.tier == 'member' then
    return 'auction', 'Open auction'
  end
  return nil, nil
end

local function draw_status(c, state)
  local y = TITLE_H
  rect(c, 'status', 0, y, M.WIDTH, STATUS_H, rgb(c, 'panel'), 0)
  local ty = y + math.floor((STATUS_H - SIZE_ROW - 4) / 2)

  -- The top bar says WHERE YOU ARE and what you can do from here. The footer says WHO YOU ARE.
  -- They both used to say the tier, so the window read "Guest Phoenix" above and "Blade guest"
  -- below, which is the same fact printed twice and neither line carrying its own weight.
  local text, colour
  if state.registered then
    text, colour = 'Posted  ' .. tostring(state.registered), rgb(c, 'good')
  else
    text, colour = (state.shell or state.world or 'Phoenix'), rgb(c, 'bright')
  end
  label(c, 'status', PAD, ty, text, colour, SIZE_ROW)

  local action, action_label = status_action(state)
  if action then
    local art = ({post='pennant', withdraw='pennant', signin='claim', ['cmd:snap']='alliance', auction='coffer'})[action]
    local bw = c.measure(action_label, SIZE_TAB) + BTN_PAD + (art and 22 or 0)
    button(c, action, M.WIDTH - PAD - bw, y + math.floor((STATUS_H - 24) / 2), bw, 24, action_label, rgb(c, 'accent'), nil, art)
  end
  rect(c, 'statusline', 0, y + STATUS_H - 1, M.WIDTH, 1, rgb(c, 'line'), 140)
  return y + STATUS_H
end

--- The tab strip, wrapping onto a second line rather than running off the edge. The first version
--- assumed one row always fit; it did not, and the labels drew on top of one another.
local function draw_tabs(c, tabs, active, top, prefix)
  prefix = prefix or 'tab:'
  local padding=prefix=='tab:' and 14 or TAB_PAD
  local gap=prefix=='tab:' and 4 or TAB_GAP
  local x, y = PAD, top + 4
  local rows = 1
  for _, tab in ipairs(tabs) do
    local text = tab.label
    if tab.count and tab.count > 0 then
      text = text .. '  ' .. tostring(tab.count)
    end
    local w = c.measure(text, SIZE_TAB) + padding
    if x + w > M.WIDTH - PAD and x > PAD then
      x, y = PAD, y + TAB_H
      rows = rows + 1
    end
    local id = tab.action_id or (prefix .. tab.id)
    if tab.id == active then
      rect(c, 'tab_' .. id, x, y, w, TAB_H - 6, rgb(c, 'btn'))
      rect(c, 'tabu_' .. id, x, y + TAB_H - 8, w, 2, rgb(c, 'accent'))
    elseif c.hover == id then
      rect(c, 'tab_' .. id, x, y, w, TAB_H - 6, rgb(c, 'hot'))
    end
    local tab_colour = rgb(c, 'dim')
    if tab.id == active then
      tab_colour = rgb(c, 'bright')
    elseif c.hover == id then
      tab_colour = rgb(c, 'bright')
    end
    label(c, 'tab_' .. id, x + math.floor(padding / 2), y + 4, text, tab_colour, SIZE_TAB)
    c.regions[#c.regions + 1] = { id = id, x = x, y = y, w = w, h = TAB_H - 6, enabled = true }
    x = x + w + gap
  end
  local bottom = top + 4 + rows * TAB_H
  rect(c, 'tabline', 0, bottom - 2, M.WIDTH, 1, rgb(c, 'line'), 140)
  return bottom
end

--[[
  A text box.

  The whole row is the target, not just the box: aiming at a 28px strip is a worse experience than
  it sounds, and there is nothing else on the row to hit by mistake. A focused box lights its edges
  and shows a caret, because with the keyboard captured the player needs to be able to see at a
  glance where their typing is going.
]]
local function draw_navigation(c, state, active, top)
  local primary, secondary, group, selected = M.navigation.describe(active, state.tier, state.counts, state.board)
  local bottom = draw_tabs(c, primary, group, top, 'nav:')
  if #secondary > 0 then bottom = draw_tabs(c, secondary, selected, bottom) end
  return bottom
end

local function draw_field(c, index, y, row)
  local key = 'f' .. index
  local focused = row.focused == true
  rect(c, 'fbg_' .. key, 0, y, M.WIDTH, FORM_H, rgb(c, 'chrome'), focused and 130 or 70)
  rect(c, 'ftick_' .. key, 0, y + 4, 3, FORM_H - 8, rgb(c, focused and 'accent' or 'dim'))
  label(c, 'flb_' .. key, PAD, y + 15, tostring(row.title or ''):upper(), rgb(c, 'accent'), SIZE_FOOT)

  local bx = PAD + 104
  local bw = M.WIDTH - PAD - bx
  local edge = rgb(c, focused and 'accent' or 'line')
  rect(c, 'fbox_' .. key, bx, y + 8, bw, 28, rgb(c, 'panel'), 210)
  rect(c, 'fT_' .. key, bx, y + 8, bw, 1, edge, focused and 255 or 150)
  rect(c, 'fB_' .. key, bx, y + 35, bw, 1, edge, focused and 255 or 150)
  rect(c, 'fL_' .. key, bx, y + 8, 1, 28, edge, focused and 255 or 150)
  rect(c, 'fR_' .. key, bx + bw - 1, y + 8, 1, 28, edge, focused and 255 or 150)

  local shown = row.value
  if shown == nil or shown == '' then
    shown = row.placeholder or ''
  end
  label(c, 'fv_' .. key, bx + 8, y + 14, clip(c, shown, bw - 16, SIZE_ROW),
    rgb(c, (row.value and row.value ~= '') and 'bright' or 'dim'), SIZE_ROW)

  if row.action_id then
    c.regions[#c.regions + 1] = { id = row.action_id, x = 0, y = y, w = M.WIDTH, h = FORM_H, enabled = true, value = row.value or '' }
  end
  return y + FORM_H
end

--[[
  A dropdown, closed: a label and the value in the same boxed field a text input uses.

  Category and role used to be a row with a Next button that stepped through the values one at a
  time. Cycling is fine for two options and hostile for six: you cannot see what is available, you
  cannot go back, and you have to count clicks to land on the one you want. It reads as a stand-in
  for a control rather than a control.
]]
local function draw_select(c, index, y, row)
  local key = 's' .. index
  local open = row.open == true
  rect(c, 'sbg_' .. key, 0, y, M.WIDTH, FORM_H, rgb(c, 'chrome'), open and 130 or 70)
  rect(c, 'stick_' .. key, 0, y + 4, 3, FORM_H - 8, rgb(c, open and 'accent' or 'dim'))
  label(c, 'slb_' .. key, PAD, y + 15, tostring(row.title or ''):upper(), rgb(c, 'accent'), SIZE_FOOT)

  local bx = PAD + 104
  local bw = M.WIDTH - PAD - bx
  local edge = rgb(c, open and 'accent' or 'line')
  rect(c, 'sbox_' .. key, bx, y + 8, bw, 28, rgb(c, 'panel'), 210)
  rect(c, 'sT_' .. key, bx, y + 8, bw, 1, edge, open and 255 or 150)
  rect(c, 'sB_' .. key, bx, y + 35, bw, 1, edge, open and 255 or 150)
  rect(c, 'sL_' .. key, bx, y + 8, 1, 28, edge, open and 255 or 150)
  rect(c, 'sR_' .. key, bx + bw - 1, y + 8, 1, 28, edge, open and 255 or 150)

  label(c, 'sv_' .. key, bx + 8, y + 14, clip(c, tostring(row.value or ''), bw - 40, SIZE_ROW),
    rgb(c, 'bright'), SIZE_ROW)
  -- The marker that says this opens. Two stacked bars rather than a glyph, because the font a
  -- player has is not something this addon gets to assume.
  local ax = bx + bw - 18
  rect(c, 'sa1_' .. key, ax, y + (open and 18 or 20), 10, 2, rgb(c, 'accent'), 220)
  rect(c, 'sa2_' .. key, ax + 2, y + (open and 22 or 24), 6, 2, rgb(c, 'accent'), 220)

  if row.action_id then
    c.regions[#c.regions + 1] = { id = row.action_id, x = 0, y = y, w = M.WIDTH, h = FORM_H, enabled = true }
  end
  return y + FORM_H
end

--- One choice in an open dropdown. Indented under the box it belongs to, and marked when it is the
--- value currently held, so the list says where you are as well as where you could go.
local function draw_choices(c,index,y,row)
  local count=#(row.options or {})
  local h=row.compact and 40 or 76
  if count==0 then return y+h end
  local width=(M.WIDTH-PAD*2-GAP*(count-1))/count
  for n,option in ipairs(row.options) do
    local x=PAD+(n-1)*(width+GAP)
    local key='choice_'..index..'_'..n
    local colour=option.colour or rgb(c,'accent')
    rect(c,key,x,y+4,width,h-8,rgb(c,option.selected and 'hot' or 'chrome'),220)
    rect(c,key..'_edge',x,y+h-5,width,2,option.selected and colour or rgb(c,'line'),220)
    if c.hover==option.id then rect(c,key..'_hover',x,y+4,width,2,colour,220) end
    local shown=clip(c,option.label,width-(row.compact and option.icon and 38 or 12),SIZE_SUB)
    local text_x=x+(width-c.measure(shown,SIZE_SUB))/2
    if option.icon then
      if row.compact then
        local left=x+(width-c.measure(shown,SIZE_SUB)-28)/2
        icon(c,key,option.icon,left,y+7,24,{255,255,255});text_x=left+28
      else icon(c,key,option.icon,x+(width-32)/2,y+9,32,{255,255,255}) end
    end
    label(c,key..'_label',text_x,y+(row.compact and 13 or 47),shown,option.selected and colour or rgb(c,'bright'),SIZE_SUB)
    if option.selected and not row.compact then
      rect(c,key..'_check',x+width-14,y+10,7,7,colour,230)
    end
    c.regions[#c.regions+1]={id=option.id,x=x,y=y+4,w=width,h=h-8,enabled=true}
  end
  return y+h
end

-- Compact navigation/actions and feedback are not record rows.
local function draw_bar(c,index,y,row)
  local right=M.WIDTH-PAD
  local left=PAD
  for n=#(row.actions or {}),1,-1 do
    local a=row.actions[n]
    local w=c.measure(a.label,SIZE_TAB)+BTN_PAD
    if a.align=='left' or a.label:match('^Back') then
      button(c,a.id,left,y+5,w,24,a.label,rgb(c,'dim'));left=left+w+GAP
    else
      right=right-w
      button(c,a.id,right,y+5,w,24,a.label,rgb(c,a.primary and 'accent' or 'bright'))
      right=right-GAP
    end
  end
  label(c,'bar_'..index,left,y+11,clip(c,row.title or '',right-left-4,SIZE_SUB),rgb(c,row.accent or 'dim'),SIZE_SUB)
  return y+36
end
-- Search and its contextual actions share one row. Its hit region is only the
-- input itself, so clicking Filters never captures keyboard focus by accident.
local function draw_finderbar(c,index,y,row)
  local right=M.WIDTH-PAD
  for n=#(row.actions or {}),1,-1 do
    local a=row.actions[n];local w=c.measure(a.label,SIZE_TAB)+BTN_PAD
    right=right-w;button(c,a.id,right,y+8,w,28,a.label,rgb(c,'bright'));right=right-GAP
  end
  local key='search_'..index
  local width=math.max(40,right-PAD)
  local edge=rgb(c,row.focused and 'accent' or 'line')
  rect(c,key,PAD,y+8,width,28,rgb(c,'panel'),210)
  rect(c,key..'t',PAD,y+8,width,1,edge)
  rect(c,key..'b',PAD,y+35,width,1,edge)
  rect(c,key..'l',PAD,y+8,1,28,edge)
  rect(c,key..'r',PAD+width-1,y+8,1,28,edge)
  local value=row.value or ''
  label(c,key,PAD+8,y+15,clip(c,value~='' and value or row.placeholder or 'Search',width-16,SIZE_SUB),rgb(c,value~='' and 'bright' or 'dim'),SIZE_SUB)
  if row.action_id then c.regions[#c.regions+1]={id=row.action_id,x=PAD,y=y+8,w=width,h=28,enabled=true,value=value} end
  return y+44
end
local function draw_actions(c,index,y,row)
  rect(c,'formline_'..index,PAD,y+4,M.WIDTH-PAD*2,1,rgb(c,'line'),160)
  label(c,'formtitle_'..index,PAD,y+12,clip(c,row.title or '',M.WIDTH-PAD*2,SIZE_SUB),rgb(c,'bright'),SIZE_SUB)
  label(c,'formhint_'..index,PAD,y+30,clip(c,row.subtitle or '',M.WIDTH-PAD*2,SIZE_FOOT),rgb(c,'dim'),SIZE_FOOT)
  draw_bar(c,'formbuttons_'..index,y+45,{actions=row.actions})
  return y+84
end

-- Shared dashboard primitives. Both loaders draw this same measured canvas.
function M.draw_surface(c,index,y,row)
  local key='surface_'..index
  local width=M.WIDTH-2*PAD
  if row.kind=='rolecounts' then
    local w=(width-GAP*4)/5
    for i,opt in ipairs(row.options or {}) do
      local x=PAD+(i-1)*(w+GAP)
      rect(c,key..i,x,y+2,w,80,rgb(c,'chrome'),170)
      icon(c,key..i,'role_'..opt.role:lower(),x+(w-26)/2,y+6,26,{255,255,255})
      label(c,key..i,x+(w-c.measure(opt.label,SIZE_FOOT))/2,y+35,opt.label,rgb(c,'bright'),SIZE_FOOT)
      button(c,'pf:count:'..opt.role..':-1',x+6,y+53,23,23,'-',rgb(c,'dim'))
      label(c,key..i..'count',x+(w-c.measure(opt.value,SIZE_SUB))/2,y+59,opt.value,rgb(c,'bright'),SIZE_SUB)
      button(c,'pf:count:'..opt.role..':1',x+w-29,y+53,23,23,'+',rgb(c,'accent'))
    end
  elseif row.kind=='columns' or row.kind=='record' then
    local x=PAD
    local cols=row.columns or {0.34,0.34,0.16,0.16}
    if row.kind=='record' then rect(c,key,PAD,y+2,width,56,rgb(c,'chrome'),index%2==0 and 140 or 70) end
    for i,fraction in ipairs(cols) do
      local w=width*fraction
      local cell=(row.cells or {})[i]
      if cell then
        if type(cell)=='string' then cell={text=cell} end
        local inset=8
        if i==1 and row.item_name then
          icon(c,key..'_item','art-coffer',x+6,y+12,28,{255,255,255});c.icons[#c.icons].item_name=row.item_name;inset=40
        end
        local size=(row.kind=='columns' or cell.small) and SIZE_FOOT or SIZE_SUB
        label(c,key..'_cell'..i,x+inset,y+8,clip(c,cell.text or '',w-inset-8,size),rgb(c,row.kind=='columns' and 'dim' or (cell.colour or 'bright')),size)
        if cell.subtext then label(c,key..'_sub'..i,x+8,y+30,clip(c,cell.subtext,w-16,SIZE_FOOT),rgb(c,'dim'),SIZE_FOOT) end
      end
      if i==#cols and row.action then
        button(c,row.action.id,x+4,y+6,w-8,23,clip(c,row.action.label,w-14,SIZE_FOOT),rgb(c,'accent'),SIZE_FOOT)
        if row.secondary_action then button(c,row.secondary_action.id,x+4,y+32,w-8,23,clip(c,row.secondary_action.label,w-14,SIZE_FOOT),rgb(c,'dim'),SIZE_FOOT) end
      end
      x=x+w
    end
    if row.kind=='columns' then rect(c,key..'_rule',PAD,y+26,width,1,rgb(c,'line'),160) end
  elseif row.kind=='pagehead' then
    local right=M.WIDTH-PAD
    local left=PAD
    for i=#(row.actions or {}),1,-1 do
      local a=row.actions[i];local w=c.measure(a.label,SIZE_TAB)+BTN_PAD
      if a.align=='left' or a.label:match('^Back') then
        button(c,a.id,left,y+9,w,26,a.label,rgb(c,'dim'));left=left+w+GAP
      else
        right=right-w;button(c,a.id,right,y+12,w,26,a.label,rgb(c,'accent'));right=right-GAP
      end
    end
    label(c,key,left,y+12,clip(c,row.title,right-left-6,SIZE_TITLE),rgb(c,'bright'),SIZE_TITLE)
    label(c,key..'_sub',PAD,y+39,clip(c,row.subtitle or '',width,SIZE_FOOT),rgb(c,'dim'),SIZE_FOOT)
  elseif row.kind=='metrics' or row.kind=='jobgrid' then
    local count=#row.items;local w=(width-GAP*(count-1))/math.max(1,count)
    for i,item in ipairs(row.items) do
      local x=PAD+(i-1)*(w+GAP);local id=key..'_'..i
      rect(c,id,x,y+4,w,M.row_height(row)-8,rgb(c,'chrome'),170)
      local art=item.icon or (item.art and ('art-'..item.art));local inset=art and 32 or 10
      if art then icon(c,id..'_art',art,x+8,y+8,20,{255,255,255}) end
      label(c,id..'_title',x+inset,y+11,clip(c,item.title,w-inset-10,SIZE_FOOT),rgb(c,'dim'),SIZE_FOOT)
      label(c,id..'_value',x+10,y+(row.kind=='jobgrid' and 25 or 29),clip(c,item.value or 'Not set',w-20,SIZE_SUB),rgb(c,'bright'),SIZE_SUB)
    end
  elseif row.kind=='cards' then
    local w=(width-GAP)/2
    for i,item in ipairs(row.items) do
      local x=PAD+(i-1)*(w+GAP);local id=key..'_'..i
      rect(c,id,x,y+4,w,76,rgb(c,'chrome'),150)
      local art=item.art or ART_TAGS[item.tag]
      if art then icon(c,id,'art-'..art,x+10,y+12,24,{255,255,255}) end
      local inset=art and 42 or 12
      label(c,id..'_title',x+inset,y+15,clip(c,item.title,w-inset-10,SIZE_ROW),rgb(c,'bright'),SIZE_ROW)
      local meta_width=item.meta and c.measure(item.meta,SIZE_FOOT)+8 or 0
      label(c,id..'_sub',x+12,y+36,clip(c,item.subtitle or '',w-24-meta_width,SIZE_FOOT),rgb(c,'dim'),SIZE_FOOT)
      if item.meta then label(c,id..'_meta',x+w-12-meta_width+8,y+36,item.meta,rgb(c,item.meta_colour or 'bright'),SIZE_FOOT) end
      if item.action then
        local bw=math.min(w-24,c.measure(item.action.label,SIZE_TAB)+BTN_PAD)
        button(c,item.action.id,x+12,y+52,bw,24,item.action.label,rgb(c,'accent'))
      end
    end
  elseif row.kind=='toggle' then
    local a=row.action;local x=M.WIDTH-PAD-62
    label(c,key,PAD,y+10,clip(c,row.title,x-PAD-12,SIZE_ROW),rgb(c,'bright'),SIZE_ROW)
    label(c,key..'_sub',PAD,y+31,clip(c,row.subtitle or '',x-PAD-12,SIZE_FOOT),rgb(c,'dim'),SIZE_FOOT)
    button(c,a.id,x,y+13,62,25,row.on and 'ON' or 'OFF',rgb(c,row.on and 'good' or 'dim'),nil,nil,row.on)
  elseif row.kind=='banner' then
    rect(c,key,PAD,y+4,width,60,rgb(c,'chrome'),170)
    rect(c,key..'_line',PAD,y+4,2,60,rgb(c,row.accent or 'accent'),210)
    local right=M.WIDTH-PAD-10
    if row.action then
      local w=c.measure(row.action.label,SIZE_TAB)+BTN_PAD;right=right-w
      button(c,row.action.id,right,y+21,w,25,row.action.label,rgb(c,'accent'));right=right-12
    end
    if row.secondary_action then
      local a=row.secondary_action;local w=c.measure(a.label,SIZE_TAB)+BTN_PAD;right=right-w
      button(c,a.id,right,y+21,w,25,a.label,rgb(c,'accent'));right=right-12
    end
    local left=PAD+12
    if row.art then icon(c,key..'_art','art-'..row.art,left,y+18,28,{255,255,255});left=left+36 end
    if row.role_icon then
      icon(c,key..'_role','role_'..row.role_icon:lower(),left,y+19,28,{255,255,255});left=left+36
    end
    label(c,key..'_title',left,y+14,clip(c,row.title,right-left,SIZE_ROW),rgb(c,'bright'),SIZE_ROW)
    label(c,key..'_sub',left,y+38,clip(c,row.subtitle or '',right-left,SIZE_FOOT),rgb(c,'dim'),SIZE_FOOT)
  end
  return y+M.row_height(row)
end

local function draw_option(c, index, y, row)
  local key = 'o' .. index
  local bx = PAD + 104
  local bw = M.WIDTH - PAD - bx
  local hovered = c.hover == row.action_id
  local on = row.selected == true
  rect(c, 'obg_' .. key, bx, y, bw, OPTION_H, rgb(c, (hovered or on) and 'hot' or 'chrome'), on and 200 or 150)
  if on then
    rect(c, 'omk_' .. key, bx, y, 2, OPTION_H, rgb(c, 'accent'))
  end
  label(c, 'ov_' .. key, bx + 12, y + 5, clip(c, tostring(row.title or ''), bw - 24, SIZE_SUB),
    rgb(c, (on or hovered) and 'bright' or 'dim'), SIZE_SUB)
  if row.action_id then
    c.regions[#c.regions + 1] = { id = row.action_id, x = bx, y = y, w = bw, h = OPTION_H, enabled = true }
  end
  return y + OPTION_H
end

--- A section label. Quiet, spaced, and never clickable: it exists to break a wall of rows into
--- parts a reader can skip between.
local function draw_header(c, index, y, row)
  label(c, 'h_' .. index, PAD, y + 8, tostring(row.title or ''):upper(), rgb(c, 'accent'), SIZE_FOOT)
  local tw = c.measure(tostring(row.title or ''):upper(), SIZE_FOOT)
  rect(c, 'hl_' .. index, PAD + tw + 10, y + 14, M.WIDTH - PAD * 2 - tw - 10, 1, rgb(c, 'line'), 110)
  return y + HEADER_H
end

--- A status pill. Short, filled, and the one thing on a row that should be readable from across
--- the screen: whether this character is linked is the question the window exists to answer.
local function draw_chip(c, id, x, y, text, colour)
  local w = c.measure(text, SIZE_FOOT) + 14
  rect(c, 'chip_' .. id, x - w, y, w, CHIP_H, rgb(c, colour), 200)
  label(c, 'chip_' .. id, x - w + 7, y + 3, text, rgb(c, 'panel'), SIZE_FOOT)
  return w
end

--- One listing row: a title line, a quieter second line, an optional right-hand figure, and an
--- optional action button.
local function draw_row(c, index, y, row)
  local key = 'r' .. index
  if index % 2 == 0 then
    rect(c, 'bg_' .. key, 0, y, M.WIDTH, ROW_H, rgb(c, 'chrome'), 90)
  end
  rect(c, 'tick_' .. key, 0, y + 4, 3, ROW_H - 8, rgb(c, row.accent or 'dim'))

  -- The RIGHT-HAND side is laid out first. Whatever is left over is what the text may use, which is
  -- the only way a row can promise its title will not run through the button beside it.
  local right = M.WIDTH - PAD
  if row.chip then
    right = right - draw_chip(c, key, right, y + math.floor((ROW_H - CHIP_H) / 2), row.chip, row.chip_colour or 'good') - 10
  end
  if row.action then
    local w = c.measure(row.action.label, SIZE_TAB) + BTN_PAD
    right = right - w
    button(c, row.action.id, right, y + math.floor((ROW_H - 24) / 2), w, 24, row.action.label, rgb(c, 'accent'))
    right = right - 12
  end
  if row.secondary_action then
    local a = row.secondary_action
    local w = c.measure(a.label, SIZE_TAB) + BTN_PAD
    right = right - w
    button(c, a.id, right, y + math.floor((ROW_H - 24) / 2), w, 24, a.label, rgb(c, 'accent'))
    right = right - 12
  end
  if row.meta then
    local w = c.measure(row.meta, SIZE_ROW)
    label(c, 'm_' .. key, right - w, y + 7, row.meta, rgb(c, row.meta_colour or 'bright'), SIZE_ROW)
    right = right - w - 10
  end

  local x = PAD
  if row.item_name then
    icon(c, key, 'art-coffer', x, y + math.floor((ROW_H - 28) / 2), 28, { 255, 255, 255 })
    c.icons[#c.icons].item_name = row.item_name
    x = x + 38
    if row.tag == 'CONFIRM' then
      x = x + tag(c, key, x, y + math.floor((ROW_H - 18) / 2), row.tag, row.accent or 'dim') + 10
    end
  elseif row.role_icon then
    local role=({ANY='any',TANK='tank',HEALER='healer',SUPPORT='support',DPS='dps'})[row.role_icon] or 'any'
    icon(c,key,'role_'..role,x,y+math.floor((ROW_H-28)/2),28,{255,255,255})
    x=x+38
  elseif row.art then
    local size = row.art_size or 28
    icon(c, key, 'art-' .. row.art, x, y + math.floor((ROW_H - size) / 2), size, {255,255,255})
    x = x + size + 10
    if row.tag then
      x = x + tag(c, key, x, y + math.floor((ROW_H - 18) / 2), row.tag, row.accent or 'dim') + 10
    end
  elseif row.tag then
    local art = ART_TAGS[row.tag]
    if art then
      icon(c, key, 'art-' .. art, x, y + math.floor((ROW_H - 28) / 2), 28, { 255, 255, 255 })
      x = x + 38
    else
      x = x + tag(c, key, x, y + math.floor((ROW_H - 18) / 2), row.tag, row.accent or 'dim') + 10
    end
  end
  local text_left = x
  local available = right - x

  local title = clip(c, row.title, available, SIZE_ROW)
  label(c, 'a_' .. key, x, y + 9, title, rgb(c, 'bright'), SIZE_ROW)
  if row.badge then
    local bx = x + c.measure(title, SIZE_ROW) + 10
    label(c, 'b_' .. key, bx, y + 10, clip(c, row.badge, right - bx, SIZE_SUB), rgb(c, row.badge_colour or 'info'), SIZE_SUB)
  end
  if row.subtitle and row.subtitle ~= '' then
    label(c, 'c_' .. key, text_left, y + 29, clip(c, row.subtitle, available, SIZE_SUB), rgb(c, 'dim'), SIZE_SUB)
  end
  return y + ROW_H
end

local function draw_footer(c, y, state)
  rect(c, 'footline', 0, y, M.WIDTH, 1, rgb(c, 'line'), 140)
  rect(c, 'footer', 0, y + 1, M.WIDTH, FOOT_H - 1, rgb(c, 'chrome'))

  -- Identity, and only identity. The character you are on, and what it is connected to: an
  -- IngestKey belongs to ONE linkshell, so a member of two has to see without asking which one is
  -- about to receive their attendance.
  local left = state.jobs or ''
  if state.tier == 'member' and state.shell then
    left = left .. '   ' .. state.shell
    if state.dkp then
      left = left .. '   DKP ' .. tostring(state.dkp)
    end
  else
    left = left .. '   not linked'
  end

  local ty = y + math.floor((FOOT_H - SIZE_FOOT - 4) / 2)
  local right = tostring(state.count_label or '')
  if state.surface_layout then left=state.tier=='member' and 'Linked' or 'Not linked' end
  left=clip(c,left,M.WIDTH-PAD*2-c.measure(right,SIZE_FOOT)-16,SIZE_FOOT)
  label(c, 'foot', PAD, ty, left, rgb(c, 'dim'), SIZE_FOOT)
  right=clip(c,right,M.WIDTH-PAD*2-c.measure(left,SIZE_FOOT)-16,SIZE_FOOT)
  label(c, 'footr', M.WIDTH - PAD - c.measure(right, SIZE_FOOT), ty, right, rgb(c, 'accent'), SIZE_FOOT)
end

--[[
  Build the whole window.

  `state.rows` is the already-resolved list for the active tab; deciding WHAT is in a tab belongs to
  the caller, which has the data. This module decides the shape: where things sit, what is
  clickable, and what the chrome says.
]]
--[[
  How tall the window may get, in body rows, when nobody says otherwise.

  The window used to size itself to its content and let the renderer shove it back on screen, so
  opening a list, or a suggestion dropdown, JUMPED the whole panel upward under the pointer: the
  thing you were about to click moved before you clicked it. Content is trimmed to the room
  available instead, and the window stays where you put it.
]]
M.MAX_ROWS = 12

--- How tall a row draws. One place, so the trim pass and the draw pass cannot disagree about it;
--- when they did, the window trimmed for one height and drew at another.
function M.row_height(row)
  local kind = type(row) == 'table' and row.kind or nil
  if kind=='text' then return 23
  elseif kind=='record' then return 60
  elseif kind=='columns' then return 28
  elseif kind=='pagehead' then return 56
  elseif kind=='cards' then return 80
  elseif kind=='metrics' then return 60
  elseif kind=='jobgrid' then return 44
  elseif kind=='rolecounts' then return 84
  elseif kind=='banner' then return 68
  elseif kind=='toggle' then return 54
  elseif kind == 'choices' then
    return row.compact and 40 or 76
  elseif kind == 'finderbar' then return 44
  elseif kind == 'filterchips' then return 36
  elseif kind == 'toolbar' then
    return 36
  elseif kind == 'actions' then
    return 84
  elseif kind == 'header' then
    return HEADER_H
  elseif kind == 'option' then
    return OPTION_H
  elseif kind == 'select' or kind == 'field' then
    return FORM_H
  end
  return ROW_H
end

function M.build(state, measure, room)
  state = type(state) == 'table' and state or {}
  room = math.min(tonumber(room) or 680, state.surface_layout and M.MIN_HEIGHT or 680)
  local theme = M.theme(state.theme)
  local c = canvas_for(theme, measure, state.hover)

  local counts = state.counts or {}
  local tabs = M.tabs_for(state.tier, counts)
  local active = M.resolve_tab(state.tier, state.tab, counts)
  local rows = type(state.rows) == 'table' and state.rows or {}
  c.action_variants={}
  local normalized={}
  for _,row in ipairs(rows) do
    local function action(a)
      if a then c.action_variants[a.id]=a.variant or (a.primary and 'primary') or 'secondary' end
    end
    action(row.action);action(row.secondary_action)
    for _,a in ipairs(row.actions or {}) do action(a) end
    for _,item in ipairs(row.items or {}) do action(item.action) end
    if row.kind=='text' then
      local text=tostring(row.text or row.title or ''):gsub('\r','')
      for paragraph in (text..'\n'):gmatch('(.-)\n') do
        repeat
          local low,high,take=1,#paragraph,0
          while low<=high do
            local mid=math.floor((low+high)/2)
            if c.measure(paragraph:sub(1,mid),SIZE_SUB)<=M.WIDTH-PAD*2-12 then take=mid;low=mid+1 else high=mid-1 end
          end
          take=math.max(1,take)
          if take<#paragraph then
            local word=paragraph:sub(1,take):match('^.*()%s')
            if word and word>1 then take=word end
          end
          normalized[#normalized+1]={kind='text',text=paragraph:sub(1,take),accent=row.accent}
          paragraph=paragraph:sub(take+1)
        until #paragraph==0
      end
    else normalized[#normalized+1]=row end
  end
  rows=normalized
  local footer=nil
  if #rows>0 and (rows[#rows].kind=='actions' or rows[#rows].dock) then
    footer=rows[#rows];local body={}
    for i=1,#rows-1 do body[i]=rows[i] end
    rows=body
  end

  -- Height depends on how many lines the tab strip wrapped onto, so the strip is laid out first,
  -- into a throwaway canvas, and the real pass repeats it once the panel rectangle can be sized.
  local probe = canvas_for(theme, c.measure, nil)
  local chrome_top=TITLE_H+(state.surface_layout and 0 or STATUS_H)
  local footer_h=footer and M.row_height(footer) or 0
  local body_top = draw_navigation(probe, state, active, chrome_top)
  -- Trim to what fits. `room` is the pixels the renderer actually has below the window's top edge;
  -- without one, a sane default so the model stays testable on its own.
  local budget = (tonumber(room) or (body_top + M.MAX_ROWS * ROW_H + FOOT_H)) - body_top - FOOT_H - footer_h

  --[[
    Split into pages rather than throwing the tail away.

    A trimmed row used to be gone: the list said "+N more" and the only way to reach item eleven was
    a chat command. That is tolerable for a read-only list and not for one with a BUTTON on every
    row, which the wishlist is; a member with twelve items could not click Remove on the last four.

    Pages are computed by walking the rows and filling the budget over and over, so nothing has to
    remember an offset and a row that changes height cannot desynchronise a stored one. One row of
    footer is reserved for the pager, and only when there is more than one page: a list that fits
    keeps every pixel it had.
  ]]
  -- The leading task controls stay visible while only the records paginate.
  local prefix, body, prefix_h={}, {}, 0
  local leading=true
  for _,row in ipairs(rows) do
    local persistent=leading and (row.kind=='pagehead' or row.kind=='toolbar' or row.kind=='field' or row.kind=='choices' or row.kind=='select' or row.kind=='finderbar' or row.kind=='filterchips')
    if persistent and prefix_h+M.row_height(row)<budget-ROW_H*2 then
      prefix[#prefix+1]=row;prefix_h=prefix_h+M.row_height(row)
    else leading=false;body[#body+1]=row end
  end
  rows=body
  local pages, current, body_h = {}, {}, 0
  local total_h=prefix_h
  for _,row in ipairs(rows) do total_h=total_h+M.row_height(row) end
  local pager_h=total_h>budget and ROW_H or 0
  local context=nil
  for index, row in ipairs(rows) do
    local h = M.row_height(row)
    local next_h=(row.kind=='header' or row.kind=='columns') and rows[index+1] and M.row_height(rows[index+1]) or 0
    if #current > 0 and body_h + h + next_h + pager_h + prefix_h > budget then
      pages[#pages + 1] = current
      current, body_h = {}, 0
      if context and row.kind~='header' and row.kind~='columns' and prefix_h+M.row_height(context)+h+pager_h<=budget then
        current[1]=context;body_h=M.row_height(context)
      end
    end
    current[#current + 1] = row
    body_h = body_h + h
    if row.kind=='header' or row.kind=='columns' then context=row end
  end
  if #current > 0 or #prefix>0 then pages[#pages + 1] = current end

  -- A page number out of range lands on the first page rather than an empty screen: the list can
  -- shrink under a stored page (an item removed, a static filled), and an empty window with no way
  -- back would be the worst possible answer to "your list got shorter".
  local page_count = #pages
  c.page_count=page_count
  local page = math.floor(tonumber(state.page) or 1)
  if page_count == 0 or page < 1 or page > page_count then
    page = 1
  end
  local shown_rows = {}
  for _,row in ipairs(prefix) do shown_rows[#shown_rows+1]=row end
  for _,row in ipairs(pages[page] or {}) do shown_rows[#shown_rows+1]=row end
  body_h = 0
  for _, row in ipairs(shown_rows) do
    body_h = body_h + M.row_height(row)
  end

  if page_count > 1 then
    local copy = {}
    for index, row in ipairs(shown_rows) do
      copy[index] = row
    end
    -- Wraps. One control instead of a Prev and a Next, and no dead end on the last page.
    copy[#copy + 1] = {
      title = 'Page ' .. tostring(page) .. ' of ' .. tostring(page_count),
      subtitle = '',
      accent = 'dim',
      action = { id = 'page:' .. tostring(page < page_count and page + 1 or 1), label = page < page_count and 'Next' or 'First' },
      secondary_action = page > 1 and {id='page:' .. tostring(page-1), label='Previous'} or nil,
    }
    shown_rows = copy
    body_h = body_h + ROW_H
  end
  rows = shown_rows
  c.page=page
  if #rows == 0 then
    body_h = ROW_H
  end
  -- Home grows with its attention items; a quiet dashboard should not reserve an empty page.
  local fit_content=false;for _,row in ipairs(rows) do if row.fit_content then fit_content=true end end
  local minimum=fit_content and 0 or state.surface_layout and active=='home' and footer and footer.kind=='cards' and 0 or M.MIN_HEIGHT
  local height = math.max(body_top + body_h + FOOT_H + footer_h, math.min(minimum, tonumber(room) or minimum))

  rect(c, 'panel', 0, 0, M.WIDTH, height, theme.panel, theme.panel_alpha or 230)
  rect(c, 'edge_t', 0, 0, M.WIDTH, 1, rgb(c, 'line'), 190)
  rect(c, 'edge_b', 0, height - 1, M.WIDTH, 1, rgb(c, 'line'), 190)
  rect(c, 'edge_l', 0, 0, 1, height, rgb(c, 'line'), 190)
  rect(c, 'edge_r', M.WIDTH - 1, 0, 1, height, rgb(c, 'line'), 190)

  draw_title(c,state)
  if not state.surface_layout then draw_status(c, state) end
  local y = draw_navigation(c, state, active, chrome_top)

  if #rows == 0 then
    label(c, 'empty', PAD, y + 14, state.empty or 'Nothing here right now.', rgb(c, 'dim'), SIZE_SUB)
    y = y + ROW_H
  else
    for index, row in ipairs(rows) do
      if row.kind=='record' or row.kind=='columns' or row.kind=='pagehead' or row.kind=='cards' or row.kind=='metrics' or row.kind=='jobgrid' or row.kind=='banner' or row.kind=='toggle' or row.kind=='rolecounts' then
        y=M.draw_surface(c,index,y,row)
      elseif row.kind == 'text' then
        label(c,'text_'..index,PAD+6,y+4,row.text or '',rgb(c,row.accent or 'dim'),SIZE_SUB);y=y+23
      elseif row.kind == 'finderbar' then
        y=draw_finderbar(c,index,y,row)
      elseif row.kind == 'toolbar' or row.kind=='filterchips' then
        y=draw_bar(c,index,y,row)
      elseif row.kind == 'choices' then
        y = draw_choices(c,index,y,row)
      elseif row.kind == 'field' then
        y = draw_field(c, index, y, row)
      elseif row.kind == 'select' then
        y = draw_select(c, index, y, row)
      elseif row.kind == 'option' then
        y = draw_option(c, index, y, row)
      elseif row.kind == 'header' then
        y = draw_header(c, index, y, row)
      else
        y = draw_row(c, index, y, row)
      end
    end
  end

  if footer then
    if footer.kind=='actions' then draw_actions(c,'fixed',height-FOOT_H-footer_h,footer)
    elseif footer.kind=='cards' then M.draw_surface(c,'fixed',height-FOOT_H-footer_h,footer)
    else draw_bar(c,'fixed',height-FOOT_H-footer_h,footer) end
  end
  draw_footer(c, height - FOOT_H, state)

  c.width = M.WIDTH
  c.height = height
  c.tab = active
  return c
end

--[[
  Which region a click landed in, or nil.

  Panel-relative; the caller subtracts the window origin first. Walks BACKWARDS so a control drawn
  later (and therefore on top) wins an overlap, which is what a player expects from something that
  looks layered. A disabled region is skipped rather than swallowing the click.
]]
function M.hit(canvas, x, y)
  if type(canvas) ~= 'table' or type(canvas.regions) ~= 'table' then
    return nil
  end
  for index = #canvas.regions, 1, -1 do
    local r = canvas.regions[index]
    if r.enabled and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
      return r.id
    end
  end
  return nil
end

--- True when the point is inside the window at all, so the renderer knows to consume the click
--- rather than letting it fall through to the game.
function M.contains(canvas, x, y)
  return type(canvas) == 'table' and x >= 0 and y >= 0 and x < (canvas.width or 0) and y < (canvas.height or 0)
end

--- The title bar is the drag handle, minus the icon buttons sitting in it.
function M.is_drag_handle(canvas, x, y)
  return M.contains(canvas, x, y) and y < TITLE_H and M.hit(canvas, x, y) == nil
end

M.TITLE_H = TITLE_H
M.HEADER_H = HEADER_H
M.ROW_H = ROW_H

return M
