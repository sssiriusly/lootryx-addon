-- Human time entry for manual reports. No network or game reads.
local M = {}
function M.parse(value, now)
  now = now or os.time()
  value = tostring(value or ''):match('^%s*(.-)%s*$')
  local lower = value:lower()
  if lower == '' or lower == 'now' then return os.date('!%Y-%m-%dT%H:%M:%SZ', now) end
  local minutes = lower:match('^(%d+)%s*m%s*ago$') or lower:match('^(%d+)%s*min%s*ago$')
  if minutes and tonumber(minutes) > 1440 then return nil, 'Older corrections: use the officer website or Discord.' end
  if minutes then return os.date('!%Y-%m-%dT%H:%M:%SZ', now - tonumber(minutes)*60) end
  local hour, minute = lower:match('^(%d%d?):(%d%d)$')
  if hour then
    hour, minute = tonumber(hour), tonumber(minute)
    if hour > 23 or minute > 59 then return nil, 'Enter a clock time from 00:00 to 23:59.' end
    local date = os.date('*t', now)
    date.hour, date.min, date.sec, date.isdst = hour, minute, 0, nil
    local epoch = os.time(date)
    if epoch > now then date.day = date.day - 1; epoch = os.time(date) end
    return os.date('!%Y-%m-%dT%H:%M:%SZ', epoch)
  end
  if value:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then return value end
  return nil, 'Use now, 2m ago, or a local clock time like 19:45.'
end
M.targets = {
  "Absolute Virtue",
  "Adamantoise",
  "Aspidochelone",
  "Behemoth",
  "Byakko",
  "Capricious Cassie",
  "Cerberus",
  "Dynamis Lord",
  "Fafnir",
  "Genbu",
  "Hydra",
  "Ixaern drg",
  "Ixaern drk",
  "Jailer of Faith",
  "Jailer of Fortitude",
  "Jailer of Hope",
  "Jailer of Justice",
  "Jailer of Love",
  "Jailer of Prudence",
  "Jailer of Temperance",
  "Jormungand",
  "Khimaira",
  "King Arthro",
  "King Behemoth",
  "King Vinegarroon",
  "Kirin",
  "Leaping Lizzy",
  "Nidhogg",
  "Roc",
  "Seiryu",
  "Serket",
  "Shikigami Weapon",
  "Simurgh",
  "Suzaku",
  "Tiamat",
  "Valkurm Emperor",
  "Vrtra",
}
return M
