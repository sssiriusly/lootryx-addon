-- Direct3D artwork owned by Lootryx. Only allocated texture pointers are retained/released.
-- FFI is used for graphics interop, never to scan or write game memory.
local M = {}
function M.new(ffi, d3d, resources, asset_path)
  local cache = {}
  local used, frame = {}, 0
  local T = {}
  -- Retire cold item textures before building the next ImGui draw list, never
  -- while a queued image still references them. Static interface artwork stays hot.
  function T.begin_frame()
    frame=frame+1
    local keys={}
    for key,at in pairs(used) do if key:sub(1,5)=='item:' then keys[#keys+1]={key=key,at=at} end end
    if #keys<=128 then return end
    table.sort(keys,function(a,b) return a.at<b.at end)
    for i=1,#keys-128 do
      local old=keys[i]
      if old.at<frame-1 then
        local entry=cache[old.key]
        if entry then entry.object:Release() end
        cache[old.key],used[old.key]=nil,nil
      end
    end
  end
  local C = ffi.C
  local function create(key, load)
    if cache[key] ~= nil then return cache[key] or nil end
    local out = ffi.new('IDirect3DTexture8*[1]')
    local result = load(out)
    if result ~= C.S_OK or out[0] == nil then
      cache[key] = false
      return nil
    end
    local owned = ffi.cast('IDirect3DTexture8*', out[0])
    cache[key] = {object=owned, ref=tonumber(ffi.cast('uintptr_t', owned))}
    return cache[key]
  end
  function T.get(icon)
    local entry
    if type(icon.item_name) == 'string' then
      local key = 'item:' .. icon.item_name
      used[key]=frame
      local item = cache[key] == nil and resources:GetItemByName(icon.item_name, 1) or nil
      if cache[key] ~= nil then entry = cache[key] or nil
      elseif item and type(item.Bitmap) == 'string' and type(item.ImageSize) == 'number' and item.ImageSize > 0 then
        entry = create(key, function(out)
          return C.D3DXCreateTextureFromFileInMemoryEx(d3d.get_device(), item.Bitmap, item.ImageSize,
            0xFFFFFFFF, 0xFFFFFFFF, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED,
            C.D3DX_DEFAULT, C.D3DX_DEFAULT, 0xFF000000, nil, nil, out)
        end)
      else cache[key] = false end
    end
    if not entry and type(icon.name) == 'string' and icon.name:match('^[%w_-]+$') then
      entry = create('art:' .. icon.name, function(out)
        return C.D3DXCreateTextureFromFileA(d3d.get_device(), asset_path .. icon.name .. '.png', out)
      end)
    end
    return entry and entry.ref or nil
  end
  function T.destroy()
    for _, entry in pairs(cache) do if entry then entry.object:Release() end end
    cache = {}
    used = {}
  end
  return T
end
return M
