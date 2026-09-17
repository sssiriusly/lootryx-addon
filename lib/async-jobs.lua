-- Cooperative jobs compatible with stock Lua 5.1. Never yields across a C pcall.
local M={}
local function pack(...) return {n=select('#',...),...} end
function M.protect(fn,...)
  local co=coroutine.create(fn);local result=pack(coroutine.resume(co,...))
  while result[1] and coroutine.status(co)~='dead' do
    local resumed=pack(coroutine.yield(unpack(result,2,result.n)))
    result=pack(coroutine.resume(co,unpack(resumed,1,resumed.n)))
  end
  return unpack(result,1,result.n)
end
function M.new(identity,on_error,on_done)
  local q={}
  local active
  local owner
  local identity_changed=false
  local function valid_identity()
    local current=identity()
    if current~='offline' then
      if owner and owner~=current then identity_changed=true end
      owner=owner or current
    end
    return not identity_changed
  end
  function q.busy() return active~=nil end
  local function resume(...)
    local job=active
    local ok,value=coroutine.resume(job.co,...)
    if not ok then active=nil;on_error('Request task failed. Please retry or report this error.');if on_done then on_done() end
    elseif coroutine.status(job.co)=='dead' then active=nil;if job.waited and on_done then on_done() end
    elseif type(value)=='table' and type(value.step)=='function' and type(value.close)=='function' then job.request=value;job.waited=true
    else active=nil;on_error('Invalid asynchronous request task.');if on_done then on_done() end end
  end
  function q.run(fn,...)
    if active then return false end
    if not valid_identity() then
      if not q.warned then q.warned=true;on_error('Character changed. Reload Lootryx before making requests.') end
      return false
    end
    active={co=coroutine.create(fn),identity=identity()};resume(...);return true
  end
  function q.cancel(quiet)
    if not active then return end
    if active.request then pcall(active.request.close) end
    active=nil
    if not quiet then on_error('Request interrupted. Check the website before repeating a write.') end
    if on_done then on_done() end
  end
  function q.tick()
    if not active then return end
    if not valid_identity() or active.identity~=identity() then q.cancel(false);return end
    local job=active;local ok,err=pcall(job.request.step)
    if not ok then job.request.close();job.request.done=true;job.request.error='Network response could not be processed.' end
    if job.request.done then
      local r=job.request;job.request=nil
      resume(not r.error and 1 or nil,r.error or r.code,r.body)
    end
  end
  return q
end
return M
