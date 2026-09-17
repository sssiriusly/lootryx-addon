-- Pure Lua 5.1 pointer calibration. No FFI, OS calls, or input simulation.
local M={}
local function valid(n) return type(n)=='number' and n==n and math.abs(n)<10000000 end
function M.new(read_ui)
  local self={stage=nil,message=''}
  local saved={}
  local persist=function() end
  local samples={}
  local candidate
  local function profile()
    local ok,s=pcall(read_ui);s=ok and type(s)=='table' and s or {}
    return table.concat({tostring(s.ui_x_res),tostring(s.ui_y_res),tostring(s.x_res),tostring(s.y_res)},':')
  end
  function self.configure(config,save) saved=config;persist=save or persist end
  function self.map(x,y)
    self.raw_x,self.raw_y=x,y
    if saved.pointer_profile==profile() and valid(saved.pointer_sx) and valid(saved.pointer_sy) and valid(saved.pointer_ox) and valid(saved.pointer_oy)
      and saved.pointer_sx>=0.5 and saved.pointer_sx<=2 and saved.pointer_sy>=0.5 and saved.pointer_sy<=2 then
      return x*saved.pointer_sx+saved.pointer_ox,y*saved.pointer_sy+saved.pointer_oy
    end
    return x,y
  end
  function self.start() self.stage=1;self.message='';samples={};candidate=nil end
  function self.cancel() self.stage=nil;samples={};candidate=nil end
  function self.reset() self.cancel();saved.pointer_profile='';persist() end
  function self.target()
    return ({ {70,105},{550,405},{310,255} })[self.stage or 1]
  end
  function self.click(x,y,ox,oy)
    if not self.stage or not valid(x) or not valid(y) then return false end
    local target=self.target();local tx,ty=ox+target[1],oy+target[2]
    if self.stage<3 then
      samples[self.stage]={x=x,y=y,tx=tx,ty=ty}
      if self.stage==2 then
        local a,b=samples[1],samples[2]
        local dx,dy=b.x-a.x,b.y-a.y
        if math.abs(dx)<100 or math.abs(dy)<100 then self.start();self.message='Points too close. Try again.';return false end
        local sx,sy=(b.tx-a.tx)/dx,(b.ty-a.ty)/dy
        if sx<0.5 or sx>2 or sy<0.5 or sy>2 then self.start();self.message='Alignment outside range. Try again.';return false end
        candidate={sx=sx,sy=sy,ox=a.tx-a.x*sx,oy=a.ty-a.y*sy}
      end
      self.stage=self.stage+1;return false
    end
    if math.abs(x*candidate.sx+candidate.ox-tx)>8 or math.abs(y*candidate.sy+candidate.oy-ty)>8 then
      self.start();self.message='Verification missed. Try again.';return false
    end
    saved.pointer_sx,saved.pointer_sy=candidate.sx,candidate.sy
    saved.pointer_ox,saved.pointer_oy=candidate.ox,candidate.oy
    saved.pointer_profile=profile();self.cancel();persist();return true
  end
  function self.describe()
    return {'Pointer: '..(saved.pointer_profile==profile() and 'calibrated' or 'native events, not calibrated'),
      'Runtime '.._VERSION..' / UI and render '..profile(),
      'Last event '..tostring(self.raw_x)..','..tostring(self.raw_y),
      'Use Settings > Align pointer if the game cursor and addon disagree.'}
  end
  return self
end
return M
