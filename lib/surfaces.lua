-- Presentation only. Reuses the existing action IDs and never performs I/O.
local M = { jobs_tab = 'current', tod_open = false, auction_tab = 'active', search={}, filters={}, find_counts={} }
local function head(title, subtitle, actions)
  return {kind='pagehead',title=title,subtitle=subtitle,actions=actions}
end
local function section(title) return {kind='header',title=title} end
local function metrics(items) return {kind='metrics',items=items} end
local function cards(out, items)
  for i=1,#items,2 do out[#out+1]={kind='cards',items={items[i],items[i+1]}} end
end
local function action(id,label) return {id=id,label=label,variant=(id=='post' or id=='auction' or id:sub(1,8)=='editbid:') and 'primary' or 'secondary'} end
local function copy(t) local out={};for k,v in pairs(t) do out[k]=v end;return out end
local function job(v) return v and (v.job..' '..v.level) or 'Unavailable' end
local function wallet_rows(out,dkp)
  if not dkp or not dkp.splitVisible then return end
  out[#out+1]=section('Your DKP wallets (separate balances)')
  local cells={}
  for _,w in ipairs(dkp.wallets or {}) do
    cells[#cells+1]={title=w.poolName or 'Unknown wallet',value=tostring(w.currentBalance or 0)..' DKP'}
    if #cells==3 then out[#out+1]=metrics(cells);cells={} end
  end
  if #cells>0 then out[#out+1]=metrics(cells) end
end
local function balance(dkp)
  if dkp and dkp.splitVisible then return 'By wallet above' end
  local value=dkp and (dkp.headline or dkp.balance)
  return type(value)=='number' and tostring(value)..' DKP' or 'Not fetched'
end
function M.action(id,tab)
  tab=tab or M.find_tab or 'lfg'
  M.filters[tab]=M.filters[tab] or {role='ALL',category='ALL'}
  local filter=M.filters[tab]
  if id=='surface:clear' then filter.role='ALL';filter.category='ALL';filter.activity_open=false;M.search[tab]='';return true end
  if id=='surface:filters' then filter.open=not filter.open;return true end
  if id=='surface:clearsearch' then M.search[tab]='';return true end
  if id=='surface:activity' then filter.activity_open=not filter.activity_open;return true end
  if id:sub(1,17)=='surface:category:' then filter.category=id:sub(18);filter.activity_open=false;return true end
  if id:sub(1,13)=='surface:role:' then filter.role=id:sub(14);return true end
  if id=='surface:current' or id=='surface:plans' then M.jobs_tab=id:sub(9);return true end
  if id=='surface:tod' then M.tod_open=true;return true end
  if id=='surface:windows' then M.tod_open=false;return true end
  if id=='surface:active' or id=='surface:results' then M.auction_tab=id:sub(9);return true end
  return false
end
function M.find(ctx,old)
  if ctx.focused then return old end
  local mine,others,extras=nil,{},{}
  for _,r in ipairs(old) do
    if r.action and r.action.id:sub(1,9)=='pfdetail:' then
      if r.tag=='YOURS' then mine=r else others[#others+1]=r end
    elseif r.kind~='toolbar' and (r.action or r.tag=='LOCK') then extras[#extras+1]=r end
  end
  local lfg=ctx.tab=='lfg'
  M.find_tab=ctx.tab
  M.filters[ctx.tab]=M.filters[ctx.tab] or {role='ALL',category='ALL'}
  local filter=M.filters[ctx.tab]
  local bar=copy(ctx.search_row or {action_id='focus:surface.search'})
  bar.kind='finderbar';bar.placeholder=lfg and 'Search name, role or activity' or 'Search party, role or activity'
  bar.actions={action('surface:filters',filter.open and 'Hide filters' or 'Filters')}
  if not mine then bar.actions[#bar.actions+1]=action('post',lfg and 'Post availability' or 'Recruit members') end
  local out={bar}
  local chips={}
  if filter.role~='ALL' then chips[#chips+1]=action('surface:role:ALL',filter.role..' x') end
  if filter.category~='ALL' then chips[#chips+1]=action('surface:category:ALL',filter.category..' x') end
  if (ctx.search_value or '')~='' then chips[#chips+1]=action('surface:clearsearch','Search x') end
  if #chips>0 then chips[#chips+1]=action('surface:clear','Clear all');out[#out+1]={kind='filterchips',actions=chips} end
  if filter.open then
    out[#out+1]={kind='toolbar',title='Activity',actions={action('surface:activity',filter.category=='ALL' and 'All activities' or filter.category)}}
    if filter.activity_open then
      local opts={}
      for _,v in ipairs({'ALL','EXP','MISSION','BCNM','MENTOR','CRAFT','OTHER'}) do opts[#opts+1]={id='surface:category:'..v,label=v,selected=filter.category==v} end
      out[#out+1]={kind='choices',compact=true,options=opts}
    end
    local opts={}
    for _,role in ipairs({'ALL','ANY','TANK','HEALER','SUPPORT','DPS'}) do
      opts[#opts+1]={id='surface:role:'..role,label=({ALL='All roles',ANY='Any',TANK='Tank',HEALER='Healer',SUPPORT='Support',DPS='DPS'})[role],icon=role~='ALL' and ('role_'..role:lower()) or nil,selected=filter.role==role}
    end
    out[#out+1]={kind='choices',compact=true,options=opts}
  end
  if mine then
    out[#out+1]={kind='toolbar',title=(lfg and 'Your availability: ' or 'Your recruitment: ')..(mine.subtitle or mine.badge or ''),actions={mine.action,action('pfwithdraw:'..mine.action.id:sub(10),lfg and 'Withdraw' or 'Close listing')}}
  end
  for _,listing in ipairs(ctx.hud and ctx.hud.pf and ctx.hud.pf.listings or {}) do
    if listing.isMember and not listing.isMine and listing.mode=='LFM' and listing.id then
      out[#out+1]={kind='toolbar',title='Joined: '..tostring(listing.host or 'Recruitment'),actions={action('pfdetail:'..listing.id,'View roster')}}
    end
  end
  if ctx.freshness and ctx.freshness.accent=='bad' then out[#out+1]={kind='toolbar',title=ctx.freshness.subtitle,accent='bad',actions={action('refresh_pf','Retry')}} end
  local matches=0
  local listings={}
  for _,listing in ipairs(ctx.hud and ctx.hud.pf and ctx.hud.pf.listings or {}) do if listing.id then listings[listing.id]=listing end end
  for _,r in ipairs(others) do
    local text=(tostring(r.title)..' '..tostring(r.subtitle)..' '..tostring(r.badge)..' '..tostring(r.role_icon or '')):lower()
    local raw=listings[r.action.id:sub(10)]
    if raw then text=text..' '..tostring(raw.hostJob or ''):lower() end
    local role_match=filter.role=='ALL' or r.role_icon==filter.role
    if ctx.role_matches then role_match=ctx.role_matches(raw and raw.role or r.role_icon,raw and raw.comment or r.subtitle,filter.role,raw and raw.openRoles) end
    if role_match and (filter.category=='ALL' or r.badge=='['..filter.category..']') and text:find((ctx.search_value or ''):lower(),1,true) then matches=matches+1;out[#out+1]=r end
  end
  local total=#others
  local shown=matches
  local loaded=ctx.hud and ctx.hud.pf~=nil
  local status=loaded and ('Showing '..shown..' of '..total..' other'..(lfg and (total==1 and ' player' or ' players') or (total==1 and ' party' or ' parties'))) or 'Listings not fetched yet'
  M.find_counts[ctx.tab]=status..(ctx.freshness and (' / '..ctx.freshness.title) or '')
  if not loaded then out[#out+1]={kind='banner',title='Refresh to load listings',subtitle='No results received yet. This does not mean the board is empty.'}
  elseif matches==0 then out[#out+1]={kind='banner',title=#others>0 and (lfg and 'No players match these filters' or 'No parties match these filters') or (lfg and 'No other players are looking right now' or 'No other parties are recruiting'),
    subtitle=#others>0 and 'Clear filters to see every listing on this tab.' or (mine and 'Your listing is visible above, even with filters applied.' or (lfg and 'Post availability, or browse Parties to join a group.' or 'Recruit members, or browse Players to invite someone.'))} end
  for _,r in ipairs(extras) do out[#out+1]=r end
  out[#out+1]={kind='toolbar',dock=true,actions={action('pf:party','My game party'),action('pf:inbox','Invitations'),action('refresh_pf','Refresh')}}
  return out
end
function M.home(ctx, old)
  local h=ctx.hud
  local out={head('Good to see you, '..ctx.name..'.',ctx.world..' / '..ctx.shell,{action('tab:me','Your character')})}
  local urgent={}
  for _,r in ipairs(old) do
    if r.tag=='CHECK IN' then
      r=copy(r);if r.tag=='CHECK IN' then r.title='CHECK IN: '..r.title end;urgent[#urgent+1]=r
    end
  end
  local soonest
  for _,a in ipairs(h.auctions or {}) do
    if a.id and type(a.endsAtMs)=='number' and (not soonest or a.endsAtMs<soonest.endsAtMs) then soonest=a end
  end
  if soonest and ctx.tier=='member' then
    local seconds=math.max(0,math.floor(soonest.endsAtMs/1000-(ctx.now or 0)))
    local remaining=seconds>0 and (math.floor(seconds/60)..'m '..(seconds%60)..'s remaining') or 'Awaiting server result'
    local bid=soonest.myBid
    urgent[#urgent+1]={kind='banner',title=soonest.itemName or 'Auction',subtitle=remaining..(bid and (' / Your offer: '..tostring(bid.percent or bid.amount or '?')..(bid.percent and '%' or ' DKP')) or ' / No recorded offer'),
      action=action(seconds>0 and ('editbid:'..soonest.id) or 'tab:auctions',seconds>0 and (type(bid)=='table' and 'Change bid' or 'Place bid') or 'View auction')}
  end
  for _,p in ipairs(h.pf and h.pf.listings or {}) do
    if p.isMine and p.mode=='LFM' and p.id then
      urgent[#urgent+1]={title='Your party is recruiting',subtitle=tostring(p.members or 0)..' / '..tostring(p.maxSize or 6)..' members',action=action('pfdetail:'..p.id,'Manage party')}
    elseif p.isMember and p.mode=='LFM' and p.id then
      urgent[#urgent+1]={title='Joined '..tostring(p.host or 'host').."'s recruitment",subtitle=tostring(p.members or 0)..' / '..tostring(p.maxSize or 6)..' registered members',action=action('pfdetail:'..p.id,'View roster')}
    end
  end
  if #urgent>0 then out[#out+1]=section('Needs your attention');for _,r in ipairs(urgent) do r.kind='banner';out[#out+1]=r end end
  local character={}
  if ctx.tier=='member' and h.dkp and h.dkp.splitVisible then
    for _,w in ipairs(h.dkp.wallets or {}) do character[#character+1]={title=w.poolName or 'Unknown wallet',value=tostring(w.currentBalance or 0)..' DKP'} end
  else character[#character+1]={title='Balance',value=balance(ctx.tier=='member' and h.dkp or nil)} end
  character[#character+1]={title='Equipped',value=job(ctx.observation and ctx.observation.main)}
  for i=1,#character,3 do out[#out+1]=metrics({character[i],character[i+1],character[i+2]}) end
  -- The renderer reserves the last docked row on every page.
  out[#out+1]={kind='cards',dock=true,items={
    {title='Find a group',subtitle=h.pf and ((h.pf.lfg or 0)..' looking / '..(h.pf.lfm or 0)..' recruiting') or 'Players on your world',art='pennant',action=action('refresh_pf','Browse players')},
    ctx.tier=='member' and {title='Your events',subtitle=h.denied and h.denied.events and 'Your role cannot read events.' or 'Upcoming linkshell activities',art='calendar',action=not (h.denied and h.denied.events) and action('board:events','View events') or nil}
      or {title='Find your linkshell',subtitle='Communities on '..ctx.world,art='pearl',action=action('refresh_shells','Browse linkshells')}
  }}
  return out
end
function M.me(ctx, old)
  if ctx.board=='myjobs' and ctx.jobs_rows and ctx.jobs_rows[1] and ctx.jobs_rows[1].title=='Review job plans' then return ctx.jobs_rows end
  if ctx.board and ctx.board~='myjobs' then return old end
  if ctx.tier~='member' then return {head(ctx.name,ctx.world),{kind='banner',title='Connect your character',subtitle='Access linkshell records.',action={id='signin',label='Connect account',variant='primary'}},{kind='text',text='Party finder is also available without an account using an unverified public identity.'},{kind='toolbar',actions={{id='tools:world',label='Use public party finder'}}}} end
  local out={{kind='toolbar',title=(ctx.hud.you and ctx.hud.you.role and (ctx.hud.you.role:lower()..' / ') or '')..'Account linked',actions={action('cmd:dkp','Refresh balances')}}}
  wallet_rows(out,ctx.hud.dkp)
  out[#out+1]={kind='choices',compact=true,options={
    {id='surface:current',label='Current jobs',selected=M.jobs_tab=='current'},
    {id='board:myjobs',label='Plans & priorities',selected=M.jobs_tab=='plans'}}}
  if M.jobs_tab=='plans' then
    local decl=ctx.hud.myjobs
    out[#out+1]=metrics({{title='Planned main',value=decl and decl.declaredMain or 'Not fetched'},
      {title='Second priority',value=decl and decl.declaredSecondary or 'Not set'},
      {title='Third priority',value=decl and decl.declaredTertiary or 'Not set'}})
    out[#out+1]={kind='toolbar',title='Observed levels never overwrite your plans.'}
    local plans=false
    for _,r in ipairs(ctx.jobs_rows or {}) do
      if r.kind=='header' and r.title=='Job plans and priorities' then plans=true
      elseif plans and r.tag~='1st' and r.tag~='2nd' and r.tag~='3rd' then out[#out+1]=r end
    end
  else
    local observation=ctx.preview and ctx.preview.observation or ctx.observation
    out[#out+1]={kind='banner',title='Equipped: '..job(observation and observation.main)..' / '..job(observation and observation.sub),
      subtitle=ctx.preview and 'Preview: only these observed levels will be sent.' or 'Current observations, separate from your plans.',
      action=action(ctx.preview and 'jobs:sync' or 'jobs:preview',ctx.preview and 'Sync to Lootryx' or 'Preview sync')}
    local cells={}
    for _,code in ipairs({'WAR','MNK','WHM','BLM','RDM','THF','PLD','DRK','BST','BRD','RNG','SAM','NIN','DRG','SMN','BLU','COR','PUP'}) do
      cells[#cells+1]={title=code,value=observation and observation.levels[code] and tostring(observation.levels[code]) or '?'}
      if #cells==6 then out[#out+1]={kind='jobgrid',items=cells};cells={} end
    end
    out[#out+1]={kind='toolbar',title=ctx.feedback or (ctx.hud.observed_jobs and ctx.hud.observed_jobs.jobsObservedAt and ('Last synced: '..ctx.hud.observed_jobs.jobsObservedAt) or 'Not synced yet. Unknown job levels are preserved.')}
  end
  return out
end
function M.shell(ctx, old)
  if ctx.board=='more' then
    local out={head('Linkshell tools','Browse records, vote in polls, or open the website for more tools.')}
    local items={}
    for _,r in ipairs(old) do
      local id=r.action and r.action.id or ({Bounties='board:bounties',Bank='board:bank',Polls='board:polls',['Recent loot']='board:loot'})[r.title]
      if id=='board:bounties' or id=='board:bank' or id=='board:polls' or id=='board:item' or id=='board:loot' then
        local item=copy(r);if r.action then item.action=copy(r.action);item.action.label=({['board:bounties']='View bounties',['board:bank']='View bank',['board:polls']='View polls',['board:item']='Look up item',['board:loot']='View loot'})[id] end;items[#items+1]=item
      end
    end
    local restricted=ctx.hud.denied and ctx.hud.denied.statics
    items[#items+1]={title='Statics',subtitle=restricted and 'Ask an officer for access to linkshell teams.' or 'Your linkshell teams and schedules',art='alliance',action=not restricted and action('board:statics','View teams') or nil}
    cards(out,items)
    return out
  end
  if ctx.board or ctx.focused then return old end
  local out={head(ctx.shell,'Your linkshell, within reach.',{action('attendance:open','Attendance')})}
  wallet_rows(out,ctx.hud.dkp)
  local stats={{title='Open auctions',value=ctx.hud.auctions and tostring(#ctx.hud.auctions) or 'Not fetched'},{title='Tracked targets',value=ctx.hud.windows and tostring(#ctx.hud.windows) or 'Not fetched'}}
  if not (ctx.hud.dkp and ctx.hud.dkp.splitVisible) then table.insert(stats,1,{title='Your balance',value=balance(ctx.hud.dkp)}) end
  out[#out+1]=metrics(stats)
  local tools,items={},{}
  for _,r in ipairs(old) do
    if r.tag=='DROP' then local a=copy(r.action);a.label='Report a drop';tools[#tools+1]=a
    elseif r.title=='Events' or r.title=='Standings' then
      local item=copy(r)
      if r.action then item.action=copy(r.action);item.action.label=r.title=='Events' and 'View events' or 'View standings' end
      items[#items+1]=item
    end
  end
  out[#out+1]={kind='toolbar',actions=tools}
  out[#out+1]=section('Events and standings')
  cards(out,items)
  out[#out+1]={kind='toolbar',actions={action('board:more','More linkshell tools')}}
  return out
end
-- Keep refusals, forms and empty states intact; align only actual fetched records.
function M.details(ctx, rows)
  local board=ctx.board
  local layouts={events={'Event','Status / response','Time',''},bank={'Item','Availability','Quantity',''},
    loot={'Item','Disposition / recipient','Recorded',''},wishlist={'Item','Preference','Priority',''},
    bounties={'Bounty','Claims','Reward',''}}
  local titles=layouts[board]
  if not titles then return rows end
  local out,headed={},false
  local columns=(board=='loot' or board=='bank' or board=='bounties') and {0.4,0.4,0.2} or {0.35,0.33,0.17,0.15}
  if board=='events' then columns={0.3,0.3,0.15,0.25} end
  for _,r in ipairs(rows) do
    local aid=r.action and r.action.id or ''
    local record=r.item_name or (board=='events' and aid:sub(1,12)=='board:event:')
      or (board=='bounties' and r.meta)
    if record then
      if not headed then out[#out+1]={kind='columns',columns=columns,cells=titles};headed=true end
      local detail,extra=r.subtitle,r.chip
      if board=='loot' and detail then
        local disposition,recipient=detail:match('^(.-)  to (.+)$')
        if recipient then detail=recipient;extra=disposition end
      end
      out[#out+1]={kind='record',columns=columns,item_name=r.item_name,accent=r.accent,
        cells={{text=r.title,subtext=r.badge},{text=detail,subtext=extra},
          {text=r.meta or (board=='wishlist' and r.tag or ''),colour=r.meta_colour}},action=r.action,secondary_action=r.secondary_action}
    else out[#out+1]=r end
  end
  return out
end
function M.present(ctx, old)
  local rows=old
  if ctx.tab=='home' and not ctx.board then rows=M.home(ctx,old)
  elseif ctx.tab=='lfg' or ctx.tab=='lfm' then rows=M.find(ctx,old)
  elseif ctx.tab=='me' then rows=M.me(ctx,old)
  elseif ctx.tab=='shell' then rows=M.shell(ctx,old)
  elseif ctx.tab=='settings' and not ctx.board then
    rows={head('Preferences','Display, reporting and local diagnostics.',{action('notifications','Notifications')})}
    local diagnostics,reporting,buttons,report_summary=false,false,{},{}
    for _,r in ipairs(old) do
      if r.kind=='header' and r.title=='Diagnostics' then diagnostics=true;reporting=false;rows[#rows+1]=r
      elseif r.kind=='toolbar' and r.title=='Reporting' then reporting=true
      elseif diagnostics and r.action then buttons[#buttons+1]=action(r.action.id,r.title)
      elseif reporting and r.action and (r.action.id=='cmd:auto' or r.action.id=='cmd:heartbeat') then
        report_summary[#report_summary+1]=(r.action.id=='cmd:auto' and 'Snapshots ' or 'Zone sharing ')..(r.tag=='ON' and 'on' or 'off')
      elseif reporting and r.action and r.action.id=='board:corrections' then
        rows[#rows+1]={kind='banner',title='Attendance reporting',subtitle=table.concat(report_summary,' / '),art='setting-snapshot',action=action('board:reporting','Configure')}
        if r.tag=='SET' then rows[#rows+1]={kind='toolbar',title='Name adjustments active',actions={action('board:corrections','Review adjustments')}} end
        reporting=false
      else rows[#rows+1]=r end
    end
    rows[#rows+1]={kind='toolbar',actions=buttons}
  elseif ctx.tab=='shells' and not ctx.focused then
    rows={head('Find your linkshell','A community for the way you play.')}
    if ctx.search_row then rows[#rows+1]=ctx.search_row end
    local matched=0
    for _,r in ipairs(old) do if (tostring(r.title)..' '..tostring(r.subtitle)):lower():find((ctx.search_value or ''):lower(),1,true) then rows[#rows+1]=r;matched=matched+1 end end
    if matched==0 then
      if ctx.hud.shells==nil then
        rows[#rows+1]={kind='banner',title='Linkshell directory not loaded',subtitle='Load communities on '..ctx.world..'.',action=action('refresh_shells','Load directory')}
      elseif (ctx.search_value or '')~='' then
        rows[#rows+1]={kind='banner',title='No linkshells match',subtitle='Try another name or clear your search.'}
      else rows[#rows+1]={kind='banner',title='No linkshells listed yet',subtitle='Refresh to check for new communities.',action=action('refresh_shells','Refresh directory')} end
    end
  elseif ctx.tab=='auctions' and not ctx.focused then
    local grants=ctx.hud.you and ctx.hud.you.canRun
    local opener={}
    if type(grants)~='table' then opener={action('auction','Check auction access')}
    elseif grants.auctions==true then opener={action('auction','Open auction')} end
    rows={head('Auctions','Sealed offers. Live deadlines.',opener),
      {kind='choices',compact=true,options={{id='surface:active',label='Active',selected=M.auction_tab=='active'},
        {id='surface:results',label='Results',selected=M.auction_tab=='results'}}}}
    for _,r in ipairs(old) do
      local result=r.result==true
      if (M.auction_tab=='results')==result then
        if r.title=='Choose another offer' and r.action and r.action.id:sub(1,8)=='editbid:' and #rows>2 and rows[#rows].item_name then
          rows[#rows].secondary_action=r.action
          rows[#rows].subtitle=rows[#rows].subtitle:match('^(Minimum %d+ DKP)') or rows[#rows].subtitle
        else rows[#rows+1]=r end
      end
    end
    if ctx.hud.denied and ctx.hud.denied.auctions then
      rows={head('Auctions'),{kind='banner',title='Auction records unavailable',subtitle='Your linkshell role cannot read auctions. Ask an officer about access.',accent='bad'}}
    elseif #rows==2 then rows[#rows+1]={kind='banner',title=M.auction_tab=='results' and 'No results received this session' or 'No active auctions loaded',subtitle='Use Refresh to check for changes.'} end
  elseif ctx.tab=='windows' and not ctx.hnm_presented then
    rows={head(M.tod_open and 'Log time of death' or 'HNM windows','Track known targets and record witnessed kills.',
      {action(M.tod_open and 'surface:windows' or 'surface:tod',M.tod_open and 'Back to windows' or 'Log ToD')})}
    for _,r in ipairs(old) do
      local target=r.action and r.action.id:sub(1,4)=='tod:'
      if M.tod_open and not target or not M.tod_open and target then rows[#rows+1]=r end
    end
    if #rows==1 then rows[#rows+1]={kind='banner',title='No tracked windows loaded',subtitle='Refresh to fetch your shell targets.'} end
  end
  rows=M.details(ctx,rows)
  if ctx.detail_layout then rows=ctx.detail_layout.present(ctx,rows) end
  -- Focused boards keep every action, with navigation separated from records.
  local out={}
  for _,r in ipairs(rows) do
    r=copy(r)
    if r.tag=='BACK' and r.action then r={kind='toolbar',title='',actions={r.action}}
    elseif (r.tag=='ON' or r.tag=='OFF') and r.action then r.kind='toggle';r.on=r.tag=='ON'
    end
    out[#out+1]=r
  end
  if ctx.focused and out[1] and out[1].kind=='header' then out[1].kind='pagehead' end
  -- A form has one anchored confirmation area, instead of competing record rows.
  local submit,cancel,body=nil,nil,{}
  local forms={bidsend=true,['auc:send']=true,dropgo=true,todsend=M.tod_open}
  local backs={bidcancel=true,['auc:cancel']=true,['drop:cancel']=true}
  for _,r in ipairs(out) do
    if r.action and forms[r.action.id] then submit=r
    elseif r.kind=='toolbar' and r.actions and #r.actions==1 and backs[r.actions[1].id] then cancel=r.actions[1]
    else body[#body+1]=r end
  end
  if submit then
    local actions={};if cancel then actions[#actions+1]=cancel end;submit.action.variant='primary';actions[#actions+1]=submit.action
    body[#body+1]={kind='actions',title=submit.title,subtitle=submit.subtitle,actions=actions};out=body
  end
  if ctx.freshness and ctx.tab~='home' and ctx.tab~='shell' and ctx.tab~='me' and ctx.tab~='settings' and ctx.tab~='lfg' and ctx.tab~='lfm' and ctx.tab~='windows' and not ctx.focused then
    table.insert(out,2,{kind='toolbar',title=ctx.freshness.title,accent=ctx.freshness.accent,actions={action('refresh','Refresh')}})
    if ctx.freshness.accent=='bad' then table.insert(out,3,{kind='toolbar',title=ctx.freshness.subtitle,accent='bad'}) end
  end
  if ctx.tab=='me' and (not ctx.board or ctx.board=='myjobs' or ctx.board=='wishlist' or ctx.board=='macros' or ctx.board=='connection') then
    table.insert(out,1,{kind='choices',compact=true,options={
      {id='nav:me',label='Profile',selected=not ctx.board or ctx.board=='myjobs'},
      {id='board:wishlist',label='Wishlist',selected=ctx.board=='wishlist'},
      {id='board:macros',label='Macros',selected=ctx.board=='macros'},
      {id='signin',label='Connection',selected=ctx.board=='connection'}}})
  end
  return out
end
return M
