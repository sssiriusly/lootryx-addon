-- Shared TLS transport for LuaSocket/LuaSec. Authenticate before sending HTTP data.
-- SAN layout is the LuaSec 1.0.2 X509 API: extensions()['2.5.29.17'].dNSName.
local M = {}
local function dns(value)
  return type(value)=='string' and value~='' and value:match('^[%w.-]+$')
    and not value:find('%.%.') and not value:match('^%.') and not value:match('%.$')
end
function M.matches(host, extensions)
  if not dns(host) or type(extensions)~='table' then return false end
  host=host:lower()
  local san=extensions['2.5.29.17']
  if type(san)~='table' then return false end
  local ip=host:match('^[%d.]+$')~=nil
  local names
  if ip then names=san.iPAddress else names=san.dNSName end
  if type(names)~='table' then return false end
  for _,name in ipairs(names) do
    if type(name)=='string' then
      name=name:lower()
      if dns(name) and name==host then return true end
      if not ip and name:sub(1,2)=='*.' then
        local suffix=name:sub(3)
        local label,rest=host:match('^([^.]+)%.(.+)$')
        if dns(suffix) and suffix:find('%.') and label and rest==suffix then return true end
      end
    end
  end
  return false
end
function M.new(http,socket,ssl,cafile)
  local T={TIMEOUT=4}
  function T.request(request)
    if type(request)~='table' or type(request.url)~='string' then return nil,'HTTPS request must be a table' end
    local authority=request.url:match('^https://([^/%?#]+)')
    if not authority then return nil,'HTTPS URL required' end
    local host,port=authority:match('^([^:]+):(%d+)$')
    if not host then host=authority;port=443 end
    port=tonumber(port)
    if not dns(host) or not port or port<1 or port>65535 then return nil,'invalid HTTPS authority' end
    if request.proxy or http.PROXY then return nil,'HTTPS proxy override refused' end
    local clock=socket.gettime or os.time
    local started=clock()
    local function budget(sock)
      local remaining=T.TIMEOUT-(clock()-started)
      if remaining<=0 then error('HTTPS request deadline exceeded') end
      assert(sock:settimeout(remaining))
      assert(sock:settimeout(remaining,'t'))
      return 1
    end
    local connections={}
    local function create()
      local conn={sock=assert(socket.tcp())}
      connections[#connections+1]=conn
      function conn:close()
        if not self.closed then self.closed=true;return self.sock:close() end
      end
      function conn:settimeout() return budget(self.sock) end
      function conn:connect(actual,actual_port)
        if actual:lower()~=host:lower() or tonumber(actual_port)~=port then error('HTTPS authority changed') end
        budget(self.sock)
        assert(self.sock:connect(host,port))
        self.sock=assert(ssl.wrap(self.sock,{
          mode='client',protocol='any',verify='peer',cafile=cafile,
          options={'all','no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'},
        }))
        self.sock:sni(host)
        budget(self.sock)
        assert(self.sock:dohandshake())
        local cert=self.sock:getpeercertificate()
        if not cert or not M.matches(host,cert:extensions()) then error('TLS hostname verification failed') end
        self.verified=true
        return 1
      end
      for _,method in ipairs({'send','receive','getfd','dirty'}) do
        conn[method]=function(self,...)
          if method=='send' and not self.verified then error('HTTP data before TLS verification refused') end
          if method=='send' or method=='receive' then budget(self.sock) end
          return self.sock[method](self.sock,...)
        end
      end
      return conn
    end
    -- Request data cannot override verification, hostname, port, proxy or redirects.
    local copy={url=request.url,method=request.method,source=request.source,sink=request.sink,
      headers={},port=port,create=create,redirect=false}
    for key,value in pairs(request.headers or {}) do copy.headers[key]=value end
    local ok,result,code,headers,status=pcall(http.request,copy)
    T.last_ms=math.max(0,math.floor((clock()-started)*1000))
    T.max_ms=math.max(T.max_ms or 0,T.last_ms)
    T.request_count=(T.request_count or 0)+1
    for _,conn in ipairs(connections) do pcall(conn.close,conn) end
    if not ok then return nil,'TLS/HTTP request failed: ' .. tostring(result) end
    return result,code,headers,status
  end
  return T
end
return M
