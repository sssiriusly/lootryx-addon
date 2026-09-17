--[[
  Lootryx addon · the Windower RENDERER for lib/window.lua's model.

  This is the only file that knows how a rectangle reaches the screen. It takes the plain
  description lib/window.lua produces and draws it with Windower's own primitives and text
  objects, then routes mouse events back through the model's hit regions.

  Everything interesting about the window (layout, tabs, what is clickable, every string) lives in
  the model and is tested without a game. This file is deliberately dull, because it is the half
  that has to be written again for Ashita, where ImGui replaces primitives entirely.

  Two Windower facts shape the code below:

  1. Primitives and text objects are RETAINED. Creating one per frame would leak; destroying and
     recreating them would flicker. So they are pooled by id, reused across rebuilds, and simply
     hidden when a rebuild stops mentioning them. That lets the model above be written in the
     immediate style (just describe the whole window each time) without paying for it.
  2. A mouse click reaches the game unless the handler returns true. A stray click that falls
     through while you are fighting is exactly what nobody wants, so anything landing inside the
     panel is consumed. Nothing here is ever sent to the game server: consuming a click is the
     opposite of injecting one.
]]

local texts = require('texts')

local P = {}

-- The model module, injected rather than required: lootryx.lua loads every lib with loadfile() so
-- the addon works regardless of package.path, and this file must follow the same rule.
local window = nil
local rebuild = nil
local moved = nil

--- `model` is lib/window.lua. `rebuild_fn` returns a freshly built canvas, and is called when the
--- hovered control changes so the pointer can light one up. Optional: without it the window simply
--- never shows a hover state, rather than failing.
function P.bind(model, rebuild_fn, moved_fn)
  window = model
  rebuild = rebuild_fn
  moved = moved_fn
end

local hovered = nil

--- Which control the pointer is over, for the model to draw differently. Read during a rebuild.
function P.hover()
  return hovered
end

local prims, labels = {}, {}
local serial = 0
local shown = false
local canvas = nil
-- Starts near the top of the screen. It was 120px down, which is a lot of room to give away on a
-- 720p client, where the difference decides whether a full tab fits without trimming.
local origin = { x = 40, y = 60 }
local drag = nil
local pressed = nil

local FONT = {
  font = 'Consolas',
  size = 10,
  alpha = 255,
  red = 255,
  green = 255,
  blue = 255,
  stroke = { width = 1, alpha = 200, red = 0, green = 0, blue = 0 },
}

-- Fully transparent and invisible, both: `visible = false` alone still reserved the padding, which
-- left every label offset from where the model placed it.
local NO_BACKGROUND = { alpha = 0, red = 0, green = 0, blue = 0, visible = false }

local function screen_size()
  local ok, settings = pcall(windower.get_windower_settings)
  if ok and settings then
    return settings.ui_x_res or 1280, settings.ui_y_res or 720
  end
  return 1280, 720
end

--- Keep the window on screen. A panel dragged off the edge, or left behind by a resolution change,
--- is a window the player cannot get back without editing settings by hand.
--- How much vertical room the window has from its own top edge to the bottom of the screen. The
--- model trims its rows to this rather than growing and being shoved back up.
local function room()
  local _, h = screen_size()
  return math.max(200, h - origin.y - 8)
end

local function clamp()
  local w, h = screen_size()
  local width = canvas and canvas.width or 466
  local height = canvas and canvas.height or 200
  origin.x = math.max(0, math.min(origin.x, w - width))
  -- Only ever pushes the window back on screen when it is genuinely off it. The window is sized to
  -- the room it has, so this no longer fights a growing body for position.
  origin.y = math.max(0, math.min(origin.y, math.max(0, h - math.min(height, h))))
end

local function prim_for(id)
  local entry = prims[id]
  if not entry then
    serial = serial + 1
    entry = { name = 'lootryx_panel_' .. serial }
    prims[id] = entry
    windower.prim.create(entry.name)
  end
  return entry
end

--[[
  Real font metrics.

  The model asks how wide a string will be so it can lay tabs and buttons out; the first version
  guessed from character counts and the tabs visibly overlapped in game. A single hidden text
  object, kept off screen, answers properly through Windower's own extents. Results are cached
  because a rebuild asks about the same handful of strings repeatedly, and creating a text object
  per measurement would be far more expensive than the layout itself.
]]
local measure_obj = nil
local measure_cache = {}
local measure_keys, measure_next = {}, 1

--- The vertical room the window has, for the model to trim its rows to.
function P.room()
  return room()
end

function P.measure(text, size)
  text = tostring(text or '')
  size = size or 10
  local key = size .. ':' .. text
  local hit = measure_cache[key]
  if hit then
    return hit
  end
  if not measure_obj then
    measure_obj = texts.new('', { flags = { draggable = false }, text = FONT, bg = NO_BACKGROUND, padding = 0 })
    measure_obj:hide()
  end
  local width
  local ok = pcall(function()
    measure_obj:size(size)
    measure_obj:text(text)
    width = measure_obj:extents()
  end)
  -- A width under half the fallback is not a measurement, it is a text object that has never been
  -- drawn reporting nothing. Treated as a failure so the estimate takes over, rather than
  -- collapsing the column to nothing.
  local estimate = math.floor(#text * size * 0.78) + 10
  if not ok or type(width) ~= 'number' or width < estimate * 0.5 then
    -- Extents can come back empty before the object has ever been drawn. Falling back to an
    -- estimate keeps the window usable rather than collapsing every column to zero width.
    width = math.floor(#text * size * 0.78) + 10
  end
  -- Countdown values and edited text are effectively unlimited. Keep a bounded FIFO
  -- of font measurements while retaining the common labels between redraws.
  local expired = measure_keys[measure_next]
  if expired then measure_cache[expired] = nil end
  measure_keys[measure_next] = key
  measure_next = measure_next % 512 + 1
  measure_cache[key] = width
  return width
end

local function label_for(id)
  local entry = labels[id]
  if not entry then
    entry = {
      obj = texts.new('', { flags = { draggable = false }, text = FONT, bg = NO_BACKGROUND, padding = 0 }),
    }
    labels[id] = entry
  end
  return entry
end

--[[
  A pointer of our own, shown only while the mouse is over the window.

  Windower draws its overlay ON TOP of everything the game draws, including the game's mouse cursor.
  A small window gets away with that; this one is 700px wide and sits near the top of the screen,
  so the cursor vanishes underneath exactly the thing it is trying to click. The window is unusable
  if you cannot see where you are pointing.

  It is a TEXT object rather than a primitive on purpose: texts render above prims, so this cannot
  end up underneath a row that was created after it. It is hidden the moment the pointer leaves the
  window, so the real cursor is what you see everywhere else and there are never two on screen.
]]
local cursor_obj = nil
local cursor_shown = false

local function cursor()
  if not cursor_obj then
    cursor_obj = texts.new('', { flags = { draggable = false }, text = FONT, bg = NO_BACKGROUND, padding = 0 })
  end
  return cursor_obj
end

local function hide_cursor()
  if cursor_shown and cursor_obj then
    cursor_obj:hide()
    cursor_shown = false
  end
end

--- Put the pointer at a screen position, or take it away when `inside` is false.
local cursor_x, cursor_y = nil, nil

local function move_cursor(inside, mx, my, theme)
  if not inside or not shown then
    hide_cursor()
    return
  end
  local obj = cursor()
  if not cursor_shown then
    -- The glyph, its size and its colour are set once, when it appears. Windower delivers a lot of
    -- mouse-move events, and re-sending all four properties on each of them is the difference
    -- between a pointer that follows smoothly and one that stutters.
    obj:text('+')
    obj:size(14)
    local colour = (theme and theme.bright) or { 235, 235, 235 }
    obj:color(colour[1], colour[2], colour[3])
    obj:show()
    cursor_shown = true
    cursor_x, cursor_y = nil, nil
  end
  -- Offset so the glyph's centre, not its top-left, sits under the real pointer.
  local px, py = mx - 4, my - 9
  if cursor_x ~= px or cursor_y ~= py then
    cursor_x, cursor_y = px, py
    obj:pos(px, py)
  end
end

--- Draw one built canvas. Everything it does not mention is hidden rather than destroyed, which is
--- what makes rebuilding the whole window on every change cheap enough to do freely.
function P.draw(built)
  if P.pointer_alignment and P.pointer_alignment.stage then
    hide_cursor()
    local a=P.pointer_alignment;local target=a.target();local colour=built.theme.bright
    built={width=620,height=460,theme=built.theme,icons={},regions={{id='pointer:sample',x=target[1]-12,y=target[2]-12,w=25,h=25,enabled=true}},rects={
      {id='align_x',x=target[1]-12,y=target[2],w=25,h=1,colour=colour,alpha=255},
      {id='align_y',x=target[1],y=target[2]-12,w=1,h=25,colour=colour,alpha=255}},labels={
      {id='align_title',x=20,y=15,text='Pointer alignment: '..a.stage..' of 3',size=13,colour=colour},
      {id='align_help',x=20,y=42,text='Click the cross centre with your GAME cursor.',size=10,colour=colour},
      {id='align_cancel',x=20,y=64,text='Right-click to cancel. '..a.message,size=10,colour=colour}}}
  end
  canvas = built
  clamp()
  for _, entry in pairs(prims) do
    entry.used = false
  end
  for _, entry in pairs(labels) do
    entry.used = false
  end

--[[
    Every property is compared before it is set.

    The window rebuilds in full on every change, which is what keeps the model simple: there is one
    path, and it always produces the whole screen. The cost was that a keystroke in a text box
    re-issued every position, size, colour and visibility call for every rectangle and every label,
    several hundred Windower calls to redraw a screen where one word had changed. Typing felt
    heavy for that reason and no other.

    Comparing first is enough to fix it because almost nothing does change between two frames: the
    chrome, the tabs, the rows above and below are identical, and only the characters under the
    caret differ.
  ]]
  for _, r in ipairs(built.rects) do
    local entry = prim_for(r.id)
    entry.used = true
    local px, py = origin.x + r.x, origin.y + r.y
    if entry.x ~= px or entry.y ~= py then
      entry.x, entry.y = px, py
      windower.prim.set_position(entry.name, px, py)
    end
    if entry.w ~= r.w or entry.h ~= r.h then
      entry.w, entry.h = r.w, r.h
      windower.prim.set_size(entry.name, r.w, r.h)
    end
    local cr, cg, cb = r.colour[1], r.colour[2], r.colour[3]
    if entry.alpha ~= r.alpha or entry.r ~= cr or entry.g ~= cg or entry.b ~= cb then
      entry.alpha, entry.r, entry.g, entry.b = r.alpha, cr, cg, cb
      windower.prim.set_color(entry.name, r.alpha, cr, cg, cb)
    end
    if entry.visible ~= shown then
      entry.visible = shown
      windower.prim.set_visibility(entry.name, shown)
    end
  end

  for _, ico in ipairs(built.icons or {}) do
    local entry = prim_for('icon_' .. ico.id)
    entry.used = true
    local texture = (ico.item_name and P.item_icons and P.item_icons.get(ico.item_name))
      or (windower.addon_path .. 'assets/' .. ico.name .. '.png')
    if entry.texture ~= texture then
      -- set_texture is the expensive call, so it is made only when the picture actually changes;
      -- position, size and tint are cheap and reapplied every draw.
      -- Texture completion must not replace the model's explicit dimensions.
      windower.prim.set_fit_to_texture(entry.name, false)
      windower.prim.set_texture(entry.name, texture)
      entry.texture = texture
    end
    local px,py=origin.x+ico.x,origin.y+ico.y
    if entry.x~=px or entry.y~=py then
      entry.x,entry.y=px,py
      windower.prim.set_position(entry.name,px,py)
    end
    windower.prim.set_size(entry.name, ico.size, ico.size)
    local cr,cg,cb=ico.colour[1],ico.colour[2],ico.colour[3]
    if entry.alpha~=ico.alpha or entry.r~=cr or entry.g~=cg or entry.b~=cb then
      entry.alpha,entry.r,entry.g,entry.b=ico.alpha,cr,cg,cb
      windower.prim.set_color(entry.name,ico.alpha,cr,cg,cb)
    end
    -- Cleanup consults this cache. A reused icon must be recorded as visible
    -- again, or its next removal is skipped and it stays at its old position.
    if entry.visible ~= shown then
      entry.visible = shown
      windower.prim.set_visibility(entry.name, shown)
    end
  end

  for _, l in ipairs(built.labels) do
    local entry = label_for(l.id)
    entry.used = true
    local obj = entry.obj
    if entry.text ~= l.text then
      entry.text = l.text
      obj:text(l.text)
    end
    if entry.size ~= l.size then
      entry.size = l.size
      obj:size(l.size)
    end
    local stroke = built.theme.text_stroke or 130
    if entry.stroke ~= stroke then
      entry.stroke = stroke
      obj:stroke_alpha(stroke)
    end
    local cr, cg, cb = l.colour[1], l.colour[2], l.colour[3]
    if entry.r ~= cr or entry.g ~= cg or entry.b ~= cb then
      entry.r, entry.g, entry.b = cr, cg, cb
      obj:color(cr, cg, cb)
    end
    local px, py = origin.x + l.x, origin.y + l.y
    if entry.x ~= px or entry.y ~= py then
      entry.x, entry.y = px, py
      obj:pos(px, py)
    end
    if entry.visible ~= shown then
      entry.visible = shown
      if shown then
        obj:show()
      else
        obj:hide()
      end
    end
  end

  for _, entry in pairs(prims) do
    if not entry.used and entry.visible ~= false then
      entry.visible = false
      windower.prim.set_visibility(entry.name, false)
    end
  end
  for _, entry in pairs(labels) do
    if not entry.used and entry.visible ~= false then
      entry.visible = false
      entry.obj:hide()
    end
  end
end

function P.visible()
  return shown
end

--- The clickable regions of what is currently drawn, in panel-relative coordinates, plus the
--- window origin. The renderer already owns the hit-test surface; exposing it lets a caller ask
--- WHERE a control is rather than assuming, which is the difference between a test that survives a
--- layout change and one that pins pixel positions.
function P.regions()
  local out = {}
  for _, r in ipairs((canvas and canvas.regions) or {}) do
    out[#out + 1] = {
      id = r.id,
      x = origin.x + r.x + math.floor(r.w / 2),
      y = origin.y + r.y + math.floor(r.h / 2),
      w = r.w,
      h = r.h,
    }
  end
  return out
end

function P.show(value)
  shown = value ~= false
  if not shown then
    drag, pressed, hovered = nil, nil, nil
    if P.pointer_alignment then P.pointer_alignment.cancel() end
    -- Straight away, not on the next mouse move: a closed window must not leave a pointer behind.
    hide_cursor()
  end
  if canvas then
    P.draw(canvas)
  end
end

function P.toggle()
  P.show(not shown)
  return shown
end

function P.position()
  return origin.x, origin.y
end

function P.set_position(x, y)
  origin.x, origin.y = tonumber(x) or origin.x, tonumber(y) or origin.y
  clamp()
  if canvas then
    P.draw(canvas)
  end
end

--- Free everything. Primitives outlive the addon unless deleted, so unload must be thorough or a
--- reload leaves ghost rectangles on screen.
function P.destroy()
  hide_cursor()
  if cursor_obj then
    cursor_obj:destroy()
    cursor_obj = nil
  end
  for _, entry in pairs(prims) do
    windower.prim.delete(entry.name)
  end
  for _, entry in pairs(labels) do
    entry.obj:destroy()
  end
  if measure_obj then
    measure_obj:destroy()
    measure_obj = nil
  end
  prims, labels, canvas, drag, pressed = {}, {}, nil, nil, nil
  measure_cache = {}
  measure_keys, measure_next = {}, 1
  shown = false
end

--[[
  Route a Windower mouse event.

  `kind` 0 is movement, 1 is left-button down, 2 is left-button up. Returns true when the event was
  ours, which stops it reaching the game.

  A button fires on RELEASE over the same control it was pressed on, not on press. That is what
  makes a misclick recoverable: press, notice, slide off, let go, nothing happens. Firing on press
  would make every accidental click final, which matters when the buttons place DKP bids.
]]
function P.mouse(kind, mx, my, on_action, delta)
  if not shown or not canvas or not window then
    return false
  end
  if P.pointer_alignment and P.pointer_alignment.stage then
    hide_cursor()
    -- FFXI needs real movement events to show and move its own cursor during alignment.
    -- Only clicks are captured here; drawing our corrected cursor would bias calibration.
    if kind==0 then return false end
    if kind==4 then P.pointer_alignment.cancel();pressed=nil
    elseif kind==1 then pressed='alignment'
    elseif kind==2 and pressed=='alignment' then P.pointer_alignment.click(mx,my,origin.x,origin.y);pressed=nil
    else return true end
    if rebuild then P.draw(rebuild()) end
    return true
  end
  if P.pointer_coordinates then mx,my=P.pointer_coordinates(mx,my) end
  local x, y = mx - origin.x, my - origin.y
  if kind==10 and window.contains(canvas,x,y) then
    local step=(tonumber(delta) or 0)>0 and -1 or 1
    local page=math.max(1,math.min(canvas.page_count or 1,(canvas.page or 1)+step))
    if delta and delta~=0 and page~=(canvas.page or 1) and on_action then on_action('page:'..page) end
    return true
  end

  -- The pointer follows every movement, which is cheap: it repositions one text object and never
  -- rebuilds the window.
  if kind == 0 then
    move_cursor(window.contains(canvas, x, y), mx, my, canvas.theme)
  end

  -- Hover, recomputed on movement only, and redrawn ONLY when the answer changes. Rebuilding on
  -- every mouse event would redraw the whole window many times a second for no visible difference.
  if kind == 0 and not drag then
    local over = window.hit(canvas, x, y)
    if over ~= hovered then
      hovered = over
      if rebuild then
        local ok, built = pcall(rebuild)
        if ok and built then
          P.draw(built)
        end
      end
    end
  end

  if drag then
    if kind == 0 then
      origin.x, origin.y = mx - drag.x, my - drag.y
      P.draw(canvas)
      return true
    end
    if kind == 2 then
      drag = nil
      if moved then moved(origin.x, origin.y) end
      return true
    end
  end

  if kind == 1 then
    local id = window.hit(canvas, x, y)
    if id then
      pressed = id
      return true
    end
    if window.is_drag_handle(canvas, x, y) then
      drag = { x = x, y = y }
      return true
    end
    -- Inside the panel but not on anything: still ours, so the click does not reach the game.
    return window.contains(canvas, x, y)
  end

  if kind == 2 then
    local id = window.hit(canvas, x, y)
    local was = pressed
    pressed = nil
    if was and id == was then
      if type(on_action) == 'function' then
        on_action(was)
      end
      return true
    end
    return window.contains(canvas, x, y)
  end

  return window.contains(canvas, x, y)
end

return P
