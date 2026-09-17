-- HNM presentation and local navigation only. No network or game writes.
local M = {}
local columns = {0.46, 0.37, 0.17}
local function text(value, fallback)
  return type(value)=='string' and value~='' and value or fallback
end
local function action(id, label) return {id=id,label=label} end
local function duration(ms)
  local seconds=math.max(0,math.ceil(ms/1000))
  return string.format('%02d:%02d:%02d',math.floor(seconds/3600),math.floor(seconds/60)%60,seconds%60)
end
function M.window(target, now)
  local opens=type(target.openAtMs)=='number' and target.openAtMs or nil
  local closes=type(target.closeAtMs)=='number' and target.closeAtMs or nil
  if target.status=='WAITING' and opens and now<opens then return duration(opens-now),'Opens in','info' end
  if (target.status=='OPEN' or target.status=='WAITING') and closes and now<closes then
    return duration(closes-now),'Closes in','good'
  end
  if target.status=='MISSED' or ((target.status=='OPEN' or target.status=='WAITING') and closes and now>=closes) then
    return 'Window elapsed','Refresh or log a witnessed kill','dim'
  end
  if target.status=='OPEN' then return 'Window open','Closing time unavailable','good' end
  if target.status=='WAITING' then return 'Waiting','Window timing unavailable','info' end
  return 'No ToD yet','Log a witnessed kill','dim'
end
function M.new()
  local self={search='',open=false}
  function self.set_search(value) self.search=tostring(value or '') end
  function self.action(id)
    if id=='hnm:clear' then self.search='';return {kind='refresh'} end
    if id=='hnm:back' or id=='surface:windows' then self.open=false;return {kind='refresh'} end
    if id=='hnm:setup' then return {kind='setup'} end
    if id=='hnm:current' then return {kind='current'} end
    if id=='hnm:log' or id=='surface:tod' then self.open=true;return {kind='form'} end
    if id:sub(1,9)=='hnm:pick:' then
      local name=id:sub(10)
      if name~='' then self.open=true;return {kind='form',target=name} end
    end
  end
  function self.rows(ctx, form_rows)
    local targets=ctx.targets or {}
    if self.open then
      local out={{kind='toolbar',title='Log time of death',actions={action('surface:windows','Back to windows')}},
        {kind='toolbar',title='Blank time means now. Manual time is supported.',actions={action('hnm:current','Use current target')}}}
      for _,r in ipairs(form_rows or {}) do
        if not (r.action and r.action.id:sub(1,4)=='tod:') then out[#out+1]=r end
      end
      return out
    end
    local out={{kind='finderbar',value=ctx.search_display or self.search,focused=ctx.search_focused,
      placeholder='Search target or zone',action_id='focus:hnm.search',actions={action('surface:tod','Log ToD')}}}
    if ctx.freshness and ctx.freshness.accent=='bad' then out[#out+1]={kind='toolbar',title=ctx.freshness.subtitle,accent='bad'} end
    local query=(ctx.search_value or self.search):lower():match('^%s*(.-)%s*$')
    if query~='' then out[#out+1]={kind='toolbar',title='Matching target names and zones',actions={action('hnm:clear','Clear search')}} end
    out[#out+1]={kind='columns',columns=columns,cells={'Target / zone','Window status',''}}
    local count=0
    for _,target in ipairs(targets) do
      local name=text(target.name,'Unknown target')
      local zone=text(target.zone,'Zone unavailable')
      if query=='' or (name..' '..zone):lower():find(query,1,true) then
        local value,detail,accent=M.window(target,ctx.now_ms or 0)
        local status=accent=='good' and 'OPEN NOW' or (accent=='info' and 'UPCOMING' or (value=='Window elapsed' and 'STALE' or 'UNKNOWN'))
        local timing=value:match('^%d%d:') and (detail..' '..value) or (value=='Window elapsed' and 'New witnessed ToD needed' or detail)
        out[#out+1]={kind='record',columns=columns,cells={{text=name,subtext=zone},{text=status,colour=accent,subtext=timing}},accent=accent,
          action=text(target.name) and action('hnm:pick:'..name,'Log ToD') or nil}
        count=count+1
      end
    end
    if count==0 then
      out[#out+1]={kind='banner',title=query~='' and 'No tracked targets match' or (ctx.targets and 'No targets tracked yet' or 'Targets have not been loaded'),
        subtitle=query~='' and 'Try another name or zone, or clear the search.' or 'Set up the targets your linkshell wants to track on the website.'}
    end
    out[#out+1]={kind='toolbar',dock=true,title=ctx.freshness and ctx.freshness.title or 'Tracking setup',actions={action('hnm:setup','Manage targets'),action('refresh','Refresh')}}
    return out
  end
  return self
end
return M
