-- Explicit Lootryx attendance lifecycle. Never queues captures or controls the game.
local M={}
local function trim(value) return tostring(value or ''):match('^%s*(.-)%s*$') end
local function button(id,label,variant) return {id='attendance:'..id,label=label,variant=variant} end
local function text(rows,value) rows[#rows+1]={kind='text',text=value} end
local function same_names(a,b)
  return table.concat(a.characters or {},'\n')==table.concat(b.characters or {},'\n')
    and table.concat(a.assertedCharacters or {},'\n')==table.concat(b.assertedCharacters or {},'\n')
end
function M.new(api)
  local self={state=nil,feedback=nil,draft=nil,review=nil,preview=nil,next_poll=0,failures=0}
  local observed=nil
  local function now() return api.now and api.now() or os.time() end
  self.next_poll=now()+math.max(15,tonumber(api.interval and api.interval()) or 30)
  local function redraw() if api.redraw then api.redraw() end end
  local function notify(message) if api.notify then api.notify(message) end end
  local function active()
    local event=self.state and self.state.activeEvent
    if type(event)~='table' then return nil end
    if (tonumber(event.checkInOpenUntilMs) or 0)<=now()*1000 then return nil end
    return event
  end
  local function wallet(event)
    local state=self.state or {}
    local id=event and event.poolId or state.defaultPoolId
    if event and not event.poolId then
      for _,entry in ipairs(state.types or {}) do if entry.type==event.type then id=entry.poolId;break end end
    end
    for _,pool in ipairs(state.pools or {}) do if pool.id==id then return id,pool.name end end
    return id,'Unknown wallet'
  end
  local function accept(reply)
    self.state=reply;self.failures=0
    local current=active()
    local key=current and (current.id..':'..tostring(current.checkInOpenUntilMs)) or nil
    if observed and (not current or observed.id~=current.id) then notify('Attendance check-in closed: '..observed.title) end
    if current and (not observed or observed.id~=current.id) then
      notify('Attendance check-in open: '..current.title)
      if api.opened then api.opened(current.id) end
    elseif current and observed.key~=key then notify('Attendance check-in updated: '..current.title) end
    observed=current and {id=current.id,key=key,title=current.title} or nil
    if self.preview and (not current or self.preview.eventId~=current.id) then self.preview=nil end
    self.next_poll=now()+math.max(5,tonumber(api.interval and api.interval()) or 30)
  end
  local function read(quiet)
    local reply,err=api.request('/attendance/state',{})
    if reply and reply.ok==true and type(reply.canManage)=='boolean' and type(reply.events)=='table' then
      accept(reply);if not quiet then self.feedback=nil end
      return true
    end
    self.state=nil;self.preview=nil;self.review=nil;self.failures=self.failures+1
    self.next_poll=now()+math.min(300,math.max(5,tonumber(api.interval and api.interval()) or 30)*2^math.min(self.failures,4))
    self.feedback='Attendance status unavailable. '..tostring(err or 'Refresh to retry.')
    return false
  end
  local function snapshot()
    local result=api.snapshot()
    if type(result)~='table' or type(result.characters)~='table' or #result.characters==0 then
      self.feedback='No attendance saved. No names are available to capture.';return nil
    end
    return result
  end
  local function create_payload()
    local draft=self.draft or {}
    local title,category=trim(draft.title),trim(draft.type)
    local points=tonumber(draft.points)
    if title=='' or #title>120 then return nil,'Enter an event title (1 to 120 characters).' end
    if category=='' or #category>40 then return nil,'Enter an event type (1 to 40 characters).' end
    if not points or points<1 or points>1000 or points~=math.floor(points) then return nil,'Enter whole-number points from 1 to 1000.' end
    local poolId=wallet({type=category})
    if not poolId then return nil,'Wallet unavailable. Refresh attendance before starting.' end
    draft.requestId=draft.requestId or ('attendance-'..tostring(now())..'-'..tostring({}):gsub('[^%w]',''))
    return {requestId=draft.requestId,title=title,type=category,pointValue=points,expectedPoolId=poolId}
  end
  function self.reset()
    self.state=nil;self.feedback=nil;self.draft=nil;self.review=nil;self.preview=nil
    self.capture_feedback=nil;self.capture_at=nil
    self.next_poll=now()+math.max(15,tonumber(api.interval and api.interval()) or 30);self.failures=0;observed=nil
  end
  function self.cancel_review() self.review=nil end
  function self.set_field(name,value)
    name=tostring(name):gsub('^attendance%.','')
    if self.draft and (name=='title' or name=='type' or name=='points') then
      if self.draft[name]~=value then self.draft.requestId=nil end
      self.draft[name]=value;self.review=nil;self.feedback=nil
      return true
    end
    return false
  end
  function self.field_value(name) return self.draft and self.draft[tostring(name):gsub('^attendance%.','')] or '' end
  function self.capture_target()
    local event=active();return event and event.id or nil
  end
  function self.refresh_for_capture()
    local ok=read(true)
    if api.redraw then api.redraw(false) end
    return ok
  end
  function self.poll(timestamp)
    if api.enabled and not api.enabled() then return end
    if (timestamp or now())<self.next_poll or self.review then return end
    read(true);if api.redraw then api.redraw(false) end;return true
  end
  function self.action(id)
    if type(id)~='string' or id:sub(1,11)~='attendance:' then return false end
    local action=id:sub(12)
    if action=='open' or action=='refresh' then self.review=nil;read(false)
    elseif action=='new' and self.state and self.state.canManage and not active() then
      self.draft=self.draft or {title='',type='',points=''};self.feedback=nil;self.review=nil
    elseif action=='cancel' then self.draft=nil;self.review=nil;self.preview=nil;self.feedback=nil
    elseif action=='cancel-review' then self.review=nil
    elseif action:sub(1,5)=='type:' and self.draft and self.state and self.state.canManage then
      local selected=(self.state.types or {})[tonumber(action:sub(6)) or 0]
      if selected then
        self.draft.type=selected.type;self.draft.points=selected.pointValue and tostring(selected.pointValue) or ''
        self.draft.requestId=nil;self.review=nil;self.feedback=nil
      end
    elseif action=='review-create' and self.state and self.state.canManage and not active() then
      local payload,err=create_payload();self.feedback=err
      if payload then self.review={kind='create',payload=payload,title=payload.title} end
    elseif action:sub(1,6)=='start:' and self.state and self.state.canManage and not active() then
      for _,event in ipairs(self.state.events or {}) do
        if event.id==action:sub(7) then
          local poolId=wallet(event)
          if poolId and type(event.revision)=='string' then self.review={kind='start',title=event.title,event=event,payload={eventId=event.id,expectedPoolId=poolId,expectedRevision=event.revision}}
          else self.feedback='Event review data unavailable. Refresh attendance before starting.' end
          break
        end
      end
    elseif action=='close' and self.state and self.state.canManage and active() then
      local event=active()
      if type(event.revision)=='string' then self.review={kind='close',title=event.title,payload={eventId=event.id,expectedRevision=event.revision}}
      else self.feedback='Event review data unavailable. Refresh attendance before closing.' end
    elseif action=='review-confirm' and self.review and self.state and self.state.canManage then
      local review=self.review
      local path=review.kind=='create' and '/attendance/create-start' or ('/attendance/'..review.kind)
      local reply,err=api.request(path,review.payload)
      if reply and reply.ok==true and type(reply.canManage)=='boolean' and type(reply.events)=='table'
        and type(reply.eventId)=='string' and (review.kind=='create' or reply.eventId==review.payload.eventId) then
        accept(reply);self.review=nil;self.draft=nil;self.preview=nil
        self.feedback=review.kind=='close' and 'Check-in closed. Existing attendance is kept. No scoring was triggered.'
          or (active() and 'Check-in is open. Preview the roster before capturing.' or 'Event request completed. Check-in is now closed; refresh before further action.')
      else
        self.feedback=tostring(err or 'Request failed. No success was confirmed. Retry with the same reviewed details.')
        -- Preserve the draft and request identity after uncertain transport results.
      end
    elseif action=='preview' and active() then
      local payload=snapshot()
      if payload then payload.eventId=active().id;self.preview=payload;self.feedback=nil end
    elseif action=='capture' and active() and self.preview then
      local payload=snapshot()
      if payload then
        payload.eventId=active().id
        if self.preview.eventId~=payload.eventId or not same_names(self.preview,payload) then
          self.preview=payload;self.feedback='Roster changed. Review the updated names, then capture again.'
        else
          local title=active().title
          local reply,err=api.request('/attendance/capture',payload)
          if reply and reply.ok==true and reply.eventId==payload.eventId and type(reply.recorded)=='number'
            and type(reply.matched)=='number' and type(reply.skipped)=='number'
            and reply.recorded>=0 and reply.recorded<=reply.matched and reply.skipped>=0 then
            self.preview=nil
            local recorded=tonumber(reply.recorded) or 0
            local known=math.max(0,(tonumber(reply.matched) or 0)-recorded)
            self.feedback='Attendance saved for '..title..': '..recorded..' new, '..known..' already present, '..tostring(reply.skipped or 0)..' unmatched. No DKP awarded.'
          else
            self.preview=nil;self.state=nil;self.review=nil
            self.feedback='Capture not confirmed. '..tostring(err or 'Refresh status and check attendance before retrying.')..' Nothing is queued for another event.'
          end
          self.capture_feedback=self.feedback;self.capture_at=now()*1000
        end
      end
    else return false end
    redraw();return true
  end
  function self.rows()
    local rows={{kind='toolbar',fit_content=true,title='Attendance',actions={button('refresh','Refresh'),button('back','Back')}}}
    if self.feedback then rows[#rows+1]={kind='text',text=self.feedback} end
    if not self.state then
      rows[#rows+1]={kind='banner',title='Refresh attendance to continue',subtitle='Capture waits for a known event.'}
      return rows
    end
    local event=active()
    if self.review then
      local r=self.review
      rows[#rows+1]={kind='banner',title=(r.kind=='close' and 'Close check-in: ' or 'Start check-in: ')..r.title}
      if r.kind=='close' then text(rows,'Stops new captures for this event. Existing attendance remains. Scoring is separate.')
      else
        local policy=r.event or {type=r.payload.type,pointValue=r.payload.pointValue}
        local _,name=wallet(policy)
        text(rows,tostring(policy.type)..' / '..name..' / '..tostring(policy.pointValue)..' base points')
        text(rows,'Check-in: '..tostring(self.state.windowMinutes)..' minutes. '..(r.kind=='create' and 'Event starts now. No extra flat payout.' or 'Uses the selected event settings.'))
        text(rows,'Starting check-in does not award DKP. Capture attendance next, then review scoring on the website.')
      end
      rows[#rows+1]={kind='toolbar',dock=true,actions={button('cancel-review','Cancel review'),button('review-confirm',r.kind=='close' and 'Close check-in' or 'Start & open check-in',r.kind=='close' and 'danger' or 'primary')}}
    elseif self.draft and not event then
      text(rows,'Unscheduled run starts now. Event type determines its DKP wallet.')
      api.field(rows,'attendance.title','Title',self.draft.title,'What are you doing?')
      local options={};for index,entry in ipairs(self.state.types or {}) do options[#options+1]={id='attendance:type:'..index,label=entry.type,selected=self.draft.type==entry.type} end
      if #options>0 then rows[#rows+1]={kind='choices',compact=true,options=options}
      else api.field(rows,'attendance.type','Type',self.draft.type,'Event category') end
      api.field(rows,'attendance.points','Base points',self.draft.points,'Officer override, whole number 1 to 1000')
      if trim(self.draft.type)=='' then text(rows,'Choose an event type to see its wallet and suggested base points.')
      else local _,name=wallet({type=trim(self.draft.type)});text(rows,'Mapped wallet: '..name..' / Check-in: '..tostring(self.state.windowMinutes)..' minutes') end
      rows[#rows+1]={kind='toolbar',dock=true,actions={button('cancel','Cancel'),button('review-create','Review event','primary')}}
    elseif event then
      local _,name=wallet(event)
      local seconds=math.max(0,math.ceil(event.checkInOpenUntilMs/1000-now()))
      rows[#rows+1]={kind='banner',art='calendar',title=event.title,subtitle='Check-in is open'}
      rows[#rows+1]={kind='metrics',items={{title='DKP track',value=name,art='coins'},{title='Time remaining',value=math.ceil(seconds/60)..' min',art='clock'},{title='Roster preview',value=self.preview and tostring(#self.preview.characters)..' players' or 'Not reviewed',art='alliance'}}}
      if self.preview then
        rows[#rows+1]={kind='header',title='Names to report ('..#self.preview.characters..'):'}
        local line={}
        for index,name in ipairs(self.preview.characters) do
          line[#line+1]=name
          if #line==5 or index==#self.preview.characters then text(rows,table.concat(line,', '));line={} end
        end
        if self.preview.assertedCharacters and #self.preview.assertedCharacters>0 then text(rows,'Manually included: '..table.concat(self.preview.assertedCharacters,', ')) end
      else text(rows,'Preview current alliance names, including your attendance adjustments. This cannot recover a past roster.') end
      text(rows,'Capturing records attendance only. Review and score the event separately.')
      local actions={button('preview',self.preview and 'Refresh preview' or 'Preview roster')}
      if self.preview then actions[#actions+1]=button('capture','Capture attendance','primary') end
      rows[#rows+1]={kind='toolbar',actions={button('website','Website records'),self.state.canManage and button('close','Close check-in') or nil}}
      rows[#rows+1]={kind='toolbar',dock=true,actions=actions}
    else
      rows[#rows+1]={kind='text',text=self.state.canManage and 'No open check-in. Choose an event or start an unscheduled run.' or 'No open check-in. Ask an officer to start one, then refresh. RSVP does not record attendance.'}
      text(rows,'Missed an earlier run? Request late attendance on the website event page for officer review.')
      if self.state.canManage then
        for _,item in ipairs(self.state.events or {}) do
          local _,name=wallet(item)
          rows[#rows+1]={kind='banner',title=item.title,subtitle=tostring(item.type)..' / '..name,action=button('start:'..item.id,'Start check-in')}
        end
        if self.state.eventsMayBeTruncated then text(rows,'Showing a limited event list. Open the website for the complete calendar.') end
        rows[#rows+1]={kind='toolbar',dock=true,actions={button('website','Website events'),button('new','Start unscheduled event','primary')}}
      else
        rows[#rows+1]={kind='toolbar',dock=true,actions={button('website','Website events')}}
      end
    end
    return rows
  end
  return self
end
return M
