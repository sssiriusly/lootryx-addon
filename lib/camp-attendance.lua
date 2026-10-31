-- HNM camp checks are server scheduled. Only explicit clicks send attendance answers.
local M={}
local function button(id,label) return {id='camp:'..id,label=label} end
local function text(rows,value) rows[#rows+1]={kind='text',text=value} end
function M.new(api)
  local self={state=nil,next_poll=0,failures=0,draft=nil,review=nil,selected={},feedback=nil}
  local offset,noticed=0,{}
  local function now() return api.now and api.now() or os.time() end
  self.next_poll=now()+30
  local function ms() return now()*1000+offset end
  local function camp() return not self.listing and self.state and self.state.activeCamp end
  local function clear_review() self.review=nil;self.selected={} end
  local function countdown(deadline) local n=math.max(0,math.ceil((deadline-ms())/1000));return string.format('%d:%02d',math.floor(n/60),n%60) end
  local function latejoin(c,check)
    if check.checkNumber<=0 or not check.periodStartsAtMs then return false end
    for _,p in ipairs(c.participants or {}) do
      if p.membershipId==c.myMembershipId then return (p.joinedAtMs or 0)>check.periodStartsAtMs end
    end
    return false
  end
  local function opencheck(selected)
    local c=selected or camp();if not c or not c.myJoined or c.status~='ACTIVE' then return nil end
    for _,check in ipairs(c.checks or {}) do
      if check.canRespond~=false and check.checkNumber>=0 and check.opensAtMs<=ms() and check.closesAtMs>ms() and check.status~='CLOSED' and not check.response and not latejoin(c,check) then return check end
    end
  end
  local function accept(reply,background)
    if background or not self.viewid then self.live=reply end
    if not background or not self.viewid or (reply.activeCamp and reply.activeCamp.id==self.viewid) then
      local previous=camp();local incoming=reply.activeCamp
      if previous and (not incoming or previous.id~=incoming.id) then clear_review() end
      self.state=reply
    end
    offset=reply.serverNowMs-now()*1000;self.failures=0;self.next_poll=now()+30
    local c=reply.activeCamp;local check=c and opencheck(c)
    local rc=c and c.readyCheck
    if c and c.myJoined and rc and rc.open and rc.closesAtMs>ms() and not rc.myResponse and not noticed[rc.id] then
      noticed[rc.id]=true;api.notify(c.targetName..' availability check: '..countdown(rc.closesAtMs)..' to respond. No DKP. Open camp attendance.')
    end
    if check and c then
      local key=c.id..':'..check.checkNumber
      if not noticed[key] then
        noticed[key]=true
        api.notify(c.targetName..' attendance check: '..countdown(check.closesAtMs)..' to respond. Open HNM camp.')
      end
    end
  end
  local function read(quiet,id,background)
    local reply,err=api.request('/camps/state',id and {campId=id} or {})
    if reply and type(reply.serverNowMs)=='number' and type(reply.camps)=='table' and type(reply.canManage)=='boolean' then
      accept(reply,background);if not quiet then self.feedback=nil end;return true
    end
    self.failures=self.failures+1;self.next_poll=now()+math.min(300,30*2^math.min(self.failures,3))
    self.feedback='Camp status unavailable. '..tostring(err or 'Refresh to retry.');return false
  end
  local function mutate(path,body,message)
    local reply,err=api.request('/camps/'..path,body)
    if not reply or reply.ok~=true then self.feedback='Not confirmed. '..tostring(err or 'Refresh before retrying.');return false end
    if type(reply.serverNowMs)=='number' and type(reply.camps)=='table' then accept(reply) else read(true,body.campId) end
    self.feedback=type(reply.warning)=='string' and reply.warning or message;api.notify(self.feedback);return true
  end
  function self.reset() self.state=nil;self.next_poll=now()+30;self.draft=nil;clear_review();self.feedback=nil;self.live=nil;self.viewid=nil;self.listing=nil;offset=0;noticed={} end
  function self.poll(timestamp)
    if api.enabled and not api.enabled() then return end
    if (timestamp or now())<self.next_poll then return end
    read(true,nil,true);if api.redraw then api.redraw(false) end;return true
  end
  function self.set_field(name,value)
    if self.review and self.review.kind=='exception' and name=='checkNumber' then
      local n=tonumber(value);self.review.checkNumber=n and n>=(camp() and camp().status=='KILLED' and -1 or 0) and n==math.floor(n) and n or nil;return
    end
    if self.review and (self.review.kind=='exception' or self.review.kind=='post') and name=='reason' then self.review.reason=value;return end
    if self.draft and (name=='target' or name=='starts') then self.draft[name]=value;if name=='starts' then self.draft.delay=nil end;self.draft.requestId=nil;self.review=nil end
  end
  function self.field_value(name) if name=='checkNumber' then return self.review and tostring(self.review.checkNumber or '') or '' end;if name=='reason' then return self.review and self.review.reason or '' end;return self.draft and self.draft[name] or '' end
  function self.alert()
    local c=self.live and self.live.activeCamp or camp();if self.live and not self.live.activeCamp then return nil end;local check=c and opencheck(c)
    if not check then
      local rc=c and c.readyCheck
      if not c or not c.myJoined or not rc or not rc.open or rc.closesAtMs<=ms() or rc.myResponse then return nil end
      return {kind='banner',opaque=true,title=c.targetName..' availability check',subtitle=countdown(rc.closesAtMs)..' remaining. No DKP.',action=button('open','Respond now')}
    end
    return {kind='banner',opaque=true,title=c.targetName..' attendance check',accent='info',
      subtitle=countdown(check.closesAtMs)..' remaining. Explicit response required.',
      action=button('open','Respond now')}
  end
  function self.action(id)
    local action=id:match('^camp:(.*)$');if not action then return false end
    if action=='new' and not self.state then read(false) end
    local c=camp();local manage=self.state and self.state.canManage
    if action=='open' then clear_review();self.draft=nil;self.listing=nil;self.viewid=nil;read(false)
    elseif action=='refresh' then read(false,self.viewid)
    elseif action:sub(1,5)=='view:' then clear_review();self.draft=nil;self.listing=nil;self.viewid=action:sub(6);read(false,self.viewid)
    elseif action=='list' then clear_review();self.draft=nil;self.listing=true;self.viewid=nil
    elseif action=='new' and manage then self.draft={target='',starts='',delay=0,policy='EXPO'};self.review=nil
    elseif action=='cancel' then self.draft=nil;self.review=nil;self.selected={}
    elseif action:sub(1,6)=='delay:' and self.draft then self.draft.delay=tonumber(action:sub(7));self.draft.starts='';self.draft.requestId=nil;self.review=nil
    elseif action:sub(1,7)=='policy:' and self.draft then self.draft.policy=action:sub(8);self.draft.requestId=nil;self.review=nil
    elseif action:sub(1,5)=='pool:' and self.draft then self.draft.poolId=action:sub(6);self.draft.requestId=nil;self.review=nil
    elseif action=='review-start' and manage and self.draft then
      local d=self.draft
      if not self.state.rules then self.feedback='Rules unavailable. Refresh before starting.'
      elseif d.target=='' or not d.poolId then self.feedback='Enter a target and select the DKP wallet.'
      elseif d.starts~='' and not d.starts:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then self.feedback='Use UTC YYYY-MM-DDTHH:MM:SSZ, or leave blank to start now.'
      else
        d.requestId=d.requestId or ('camp-'..now()..'-'..tostring({}):gsub('[^%w]',''))
        self.review={kind='start',payload={observationOnly=false,policy=d.policy,targetName=d.target,poolId=d.poolId,startsAt=d.starts~='' and d.starts or (d.delay and d.delay>0 and os.date('!%Y-%m-%dT%H:%M:%SZ',math.floor(ms()/1000)+d.delay*60) or nil),requestId=d.requestId}}
      end
    elseif action=='confirm-start' and manage and self.review and self.review.kind=='start' then
      if mutate('start',self.review.payload,'Camp started. Members must join and answer each check.') then self.review=nil;self.draft=nil;self.listing=nil;self.viewid=nil end
    elseif action=='ready-start' and manage and c then mutate('ready-start',{campId=c.id,requestId='ready-'..now()..'-'..tostring({}):gsub('[^%w]','')},'Availability check opened. No DKP is awarded by this check.')
    elseif (action=='ready-now' or action=='unavailable-now') and c and c.readyCheck then mutate('ready-respond',{campId=c.id,readyCheckId=c.readyCheck.id,response=action=='ready-now' and 'READY' or 'AFK'},'Availability response recorded.')
    elseif action=='join' and c and c.status=='ACTIVE' then mutate('join',{campId=c.id},'Joined '..c.targetName..'. Watch for attendance checks.')
    elseif action=='leave' and c then self.review={kind='leave'}
    elseif action=='confirm-leave' and c and self.review and self.review.kind=='leave' then
      if mutate('leave',{campId=c.id},'Left session. Previous responses remain recorded.') then self.review=nil end
    elseif (action=='ready' or action=='afk') and c then
      local check=opencheck()
      if not check then self.feedback='No unanswered check is currently open. Refresh camp.'
      else mutate('respond',{campId=c.id,checkNumber=check.checkNumber,response=action=='ready' and 'READY' or 'AFK'},action=='ready' and 'Ready response recorded. Credit is subject to period eligibility.' or 'AFK recorded. No credit for this period.') end
    elseif action:sub(1,4)=='end:' and manage and c then self.review={kind='end',outcome=action:sub(5),revision=c.revision};self.selected={}
    elseif action:sub(1,5)=='kill:' and self.review and self.review.kind=='end' and manage then local key=action:sub(6);self.selected[key]=not self.selected[key]
    elseif action=='review-post' and manage and c and c.status~='ACTIVE' and not c.postedAtMs and c.rules and c.rules.observationOnly==false then self.review={kind='post',revision=c.revision,reason=''}
    elseif action=='confirm-post' and manage and c and self.review and self.review.kind=='post' then
      if #self.review.reason<8 then self.feedback='Enter a review note of at least 8 characters.'
      elseif mutate('post',{campId=c.id,expectedRevision=self.review.revision,reason=self.review.reason},'Reviewed attendance DKP posted to the session wallet.') then self.review=nil end
    elseif action:sub(1,10)=='exception:' and manage and c and not c.postedAtMs then self.review={kind='exception',revision=c.revision,membershipId=action:sub(11),reason='',action='GRANT'}
    elseif action:sub(1,6)=='check:' and self.review and self.review.kind=='exception' then self.review.checkNumber=tonumber(action:sub(7))
    elseif (action=='grant' or action=='deny') and self.review and self.review.kind=='exception' then self.review.action=action=='grant' and 'GRANT' or 'DENY'
    elseif action=='confirm-exception' and manage and c and self.review and self.review.kind=='exception' then
      local r=self.review
      if not r.checkNumber or #r.reason<8 then self.feedback='Choose a check and enter a reason of at least 8 characters.'
      elseif mutate('exception',{campId=c.id,membershipId=r.membershipId,expectedRevision=r.revision,checkNumber=r.checkNumber,reason=r.reason,action=r.action},'Attendance correction recorded in the audit log.') then self.review=nil end
    elseif action=='confirm-end' and manage and c and self.review and self.review.kind=='end' then
      local ids={};for key,on in pairs(self.selected) do if on then ids[#ids+1]=key end end
      if mutate('end',{campId=c.id,outcome=self.review.outcome,killMembershipIds=#ids>0 and ids or nil,expectedRevision=self.review.revision},'Session ended. Observations retained for review. No DKP posted.') then self.review=nil;self.selected={} end
    end
    return true
  end
  function self.rows()
    local rows={{kind='pagehead',title='HNM camp attendance',actions={button('back','HNM windows'),button('refresh','Refresh')}}}
    local displayed=camp()
    text(rows,displayed and displayed.rules and displayed.rules.observationOnly==false and 'Attendance estimates become spendable only after officer review and posting.' or 'Observation mode: responses and estimates only. No DKP is posted.')
    if self.feedback then text(rows,self.feedback) end
    if not self.state then text(rows,'Refresh to load camps. Attendance responses are never automatic.');return rows end
    if self.state.participationConflict then text(rows,'You are still attending another linkshell session. Open Live attendance on the website to leave it before joining here.') end
    if self.state.joinedElsewhere then local e=self.state.joinedElsewhere;text(rows,'Still joined: '..e.targetName..' / '..e.shellName..'. Switch linkshell and leave that session before joining here.') end
    local c=camp();local manage=self.state.canManage
    if self.draft then
      api.field(rows,'camp.target','Target',self.draft.target,'Example: Simurgh')
      rows[#rows+1]={kind='toolbar',title=self.draft.delay==0 and 'Start now' or (self.draft.delay and ('Starts in '..self.draft.delay..' minutes') or 'Custom UTC start'),actions={button('delay:0','Now'),button('delay:15','In 15 min'),button('delay:30','In 30 min')}}
      api.field(rows,'camp.starts','Start UTC',self.draft.starts,'Optional custom UTC: YYYY-MM-DDTHH:MM:SSZ')
      rows[#rows+1]={kind='toolbar',title='Attendance rules: '..self.draft.policy,actions={button('policy:LG','LG event'),button('policy:EXPO','Expo camp'),button('policy:NONE','No DKP')}}
      text(rows,'Choose the wallet that receives reviewed attendance DKP:')
      for _,pool in ipairs(self.state.pools or {}) do rows[#rows+1]={kind='toolbar',title=pool.name,actions={button('pool:'..pool.id,self.draft.poolId==pool.id and 'Selected' or 'Select')}} end
      local r=(self.state.policies and self.state.policies[self.draft.policy]) or self.state.rules
      if r then
        text(rows,tostring(r.intervalMinutes)..'-minute periods, '..tostring(r.responseMinutes)..'-minute responses / '..tostring(r.attendancePoints)..' DKP each, up to '..tostring(r.attendanceCap or 'no limit on')..' credited periods per member. Checks continue until the camp ends.')
        text(rows,'Early: '..tostring(r.earlyPoints)..' / kill: '..tostring(r.killPoints)..' / camp maximum: '..tostring(r.maxPoints or 'no cap')..' DKP.')
        text(rows,'Starting now gives no early bonus. Schedule at least '..tostring(r.earlyOpenMinutes)..' minutes ahead for the early check.')
      else text(rows,'Rules unavailable. Refresh before starting.') end
      if r and r.earlyPoints>0 then text(rows,'Announce the start to members. Early credit requires joining and responding before start minus '..tostring(r.earlyCloseMinutes)..' minutes, and remaining for the start.') end
      if self.review then text(rows,'Reviewed start: '..tostring(self.review.payload.startsAt or 'Immediately after confirmation')) end
      rows[#rows+1]={kind='toolbar',actions={button('cancel','Cancel'),button(self.review and 'confirm-start' or 'review-start',self.review and 'Confirm start' or 'Review start')}}
      return rows
    end
    if not c then
      text(rows,'Join an active camp to receive checks. Officers can start an unscheduled or planned camp.')
      if manage then rows[#rows+1]={kind='toolbar',actions={button('new','Start camp')}} end
      for _,entry in ipairs(self.state.camps or {}) do rows[#rows+1]={kind='banner',title=entry.targetName,subtitle=entry.status,action=button('view:'..entry.id,'View camp')} end
      return rows
    end
    rows[#rows+1]={kind='banner',title=c.targetName,subtitle=c.status..' / '..(c.myJoined and 'Joined' or 'Not joined')}
    rows[#rows+1]={kind='toolbar',actions={button('list','All camps')}}
    if self.review and self.review.kind=='post' then
      local total=0
      for _,p in ipairs(c.participants or {}) do text(rows,p.name..': '..tostring(p.proposedDkp or 0)..' DKP');total=total+(p.proposedDkp or 0) end
      text(rows,'Post '..tostring(total)..' DKP to this session wallet? Verify attendance and exceptions first. Points become spendable.')
      api.field(rows,'camp.reason','Review note',self.review.reason,'What did you verify? At least 8 characters')
      rows[#rows+1]={kind='toolbar',actions={button('cancel','Cancel'),button('confirm-post','Confirm and post DKP')}};return rows
    end
    if self.review and self.review.kind=='exception' then
      local r=self.review
      local name='Selected member';for _,p in ipairs(c.participants or {}) do if p.membershipId==r.membershipId then name=p.name;break end end
      text(rows,'Officer correction for '..name..'. Select the period and document the exception.')
      for _,ch in ipairs(c.checks or {}) do rows[#rows+1]={kind='toolbar',title=ch.checkNumber==0 and 'Early check' or 'Period '..ch.checkNumber,actions={button('check:'..ch.checkNumber,r.checkNumber==ch.checkNumber and 'Selected' or 'Select')}} end
      api.field(rows,'camp.checkNumber','Period',tostring(r.checkNumber or ''),'Period number, 0 early, -1 kill (ended kills only)')
      api.field(rows,'camp.reason','Reason',r.reason,'Scout assignment, transfer or correction; at least 8 characters')
      rows[#rows+1]={kind='toolbar',title=r.action,actions={button('grant','Mark eligible'),button('deny','Exclude period')}}
      rows[#rows+1]={kind='toolbar',actions={button('cancel','Cancel'),button('confirm-exception','Record correction')}};return rows
    end
    if self.review and self.review.kind=='leave' then
      text(rows,'Leave this session? Recorded responses remain. Leaving forfeits participation in future checks and the kill bonus.')
      rows[#rows+1]={kind='toolbar',actions={button('cancel','Cancel'),button('confirm-leave','Confirm leave')}};return rows
    end
    if self.review and self.review.kind=='end' then
      text(rows,'End as '..self.review.outcome..'. Review participants before ending. No kill is detected automatically.')
      if self.review.outcome=='KILLED' then
        text(rows,'Select only members who participated in the kill:')
        for _,p in ipairs(c.participants or {}) do if not p.leftAtMs then rows[#rows+1]={kind='toolbar',title=p.name,actions={button('kill:'..p.membershipId,self.selected[p.membershipId] and 'Selected' or 'Include')}} end end
      end
      rows[#rows+1]={kind='toolbar',actions={button('cancel','Cancel'),button('confirm-end','End session')}};return rows
    end
    local rc=c.readyCheck
    if rc and rc.open and rc.closesAtMs>ms() then
      text(rows,'Availability check: '..countdown(rc.closesAtMs)..' remaining. No DKP; scheduled checks are unchanged.')
      if c.myJoined and not rc.myResponse then rows[#rows+1]={kind='toolbar',actions={button('ready-now','Ready now'),button('unavailable-now','Unavailable')}}
      elseif rc.myResponse then text(rows,'Your availability: '..rc.myResponse) end
      if manage then for _,r in ipairs(rc.responses or {}) do
        for _,p in ipairs(c.participants or {}) do if p.membershipId==r.membershipId then text(rows,p.name..': '..(r.response or 'No response')) end end
      end end
    elseif manage and c.status=='ACTIVE' then rows[#rows+1]={kind='toolbar',actions={button('ready-start','Ready check now')}} end
    local check=opencheck()
    if check then
      rows[#rows+1]={kind='banner',opaque=true,title='Confirm attendance',accent='info',subtitle=countdown(check.closesAtMs)..' to respond. Confirm you were present and available for this period.',action=button('ready','Present and ready'),secondary_action=button('afk','AFK / unavailable')}
    end
    for _,ch in ipairs(c.checks or {}) do
      local closed=c.status~='ACTIVE' or ch.status=='CLOSED'
      local status=ch.response or (closed and 'Closed / no response' or latejoin(c,ch) and 'Joined after period began' or ms()>=ch.closesAtMs and 'No response' or ms()>=ch.opensAtMs and 'Open' or 'Upcoming')
      text(rows,(ch.checkNumber==0 and 'Early check' or 'Period '..ch.checkNumber)..': '..status..(not closed and ms()<ch.opensAtMs and (' / opens in '..countdown(ch.opensAtMs)) or ''))
    end
    if c.status=='ACTIVE' then rows[#rows+1]={kind='toolbar',actions={button(c.myJoined and 'leave' or 'join',c.myJoined and 'Leave camp' or 'Join camp')}} end
    text(rows,c.postedAtMs and 'Posted points (see ledger for corrections)' or 'Estimated points (not spendable)')
    for _,p in ipairs(c.participants or {}) do
      rows[#rows+1]={kind='toolbar',title=p.name..': '..tostring(c.postedAtMs and p.earnedDkp or p.proposedDkp or 0)..(c.postedAtMs and ' DKP posted' or ' DKP estimated')..(p.leftAtMs and ' / Left' or ''),actions=manage and not c.postedAtMs and {button('exception:'..p.membershipId,'Correct')} or {}}
      if manage then
        local answers={};for _,r in ipairs(p.responses or {}) do answers[#answers+1]=(r.checkNumber==-1 and 'Kill' or r.checkNumber==0 and 'Early' or '#'..r.checkNumber)..' '..r.response..(r.settled and ' settled' or ' pending') end
        text(rows,#answers>0 and table.concat(answers,' / ') or 'No responses yet')
      end
    end
    if manage and c.status=='ACTIVE' then rows[#rows+1]={kind='toolbar',actions={button('end:KILLED','Killed'),button('end:MISSED','Missed claim'),button('end:ENDED','End without kill')}} end
    if manage and c.status~='ACTIVE' and not c.postedAtMs and c.rules and c.rules.observationOnly==false then rows[#rows+1]={kind='toolbar',actions={button('review-post','Review and post DKP')}} end
    return rows
  end
  return self
end
return M
