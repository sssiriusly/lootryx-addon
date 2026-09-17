-- Compact overlay text interface, rendered through the same ImGui canvas path.
-- Inline colour markup is split into text runs instead of appearing as literal text.
local M = {}
function M.new(panel_factory, imgui)
  local objects = {}
  local T = {}
  function T.new(text, options)
    options = options or {}
    local size = (options.text or {}).size or 10
    local rgb = {255,255,255}
    local value, dirty = text or '', true
    local panel = panel_factory(imgui)
    local o = {}
    panel.bind({
      hit=function() return nil end,
      contains=function(c,x,y) return x>=0 and y>=0 and x<c.width and y<c.height end,
      is_drag_handle=function(c,x,y) return x>=0 and y>=0 and x<c.width and y<c.height end,
    })
    function o:pos(x,y) if x then panel.set_position(x,y) end; return panel.position() end
    function o:text(v) value=v; dirty=true end
    function o:color(r,g,b) rgb={r,g,b};dirty=true end
    function o:hide() panel.show(false) end
    function o:show() panel.show(true) end
    function o:destroy() panel.destroy();objects[o]=nil end
    function o:present()
      if dirty then
        local labels, x, y, width, current = {}, 4, 4, 0, rgb
        local function run(chunk)
          if chunk == '' then return end
          labels[#labels+1]={id=tostring(#labels+1),x=x,y=y,size=size,colour=current,text=chunk}
          x=x+panel.measure(chunk,size);width=math.max(width,x)
        end
        for line in (value .. string.char(10)):gmatch('(.-)' .. string.char(10)) do
          local pos=1
          while pos<=#line do
            local a,b,r,g,blue=line:find('\\cs%((%d+),(%d+),(%d+)%)',pos)
            local reset_a,reset_b=line:find('\\cr',pos,true)
            if reset_a and (not a or reset_a<a) then
              run(line:sub(pos,reset_a-1));current=rgb;pos=reset_b+1
            elseif a then
              run(line:sub(pos,a-1));current={tonumber(r),tonumber(g),tonumber(blue)};pos=b+1
            else run(line:sub(pos));break end
          end
          x=4;y=y+size*4/3+2
        end
        panel.draw({width=width+4,height=y+2,labels=labels,icons={},regions={},rects={
          {x=0,y=0,w=width+4,h=y+2,colour={0,0,0},alpha=(options.bg or {}).alpha or 190}}})
        dirty=false
      end
      panel.present()
    end
    objects[o]=panel
    return o
  end
  function T.present() for object in pairs(objects) do object:present() end end
  function T.mouse(kind,x,y)
    for _,panel in pairs(objects) do if panel.mouse(kind,x,y) then return true end end
    return false
  end
  function T.destroy() for object in pairs(objects) do object:destroy() end end
  return T
end
return M
