-- Loader-independent character/party policy. No loader API, I/O or cached game state.
-- Contract: player {id,name,main_job,sub_job}; ordered members {id,name,zone_id,own_party}.
local M = {}
function M.name(player)
  return type(player) == 'table' and type(player.name) == 'string' and player.name or nil
end
function M.jobs(player)
  if type(player) ~= 'table' then return nil, nil end
  local main = type(player.main_job) == 'string' and player.main_job ~= '' and player.main_job or nil
  local sub = type(player.sub_job) == 'string' and player.sub_job ~= '' and player.sub_job or nil
  if not main then return nil, nil end
  return main, sub
end
function M.own_zone(player, members)
  if type(player) ~= 'table' or type(player.id) ~= 'number' or player.id <= 0 then return nil end
  for _, member in ipairs(members or {}) do
    local zone = member.zone_id
    if member.own_party and member.id == player.id and type(zone) == 'number'
      and zone > 0 and zone < math.huge and zone == math.floor(zone) then
      return zone
    end
  end
  return nil
end
function M.alliance_names(members)
  local names, seen = {}, {}
  for _, member in ipairs(members or {}) do
    local name = member.name
    if type(name) == 'string' and name ~= '' and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  return names
end
-- Observations never infer an unlocked/capped job from an absent or zero field.
function M.job_observation(raw)
  if type(raw)~='table' then return nil end
  local valid={WAR=true,MNK=true,WHM=true,BLM=true,RDM=true,THF=true,PLD=true,DRK=true,BST=true,BRD=true,RNG=true,SAM=true,NIN=true,DRG=true,SMN=true,BLU=true,COR=true,PUP=true}
  local function level(n) return type(n)=='number' and n==math.floor(n) and n>=1 and n<=99 end
  local out={levels={}}
  for code,n in pairs(type(raw.levels)=='table' and raw.levels or {}) do if valid[code] and level(n) then out.levels[code]=n end end
  for _,slot in ipairs({'main','sub'}) do
    local v=raw[slot]
    if type(v)=='table' and valid[v.job] and level(v.level) then out[slot]={job=v.job,level=v.level} end
  end
  -- Subjob equipped level is capped by the main job, never use it as the learned level.
  if out.main and not out.levels[out.main.job] then out.levels[out.main.job]=out.main.level end
  return next(out.levels) and out or nil
end
return M
