-- Explicit local chat drafts only. This module cannot submit or execute a command.
local M={}
function M.build(action,name)
  if type(name)~='string' or #name<3 or #name>15 or not name:match('^[A-Za-z]+$') then
    return nil,'Enter a character name using 3 to 15 letters.'
  end
  local prefix=({tell='/tell ',invite='/pcmd add ',kick='/pcmd kick '})[action]
  if not prefix then return nil,'Unknown chat action.' end
  return prefix..name..(action=='tell' and ' ' or '')
end
function M.prepare(host,action,name)
  M.pending=nil
  local text,err=M.build(action,name)
  if not text then return false,err end
  if type(host.get_chat_draft)~='function' or type(host.set_chat_draft)~='function' then
    return false,'Chat prefilling is unavailable on this client.'
  end
  local ok,current=pcall(host.get_chat_draft)
  if not ok then return false,'Could not read chat. Your draft was left untouched.' end
  if current~=nil and type(current)~='string' then return false,'Could not read chat safely.' end
  if current and current~='' and current~=text then
    return false,'Chat already contains a draft. Send or clear it first.'
  end
  if type(host.chat_is_open)=='function' then
    local readable,opened=pcall(host.chat_is_open)
    if not readable then return false,'Could not check chat input. Open chat and retry.' end
    if not opened then
      M.pending={action=action,name=name,expires=os.time()+30}
      return true,'Draft held for 30s. Open game chat to insert it; nothing is sent.'
    end
  end
  M.pending=nil
  local written,result=pcall(host.set_chat_draft,text)
  if not written or result==false then return false,'Could not prefill chat on this client.' end
  local checked,actual=pcall(host.get_chat_draft)
  if not checked or actual~=text then return false,'Chat did not accept the draft. Open chat and retry.' end
  return true,'Prepared '..text..' in chat. Review it and press Enter yourself.'
end
function M.poll(host,valid)
  local p=M.pending
  if not p then return end
  if os.time()>=p.expires then M.pending=nil;return false,'Chat draft expired. Click Prepare again.' end
  local ok,opened=pcall(host.chat_is_open)
  if not ok or not opened then return end
  M.pending=nil
  if valid and not valid(p.action,p.name) then return false,'That player left your party. Draft cancelled.' end
  return M.prepare(host,p.action,p.name)
end
return M
