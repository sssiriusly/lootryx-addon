-- ImGui renderer for the same window canvas used by Windower.
-- Injected ImGui and texture lookup keep loader calls out of layout/action policy.
local M = {}
function M.new(imgui, texture, format_text)
  format_text = format_text or tostring
  local P = {}
  local model, rebuild, moved, canvas
  local shown, ready = false, false
  local pointer_x, pointer_y
  local ox, oy, hovered, pressed, drag = 40, 60, nil, nil, nil
  local function screen()
    local ok, io = pcall(imgui.GetIO)
    if ok and io and io.DisplaySize then
      local d = io.DisplaySize
      return d.x or d[1] or 1280, d.y or d[2] or 720
    end
    return 1280, 720
  end
  local function clamp()
    local w, h = screen()
    ox = math.max(0, math.min(ox, w - (canvas and canvas.width or 466)))
    oy = math.max(0, math.min(oy, h - math.min(canvas and canvas.height or 200, h)))
  end
  local function colour(c, a)
    return c[1] + c[2] * 256 + c[3] * 65536 + (a or 255) * 16777216
  end
  local function refresh()
    if rebuild then local built = rebuild(); if built then P.draw(built) end end
  end
  function P.bind(value, rebuild_fn, moved_fn) model, rebuild, moved = value, rebuild_fn, moved_fn end
  function P.hover() return hovered end
  function P.position() return ox, oy end
  function P.room() local _, h = screen(); return math.max(200, h - oy - 8) end
  function P.visible() return shown end
  function P.measure(text, size)
    local pixels = (size or 10) * 4 / 3
    local ok, width = pcall(function()
      local measured = imgui.CalcTextSize(format_text(text or ''))
      return (measured.x or measured[1]) * pixels / imgui.GetFontSize()
    end)
    if ok and type(width) == 'number' and width >= 0 then return width end
    return #format_text(text or '') * pixels * 0.6
  end
  function P.draw(value) canvas = value; clamp() end
  function P.set_position(x, y) ox, oy = tonumber(x) or ox, tonumber(y) or oy; clamp() end
  function P.show(value)
    shown = value ~= false
    if not shown then drag, pressed, hovered = nil, nil, nil end
  end
  function P.toggle() P.show(not shown); return shown end
  function P.destroy() P.show(false); canvas = nil; ready = false end

  -- Only called inside d3d_present. No retained images can survive a hidden row.
  function P.present()
    if not shown or not canvas then return end
    if not ready then ready = true; refresh() end
    clamp()
    local draw = imgui.GetBackgroundDrawList()
    draw:PushClipRect({ox, oy}, {ox + canvas.width, oy + canvas.height}, true)
    local ok, err = pcall(function()
      for _, r in ipairs(canvas.rects or {}) do
        draw:AddRectFilled({ox + r.x, oy + r.y}, {ox + r.x + r.w, oy + r.y + r.h}, colour(r.colour, r.alpha))
      end
      for _, ico in ipairs(canvas.icons or {}) do
        local ref = texture and texture(ico)
        if ref then
          draw:AddImage(ref, {ox + ico.x, oy + ico.y}, {ox + ico.x + ico.size, oy + ico.y + ico.size},
            {0, 0}, {1, 1}, colour(ico.colour, ico.alpha))
        end
      end
      for _, label in ipairs(canvas.labels or {}) do
        draw:AddText(imgui.GetFont(), (label.size or 10) * 4 / 3,
          {ox + label.x, oy + label.y}, colour(label.colour), format_text(label.text))
      end
    end)
    draw:PopClipRect()
    if not ok then error(err, 0) end
    if pointer_x and model and model.contains(canvas,pointer_x-ox,pointer_y-oy) then
      -- The game's cursor can sit beneath the overlay. Draw a small local pointer above it.
      draw:AddTriangleFilled({pointer_x+1,pointer_y+1},{pointer_x+5,pointer_y+16},{pointer_x+11,pointer_y+11},colour({0,0,0}))
      draw:AddTriangleFilled({pointer_x,pointer_y},{pointer_x+4,pointer_y+14},{pointer_x+9,pointer_y+9},colour({255,245,215}))
    end
  end

  -- Same normalized mouse contract as Windower: move=0, left-down=1, left-up=2.
  function P.mouse(kind, mx, my, on_action, delta)
    if not shown or not canvas or not model then return false end
    pointer_x, pointer_y = mx, my
    local x, y = mx - ox, my - oy
    if kind==10 and model.contains(canvas,x,y) then
      local step=(tonumber(delta) or 0)>0 and -1 or 1
      local page=math.max(1,math.min(canvas.page_count or 1,(canvas.page or 1)+step))
      if delta and delta~=0 and page~=(canvas.page or 1) and on_action then on_action('page:'..page) end
      return true
    end
    if drag then
      if kind == 0 then ox, oy = mx - drag.x, my - drag.y; clamp(); return true end
      if kind == 2 then drag = nil; if moved then moved(ox, oy) end; refresh(); return true end
    end
    if kind == 0 then
      local over = model.hit(canvas, x, y)
      if over ~= hovered then hovered = over; refresh() end
    elseif kind == 1 then
      local id = model.hit(canvas, x, y)
      if id then pressed = id; return true end
      if model.is_drag_handle(canvas, x, y) then drag = {x=x, y=y}; return true end
    elseif kind == 2 then
      local was = pressed
      pressed = nil
      if was and model.hit(canvas, x, y) == was then
        if on_action then on_action(was) end
        return true
      end
      -- Release belongs to this UI even when the pointer moved off the window.
      if was then return true end
    end
    return model.contains(canvas, x, y)
  end
  return P
end
return M
