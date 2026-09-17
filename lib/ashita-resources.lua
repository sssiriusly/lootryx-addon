-- Read-only Ashita resource and treasure adapters. Never reads inventory bags.
local M = {}
function M.new(resources, inventory)
  local names
  local R = {}
  function R.job(id)
    if type(id) ~= 'number' or id <= 0 then return nil end
    local name = resources:GetString('jobs.names_abbr', id)
    return type(name) == 'string' and name ~= '' and name or nil
  end
  function R.resources()
    if not names then
      names = {}
      -- Item IDs are unsigned 16-bit protocol values, not a gameplay tuning value.
      for id = 1, 65534 do
        local item = resources:GetItemById(id)
        if item and item.Name then
          local name = item.Name[1]
          if type(name) == 'string' and name ~= '' and name ~= '.' then names[id] = {id=id,en=name} end
        end
      end
    end
    return {items=names}
  end
  function R.treasure()
    local pool = {}
    for slot = 0, 9 do
      local row = inventory:GetTreasurePoolItem(slot)
      if row and type(row.Use) == 'number' and row.Use > 0 and type(row.ItemId) == 'number' and row.ItemId > 0 and row.ItemId < 65535 then
        pool[slot] = {item_id=row.ItemId, timestamp=row.DropTime}
      end
    end
    return pool
  end
  function R.game_path()
    local path = resources:GetFilePath(0)
    if type(path) ~= 'string' then return nil end
    local start = path:upper():find('[\\/]ROM[\\/]')
    return start and path:sub(1,start) or nil
  end
  return R
end
return M
