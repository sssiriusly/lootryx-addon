--[[
        Copyright © 2021, Rubenator
        All rights reserved.
        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions are met:
            * Redistributions of source code must retain the above copyright
              notice, this list of conditions and the following disclaimer.
            * Redistributions in binary form must reproduce the above copyright
              notice, this list of conditions and the following disclaimer in the
              documentation and/or other materials provided with the distribution.
            * Neither the name of EquipViewer nor the
              names of its contributors may be used to endorse or promote products
              derived from this software without specific prior written permission.
        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
        ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
        DISCLAIMED. IN NO EVENT SHALL Rubenator BE LIABLE FOR ANY
        DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
        (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
        LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
        ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
        (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
        SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]
-- DAT decoding adapted from EquipViewer by Rubenator; extraction credited to Trv.
-- Only reads known ROM files and writes numeric BMP filenames inside the addon cache.
local M = {}
local function rotate(n) return (n % 32) * 8 + math.floor(n / 32) end
local function le(n, width)
  local out = {}
  for i = 1, width do out[i] = string.char(n % 256); n = math.floor(n / 256) end
  return table.concat(out)
end
local header = 'BM' .. le(4218, 4) .. le(0, 4) .. le(122, 4)
  .. le(108, 4) .. le(32, 4) .. le(32, 4) .. le(1, 2) .. le(32, 2)
  .. le(3, 4) .. le(4096, 4) .. string.rep('\0', 16)
  .. le(0x00FF0000, 4) .. le(0x0000FF00, 4) .. le(0x000000FF, 4)
  .. le(0xFF000000, 4) .. 'sRGB' .. string.rep('\0', 48)

function M.decode(data)
  if type(data) ~= 'string' or #data ~= 2048 then return nil end
  local palette, pixels = {}, {}
  for i = 0, 255 do
    local b, g, r, a = data:byte(i * 4 + 1, i * 4 + 4)
    palette[i] = string.char(rotate(b), rotate(g), rotate(r), math.min(255, rotate(a) * 2))
  end
  for i = 1025, 2048 do pixels[#pixels + 1] = palette[rotate(data:byte(i))] end
  return header .. table.concat(pixels)
end

local maps = {
  { 1, 4095, '118/106', 0 }, { 4096, 8191, '118/107', 4096 },
  { 8192, 8703, '118/110', 8192 }, { 8704, 10239, '301/115', 8704 },
  { 10240, 16383, '118/109', 10240 }, { 16384, 23039, '118/108', 16384 },
  { 23040, 28671, '286/73', 23040 },
}
local function normalize(name)
  if type(name) ~= 'string' then return nil end
  return name:lower():gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
end
local function read_cached(path)
  local file = io.open(path, 'rb')
  if not file then return false end
  local bytes = file:read(4219)
  file:close()
  return bytes and #bytes == 4218 and bytes:sub(1, 122) == header
end

function M.new(game_root, cache_root, resources)
  local names, memo = nil, {}
  local function resolve(name)
    local key = normalize(name)
    if not key or key == '' then return nil end
    if not names then
      names = {}
      local ok, items = pcall(resources)
      if not ok or type(items) ~= 'table' then return nil end
      for index, item in pairs(items) do
        if type(item) == 'table' then
          local id = tonumber(item.id or index)
          if id and id == math.floor(id) and id >= 1 and id <= 28671 then
            for _, field in ipairs({ 'en', 'enl' }) do
              local alias = normalize(item[field])
              if alias and alias ~= '' then
                if names[alias] == nil then names[alias] = id
                elseif names[alias] ~= id then names[alias] = false end
              end
            end
          end
        end
      end
    end
    return names[key] or nil
  end
  local function extract(id)
    if type(game_root) ~= 'string' or game_root == '' then return nil end
    for _, range in ipairs(maps) do
      if id >= range[1] and id <= range[2] then
        local file = io.open(game_root .. '/ROM/' .. range[3] .. '.DAT', 'rb')
        if not file then return nil end
        local data
        for _, stride in ipairs({ 3072, 5120 }) do
          local offset = (id - range[4]) * stride
          file:seek('set', offset)
          local record = file:read(4)
          -- Verify record identity, not just file length, before trying either layout.
          if record and #record == 4 and rotate(record:byte(1)) + 256 * rotate(record:byte(2)) == id
            and record:byte(3) == 0 and record:byte(4) == 0 then
            file:seek('set', offset + 0x2BD)
            data = file:read(2048)
            if data and #data == 2048 then break end
          end
          data = nil
        end
        file:close()
        return M.decode(data)
      end
    end
  end
  local function get(name)
    local id = resolve(name)
    if not id then return nil end
    if memo[id] ~= nil then return memo[id] or nil end
    memo[id] = false
    -- The name never participates in a filesystem path. Only the validated resource ID does.
    local path = cache_root .. 'v1-' .. tostring(id) .. '.bmp'
    if read_cached(path) then memo[id] = path; return path end
    local bmp = extract(id)
    if not bmp then return nil end
    local file = io.open(path, 'wb')
    if not file then return nil end
    local ok, wrote = pcall(file.write, file, bmp)
    local closed = file:close()
    if ok and wrote and closed and read_cached(path) then memo[id] = path; return path end
    return nil
  end
  return { get = function(name)
    local ok, value = pcall(get, name)
    return ok and value or nil
  end }
end
return M
