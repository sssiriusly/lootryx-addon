-- Per-character JSON settings. Storage and codec are explicit host dependencies.
-- Only keys/types present in defaults are accepted. Input is never executed as Lua.
local M = {}
function M.new(storage, codec, identity)
  local defaults, settings, owner
  local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for key, v in pairs(value) do result[key] = copy(v) end
    return result
  end
  local function merge(base, saved)
    for key, value in pairs(base) do
      local v = saved[key]
      if type(v) == type(value) then
        if type(v) == 'table' then
          -- Macro hash cache is an intentionally open string map.
          if key == 'macro_hashes' then
            for k, hash in pairs(v) do
              if type(k) == 'string' and k:match('^b%d+$') and type(hash) == 'string' then value[k] = hash end
            end
          else merge(value, v) end
        else base[key] = v end
      end
    end
  end
  local C = {}
  function C.load(value)
    defaults, owner = copy(value), identity()
    settings = copy(defaults)
    if owner then
      local raw = storage.read(owner)
      if raw then
        local ok, saved = pcall(codec.decode, raw)
        if not ok or type(saved) ~= 'table' then error('Lootryx settings are invalid; restore the settings backup.') end
        merge(settings, saved)
      end
    end
    return settings
  end
  function C.save(value)
    if not owner or identity() ~= owner or value ~= settings then return false end
    local allowed = copy(defaults)
    merge(allowed, value)
    local ok, encoded = pcall(codec.encode, allowed)
    if not ok then return false end
    return storage.write(owner, encoded) == true
  end
  return C
end
return M
