-- Windower slot-to-shared-state adapter. Read functions are injected by the entry point.
-- Fresh reads on demand, no polling, cache, game action or network capability.
local M = {}
function M.new(read_player, read_party)
  local adapter = {}
  function adapter.player()
    local player = read_player()
    if type(player) ~= 'table' then return nil end
    return { id = player.id, name = player.name, main_job = player.main_job, sub_job = player.sub_job }
  end
  function adapter.members()
    local party = read_party()
    local members = {}
    if type(party) ~= 'table' then return members end
    for group = 0, 2 do
      for index = 0, 5 do
        local key = group == 0 and ('p' .. index) or ('a' .. group .. index)
        local member = party[key]
        if type(member) == 'table' then
          members[#members + 1] = {
            id = member.id, name = member.name, zone_id = member.zone, own_party = group == 0,
          }
        end
      end
    end
    return members
  end
  return adapter
end
return M
