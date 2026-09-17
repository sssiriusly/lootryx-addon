-- Ashita v4 keyboard capture only. Never dispatches a console or game command.
-- Preserve an existing input block owned by another UI when our field closes.
local M = {}
function M.new(keyboard, clipboard)
  local captured, previous = false, false
  local driver = { clipboard = clipboard }
  function driver.block()
    if captured then return end
    previous = keyboard:GetBlockInput()
    keyboard:SetBlockInput(true)
    captured = true
  end
  function driver.release()
    if not captured then return end
    keyboard:SetBlockInput(previous)
    captured = false
  end
  return driver
end
return M
