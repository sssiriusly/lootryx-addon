-- Presentation groups only. Targets are existing tabs with existing authorization.
local M = {}
local targets = { home = 'home', find = 'lfg', linkshell = 'shell', me = 'me', settings = 'settings' }

function M.target(group)
  return targets[group]
end

function M.describe(active, tier, counts, board)
  counts = counts or {}
  local group = active
  if active == 'lfg' or active == 'lfm' or active == 'shells' then group = 'find' end
  if active == 'shell' or active == 'auctions' or active == 'windows' then group = 'linkshell' end
  local primary = { { id = 'home', label = 'Home' }, { id = 'lfg', label = 'Find' } }
  if tier == 'member' then primary[#primary + 1] = { id = 'shell', label = 'Linkshell' } end
  primary[#primary + 1] = { id = 'me', label = 'Me' }
  primary[#primary + 1] = { id = 'settings', label = 'Settings' }
  local secondary = {}
  if group == 'find' then
    secondary = {
      { id = 'lfg', label = 'Players', count = counts.lfg },
      { id = 'lfm', label = 'Parties', count = counts.lfm },
      { id = 'shells', label = 'Linkshells', count = counts.shells },
    }
  elseif group == 'linkshell' and tier == 'member' then
    secondary = {
      { id = 'shell', label = 'Overview' },
      { id = 'auctions', label = 'Auctions', count = counts.auctions },
      { id = 'windows', label = 'HNM', count = counts.windows },
      { id = 'events', label = 'Events', action_id='board:events' },
      { id = 'standings', label = 'Standings', action_id='board:standings' },
      { id = 'more', label = 'More', action_id='board:more' },
    }
  end
  local selected=board or active
  if board and board:sub(1,6)=='event:' then selected='events'
  elseif board and ({bank=true,loot=true,bounties=true,statics=true,polls=true,item=true})[board] then selected='more'
  elseif board=='attendance' then selected='events' end
  return primary, secondary, targets[group], selected
end

return M
