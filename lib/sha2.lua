--[[
  sha2.lua · pure-Lua SHA-256 + HMAC-SHA256 for Windower4 (Lua 5.1, no bit lib).

  Self-contained: implements 32-bit bitwise ops with plain arithmetic so it runs on
  stock Windower Lua without `bit`/`bit32`. Big-endian, RFC 6234 / FIPS 180-4 compliant.

  This implementation's arithmetic was transcribed to Node and checked byte-for-byte
  against node:crypto (empty string, block boundaries 55/56/64, long inputs, and
  HMAC incl. the long-key path) · all vectors matched. See addon/README.md.

  Attribution: standard textbook SHA-256; pure-arithmetic bitops are a common
  public-domain pattern for Lua 5.1. Vendored for Lootryx's addon (no network deps).

  API:
    local sha2 = loadfile(windower.addon_path .. 'lib/sha2.lua')()
    sha2.sha256(message)          -> lowercase hex string (64 chars)
    sha2.hmac_sha256(key, msg)    -> lowercase hex string (64 chars)
]]

local MOD = 2 ^ 32

-- Per-bit combine over 32 bits. Correct for any integers in [0, 2^32).
local function bitwise(a, b, f)
  local result, bitval = 0, 1
  for _ = 1, 32 do
    local abit = a % 2
    local bbit = b % 2
    if f(abit, bbit) == 1 then
      result = result + bitval
    end
    bitval = bitval * 2
    a = (a - abit) / 2
    b = (b - bbit) / 2
  end
  return result
end

local function band(a, b)
  return bitwise(a, b, function(x, y) return (x + y == 2) and 1 or 0 end)
end
local function bor(a, b)
  return bitwise(a, b, function(x, y) return (x + y >= 1) and 1 or 0 end)
end
local function bxor(a, b)
  return bitwise(a, b, function(x, y) return (x ~= y) and 1 or 0 end)
end
local function bnot(a)
  return MOD - 1 - a
end
local function rshift(a, n)
  return math.floor(a / (2 ^ n))
end
local function lshift(a, n)
  return (a * (2 ^ n)) % MOD
end
local function rrotate(a, n)
  return bor(rshift(a, n), lshift(a, 32 - n))
end

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- 32-bit word -> 4 big-endian bytes.
local function u32bytes(x)
  return string.char(
    math.floor(x / 0x1000000) % 256,
    math.floor(x / 0x10000) % 256,
    math.floor(x / 0x100) % 256,
    x % 256
  )
end

-- Returns the raw 32-byte digest string.
local function digest_raw(msg)
  local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

  local bitlen = #msg * 8
  msg = msg .. string.char(0x80)
  while (#msg % 64) ~= 56 do
    msg = msg .. string.char(0)
  end
  local hi = math.floor(bitlen / MOD)
  local lo = bitlen % MOD
  msg = msg .. u32bytes(hi) .. u32bytes(lo)

  for chunk = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local b0 = string.byte(msg, chunk + i * 4)
      local b1 = string.byte(msg, chunk + i * 4 + 1)
      local b2 = string.byte(msg, chunk + i * 4 + 2)
      local b3 = string.byte(msg, chunk + i * 4 + 3)
      w[i] = ((b0 * 256 + b1) * 256 + b2) * 256 + b3
    end
    for i = 16, 63 do
      local s0 = bxor(bxor(rrotate(w[i - 15], 7), rrotate(w[i - 15], 18)), rshift(w[i - 15], 3))
      local s1 = bxor(bxor(rrotate(w[i - 2], 17), rrotate(w[i - 2], 19)), rshift(w[i - 2], 10))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
    end

    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for i = 0, 63 do
      local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local temp1 = (h + S1 + ch + K[i + 1] + w[i]) % MOD
      local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local temp2 = (S0 + maj) % MOD
      h = g
      g = f
      f = e
      e = (d + temp1) % MOD
      d = c
      c = b
      b = a
      a = (temp1 + temp2) % MOD
    end

    H[1] = (H[1] + a) % MOD
    H[2] = (H[2] + b) % MOD
    H[3] = (H[3] + c) % MOD
    H[4] = (H[4] + d) % MOD
    H[5] = (H[5] + e) % MOD
    H[6] = (H[6] + f) % MOD
    H[7] = (H[7] + g) % MOD
    H[8] = (H[8] + h) % MOD
  end

  local out = {}
  for i = 1, 8 do
    out[i] = u32bytes(H[i])
  end
  return table.concat(out)
end

local function bin2hex(s)
  local hex = {}
  for i = 1, #s do
    hex[i] = string.format('%02x', string.byte(s, i))
  end
  return table.concat(hex)
end

local BLOCK = 64

local function hmac_sha256(key, message)
  if #key > BLOCK then
    key = digest_raw(key)
  end
  key = key .. string.rep('\0', BLOCK - #key)

  local ipad, opad = {}, {}
  for i = 1, BLOCK do
    local kb = string.byte(key, i)
    ipad[i] = string.char(bxor(kb, 0x36))
    opad[i] = string.char(bxor(kb, 0x5c))
  end

  local inner = digest_raw(table.concat(ipad) .. message)
  return bin2hex(digest_raw(table.concat(opad) .. inner))
end

return {
  sha256 = function(msg)
    return bin2hex(digest_raw(msg))
  end,
  hmac_sha256 = hmac_sha256,
}
