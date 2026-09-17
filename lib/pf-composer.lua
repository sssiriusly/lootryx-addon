-- Shared presentation and payload policy. No loader APIs or network access.
local M={}
local roles={'ANY','TANK','HEALER','SUPPORT','DPS'}
function M.role_label(role)
  return ({ANY='Any',TANK='Tank',HEALER='Healer',SUPPORT='Support',DPS='DPS'})[role]
end
function M.pick(draft,role,mode)
  if not M.role_label(role) then return end
  if mode=='LFG' then draft.role=role;return end
  draft.needed={[role]=true}
end
-- Older addons put a multi-role request in the comment. Keep those listings
-- discoverable without treating every legacy ANY listing as a match for all roles.
function M.matches(role,comment,wanted,open_roles)
  if wanted=='ALL' then return true end
  if type(open_roles)=='table' then return (tonumber(open_roles[wanted]) or 0)>0 or (tonumber(open_roles.ANY) or 0)>0 end
  local legacy=type(comment)=='string' and comment:match('^Looking for: ([A-Z +]+)%.')
  if role=='ANY' and legacy then
    for token in legacy:gmatch('[A-Z]+') do if token==wanted then return true end end
    return false
  end
  return role=='ANY' or role==wanted
end
-- Counts are enabled only by an explicit server capability. Never encode them
-- in comments: older APIs silently ignore unknown fields.
function M.enable_counts(draft,supported)
  draft.counted=supported==true
  if not draft.counted then return end
  if draft.maxSize==nil then draft.maxSize=6 end
  if type(draft.roleSlots)~='table' then draft.roleSlots={ANY=(tonumber(draft.maxSize) or 6)-1} end
end
function M.adjust(draft,role,delta)
  if not draft.counted or not M.role_label(role) then return false end
  local value=tonumber((draft.roleSlots or {})[role]) or 0
  draft.roleSlots=draft.roleSlots or {}
  draft.roleSlots[role]=math.max(0,math.min(17,value+delta))
  return true
end
function M.count_payload(draft,mode)
  if mode~='LFM' or not draft.counted then return nil end
  local counts,total={},0
  for _,role in ipairs(roles) do
    local n=tonumber((draft.roleSlots or {})[role]) or 0
    if n<0 or n>17 or n~=math.floor(n) then return nil,'Use whole numbers from 0 to 17 for role places.' end
    counts[role]=n;total=total+n
  end
  local capacity=tonumber(draft.maxSize)
  if not capacity or capacity<2 or capacity>18 or capacity~=math.floor(capacity) then return nil,'Choose a party size from 2 to 18.' end
  if total~=capacity-1 then return nil,'Assign exactly '..(capacity-1)..' places after the host. Currently assigned: '..total..'.' end
  return {roleSlots=counts,maxSize=capacity}
end
function M.count_rows(draft)
  local row={kind='rolecounts',options={}}
  for _,role in ipairs(roles) do
    row.options[#row.options+1]={role=role,label=M.role_label(role),value=tostring((draft.roleSlots or {})[role] or 0)}
  end
  return {{kind='text',text='Places after you, including existing joiners.'},row}
end
function M.open_summary(open_roles)
  if type(open_roles)~='table' then return nil end
  local parts={}
  for _,role in ipairs(roles) do
    local n=tonumber(open_roles[role]) or 0
    if n>0 then parts[#parts+1]=n..' '..M.role_label(role) end
  end
  return #parts>0 and table.concat(parts,' + ') or 'No open role places'
end
function M.payload(draft,mode)
  if draft.category=='CRAFT' then return 'ANY',draft.comment end
  if mode=='LFG' then return draft.role,draft.comment end
  local selected={}
  for _,role in ipairs(roles) do if (draft.needed or {ANY=true})[role] then selected[#selected+1]=role end end
  if #selected<=1 then return selected[1] or 'ANY',draft.comment end
  return 'ANY','Looking for: '..table.concat(selected,' + ')..'. '..(draft.comment or '')
end
function M.choices(draft,mode)
  local options={}
  for _,role in ipairs(roles) do options[#options+1]={id='set:pf.role:'..role,label=M.role_label(role),
    icon='role_'..role:lower(),selected=mode=='LFG' and draft.role==role or mode=='LFM' and (draft.needed or {ANY=true})[role]==true,
    colour=({TANK={140,188,232},HEALER={164,216,165},SUPPORT={214,172,240},DPS={237,172,143}})[role]} end
  return {kind='choices',options=options}
end
return M
