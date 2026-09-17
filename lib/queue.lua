--[[
  lib/queue.lua : a SHORT-LIVED in-memory retry buffer for ingest posts.

  WHAT THIS IS FOR. `post()` is blocking LuaSocket with a hard 5 second ceiling, and the auto loop
  backs off when it fails. Both of those are only acceptable because a request that times out is not
  a LOST capture: it lands here and goes out on the next tick. Without this buffer, one dropped
  packet during a fight silently costs eighteen people their attendance credit for that interval,
  and nobody finds out until DKP is wrong.

  WHY IT IS DELIBERATELY NOT A DISK LOG. Captures are short-lived observations.
  v0.40.28 binds the event before sending; the exact eventId and capturedAt survive
  retries. The server rejects closed destinations and stale observations. Keeping
  old reports across client restarts would not reconstruct missing attendance and
  would leave misleading pending work. GUI captures are never queued.

  Everything below follows from that:

    - Entries EXPIRE, in minutes rather than hours (`max_age_seconds`). Past that horizon the safe
      action is to drop the capture, not to deliver it.
    - The buffer lives in memory only, so a client restart discards it. That is the correct
      behaviour and not a limitation: by the time a client has crashed and relaunched, minutes have
      passed and replaying is exactly the hazard above.
    - A capture is only ever queued for failures that MIGHT succeed later: a transport failure or a
      5xx. A 4xx is the server saying no on purpose (bad signature, no open check-in window), and
      retrying it would either never succeed or, in the 422 case, keep a capture alive precisely
      long enough to misfile it.

  Replaying is otherwise safe: `Presence`'s `(snapshotId, membershipId)` unique constraint plus
  `skipDuplicates` makes re-reporting an already-recorded member a no-op (`recorded: 0`), never a
  double count (README section 1a). Only the ID header pair is re-derived on the way out, because
  the HMAC timestamp window is about replay protection on the WIRE; the body, `capturedAt` included,
  goes back out byte for byte as it was captured.

  PURE POLICY, like lib/hud.lua. No `require`, no Windower API, no transport, no file access and no
  clock read: `now` is always a parameter. lootryx.lua owns the ten lines that actually call the
  network. That keeps the compliance surface where the scanner already looks, and it is what makes
  every expiry and eviction rule here testable without waiting real seconds.
]]

local M = {}

-- Cap and horizon. Both are ceilings on damage rather than tuning knobs: the cap bounds memory if
-- an endpoint stays down for an evening, and the horizon is the "could this still be the same
-- event?" window described above. Ten minutes bounds local memory retention; the server can reject stale observations earlier.
-- The stored eventId, not this time horizon, prevents cross-event delivery.
M.DEFAULT_MAX_ENTRIES = 32
M.DEFAULT_MAX_AGE_SECONDS = 600

function M.new(options)
  options = options or {}
  return {
    entries = {},
    max_entries = options.max_entries or M.DEFAULT_MAX_ENTRIES,
    max_age_seconds = options.max_age_seconds or M.DEFAULT_MAX_AGE_SECONDS,
    -- Counters, so `//lootryx status` can tell a player that captures were DROPPED rather than
    -- quietly showing an empty queue. A retry buffer that discards work silently is a worse failure
    -- than no retry buffer, because it removes the symptom that would have prompted a question.
    dropped_expired = 0,
    dropped_overflow = 0,
  }
end

--[[
  Should a failed attempt be retried at all?

  `status` is the HTTP status, or nil when the transport never got an answer (refused, timed out,
  DNS). nil and 5xx are worth retrying; everything else is the server having made a decision.

  422 is the interesting one and the reason this is a function rather than an inline `not status`.
  It is what `/snapshot` returns when no check-in window is open, and it is exactly the case where
  retrying is actively harmful: the capture would sit in the buffer waiting for SOME window to open,
  and the next one to open might belong to a different event.
]]
function M.should_retry(status)
  if status == nil then
    return true
  end
  local numeric = tonumber(status)
  if not numeric then
    return true
  end
  return numeric >= 500 and numeric < 600
end

--- Drops everything past the horizon. Returns how many went.
function M.prune(queue, now)
  local live, dropped = {}, 0
  for _, entry in ipairs(queue.entries) do
    if (now - entry.at) <= queue.max_age_seconds then
      live[#live + 1] = entry
    else
      dropped = dropped + 1
    end
  end
  queue.entries = live
  queue.dropped_expired = queue.dropped_expired + dropped
  return dropped
end

--[[
  Adds one attempt. `url` and `body` are stored exactly as they were built, unsigned: signing
  happens at flush time, because the timestamp/nonce header pair has a validity window and a
  signature minted now would be stale by the time it went out.

  Eviction is OLDEST FIRST when the cap is hit. That is the right end to drop from given the horizon
  above: the oldest pending capture is the one closest to being unsafe to deliver anyway, while the
  newest is the one most likely to still belong to the event that is open.
]]
function M.push(queue, url, body, now)
  M.prune(queue, now)
  queue.entries[#queue.entries + 1] = { url = url, body = body, at = now }
  while #queue.entries > queue.max_entries do
    table.remove(queue.entries, 1)
    queue.dropped_overflow = queue.dropped_overflow + 1
  end
  return #queue.entries
end

--- The next entry still inside the horizon, removed from the buffer, or nil when there is nothing
--- safe left to send. Expired entries are discarded here too, so a caller that only ever calls
--- `take` still cannot deliver something stale.
function M.take(queue, now)
  M.prune(queue, now)
  if #queue.entries == 0 then
    return nil
  end
  return table.remove(queue.entries, 1)
end

--[[
  Puts a taken entry BACK after a retry failed, preserving its ORIGINAL capture time.

  Re-adding through `push` would stamp it with the current time, and an entry whose age resets on
  every attempt never expires: a capture that cannot be delivered would live in the buffer
  indefinitely and eventually be credited to whatever event happened to be open, which is precisely
  the failure this file's horizon exists to prevent. Keeping `at` fixed means the horizon counts
  from when the players were actually seen, no matter how many times delivery is attempted.

  It goes back at the FRONT, because it is still the oldest thing here and the buffer is FIFO.
]]
function M.requeue(queue, entry, now)
  table.insert(queue.entries, 1, entry)
  M.prune(queue, now)
  while #queue.entries > queue.max_entries do
    table.remove(queue.entries, 1)
    queue.dropped_overflow = queue.dropped_overflow + 1
  end
  return #queue.entries
end

function M.size(queue)
  return #queue.entries
end

--- One line for `//lootryx status`, or nil when there is nothing worth saying. Mentions drops,
--- because a capture that was thrown away is the thing a player most needs to know about.
function M.status_line(queue, now)
  M.prune(queue, now)
  local pending = #queue.entries
  local dropped = queue.dropped_expired + queue.dropped_overflow
  if pending == 0 and dropped == 0 then
    return nil
  end
  local line = tostring(pending) .. ' capture(s) waiting to retry'
  if dropped > 0 then
    line = line .. ', ' .. tostring(dropped) .. ' given up on (too old to credit safely)'
  end
  return line
end

return M
