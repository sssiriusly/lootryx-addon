--[[
  Lootryx addon · HUD content builder (docs/prds/addon-ground-truth.md §5, ADDON-GT-3).

  PURE LOGIC. No Windower API, no Ashita API, no network, no file I/O, no clock read: this file
  turns state the addon has ALREADY fetched into a list of lines, and a loader-specific renderer
  draws them. Windower draws with text objects; Ashita will draw the same lines with ImGui. Neither
  renderer holds its own copy of what the HUD says.

  That split is not only tidiness. The PRD requires the HUD to "issue no network call of its own",
  and this structure makes that true by construction rather than by review: the builder has nothing
  to issue a call WITH. It cannot fetch, it cannot poll, it cannot read the game. It is handed a
  table and returns strings. `now_ms` is a parameter for the same reason, which also makes every
  countdown below deterministically testable.

  ── The state table ────────────────────────────────────────────────────────────────────────────
  Every field is optional; absent means "the player has not run the command that fetches it".

    {
      dkp      = { headline = 250, splitVisible = false },        -- from //lootryx dkp | auctions
      auctions = { { itemName, mode, tier, tierMinimum, endsAtMs, myBid = {amount, percent, lane} } },
      windows  = { { name, zone, status, openAtMs, closeAtMs } }, -- from //lootryx windows
      event    = { alliance = 12, auto = true, lastSnapAtMs = 1700000000000, snapOk = true },
    }

  ── What it never shows ────────────────────────────────────────────────────────────────────────
  Another member's bid, or another member's balance. Neither is even reachable: the `/me` response
  the state is built from does not contain them (apps/api/src/modules/ingest/auction-support.ts).
]]

local M = {}

-- The narrowest the overlay ever draws. Below this a short box would let the right-aligned mode tag
-- and countdown slide left every time a value loses a digit, which reads as the box twitching.
M.MIN_WIDTH = 26

--[[
  ── COLOUR, PER VALUE ──────────────────────────────────────────────────────────────────────────

  Windower's texts library reads inline colour codes: `\cs(r,g,b)` opens a colour and `\cr` closes
  it back to the object's base colour. This is the ordinary idiom across installed addons
  (EraInfoBar, DistancePlus, Debuffed and a dozen more all build lines this way), and it is what
  turns this overlay from a wall of one-colour text into something readable at a glance.

  The MODE colour stays the box's base, so the whole thing still reads as red/gold/blue/white from
  the corner of your eye. These are the exceptions layered on top: the handful of values whose
  meaning is worth a colour of its own.

  Two rules keep it from becoming a rainbow:

    1. CHROME IS DIM. Labels, units and separators sit back so the numbers come forward. Most of the
       gain here is not from colouring values brightly, it is from getting everything that is not a
       value out of the way.
    2. A COLOUR MEANS ONE THING. Green is good or additive, red is bad or subtractive, amber is
       pending, gold is your own balance. Nothing is coloured for variety.
]]
local C = {
  dim = '\\cs(150,145,135)',
  bright = '\\cs(245,243,238)',
  gold = '\\cs(255,200,90)',
  good = '\\cs(130,220,140)',
  bad = '\\cs(255,105,97)',
  pending = '\\cs(240,190,90)',
  off = '\\cr',
}

--- Wraps `text` in a colour and closes it again. Never leaves a colour open, so one block cannot
--- bleed into the next when the caller concatenates them.
local function tint(colour, text)
  return colour .. tostring(text) .. C.off
end

--[[
  The line as it will LOOK, with the colour codes removed.

  Needed for two different reasons, and both matter. Alignment is computed from visible width, so a
  `#line` that counted markup would push the right-aligned countdown off the edge by roughly twelve
  characters per colour used. And tests assert on what a player reads, not on the escape codes, so
  this is what they compare against.
]]
function M.plain(line)
  if type(line) ~= 'string' then
    return ''
  end
  return (line:gsub('\\cs%(%d+,%d+,%d+%)', ''):gsub('\\cr', ''))
end

-- Coarse countdown, "2h 15m" / "45m" / "<1m". This is THE formatter for chat output, and it lives
-- here rather than in lootryx.lua so the HUD and the chat commands cannot drift apart; lootryx.lua
-- binds its own `format_duration_short` to this function.
--
-- Callers clamp to >= 0 before calling, so this never has to render a negative duration.
function M.format_duration(total_seconds)
  if total_seconds < 60 then
    return '<1m'
  end
  local total_minutes = math.floor(total_seconds / 60)
  local hours = math.floor(total_minutes / 60)
  local minutes = total_minutes % 60
  if hours > 0 then
    return tostring(hours) .. 'h ' .. tostring(minutes) .. 'm'
  end
  return tostring(minutes) .. 'm'
end

-- Precise countdown for the HUD, which is a different job from the one above and deliberately a
-- different function rather than a flag. A treasure-pool auction closes in under four minutes, so
-- "<1m" is useless exactly when the overlay matters most: a player deciding whether they still have
-- time to bid needs seconds. Above ten minutes the seconds are noise, so it falls back to the
-- coarse form and the two agree everywhere it matters.
function M.format_countdown(total_seconds)
  if total_seconds < 0 then
    total_seconds = 0
  end
  if total_seconds >= 600 then
    return M.format_duration(total_seconds)
  end
  local minutes = math.floor(total_seconds / 60)
  local seconds = total_seconds % 60
  if minutes > 0 then
    return tostring(minutes) .. 'm ' .. tostring(seconds) .. 's'
  end
  return tostring(seconds) .. 's'
end

-- Auction decisions need seconds even for longer windows.
function M.format_auction_countdown(total_seconds)
  local seconds=math.max(0,math.floor(tonumber(total_seconds) or 0))
  local hours=math.floor(seconds/3600)
  local minutes=math.floor(seconds%3600/60)
  return (hours>0 and (hours..'h ') or '')..((hours>0 or minutes>0) and (minutes..'m ') or '')..(seconds%60)..'s'
end

-- Same defensive coercion the chat renderers use, and for the same reason: only the REQUEST is
-- HMAC-signed, so a malformed response field must degrade to a placeholder rather than throw.
local function safe_str(value, fallback)
  if type(value) == 'string' then
    return value
  end
  return fallback or '?'
end

local function safe_num(value, fallback)
  if type(value) == 'number' then
    return value
  end
  return fallback or 0
end

local function seconds_until(at_ms, now_ms)
  return math.max(0, math.floor((safe_num(at_ms, 0) - now_ms) / 1000))
end

-- The open auction closing FIRST, which is the only one a player can still miss.
local function soonest_auction(auctions, now_ms)
  if type(auctions) ~= 'table' then
    return nil
  end
  local best, best_ends
  for _, row in ipairs(auctions) do
    if type(row) == 'table' then
      local ends_at = safe_num(row.endsAtMs, 0)
      -- Already closed rows are skipped rather than shown at 0s: the server sweeps them on the next
      -- fetch, and an overlay insisting on a dead auction is worse than showing nothing.
      if ends_at > now_ms and (not best_ends or ends_at < best_ends) then
        best, best_ends = row, ends_at
      end
    end
  end
  return best
end

--[[
  The event whose check-in is open now, soonest to close.

  This is the one deadline in the whole product you lose by STANDING STILL. An auction closes
  whether or not you are at the keyboard and the result is the same either way; a check-in that
  closes while you are fighting means the attendance you actually earned does not count. That is
  what the overlay is for, so it outranks everything below it.

  Closed rows are skipped rather than shown at 0s, the same rule the auction finder follows: an
  overlay insisting on a window that has already gone is worse than showing nothing.
]]
local function open_checkin(events, now_ms)
  if type(events) ~= 'table' then
    return nil
  end
  local best, best_until
  for _, row in ipairs(events) do
    if type(row) == 'table' then
      local until_ms = safe_num(row.checkInOpenUntilMs, 0)
      if until_ms > now_ms and (not best_until or until_ms < best_until) then
        best, best_until = row, until_ms
      end
    end
  end
  return best
end

-- An OPEN window always outranks a future one, however soon the future one is: open means the
-- target can pop now. Among equals, the one changing state soonest.
local function active_window(windows, now_ms)
  if type(windows) ~= 'table' then
    return nil
  end
  local best, best_rank, best_at
  for _, row in ipairs(windows) do
    if type(row) == 'table' then
      local status = safe_str(row.status, '')
      local rank, at
      if status == 'OPEN' then
        rank, at = 1, safe_num(row.closeAtMs, 0)
      else
        rank, at = 2, safe_num(row.openAtMs, 0)
      end
      -- A window whose transition is already in the past carries no countdown worth drawing.
      if at > now_ms and (not best_rank or rank < best_rank or (rank == best_rank and at < best_at)) then
        best, best_rank, best_at = row, rank, at
      end
    end
  end
  return best, best_rank, best_at
end

--[[
  What is open and how long is left, then what to do about it.

  Says whether you have ALREADY posted, because "check in" and "you are counted" are different
  states and only one of them needs you. Your own answer is the only signup fact the server sends
  the addon, and it is the fact that decides whether this line is an instruction or a reassurance.
]]
local function checkin_block(row, now_ms, state)
  local left_seconds = seconds_until(row.checkInOpenUntilMs, now_ms)
  local clock = tint(left_seconds < 60 and C.bad or C.good, M.format_countdown(left_seconds))
  local lines = {
    { left = tint(C.bright, safe_str(row.title, '(untitled event)')), right = clock },
  }

  -- `snapOk` is set by the last snapshot this session, which is the only thing the addon can know
  -- for certain: a snapshot posted earlier today from another sitting is not something it saw.
  local posted = type(state) == 'table' and type(state.event) == 'table' and state.event.snapOk == true
  -- `right` is always a string, never nil: the renderer measures and concatenates both halves of an
  -- aligned pair unconditionally, so an absent right-hand side is the empty string.
  local answered = type(row.mySignup) == 'string' and row.mySignup ~= ''
  lines[#lines + 1] = {
    left = posted and tint(C.good, 'counted') or tint(C.dim, '//lootryx snap'),
    right = answered and tint(C.dim, safe_str(row.mySignup, ''):lower()) or '',
  }
  return lines
end

local function auction_block(row, now_ms, state)
  -- The two facts a player opens this box for -- WHAT is closing and HOW LONG is left -- now share
  -- the first line, countdown right aligned. The verb went with them: a ticking clock in a gold box
  -- tagged AUCTION cannot mean anything else, and dropping "closes in" keeps the box width stable
  -- as the countdown shrinks from `2m 41s` to `59s`.
  -- The countdown turns RED inside the last minute. The box is already gold because an auction is
  -- open; this says the different thing, that it is nearly gone, without spending a whole mode on it.
  local left_seconds = seconds_until(row.endsAtMs, now_ms)
  local clock = tint(left_seconds < 60 and C.bad or C.bright, M.format_countdown(left_seconds))
  local lines = {
    { left = tint(C.bright, safe_str(row.itemName, '(unknown item)')), right = clock },
  }

  local mode = safe_str(row.mode, 'TIERED')
  local terms
  if mode == 'PERCENTAGE' then
    terms = 'bid a %'
  elseif mode == 'ALL_IN' then
    terms = 'ALL-IN'
  elseif mode == 'FIXED' then
    terms = 'buy at ' .. tostring(safe_num(row.fixedPrice, 0))
  elseif safe_num(row.tierMinimum, 0) > 0 then
    terms = 'min ' .. tostring(safe_num(row.tierMinimum, 0))
  else
    terms = 'sealed bid'
  end
  -- The countdown comes SECOND, directly under the item name, because it is the thing a player is
  -- actually looking at the overlay to find out. The terms below it change how much to bid; the
  -- countdown changes whether bidding is still possible at all.
  -- No `[?]` when the tier is missing: an empty bracket is a question the overlay cannot answer and
  -- the reader cannot act on.
  local tier = safe_str(row.tier, '')
  local terms_line = (tier ~= '' and tier ~= '?') and (tint(C.dim, '[' .. tier .. '] ') .. terms) or terms

  -- Your balance belongs HERE, not only in the resting state. The old overlay showed your DKP while
  -- nothing was happening and hid it the moment an auction opened, which is exactly backwards for
  -- someone deciding whether they can afford to raise.
  local dkp = type(state) == 'table' and type(state.dkp) == 'table' and state.dkp or nil
  if dkp and dkp.splitVisible ~= true then
    terms_line = terms_line .. tint(C.dim, ' | DKP ') .. tint(C.gold, tostring(safe_num(dkp.headline, 0)))
  end
  lines[#lines + 1] = terms_line

  -- YOUR bid, or the absence of one. "no bid yet" is the more useful of the two states to see on an
  -- overlay: it is the one that still needs an action.
  if type(row.myBid) == 'table' then
    local offer
    if type(row.myBid.percent) == 'number' then
      offer = tostring(row.myBid.percent) .. '%'
    else
      offer = tostring(safe_num(row.myBid.amount, 0)) .. ' DKP'
    end
    local lane = (safe_str(row.myBid.lane, 'MAIN') == 'LOW') and ', low lane' or ''
    -- `lane` is usually empty, and tinting an empty string emits an open-and-close pair that says
    -- nothing. Harmless to render, but it makes the line harder to read in a test failure.
    local suffix = lane ~= '' and tint(C.dim, lane) or ''
    lines[#lines + 1] = tint(C.dim, 'you bid ') .. tint(C.bright, offer) .. suffix
  else
    -- The state that still needs something from you, so it is the one that gets a colour.
    lines[#lines + 1] = tint(C.pending, 'no bid yet')
  end

  return lines
end

local function watch_block(row, rank, at, now_ms)
  local lines = { tint(C.bright, safe_str(row.name, '(unknown target)')) }
  local zone = safe_str(row.zone, '')
  if zone ~= '' then
    lines[#lines + 1] = tint(C.dim, zone)
  end
  if rank == 1 then
    -- Merged, so the open and pending states are the same height. "left" rather than "closes in"
    -- keeps it inside the box at `2h 15m`, where the longer verb would overflow.
    lines[#lines + 1] = tint(C.good, 'WINDOW OPEN') .. tint(C.dim, ', ') .. tint(C.bright, M.format_countdown(seconds_until(at, now_ms))) .. tint(C.dim, ' left')
  else
    lines[#lines + 1] = tint(C.dim, 'opens in ') .. tint(C.bright, M.format_countdown(seconds_until(at, now_ms)))
  end
  return lines
end

--[[
  ── THE ALERT ZONE, which outranks even a closing auction ───────────────────────────────────────

  Every other state below assumes reports are actually landing. When they are not, a player stands
  at a camp for three hours believing their attendance is being recorded, and finds out days later
  when DKP is wrong. That is the worst outcome this overlay can prevent, so "the addon is not
  working" takes the top slot and is deliberately blunt.

  Only two things qualify, and the discipline matters: an alert that never clears is an alert
  everybody learns to ignore. Both of these are unambiguous, both are the player's to fix, and both
  disappear the moment they are fixed.

    dev credentials  nothing you do reaches your shell at all. The single most important thing to
                     tell someone who has just installed this.
    401 / 403        the key was rejected. Reports are being made and thrown away.

  Deliberately NOT alerts, because they are ordinary states that would latch red forever:
    422              "no check-in window is open" is the normal condition of not being at an event,
                     and `auto` produces it every interval while you are anywhere else.
    dropped captures a past loss is worth showing, but it is history rather than something to act
                     on, so it goes in the status line instead.
]]
local function alert_block(state)
  local config = type(state.config) == 'table' and state.config or {}
  local ingest = type(state.ingest) == 'table' and state.ingest or {}

  if config.dev == true then
    -- The one state a brand new member is guaranteed to see, so it gets the WHOLE story: what is
    -- wrong, what it costs them, and where to go. "edit data/settings.xml" was true and useless,
    -- because someone who has just installed this does not have a key to put in it yet and nothing
    -- on screen told them that keys come from the website.
    local where = safe_str(config.site, 'lootryx.com')
    return {
      'NOT LINKED',
      tint(C.dim, 'nothing is being recorded'),
      tint(C.bright, 'get your key at'),
      tint(C.bright, where),
      tint(C.dim, 'then //lua reload lootryx'),
    }
  end

  local status = safe_num(ingest.status, 0)
  if ingest.ok == false and (status == 401 or status == 403) then
    return {
      'NOT RECORDING',
      tint(C.dim, 'key rejected (') .. tostring(status) .. tint(C.dim, ')'),
      tint(C.bright, '//lootryx status'),
    }
  end

  return nil
end

--[[
  ── THE RESTING STATE ──────────────────────────────────────────────────────────────────────────

  What the overlay says when nothing has a deadline: your balance, and whether attendance capture is
  actually running. This is the state a player looks at for most of an evening, so it earns its
  space by answering "is this thing working?" without being asked.
]]
local function event_block(state, now_ms)
  local lines = {}
  local dkp = type(state.dkp) == 'table' and state.dkp or nil
  if dkp then
    -- One number. A member holding several wallets is NOT summed here (summing would state a
    -- fungibility that does not exist); the overlay is too small for the breakdown, so it points at
    -- the command that shows it properly.
    if dkp.splitVisible == true then
      lines[#lines + 1] = tint(C.dim, 'DKP: see ') .. tint(C.bright, '//lootryx dkp')
    else
      lines[#lines + 1] = tint(C.dim, 'DKP ') .. tint(C.gold, tostring(safe_num(dkp.headline, 0)))
    end
  end

  local event = type(state.event) == 'table' and state.event or nil
  if event then
    local bits = {}
    if type(event.alliance) == 'number' and event.alliance > 0 then
      bits[#bits + 1] = tint(C.dim, 'alliance ') .. tint(C.bright, tostring(event.alliance))
    end
    if event.auto ~= nil then
      bits[#bits + 1] = tint(C.dim, 'auto ')
        .. (event.auto and tint(C.good, 'on') or tint(C.dim, 'off'))
    end
    if #bits > 0 then
      -- ` | ` rather than two spaces: `alliance 17  auto on` is fine, but the same rule has to
      -- hold for the chips line below, where `roster +3 -1  2 queued` reads as `-12 queued`.
      lines[#lines + 1] = table.concat(bits, tint(C.dim, ' | '))
    end
    -- Epoch MILLISECONDS, like every other timestamp in this file, so the elapsed time is derived
    -- from the caller's `now_ms` rather than baked in by whoever wrote the state. A state table
    -- written once and rendered for the next hour would otherwise keep saying "last snap 0m ago".
    if type(event.lastSnapAtMs) == 'number' then
      local ago = math.max(0, math.floor((now_ms - event.lastSnapAtMs) / 1000))
      -- `do_snap` sets snapOk=false on EVERY non-200, and the most common non-200 by far is the
      -- routine 422 for "no check-in window is open", which is simply what being anywhere but an
      -- event looks like. Marking that FAILED painted the word on screen all evening for a player
      -- doing nothing wrong: the same latch-forever problem the alert zone above is careful to
      -- avoid, one line lower. The 422 case is not a failure of the addon, so this line reports
      -- the addon's action plainly and the status chip below carries the server's answer.
      local ingest = type(state.ingest) == 'table' and state.ingest or nil
      local routine = safe_num(event.snapStatus, ingest and ingest.status or 0) == 422
      local failed = event.snapOk == false and not routine
      local head = failed and (tint(C.dim, 'last snap ') .. tint(C.bad, 'FAILED ')) or tint(C.dim, 'last snap ')
      lines[#lines + 1] = head .. tint(C.bright, M.format_duration(ago)) .. tint(C.dim, ' ago')
      if event.snapOk==false and event.snapReason then lines[#lines+1]=tint(C.dim,tostring(event.snapReason):sub(1,80)) end
    end
  end

  return lines
end

--[[
  ── THE STATUS LINE, drawn in EVERY mode ───────────────────────────────────────────────────────

  The overlay's original design showed exactly one of three states, which meant that the moment an
  auction opened, everything about whether capture was working vanished from the screen. That is
  precisely backwards: a bid window is when the most people are at camp and when a silently broken
  capture costs the most.

  So operational state gets its own line and is never displaced. It is terse because it is read at a
  glance by someone busy, and it says NOTHING when there is nothing to say rather than drawing a row
  of zeroes.

  Every entry is something that quietly changes what is being recorded, and that a player would
  otherwise have to type `//lootryx status` to find out:

    roster +2 -1   a session correction is live. It changes who earns DKP, so it belongs wherever
                   the person who set it is already looking.
    3 queued       captures are waiting to retry. Nothing lost yet.
    1 lost         captures aged out uncredited. History, not an action, but never hidden.
    no check-in open  the ordinary 422: not at an open event, so a capture has nowhere to land.
    2 macro edits  web edits are waiting to be pulled down.
]]
local function status_line(state)
  local bits = {}

  local roster = type(state.roster) == 'table' and state.roster or nil
  if roster then
    local added, removed = safe_num(roster.added, 0), safe_num(roster.removed, 0)
    if added > 0 or removed > 0 then
      -- Green adds, red removes. The two halves of a roster correction do opposite things to
      -- somebody's DKP, and reading them as one grey blob is how a stale correction survives.
      local text = tint(C.dim, 'roster')
      if added > 0 then
        text = text .. ' ' .. tint(C.good, '+' .. tostring(added))
      end
      if removed > 0 then
        text = text .. ' ' .. tint(C.bad, '-' .. tostring(removed))
      end
      bits[#bits + 1] = text
    end
  end

  local queue = type(state.queue) == 'table' and state.queue or nil
  if queue then
    if safe_num(queue.pending, 0) > 0 then
      bits[#bits + 1] = tint(C.pending, tostring(safe_num(queue.pending, 0))) .. tint(C.dim, ' queued')
    end
    if safe_num(queue.dropped, 0) > 0 then
      bits[#bits + 1] = tint(C.bad, tostring(safe_num(queue.dropped, 0))) .. tint(C.dim, ' lost')
    end
  end

  local ingest = type(state.ingest) == 'table' and state.ingest or nil
  if ingest and ingest.ok == false and safe_num(ingest.status, 0) == 422 then
    -- "no check-in" reads as "you forgot to check in" and invites a player to spam `snap` at it.
    -- The actual state is that no window is OPEN, and opening one is an officer's job, not theirs.
    bits[#bits + 1] = tint(C.dim, 'no check-in open')
  end

  local macros = type(state.macros) == 'table' and state.macros or nil
  if macros and safe_num(macros.pendingPull, 0) > 0 then
    bits[#bits + 1] = tint(C.pending, tostring(safe_num(macros.pendingPull, 0))) .. tint(C.dim, ' macro edits')
  end

  if #bits == 0 then
    return nil
  end
  -- A number against a number is one number at a glance: with two spaces, `roster +3 -1  2 queued`
  -- reads as `-12 queued`. The roster chip is the only one that ends in a digit, and it is also the
  -- most common pairing during an event.
  return table.concat(bits, tint(C.dim, ' | '))
end

--[[
  The lines to draw, top to bottom, or an EMPTY table when there is nothing to say.

  TWO ZONES, which is the change from the original one-of-three design.

  A FOCUS block, the single most urgent thing, ordered by how badly a delay costs you:

    alert    the addon is not working. Outranks everything, because every state below it is an
             implicit claim that reports are landing, and if they are not then all of them lie.
    auction  a closing bid window is the only ordinary thing here with a deadline you can miss.
    watch    an open HNM window is urgent, but it is not gone in ninety seconds.
    event    your balance and whether capture is running. Always available, so it rests here rather
             than competing.

  And a STATUS line, drawn in every mode, carrying the operational state that used to disappear the
  instant anything more urgent appeared. See `status_line` for why that was backwards.

  Returns lines, mode. The mode drives the header AND the text colour in the renderer, so urgency is
  readable without reading, and it lets tests assert which state won rather than inferring it from
  the text.
]]
function M.build_lines(state, now_ms)
  if type(state) ~= 'table' then
    return {}, nil
  end

  local focus, mode

  focus = alert_block(state)
  if focus then
    mode = 'alert'
  end

  -- Above auctions on purpose: an auction closes the same way whether or not you are watching, and
  -- a check-in you miss costs you attendance you actually earned.
  if not mode then
    local checkin = open_checkin(state.events, now_ms)
    if checkin then
      focus, mode = checkin_block(checkin, now_ms, state), 'checkin'
    end
  end

  if not mode then
    local auction = soonest_auction(state.auctions, now_ms)
    if auction then
      focus, mode = auction_block(auction, now_ms, state), 'auction'
    end
  end

  if not mode then
    local window, rank, at = active_window(state.windows, now_ms)
    if window then
      focus, mode = watch_block(window, rank, at, now_ms), 'watch'
    end
  end

  if not mode then
    local event = event_block(state, now_ms)
    if #event > 0 then
      focus, mode = event, 'event'
    end
  end

  local status = status_line(state)

  if not mode and not status then
    -- Nothing fetched yet, or nothing worth saying. The renderer hides the overlay entirely rather
    -- than drawing an empty frame.
    return {}, nil
  end

  local lines = {}
  for _, line in ipairs(focus or {}) do
    lines[#lines + 1] = line
  end
  if status then
    -- A blank spacer only when there is something above it to separate from, so an overlay showing
    -- only operational state does not open with an empty row.
    if #lines > 0 then
      lines[#lines + 1] = ''
    end
    lines[#lines + 1] = status
  end

  -- ── ONE box width, computed once, used by every right-aligned thing ──────────────────────────
  --
  -- A left-aligned block in a monospace box has no right edge, so the mode tag and the auction
  -- countdown had nothing to sit against. Measuring the widest line gives them one, and pinning a
  -- MINIMUM keeps a short box from making the header tag jump left every time the countdown loses
  -- a digit. Byte length is the right measure here: the English client's item and zone names are
  -- ASCII, and this file deliberately emits no multi-byte characters (a middle dot or a box-drawing
  -- rule that renders as `?` in the alert state is the worst failure available).
  local width = M.MIN_WIDTH
  for _, line in ipairs(lines) do
    -- Measured on the STRIPPED text. A `#line` that counted colour markup would over-measure by
    -- roughly a dozen characters per colour and push the right-aligned countdown off the box.
    local candidate
    if type(line) == 'table' then
      candidate = #M.plain(line.left) + 2 + #M.plain(line.right)
    else
      candidate = #M.plain(line)
    end
    if candidate > width then
      width = candidate
    end
  end

  -- Materialize the aligned pairs now that the width is known.
  for index, line in ipairs(lines) do
    if type(line) == 'table' then
      local gap = width - #M.plain(line.left) - #M.plain(line.right)
      if gap < 2 then
        gap = 2
      end
      lines[index] = line.left .. string.rep(' ', gap) .. line.right
    end
  end

  -- Status-only is a real state: there IS something to say, so the overlay must draw, and must not
  -- report "no mode" (which the renderer treats as nothing to show). It rests at `event`, the least
  -- urgent colour.
  return lines, mode or 'event', width
end

return M
