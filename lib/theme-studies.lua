-- Palette refinement only: pure data, no I/O, network or Windower calls.
return function(window)
  local extra = {
    classic = {
      label = "Classic Blue",
      panel = { 13, 22, 75 },
      chrome = { 24, 40, 114 },
      line = { 112, 137, 202 },
      hot = { 39, 61, 136 },
      bright = { 246, 247, 255 },
      accent = { 255, 227, 145 },
      dim = { 181, 194, 228 },
      btn = { 43, 64, 133 },
      btn_edge = { 142, 166, 229 },
    },
    crystal = {
      label = "Crystal",
      panel = { 12, 24, 33 },
      chrome = { 20, 40, 54 },
      line = { 62, 111, 132 },
      hot = { 30, 65, 79 },
      bright = { 234, 248, 252 },
      accent = { 143, 224, 241 },
      dim = { 155, 184, 196 },
      btn = { 30, 66, 81 },
      btn_edge = { 98, 167, 189 },
    },
    airship = {
      label = "Airship",
      panel = { 28, 24, 21 },
      chrome = { 45, 36, 28 },
      line = { 116, 91, 63 },
      hot = { 63, 47, 31 },
      bright = { 248, 237, 216 },
      accent = { 229, 178, 100 },
      dim = { 190, 171, 145 },
      btn = { 72, 50, 30 },
      btn_edge = { 188, 142, 77 },
    },
    moon = {
      label = "Moonlit",
      panel = { 20, 20, 33 },
      chrome = { 34, 33, 53 },
      line = { 89, 89, 127 },
      hot = { 48, 47, 75 },
      bright = { 243, 241, 251 },
      accent = { 202, 193, 248 },
      dim = { 178, 175, 202 },
      btn = { 57, 52, 89 },
      btn_edge = { 149, 137, 199 },
    },
    chocobo = {
      label = "Chocobo Trail",
      panel = { 28, 26, 17 },
      chrome = { 43, 39, 23 },
      line = { 111, 98, 52 },
      hot = { 61, 52, 25 },
      bright = { 250, 244, 218 },
      accent = { 244, 207, 78 },
      dim = { 194, 183, 140 },
      btn = { 68, 55, 22 },
      btn_edge = { 192, 162, 61 },
    },
    moghouse = {
      label = "Mog House",
      panel = { 243, 235, 220 },
      chrome = { 226, 213, 190 },
      line = { 155, 134, 107 },
      hot = { 218, 201, 177 },
      bright = { 48, 38, 31 },
      accent = { 132, 60, 58 },
      dim = { 101, 81, 63 },
      btn = { 222, 204, 180 },
      btn_edge = { 143, 104, 78 },
      good = { 36, 104, 70 },
      bad = { 163, 41, 40 },
      info = { 39, 91, 135 },
    },
  }
  for _, id in ipairs({ 'classic', 'crystal', 'airship', 'moon', 'chocobo', 'moghouse' }) do
    window.THEMES[id] = extra[id]
    window.THEME_ORDER[#window.THEME_ORDER + 1] = id
  end
  local function mix(a, b, fraction)
    local result = {}
    for i = 1, 3 do result[i] = math.floor(a[i] * (1 - fraction) + b[i] * fraction + 0.5) end
    return result
  end
  for id, theme in pairs(window.THEMES) do
    local light = id == 'moghouse'
    if not light then
      theme.panel = mix(theme.panel, { 20, 21, 24 }, 0.22)
      theme.chrome = mix(theme.chrome, theme.panel, 0.30)
      theme.hot = mix(theme.hot, theme.panel, 0.18)
      theme.line = mix(theme.line, theme.panel, 0.22)
      theme.btn = mix(theme.btn, theme.panel, 0.15)
    end
    -- Opaque reading surfaces keep contrast stable over bright game scenery.
    theme.panel_alpha = 255
    theme.text_stroke = light and 0 or 130
    theme.btn_hi = mix(theme.btn, theme.hot, 0.5)
    theme.good = light and { 35, 100, 66 } or { 151, 218, 168 }
    theme.bad = light and { 158, 38, 40 } or { 255, 155, 149 }
    theme.info = light and { 38, 85, 132 } or { 155, 205, 243 }
  end
end
