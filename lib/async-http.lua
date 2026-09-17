-- Frame-stepped LuaSocket/LuaSec HTTP with cooperative DNS-over-HTTPS.
-- No processes, game APIs, new dependencies or automatic request replay.
local M={}
function M.new(socket,ssl,cafile,framing,verify,resolver,json)
  local T={TIMEOUT=5,dns_seconds=300}
  local clock=socket.gettime or os.time
  local start
  start=function(request,pinned_ip,limit)
    assert(type(request)=='table' and type(request.url)=='string','Invalid HTTP request')
    local scheme,authority,path=request.url:match('^(https?)://([^/]+)(/.*)$')
    assert(scheme and not authority:find('[%s@?#]') and not path:find('[\r\n]'),'Invalid HTTP URL')
    local host,port=authority:match('^([%w.-]+):(%d+)$')
    if not host then host=authority;port=scheme=='https' and 443 or 80 end
    assert(host:match('^[%w.-]+$'),'Invalid HTTP host');host=host:lower();port=tonumber(port)
    assert(port and port>0 and port<65536,'Invalid HTTP port')
    assert(scheme~='http' or host=='localhost' or host=='127.0.0.1','Plain HTTP is local development only')
    assert(scheme~='https' or ssl,'Verified TLS unavailable')
    assert(not request.proxy and not request.create,'Transport override refused')
    local method=request.method or 'GET';assert(method=='GET' or method=='POST','Unsupported HTTP method')
    local chunks,size={},0
    if request.source then
      while true do local chunk,err=request.source();assert(not err,'HTTP source failed');if not chunk then break end
        assert(type(chunk)=='string' and #chunk>0,'Invalid HTTP source');size=size+#chunk;assert(size<=2097152,'HTTP request too large');chunks[#chunks+1]=chunk
      end
    end
    local lines={method..' '..path..' HTTP/1.1','Host: '..authority,'Connection: close','Accept-Encoding: identity','Content-Length: '..size}
    for key,value in pairs(request.headers or {}) do
      assert(type(key)=='string' and key:match('^[%w-]+$') and type(value)=='string' and not value:find('[\r\n]'),'Invalid HTTP header')
      local lower=key:lower()
      assert(lower~='transfer-encoding','Transfer override refused')
      if lower~='host' and lower~='connection' and lower~='content-length' and lower~='accept-encoding' then lines[#lines+1]=key..': '..value end
    end
    local wire=table.concat(lines,'\r\n')..'\r\n\r\n'..table.concat(chunks)
    local r={state='dns',started=clock(),parser=framing.new(limit),offset=1}
    local addresses,index,connect_at
    local function connect_next()
      r.close();index=(index or 0)+1
      if not addresses[index] then return false end
      r.sock=assert(socket.tcp());assert(r.sock:settimeout(0))
      local ok,err=r.sock:connect(addresses[index],port)
      connect_at=clock();r.state='connect'
      return ok or err=='timeout' or err=='wantread' or err=='wantwrite'
    end
    function r.close()
      if r.resolving then r.resolving.close();r.resolving=nil end
      if r.sock then pcall(r.sock.close,r.sock);r.sock=nil end
    end
    local function finish(error)
      if error and T.resolver and (r.state=='connect' or r.state=='next-address') then T.resolver.cache[host]=nil end
      r.error=error;r.done=true;r.code=r.parser.code;r.body=r.parser.body;r.close()
      T.last_ms=math.max(0,math.floor((clock()-r.started)*1000));T.max_ms=math.max(T.max_ms or 0,T.last_ms);T.request_count=(T.request_count or 0)+1
    end
    local function pending(error) return error=='timeout' or error=='wantread' or error=='wantwrite' end
    function r.step()
      if r.done then return end
      if clock()-r.started>=T.TIMEOUT then
        finish('Network deadline exceeded. Check results before repeating a write.');return
      end
      if r.state=='dns' then
        if pinned_ip then addresses={pinned_ip}
        elseif host=='localhost' then addresses={'127.0.0.1'}
        elseif resolver and resolver.ip(host) then addresses={host}
        else
          if not T.resolver then finish('DNS resolver unavailable.');return end
          T.resolver.cache_seconds=T.dns_seconds
          if not r.resolving then r.resolving=T.resolver.resolve(host) end
          if not r.resolving.done then r.resolving.step();return end
          if r.resolving.error then finish(r.resolving.error);return end
          addresses=r.resolving.addresses;r.resolving=nil
        end
        if not connect_next() then
          r.state='next-address'
        end
        return
      elseif r.state=='next-address' then
        if not addresses[index+1] then finish('Connection failed.');return end
        if not connect_next() then r.state='next-address' end
        return
      elseif r.state=='connect' then
        if not r.sock:getpeername() then
          if addresses[index+1] and clock()-connect_at>=1 then r.state='next-address' end
          return
        end
        if scheme=='https' then
          r.sock=assert(ssl.wrap(r.sock,{mode='client',protocol='any',verify='peer',cafile=cafile,options={'all','no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'}}))
          r.sock:sni(host);assert(r.sock:settimeout(0));r.state='tls'
        else r.state='send' end
      elseif r.state=='tls' then
        local ok,err=r.sock:dohandshake()
        if ok then
          local cert=r.sock:getpeercertificate()
          if not cert or not verify.matches(host,cert:extensions()) then finish('TLS hostname verification failed.');return end
          r.state='send'
        elseif not pending(err) then finish('TLS certificate or handshake failed.') end
      elseif r.state=='send' then
        local sent,err,last=r.sock:send(wire,r.offset,math.min(#wire,r.offset+4095))
        r.offset=(sent or last or (r.offset-1))+1
        if not sent and not pending(err) then finish('Request send failed. Check results before retrying.');return end
        if r.offset>#wire then r.state='receive' end
      elseif r.state=='receive' then
        local data,err,partial=r.sock:receive(4096)
        r.parser.feed(data or partial or '',err=='closed')
        if r.parser.done then finish()
        elseif not data and not pending(err) then finish('Response interrupted. Check results before retrying.') end
      end
    end
    return r
  end
  if resolver then T.resolver=resolver.new(start,json,clock) end
  function T.start(request) return start(request) end
  function T.request(request)
    local ok,job=pcall(T.start,request)
    if not ok then return nil,'Request could not be prepared.' end
    local success,code,body=coroutine.yield(job)
    if success and request.sink then local accepted=request.sink(body);if not accepted then return nil,'Response sink failed.' end;request.sink(nil) end
    return success,code
  end
  return T
end
return M
