-- Only Lootryx's own per-character JSON settings and their staging/backup files.
-- Root comes from the loader install path, never from a server response or text field.
local M = {}
function M.new(root, exists, mkdir)
  local S = {}
  local function path_for(owner)
    assert(type(owner) == 'string' and owner:match('^%a+_%d+$'), 'invalid settings identity')
    return root .. '/' .. owner .. '.json'
  end
  local function read(path)
    local file = io.open(path, 'rb')
    if not file then
      if exists(path) then error('Lootryx cannot read its settings file.') end
      return nil
    end
    local bytes = file:read(1048577)
    file:close()
    if not bytes or #bytes > 1048576 then error('Lootryx settings file is empty or too large.') end
    return bytes
  end
  function S.read(owner)
    local path = path_for(owner)
    -- Recover an interrupted rename before letting defaults replace existing settings.
    return read(path) or read(path .. '.bak')
  end
  function S.write(owner, bytes)
    local path = path_for(owner)
    if type(bytes) ~= 'string' or #bytes > 1048576 then return false end
    if not mkdir(root) and not exists(root) then return false end
    local staged, backup = path .. '.tmp', path .. '.bak'
    local file = io.open(staged, 'wb')
    if not file then return false end
    local ok, result = pcall(file.write, file, bytes)
    local closed, close_result = pcall(file.close, file)
    if not ok or not result or not closed or not close_result then return false end
    local checked, actual = pcall(read, staged)
    if not checked or actual ~= bytes then return false end
    local had_original = exists(path)
    if had_original then
      if exists(backup) and not os.remove(backup) then return false end
      if not os.rename(path, backup) then return false end
    end
    if not os.rename(staged, path) then
      if had_original then os.rename(backup, path) end
      return false
    end
    return true
  end
  return S
end
return M
