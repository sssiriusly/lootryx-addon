-- Recruitment presentation and explicit website actions, shared by both loaders.
local M={detail=nil,feedback=nil}
local roles={'ANY','TANK','HEALER','SUPPORT','DPS'}
local function role_label(role) return ({ANY='Any role',TANK='Tank',HEALER='Healer',SUPPORT='Support',DPS='DPS'})[role] or 'Any role' end
function M.new(api)
  local composer=api.composer
  local self={detail=nil,feedback=nil,invites=nil,character='',join_role='ANY',request=api.request,generation=0}
  local function read(id)
    local generation=self.generation
    self.detail_id=id
    self.party_only=false;self.more=false;self.confirm=nil;self.contact=false
    if not self.detail or self.detail.id~=id then self.character='';self.join_role='ANY' end
    if self.detail and self.detail.id~=id then self.detail=nil end
    local reply,err=api.request('/party-finder/detail',{listingId=id})
    if generation~=self.generation then return end
    if reply and type(reply.listing)=='table' then
      self.detail=reply.listing;self.character=self.detail.characterName or self.character
      if type(self.detail.openRoles)=='table' and not composer.matches('',nil,self.join_role,self.detail.openRoles) then
        for _,role in ipairs(roles) do if (tonumber(self.detail.openRoles[role]) or 0)>0 then self.join_role=role;break end end
      end
      if api.observe_listing then api.observe_listing(self.detail) end;self.feedback=nil;self.stale=false
    else self.stale=true;self.feedback=err or "Could not read this listing. Please retry." end
  end
  function self.action(id)
    local generation=self.generation
    if self.stale and (id:sub(1,9)=='pfaction:' and id~='pfaction:refresh' or id:sub(1,6)=='pfask:' or id:sub(1,11)=='pf:confirm:') then
      self.feedback='Refresh this listing before making changes.';api.redraw();return true
    end
    if id:sub(1,12)=='pf:joinrole:' then
      local selected=id:sub(13);for _,role in ipairs(roles) do if selected==role then self.join_role=role end end
    elseif id=='pf:edit' and self.detail and self.detail.isMine and api.edit then
      api.edit(self.detail);return true
    elseif id=='pf:recruit' and api.recruit then
      api.recruit();return true
    elseif id=='pf:create-recruitment' and api.create then
      api.create();return true
    elseif id=='pf:contact' and self.detail then self.contact=true;self.feedback=nil
    elseif id=='pf:party' then
      self.return_detail=self.detail and self.detail.id or nil
      self.return_record=self.detail
      self.party_only=true;self.detail=nil;self.detail_id=nil;self.invites=nil;self.feedback=nil
    elseif id:sub(1,8)=='prefill:' then
      local action,name=id:sub(9):match('^([^:]+):(.+)$')
      action=action or id:sub(9);name=name or self.character
      if action=='kick' then
        local present=false
        for _,member in ipairs(api.party()) do if member.own_party and member.name==name then present=true end end
        if not present then self.feedback='That character is no longer in your party.';api.redraw();return true end
      end
      local ok,message=api.prefill(action,name);self.feedback=message
    elseif id=='pf:more' then self.more=not self.more;self.confirm=nil
    elseif id=='pf:cancel-review' then self.confirm=nil;self.more=false
    elseif id:sub(1,11)=='pf:confirm:' and self.detail then
      local action=id:sub(12)
      if action~=self.confirm then return false end
      self.confirm=nil
      return self.action('pfaction:'..action..':confirmed')
    elseif id=='pf:back' then
      self.generation=self.generation+1
      if self.contact then self.contact=false;self.feedback=nil
      elseif self.party_only and self.return_detail then self.detail=self.return_record;self.detail_id=self.return_detail;self.return_detail=nil;self.return_record=nil;self.party_only=false;self.feedback=nil
      else self.party_only=false;self.detail=nil;self.detail_id=nil;self.invites=nil;self.feedback=nil;self.more=false;self.confirm=nil;self.return_detail=nil end
    elseif id=='pf:retry-detail' and self.detail_id then read(self.detail_id)
    elseif id=='pf:inbox' then
      self.party_only=false;self.detail_id=nil
      local reply,err=api.request('/party-finder/invites',{})
      if generation~=self.generation then return true end
      self.invites_failed=not (reply and type(reply.invites)=='table')
      self.invites=not self.invites_failed and reply.invites or {};self.detail=nil
      if not self.invites_failed and api.observe_invites then api.observe_invites(self.invites) end
      self.feedback=self.invites_failed and (err or 'Could not read invitations. Please retry.') or nil
    elseif id:sub(1,9)=='pfdetail:' then read(id:sub(10))
    elseif id:sub(1,10)=='pfrespond:' then
      local action,inviteId=id:sub(11):match('^([^:]+):(.+)$')
      local reply,err=api.request('/party-finder/invite-response',{inviteId=inviteId,action=action})
      if generation~=self.generation then return true end
      self.feedback=reply and 'Invitation updated.' or err
      if reply then
        local remaining={}
        for _,invite in ipairs(self.invites or {}) do if invite.id~=inviteId then remaining[#remaining+1]=invite end end
        self.invites=remaining;api.refresh()
        if action=='accept' and type(reply.listing)=='table' then
          self.invites=nil;self.detail=reply.listing;self.detail_id=self.detail.id;self.character=self.detail.characterName or ''
          if api.observe_listing then api.observe_listing(self.detail) end
          self.feedback='Joined recruitment. Your game party is separate.'
        end
      end
    elseif id:sub(1,6)=='pfask:' and self.detail then
      local reply,err=api.request('/party-finder/action',{listingId=id:sub(7),action='invite',targetListingId=self.detail.id,role=self.detail.role or 'ANY'})
      if generation~=self.generation then return true end
      self.feedback=reply and 'Recruitment invitation sent.' or err
    elseif id:sub(1,9)=='pfaction:' and self.detail then
      local action=id:sub(10)
      if action=='close' or action=='leave' then
        self.confirm=action;api.redraw();return true
      end
      action=action:gsub(':confirmed$','')
      if action=='join' then
        local reply,err=api.request('/party-finder/join',{listingId=self.detail.id,role=self.join_role})
        if generation~=self.generation then return true end
        if reply then read(self.detail.id);self.feedback='Joined the Lootryx roster. Your game party is separate.';api.refresh() else self.feedback=err end
      elseif action=='refresh' then read(self.detail.id)
      else
        local reply,err=api.request('/party-finder/action',{listingId=self.detail.id,action=action})
        if generation~=self.generation then return true end
        if reply then
          if action=='close' or action=='leave' then self.detail=nil;self.detail_id=nil;api.refresh() else read(self.detail.id) end
          self.feedback='Recruitment updated.'
        else self.feedback=err end
      end
    else return false end
    api.redraw();return true
  end
  function self.leave()
    self.generation=self.generation+1
    self.party_only=false;self.detail=nil;self.detail_id=nil;self.invites=nil;self.feedback=nil
    self.more=false;self.confirm=nil;self.return_detail=nil;self.return_record=nil;self.contact=false
  end
  local function action(id,label) return {id=id,label=label,variant=id=='pfaction:join' and 'primary' or (id:sub(1,11)=='pf:confirm:' and 'danger' or 'secondary')} end
  local function party_count()
    local n=0;for _,member in ipairs(api.party()) do if member.own_party then n=n+1 end end;return n
  end
  local function add_party(rows)
    rows[#rows+1]={kind='pagehead',title='Your game party',subtitle='Only your game party leader can kick members.'}
    rows[#rows+1]={kind='text',text='Commands are prepared for you to review and send manually.'}
    for _,member in ipairs(api.party()) do if member.own_party and type(member.name)=='string' then
      local is_self=api.self_name and member.name==api.self_name()
      rows[#rows+1]={title=member.name..(is_self and ' (You)' or ''),subtitle=(api.zone_name and api.zone_name(member.zone_id)) or 'Location unavailable',art='alliance',
        action=not is_self and action('prefill:tell:'..member.name,'Prepare Tell') or nil,
        secondary_action=not is_self and action('prefill:kick:'..member.name,'Prepare kick') or nil}
    end end
    if party_count()==0 then rows[#rows+1]={kind='banner',title='No party data available',subtitle='Your client party will appear here when available.'} end
  end
  function self.rows()
    local rows={{kind='toolbar',fit_content=true,actions={action('pf:back',(self.contact or (self.party_only and self.return_detail)) and 'Back to recruitment' or 'Back to listings')}}}
    if self.feedback then rows[#rows+1]={kind='toolbar',title=self.feedback} end
    if self.party_only then add_party(rows);return rows end
    if self.invites then
      rows[#rows+1]={kind='pagehead',title='Recruitment invitations',subtitle='Accept a place on the Lootryx roster. Your game party is separate.'}
      rows[#rows+1]={kind='toolbar',actions={action('pf:inbox',self.invites_failed and 'Retry' or 'Refresh')}}
      if self.invites_failed then return rows end
      for _,invite in ipairs(self.invites) do
        local listing=invite.listing or {};local host=listing.hostName or listing.host
        if type(host)=='table' then host=host.name end
        local available=not listing.status or listing.status=='OPEN'
        if listing.memberCount and listing.maxSize and listing.memberCount>=listing.maxSize then available=false end
        rows[#rows+1]={title=invite.listing and (invite.listing.contentName or invite.listing.comment or 'Party invitation') or 'Party invitation',tag='LFG',
          subtitle='Host: '..(host or 'Unknown')..' / '..role_label(invite.role)..' / '..(listing.category or 'Activity unspecified'),
          action=available and action('pfrespond:accept:'..invite.id,'Accept') or nil,secondary_action=action('pfrespond:decline:'..invite.id,'Decline')}
        if listing.id then rows[#rows+1]={kind='toolbar',title=available and ('Lootryx roster: '..tostring(listing.memberCount or '?')..' / '..tostring(listing.maxSize or '?')..' places') or 'Invitation unavailable: recruitment is full or closed',actions={action('pfdetail:'..listing.id,'View details')}} end
      end
      if #self.invites==0 then rows[#rows+1]={kind='banner',title='No pending invitations',subtitle='New recruitment invitations will appear here.'} end
      return rows
    end
    local d=self.detail
    if not d then
      if self.detail_id then rows[#rows+1]={kind='toolbar',title='Listing unavailable',actions={action('pf:retry-detail','Retry')}} end
      return rows
    end
    if self.contact then
      rows[#rows+1]={kind='pagehead',title='Message '..(d.host or 'host'),subtitle='Prepare a Tell, then review and send it yourself.'}
      if self.character=='' then rows[#rows+1]={kind='text',text='Enter their game name. Account names may differ.'} end
      if api.contact_field then api.contact_field(rows,self.character) end
      rows[#rows+1]={kind='toolbar',dock=true,title='Your game party is unchanged',actions={action('prefill:tell','Prepare Tell')}}
      return rows
    end
    local ready=0;for _,member in ipairs(d.roster or {}) do if member.status=='READY' then ready=ready+1 end end
    local heading=d.contentName or (d.mode=='LFG' and ((d.host or 'Player')..' is looking for a group') or ((d.host or 'Party')..' recruitment'))
    local sub={};for _,value in ipairs({d.category or '',d.hostJob or '',d.zone or '',d.comment or ''}) do if value~='' then sub[#sub+1]=value end end
    rows[1].actions[#rows[1].actions+1]=action('pfaction:refresh','Refresh')
    if d.isMine or d.isMember then rows[1].actions[#rows[1].actions+1]=action('pf:more','More') end
    rows[#rows+1]={kind='pagehead',title=heading,subtitle=table.concat(sub,' / ')}
    if self.stale then
      rows[#rows+1]={kind='banner',title='Cached listing, refresh unavailable',subtitle='Last known roster below. Refresh before joining or changing recruitment.',action=action('pf:retry-detail','Retry')}
      for _,member in ipairs(d.roster or {}) do rows[#rows+1]={title=member.name,subtitle=role_label(member.role),role_icon=member.role or 'ANY'} end
      return rows
    end
    if self.confirm then
      rows[#rows+1]={kind='banner',title=self.confirm=='close' and 'Close this listing?' or 'Leave this recruitment?',
        subtitle=self.confirm=='close' and 'Remove this listing from the board. Your game party is unchanged.' or 'Remove your Lootryx roster place. Your game party is unchanged.'}
      rows[#rows+1]={kind='toolbar',actions={action('pf:cancel-review','Cancel'),action('pf:confirm:'..self.confirm,self.confirm=='close' and 'Confirm close' or 'Confirm leave')}}
      return rows
    end
    if self.more then
      rows[#rows+1]={kind='toolbar',title='Listing options',actions={action('pf:cancel-review','Done'),action(d.isMine and 'pfaction:close' or 'pfaction:leave',d.isMine and (d.mode=='LFG' and 'Stop looking' or 'Close listing') or 'Leave recruitment')}}
    end
    local management
    if d.isMine and (d.status=='OPEN' or d.status=='FULL') then
      management={kind='toolbar',actions={api.edit and action('pf:edit',d.mode=='LFG' and 'Edit availability' or 'Edit recruitment') or nil,api.recruit and d.mode=='LFM' and action('pf:recruit','Recruit more') or nil}}
    end
    local status=({OPEN='Recruiting',FULL='Full',CLOSED='Closed',EXPIRED='Expired'})[d.status] or 'Unknown'
    local summary=d.mode=='LFG' and role_label(d.role) or (tostring(d.memberCount or #(d.roster or {}))..' / '..tostring(d.maxSize or 6)..' places')
    if d.readyCheckStartedAt then summary=summary..' / '..ready..' ready' end
    local summary_cells={{title=status,value=summary,art='alliance'}}
    rows[#rows+1]={kind='metrics',items=summary_cells}
    local dock_actions={action('pf:party','My game party')}
    if d.mode=='LFM' and not d.isMine then dock_actions[#dock_actions+1]=action('pf:contact','Message host') end
    if d.mode=='LFM' then
      local needs=composer.open_summary(d.openRoles)
      if needs then
        local cells=summary_cells;for _,role in ipairs(roles) do local count=tonumber(d.openRoles[role]) or 0;if count>0 then cells[#cells+1]={title='Need '..role_label(role),value=tostring(count)..' '..role_label(role),icon='role_'..role:lower()} end end
        if #cells>4 then local extra={};while #cells>4 do table.insert(extra,1,table.remove(cells)) end;rows[#rows+1]={kind='metrics',items=extra} end
      end
      local actions={}
      local open=d.status=='OPEN'
      local full=(tonumber(d.memberCount) or #(d.roster or {})) >= (tonumber(d.maxSize) or 6)
      if open and not full and not d.isMember then
        local options={};for _,role in ipairs(roles) do if type(d.openRoles)~='table' or composer.matches('',nil,role,d.openRoles) then options[#options+1]={id='pf:joinrole:'..role,label=role_label(role),icon='role_'..role:lower(),selected=self.join_role==role} end end
        rows[#rows+1]={kind='choices',compact=true,options=options}
        actions[#actions+1]=action('pfaction:join','Join recruitment')
      end
      local active=open or d.status=='FULL'
      if active and d.isMine then actions[#actions+1]=action('pfaction:ready-check','Ready check') end
      if active and d.isMember and d.readyCheckStartedAt then actions[#actions+1]=action('pfaction:ready','I am ready') end
      if not active or (full and not d.isMember) then rows[#rows+1]={kind='banner',title=not active and 'Recruitment is closed' or 'Recruitment is full',subtitle='Refresh to check for availability.'} end
      for _,item in ipairs(actions) do dock_actions[#dock_actions+1]=item end
      rows[#rows+1]={kind='header',title='Recruitment roster'}
      for _,member in ipairs(d.roster or {}) do rows[#rows+1]={title=member.name,subtitle=(member.role or 'ANY')..' | '..(({JOINED='Joined',READY='Ready'})[member.status or 'JOINED'] or 'Joined'),tag=member.isHost and 'HOST' or 'LFG',role_icon=member.role or 'ANY',meta=member.isHost and 'HOST' or nil} end
      if #(d.roster or {})==0 then rows[#rows+1]={title='No roster members returned',tag='INFO'} end
      if d.isMine and self.more then rows[#rows+1]={kind='text',text='Members leave their own roster place. Host removal is not supported. Game party actions are separate.'} end
    end
    if not d.isMine and d.mode=='LFG' then
      rows[#rows+1]={kind='header',title='Contact in game'}
      if self.character=='' then rows[#rows+1]={kind='toolbar',title='Enter their game name: account names may differ.'} end
      if api.contact_field then api.contact_field(rows,self.character) end
      rows[#rows+1]={kind='toolbar',title='Review and send manually',actions={action('prefill:tell',d.mode=='LFG' and 'Message player' or 'Message host'),d.mode=='LFG' and action('prefill:invite','Prepare game invite') or nil}}
    end
    if d.mode=='LFG' and not d.isMine then
      rows[#rows+1]={kind='header',title='Invite to your recruitment'}
      local found=false
      for _,listing in ipairs(api.listings()) do if listing.isMine and listing.mode=='LFM' then found=true;rows[#rows+1]={title=listing.contentName or listing.comment or 'Your recruiting party',tag='LFG',action=action('pfask:'..listing.id,'Invite')} end end
      if not found then rows[#rows+1]={title='Create recruitment to invite this player',tag='LFG',action=api.create and action('pf:create-recruitment','Create recruitment') or nil} end
    end
    if management then rows[#rows+1]=management end
    rows[#rows+1]={kind='toolbar',dock=true,actions=dock_actions}
    return rows
  end
  return self
end
return M
