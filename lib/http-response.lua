-- Bounded incremental HTTP/1.1 response framing. No sockets or platform APIs.
local M={}
function M.new(limit)
  local p={buffer='',body='',limit=limit or 2097152,done=false}
  function p.feed(bytes,closed)
    if p.done then return end
    p.buffer=p.buffer..(bytes or '')
    if not p.code then
      local at=p.buffer:find('\r\n\r\n',1,true)
      if not at then assert(#p.buffer<=32768,'HTTP headers too large');assert(not closed,'Incomplete HTTP headers');return end
      assert(at<=32768,'HTTP headers too large')
      local head=p.buffer:sub(1,at-1);p.buffer=p.buffer:sub(at+4)
      p.code=tonumber(head:match('^HTTP/1%.[01] (%d%d%d)'))
      assert(p.code and p.code>=200,'Unsupported HTTP status')
      local headers={}
      for key,value in head:gmatch('\r\n([^:]+):%s*([^\r\n]*)') do
        key=key:lower()
        if key=='content-length' or key=='transfer-encoding' then assert(not headers[key],'Duplicate HTTP framing header') end
        headers[key]=value
      end
      p.headers=headers
      if headers['transfer-encoding'] then
        assert(headers['transfer-encoding']:lower()=='chunked' and not headers['content-length'],'Unsupported HTTP framing');p.chunked=true
      elseif headers['content-length'] then
        assert(headers['content-length']:match('^%d+$'),'Invalid HTTP length')
        p.length=tonumber(headers['content-length']);assert(p.length<=p.limit,'HTTP body too large')
      end
      if p.code==204 or p.code==304 then p.length=0 end
    end
    local function append(value)
      assert(#p.body+#value<=p.limit,'HTTP body too large');p.body=p.body..value
    end
    if p.chunked then
      -- Work is bounded by the caller's receive chunk size, including tiny chunks.
      while not p.done do
        if p.trailers then
          if p.buffer:sub(1,2)=='\r\n' or p.buffer:find('\r\n\r\n',1,true) then p.done=true;break end
          assert(#p.buffer<=32768,'HTTP trailers too large');break
        end
        if not p.chunk then
          local at=p.buffer:find('\r\n',1,true)
          if not at then assert(#p.buffer<=128,'Invalid HTTP chunk');break end
          assert(at<=128,'Invalid HTTP chunk')
          local line=p.buffer:sub(1,at-1);local hex=line:match('^(%x+)$') or line:match('^(%x+);')
          assert(hex and #hex<=8,'Invalid HTTP chunk')
          p.chunk=tonumber(hex,16);assert(#p.body+p.chunk<=p.limit,'HTTP body too large')
          p.buffer=p.buffer:sub(at+2)
          if p.chunk==0 then p.trailers=true;p.chunk=nil end
        elseif #p.buffer>=p.chunk+2 then
          assert(p.buffer:sub(p.chunk+1,p.chunk+2)=='\r\n','Invalid HTTP chunk ending')
          append(p.buffer:sub(1,p.chunk));p.buffer=p.buffer:sub(p.chunk+3);p.chunk=nil
        else break end
      end
    elseif p.length then
      assert(#p.body+#p.buffer<=p.length,'Unexpected HTTP body data');append(p.buffer);p.buffer='';p.done=#p.body==p.length
    else append(p.buffer);p.buffer='';p.done=closed==true end
    assert(not closed or p.done,'Incomplete HTTP response')
  end
  return p
end
return M
