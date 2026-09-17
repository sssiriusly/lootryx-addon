-- Shared local tools and bounded output history. No platform APIs or network calls.
local M={draft={book='',include='',exclude=''}, history={}, pending=nil}
M.notices={}
M.unread=0
M.notice_sequence=0
function M.notify(message,enabled,emit,action)
  M.notice_sequence=M.notice_sequence+1
  M.notices[#M.notices+1]={id=M.notice_sequence,message=message,at=os.time(),action=action,read=false}
  M.unread=M.unread+1
  if #M.notices>50 then
    local removed=table.remove(M.notices,1)
    if not removed.read then M.unread=math.max(0,M.unread-1) end
  end
  if enabled then emit(message) end
end
function M.mark_read(id)
  for _,notice in ipairs(M.notices) do
    if notice.id==tonumber(id) then
      if not notice.read then notice.read=true;M.unread=math.max(0,M.unread-1) end
      return notice
    end
  end
end
function M.open_notice(id)
  local notice=M.mark_read(id)
  return notice and notice.action and notice.action.id
end
function M.mark_all_read()
  for _,notice in ipairs(M.notices) do notice.read=true end
  M.unread=0
end
function M.clear_notices() M.notices={};M.unread=0;M.notice_detail=nil end
function M.notification_rows()
  if M.notice_detail then
    local selected
    for _,notice in ipairs(M.notices) do if notice.id==M.notice_detail then selected=notice end end
    local rows={{kind='pagehead',title='Notification',actions={{id='notices:list',label='Back to notifications'}}}}
    if not selected then rows[#rows+1]={kind='text',text='This notification is no longer in session history.'};return rows end
    rows[#rows+1]={kind='text',text=os.date('%Y-%m-%d %H:%M:%S',selected.at)..' / Read'}
    rows[#rows+1]={kind='text',text=selected.message}
    if selected.action then rows[#rows+1]={kind='toolbar',actions={{id='notices:open:'..selected.id,label=selected.action.label or 'View related record'}}} end
    rows[#rows+1]={kind='text',text='This is a recorded update. The related record may have changed or expired; refresh its destination for current status.'}
    return rows
  end
  local rows={{kind='pagehead',title='Notifications',subtitle=tostring(M.unread)..' unread / this session, newest first.',
    actions={{id='notices:preferences',label='Preferences'}}},
    {kind='toolbar',actions={{id='notices:read-all',label='Mark all read'},{id='notices:clear',label='Clear history',variant='danger'}}}}
  if #M.notices==0 then rows[#rows+1]={kind='banner',title='No notifications yet',subtitle='Party, recruitment and auction updates appear here.'} end
  for i=#M.notices,1,-1 do
    local notice=M.notices[i]
    rows[#rows+1]={kind='banner',title=notice.message,
      subtitle=(notice.read and 'Read / ' or 'Unread / ')..os.date('%H:%M:%S',notice.at),art='notification',accent=not notice.read and 'info' or 'dim',
      action={id='notices:detail:'..notice.id,label='Read'},
      secondary_action=not notice.read and {id='notices:read:'..notice.id,label='Mark read'} or nil}
  end
  return rows
end
function M.reporting_rows(settings,correction,status)
  status=status or {}
  local attendance=not settings.auto and 'Off' or not status.linked and 'Blocked: link your character' or status.active and 'Check-in open' or 'Waiting for check-in'
  local heartbeat=not settings.heartbeat and 'Off' or not status.linked and 'Blocked: link your character' or M.heartbeat_status or 'Waiting for first report'
  local rows={
    {kind='pagehead',title='Reporting',subtitle='Optional reports sent to Lootryx.',actions={{id='settings',label='Back'}}},
    {kind='toggle',title='Automatic attendance capture',on=settings.auto==true,
      subtitle=attendance..' / every '..tostring(settings.interval)..'s',
      action={id='cmd:auto',label=settings.auto and 'Turn off' or 'Turn on'}},
    {kind='toggle',title='Share my current zone',on=settings.heartbeat==true,
      subtitle=heartbeat..' / every '..tostring(settings.heartbeat_interval)..'s',
      action={id='cmd:heartbeat',label=settings.heartbeat and 'Turn off' or 'Turn on'}},
    {kind='text',text=status.capture or 'No capture result this session. Attendance requires an open check-in.'},
    {kind='text',text=M.heartbeat_feedback or 'Zone reports need linkshell opt-in. No accepted report this session.'},
    {kind='banner',title='Attendance adjustments',subtitle=correction or 'No adjustments active',
      action={id='board:corrections',label='Edit'},secondary_action=correction and {id='tools:reset',label='Clear'} or nil},
    {kind='toolbar',actions={{id='attendance:open',label='View attendance'},{id='board:network',label='Network status'}}},
    {kind='text',text='No automatic DKP awards. Zone reports exclude coordinates and kills. Switches persist; attendance adjustments clear on reload.'},
  }
  return rows
end
function M.preference_rows(settings)
  local rows={{kind='pagehead',title='Notification preferences',actions={{id='notifications',label='Back'}}},
    {kind='text',text='History is kept for this session, even when chat alerts are off. Reloading clears history.'}}
  local function option(key,title,detail)
    rows[#rows+1]={kind='toggle',title=title,subtitle=detail,on=settings[key]~=false,
      action={id='notice:'..key,label=settings[key]~=false and 'Turn off' or 'Turn on'}}
  end
  local section=M.preference_section or 'background'
  rows[#rows+1]={kind='choices',compact=true,options={{id='notices:group:background',label='Background',selected=section=='background'},{id='notices:group:auctions',label='Auctions',selected=section=='auctions'},{id='notices:group:party',label='Party',selected=section=='party'}}}
  if section=='background' then
  option('live_auctions','Check auctions','Every '..tostring(settings.auction_refresh_interval)..'s while enabled')
  option('live_recruitment','Check recruitment and invitations','Every '..tostring(settings.recruitment_refresh_interval)..'s while enabled')
  option('live_attendance','Check event attendance','Every '..tostring(settings.attendance_refresh_interval or 30)..'s while enabled')
  option('notify_checkin','Attendance check-in alerts','Opened or closed check-in, after a successful background or manual refresh')
  elseif section=='auctions' then
  rows[#rows+1]={kind='text',text=settings.live_auctions==false and 'Background auction checks are off. New auctions and results are only discovered when you refresh.' or 'New auctions and results arrive after a successful auction check, not instantly.'}
  option('notify_new_auctions','New auctions','A newly discovered auction opens')
  option('notify_auction_results','Auction results','The server confirms a followed auction result')
  option('notify_auction_deadline','Bidding deadline','Local countdown ends; settlement may still be pending')
  else
  rows[#rows+1]={kind='text',text='Game party alerts use local party data. Recruitment, invitation and ready-check alerts need a successful background or manual refresh.'}
  option('notify_party','Game party changes','A stable join or leave in your six-player game party')
  option('notify_recruitment','Recruitment roster','Joins, departures and closure in tracked recruitment')
  option('notify_invites','Recruitment invitations','Website invitations, separate from game invites')
  option('notify_ready','Ready checks','A ready check starts or everyone is ready')
  end
  return rows
end
function M.valid_book(n) return type(n)=='number' and n==math.floor(n) and n>=1 and n<=M.max_books end
function M.begin(limit) M.pending={};M.limit=limit or 5 end
function M.record(message)
  M.history_sequence=(M.history_sequence or 0)+1
  message=tostring(message)
  M.history[#M.history+1]=message
  if #M.history>200 then table.remove(M.history,1) end
  if M.pending then M.pending[#M.pending+1]=message;return true end
  return false
end
function M.finish(emit)
  local lines=M.pending or {};M.pending=nil
  if #lines<=(M.limit or 5) then for _,line in ipairs(lines) do emit(line) end
  else
    emit(lines[1]);emit(lines[#lines])
    emit(tostring(#lines)..' lines available in Settings > Results.')
  end
end
function M.results()
  local rows={{kind='pagehead',title='Recent results',subtitle='Local session history, newest first.',
    actions={{id='board:hub',label='Back'}}},
    {kind='toolbar',actions={{id='tools:export',label='Export full text'},{id='tools:clear',label='Clear',variant='danger'}}}}
  if M.export_feedback then rows[#rows+1]={kind='text',text=M.export_feedback} end
  if M.export_path then rows[#rows+1]={kind='toolbar',actions={{id='tools:open-export',label='Open exported text'}}} end
  if #M.history==0 then rows[#rows+1]={kind='text',text='No results recorded this session.'} end
  for i=#M.history,1,-1 do rows[#rows+1]={kind='text',text=M.history[i]} end
  return rows
end
function M.export(root)
  local path=root..'lootryx-results.txt'
  local file,problem=io.open(path,'w')
  if not file then M.export_feedback='Could not export results: '..tostring(problem);return false end
  file:write(table.concat(M.history,'\n'));file:close()
  M.export_path=path
  M.export_feedback='Saved full text to '..path..'. Open this file to copy or share the results. Review it for private account details first.'
  return true
end
M.refreshes={}
function M.refresh_result(url,status,body,request,json,refresh_key)
  local ok,reply=pcall(json.decode,body or '')
  local keys={}
  if url:match('/me$') then
    local qok,q=pcall(json.decode,request or '{}');q=qok and type(q)=='table' and q or {}
    if refresh_key then keys[refresh_key]=refresh_key end
    for _,k in ipairs({'auctions','events','wishlist','bounties','loot','bank','currency','statics','polls'}) do if q[k] then keys[k]=k end end
  elseif url:find('/party%-finder/list') or url:find('/public/party%-finder') then keys.pf='listings'
  elseif url:find('/linkshells') then keys.shells='linkshells'
  elseif url:match('/myjobs$') then keys.myjobs='declaration'
  elseif url:match('/polls$') then keys.polls='polls'
  elseif url:match('/statics$') then keys.statics='statics'
  elseif url:match('/item$') then keys.item='item' end
  for key,field in pairs(keys) do
    local state=M.refreshes[key] or {}
    local good=status==200 and ok and type(reply)=='table' and (type(reply[field])=='table' or (key=='item' and reply.found==false))
    state.denied=false
    for _,block in ipairs(ok and type(reply)=='table' and type(reply.denied)=='table' and reply.denied or {}) do
      if block==key then state.denied=true;state.updated=nil end
    end
    state.attempted=os.time();state.failed=not good
    if good then state.updated=os.time() end
    M.refreshes[key]=state
  end
end
function M.refresh_row(key)
  key=({lfg='pf',lfm='pf'})[key] or key
  local state=M.refreshes[key]
  if not state then return nil end
  if state.denied then return {title='Access unavailable',subtitle='Your role cannot read this board.',tag='INFO',accent='dim'} end
  local age=state.updated and math.max(0,os.time()-state.updated)
  return {title=state.failed and 'Refresh failed' or ('Updated ' .. age .. 's ago'),
    subtitle=state.failed and (age and ('Showing cached results, last updated ' .. age .. 's ago. Use Refresh to retry.') or 'No successful read yet. Use Refresh to retry.') or 'Cached results. Refresh to check for changes.',
    tag='INFO',art='setting-diagnostic',accent=state.failed and 'bad' or 'dim'}
end
return M
