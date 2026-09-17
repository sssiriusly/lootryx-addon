-- Observe successful reads only. No gameplay writes; network scheduling stays with the host.
local M={}
function M.new(api)
  local self={targets={},snapshots={},retired={},retired_order={},invites={},invite_order={},index=0,last_party=0}
  local function emit(kind,text,id) api.notify(kind,text,id) end
  function self.party(now)
    if now-self.last_party<2 then return end
    self.last_party=now
    local current,own={},api.name()
    for _,member in ipairs(api.party() or {}) do
      if member.own_party and type(member.name)=='string' then current[member.name]=true end
    end
    if not own or not current[own] then self.party_baseline=nil;self.party_candidate=nil;return end
    local keys={};for name in pairs(current) do keys[#keys+1]=name end;table.sort(keys)
    local signature=table.concat(keys,',')
    if not self.party_baseline then self.party_baseline=current;self.party_signature=signature;return end
    if signature==self.party_signature then self.party_candidate=nil;return end
    if self.party_candidate~=signature then self.party_candidate=signature;return end
    for name in pairs(current) do if name~=own and not self.party_baseline[name] then emit('notify_party',name..' joined your game party.') end end
    for name in pairs(self.party_baseline) do if name~=own and not current[name] then emit('notify_party',name..' left your game party.') end end
    self.party_baseline=current;self.party_signature=signature;self.party_candidate=nil
  end
  function self.listing(d)
    if type(d)~='table' or type(d.id)~='string' or not (d.isMine or d.isMember) then return end
    local terminal=d.status~='OPEN' and d.status~='FULL'
    if self.retired[d.id] then
      if terminal then return end
      self.retired[d.id]=nil
      for i=#self.retired_order,1,-1 do if self.retired_order[i]==d.id then table.remove(self.retired_order,i) end end
    end
    local count=0;for _ in pairs(self.snapshots) do count=count+1 end
    if not self.snapshots[d.id] and count>=20 then return end
    self.targets[d.id]=true
    local old=self.snapshots[d.id]
    local roster={};local all_ready=#(d.roster or {})>0
    for _,member in ipairs(d.roster or {}) do
      local id=member.userId or member.name
      roster[id]=member
      if member.status~='READY' then all_ready=false end
      if old and not old.roster[id] and not member.isMine then emit('notify_recruitment',member.name..' joined your Lootryx recruitment.',d.id) end
    end
    if old then
      for id,member in pairs(old.roster) do if not roster[id] and not member.isMine then emit('notify_recruitment',member.name..' left your Lootryx recruitment.',d.id) end end
      if d.status~=old.status and d.status~='OPEN' then emit('notify_recruitment','Your Lootryx recruitment is '..tostring(d.status):lower()..'.',d.id) end
    end
    if d.readyCheckStartedAt and (not old or old.ready~=d.readyCheckStartedAt) then
      emit('notify_ready','Ready check started. Open your recruitment to respond.',d.id)
    end
    if d.readyCheckStartedAt and all_ready and (not old or not old.all_ready or old.ready~=d.readyCheckStartedAt) then
      emit('notify_ready','Everyone in your Lootryx recruitment is ready.',d.id)
    end
    self.snapshots[d.id]={roster=roster,status=d.status,ready=d.readyCheckStartedAt,all_ready=all_ready}
    if terminal then
      self.targets[d.id]=nil;self.snapshots[d.id]=nil;self.retired[d.id]=true
      self.retired_order[#self.retired_order+1]=d.id
      if #self.retired_order>200 then self.retired[table.remove(self.retired_order,1)]=nil end
    end
  end
  function self.invitations(invites)
    for _,invite in ipairs(invites) do
      if type(invite.id)=='string' and not self.invites[invite.id] then
        self.invites[invite.id]=true
        self.invite_order[#self.invite_order+1]=invite.id
        if #self.invite_order>200 then self.invites[table.remove(self.invite_order,1)]=nil end
        emit('notify_invites','New recruitment invitation. Open Find > Invitations.')
      end
    end
  end
  function self.poll(now)
    if not api.enabled() then return false end
    if not self.next_poll then self.next_poll=now+api.interval();return false end
    if now<self.next_poll then return false end
    self.next_poll=now+api.interval()*(self.backoff or 1)
    for _,listing in ipairs(api.listings() or {}) do
      local snapshot=self.snapshots[listing.id]
      if (listing.isMine or listing.isMember) and listing.id and not self.retired[listing.id] and (not snapshot or snapshot.status=='OPEN' or snapshot.status=='FULL') then self.targets[listing.id]=true end
    end
    local targets={};for id in pairs(self.targets) do targets[#targets+1]=id end;table.sort(targets)
    self.index=(self.index % (#targets+1))+1
    local id=targets[self.index]
    local reply=api.request(id and '/party-finder/detail' or '/party-finder/invites',id and {listingId=id} or {})
    local success=reply and (id and type(reply.listing)=='table' or not id and type(reply.invites)=='table')
    if success then
      self.backoff=1
      if id then
        if not (reply.listing.isMine or reply.listing.isMember) then self.targets[id]=nil;self.snapshots[id]=nil end
        self.listing(reply.listing);api.updated(reply.listing) else self.invitations(reply.invites) end
    else self.backoff=math.min(8,(self.backoff or 1)*2) end
    return true
  end
  return self
end
return M
