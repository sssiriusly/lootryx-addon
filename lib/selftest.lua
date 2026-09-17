--[[
  lib/selftest.lua : runs the addon's own checks and formats the result.

  WHY THIS EXISTS. addon/README.md section 6 is a checklist of things that can only be confirmed
  inside a real FFXI client, and most of it has never been ticked, because ticking it meant a person
  logging in and working through a page of prose one command at a time. That is a bad deal: it is
  slow, it is easy to do half of, and the half that gets skipped is the boring half where the bugs
  live. `//lootryx selftest` collapses it into one command whose output can be pasted back.

  It matters more than it sounds, because the harness in packages/addon-harness runs the addon under
  LuaJIT while Windower runs stock Lua 5.1. Those are different implementations with different
  number and string handling, and this addon carries a hand-vendored pure-Lua SHA-256. "It passes
  under LuaJIT" is genuinely not the same claim as "it computes the right signature in the client",
  and until something checks the second one in the client, nothing has.

  WHAT IT MAY DO. Reads and local computation, nothing else. No request, no file write, no game
  action: running a diagnostic must never be the thing that changes something. That is not a
  convention here, it is checked by the compliance suite, which asserts this file has no transport
  and no I/O of its own and that the command never runs from the render loop.

  PURE. `M.run` is handed a list of checks and calls them. Every environment read lives in the
  caller (lootryx.lua), where the compliance scanner already looks for Windower APIs, so this file
  stays formatting and control flow and can be tested without a game or a network.
]]

local M = {}

M.OK = 'ok'
M.WARN = 'warn'
M.FAIL = 'fail'

local LABEL = {
  ok = '  OK  ',
  warn = ' WARN ',
  fail = ' FAIL ',
}

--[[
  Runs one check and normalizes whatever it did into (status, detail).

  A check that ERRORS is a FAIL with the error text, never an escape: the entire value of this
  command is that it still reports when something is broken, and a diagnostic that dies on the first
  broken thing tells you about exactly one problem per run.
]]
function M.evaluate(check)
  local ok, status, detail = pcall(check.fn)
  if not ok then
    return M.FAIL, 'errored: ' .. tostring(status)
  end
  if status == true then
    return M.OK, detail
  end
  if status == false or status == nil then
    return M.FAIL, detail
  end
  if status == M.WARN then
    return M.WARN, detail
  end
  if status == M.OK or status == M.FAIL then
    return status, detail
  end
  return M.FAIL, 'unknown status ' .. tostring(status)
end

local function pad(text, width)
  local out = tostring(text)
  while #out < width do
    out = out .. ' '
  end
  return out
end

--[[
  Runs every check and returns (lines, summary) where summary is {ok=, warn=, fail=}.

  Returns lines rather than printing them so the caller owns output, which is what lets this be
  tested without capturing a chat log, and lets the same list be rendered somewhere else later.
]]
function M.run(checks)
  local lines = {}
  local summary = { ok = 0, warn = 0, fail = 0 }

  local width = 0
  for _, check in ipairs(checks or {}) do
    if #check.name > width then
      width = #check.name
    end
  end

  for _, check in ipairs(checks or {}) do
    local status, detail = M.evaluate(check)
    summary[status] = (summary[status] or 0) + 1
    local line = '[' .. (LABEL[status] or status) .. '] ' .. pad(check.name, width)
    if detail and detail ~= '' then
      line = line .. '  ' .. tostring(detail)
    end
    lines[#lines + 1] = line
  end

  return lines, summary
end

--[[
  The closing line. Says what to DO, because a failure a player cannot act on is just an alarm.

  A WARN is deliberately not a failure: the things that warn here (no luasec, an unconfigured macro
  folder) are features not yet set up rather than an addon that does not work, and conflating "you
  have not configured this" with "this is broken" trains people to ignore the whole report.
]]
function M.summary_line(summary)
  local total = (summary.ok or 0) + (summary.warn or 0) + (summary.fail or 0)
  local line = tostring(summary.ok or 0) .. '/' .. tostring(total) .. ' checks passed'
  if (summary.warn or 0) > 0 then
    line = line .. ', ' .. tostring(summary.warn) .. ' warning(s)'
  end
  if (summary.fail or 0) > 0 then
    return line .. ', ' .. tostring(summary.fail) .. ' FAILED. Please paste this whole block when reporting.'
  end
  if (summary.warn or 0) > 0 then
    return line .. '. Warnings need context: read the affected check above.'
  end
  return line .. '. All listed local checks passed; network and gameplay testing are separate.'
end

return M
