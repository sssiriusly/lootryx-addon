-- Cloudflare DNS-over-HTTPS. Resolver requests never receive application headers.
-- No system DNS, process launch, persistent cache or game APIs.
local M={}
local function name(value)
  if type(value)~='string' then return nil end
  value=value:lower():gsub('%.$','')
  if #value<1 or #value>253 then return nil end
  for label in (value..'.'):gmatch('(.-)%.') do
    if #label<1 or #label>63 or not label:match('^[%w-]+$') or label:match('^-') or label:match('-$') then return nil end
  end
  return value
end
function M.ip(value)
  if type(value)~='string' or not value:match('^%d+%.%d+%.%d+%.%d+$') then return nil end
  for part in value:gmatch('%d+') do if #part>3 or tonumber(part)>255 or tostring(tonumber(part))~=part then return nil end end
  return value
end
function M.answer(host,body,age,json)
  local reply=json.decode(body)
  assert(type(reply)=='table' and reply.Status==0 and reply.TC==false,'DNS resolution failed')
  assert(type(reply.Question)=='table' and #reply.Question==1 and name(reply.Question[1].name)==host and reply.Question[1].type==1,'DNS question mismatch')
  assert(type(reply.Answer)=='table' and #reply.Answer<=64,'DNS answer unavailable')
  local current,seen,ttl=host,{},86400
  for hop=1,9 do
    assert(not seen[current],'DNS alias loop');seen[current]=true
    local addresses,alias={},nil
    for _,rr in ipairs(reply.Answer) do
      if name(rr.name)==current and (rr.type==1 or rr.type==5) then
        assert(type(rr.TTL)=='number' and rr.TTL>=0 and rr.TTL<=2147483647 and rr.TTL==math.floor(rr.TTL),'Invalid DNS lifetime')
        ttl=math.min(ttl,rr.TTL)
        if rr.type==1 then addresses[#addresses+1]=assert(M.ip(rr.data),'Invalid DNS address')
        else local target=assert(name(rr.data),'Invalid DNS alias');assert(not alias or alias==target,'Conflicting DNS aliases');alias=target end
      end
    end
    assert(not alias or #addresses==0,'Ambiguous DNS answer')
    if #addresses>0 then if age~=nil then assert(tostring(age):match('^%d+$'),'Invalid DNS age') end;local elapsed=tonumber(age) or 0;assert(elapsed>=0 and elapsed<2147483648,'Invalid DNS age');return addresses,math.max(0,ttl-elapsed) end
    current=assert(alias,'DNS address unavailable')
  end
  error('DNS alias limit exceeded')
end
function M.new(start,json,clock)
  local R={cache={},retry_at=0,cache_seconds=300,timeout=4,retry_seconds=15}
  local endpoints={'1.1.1.1','1.0.0.1'}
  function R.resolve(host)
    host=assert(name(host),'Invalid DNS name')
    local now=clock();local cached=R.cache[host]
    if cached and cached.until_at>now then return {done=true,addresses=cached.addresses,close=function() end} end
    local job={started=now,attempt=0}
    function job.close() if job.request then job.request.close();job.request=nil end end
    local function fail()
      job.close();job.done=true;job.error='DNS unavailable. Cached results remain available; retry shortly.'
      R.retry_at=clock()+R.retry_seconds
    end
    if now<R.retry_at then job.done=true;job.error='DNS retry delayed. Retry shortly.';return job end
    function job.step()
      if job.done then return end
      if clock()-job.started>=R.timeout then fail();return end
      if not job.request then
        job.attempt=job.attempt+1
        if not endpoints[job.attempt] then fail();return end
        job.request=start({url='https://cloudflare-dns.com/dns-query?name='..host..'&type=A',
          headers={accept='application/dns-json'}},endpoints[job.attempt],16384)
        job.attempt_at=clock();return
      end
      local req=job.request
      local ok=pcall(req.step)
      if not ok then job.close();return end
      if not req.done then
        if clock()-job.attempt_at>=R.timeout/2 then job.close() end
        return
      end
      if not req.error and req.code==200 then
        local parsed,addresses,ttl=pcall(M.answer,host,req.body,req.parser.headers.age,json)
        if parsed then
          job.close();job.done=true;job.addresses=addresses;R.retry_at=0
          local count=0
          for key,entry in pairs(R.cache) do if entry.until_at<=clock() then R.cache[key]=nil else count=count+1 end end
          if count>=16 then R.cache={} end
          ttl=math.min(ttl,R.cache_seconds)
          if ttl>0 then R.cache[host]={addresses=addresses,until_at=clock()+ttl} end
          return
        end
        -- A valid HTTP response with an unusable DNS answer is not retried elsewhere.
        fail();return
      end
      job.close()
    end
    return job
  end
  return R
end
return M
