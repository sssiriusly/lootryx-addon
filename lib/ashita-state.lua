-- Ashita v4 party-manager adapter, matching client-state.lua's loader-neutral contract.
-- SDK reference: AshitaXI/Ashita-v4beta addons/libs/annotations/SDK/Memory/IParty.lua.
-- Caller injects the manager and numeric-job-to-abbreviation lookup. No global loader dependency.
local M = {}
function M.new(party, job_name)
  local reader = {}
  local function active(index)
    local value = party:GetMemberIsActive(index)
    return value == true or (type(value) == 'number' and value ~= 0)
  end
  function reader.player()
    if not active(0) then return nil end
    local id = party:GetMemberServerId(0)
    if type(id) ~= 'number' or id <= 0 then return nil end
    return {
      id = id, name = party:GetMemberName(0),
      main_job = job_name(party:GetMemberMainJob(0)),
      sub_job = job_name(party:GetMemberSubJob(0)),
    }
  end
  function reader.members()
    local members = {}
    for index = 0, 17 do
      if active(index) then
        members[#members + 1] = {
          id = party:GetMemberServerId(index), name = party:GetMemberName(index),
          zone_id = party:GetMemberZone(index), own_party = index < 6,
        }
      end
    end
    return members
  end
  return reader
end
return M
