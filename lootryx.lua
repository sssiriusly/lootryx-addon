--[[
  Lootryx · FFXI attendance addon for Windower4.

  WHAT IT DOES (and ONLY this):
    * Reads party / alliance member NAMES via the public read-only Windower API
      (windower.ffxi.get_party / get_player). No memory writes, no packet
      injection, no gameplay automation. It only reads and reports outward.
    * Signs a snapshot with per-actor HMAC-SHA256 and POSTs it to the Lootryx
      ingest endpoint over LuaSocket.
    * //lootryx status prints its OWN local state (key id masked, api_base, shell,
      auto mode, and the outcome of the last ingest POST) to the chat log. Still a
      read: no new network call, no game action.
    * (EPIC MACRO M2) Reads your OWN local macro book DAT files (mcrN.dat / mcr.ttl,
      lib/macros.lua) to sync your macros to Lootryx.
    * (EPIC MACRO M4, this version) WRITES pulled web edits back to those SAME local macro
      files, and ONLY those files. Per the amended CLAUDE.md invariant 1 (owner decision
      2026-07-18), this is local-config editing, not an in-game action: it never sends
      anything to the game server, never touches game memory, never injects a packet. The
      write path is whitelisted in code (lib/macros.lua: basename must match mcr%d*.dat or
      mcr.ttl, resolved under the configured macro dir), backs up the original file to
      `.bak` before every overwrite, and REFUSES to write whichever book you currently have
      open in-game (FFXI holds it in memory and would flush a stale copy back over the
      write on your next zone/logout). This command never runs from the render loop, only
      when you type it. See addon/README.md §1b/§8.
    * (owner decision 2026-07-29, manual ToD reporting) `//lootryx tod <target name>` reports
      a Time of Death you just witnessed and POSTs it to the LIVE `/api/ingest/tod` route,
      crediting YOU as the reporter. COMMAND-TRIGGERED ONLY, same class as `//lootryx macros
      push` above: no kill-event hook, no combat/death/packet event registration, never
      called from the `prerender` loop. `killedAt` is always "now" at send time; there is no
      backdating argument (an officer's Discord `/tod` command stays the unbounded, backdating
      path). See addon/README.md §1c.
    * (docs/prds/addon-ground-truth.md, this version) `//lootryx hud on|off` draws a small
      on-screen overlay of whatever is most urgent (a closing auction, an open HNM window, your
      DKP). OFF by default. It performs NO network request of any kind: it only re-formats data a
      command you typed already fetched, and lib/hud.lua has no transport to call. See §1f.
    * (docs/prds/addon-ground-truth.md, this version) `//lootryx auctions`, `//lootryx bid`,
      `//lootryx allin` and the officer-only `//lootryx auction <item>` read and place SEALED BIDS
      over HTTP. Bidding is a POST to Lootryx and nothing else: no lotting, no claiming, no
      treasure-pool interaction, no automatic or timed bidding, and no in-game action of any kind.
      Every bidding rule is enforced server-side; this file only formats what it is told.
    * (docs/prds/addon-ground-truth.md, this version) `//lootryx drop <item> <winner>` reports a
      drop you just witnessed being awarded and POSTs it to the LIVE `/api/ingest/drop` route.
      COMMAND-TRIGGERED ONLY, same class as `//lootryx tod`: no loot/treasure-pool event hook, no
      automatic drop detection, never called from the `prerender` loop. `capturedAt` is always
      "now" at send time. See addon/README.md §1c.
    * (docs/prds/addon-read-commands.md, this version) `//lootryx dkp`, `//lootryx standings
      [pool]`, and `//lootryx windows` each POST the SAME new composite READ route,
      `/api/ingest/me`, the ingest surface's FIRST read endpoint (every route above is a write
      or a command). COMMAND-TRIGGERED ONLY, never from the `prerender` loop: nothing here
      mutates anything server-side (no writes, no audit rows), it only fetches the caller's own
      DKP balance(s), a standings board, and the shell's tracked HNM windows over the SAME
      HMAC-signed transport. See addon/README.md §1d.

  Operations, all using the SAME signing transport verified in addon/README.md:
    //lootryx link <code>   -> POST <api_base>/link      (IMPLEMENTED server-side today)
    //lootryx snap          -> POST <api_base>/snapshot   (IMPLEMENTED server-side today, live
                                                            at /api/ingest/snapshot)
    //lootryx macros push   -> POST <api_base>/macros, one changed book per request
                                                           (IMPLEMENTED server-side today, live
                                                            at /api/ingest/macros)
    //lootryx macros pull <activeBookIndex>
                             -> POST <api_base>/macros/pull, writes returned books to the LOCAL
                                macro DAT files, then POST <api_base>/macros/ack
                                                           (IMPLEMENTED, this version; see §8 above)
    //lootryx auctions      -> POST <api_base>/me   {auctions=true}, read-only
    //lootryx bid <n> ...   -> POST <api_base>/bid,  command-triggered only
    //lootryx allin <n>     -> POST <api_base>/bid   at 100%, after a typed confirmation
    //lootryx auction <it>  -> POST <api_base>/auction, officer-gated SERVER-SIDE
    //lootryx drop <item> <winner>
                             -> POST <api_base>/drop, command-triggered only, capturedAt = now
                                                           (IMPLEMENTED, this version, live at
                                                            /api/ingest/drop)
    //lootryx tod <target>  -> POST <api_base>/tod, command-triggered only, killedAt = now
                                                           (IMPLEMENTED, this version, live at
                                                            /api/ingest/tod; see §1c above)
    //lootryx dkp / standings [pool] / windows
                             -> POST <api_base>/me, ONE composite read, command-triggered only
                                                           (IMPLEMENTED, this version, live at
                                                            /api/ingest/me; see §1d above)

  Transport contract (discovered from apps/api/src/lib/hmac.ts · see README):
    headers: x-hoard-key-id, x-hoard-timestamp (unix s), x-hoard-nonce, x-hoard-signature (hex)
    signature = HMAC_SHA256(secret, timestamp .. "." .. nonce .. "." .. rawBody)

  NOTE: get_party()/get_player() shapes and http behaviour need in-game confirmation.
  Every such spot is tagged `-- VERIFY IN-GAME:`.

  Windower4 only today. Ashita v4's addon API is a genuinely different framework (its
  own memory manager, event registration, and settings persistence, no windower.*
  namespace at all), so porting is a real future job, not a thin shim; see the honesty
  note in addon/README.md. Nothing here claims Ashita support.
]]

-- Windower loads this file directly; another loader supplies an explicit platform host.
local host = ...
if type(host) ~= 'table' then
  if rawget(_G, 'AshitaCore') and rawget(_G, 'addon') then
    return loadfile(addon.path .. '/lib/ashita-host.lua')().start(function(platform)
      loadfile(platform.addon_path .. 'lootryx.lua')(platform)
    end)
  end
  host = loadfile(windower.addon_path .. 'lib/windower-host.lua')()
end
local _addon = host.metadata
_addon.name = 'Lootryx'
_addon.author = 'Sirius'
_addon.version = '0.40.31'
_addon.commands = { 'lootryx', 'lx' }

local config = host.config
local http = host.http
local ltn12 = host.ltn12
-- The host provides the shared peer/hostname-verified TLS transport. HTTPS is refused
-- when the loader TLS dependency is unavailable; there is no unverified fallback.
local https_ok, https = host.https_ok, host.https
-- Vendored pure-Lua HMAC-SHA256 (no external deps). Loaded by absolute addon path
-- so it works regardless of package.path.
local sha2 = loadfile(host.addon_path .. 'lib/sha2.lua')()
-- Pure-Lua ingest-error -> human chat message mapping (no Windower API, see the file).
local ingest_errors = loadfile(host.addon_path .. 'lib/errors.lua')(loadfile(host.addon_path .. 'lib/json.lua')())
-- Pure-Lua JSON decoder (no Windower API, see the file). Needed to parse the /macros/pull
-- response's nested books/pages/macros shape; every other endpoint here only reads a flat
-- {ok,...} shape off individual fields and doesn't need it.
local json = loadfile(host.addon_path .. 'lib/json.lua')()
-- Pure-Lua reader/encoder/whitelisted-writer for the local macro DAT files (see the file header
-- for the full compliance note). do_macros_push() below only ever calls the READ side; the write
-- side (encode_page_bytes/write_page_file/write_titles_file, all gated by lib/macros.lua's own
-- basename+dir whitelist) is called ONLY from do_macros_pull() below, EPIC MACRO M4.
local macros_lib = loadfile(host.addon_path .. 'lib/macros.lua')(sha2, host.game_path)
-- Pure-Lua HUD content builder (ADDON-GT-3): turns already-fetched state into lines to draw. No
-- Windower API, no network, no clock read, so the overlay CANNOT poll or fetch anything (see the
-- file header). The Windower renderer below is the only half that touches a loader API; an Ashita
-- renderer would replace that half alone.
local hud_lib = loadfile(host.addon_path .. 'lib/hud.lua')()
-- The window: a PURE model (lib/window.lua, no Windower calls, harness-tested) and the Windower
-- renderer for it (lib/panel.lua). Split that way because the addon is planned for Ashita too,
-- where ImGui replaces primitives entirely: only the renderer gets written twice.
local window_lib = loadfile(host.addon_path .. 'lib/window.lua')()
loadfile(host.addon_path .. 'lib/theme-studies.lua')()(window_lib)
window_lib.navigation = loadfile(host.addon_path .. 'lib/navigation.lua')()
local panel_lib = host.panel
panel_lib.item_icons = loadfile(host.addon_path .. 'lib/item-icons.lua')().new(
  host.game_path, host.addon_path .. 'assets/item-cache/', function()
    local ok, res = pcall(host.resources)
    return ok and res.items or {}
  end)
panel_lib.bind(window_lib)
-- Pure-Lua retry-buffer policy for failed attendance posts (see the file header for why it is a
-- short-lived in-memory buffer and deliberately NOT a disk log). Like lib/hud.lua it has no
-- Windower API, no transport and no clock of its own; the ten lines that actually re-send live in
-- `do_drain_queued` below.
local queue_lib = loadfile(host.addon_path .. 'lib/queue.lua')()
-- Pure-Lua roster-correction policy: the people at camp the eighteen-slot alliance cannot show.
-- Same shape as the two above (no Windower API, no transport, no I/O, no clock).
local roster_lib = loadfile(host.addon_path .. 'lib/roster.lua')()
local client_state = loadfile(host.addon_path .. 'lib/client-state.lua')()
local client_reader = host.client_reader
-- Pure-Lua self-test runner and formatter (see its header). Holds no checks of its own: the checks
-- are built in `do_selftest` below, where the Windower reads live and where the compliance scanner
-- already looks for them.
local selftest_lib = loadfile(host.addon_path .. 'lib/selftest.lua')()
-- The window's text input. It is the ONE file that calls windower.send_command, narrowly and with
-- two literal arguments, to stop keystrokes reaching FFXI while a box has focus; its header and
-- COMPLIANCE.md §3 both spell out why that is the safe direction and how it is enforced.
local field_lib = host.field
field_lib.tod = loadfile(host.addon_path .. 'lib/tod-input.lua')()
-- Windower's text-object library, the ONLY drawing primitive this addon uses. Required lazily at
-- the top like every other dependency; an Ashita build would require its ImGui equivalent instead.
local texts = host.texts

-- Hard upper bound on how long a request may hold the client, connect included.
--
-- `post()` below is BLOCKING LuaSocket, and the prerender loop at the bottom of this file can
-- reach it (auto snapshots). LuaSocket's module default is 60 seconds, so an endpoint that accepts
-- a TCP connection and then never answers -- a hung load balancer, a hotel captive portal, a
-- half-open link after a laptop wakes -- froze the FFXI client for a full minute. Mid-fight, with
-- `auto` on, that is indistinguishable from a crash, and no reporting tool is worth costing a
-- player their character.
--
-- Deliberately a CONSTANT and not a setting: a configurable bound is one typo away from being
-- raised back to a minute, and the whole value here is that the ceiling cannot move. Five seconds
-- is many times a healthy ingest round-trip and short enough to read as a hitch. The queue in
-- `lib/queue.lua` is what makes a timeout cheap: a request that times out is not a lost capture,
-- it is a capture that drains on the next attempt.
local REQUEST_TIMEOUT_SECONDS = 5
http.TIMEOUT = REQUEST_TIMEOUT_SECONDS
if https_ok and https then
  https.TIMEOUT = REQUEST_TIMEOUT_SECONDS
end

-- The shipped demo credentials, held as their own constants rather than read back off `defaults`.
--
-- "Is this addon still unconfigured?" was originally asked as `settings.key_id == defaults.key_id`,
-- which is only true if `settings` and `defaults` are different tables. Windower's `config.load`
-- returns a merged copy so it happens to hold there, but the test harness's config stub returns the
-- SAME table, which made the comparison permanently true: the check could never clear no matter
-- what a player pasted in. Comparing against a value nothing can reach and mutate removes the
-- assumption entirely, in both places that ask the question (the overlay's alert, and selftest).
-- The shell slug the addon ships with. Like the demo credentials it is a PLACEHOLDER, not a fact,
-- and it is wrong for every linkshell except the one it was named after. It exists only so
-- settings.xml has a complete shape before anyone configures it.
local DEMO_SHELL_SLUG = 'your-shell'

--[[
  Slugs that are not answers.

  0.10.1 and earlier shipped `lootgoblins` as the default, so it is sitting in the settings.xml of
  every install that hit the bad-URL bug. Renaming the constant alone would leave exactly those
  players unfixed, since their saved value no longer matches the new placeholder. So the OLD default
  keeps counting as a placeholder too.

  The cost is that a linkshell whose slug is genuinely `lootgoblins` is treated as unset and gets the
  generic wording instead of a direct link. That is a small loss for one hypothetical shell against a
  404 for every existing install, and the generic wording is still true for them.
]]
local PLACEHOLDER_SLUGS = { ['your-shell'] = true, ['lootgoblins'] = true }

local function is_placeholder_slug(slug)
  return slug == nil or slug == '' or PLACEHOLDER_SLUGS[slug] == true
end
local DEMO_KEY_ID = 'dev-addon-key'
local DEMO_SECRET = 'hoard-dev-ingest-secret'

local defaults = {
  live_auctions = true,
  auction_refresh_interval = 15,
  notify_auction_results = true,
  notify_new_auctions = true,
  live_recruitment = true,
  live_attendance = true,
  attendance_refresh_interval = 30,
  notify_checkin = true,
  recruitment_refresh_interval = 30,
  notify_party = true,
  notify_recruitment = true,
  notify_invites = true,
  notify_ready = true,
  notify_auction_deadline = true,
  key_id = DEMO_KEY_ID,
  secret = DEMO_SECRET,
  --[[
    The character this key belongs to, recorded when it is stored.

    Windower keeps settings PER CHARACTER and falls back to <global> for a character with no section
    of its own. That is normally a convenience and here it was a trap: log in on a brand new alt and
    it inherits whichever key <global> happens to hold, so the addon reads as fully linked, the
    window shows the shell tabs, and every signed request goes out under a key that is not this
    character's. The failure is silent in the worst way, because the addon is confident.

    Empty means "an install from before this was recorded". Those are LEFT ALONE and treated as
    linked, because upgrading the addon must not log anybody out; the check only fires once a name
    has actually been written by a setup or a link.
  ]]
  linked_character = '',
  -- Base of the ingest surface. /link and /snapshot are appended. Defaults to prod so a shipped
  -- addon works out of the box; point this at a local API (http://localhost:3100/api/ingest) for
  -- dev/testing (see data/settings.example.xml).
  api_base = 'https://lootryx.com/api/ingest',
  shell_slug = DEMO_SHELL_SLUG,
  -- The FFXI world this install plays on. Only the PUBLIC routes need it: every signed route
  -- derives the world from the shell the key belongs to. It exists so a player with no linkshell
  -- can still read the server-wide board, which is the whole point of those routes.
  world = 'Phoenix',
  network_dns_cache_seconds = 300,
  -- Seconds between auto snapshots when `auto` is on.
  interval = 300,
  -- Zone heartbeat (docs/prds/zone-heartbeat-coverage.md): a slow "I am here, in this zone" ping so
  -- the shell can answer "can anyone confirm a ToD in X right now". OFF BY DEFAULT and off on BOTH
  -- sides: this one is opt-in locally as well as per-shell, because unlike everything else the
  -- addon reports, it discloses where YOU are rather than what you saw. Turning it off here stops
  -- the pings entirely without disabling any other part of the addon.
  heartbeat = false,
  -- Seconds between heartbeats. Minutes, not seconds, on purpose: this is a coverage board, not a
  -- tracker, and a tighter interval buys nothing while costing a blocking request.
  heartbeat_interval = 300,
  -- Auto-post a snapshot every `interval` seconds. Off by default: the /snapshot endpoint is
  -- live server-side (COV-1), but auto-posting stays an explicit opt-in, not a default.
  auto = false,
  -- EPIC MACRO M2: explicit override for the FFXI macro folder (containing mcrN.dat / mcr.ttl).
  -- Empty string means "auto-resolve" (macros_lib.resolve_macro_dir, best-effort, see that file);
  -- set this if auto-resolve reports it cannot read any macro files. See settings.example.xml.
  macro_dir = '',
  -- Per-book contentHash cache (keys "b1".."b20"), so `//lootryx macros push` only re-sends a book
  -- whose decoded content actually changed since the last successful push. Populated by
  -- do_macros_push() below; never read or written anywhere else.
  macro_hashes = {},
  -- ADDON-GT-3 overlay. OFF by default, per the PRD: an addon that starts drawing on someone's
  -- screen uninvited is a bad citizen, and this one is opt-in like `auto`.
  -- ON by default (owner decision, 2026-09-07). The overlay is the only place the addon tells you
  -- it is NOT working -- an unconfigured key, a rejected key, captures piling up unsent -- and a
  -- player who has to know to turn it on first is a player who finds out about all of that later,
  -- from wrong DKP. `//lootryx hud off` still hides it, and the position is still remembered.
  hud_enabled = true,
  -- Whether the window is open. Persisted so your choice comes back with you, the same way
  -- hud_enabled does. Defaults to OPEN (owner decision 2026-09-09): a window nobody knows to ask
  -- for is a window nobody uses, and the first run is exactly when a new player needs the board,
  -- the linkshell directory and the setup steps in front of them. Close it once and it stays shut.
  -- Whether the window comes up with the addon. The close button no longer writes this: closing
  -- means "not now", not "never again", and losing the window until you find the command again is
  -- not what a close button should mean. Turn it off in Settings if you want a quiet login.
  open_on_login = true,
  window_open = true,
  pointer_profile='',pointer_sx=1,pointer_sy=1,pointer_ox=0,pointer_oy=0,
  window_x = 40,
  window_y = 60,
  -- Which theme the window draws in. Vana'diel by default: it is the look of the game's own menus,
  -- which is what an overlay sitting on top of them should read as. //lootryx theme lists the rest.
  theme = 'vanadiel',
  -- Persisted position, so a player moves it once. Top-left corner, in pixels.
  hud_x = 20,
  hud_y = 200,
}

local settings = config.load(defaults)

--[[
  Saving, and knowing whether it happened.

  `config.save(t)` takes a character name as its second argument and DEFAULTS IT TO THE LOGGED IN
  CHARACTER, and its first act is:

      if char ~= 'all' and not windower.ffxi.get_info().logged_in then return end

  So a save issued from the character select or log in screen is silently discarded. Every call site
  here then went on to print `saved.` or `connected as ...`, which is a lie the player only finds
  out about on the next reload, when their credentials are gone and the addon acts like they never
  typed anything.

  This wrapper reports whether the write actually happened so callers can say so. It deliberately
  does NOT pass 'all': settings are saved per character on purpose, because `//lootryx setup` binds
  a key to one specific character.
]]
local function save_settings()
  if not host.logged_in() then
    return false
  end
  return config.save(settings) ~= false
end
math.randomseed(os.time())

-- Everything the HUD overlay is allowed to know (ADDON-GT-3), written ONLY by command handlers
-- that have just fetched something. Declared HERE, above every writer, because Lua closures capture
-- upvalues declared before them: down beside the renderer it would be a nil global to `do_snap`.
local hud_state = {}

--[[
  What the server refused to send, and why that is not the same as "there is none".

  `/me` withholds a block the caller's role may not read (a TRIAL holds neither auction:read nor
  bank:read) and names it in `denied`. Drawing an empty list for that would have the addon assert
  the shell's bank is empty, which is a lie about the player's own linkshell and precisely the
  nil-versus-empty confusion every other read here is careful about. So a refusal is its own state.
]]
local function record_denials(decoded)
  -- `you` rides every /me reply. Recording it here means ANY read command teaches the Me tab what
  -- role you are, which is what turns "your role cannot read the bank" from a dead end into
  -- something a member can act on: they can see they are a trial and go ask.
  if type(decoded) == 'table' and type(decoded.you) == 'table' then
    if hud_state.you and hud_state.you.role==decoded.you.role and type(decoded.you.canRun)~='table' then
      decoded.you.canRun=hud_state.you.canRun
    end
    if hud_state.you and hud_state.you.role==decoded.you.role and type(decoded.you.canRead)~='table' then
      decoded.you.canRead=hud_state.you.canRead
    end
    hud_state.you = decoded.you
  end
  hud_state.denied = {}
  if type(decoded) ~= 'table' or type(decoded.denied) ~= 'table' then
    return
  end
  for _, block in ipairs(decoded.denied) do
    if type(block) == 'string' then
      hud_state.denied[block] = true
    end
  end
end

--- True when the last read was refused this block on permission grounds.
local function denied(block)
  return type(hud_state.denied) == 'table' and hud_state.denied[block] == true
end

-- Outcome of the LAST ingest POST (any endpoint), purely local state read by
-- `//lootryx status`. Populated by post() below; nothing here ever triggers a request.
local last_ingest = {
  endpoint = nil, -- e.g. '/snapshot'
  ok = nil, -- true | false | nil (nothing sent yet this session)
  status = nil, -- HTTP status number, or nil on a transport failure
  at = nil, -- os.time() of the attempt
  error = nil, -- human-readable message from ingest_errors, only set when ok == false
}

-- ─────────────────────────── helpers ───────────────────────────

host.ui_tools = loadfile(host.addon_path .. 'lib/ui-tools.lua')()
host.ui_tools.max_books=macros_lib.BOOKS_MAX
local function log(msg)
  if not host.ui_tools.record(msg) then host.chat(207, 'Lootryx: ' .. msg) end
end

-- For the paths that must not claim success they did not have.
local function warn_if_not_saved(saved)
  if not saved then
    log('WARNING: Not saved: changes are active for this session only.')
    if not host.logged_in() then
      log('You are not logged in. Log in with this character and try again.')
    else
      log('Could not save the character settings. Check folder access before reloading.')
    end
  end
end

-- key_id is not secret (it rides on every request header), but //lootryx status still
-- partially masks it so a pasted screenshot does not hand out a full working id for
-- free. The secret itself is NEVER read by this file outside sign().
local function mask_key(key)
  if not key or key == '' then
    return '(not set)'
  end
  if #key <= 8 then
    return key:sub(1, 2) .. '...'
  end
  return key:sub(1, 6) .. '...' .. key:sub(-4)
end

local function format_ago(at)
  if not at then
    return 'never'
  end
  local delta = os.time() - at
  if delta < 60 then
    return delta .. 's ago'
  elseif delta < 3600 then
    return math.floor(delta / 60) .. 'm ago'
  elseif delta < 86400 then
    return math.floor(delta / 3600) .. 'h ago'
  end
  return math.floor(delta / 86400) .. 'd ago'
end

-- R12-TEXT (2026-08-02), VERIFY IN-GAME, flagged not fixed: only escapes the 5 JSON metacharacters
-- and otherwise passes every byte through UNCHANGED, which is correct IF the source bytes are
-- already valid UTF-8. character names are game-enforced ASCII, so that always holds for them; a
-- macro name/line/title byte >= 0x80 (`//lootryx macros push`, lib/macros.lua's reader, which is
-- itself deliberately byte-agnostic, see that file's header) is the open question: FFXI's own DAT
-- format is widely believed to store extended/auto-translate glyphs in a Windows codepage or SJIS,
-- not UTF-8, and this addon has no live client to confirm that against (same class of gap as this
-- file's other "VERIFY IN-GAME" notes). If the source byte for such a character is NOT already valid
-- UTF-8, passing it through here embeds an invalid UTF-8 byte inside the JSON document sent over the
-- wire; the server decodes the raw body as UTF-8 (apps/api/src/modules/ingest/handlers.ts), which
-- replaces an invalid sequence with U+FFFD rather than erroring, so the failure mode is silent
-- corruption of that one character, not a rejected request. Left unfixed deliberately: converting
-- would require knowing the TRUE source encoding first, which is not guessable from here, and a wrong
-- guess could make real ASCII macro content worse, not better. See docs/BACKLOG.md § Needs attention.
local function json_escape(s)
  return (s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'))
end

-- Minimal JSON encoder for the shapes we send: strings, numbers, booleans, arrays,
-- and string-keyed objects. We encode the body ONCE and sign exactly that string,
-- so key order is irrelevant to correctness.
--[[
  The one value that means "explicitly null" rather than "absent".

  A Lua table cannot hold nil (assigning nil REMOVES the key), so "this field is null" and "this
  field was not mentioned" are otherwise the same table. For the job declaration they are opposite
  instructions: an omitted slot keeps what is stored, and a null one clears it. Without this,
  clearing a slot silently became leaving it alone.
]]
local JSON_NULL = {}

local function json_encode(v)
  if v == JSON_NULL then
    return 'null'
  end
  local t = type(v)
  if t == 'string' then
    return '"' .. json_escape(v) .. '"'
  elseif t == 'number' or t == 'boolean' then
    return tostring(v)
  elseif t == 'table' then
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    -- An EMPTY table is the one genuinely ambiguous case: Lua cannot tell `{}` from `[]`, and
    -- `#v == count` is 0 == 0 for both, so the array branch below used to claim it. That made
    -- `//lootryx dkp`, `//lootryx windows`, bare `//lootryx standings` and `//lootryx pf` all send
    -- a body of `[]`, which every ingest route rejects outright, because each parses its body with
    -- a zod OBJECT schema ("expected object, received array"). Four shipped read commands failed on
    -- it. An empty table is therefore encoded as an OBJECT, which is right for this addon in
    -- particular: every request body it sends is an object, and no builder in it can produce an
    -- empty array (`characters` is the alliance including yourself, `books` is always exactly one
    -- book, `acked` is guarded by `#acked > 0`, and `pages`/`macros` are fixed 10- and 20-slot
    -- arrays that parse_book fills with blanks rather than omitting).
    if count == 0 then
      return '{}'
    end
    if #v == count then
      local parts = {}
      for i = 1, #v do
        parts[i] = json_encode(v[i])
      end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode(val)
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

local function make_nonce()
  return string.format('%d-%06d-%06d', os.time(), math.random(0, 999999), math.random(0, 999999))
end

local function sign(timestamp, nonce, raw_body)
  return sha2.hmac_sha256(settings.secret, timestamp .. '.' .. nonce .. '.' .. raw_body)
end

-- Short label for `//lootryx status`, e.g. ".../api/ingest/snapshot" -> "/snapshot".
local function endpoint_label(url)
  return url:match('/api/ingest(/.*)$') or url
end

-- Records the outcome of one ingest POST into `last_ingest` for `//lootryx status` to
-- read later. Pure local bookkeeping: never makes a request or retries anything itself.
local function record_ingest_result(url, status, body)
  last_ingest.endpoint = endpoint_label(url)
  last_ingest.at = os.time()
  local numeric_status = tonumber(status)
  last_ingest.status = numeric_status
  if numeric_status and numeric_status >= 200 and numeric_status < 300 then
    last_ingest.ok = true
    last_ingest.error = nil
  else
    last_ingest.ok = false
    last_ingest.error = ingest_errors.describe_failure(status, body)
  end
end

-- Blocking LuaSocket POST. Returns (http_status_number_or_nil, response_body_string).
-- VERIFY IN-GAME: this call blocks the client for its duration. Fine on localhost;
-- a production build should move it to a coroutine / async worker. An `https://` api_base is sent
-- over luasec's `ssl.https` when that soft dependency loaded successfully (see the require at the
-- top of the file); otherwise this falls back to plain `socket.http`, which cannot actually speak
-- TLS, so the request will fail: a loud chat warning below explains why instead of leaving that
-- as a bare, confusing transport error.
--[[
  ── UNTIL YOU ARE LINKED, NOTHING WORKS, SO SAY SO ONCE AND SAY IT PROPERLY ────────────────────

  A member who installs this and types `//lootryx dkp` on the built-in demo key gets an HTTP 401 and
  a transport error. That is a true message and a useless one: the problem is not that a request
  failed, it is that they have not been given a key yet, and nothing in the reply tells them where
  to get one.

  Every command that touches the network checks this first and refuses LOCALLY, with the actual
  steps and the actual URL. Refusing is also the honest thing to do with the request: firing a
  doomed signature at production teaches the player nothing and costs the server a rejection.
]]
local function site_url()
  -- Derived from api_base rather than hardcoded, so a shell pointed at a different deployment (or
  -- a developer on localhost) is told about THEIR site and not about lootryx.com.
  local base = tostring(settings.api_base or '')
  return (base:gsub('/api/ingest.*$', ''))
end

--[[
  Open a page of THIS Lootryx deployment in the player's browser.

  Buttons that print a URL for you to retype into a browser are not buttons. `windower.open_url` is
  Windower's own API for this and hands the address to the default browser; it is not a shell
  escape, which matters because `os.execute` and `io.popen` are forbidden here and would have been
  the other way to do it (see COMPLIANCE.md §3, which greps for exactly that).

  It is the ONE call site in the addon, and the URL is always built here from `site_url()`, which
  is itself derived from the configured `api_base`. A caller passes a PATH, never an address, and
  the result is re-checked against that origin before it goes anywhere: a slug arriving from the
  server can therefore never redirect the player somewhere else, however malformed it is. The
  server response is HMAC-verified, but the request is the only signed half, so a value out of it
  is still input and is treated as such.
]]
local function open_in_browser(path)
  local origin = site_url()
  if origin == '' then
    log('no site configured to open (check //lootryx status).')
    return false
  end
  path = tostring(path or '')
  -- No scheme, no host, no traversal: this builds a page under the configured origin or nothing.
  if path:find('://', 1, true) or path:find('..', 1, true) or path:sub(1, 2) == '//' then
    log('refused to open a suspicious address.')
    return false
  end
  if path ~= '' and path:sub(1, 1) ~= '/' then
    path = '/' .. path
  end
  local url = origin .. path
  if url:sub(1, #origin) ~= origin then
    log('refused to open a suspicious address.')
    return false
  end
  if type(host.open_url) ~= 'function' then
    -- Older Windower builds have no such API. Printing the address is the honest fallback, and is
    -- exactly what every one of these buttons used to do.
    log('open ' .. url)
    return false
  end
  if host.open_url(url) == false then
    log('open ' .. url)
    return false
  end
  log('opened ' .. url .. ' in your browser.')
  return true
end

--- Anything a credential or a slug must never contain: markup, whitespace, or quotes. A value that
--- fails this came from a malformed paste, and saving it would produce a 401 that looks like the
--- website's fault rather than the paste's.
local function looks_like_a_value(text)
  if type(text) ~= 'string' or text == '' or #text > 200 then
    return false
  end
  return text:match('^[%w%-%_%.%:%/@]+$') ~= nil
end

--[[
  Is this addon actually set up?

  Three ways to be unconfigured, and the third was learned the hard way. The obvious two are the
  shipped demo values. The third is credentials that are not credentials at all: a member who pasted
  the website's XML block into `//lootryx key` before v0.9.4 parsed it ended up with a key id of
  literally `<settings>`, which is neither the demo value nor a real key. The addon considered
  itself configured, said nothing on load, offered no setup steps, and every command afterwards
  failed 401 with no hint that the credentials were the problem.

  So anything that cannot possibly be a credential counts as not having one. That is strictly better
  than the alternative, because the setup guidance it triggers is exactly what such a player needs.
]]
--[[
  Where to send someone for their key.

  The slug is only a real slug once the addon has been configured, and until then it is the shipped
  placeholder. Pasting it into a URL produced a link that 404s, which was the FIRST instruction a
  brand new member followed: seen in a live client printing `/shells/lootgoblins/...` to a member of
  `loot-goblins`. For anyone on a different linkshell it was worse than a 404, because it pointed at
  somebody else's shell.

  So a URL is only built when the slug is known to be real. Otherwise it names the site and
  describes the page, which is a slightly longer sentence and always true.
]]
--- The same destination as `setup_location`, as a PATH, for the button that opens a browser.
--- `open_in_browser` takes a path and refuses anything carrying a scheme, which is what stops a
--- value from the server sending somebody elsewhere; this keeps that property.
--- An unpaired install has only the placeholder slug, so it opens the site root and lets the player
--- find their own linkshell rather than guessing at a URL that would 404.
local function setup_path()
  if not is_placeholder_slug(settings.shell_slug) then
    return '/shells/' .. tostring(settings.shell_slug) .. '/profile/characters'
  end
  return '/'
end

local function setup_location()
  if not is_placeholder_slug(settings.shell_slug) then
    return site_url() .. '/shells/' .. tostring(settings.shell_slug) .. '/profile/characters'
  end
  return site_url() .. "  (your linkshell's My Characters page, under My Profile)"
end

-- The slug as something to SHOW. Same reasoning as setup_location: until the addon is paired the
-- slug is the shipped placeholder, and printing it as fact made a live client's first line read
-- `shell=lootgoblins` on an addon that had never been connected to anything.
local function shell_label()
  if is_placeholder_slug(settings.shell_slug) then
    return '(not set)'
  end
  return tostring(settings.shell_slug)
end

-- Assigned below, once self_name exists. Declared here because require_setup, a few lines down,
-- closes over it and would otherwise capture a nil global forever.
local linked_elsewhere

local function is_unconfigured()
  -- A key belonging to a DIFFERENT character counts as unconfigured for this one. This is the
  -- single place every signed command already asks, so putting the test here means none of them can
  -- forget it; `require_setup` has one caller and would have covered almost nothing.
  -- Guarded for nil because this is also read once at load, before the assignment below it.
  if linked_elsewhere and linked_elsewhere() then
    return true
  end
  if settings.key_id == DEMO_KEY_ID or settings.secret == DEMO_SECRET then
    return true
  end
  return not looks_like_a_value(settings.key_id) or not looks_like_a_value(settings.secret)
end

--- The whole first-run story, in the order a person actually does it. Printed on load and by any
--- command that cannot work yet, so it is never more than one command away.
local function print_setup_steps()
  local other = linked_elsewhere and linked_elsewhere()
  if other then
    log('this character is NOT linked. The key saved here belongs to ' .. other .. '.')
    log('  Windower keeps settings per character, so an alt inherits whatever <global> holds.')
    log('  link this one: open ' .. setup_location())
    log('  then: //lootryx setup <code>')
    return
  end
  log('this addon is NOT LINKED yet, so nothing you do is being recorded.')
  log('  1. open ' .. setup_location())
  log('  2. //lootryx setup <code>               that is the whole thing.')
  log('  not in a linkshell? you can still use these right now, no account needed:')
  log('    //lootryx pf list    who is looking for a group on ' .. tostring(settings.world))
  log('    //lootryx shells     linkshells recruiting on ' .. tostring(settings.world))
  log('  it fetches your key and links this character in one go. No file editing, no reload.')
  log('  (the manual route still works: see //lootryx key)')
end

--- Returns true when the command should STOP. Callers do `if require_setup() then return end`.
local function require_setup()
  if not is_unconfigured() then
    return false
  end
  print_setup_steps()
  return true
end

local function post(url, body, refresh_key)
  local timestamp = tostring(os.time())
  local nonce = make_nonce()
  local signature = sign(timestamp, nonce, body)

  local transport = http
  if url:match('^https://') then
    if https_ok and https then
      transport = https
    else
      log('HTTPS request refused: verified TLS transport is unavailable. Install the loader TLS dependencies.')
      transport = {request=function() return nil, 'verified HTTPS transport unavailable' end}
    end
  end

  local response = {}
  local ok, code = transport.request({
    url = url,
    method = 'POST',
    headers = {
      ['content-type'] = 'application/json',
      ['content-length'] = tostring(#body),
      ['x-hoard-key-id'] = settings.key_id,
      ['x-hoard-timestamp'] = timestamp,
      ['x-hoard-nonce'] = nonce,
      ['x-hoard-signature'] = signature,
    },
    source = ltn12.source.string(body),
    sink = ltn12.sink.table(response),
  })

  local status, resp_body
  if not ok then
    status, resp_body = nil, tostring(code) -- transport error; `code` holds the message
  else
    status, resp_body = code, table.concat(response)
  end
  host.ui_tools.refresh_result(url,status,resp_body,body,json,refresh_key)
  record_ingest_result(url, status, resp_body)
  return status, resp_body
end

--[[
  The PUBLIC reads: GET, unsigned, no key, no account.

  Everything else in this addon is HMAC-signed, because everything else is shell data. These two
  are not. Party Finder is server-wide by design (its session routes are `isAuthenticated` and no
  more), and the recruiting directory is how somebody finds a linkshell in the first place. Until
  these existed the addon was unusable without a linkshell, because an IngestKey requires a shellId
  AND a membershipId, so `//lootryx setup` could only ever succeed for an existing member. That
  left the flagship world board unreachable by exactly the players it was built for.

  Served by apps/api/src/modules/public/handlers.ts, which rate-limits by IP and returns the same
  narrow projection the signed route does (a host NAME, never a user id).
]]
local function url_escape(text)
  return tostring(text or ''):gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end)
end

local function get_public(path)
  local url = site_url() .. '/api/public' .. path
  local transport = http
  if url:match('^https://') then
    if https_ok and https then transport = https
    else host.ui_tools.refresh_result(url,nil,'',nil,json);return nil, 'verified HTTPS transport unavailable' end
  end
  local response = {}
  local ok, code = transport.request({ url = url, method = 'GET', sink = ltn12.sink.table(response) })
  host.ui_tools.refresh_result(url,ok and code or nil,table.concat(response),nil,json)
  if not ok then
    return nil, tostring(code)
  end
  return code, table.concat(response)
end

--[[
  The window.

  Rows for the active tab, then the chrome around them. Everything here reads state the addon has
  ALREADY fetched: opening the window makes no request of its own, exactly like the overlay. A
  refresh is an explicit click.
]]
local window_tab = 'home'
local board_view = nil

--[[
  Which page of the current screen is showing.

  Declared HERE, beside the tab, rather than next to the other window state further down, because
  `window_state()` reads it and Lua resolves a local by POSITION: a name used above its `local` line
  is a global, not that local. Declared below the reader, this silently split into two variables,
  the reader always saw nil, and paging did nothing at all while still consuming the click.

  Reset by anything that changes what the list IS, since a page number counted against one list
  means nothing against another.
]]
local window_page = 1
-- Forward declarations. The bodies live below `self_name`/`shell_label`, which they read: a local
-- is resolved by POSITION in Lua, so defining them up here would make every call a nil-call.
local window_rows_for
local window_refresh
-- Assigned once window_action exists, and forward-declared here because the `keyboard` event
-- registration at the bottom of the file closes over them. Lua resolves a local by POSITION, so a
-- plain reference before the assignment would silently capture a global nil forever.
local field_submit
local field_cancel

-- ─────────────────────────── domain reads ───────────────────────────

-- VERIFY IN-GAME: read-only. get_player().name is the logged-in character.
local function self_name()
  return client_state.name(client_reader.player())
end

--[[
  The job you are on RIGHT NOW, read out of the client the same way your name is.

  This is the one thing this transport knows that neither of the others can. Answering an event on
  Discord means typing a job and getting it right; answering it here means the addon already knows,
  because you are standing in the game as that job. Nothing is trusted about it: the server
  re-validates every job string it is handed, however the client obtained it.

  Both halves can be nil (not logged in, or no subjob at a low level), and nil means "leave whatever
  is recorded alone" all the way to the server, never "clear it".
]]
local function self_jobs()
  return client_state.jobs(client_reader.player())
end

--[[
  The character the stored key was minted for, when that is NOT the one playing. Nil otherwise.

  Three ways to be nil, and all three mean "carry on":
    * no name recorded, an install from before this existed (see `linked_character`)
    * not logged in yet, so there is nothing to compare against
    * the names match, which is the ordinary case

  Only a real, known disagreement returns a name, because every other answer would lock somebody out
  of an addon that was working a moment ago.
]]
linked_elsewhere = function()
  local recorded = settings.linked_character
  if type(recorded) ~= 'string' or recorded == '' then
    return nil
  end
  local playing = self_name()
  if not playing or playing == recorded then
    return nil
  end
  return recorded
end

--[[
  The zone the player is standing in, as FFXI's numeric zone id, or nil.

  CONFIRMED IN A LIVE CLIENT (2026-09-07, via `//lootryx selftest`'s probes), and it is not what a
  reasonable person would have guessed: `get_player()` carries no zone at all (it has jobs, merits,
  skills, vitals, and no location), while the PARTY slots each carry `zone` as a NUMBER. So the
  player's own zone has to be read from their own row in the party table.

  Matched on `id` rather than assuming slot p0 is you. p0 IS you in Windower, but "the first slot is
  always the player" is exactly the sort of assumption that is true until someone is in an alliance
  and it quietly is not, and an id comparison costs nothing.

  A NUMBER is what goes on the wire, deliberately. 144 is Waughroon Shrine; the addon does not carry
  a table of three hundred zone names to translate that, because the id is the ground truth, it does
  not vary by client language, and the server already owns FFXI reference data. Guessing at names
  here is what would make a zone gate compare "144" against "Dragon's Aery" and reject everything.
]]
local function own_zone_id()
  return client_state.own_zone(client_reader.player(), client_reader.members())
end

--[[
  Every English item name the client knows, for the item box's suggestions.

  Windower ships `res/items.lua`, a generated table of roughly 23,000 items. It is STATIC LOCAL
  DATA: reading it contacts nothing, asks the game server nothing, and is the same class of act as
  reading your own party list. It is the difference between typing "Ridill" correctly and reporting
  a drop the server then cannot match.

  Loaded lazily and cached, because it is large and most sessions never open the box. If the module
  is missing the field still works, it just stops suggesting: a linkshell should not lose the
  ability to report a drop because a resource file moved.
]]
local item_name_cache = nil
local function item_names()
  if item_name_cache then
    return item_name_cache
  end
  item_name_cache = {}
  local ok, resources = pcall(host.resources)
  if ok and type(resources) == 'table' and type(resources.items) == 'table' then
    for _, item in pairs(resources.items) do
      if type(item) == 'table' and type(item.en) == 'string' and item.en ~= '' then
        item_name_cache[#item_name_cache + 1] = item.en
      end
    end
  end
  return item_name_cache
end

-- VERIFY IN-GAME: collect every alliance member NAME from get_party(). Party 1 is
-- p0..p5; alliance parties 2 and 3 are a10..a15 and a20..a25. Read-only.
local function collect_alliance()
  return client_state.alliance_names(client_reader.members())
end

-- Proposed forward-looking snapshot body (maps to the Snapshot + Presence models:
-- snapshotterCharacter, allianceIndex, and the present character names).
-- ADDON-GT-4 (docs/prds/addon-ground-truth.md §2a): `kind` says what this report CLAIMS to be.
--
--   'checkin'  a report you typed (`//lootryx snap`). Confirms you turned up, exactly as every
--              report did before this field existed.
--   'sample'   a repeat post from the `auto` loop. Asks to be counted as a point-in-time sample, so
--              a member present all night earns more than one present for ten minutes.
--
-- It is a REQUEST and the server decides. A shell that has not turned sampling on treats every
-- report as a check-in, and the server enforces its own minimum interval between samples, so this
-- addon cannot inflate anyone's share by posting more often. Nothing here needs to know the shell's
-- configuration, which is exactly why it does not ask for it.
--
-- The session roster correction (lib/roster.lua) is applied HERE rather than at the command layer,
-- so it reaches the auto loop too. That is the whole reason it is session scoped: an adjustment
-- that only applied to a typed `snap` would leave every automatic capture reporting the wrong
-- roster for the rest of the night. In memory only, never persisted, so a reload clears it.
local roster_adjustment = roster_lib.new()

local function build_snapshot(kind)
  local characters, added = roster_lib.apply(collect_alliance(), roster_adjustment)
  local snapshot = {
    shell = settings.shell_slug,
    snapshotter = self_name() or 'unknown',
    allianceIndex = 0,
    characters = characters,
    capturedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    kind = kind or 'checkin',
  }
  -- Provenance, sent only when there is any. An added name was ASSERTED by an officer, not observed
  -- by the client, and those should not be indistinguishable in the record: reading the party list
  -- is the entire basis for calling this attendance "verified". The names also stay in
  -- `characters` so credit flows today; Presence dedupes, so listing a name twice costs nothing.
  if #added > 0 then
    snapshot.assertedCharacters = added
  end
  return snapshot
end

-- Pure reply formatting for a /snapshot response, split out for the same testability reason as
-- every other *_reply_message here. The server returns the kind the write ACTUALLY became, which is
-- not always the one that was asked for (a shell with sampling off, or a post inside the server's
-- sample interval, lands as a check-in), and a reporter should read what happened.
local say = {}

function say.snapshot_reply_message(count, decoded, adjusted)
  local kind = type(decoded) == 'table' and decoded.kind or nil
  local line
  if kind == 'sample' then
    line = 'sampled ' .. tostring(count) .. ' members (counts toward time-present credit).'
  else
    line = 'snapshot posted: ' .. tostring(count) .. ' members.'
  end
  -- A live roster correction is named on EVERY capture, not just the one where it was set.
  -- It silently changes who earns DKP, so the moment it stops being visible it stops being
  -- accountable, and the officer who set it three hours ago is the person most likely to forget.
  if adjusted then
    line = line .. ' (' .. adjusted .. ')'
  end
  return line
end

-- ─────────────────────────── operations ───────────────────────────

-- Pure renderer for a successful /link response's `character` block (`{ name, isMain, ... }`, see
-- apps/api/src/modules/ingest/handlers.ts's `ctx.json({ ok: true, character })`, the raw Prisma
-- row). Only the ONE detail a player actually cares about (did this become their main character)
-- is surfaced; ids/timestamps stay server-side plumbing. Split out, same testability reason as
-- say.link_reply_message's siblings above (say.tod_reply_message, say.dkp_reply_lines, ...). R12-ADDON
-- (2026-08-02): replaces a prior version that appended the raw JSON response body to this chat
-- line, unreadable (a bare cuid-keyed object dumped after "linked <name> (200).").
function say.link_reply_message(name, character)
  if type(character) == 'table' and character.isMain == true then
    return 'linked ' .. name .. ', set as your main character.'
  end
  return 'linked ' .. name .. '.'
end

local function do_link(code)
  if require_setup() then
    return
  end
  if not code or code == '' then
    log('usage: //lootryx link <code>')
    return
  end
  local name = self_name()
  if not name then
    log('cannot read your character name (are you logged in?).')
    return
  end
  local body = json_encode({ code = code, characterName = name })
  local status, response = post(settings.api_base .. '/link', body)
  if status ~= 200 then
    log('link failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  -- A 200 already means the link succeeded server-side; a parse failure here only costs the
  -- "set as your main character" detail, never the success confirmation itself.
  local parse_ok, decoded = pcall(json.decode, response)
  local character = (parse_ok and type(decoded) == 'table') and decoded.character or nil
  log(say.link_reply_message(name, character))
end

-- Failed attendance captures waiting for another try. ONLY snapshots go in here, never a bid, a
-- link or a ToD: replaying those would be wrong (a bid is a decision you made at a moment, not an
-- observation), whereas re-sending a snapshot is a no-op when it already landed, because
-- `Presence`'s (snapshotId, membershipId) constraint plus skipDuplicates dedupes it server-side
-- (README section 1a). Idempotence is what makes retrying safe, so retrying stops where it stops.
local snapshot_queue = queue_lib.new()

-- `silent` is the AUTO loop's flag, and it now carries a second meaning that is not a coincidence:
-- an automatic repeat post IS what a sample is (a reading taken while the event runs), while a
-- report you typed is a check-in. One existing distinction, no new argument to get wrong.
local function do_snap(silent)
  -- Silent too: the auto loop must not hammer production with doomed signatures either, and a
  -- player who left `auto` on before configuring should not discover that from a rate limit.
  if is_unconfigured() then
    if not silent then
      print_setup_steps()
    end
    return nil
  end
  local snapshot = build_snapshot(silent and 'sample' or 'checkin')
  if #snapshot.characters == 0 then
    if not silent then
      log('no alliance members read: nothing to snapshot.')
    end
    -- nil, not false: nothing was ATTEMPTED, so this must not count as a failure for the auto
    -- loop's backoff below. Standing at a moggle with no party is the normal state, and backing
    -- off on it would delay the first real capture of the night.
    return nil
  end
  local destination=host.ui_tools.attendance.capture_target()
  if not destination then
    host.ui_tools.attendance.refresh_for_capture()
    destination=host.ui_tools.attendance.capture_target()
    if not destination then
      if not silent then log('No capture sent. Open Linkshell > Attendance to start or check the current event.') end
      if host.ui_tools.attendance.state then return nil end
      return false
    end
    -- Automatic work sends at most one request per frame. Read the destination first,
    -- then observe and post on the next frame, preserving that event on every retry.
    if silent then return 'deferred' end
  end
  snapshot = build_snapshot(silent and 'sample' or 'checkin')
  snapshot.eventId=destination
  local body = json_encode(snapshot)
  local url = settings.api_base .. '/snapshot'
  local status, response = post(url, body)
  -- The /snapshot endpoint is live server-side (apps/api/src/modules/ingest, COV-1). A
  -- non-200 here is a real failure (bad signature, no open check-in, ...); ingest_errors
  -- turns it into a specific, actionable line instead of a raw status code.
  if status ~= 200 then
    -- Hold on to the capture if the failure is one that could plausibly clear. This is the whole
    -- reason the 5 second timeout and the auto-loop backoff are acceptable: a request that times
    -- out costs a retry, not eighteen people's attendance credit for that interval. `should_retry`
    -- deliberately refuses 4xx, including the 422 the server returns when no check-in window is
    -- open, because a capture kept alive waiting for SOME window to open is a capture that can be
    -- credited to the wrong event (README section 1a).
    if queue_lib.should_retry(status) then
      queue_lib.push(snapshot_queue, url, body, os.time())
      snapshot_queue.entries[#snapshot_queue.entries].origin={key=settings.key_id,secret=settings.secret,
        api=settings.api_base,shell=settings.shell_slug,world=settings.world,character=self_name()}
    end
    if not silent then
      log('snapshot failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
      local waiting = queue_lib.status_line(snapshot_queue, os.time())
      if waiting then
        log('  ' .. waiting .. '. Nothing to do: the addon retries on its own.')
      end
    end
    -- The overlay is where a SILENT failure becomes visible: the auto loop deliberately says nothing
    -- in chat, so without this a reporter whose key expired would never find out.
    hud_state.event = { alliance = #snapshot.characters, auto = settings.auto, lastSnapAtMs = os.time() * 1000, snapOk = false, snapStatus = status, snapReason = ingest_errors.describe_failure(status, response) }
    return false
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not silent then
    log(say.snapshot_reply_message(#snapshot.characters, parse_ok and decoded or nil, roster_lib.describe(roster_adjustment)))
  end
  hud_state.event = { alliance = #snapshot.characters, auto = settings.auto, lastSnapAtMs = os.time() * 1000, snapOk = true }
  return true
end

--[[
  Re-sends ONE held capture. Returns the same tri-state as `do_snap`: true delivered, false the
  attempt failed, nil there was nothing to send.

  Only the timestamp/nonce/signature header trio is minted fresh, by `post()` as it always is. The
  BODY goes back out byte for byte, `capturedAt` included, so what the server records is when those
  players were actually seen and not when the retry happened. The HMAC timestamp window is replay
  protection on the wire; it says nothing about how old the observation inside may be.

  Named `do_*` on purpose. The compliance guard reads the prerender registration to prove which
  handlers the auto loop can reach, and this one posts to the network, so it must be visible to
  that check rather than hidden behind a name the scanner does not recognise.
]]
local function do_drain_queued()
  if not self_name() then return nil end
  local now = os.time()
  local entry = queue_lib.take(snapshot_queue, now)
  if not entry then
    return nil
  end
  local origin=entry.origin
  if not origin or origin.key~=settings.key_id or origin.secret~=settings.secret
    or origin.api~=settings.api_base or origin.shell~=settings.shell_slug
    or origin.world~=settings.world or origin.character~=self_name() then
    log('Discarded a queued capture from a previous character or connection.')
    return nil
  end
  local status = post(entry.url, entry.body)
  if status == 200 then
    return true
  end
  if queue_lib.should_retry(status) then
    -- Back into the buffer with its ORIGINAL capture time, so attempts cannot extend its life.
    queue_lib.requeue(snapshot_queue, entry, now)
  end
  return false
end

--[[
  `//lootryx roster [+Name,Name] [-Name,Name] | clear`

  Corrects who the next capture reports, for the whole session, because an alliance holds eighteen
  and an HNM camp does not. Local only: this changes what a LATER snapshot will say and sends
  nothing by itself.

  A bare word with no `+` or `-` is refused rather than guessed at. Assuming `+` would let a
  mistyped command quietly put someone on the payroll, and that is the one error here nobody would
  catch by reading the confirmation.
]]
local function do_roster(args)
  if not args[1] then
    local description = roster_lib.describe(roster_adjustment)
    if not description then
      log('roster: no correction set. Every capture reports exactly what the game shows.')
    else
      log('roster: ' .. description)
      log('  applied to every capture until //lootryx roster clear, or a reload.')
    end
    log('  usage: //lootryx roster +Name,Name -Name  |  //lootryx roster clear')
    return
  end

  if string.lower(tostring(args[1])) == 'clear' then
    roster_adjustment = roster_lib.new()
    log('roster: correction cleared. Captures report exactly what the game shows again.')
    return
  end

  local touched, rejected = roster_lib.parse_into(roster_adjustment, args)
  for _, entry in ipairs(touched) do
    if entry.list == 'full' then
      log(
        'roster: cannot add "'
          .. entry.name
          .. '", already at the '
          .. tostring(roster_lib.MAX_ADDED)
          .. '-name limit (the server rejects an over-long capture WHOLE, so the rest of'
          .. ' the alliance would lose credit too).'
      )
    end
  end
  for _, bad in ipairs(rejected) do
    log('roster: ignored "' .. tostring(bad) .. '", names need a + or - (for example +Fahad or -Night).')
  end
  if #touched == 0 and #rejected > 0 then
    return
  end
  local description = roster_lib.describe(roster_adjustment)
  log('roster: ' .. (description or 'no correction set.'))
  log('  applied to every capture, automatic ones included, until cleared or reloaded.')
end

--[[
  One zone heartbeat. Returns the same tri-state as `do_snap`: true sent, false the attempt failed,
  nil there was nothing to send.

  Reads your character from `get_player()` and your own zone from the matching `get_party()` row.
  Both calls are on the allow-list. The zone can be unavailable during transitions, and
  `ingestHeartbeatSchema` takes `zone` as optional precisely so a client that cannot supply one is
  still useful. A ping with no zone still says "this character is logged in right now", which is
  most of what the coverage board is for.

  Off unless BOTH sides opt in: this local switch, and a per-shell Config row the server checks. It
  is the only thing the addon reports about where YOU are rather than what you saw.
]]
local function do_heartbeat()
  if not settings.heartbeat or is_unconfigured() then
    return nil
  end
  local player = client_reader.player()
  local name = player and player.name
  if not name then
    return nil
  end
  local body = json_encode({ characterName = name, zoneId = own_zone_id() })
  local status,response = post(settings.api_base .. '/heartbeat', body)
  local ok,reply=pcall(json.decode,response or '')
  local recorded=status==200 and ok and type(reply)=='table' and reply.recorded==true
  if recorded then host.ui_tools.heartbeat_last_success=os.date('%H:%M:%S') end
  host.ui_tools.heartbeat_status=recorded and 'Reporting' or (status==200 and 'Blocked by linkshell or character eligibility' or 'Report failed')
  host.ui_tools.heartbeat_feedback='Last accepted: '..(host.ui_tools.heartbeat_last_success or 'none this session')..(recorded and '' or '. Last attempt: '..os.date('%H:%M:%S')..'. Check your connection and ask an officer whether zone sharing is enabled.')
  return status == 200
end

-- `//lootryx heartbeat on | off`. Same argument discipline as `do_auto` and for the same reason:
-- a typo must never silently leave a reporting switch in the state you did not ask for. This one
-- matters a little more, because the thing being switched reports where you are.
local function do_heartbeat_toggle(args)
  local mode = (args[1] or ''):lower()
  if mode ~= 'on' and mode ~= 'off' then
    log('usage: //lootryx heartbeat on | off   (currently ' .. (settings.heartbeat and 'ON' or 'OFF') .. ')')
    return
  end
  settings.heartbeat = (mode == 'on')
  save_settings()
  if settings.heartbeat then
    log('heartbeat ON: every ' .. settings.heartbeat_interval .. 's this reports your CHARACTER and ZONE')
    log('  so the shell can see who is where. Your shell must also enable it server-side.')
  else
    log('heartbeat OFF. Nothing about your location leaves this client.')
  end
end

--[[
  `//lootryx key <key_id> <secret> [shell_slug]`, or just paste the whole block from the website.

  WHY IT TAKES BOTH SHAPES. The site's copy button produces a `<settings>` XML block, because that
  block is what you paste into settings.xml. So when a command says "paste your key here", the thing
  in a member's clipboard is the block, and pasting it is the obvious move. The first version of
  this command took bare tokens only, read `<settings>` as the key id and an XML fragment as the
  shell slug, and said "saved". Accepting only the shape the website does not give you is not a
  validation problem, it is the wrong shape.

  So: if the input contains `<key_id>` and `<secret>` tags, they are read out of it, along with
  `api_base` and `shell_slug` when present, which means one paste configures a self-hosted shell
  completely. Otherwise the input is read as bare tokens.

  EVERY VALUE IS VALIDATED BEFORE ANYTHING IS SAVED OR PRINTED. That is not tidiness. `shell_slug`
  is echoed back unmasked in the confirmation, and in the failure above it happened to receive the
  key id; had the paste been ordered differently it would have received the SECRET and printed it
  to a chat log. A value that reaches the confirmation line has to be known-good first.
]]

--- Pulls one `<tag>value</tag>` out of the pasted block.
local function xml_field(blob, tag)
  local value = blob:match('<' .. tag .. '>(.-)</' .. tag .. '>')
  if not value then
    return nil
  end
  return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

--[[
  FIELD AT A TIME, because the game's input line is not long enough for the alternatives.

  This is the lesson from a real client: FFXI's chat input truncates, and the website's settings
  block is around 350 characters, so "paste the whole block" is advice the game physically cannot
  follow. It arrives cut off mid-secret. Even the two-value form is about 102 characters, which fits
  but leaves no room at all for a longer key.

  So each field can be set on its own line, and the longest of those is roughly 85 characters:

    //lootryx key id <key_id>
    //lootryx key secret <secret>
    //lootryx key shell <slug>

  Setting one field does NOT make the addon configured. `is_unconfigured` checks both credentials,
  so the setup guidance keeps appearing until the pair is actually complete, which is the honest
  reading of a half-entered credential.
]]
local KEY_FIELDS = { id = 'key_id', secret = 'secret', shell = 'shell_slug', api = 'api_base' }

local function do_key_field(field, value)
  local setting = KEY_FIELDS[field]
  if not value or value == '' then
    log('usage: //lootryx key ' .. field .. ' <value>')
    return true
  end
  if not looks_like_a_value(value) then
    log('that value has characters a ' .. field .. ' cannot contain, so nothing was saved.')
    log('  paste ONLY the value itself, without the <' .. setting .. '> tags around it.')
    return true
  end
  if (setting == 'key_id' and value == DEMO_KEY_ID) or (setting == 'secret' and value == DEMO_SECRET) then
    log('that is the built-in demo value, which is what you are trying to replace.')
    return true
  end
  host.ui_tools.reset_connection()
  settings[setting] = value
  local saved = save_settings()

  -- Never echo a secret, even one field at a time.
  local shown = (setting == 'secret') and 'hidden' or value
  log((saved and 'saved ' or 'accepted for this session only: ') .. setting .. ' = ' .. shown .. '.')
  warn_if_not_saved(saved)
  if is_unconfigured() then
    log('  still incomplete: set the other one too, then //lootryx link <code>.')
  else
    log('  configured. Next: //lootryx link <code> to claim this character.')
  end
  return true
end

local function do_key(args)
  -- Windower splits on whitespace, and a pasted block arrives as many tokens (with newlines inside
  -- some of them), so put it back together before looking at it.
  local blob = table.concat(args, ' ')
  local key_id, secret, shell, api_base

  -- `//lootryx key id <value>` and friends: one short line per field, for when nothing longer fits.
  local first = args[1] and tostring(args[1]):lower() or nil
  if first and KEY_FIELDS[first] and args[2] then
    return do_key_field(first, args[2])
  end

  if blob:match('<key_id>') then
    key_id = xml_field(blob, 'key_id')
    secret = xml_field(blob, 'secret')
    shell = xml_field(blob, 'shell_slug')
    api_base = xml_field(blob, 'api_base')
  else
    key_id, secret, shell = args[1], args[2], args[3]
  end

  if not key_id or not secret then
    log('usage: //lootryx key <key_id> <secret>')
    log('  the game input line is too short for the whole settings block, so if that got cut off,')
    log('  set them one at a time instead:')
    log('    //lootryx key id <key_id>')
    log('    //lootryx key secret <secret>')
    log('  both come from ' .. setup_location())
    log('  the secret is shown ONCE on that page, so copy it before you leave.')
    return
  end

  -- Checked BEFORE saving and before printing. See the header: the confirmation line echoes the
  -- shell slug, and a malformed paste is exactly how a secret ends up in that position.
  if not looks_like_a_value(key_id) or not looks_like_a_value(secret) then
    log('that does not look like a key and secret, so nothing was saved.')
    log('  if you pasted the settings block, make sure the whole thing came across in one line.')
    log('  otherwise: //lootryx key <key_id> <secret>')
    return
  end
  if shell ~= nil and shell ~= '' and not looks_like_a_value(shell) then
    log('the shell slug in that paste is malformed, so nothing was saved.')
    return
  end

  if key_id == DEMO_KEY_ID or secret == DEMO_SECRET then
    log('that is the built-in demo key, which is what you are trying to replace.')
    log('  get a real one at ' .. setup_location())
    return
  end

  host.ui_tools.reset_connection()
  settings.key_id = key_id
  settings.secret = secret
  settings.linked_character = self_name() or ''
  if shell and shell ~= '' then
    settings.shell_slug = shell
  end
  if api_base and api_base ~= '' and looks_like_a_value(api_base) then
    settings.api_base = api_base
  end
  local saved = save_settings()

  local where = 'key ' .. mask_key(key_id) .. ', secret hidden, shell ' .. settings.shell_slug .. '.'
  if saved then
    log('saved. ' .. where)
    log('  no reload needed. Next: //lootryx link <code> to claim this character.')
  else
    -- In memory only. It works until the addon reloads, and then it is gone, so say both halves.
    log('accepted for this session only: ' .. where)
    warn_if_not_saved(saved)
  end
  log('  note: what you just typed is in Windower command history (up arrow). Clear it if you share your screen.')
end

--[[
  `//lootryx setup <code>` : the whole first run, in one command.

  Replaces "open settings.xml, paste an XML block that does not fit the chat input, reload, then
  redeem a second code". One short code from the website, typed once. It fetches this client's
  credentials AND links the character in the same exchange, then saves and is immediately live.

  THE ONE REQUEST THIS ADDON MAKES WITHOUT A SIGNATURE, and necessarily so: it is the request that
  obtains the thing everything else signs with. The code is therefore a bearer secret for the ten
  minutes it lives. The server side is where that is made safe (single use, its own purpose,
  rotation on redeem, the tightest rate limit in the API); this side's job is small: send it once,
  never log it, and save what comes back.
]]
--[[
  Pair with no linkshell and no account at all.

  Assigned to a forward-declared local rather than declared with , purely to keep
  one name off the main chunk: Lua 5.1 allows a function 200 locals and the  command handlers
  cannot be moved into a table because compliance.test.ts reads their names out of the source.

  Sends the character name this client is logged in as and the world from settings. Neither is
  proof of anything and the server treats them as a label: the identity that comes back is the KEY,
  and whoever holds it is its only holder.
]]
local function do_pair_world()
  local name = self_name()
  if not name then
    log('could not read your character name. Log in first.')
    return
  end
  local body = json_encode({ characterName = name, world = settings.world })
  -- Deliberately unsigned: there is nothing to sign with yet. post() adds signature headers only
  -- when a key exists, exactly as the shell pairing path relies on.
  local status, response = post(settings.api_base .. '/pair/world', body)
  if status ~= 200 then
    log('pairing failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' or not looks_like_a_value(decoded.keyId)
    or not looks_like_a_value(decoded.secret) then
    log('could not parse the server response.')
    return
  end
  host.ui_tools.reset_connection()
  settings.key_id = decoded.keyId
  settings.secret = decoded.secret
  settings.linked_character = name
  settings.shell_slug = ''
  local saved=save_settings()
  log('paired as ' .. name .. ' on ' .. tostring(settings.world) .. '.')
  log('  party finder and the linkshell directory work now, with no account.')
  -- Said every time, because it is the part that costs something if ignored: this identity lives in
  -- data/settings.xml and nowhere else until it is claimed.
  log('  this identity is UNCLAIMED: it lives only in this addon. //lootryx claim gives you a')
  log('  code that keeps it, if you make an account later.')
  warn_if_not_saved(saved)
end

local function do_claim()
  --[[
    Ask the server for a code that keeps this identity, and print it for the player to type into the
    website while signed in.

    THE ADDON MINTS, THE SITE REDEEMS, and the direction is the whole point. It ran the other way
    first: the site minted a code and this command redeemed it. That made the code a bearer
    credential for a REAL ACCOUNT, because the other half it looked like it needed (a provisional
    key) is something anyone can mint at will with `setup world`. This way round, the scarce half is
    the key sitting in data/settings.xml, and a code read over somebody's shoulder only ever lets a
    thief adopt an UNCLAIMED character into their own account.
  ]]
  -- `is_unconfigured()` and not a bare emptiness check on key_id: the addon SHIPS with a demo key,
  -- so "there is a key_id" is true on an install that has never paired with anything, and a bare
  -- check sent a signed request that could only ever come back 401. It also covers the alt-inherits-
  -- <global> case, which matters more here than usual: a claim code is minted for whichever identity
  -- the key belongs to, so claiming on an alt reading another character's key would offer up the
  -- wrong character entirely.
  if is_unconfigured() then
    log('this addon is not paired yet, so there is no character to claim.')
    log('  //lootryx setup world   pairs with no linkshell and no account.')
    return
  end
  local status, response = post(settings.api_base .. '/claim-code', json_encode({}))
  if status ~= 200 then
    log('could not get a claim code [' .. tostring(status) .. ']: ' ..
      ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' or type(decoded.code) ~= 'string' then
    log('could not parse the server response.')
    return
  end
  log('claim code: ' .. decoded.code)
  log('  sign in at lootryx.com, open My Addon, and enter it there.')
  log('  it lasts 10 minutes and works once. Your listings, party and reputation come with it.')
end

local function do_setup(args)
  local code = args[1]
  --[[
    `//lootryx setup world` pairs with NO linkshell and NO account (ADDON-OPEN-3).

    The identity it gets is provisional: it works for the Party Finder world board and the linkshell
    directory, and it belongs to whoever holds the key in `data/settings.xml` and nobody else. That
    is said plainly below rather than buried, because the two things a player needs to know are that
    it works right now and that it is not durable until claimed.
  ]]
  if type(code) == 'string' and code:lower() == 'world' then
    do_pair_world()
    return
  end
  if not code or code == '' then
    log('usage: //lootryx setup <code>')
    log('  get the code at ' .. setup_location())
    log('  it lasts 10 minutes and works once.')
    log('  no linkshell? //lootryx setup world   (party finder, no account needed)')
    return
  end
  local name = self_name()
  if not name then
    host.ui_tools.pair_feedback='Cannot read your character. Log in to the game and retry.'
    log('cannot read your character name (are you logged in?).')
    return
  end

  -- Deliberately NOT signed: there is nothing to sign with yet. post() adds signature headers
  -- regardless, which the server ignores on this route; sending them costs nothing and keeps one
  -- transport path rather than a second one that could drift.
  local status, response = post(settings.api_base .. '/pair', json_encode({ code = code, characterName = name }))
  if status ~= 200 then
    host.ui_tools.pair_feedback='Connection failed: '..ingest_errors.describe_failure(status,response)..' Get a fresh code if it expired.'
    log('setup failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    log('  codes last 10 minutes and work once. Get a fresh one and try again.')
    return
  end

  local ok, decoded = pcall(json.decode, response)
  if not ok or type(decoded) ~= 'table' or not looks_like_a_value(decoded.keyId)
    or not looks_like_a_value(decoded.secret) then
    host.ui_tools.pair_feedback='Unreadable reply. Your code is retained; retry or get a fresh code.'
    log('setup got an unreadable reply, so nothing was saved. Try again.')
    return
  end

  host.ui_tools.reset_connection()
  settings.key_id = decoded.keyId
  settings.secret = decoded.secret
  settings.linked_character = self_name() or ''
  if type(decoded.shellSlug) == 'string' and decoded.shellSlug ~= '' then
    settings.shell_slug = decoded.shellSlug
  end
  local saved = save_settings()

  -- Never the secret, and never the code. Both are credentials and this line goes to a chat log.
  log('connected as ' .. name .. ' on ' .. settings.shell_slug .. '. key ' .. mask_key(decoded.keyId) .. '.')
  if decoded.characterLinked == true then
    log('  character linked. You are done: try //lootryx dkp')
  else
    log('  character was already linked. You are done: try //lootryx dkp')
  end
  -- Last, so it is the line still on screen. The code is already spent at this point, so a
  -- discarded write is the worst case here: the credentials are real but only in memory.
  warn_if_not_saved(saved)
  host.ui_tools.pair_feedback=saved and 'Character connected.' or 'Connected for this session. Settings could not be saved.'
  return true
end

local function do_show()
  local snapshot = build_snapshot()
  log('shell=' .. snapshot.shell .. ' snapshotter=' .. snapshot.snapshotter .. ' members=' .. #snapshot.characters)
  log('  ' .. (next(snapshot.characters) and table.concat(snapshot.characters, ', ') or '(none)'))
end

-- ─────────────────────── Macro sync (EPIC MACRO M2, read + push only) ───────────────────────
-- Reads the player's OWN local macro DAT files (lib/macros.lua, decode-only) and pushes whichever
-- books changed since the last successful sync to POST <api_base>/macros, ONE BOOK PER REQUEST.
-- Command-triggered only (`//lootryx macros push`), never called from the `prerender` loop below,
-- with one book sent at a time through the cooperative transport. Socket waits yield between
-- frames; local file reads, JSON work and uncached DNS still run on the game thread.

-- A one-book response's accepted/deduped/conflicts arrays hold at most the single bookIndex we
-- sent, so a literal `"field":[N]` substring match is enough without a general JSON parser.
local function response_has_book(body, field, book_index)
  if not body then
    return false
  end
  return body:find('"' .. field .. '":%[' .. tostring(book_index) .. '%]') ~= nil
end

local function do_macros_push()
  local name = self_name()
  if not name then
    log('cannot read your character name (are you logged in?).')
    return
  end

  local macro_dir = macros_lib.resolve_macro_dir(settings.macro_dir)
  if not macro_dir then
    log('cannot resolve the macro folder. Set <macro_dir> in settings.xml (see data/settings.example.xml).')
    return
  end

  local titles = macros_lib.parse_titles(macro_dir .. 'mcr.ttl')

  local queued, blank_count = {}, 0
  for book_index = 1, macros_lib.BOOKS_MAX do
    local pages = macros_lib.parse_book(macro_dir, book_index)
    if macros_lib.is_blank_book(pages) then
      blank_count = blank_count + 1
    else
      local hash = macros_lib.hash_book(pages)
      local cache_key = 'b' .. book_index
      if settings.macro_hashes[cache_key] ~= hash then
        queued[#queued + 1] = {
          bookIndex = book_index,
          name = titles[book_index],
          contentHash = hash,
          pages = pages,
          cache_key = cache_key,
        }
      end
    end
  end

  if #queued == 0 then
    log('macros: nothing to push (' .. blank_count .. ' empty book(s), the rest already synced).')
    return
  end

  log('macros: pushing ' .. #queued .. ' changed book(s), one request each (this may pause briefly)...')
  local pushed, deduped, conflicts, failed = 0, 0, 0, 0
  for _, book in ipairs(queued) do
    local body = json_encode({
      characterName = name,
      books = {
        { bookIndex = book.bookIndex, name = book.name, contentHash = book.contentHash, pages = book.pages },
      },
    })
    local status, response = post(settings.api_base .. '/macros', body)
    if status == 200 and response_has_book(response, 'conflicts', book.bookIndex) then
      conflicts = conflicts + 1
      log('  book ' .. book.bookIndex .. ' has a pending web edit: //lootryx macros pull <activeBookIndex> it first.')
    elseif status == 200 then
      settings.macro_hashes[book.cache_key] = book.contentHash
      if response_has_book(response, 'deduped', book.bookIndex) then
        deduped = deduped + 1
      else
        pushed = pushed + 1
      end
    else
      failed = failed + 1
      log('  book ' .. book.bookIndex .. ' failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    end
  end
  save_settings()
  -- A conflict means the website holds an edit to that book which has not been pulled down yet, so
  -- the local copy and the shared one have diverged. That is exactly the kind of thing a player
  -- reads once in a chat log and then forgets, so it also goes on the overlay's status line.
  hud_state.macros = { pendingPull = conflicts }
  log(
    'macros: done. pushed '
      .. pushed
      .. ', already-current '
      .. deduped
      .. ', conflicts '
      .. conflicts
      .. ', failed '
      .. failed
      .. '.'
  )
end

-- true only if `n` is a Lua number, is a whole integer (a JSON float like 5.5 fails this), and
-- falls within [min, max] inclusive. Finding MACRO-01 hardening (2026-07-19): every server-supplied
-- bookIndex/pageNumber MUST pass this before it is ever used in file_index arithmetic below, so a
-- crafted/out-of-range pull response can never compute a file_index its declared bookIndex would
-- not itself imply.
local function is_valid_index(n, min, max)
  return type(n) == 'number' and n == math.floor(n) and n >= min and n <= max
end

-- Writes ONE pulled book (its pages + its title) to the local DAT files. Every page and the title
-- write independently through lib/macros.lua's whitelisted writer (basename+dir gate, .bak backup,
-- verified temp+rename); this function's only job is to validate the server-supplied indices,
-- refuse anything that would touch the active book, carry the right header/reserved bytes into
-- each encode call, and report per-part failures without stopping partway through the book.
-- Returns (all_ok, hit_active): all_ok is true ONLY if every page + the title (when present) wrote
-- successfully, so a book only gets ack'd (below) once it is genuinely, fully written; a partial
-- failure re-pulls next time, never silently leaves the local file half-updated with no record
-- anything went wrong. hit_active is true if any part was refused specifically because it resolved
-- into the currently active book, so the caller can report it as a refusal rather than a failure.
-- `run_state` (a small table owned by the caller, do_macros_pull) is shared across every book
-- written in the SAME pull, so a later book can tell "mcr.ttl looks missing because it never
-- existed" apart from "mcr.ttl looks missing because THIS run's own write to it removed the live
-- file and then failed to rename the replacement back into place" (see the title-write block below
-- and Finding AB-49).
--
-- Finding MACRO-01 hardening (2026-07-19): `file_index = (bookIndex-1)*10 + (pageNumber-1)` is
-- server-supplied arithmetic. Without validating bookIndex/pageNumber are in-range integers first,
-- an out-of-range pageNumber (e.g. 11) can make a DIFFERENT declared bookIndex's arithmetic overflow
-- into the file range of the book the player has open right now, silently bypassing a refusal that
-- only compared the declared bookIndex to activeBookIndex. Two layers now guard against this: (1)
-- bookIndex/pageNumber are range-validated BEFORE file_index is computed at all, so the arithmetic
-- can only ever land inside the range the declared bookIndex actually owns; (2) the active-book
-- refusal below is enforced on the RESOLVED file_index against the active book's own file range,
-- not merely on the caller's declared-bookIndex fast path (do_macros_pull still does that check
-- first as a cheap short-circuit; this is the authoritative one). Either layer alone would close the
-- reported hole; both are kept since they are cheap and independent.
local function write_book(macro_dir, book, active_book, run_state)
  if not is_valid_index(book.bookIndex, 1, macros_lib.BOOKS_MAX) then
    log('  book ' .. tostring(book.bookIndex) .. ': invalid book index from server (must be an integer 1..' .. macros_lib.BOOKS_MAX .. '), refused, skipped.')
    return false, false
  end

  local active_file_start = (active_book - 1) * macros_lib.PAGES_PER_BOOK
  local active_file_end = active_file_start + macros_lib.PAGES_PER_BOOK - 1

  local all_ok = true
  local hit_active = false
  for _, page in ipairs(book.pages or {}) do
    if not is_valid_index(page.pageNumber, 1, macros_lib.PAGES_PER_BOOK) then
      all_ok = false
      log('  book ' .. book.bookIndex .. ' page ' .. tostring(page.pageNumber) .. ': invalid page number from server (must be an integer 1..' .. macros_lib.PAGES_PER_BOOK .. '), refused, skipped.')
    else
      local file_index = (book.bookIndex - 1) * macros_lib.PAGES_PER_BOOK + (page.pageNumber - 1)
      if file_index >= active_file_start and file_index <= active_file_end then
        all_ok = false
        hit_active = true
        log('  book ' .. book.bookIndex .. ' page ' .. page.pageNumber .. ': resolves to the currently active book (' .. active_book .. '), refused, NOT written.')
      else
        -- Read the CURRENT on-disk page first: its header (version/flags/MD5) and each slot's
        -- reserved bytes are opaque fields this decoder never interprets, and must be carried
        -- forward exactly (see lib/macros.lua's "Header handling" note) rather than zeroed by an
        -- edit to a DIFFERENT field (the macro name/lines).
        local _, header, reserved = macros_lib.parse_page_file(macro_dir .. macros_lib.page_filename(file_index))
        local slots = macros_lib.macros_to_slots(page.macros)
        local encoded, encode_err = macros_lib.encode_page_bytes(slots, header, reserved)
        if not encoded then
          all_ok = false
          log('  book ' .. book.bookIndex .. ' page ' .. page.pageNumber .. ': encode failed (' .. tostring(encode_err) .. '), skipped, original file untouched.')
        else
          local write_ok, write_err = macros_lib.write_page_file(macro_dir, file_index, encoded)
          if not write_ok then
            all_ok = false
            log('  book ' .. book.bookIndex .. ' page ' .. page.pageNumber .. ': ' .. tostring(write_err))
          end
        end
      end
    end
  end

  -- Book title (mcr.ttl), one shared file across all 20 books: read the current titles + header,
  -- overwrite only this book's slot, write the whole file back. Only touched when this pull
  -- actually carries a name for the book (server sends the key only when the web edit set one).
  --
  -- Finding AB-49 hardening (2026-07-24): a failed read of mcr.ttl (locked by an AV/sync handle, or
  -- absent mid-run because an earlier book's own write removed the live file and then failed to
  -- rename the replacement back into place) used to fall through to encode_titles_bytes' "no
  -- original file" fallback: a zeroed header and every OTHER book's title silently blanked, which
  -- still reported success and got acked. macros_lib.title_write_is_safe (pure, unit-tested
  -- directly, see lib/macros.lua) now refuses instead whenever the read failure is not PROVABLY
  -- "this file has simply never been created yet", or whenever this same pull has already proven
  -- mcr.ttl exists (run_state, set the first time any book in this run reads a real header): either
  -- case means titles must be left alone, never zeroed, and the book is reported not-ok so the next
  -- pull retries it.
  if book.name ~= nil then
    local titles, ttl_header, confirmed_missing = macros_lib.parse_titles(macro_dir .. 'mcr.ttl')
    if ttl_header then
      run_state.ttl_confirmed_existing = true
    end
    local safe, refuse_reason = macros_lib.title_write_is_safe(ttl_header, confirmed_missing, run_state.ttl_confirmed_existing)
    if not safe then
      all_ok = false
      log('  book ' .. book.bookIndex .. ' title: ' .. refuse_reason .. ', refused, titles left alone.')
    else
      titles[book.bookIndex] = book.name
      local encoded_titles, titles_err = macros_lib.encode_titles_bytes(titles, ttl_header)
      if not encoded_titles then
        all_ok = false
        log('  book ' .. book.bookIndex .. ' title: encode failed (' .. tostring(titles_err) .. ').')
      else
        local write_ok, write_err = macros_lib.write_titles_file(macro_dir, encoded_titles)
        if not write_ok then
          all_ok = false
          log('  book ' .. book.bookIndex .. ' title: ' .. tostring(write_err))
        end
      end
    end
  end

  return all_ok, hit_active
end

-- //lootryx macros pull <activeBookIndex> · pulls whichever books were edited on the web
-- (pendingPull=true, source='WEB') and writes them back to the player's OWN local macro DAT
-- files, EPIC MACRO M4, the addon's FIRST local write capability. <activeBookIndex> is REQUIRED:
-- FFXI holds whichever book you currently have open under Options > Macros in memory and
-- re-flushes it to disk on zone/logout, which would silently undo a write to that exact book.
-- Windower's public Lua API has no documented/verified call in this codebase to read that state
-- directly (unlike get_party()/get_player(), already used above), so rather than guess with an
-- unverified memory read on a data-safety-critical path, the player states it explicitly on every
-- pull; that book, and only that book, is refused. Every other book writes through
-- lib/macros.lua's whitelisted writer: basename must match mcr%d*.dat or mcr.ttl, resolved under
-- the configured macro dir, backed up to .bak before any overwrite, written via temp+rename.
--
-- Finding 5 hardening (Sol audit, 2026-07-19): `<activeBookIndex>` MUST be a whole integer.
-- `tonumber('1.5')` succeeds and used to pass a bare `< 1 or > BOOKS_MAX` range check, so a
-- fractional book (e.g. `//lootryx macros pull 1.5`) would slip past the equality refusal below
-- (`book.bookIndex == active_book` never matches a float) AND corrupt write_book's
-- `active_file_start`/`active_file_end` arithmetic (fractional file-index bounds), letting a
-- pulled write land partially inside the book you actually have open in-game. `is_valid_index`
-- (defined above, already the authoritative integer+range gate for server-supplied indices) closes
-- the same hole here for this USER-supplied one.
local function do_macros_pull(active_book_arg)
  local active_book = tonumber(active_book_arg)
  if not is_valid_index(active_book, 1, macros_lib.BOOKS_MAX) then
    log('usage: //lootryx macros pull <activeBookIndex>')
    log('  <activeBookIndex> = the book number shown under Options > Macros in-game RIGHT NOW.')
    log('  Must be a whole number (integer) from 1 to ' .. macros_lib.BOOKS_MAX .. ', e.g. "3", not "3.5".')
    log('  Lootryx cannot read that from memory, so tell it, or a written book could get clobbered')
    log('  by FFXI re-flushing its own copy on your next zone/logout.')
    return
  end

  local name = self_name()
  if not name then
    log('cannot read your character name (are you logged in?).')
    return
  end

  local macro_dir = macros_lib.resolve_macro_dir(settings.macro_dir)
  if not macro_dir then
    log('cannot resolve the macro folder. Set <macro_dir> in settings.xml (see data/settings.example.xml).')
    return
  end

  local status, response = post(settings.api_base .. '/macros/pull', json_encode({ characterName = name }))
  if status ~= 200 then
    log('macros pull failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end

  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' or not decoded.books then
    log('macros pull: could not parse the server response, nothing written.')
    return
  end

  if #decoded.books == 0 then
    log('macros pull: nothing pending, every book is already up to date locally.')
    return
  end

  -- Finding 4 hardening (Sol audit, 2026-07-19): each ack entry carries BOTH the bookIndex and the
  -- contentHash THIS pull returned for it, echoed straight back to the server (never recomputed
  -- here). ackPull (packages/database/macro-sync.ts) only clears pendingPull when that hash still
  -- matches the row's CURRENT contentHash, so a web edit that lands between this pull and the ack
  -- below can never get silently cleared out from under the addon.
  --
  -- Finding AB-49 hardening (2026-07-24): `run_state` is shared across every book write_book()
  -- makes in THIS pull, so a book whose title write hits a missing mcr.ttl can tell "never created"
  -- apart from "this run's own earlier write just removed it" (see write_book's title-write block).
  local acked, refused_active, failed = {}, 0, 0
  local run_state = { ttl_confirmed_existing = false }
  for _, book in ipairs(decoded.books) do
    if book.bookIndex == active_book then
      -- Cheap fast-path refusal on the DECLARED index (matches the required <activeBookIndex>
      -- argument directly). write_book below additionally enforces the same refusal on the
      -- RESOLVED file_index, the authoritative check (see Finding MACRO-01 hardening in write_book).
      refused_active = refused_active + 1
      log("  book " .. book.bookIndex .. ": you're on this book in-game right now, switch to a different book first, then pull again. NOT written.")
    else
      local ok, hit_active = write_book(macro_dir, book, active_book, run_state)
      if ok then
        acked[#acked + 1] = { bookIndex = book.bookIndex, contentHash = book.contentHash }
      elseif hit_active then
        refused_active = refused_active + 1
      else
        failed = failed + 1
      end
    end
  end

  if #acked > 0 then
    local ack_status, ack_response = post(settings.api_base .. '/macros/ack', json_encode({ characterName = name, books = acked }))
    if ack_status ~= 200 then
      log(
        'macros pull: wrote '
          .. #acked
          .. ' book(s) locally but the ack POST failed ['
          .. tostring(ack_status)
          .. ']: '
          .. ingest_errors.describe_failure(ack_status, ack_response)
          .. ' (harmless, they will pull again next time).'
      )
    end
  end

  log('macros pull: wrote ' .. #acked .. ' book(s), refused ' .. refused_active .. ' (active in-game), failed ' .. failed .. '.')
end

local function do_macros(args)
  local sub = (args[1] or 'push'):lower()
  if sub == 'push' then
    do_macros_push()
  elseif sub == 'pull' then
    do_macros_pull(args[2])
  else
    log('usage: //lootryx macros push | macros pull <activeBookIndex>')
  end
end

-- ─────────────────────── Manual ToD reporting (owner decision 2026-07-29) ───────────────────────
-- //lootryx tod <target name> reports a Time of Death you just witnessed, crediting YOU as the
-- reporter. Docs: docs/prds/manual-tod-credit.md.
--
-- COMMAND-TRIGGERED ONLY, the entire reason the design is shaped this way: a typed command is a
-- user action reporting outward, the SAME class as `//lootryx macros push` above, so it needs no
-- Phoenix Rule 9 ruling for a kill-event hook (there is no hook). Never called from the
-- `prerender` loop below, never registered to any combat/death/packet event, no automatic kill
-- detection anywhere in this file. `killedAt` is always NOW, at send time: there is deliberately
-- no backdating argument here, because `assertIngestTimestampFresh` (apps/api/src/lib/hmac.ts)
-- bounds the addon's claimed kill time to the request's own freshness window (AB-23, stops a
-- falsified timestamp from permanently poisoning a target's pop-window math). Backdating a ToD
-- stays an officer-only action through the Discord `/tod` command, deliberately unbounded there.
--
-- POSTs the EXISTING `/api/ingest/tod` route (COV-3), the SAME by-name-match + dedup + write path
-- (recordHnmKill, packages/database/hnm-kill.ts) the officer /tod command and the web manual kill
-- already use: no fourth report path. A duplicate report of an already-known kill is a deliberate,
-- documented no-op server-side ("first report wins", the anti-farming property), never an error.

-- Pure payload builder, split out so it is directly testable without a live network response
-- (packages/addon-harness): the /tod route's body shape is exactly `{ target, reporter, killedAt }`.
local function build_tod_report(target, reporter, killed_at)
  return {
    target = target,
    reporter = reporter,
    killedAt = killed_at or os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
end

-- Pure reply formatting, also split out for the same testability reason (mirrors
-- response_has_book above): recordHnmKill's `{ matched, updated }` covers exactly three outcomes.
-- `awarded_dkp` (owner decision 2026-07-29, docs/prds/tod-report-reward.md) is the OPTIONAL fourth
-- field the /tod response now carries: a positive number when this report actually paid, nil/false
-- on every shell that hasn't opted in (the amount defaults to 0) and on a report the five defences
-- paid nothing for. Omitting the argument (every call site before this feature) reproduces the
-- exact prior text, byte for byte.
function say.tod_reply_message(target, matched, updated, awarded_dkp)
  if not matched then
    return target .. ' is not a tracked NM target. Ask an officer to set it up: ' .. site_url() .. '/shells/' .. tostring(settings.shell_slug) .. '/hnm?tab=manage'
  end
  if not updated then
    return target .. ': already reported (first report wins), no credit for this report.'
  end
  if type(awarded_dkp) == 'number' and awarded_dkp > 0 then
    return target .. ': ToD recorded, credited to you (+' .. tostring(awarded_dkp) .. ' DKP).'
  end
  return target .. ': ToD recorded, credited to you.'
end

local function do_tod(args, killed_at)
  local target = table.concat(args, ' ')
  local function reply(message, ok)
    hud_state.tod_feedback = { message = message, ok = ok == true }
    log(message)
    return ok == true
  end
  if target == '' then
    return reply('usage: //lootryx tod <target name>', false)
  end
  local name = self_name()
  if not name then
    return reply('cannot read your character name (are you logged in?).', false)
  end

  local body = json_encode(build_tod_report(target, name, killed_at))
  local status, response = post(settings.api_base .. '/tod', body)
  if status ~= 200 then
    return reply('tod failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response), false)
  end

  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    return reply('Could not read the ToD response. Check the board before retrying.', false)
  end
  return reply(say.tod_reply_message(target, decoded.matched == true, decoded.updated == true, decoded.awardedDkp), decoded.matched == true and decoded.updated == true)
end

-- //lootryx drop <item name> <winner> reports a drop you just witnessed being awarded.
-- Docs: docs/prds/addon-ground-truth.md (ADDON-GT-1).
--
-- COMMAND-TRIGGERED ONLY, the same class as `//lootryx tod` above: a typed command reporting
-- outward. Never called from the `prerender` loop, never registered to any loot/treasure-pool or
-- packet event, and there is no automatic drop detection anywhere in this file. `capturedAt` is
-- always NOW at send time; like `/tod` there is deliberately no backdating argument, because
-- `assertIngestTimestampFresh` (apps/api/src/lib/hmac.ts) bounds the claimed time to the request's
-- own freshness window.
--
-- POSTs the EXISTING `/api/ingest/drop` route (COV-6), which has been live and HMAC-verified since
-- before this command existed and was simply consumed by nothing. Same by-name-match + dedup +
-- write path (recordDropFromAddon, packages/database/drop-ingest.ts) the web drop log uses: no
-- second report path. A duplicate report of an already-recorded drop is a documented server-side
-- no-op ("first report wins"), never an error.

-- Pure payload builder, split out so it is directly testable without a live network response
-- (packages/addon-harness), mirroring build_tod_report above. The /drop route's body shape is
-- `{ shell?, itemName, recipient, capturedAt }`.
--
-- `shell` is omitted on purpose, exactly as build_tod_report omits it: the field is informational
-- only and the HMAC key alone resolves the tenant (invariant 8). Sending it would invite the reader
-- to believe it scopes something.
local function build_drop_report(item_name, recipient)
  return {
    itemName = item_name,
    recipient = recipient,
    capturedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
end

-- Pure reply formatting, split out for the same reason as say.tod_reply_message. recordDropFromAddon's
-- `{ matched, recorded }` covers exactly three outcomes and this renders all three, because "your
-- report did nothing" and "your report was recorded" must never look alike in the chat log.
function say.drop_reply_message(item_name, recipient, matched, recorded)
  if not matched then
    return recipient .. ' is not a linked character on this shell: ' .. item_name .. ' was NOT recorded.'
  end
  if not recorded then
    return item_name .. ' to ' .. recipient .. ': already reported (first report wins).'
  end
  return item_name .. ' to ' .. recipient .. ': recorded.'
end

-- The WINNER is the last token and the ITEM is everything before it. FFXI character names are a
-- single word of 3-15 characters; item names very often are not ("Kirin's Osode", "Piece of
-- Omega's Eye"), so splitting from the end is the only parse that does not need quoting.
local function split_drop_args(args)
  if #args < 2 then
    return nil, nil
  end
  local recipient = args[#args]
  local parts = {}
  for i = 1, #args - 1 do
    parts[#parts + 1] = args[i]
  end
  return table.concat(parts, ' '), recipient
end

local function do_drop(args)
  local item_name, recipient = split_drop_args(args)
  if not item_name or item_name == '' then
    log('usage: //lootryx drop <item name> <winner>')
    log('  e.g. //lootryx drop Kirin\'s Osode Talvos')
    return
  end
  if not self_name() then
    log('cannot read your character name (are you logged in?).')
    return
  end

  local body = json_encode(build_drop_report(item_name, recipient))
  local status, response = post(settings.api_base .. '/drop', body)
  if status ~= 200 then
    log('drop failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end

  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('drop: could not parse the server response for ' .. item_name .. '.')
    return
  end
  log(say.drop_reply_message(item_name, recipient, decoded.matched == true, decoded.recorded == true))
end

-- ─────────────────── Read commands: dkp / standings / windows (docs/prds/addon-read-commands.md) ───────────────────
-- `//lootryx dkp`, `//lootryx standings [pool]`, and `//lootryx windows` all POST the SAME
-- composite read route, `/me` (the ingest surface's FIRST read endpoint: every route above is a
-- write or a command), and each renders only the slice of the response it needs. COMMAND-TRIGGERED
-- ONLY, same class as `//lootryx tod`/`macros push` above: never called from the `prerender` loop,
-- no polling, no auto-refresh. Nothing here mutates anything server-side (no writes, no audit
-- rows), so there is no compliance question beyond "is this still a read" — it is: the addon only
-- ever fetches the caller's own numbers back over the same HMAC-signed transport every other
-- command already uses.
--
-- REUSE, NOT RE-DERIVATION: the server side of `/me` (apps/api/src/modules/ingest/handlers.ts)
-- computes every number through the SAME shared helpers the web app and Discord already call
-- (memberWallets/headlineWallet/hasSplitWallets, resolveStandingsPool/standings, hnmWindows), each
-- already the site of a fixed wrong-number bug (D1/A16-3, A16-7). This file only FORMATS the
-- numbers it is handed; it never re-derives a balance, a rank, or a window state itself.

-- A23-27: safe field coercion for `/me` response rows. Only the REQUEST is HMAC-signed (invariant
-- 8); the RESPONSE carries no integrity check, and addon/README.md documents a plain-HTTP fallback
-- when luasec is absent, so a network-path attacker on that fallback could forge a row with a
-- null/wrong-typed field. `do_dkp`/`do_standings`/`do_windows` below only shallow-check the
-- top-level container (`decoded.dkp`/`decoded.standings`/`decoded.windows` is a table), never the
-- fields inside it, so an unguarded `..` (concat) or `-` (arithmetic) on a malformed field throws
-- an uncaught Lua traceback instead of the friendly "could not parse" failure the rest of the
-- addon shows. These coerce a field to what the renderer needs, or a visible placeholder, so a bad
-- row degrades to a readable line instead of crashing the whole render.
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

-- Pure payload builder, split out for the same testability reason as build_tod_report above: the
-- `/me` body is exactly `{}` for dkp/windows, or `{ pool = <query> }` for a NAMED standings pool.
-- `pool_query` nil or '' means "no argument", which the server resolves through
-- `resolveStandingsPool` (@hoard/discord-shared) to the shell's DEFAULT pool, never `pools[0]`
-- display order (AUDIT A16-7, already fixed on three OTHER surfaces before this one existed).
local function build_me_request(pool_query)
  if pool_query and pool_query ~= '' then
    return { pool = pool_query }
  end
  return {}
end

-- Pure renderer for the response's `dkp` block: `{ splitVisible, headline, wallets:
-- [{poolName, currentBalance}] }`. `splitVisible` is the PER-MEMBER gate (`hasSplitWallets`,
-- @hoard/shared), the same one `/whoami`/`/mydkp`/`/dkp` already render through, deliberately NOT
-- the shell-level `splitPoolsVisible`: a member holding points in only their default wallet sees
-- ONE number even on a shell running split pools for everyone else, and a member who genuinely
-- holds two-plus wallets always sees every one of them, side by side, NEVER summed (summing would
-- state a fungibility the PRD says does not exist).
--[[
  Every chat renderer, in one table.

  Lua 5.1 allows a function 200 locals and this addon's main chunk is one function, so each
  file-scope `local function` spends part of a fixed budget, and the event signup hit the
  ceiling. These fifteen are the natural cluster to move: they take a table and return lines of
  chat, nothing more.

  Deliberately NOT the `do_*` command handlers, which were tried first and reverted. Their
  names are load-bearing: compliance.test.ts scans the shipped source for `do_*` call sites
  inside the prerender registration to prove the render loop auto-fires nothing but the
  snapshot, as an EXACT list, so that a future command wired into that loop fails immediately.
  Renaming them would leave that scanner matching nothing and passing regardless, which is a
  guard that can no longer fail. The 200-local budget is not worth paying for with that.
]]

function say.dkp_reply_lines(dkp)
  if dkp.splitVisible then
    local lines = { 'DKP (every wallet):' }
    local wallets = type(dkp.wallets) == 'table' and dkp.wallets or {}
    for _, wallet in ipairs(wallets) do
      if type(wallet) == 'table' then
        lines[#lines + 1] = '  ' .. safe_str(wallet.poolName, '(unknown pool)') .. ': ' .. tostring(wallet.currentBalance)
      end
    end
    return lines
  end
  return { 'DKP: ' .. tostring(dkp.headline) }
end

-- Pure renderer for the response's `standings` block: `{ poolName, rows: [{rank, name, dkp}] }`.
-- `poolName` is absent (a JSON `null` decodes to a missing Lua key, lib/json.lua) on a shell that
-- has not genuinely turned split pools on, matching Discord's `/standings` unqualified footer
-- exactly (THE INVISIBILITY RULE: no pool name, no wallet chrome, byte-identical to pre-feature
-- Lootryx).
function say.standings_reply_lines(reply)
  local rows = type(reply.rows) == 'table' and reply.rows or {}
  local suffix = reply.poolName and (' (' .. safe_str(reply.poolName) .. ')') or ''
  if #rows == 0 then
    return { 'no standings yet' .. suffix .. '.' }
  end
  local lines = { 'standings' .. suffix .. ':' }
  for _, row in ipairs(rows) do
    if type(row) == 'table' then
      lines[#lines + 1] =
        '  #' .. tostring(row.rank) .. ' ' .. safe_str(row.name, '(unknown)') .. ' - ' .. tostring(row.dkp) .. ' DKP'
    end
  end
  return lines
end

-- Pure duration formatter, seconds -> "2h 15m" / "45m" / "<1m". THE implementation lives in
-- lib/hud.lua, because the HUD renders the same countdowns these chat commands do and two copies
-- would eventually disagree about what "45m" means. Bound to a local so it reads the same at every
-- call site below, and so the addon-harness can still recover it as a file-local.
--
-- Every call site clamps its input to >= 0 first (`math.max(0, ...)`), so this never has to handle
-- a negative duration.
local format_duration_short = hud_lib.format_duration

-- Pure renderer for ONE `windows` row: `{ name, zone, status, openAtMs, closeAtMs }`, the exact
-- shape `hnmWindows` (@hoard/discord-shared) returns, derived from the SAME pure `hnmWindowState`
-- (@hoard/shared) the web pops board itself uses, so the addon can never show a different window
-- than the web/Discord boards do. `now_ms` is the CALLER's own `os.time() * 1000` at render time
-- (there is no per-line server round-trip), so the countdown stays accurate to when the player
-- reads the chat line, not to when the request was sent.
function say.hnm_window_line(row, now_ms)
  local name = safe_str(row.name, '(unknown target)')
  local head = row.zone and (name .. ' (' .. safe_str(row.zone) .. ')') or name
  if row.status == 'OPEN' then
    local remaining = math.max(0, math.floor((safe_num(row.closeAtMs, now_ms) - now_ms) / 1000))
    return head .. ': OPEN now, closes in ' .. format_duration_short(remaining)
  elseif row.status == 'WAITING' then
    local remaining = math.max(0, math.floor((safe_num(row.openAtMs, now_ms) - now_ms) / 1000))
    return head .. ': opens in ' .. format_duration_short(remaining)
  elseif row.status == 'MISSED' then
    local ago = math.max(0, math.floor((now_ms - safe_num(row.closeAtMs, now_ms)) / 1000))
    return head .. ': missed, closed ' .. format_duration_short(ago) .. ' ago'
  end
  return head .. ': no time-of-death recorded yet'
end

-- Pure renderer for the whole `windows` array. Actionable-first ordering is already applied
-- server-side (`hnmWindows`: OPEN soonest-to-close, then WAITING soonest-to-open, then MISSED, then
-- UNKNOWN), so this only formats, it never re-sorts.
function say.windows_reply_lines(rows, now_ms)
  if #rows == 0 then
    return { 'no HNM targets are tracked on this shell yet.' }
  end
  local lines = {}
  for _, row in ipairs(rows) do
    if type(row) == 'table' then
      lines[#lines + 1] = say.hnm_window_line(row, now_ms)
    end
  end
  return lines
end

--[[
  One line of the `/me` `events` block:
  `{ id, title, type, pool, pointValue, scheduledAtMs, checkInOpenUntilMs, mySignup, going }`.

  The fact this exists to carry is `checkInOpenUntilMs`. Attendance is what this addon is FOR, and
  until now a member could post a snapshot without being able to see the thing it attaches to: run
  `//lootryx snap` outside an open check-in and the answer was a refusal with no way to learn when it
  WOULD work, which reads as a broken addon rather than as an officer who has not started check-in.

  `safe_str`/`safe_num` throughout for the usual reason: only the REQUEST is signed, so a malformed
  field must degrade to a readable line rather than a traceback.
]]
function say.event_line(row, now_ms)
  local parts = { '  ' .. safe_str(row.title, '(untitled event)') }
  parts[#parts + 1] = ' [' .. safe_str(row.type, '?') .. ']'
  parts[#parts + 1] = ' ' .. tostring(safe_num(row.pointValue, 0)) .. ' DKP'

  local open_until = safe_num(row.checkInOpenUntilMs, 0)
  if open_until > now_ms then
    parts[#parts + 1] = ' - CHECK-IN OPEN, ' .. format_duration_short(math.floor((open_until - now_ms) / 1000)) .. ' left'
  else
    local starts_in = math.floor((safe_num(row.scheduledAtMs, now_ms) - now_ms) / 1000)
    if starts_in > 0 then
      parts[#parts + 1] = ' - starts in ' .. format_duration_short(starts_in)
    else
      parts[#parts + 1] = ' - started, check-in not open'
    end
  end

  -- Your own answer, never anyone else's: the addon may know whether YOU are going and how many
  -- are, and the server deliberately sends nothing more than that.
  if type(row.mySignup) == 'string' and row.mySignup ~= '' then
    parts[#parts + 1] = '  (you: ' .. row.mySignup:lower() .. ')'
  end
  return table.concat(parts)
end

--- Pure renderer for the whole `events` array.
function say.events_reply_lines(rows, now_ms)
  if type(rows) ~= 'table' or #rows == 0 then
    return { 'no events are scheduled on this shell.' }
  end
  local lines = { 'upcoming events:' }
  for _, row in ipairs(rows) do
    if type(row) == 'table' then
      lines[#lines + 1] = say.event_line(row, now_ms)
    end
  end
  lines[#lines + 1] = 'snapshot with //lootryx snap while a check-in is open.'
  return lines
end

--[[
  Answering an event.

  The addon could already SHOW your answer and not change it, which is the wrong half of the
  feature: an event with an open check-in is the one thing in this product with a deadline you can
  miss by standing still, and the person standing still is in the game.

  BENCH is not offered. It is what capacity ASSIGNS when an event is full, never something a member
  picks, and the server refuses it; the reply says so when a full event waitlists you, which is a
  different sentence from the one you asked for and has to read like one.
]]
local SIGNUP_CHOICES = {
  { status = 'ATTENDING', label = 'Going', blurb = 'count me in' },
  { status = 'LATE', label = 'Late', blurb = 'coming, but not on time' },
  { status = 'TENTATIVE', label = 'Maybe', blurb = 'not sure yet' },
  { status = 'ABSENCE', label = 'Out', blurb = 'cannot make this one' },
}

local function send_signup(event_id, status)
  local main, sub = self_jobs()
  local body = { eventId = event_id, status = status }
  -- `self_jobs` is the ONE place that decides what a coherent pair is (a subjob with no main job is
  -- not a shape the game produces, and the server refuses it). Re-guarding it here made both checks
  -- redundant, and a redundant guard is one that can be removed without any test noticing.
  if main then
    body.job = main
  end
  if sub then
    body.subjob = sub
  end

  local code, response = post(settings.api_base .. '/signup', json_encode(body))
  if code ~= 200 then
    log('signup failed [' .. tostring(code) .. ']: ' .. ingest_errors.describe_failure(code, response))
    return false
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('could not parse the server response.')
    return false
  end

  local landed = safe_str(decoded.status, status)
  local as = safe_str(decoded.job, '')
  if as ~= '' and safe_str(decoded.subjob, '') ~= '' then
    as = as .. '/' .. safe_str(decoded.subjob, '')
  end
  if landed ~= status then
    -- Not the answer that was asked for. Saying "you are marked ATTENDING" here would be wrong in
    -- the one direction that costs somebody a slot they think they have.
    log('that event is full, so you are on the bench instead of ' .. status:lower() ..
      (as ~= '' and ('  as ' .. as) or '') .. '.')
  else
    log('marked ' .. landed:lower() .. (as ~= '' and ('  as ' .. as) or '') .. '.')
  end

  -- Re-read, so the board shows what the server actually recorded rather than what was asked for.
  local refresh_code, refresh_body = post(settings.api_base .. '/me', json_encode({ events = true }))
  if refresh_code == 200 then
    local ok2, decoded2 = pcall(json.decode, refresh_body)
    if ok2 and type(decoded2) == 'table' then
      record_denials(decoded2)
      if not denied('events') then
        hud_state.events = decoded2.events
      end
    end
  end
  return true
end

--- `//lootryx signup <number> <going|late|maybe|out>`, numbered off the list you were just shown.
local function do_signup(args)
  local index = tonumber(args[1])
  local answer = type(args[2]) == 'string' and args[2]:lower() or nil
  local by_word = {
    going = 'ATTENDING', attending = 'ATTENDING', yes = 'ATTENDING',
    late = 'LATE',
    maybe = 'TENTATIVE', tentative = 'TENTATIVE',
    out = 'ABSENCE', no = 'ABSENCE', absence = 'ABSENCE',
  }
  local status = answer and by_word[answer] or nil
  if not index or index < 1 or index ~= math.floor(index) or not status then
    log('usage: //lootryx signup <number> <going|late|maybe|out>   (the number from //lootryx events)')
    return
  end
  if type(hud_state.events) ~= 'table' or #hud_state.events == 0 then
    log('run //lootryx events first, then answer by its number.')
    return
  end
  local event = hud_state.events[index]
  if not event then
    log('there is no event ' .. tostring(index) .. ' in the list you were shown (1-' ..
      #hud_state.events .. ').')
    return
  end
  send_signup(safe_str(event.id, ''), status)
end

--[[
  `//lootryx myjobs` reads it; `//lootryx myjobs <job> [second] [third]` declares.

  `here` is the word that makes this worth having in game: it means the job you are standing here
  as, so declaring costs no typing and cannot be misspelled. `-` clears a slot, and an omitted slot
  keeps whatever is stored, which is the same rule Discord's `/myjobs` follows.
]]
local function myjobs_slot(word)
  if word == nil then
    return nil
  end
  local lowered = word:lower()
  if lowered == '-' or lowered == 'clear' or lowered == 'none' then
    return false
  end
  if lowered == 'here' or lowered == 'current' then
    local main = self_jobs()
    return main
  end
  return word:upper()
end

local function do_myjobs(args)
  local body = {}
  local names = { 'first', 'second', 'third' }
  for i = 1, 3 do
    local parsed = myjobs_slot(args[i])
    if parsed == false then
      body[names[i]] = JSON_NULL
    elseif parsed ~= nil then
      body[names[i]] = parsed
    end
  end
  -- `here` with no job readable resolves to nothing, and sending nothing would silently turn a
  -- declaration into a read. Say so instead.
  if args[1] ~= nil and next(body) == nil then
    log('could not read the job you are on. name it instead: //lootryx myjobs <job>')
    return
  end

  body.characterName=self_name()
  local status, response = post(settings.api_base .. '/myjobs', json_encode(body))
  if status ~= 200 then
    host.ui_tools.plan_feedback=ingest_errors.describe_failure(status,response)
    log('myjobs failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('could not parse the server response.')
    return
  end
  host.ui_tools.plan_feedback=nil
  hud_state.myjobs = decoded.declaration
  hud_state.observed_jobs = decoded.current
  window_refresh()
  for _, line in ipairs(say.myjobs_reply_lines(decoded.declaration)) do
    log(line)
  end
end

--- `//lootryx statics`: the linkshell's own recruiting board, both sides of it.
local function do_statics()
  local status, response = post(settings.api_base .. '/me', json_encode({ statics = true }))
  if status ~= 200 then
    log('statics failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('could not parse the server response.')
    return
  end
  record_denials(decoded)
  if denied('statics') then
    log('Your role cannot read linkshell teams. Ask an officer for access.')
    hud_state.statics, hud_state.seekers = nil, nil
    return
  end
  hud_state.statics = decoded.statics or {}
  hud_state.seekers = decoded.seekers or {}
  hud_state.seeking = decoded.youAreSeeking == true
  window_refresh()
  for _, line in ipairs(say.statics_reply_lines(hud_state.statics, hud_state.seekers)) do
    log(line)
  end
end

--[[
  `//lootryx unseek`: take yourself off the static board.

  Removal only, and the board says so rather than pretending otherwise. LISTING yourself needs a
  timezone, availability windows, a commitment level and a voice preference; that is a form, and an
  addon that faked a half-filled version of it would put you on the board with no availability and
  waste the time of every host who clicks you. Removal needs nothing but knowing who you are, and
  "I found a group, take me off" is exactly the thing you realise mid-game.
]]
local function do_unseek()
  local status, response = post(settings.api_base .. '/unseek', json_encode({}))
  if status ~= 200 then
    log('unseek failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('could not parse the server response.')
    return
  end
  -- "Taken off" and "you were never on it" are both fine outcomes and both worth saying, because
  -- one of them means the thing you wanted was already true.
  log(decoded.removed == true and 'you are no longer listed as seeking a static.'
    or 'you were not listed as seeking a static.')
  hud_state.seeking = false
  window_refresh()
end

--- Fetches the shell's open polls into hud_state. Shared by the command and the board.
local function fetch_polls(quiet)
  local status, response = post(settings.api_base .. '/me', json_encode({ polls = true }))
  if status ~= 200 then
    if not quiet then
      log('polls failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    end
    return false
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    if not quiet then
      log('could not parse the server response.')
    end
    return false
  end
  record_denials(decoded)
  if denied('polls') then
    if not quiet then
      log('Your role cannot read linkshell polls. Ask an officer for access.')
    end
    hud_state.polls = nil
    return false
  end
  hud_state.polls = decoded.polls or {}
  window_refresh()
  return true
end

local function do_polls()
  if fetch_polls(false) then
    for _, line in ipairs(say.polls_reply_lines(hud_state.polls)) do
      log(line)
    end
  end
end

--[[
  `//lootryx vote <poll> <choice>`, both numbered off the list you were just shown.

  Clicking or typing a choice you already hold TAKES IT BACK, which is how the Discord buttons
  behave: one control that toggles, so there is no separate unvote to remember.
]]
local function send_vote(poll_id, option_id)
  local status, response = post(settings.api_base .. '/vote',
    json_encode({ pollId = poll_id, optionId = option_id }))
  if status ~= 200 then
    log('vote failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('could not parse the server response.')
    return
  end
  log(safe_str(decoded.outcome, '') == 'removed' and 'vote taken back.' or 'vote recorded.')
  -- Re-read so the counts on screen are the server's, not an increment guessed locally.
  fetch_polls(true)
end

local function do_vote(args)
  local poll_index = tonumber(args[1])
  local choice_index = tonumber(args[2])
  if not poll_index or not choice_index then
    log('usage: //lootryx vote <poll> <choice>   (both numbers from //lootryx polls)')
    return
  end
  if type(hud_state.polls) ~= 'table' or #hud_state.polls == 0 then
    log('run //lootryx polls first, then vote by its number.')
    return
  end
  local poll = hud_state.polls[poll_index]
  if not poll then
    log('there is no poll ' .. tostring(poll_index) .. ' in the list you were shown (1-' ..
      #hud_state.polls .. ').')
    return
  end
  local option = type(poll.options) == 'table' and poll.options[choice_index] or nil
  if not option then
    log('poll ' .. tostring(poll_index) .. ' has no choice ' .. tostring(choice_index) .. '.')
    return
  end
  send_vote(safe_str(poll.id, ''), safe_str(option.id, ''))
end

--- `//lootryx item <name>`: the catalog entry, plus this shell's tier / DKP value / wishlisters.
local function do_item(args)
  local query = table.concat(args, ' '):gsub('^%s+', ''):gsub('%s+$', '')
  if query == '' then
    log('usage: //lootryx item <name>   (what it is, and what your shell values it at)')
    return
  end
  local status, response = post(settings.api_base .. '/item', json_encode({ name = query }))
  if status ~= 200 then
    log('item failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('could not parse the server response.')
    return
  end
  hud_state.item = decoded.found == true and decoded or nil
  hud_state.item_query = query
  window_refresh()
  for _, line in ipairs(say.item_reply_lines(
    decoded.found == true, query, decoded.item or {}, decoded.shell
  )) do
    log(line)
  end
end

-- `//lootryx events`: what is scheduled, and whether a snapshot would land right now.
local function do_events()
  local body = json_encode({ events = true })
  local status, response = post(settings.api_base .. '/me', body)
  if status ~= 200 then
    log('events failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('events: could not parse the server response.')
    return
  end
  record_denials(decoded)
  if denied('events') then
    log('Your role cannot read the event calendar. Ask an officer for access.')
    hud_state.events = nil
    return
  end
  hud_state.events = decoded.events
  window_refresh()
  for _, line in ipairs(say.events_reply_lines(decoded.events, os.time() * 1000)) do
    log(line)
  end
end

--[[
  The caller's own wishlist.

  A wishlist is a thing you think about while looking at loot, which is to say in game, and it was
  reachable only from the web and Discord. The addon already knows how to search item names for the
  drop composer, so the same picker fills this in.

  What the server sends back deliberately does NOT include `maxDkp`. That is a standing sealed
  pre-bid ceiling, and the addon has no business carrying an amount it must never display; it is not
  in the projection at all, so there is nothing here to leak.
]]
--[[
  One item, and what the linkshell thinks of it.

  The most in-game-native question this product answers: you are looking at something in a treasure
  pool and want to know what it is and what it is worth here. Every other surface makes you leave
  the game to ask.

  The shell overlay (tier, DKP value, who wants it) is membership-gated and not permission-gated,
  matching Discord's `/item`. A sealed pre-bid ceiling is never part of it, on any surface.
]]
--- `FfxiItem.jobs` is a String[] in the schema, not a string. Rendering it as one produced an
--- empty jobs line for every item, which reads as "no job can equip this".
local function job_list(jobs)
  if type(jobs) ~= 'table' then
    return ''
  end
  local out = {}
  for _, job in ipairs(jobs) do
    if type(job) == 'string' and job ~= '' then
      out[#out + 1] = job
    end
  end
  return table.concat(out, '/')
end

--[[
  Your job declaration: which jobs you have claimed, in order, and whether it is locked.

  Ranked, not listed. The first slot is the one loot priority reads, so "which of these do you most
  want gear for" is the question the order answers.
]]
function say.myjobs_reply_lines(decl)
  if type(decl) ~= 'table' then
    return { 'could not read your job declaration.' }
  end
  local slots = {
    { label = '1st', job = decl.declaredMain },
    { label = '2nd', job = decl.declaredSecondary },
    { label = '3rd', job = decl.declaredTertiary },
  }
  local any = false
  local lines = { 'your jobs:' }
  for _, slot in ipairs(slots) do
    if type(slot.job) == 'string' and slot.job ~= '' then
      any = true
      lines[#lines + 1] = '  ' .. slot.label .. '  ' .. slot.job
    end
  end
  if not any then
    lines = { 'you have not declared any jobs yet. //lootryx myjobs <job> [second] [third]' }
  end
  if decl.locked == true then
    local left = safe_num(decl.lockDaysRemaining, 0)
    lines[#lines + 1] = '  locked for another ' .. tostring(left) ..
      (left == 1 and ' day' or ' days') .. '. an officer can change it for you.'
  elseif decl.jobsDeclaredAt == nil then
    -- Never declared is not the same as unlocked-again, and the difference is worth saying: the
    -- first one costs nothing, which is the moment to mention it.
    lines[#lines + 1] = '  your first declaration is free.'
  end
  return lines
end

--[[
  The linkshell's own Static Finder board: who is recruiting, and who is looking.

  Both halves in one answer, because they are the same question from opposite sides. Someone asking
  "is anyone running a Dynamis static" almost always also wants to know whether anyone is looking,
  and this board is small enough that splitting it into two commands would only make you type twice.
]]
function say.statics_reply_lines(statics, seekers)
  local lines = {}
  if type(statics) ~= 'table' or #statics == 0 then
    lines[#lines + 1] = 'nobody is recruiting a static on this shell.'
  else
    lines[#lines + 1] = 'recruiting:'
    for _, row in ipairs(statics) do
      if type(row) == 'table' then
        local open = safe_num(row.openSlots, 0)
        local jobs = job_list(row.openJobs)
        lines[#lines + 1] = '  ' .. safe_str(row.title, '(untitled)') ..
          (safe_str(row.hostName, '') ~= '' and ('  by ' .. safe_str(row.hostName, '')) or '') ..
          '  ' .. tostring(open) .. (open == 1 and ' seat' or ' seats') ..
          (jobs ~= '' and ('  ' .. jobs) or '')
      end
    end
  end

  if type(seekers) == 'table' and #seekers > 0 then
    lines[#lines + 1] = 'looking for a static:'
    for _, row in ipairs(seekers) do
      if type(row) == 'table' then
        local job = safe_str(row.mainJob, '')
        local sub_job = safe_str(row.secondaryJob, '')
        lines[#lines + 1] = '  ' .. safe_str(row.name, '(someone)') ..
          (job ~= '' and ('  ' .. job .. (sub_job ~= '' and ('/' .. sub_job) or '')) or '') ..
          (safe_str(row.commitment, '') ~= '' and ('  ' .. safe_str(row.commitment, ''):lower()) or '')
      end
    end
  end
  return lines
end

--[[
  The shell's open polls, with your own choices marked.

  A poll is a question the linkshell is asking itself, and the answer is usually "when can you make
  it", which is a thing you know while you are sitting in the game rather than later at a browser.
]]
function say.polls_reply_lines(polls)
  if type(polls) ~= 'table' or #polls == 0 then
    return { 'no open polls on this shell.' }
  end
  local lines = { 'open polls:' }
  for index, poll in ipairs(polls) do
    if type(poll) == 'table' then
      lines[#lines + 1] = '  ' .. tostring(index) .. '. ' .. safe_str(poll.question, '(no question)')
      for choice, option in ipairs(type(poll.options) == 'table' and poll.options or {}) do
        lines[#lines + 1] = '     ' .. tostring(choice) .. ') ' ..
          safe_str(option.label, '(unlabelled)') ..
          '  ' .. tostring(safe_num(option.votes, 0)) ..
          (option.mine == true and '  <- yours' or '')
      end
    end
  end
  lines[#lines + 1] = 'vote with //lootryx vote <poll> <choice>.'
  return lines
end

function say.item_reply_lines(found, query, item, shell_view_of_it)
  if not found then
    return { 'no item found matching "' .. tostring(query) .. '".' }
  end
  local lines = { safe_str(item.name, '(unnamed)') }
  local bits = {}
  if safe_str(item.category, '') ~= '' then
    bits[#bits + 1] = safe_str(item.category, '')
  end
  if safe_str(item.slot, '') ~= '' then
    bits[#bits + 1] = safe_str(item.slot, '')
  end
  if safe_num(item.level, 0) > 0 then
    bits[#bits + 1] = 'Lv' .. tostring(safe_num(item.level, 0))
  end
  if #bits > 0 then
    lines[#lines + 1] = '  ' .. table.concat(bits, '  ')
  end
  local jobs = job_list(item.jobs)
  if jobs ~= '' then
    lines[#lines + 1] = '  jobs: ' .. jobs
  end
  if safe_str(item.source, '') ~= '' then
    lines[#lines + 1] = '  from: ' .. safe_str(item.source, '')
  end

  if type(shell_view_of_it) ~= 'table' then
    return lines
  end
  -- A shell that has never catalogued the item has no opinion, which is a different answer from a
  -- value of zero and has to read like one.
  local tier = safe_str(shell_view_of_it.tier, '')
  local value = shell_view_of_it.dkpValue
  if tier ~= '' or value ~= nil then
    lines[#lines + 1] = '  your shell: ' ..
      (tier ~= '' and ('tier ' .. tier) or 'no tier') ..
      (value ~= nil and ('  ' .. tostring(safe_num(value, 0)) .. ' DKP') or '  no DKP value set')
  else
    lines[#lines + 1] = '  your shell has not catalogued this one.'
  end
  local wants = type(shell_view_of_it.wishlistedBy) == 'table' and shell_view_of_it.wishlistedBy or {}
  if #wants > 0 then
    lines[#lines + 1] = '  wishlisted by: ' .. table.concat(wants, ', ')
  end
  return lines
end

function say.wishlist_reply_lines(rows)
  if type(rows) ~= 'table' or #rows == 0 then
    return { 'your wishlist is empty. add with //lootryx wish add <item>.' }
  end
  local lines = { 'your wishlist:' }
  for _, row in ipairs(rows) do
    if type(row) == 'table' then
      local mark = safe_str(row.status, 'WANTED') == 'OBTAINED' and ' (got it)' or ''
      -- Your own ceiling, which the website shows you too. It is sealed from EVERYONE ELSE, and the
      -- transport enforces that by only ever addressing your own list; there is no request shape
      -- that reaches another member's row, so there is nothing here to hide from yourself.
      local ceiling = safe_num(row.maxDkp, 0)
      if ceiling > 0 then
        mark = mark .. '  (pre-bid up to ' .. tostring(ceiling) .. ')'
      end
      lines[#lines + 1] = '  ' .. tostring(safe_num(row.priority, 2)) .. '. ' ..
        safe_str(row.itemName, '(unknown item)') .. mark
    end
  end
  return lines
end

--- Shared by the command and the window: one fetch, one place that stores the result.
local function fetch_wishlist(quiet)
  local status, response = post(settings.api_base .. '/me', json_encode({ wishlist = true }))
  if status ~= 200 then
    if not quiet then
      log('wishlist failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    end
    return false
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    if not quiet then
      log('wishlist: could not parse the server response.')
    end
    return false
  end
  hud_state.wishlist = decoded.wishlist or {}
  window_refresh()
  return true
end

--- `//lootryx wish [add|remove] <item name>`.
local function do_wishlist(args)
  local sub_command = (args[1] or ''):lower()

  --[[
    `//lootryx wish max <amount|off> <item name>`: the standing sealed pre-bid, the same thing
    Discord's `/prebid` sets.

    The amount comes SECOND and the item name takes the rest of the line, the same shape
    `//lootryx drop` uses, because item names are multi-word far more often than not and quoting is
    the kind of thing people get wrong once and then stop using the command.
  ]]
  if sub_command == 'max' then
    local raw = args[2]
    local item_name = table.concat(args, ' ', 3)
    if not raw or item_name == '' then
      log('usage: //lootryx wish max <amount|off> <item name>')
      return
    end
    local clearing = tostring(raw):lower() == 'off'
    local amount = tonumber(raw)
    if not clearing and (not amount or amount < 1 or amount ~= math.floor(amount)) then
      log('a pre-bid ceiling is a whole number of DKP, or "off" to clear it.')
      return
    end

    -- json_encode drops a nil, and an ABSENT maxDkp means "leave it alone" server-side, which is the
    -- opposite of clearing. `off` therefore has to send an explicit null.
    local body = clearing
      and ('{"action":"add","itemName":' .. json_encode(item_name) .. ',"maxDkp":null}')
      or json_encode({ action = 'add', itemName = item_name, maxDkp = amount })
    local status, response = post(settings.api_base .. '/wishlist', body)
    if status ~= 200 then
      log('wishlist failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
      return
    end
    log(clearing and ('cleared the pre-bid ceiling on ' .. item_name .. '.')
      or ('pre-bid up to ' .. tostring(amount) .. ' DKP on ' .. item_name .. '.'))
    fetch_wishlist(true)
    return
  end

  if sub_command ~= 'add' and sub_command ~= 'remove' then
    if fetch_wishlist(false) then
      for _, line in ipairs(say.wishlist_reply_lines(hud_state.wishlist)) do
        log(line)
      end
    end
    return
  end

  local item_name = table.concat(args, ' ', 2)
  if item_name == '' then
    log('usage: //lootryx wish ' .. sub_command .. ' <item name>')
    return
  end

  local body = json_encode({ action = sub_command, itemName = item_name })
  local status, response = post(settings.api_base .. '/wishlist', body)
  if status ~= 200 then
    log('wishlist failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if sub_command == 'remove' then
    -- The route is idempotent and says how many rows went, which is the difference between "gone
    -- now" and "that was never on your list". Both are fine outcomes; they are not the same message.
    local removed = parse_ok and type(decoded) == 'table' and safe_num(decoded.removed, 0) or 0
    log(removed > 0 and ('removed ' .. item_name .. ' from your wishlist.')
      or (item_name .. ' was not on your wishlist.'))
  else
    log('added ' .. item_name .. ' to your wishlist.')
  end
  -- Re-read rather than patching the local copy: the server decides priority and status, and a
  -- guessed local edit is how two surfaces start disagreeing.
  fetch_wishlist(true)
end

--[[
  Bounties and recent loot: the two shell-wide reads worth having while you are out playing.

  A bounty is a standing "bring us this, get paid" and it is most useful in the moment you could
  actually go and do it, which is never while you are at a browser. Loot is the other half of the
  same question: what has this shell been getting.

  Both come off the SAME shared queries Discord's `/bounties` and `/loot` call, so the two surfaces
  cannot drift into telling a member different things about one shell.
]]
function say.bounties_reply_lines(rows)
  if type(rows) ~= 'table' or #rows == 0 then
    return { 'no open bounties on this shell.' }
  end
  local lines = { 'open bounties:' }
  for _, row in ipairs(rows) do
    if type(row) == 'table' then
      local left = row.slotsLeft
      -- nil means unlimited, which is a different fact from "none left" and has to read differently.
      local slots = left == nil and ' (unlimited)' or ('  ' .. tostring(safe_num(left, 0)) .. ' left')
      lines[#lines + 1] = '  ' .. safe_str(row.title, '(untitled)') ..
        '  ' .. tostring(safe_num(row.dkpReward, 0)) .. ' DKP' .. slots
    end
  end
  return lines
end

function say.loot_reply_lines(rows, now_ms)
  if type(rows) ~= 'table' or #rows == 0 then
    return { 'no drops recorded on this shell yet.' }
  end
  local lines = { 'recent drops:' }
  for _, row in ipairs(rows) do
    if type(row) == 'table' then
      local who = safe_str(row.recipientName, '')
      local ago = math.max(0, math.floor((now_ms - safe_num(row.createdAtMs, now_ms)) / 1000))
      lines[#lines + 1] = '  ' .. safe_str(row.itemName, '(unknown item)') ..
        '  ' .. safe_str(row.disposition, '?'):lower():gsub('_', ' ') ..
        (who ~= '' and (' to ' .. who) or '') ..
        '  ' .. format_duration_short(ago) .. ' ago'
    end
  end
  return lines
end

--- Shared by both commands and the window: one request, both blocks, one place that stores them.
local function fetch_shell_boards(quiet)
  local status, response = post(settings.api_base .. '/me', json_encode({ bounties = true, loot = true }))
  if status ~= 200 then
    if not quiet then
      log('failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    end
    return false
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    if not quiet then
      log('could not parse the server response.')
    end
    return false
  end
  record_denials(decoded)
  -- Refused blocks stay nil rather than becoming an empty list: "you may not see this" and "there
  -- are none" are opposite answers and the boards render them differently.
  --
  -- Spelled out with `if`, not `denied(x) and nil or y`. That idiom CANNOT express this: `nil` is
  -- falsy, so `true and nil or y` evaluates to `y` and the refusal silently became an empty list
  -- every time. It was written that way first and a mutation test caught it, because mutating the
  -- line changed nothing.
  if denied('bounties') then
    hud_state.bounties = nil
  else
    hud_state.bounties = decoded.bounties or {}
  end
  if denied('loot') then
    hud_state.loot = nil
  else
    hud_state.loot = decoded.loot or {}
  end
  window_refresh()
  if not quiet and (denied('bounties') or denied('loot')) then
    log('Your role cannot read '..(denied('loot') and 'loot history' or 'linkshell bounties')..'. Ask an officer for access.')
  end
  return true
end

local function do_bounties()
  -- A refusal has already been logged by fetch_shell_boards, and it is the whole answer. Following
  -- it with "no open bounties on this shell" would contradict it, and the contradiction is a lie
  -- about the caller's own linkshell.
  if fetch_shell_boards(false) and not denied('bounties') then
    for _, line in ipairs(say.bounties_reply_lines(hud_state.bounties)) do
      log(line)
    end
  end
end

local function do_loot()
  if fetch_shell_boards(false) and not denied('loot') then
    for _, line in ipairs(say.loot_reply_lines(hud_state.loot, os.time() * 1000)) do
      log(line)
    end
  end
end

--[[
  The bank: what the shell is holding and how much of it is sellable.

  Its own request rather than a third key on `fetch_shell_boards`, because the /me blocks are opt-in
  one at a time and asking for holdings while you wanted bounties is exactly the over-fetch that
  design is there to stop.

  gilValue on a holding is the value of the WHOLE holding, not per unit, so the total is a plain sum
  and must never be multiplied by quantity: `bankHoldings` in @hoard/discord-shared already sums it
  that way and the addon only renders what it is handed.
]]
function say.bank_reply_lines(bank, currency)
  if type(bank) ~= 'table' then
    return { 'could not read the bank.' }
  end
  local rows = type(bank.rows) == 'table' and bank.rows or {}
  if #rows == 0 then
    return { 'the shell bank is empty.' }
  end
  local lines = {
    'bank: ' .. tostring(safe_num(bank.totalItems, 0)) .. ' items, ' ..
      tostring(safe_num(bank.sellableGil, 0)) .. ' gil sellable',
  }
  for _, row in ipairs(rows) do
    if type(row) == 'table' then
      local qty = safe_num(row.quantity, 1)
      lines[#lines + 1] = '  ' .. safe_str(row.itemName, '(unknown item)') ..
        (qty > 1 and ('  x' .. tostring(qty)) or '') ..
        (row.sellable == true and '  sellable' or '  held')
    end
  end
  -- The currency treasury, which is the other half of "what does the shell hold": seals and coins
  -- are a stock you spend, not items sitting in a mule's inventory.
  for _, row in ipairs(type(currency) == 'table' and currency or {}) do
    if type(row) == 'table' then
      lines[#lines + 1] = '  ' .. safe_str(row.currency, '(currency)') ..
        '  ' .. tostring(safe_num(row.stock, 0)) .. ' held'
    end
  end
  return lines
end

--- Fetches the bank into hud_state. Shared by the command and the window's Bank board, so the two
--- cannot show different holdings for one shell.
local function fetch_bank(quiet)
  local status, response = post(settings.api_base .. '/me', json_encode({ bank = true }))
  if status ~= 200 then
    if not quiet then
      log('failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    end
    return false
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if parse_ok and type(decoded) == 'table' then
    record_denials(decoded)
  end
  -- A refusal is not a parse failure. The server answered, correctly, that this role may not read
  -- the bank; saying "could not parse" would blame the wrong thing and hide the real answer.
  if parse_ok and type(decoded) == 'table' and denied('bank') then
    if not quiet then
      log('Your role cannot read bank records. Ask an officer for access.')
    end
    hud_state.bank = nil
    return false
  end
  if not parse_ok or type(decoded) ~= 'table' or type(decoded.bank) ~= 'table' then
    if not quiet then
      log('could not parse the server response.')
    end
    return false
  end
  record_denials(decoded)
  hud_state.bank = decoded.bank
  -- Rides with the bank: same gate, same question, one round trip.
  hud_state.currency = decoded.currency
  window_refresh()
  return true
end

local function do_bank()
  if fetch_bank(false) then
    for _, line in ipairs(say.bank_reply_lines(hud_state.bank, hud_state.currency)) do
      log(line)
    end
  end
end

-- `//lootryx dkp`: the caller's OWN balance(s). No character-name argument, no usage guard to fail:
-- the ingest key alone resolves the caller's membership (invariant 8), so there is nothing to type
-- wrong here.
local function do_dkp()
  local body = json_encode(build_me_request(nil))
  local status, response = post(settings.api_base .. '/me', body, 'dkp')
  if status ~= 200 then
    log('dkp failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' or type(decoded.dkp) ~= 'table' then
    log('dkp: could not parse the server response.')
    return
  end
  hud_state.dkp = decoded.dkp
  window_refresh()
  for _, line in ipairs(say.dkp_reply_lines(decoded.dkp)) do
    log(line)
  end
end

-- `//lootryx standings [pool]`: top 10 by current balance. `[pool]` is optional and, when given,
-- may be multiple words (a pool name), joined the same way `//lootryx tod <target name>` joins its
-- argument above.
local function do_standings(args)
  local pool_query = table.concat(args, ' ')
  if pool_query == '' then
    pool_query = nil
  end
  local body = json_encode(build_me_request(pool_query))
  local status, response = post(settings.api_base .. '/me', body, 'standings')
  if status ~= 200 then
    if status==401 or status==403 then hud_state.standings=nil end
    hud_state.standings_error='Refresh failed. Previous results may be out of date.'
    log('standings failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' or type(decoded.standings) ~= 'table' then
    hud_state.standings=nil
    hud_state.standings_error='Could not read standings. Try refreshing.'
    log('standings: could not parse the server response.')
    return
  end
  hud_state.standings_error=nil
  hud_state.standings=decoded.standings
  for _, line in ipairs(say.standings_reply_lines(decoded.standings)) do
    log(line)
  end
end

-- `//lootryx windows`: tracked HNM targets with their next window open/close and a countdown, the
-- one a player actually wants at a camp.
local function do_windows()
  local body = json_encode(build_me_request(nil))
  local status, response = post(settings.api_base .. '/me', body, 'windows')
  if status ~= 200 then
    log('windows failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' or type(decoded.windows) ~= 'table' then
    log('windows: could not parse the server response.')
    return
  end
  hud_state.windows = decoded.windows
  local now_ms = os.time() * 1000
  for _, line in ipairs(say.windows_reply_lines(decoded.windows, now_ms)) do
    log(line)
  end
end

-- ─────────────────── Auctions: list / bid / all-in / open (docs/prds/addon-ground-truth.md §4) ───────────────────
-- ADDON-GT-2. Until this section there was no way to bid, and no way to open an auction, from
-- in-game at all: a player standing over a treasure pool had to alt-tab to the website inside a
-- four-minute window, which is the window the whole feature exists to fit inside.
--
-- COMMAND-TRIGGERED ONLY, the same class as every other command in this file: never called from the
-- `prerender` loop, no polling, no auto-refresh, and above all no automatic bidding. Nothing here
-- touches the GAME server or the game client's state; a bid is an HTTP POST to Lootryx, exactly like
-- reporting a ToD. `//lootryx auction` does not lot, claim, or move anything in-game either: it
-- opens a bidding window on the website.
--
-- NO AUCTION RULE LIVES IN THIS FILE. Whether a bid clears the tier floor, whether the mode takes a
-- percentage or a flat amount, whether the wallet covers it, whether the caller may open an auction
-- at all: every one of those is decided server-side by placeBid/createAuction, and a rejection is
-- shown with the SERVER'S OWN message, unparaphrased. A restated rule here would be a second copy
-- that drifts, and the copy players read.

-- The last list the player was SHOWN, index -> { id, name }. `bid 2` binds to the id captured when
-- they read line 2, so an auction opened between the listing and the bid can never silently
-- redirect it onto a different item. Deliberately has NO expiry: the binding is an exact auction
-- id, so the worst a stale entry can do is bid on an auction the server then reports closed, which
-- is the correct answer rather than a wrong bid.
local last_auction_list = {}

-- Pure renderer for ONE auction row of the `/me` response's `auctions` block:
-- `{ id, itemName, mode, tier, tierMinimum, fixedPrice, requiredJob, endsAtMs, isPoolDrop,
--    bidCount, myBid, myBalance }`.
--
-- `safe_str`/`safe_num` throughout for the reason documented above them: only the REQUEST is
-- HMAC-signed, so a malformed field must degrade to a readable line rather than throw a traceback.
function say.auction_line(index, row, now_ms)
  local parts = { '  ' .. tostring(index) .. ') ' .. safe_str(row.itemName, '(unknown item)') }
  parts[#parts + 1] = ' [' .. safe_str(row.tier, '?') .. ']'

  -- What this auction actually costs, in the currency the mode is bid in. A player who reads "min
  -- 100" on a percentage auction would bid the wrong thing, so each mode names its own terms.
  local mode = safe_str(row.mode, 'TIERED')
  if mode == 'PERCENTAGE' then
    parts[#parts + 1] = ' bid a %'
  elseif mode == 'ALL_IN' then
    parts[#parts + 1] = ' ALL-IN'
  elseif mode == 'FIXED' then
    parts[#parts + 1] = ' buy at ' .. tostring(safe_num(row.fixedPrice, 0))
  elseif safe_num(row.tierMinimum, 0) > 0 then
    parts[#parts + 1] = ' min ' .. tostring(safe_num(row.tierMinimum, 0))
  end

  if type(row.requiredJob) == 'string' and row.requiredJob ~= '' then
    parts[#parts + 1] = ' ' .. row.requiredJob .. ' only'
  end

  -- Clamped at zero: a row can arrive a second past its own end, and format_duration_short's
  -- contract is a non-negative duration.
  local remaining = math.max(0, math.floor((safe_num(row.endsAtMs, 0) - now_ms) / 1000))
  parts[#parts + 1] = ' - ' .. hud_lib.format_auction_countdown(remaining) .. ' left'

  -- Your OWN bid, never anyone else's: the sealed-auction rule holds in-game exactly as it does on
  -- the web. `bidCount` says how many bids exist, which the web list row already shows, and never
  -- what any of them are.
  if type(row.myBid) == 'table' then
    local offer
    if type(row.myBid.percent) == 'number' then
      offer = tostring(row.myBid.percent) .. '%'
    else
      offer = tostring(safe_num(row.myBid.amount, 0))
    end
    local lane = (safe_str(row.myBid.lane, 'MAIN') == 'LOW') and ', low' or ''
    parts[#parts + 1] = ' (you bid ' .. offer .. lane .. ')'
  end

  return table.concat(parts)
end

-- Renders the list AND returns the index->auction binding it just numbered, as one function, so the
-- numbers a player reads and the ids `bid` resolves can never disagree. Building the map separately
-- would let a skipped malformed row shift one and not the other.
function say.auctions_reply_lines(rows, now_ms)
  local list = {}
  if type(rows) ~= 'table' then
    return { 'auctions: could not read the server response.' }, list
  end

  local lines = { 'open auctions:' }
  for _, row in ipairs(rows) do
    if type(row) == 'table' and type(row.id) == 'string' then
      list[#list + 1] = { id = row.id, name = safe_str(row.itemName, '(unknown item)') }
      lines[#lines + 1] = say.auction_line(#list, row, now_ms)
    end
  end

  if #list == 0 then
    return { 'no auctions are open right now.' }, list
  end
  lines[#lines + 1] = 'bid with: //lootryx bid <number> <amount|N%> [low]'
  return lines, list
end

-- Parses `<number> <amount|N%> [low]`. Returns index, amount, percent, lane, err — amount and
-- percent are mutually exclusive, matching the server's own either/or (`ingestBidSchema`).
--
-- The `%` suffix is what distinguishes the two currencies, and it is REQUIRED rather than inferred
-- from the auction's mode, because 40 and 40% are wildly different offers and guessing which one a
-- player meant is not a mistake worth making with their DKP. The server refuses the mismatch too;
-- catching it here just means the refusal costs no round trip.
local function parse_bid_args(args)
  if #args < 2 then
    return nil, nil, nil, nil, 'usage: //lootryx bid <number> <amount|N%> [low]'
  end

  local index = tonumber(args[1])
  if not index or index < 1 or index ~= math.floor(index) then
    return nil, nil, nil, nil, 'the first argument is the NUMBER from //lootryx auctions, e.g. //lootryx bid 2 150'
  end

  -- The optional third word is the lane. Anything else there is a typo worth naming, not ignoring:
  -- silently dropping it would let "//lootryx bid 2 150 lwo" bid in the MAIN lane unannounced.
  local lane = 'MAIN'
  if args[3] then
    if string.lower(args[3]) == 'low' then
      lane = 'LOW'
    else
      return nil, nil, nil, nil, 'the only thing that goes after the amount is "low" (the low lane).'
    end
  end

  local percent_text = string.match(args[2], '^(%d+)%%$')
  if percent_text then
    local percent = tonumber(percent_text)
    if percent < 1 or percent > 100 then
      return nil, nil, nil, nil, 'a percentage bid is between 1% and 100%.'
    end
    return index, nil, percent, lane, nil
  end

  local amount = tonumber(args[2])
  if not amount or amount < 1 or amount ~= math.floor(amount) then
    return nil, nil, nil, nil, 'bid a whole number of DKP (150), or a share of your balance (40%).'
  end
  return index, amount, nil, lane, nil
end

-- Pure payload builder for /bid. `percent` and `amount` are never both present: ingestBidSchema
-- refines on exactly one of them, so sending both would be a 422 rather than a coin flip.
local function build_bid_request(auction_id, amount, percent, lane)
  local body = { auctionId = auction_id, lane = lane }
  if percent then
    body.percent = percent
  else
    body.amount = amount
  end
  return body
end

-- Pure reply formatting for a placed bid, from placeBid's own `{ bid, endsAt, extended }`. Echoes
-- the offer BACK rather than repeating what was typed, so a player sees what the server actually
-- recorded, which is the number that will settle the auction.
function say.bid_reply_message(item_name, decoded)
  local bid = type(decoded.bid) == 'table' and decoded.bid or {}
  local offer
  if type(bid.percent) == 'number' then
    offer = tostring(bid.percent) .. '% of your balance'
  else
    offer = tostring(safe_num(bid.amount, 0)) .. ' DKP'
  end
  local lane = (safe_str(bid.lane, 'MAIN') == 'LOW') and ' in the low lane' or ''
  local message = 'bid on ' .. item_name .. ': ' .. offer .. lane .. '.'
  if decoded.extended == true then
    message = message .. ' The window was extended.'
  end
  return message
end

-- Resolves a listing number against the last list the player was shown.
local function auction_at(index)
  if #last_auction_list == 0 then
    return nil, 'run //lootryx auctions first, then bid by its number.'
  end
  local entry = last_auction_list[index]
  if not entry then
    return nil, 'there is no auction ' .. tostring(index) .. ' in the list you were shown (1-' .. #last_auction_list .. ').'
  end
  return entry, nil
end

-- `//lootryx auctions`: what is open right now. Sends `auctions = true` on the SAME composite `/me`
-- route the read commands use, so this one request also carries the caller's balance; the other read
-- commands leave the flag off and are unchanged by this feature (listing auctions runs a write sweep
-- server-side, which a camping player's `//lootryx dkp` must not start paying for).
local function do_auctions(quiet)
  local body = json_encode({ auctions = true })
  local status, response = post(settings.api_base .. '/me', body)
  if status ~= 200 then
    if not quiet then log('auctions failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response)) end
    return false
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    if not quiet then log('auctions: could not parse the server response.') end
    return false
  end

  -- The overlay's own copy of what was just fetched. This assignment, and its siblings in do_dkp
  -- and do_windows, are the ONLY way state ever reaches the HUD: it has no fetch path of its own.
  record_denials(decoded)
  if denied('auctions') then
    if not quiet then log('Your role cannot read auctions. Ask an officer about Auction read access.') end
    hud_state.auctions = nil
    host.ui_tools.auction_results={};host.ui_tools.auction_followed={};last_auction_list={}
    return false
  end
  host.ui_tools.auction_results = type(decoded.auctionResults)=='table' and decoded.auctionResults or {}
  host.ui_tools.auction_seen = host.ui_tools.auction_seen or {}
  host.ui_tools.auction_followed = host.ui_tools.auction_followed or {}
  for _,a in ipairs(hud_state.auctions or {}) do host.ui_tools.auction_followed[a.id]=true end
  for _,a in ipairs(host.ui_tools.auction_results) do
    local result_key=tostring(a.id)..':'..tostring(a.closedAtMs or 'legacy')
    if host.ui_tools.auction_followed[a.id] and not host.ui_tools.auction_seen[result_key] then
      host.ui_tools.auction_seen[result_key]=true
      host.ui_tools.notify(a.itemName..': '..(a.won and 'You won.' or (a.winnerName and ('Won by '..a.winnerName..'.') or 'Closed without a winner.'))..(type(a.charge)=='number' and (' Charged '..a.charge..' DKP / '..safe_str(a.dkpPoolName,'wallet unavailable')..'.') or ''),settings.notify_auction_results~=false,log,{id='auctionweb:'..a.id,label='View result on website'})
    end
  end
  for _,a in ipairs(type(decoded.auctions)=='table' and decoded.auctions or {}) do
    if type(a.id)=='string' and not host.ui_tools.auction_followed[a.id] then
      host.ui_tools.auction_followed[a.id]=true
      host.ui_tools.notify(safe_str(a.itemName,'Auction')..': open for bidding. See Linkshell > Auctions.',settings.notify_new_auctions~=false,log,{id='auctionweb:'..a.id,label='View auction on website'})
    end
  end
  host.ui_tools.auction_checked=os.time()
  hud_state.auctions = decoded.auctions
  hud_state.dkp = decoded.dkp or hud_state.dkp
  window_refresh()
  local now_ms = os.time() * 1000
  local lines, list = say.auctions_reply_lines(decoded.auctions, now_ms)
  last_auction_list = list
  if not quiet then for _, line in ipairs(lines) do log(line) end end
  return true
end

-- Shared by `bid` and `allin`: both place a bid, and differ only in how the offer was chosen.
local function send_bid(entry, amount, percent, lane)
  local body = json_encode(build_bid_request(entry.id, amount, percent, lane))
  local status, response = post(settings.api_base .. '/bid', body)
  if status ~= 200 then
    -- The server's own words. Every bidding rule lives there, so paraphrasing a refusal here would
    -- be inventing a rule; "Bid is below the tier B minimum of 100." is already the right sentence.
    host.ui_tools.bid_error=ingest_errors.describe_failure(status,response)
    log('bid failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('bid: the bid may have been placed, but the response could not be read. Check //lootryx auctions.')
    return
  end
  log(say.bid_reply_message(entry.name, decoded))
  return true
end

-- `//lootryx bid <number> <amount|N%> [low]`.
local function do_bid(args)
  local index, amount, percent, lane, err = parse_bid_args(args)
  if err then
    log(err)
    return
  end
  local entry, lookup_err = auction_at(index)
  if lookup_err then
    log(lookup_err)
    return
  end
  send_bid(entry, amount, percent, lane)
end

-- `//lootryx allin <number>` gets its OWN verb and its OWN confirmation, rather than being
-- `//lootryx bid <n> 100%`, because it is the one bid that cannot be partially regretted: it offers
-- every point the member has. A confirmation word is cheap; spending an entire balance on a typo'd
-- number is not. The word IS the state, so there is no pending-confirmation variable to go stale or
-- to attach itself to the wrong auction after a re-list.
local function do_allin(args)
  local index = tonumber(args[1])
  if not index or index < 1 or index ~= math.floor(index) then
    log('usage: //lootryx allin <number>   (the number from //lootryx auctions)')
    return
  end
  local entry, lookup_err = auction_at(index)
  if lookup_err then
    log(lookup_err)
    return
  end

  if not (args[2] and string.lower(args[2]) == 'confirm') then
    log('ALL-IN on ' .. entry.name .. ' offers your ENTIRE balance in that wallet.')
    log('  to go through with it: //lootryx allin ' .. tostring(index) .. ' confirm')
    return
  end

  -- 100 is the whole point of the verb. On an ALL_IN auction the server normalises any percentage to
  -- 100 anyway; on an ordinary percentage auction this is a legitimate maximum bid.
  send_bid(entry, nil, 100, 'MAIN')
end

-- Splits `<item name> [long]`. The item name is multi-word far more often than not ("Piece of
-- Omega's Eye"), so the OPTIONAL trailing keyword is what gets recognised, and everything else is
-- the name. Default is a treasure-pool live drop, because that is what an officer typing this in
-- the middle of a pool almost always means; `long` opens an ordinary multi-hour window instead.
local function split_auction_args(args)
  if #args < 1 then
    return nil, nil
  end
  local words = {}
  for i = 1, #args do
    words[i] = args[i]
  end
  local pool_drop = true
  if #words > 1 and string.lower(words[#words]) == 'long' then
    pool_drop = false
    words[#words] = nil
  end
  return table.concat(words, ' '), pool_drop
end

-- `//lootryx auction <item name> [long]`: open an auction from in-game. OFFICER ONLY, enforced
-- server-side against the same `auction:run` permission the website's own button checks; this file
-- does not know the caller's role and deliberately does not guess at it.
--
-- The server REFUSES an item its catalog does not know, and says which item it thinks was meant.
-- That refusal is the feature, not an obstacle: a free-text auction opened on a typo charges a real
-- winner real DKP under a name no standing wishlist pre-bid can ever match.
--- Shared by `//lootryx auction` and the window's opener: both send the same request and differ
--- only in how the item name was chosen.
local function send_auction_open(item_name, pool_drop, selected, dkp_pool)
  if hud_state.you and type(hud_state.you.canRun)=='table' and hud_state.you.canRun.auctions==false then
    log('Your shell role cannot open auctions. Ask an officer with Run auctions permission.');return false
  end
  local entered
  if pool_drop and selected then
    if selected.invalid or selected.name ~= item_name then
      log('The pool selection changed. Read the pool and select the item again.')
      return false
    end
    local ok, pool = pcall(host.read_treasure)
    local current = ok and type(pool) == 'table' and pool[selected.slot]
    if type(current) ~= 'table' or current.item_id ~= selected.item_id or current.timestamp ~= selected.timestamp then
      log('The selected pool item changed or left. Read the pool and select it again.')
      return false
    end
    if type(selected.timestamp) == 'number' and selected.timestamp > 1000000000
      and selected.timestamp <= os.time() then entered=selected.timestamp*1000 end
    if not entered then
      log('Pool timing is unavailable. No auction opened; read the pool again or use a long auction for an item you already hold.')
      return false
    end
  end
  local body = json_encode({ itemName = item_name, poolDrop = pool_drop, poolEnteredAtMs=entered, poolId=dkp_pool })
  local status, response = post(settings.api_base .. '/auction', body)
  if status ~= 200 then
    log('auction failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return false
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' or type(decoded.auction) ~= 'table' then
    log('auction: could not parse the server response. Check the website before opening it again.')
    return false
  end

  local auction = decoded.auction
  local remaining = math.max(0, math.floor((safe_num(auction.endsAtMs, 0) - os.time() * 1000) / 1000))
  log('opened: ' .. safe_str(auction.itemName, item_name) .. ' - bidding closes in ' .. format_duration_short(remaining) .. '.')
  if decoded.reservedWarning == true then
    -- Advisory, exactly as on the web: reserved items are still auctionable. Swallowing this would
    -- hide the one warning an officer needs before selling a piece the shell marked not-sellable.
    log('  note: this item is marked RESERVED (not sellable) in the catalog.')
  end
  if type(auction.id)=='string' then
    host.ui_tools.auction_followed=host.ui_tools.auction_followed or {}
    if not host.ui_tools.auction_followed[auction.id] then
      host.ui_tools.auction_followed[auction.id]=true
      -- The opening confirmation above is the chat alert; retain it in the bell too.
      host.ui_tools.notify(safe_str(auction.itemName,item_name)..': open for bidding. See Linkshell > Auctions.',false,log)
    end
  end
  log('Members can bid in Linkshell > Auctions.')
  return true
end

local function do_auction_open(args)
  local item_name, pool_drop = split_auction_args(args)
  if not item_name or item_name == '' then
    log('usage: //lootryx auction <item name>        (a treasure-pool drop, bidding closes with the pool)')
    log('       //lootryx auction <item name> long   (an ordinary auction window instead)')
    return
  end
  send_auction_open(item_name, pool_drop)
end

-- ─────────────────────── HUD overlay (docs/prds/addon-ground-truth.md §5) ───────────────────────
-- ADDON-GT-3. The addon has only ever spoken through the chat log, which scrolls away exactly when
-- something matters: a pool auction closing, an HNM window opening. One small overlay fixes that.
--
-- IT ISSUES NO NETWORK CALL, EVER. `hud_state` below is written only by the command handlers that
-- already fetched something, and the render tick only ever formats what is already in it. There is
-- no timer that fetches, no refresh, no polling. That is a compliance property as much as a
-- performance one, and it is structural: lib/hud.lua has no transport to call even if it wanted one
-- (see its file header), and nothing in this section calls `post`.
--
-- The renderer here is Windower-specific (text objects). Everything that decides WHAT to say lives
-- in lib/hud.lua, which knows nothing about either loader, so an Ashita build replaces this half
-- alone (the split docs/Hoard_Project_Brief_v1.3.md § "Addon" calls for).

-- The Windower text object, created on first draw. nil until then, so an addon loaded with the HUD
-- off never creates one at all.
local hud_box = nil

-- Applies the persisted position and styling to the text object. Split out because it is needed
-- both on creation and after `//lootryx hud pos`.
local function hud_apply_position()
  if not hud_box then
    return
  end
  hud_box:pos(settings.hud_x, settings.hud_y)
end

local function hud_ensure_box()
  if hud_box then
    return hud_box
  end
  hud_box = texts.new('', {
    flags = { draggable = true, bold = true },
    text = {
      font = 'Consolas',
      size = 10,
      alpha = 255,
      red = 255,
      green = 255,
      blue = 255,
      -- A 1px black outline, which is the standard trick across Windower addons (equipviewer and
      -- friends all do exactly this) and the right answer to "will this read over a bright zone".
      -- It beats darkening the box: an outline makes the GLYPHS legible against anything, where a
      -- heavier background just makes a bigger black rectangle sit on the player's screen. Because
      -- of it the background below can go back to being unobtrusive.
      stroke = { width = 1, alpha = 190, red = 0, green = 0, blue = 0 },
    },
    -- 190, not 160. Contrast was computed by compositing each mode colour over a bright outdoor
    -- scene (~200/255, which is Sky, Xarcabard snow and Valley of Sorrows sand, i.e. exactly where
    -- this overlay gets used) in GAMMA-ENCODED sRGB, per CLAUDE.md hard rule 9. At alpha 160 the
    -- alert red came out at 3.1:1, under the 4.5 threshold, and it is the one colour that most
    -- needs to be readable. No red fixes that, because red is inherently low luminance and any red
    -- that reaches 4.5 there is salmon pink. Darkening the box lifts alert to 4.5 and everything
    -- else above 7, which costs a slightly darker rectangle and keeps all four hues distinct.
    -- Back down to 150 now that the text carries its own outline. The box should suggest a panel,
    -- not block out the game behind it; legibility is the stroke's job, not the background's.
    bg = { alpha = 150, red = 0, green = 0, blue = 0 },
    padding = 4,
  })
  hud_apply_position()
  return hud_box
end

--[[
  Urgency as COLOUR, not just as a word.

  `build_lines` has always returned a mode "so a renderer can tint the header", and this renderer
  never did: it appended the mode as text and drew everything in the same white. A closing bid
  window and an idle balance therefore looked identical at a glance, which defeats the point of an
  overlay -- the whole reason to put something on screen rather than in the chat log is that it can
  be read without being read.

  Values are the Lootryx palette's intent in the only form a Windower text object takes: red for
  "this is broken", the product's gold for a deadline, a cool blue for a window that is open but not
  urgent, and a near-white resting state that does not compete with the game behind it.
]]
--[[
  Refreshes the parts of `hud_state` the overlay cannot be told about by a command reply, because
  they are facts about the ADDON rather than answers from the server: is a roster correction live,
  are captures waiting, did the last report land, are we still on demo credentials.

  Called once per frame, immediately before the render. That is safe and deliberate: every line
  below is a read of a Lua table already in memory. There is no request here, no game read and no
  file access, so the overlay's "it cannot fetch" property is untouched -- `lib/hud.lua` still
  receives a table and returns strings, and still has no way to obtain anything itself.

  Doing it per frame rather than at each mutation site is the smaller and safer choice: half of
  these change in several places (a capture is queued in `do_snap` and drained in
  `do_drain_queued`), and a state that must be poked from every one of those sites is a state that
  will eventually be missed at one of them and quietly show a stale number.
]]
local function hud_refresh_operational_state()
  queue_lib.prune(snapshot_queue, os.time())
  hud_state.queue = {
    pending = queue_lib.size(snapshot_queue),
    dropped = snapshot_queue.dropped_expired + snapshot_queue.dropped_overflow,
  }
  hud_state.roster = { added = #roster_adjustment.added, removed = #roster_adjustment.removed }
  hud_state.ingest = { ok = last_ingest.ok, status = last_ingest.status }
  -- The single most useful thing to tell someone who just installed this and has not yet pasted a
  -- key: every report they make is going nowhere.
  -- The site comes from api_base, so the overlay names the shell's OWN deployment rather than a
  -- hardcoded lootryx.com that would be wrong for anyone self-hosting or testing locally.
  hud_state.config = { dev = is_unconfigured(), site = site_url():gsub('^https?://', '') }
end

-- The two codes the renderer itself needs. Everything else lives in lib/hud.lua's palette; these
-- are here because the header is assembled by this half, not by the content builder.
local HUD_DIM = '\\cs(150,145,135)'
local HUD_RESET = '\\cr'

local HUD_MODE_COLORS = {
  alert = { 255, 105, 97 },
  -- Green, and deliberately not the auction gold: an open check-in is the one deadline you lose by
  -- standing still, and it should not read as "another thing closing soon".
  checkin = { 130, 230, 150 },
  auction = { 255, 200, 90 },
  watch = { 130, 200, 255 },
  event = { 225, 225, 225 },
}

-- Guarded the same way `destroy` is on unload, and for the same reason: this addon has never run
-- against a real client, so a wrong guess about the texts API must degrade to "the overlay is not
-- tinted" rather than to a Lua error inside the render loop.
local function hud_apply_mode_color(box, mode)
  local rgb = HUD_MODE_COLORS[mode or 'event'] or HUD_MODE_COLORS.event
  if type(box.color) == 'function' then
    box:color(rgb[1], rgb[2], rgb[3])
  end
end

-- ONE render tick. Formats `hud_state` and nothing else: no fetch, no game read, no file access.
-- Cheap enough to run every frame, because build_lines is pure string work over at most a handful
-- of rows and the text object is only rewritten when the text actually changed.
local hud_last_text = nil
local hud_last_mode = nil
local function hud_render()
  if panel_lib.visible() then
    if hud_box then
      hud_box:hide()
    end
    hud_last_text = nil
    return
  end
  if not settings.hud_enabled then
    if hud_box then
      hud_box:hide()
    end
    return
  end

  local lines, mode, width = hud_lib.build_lines(hud_state, os.time() * 1000)
  if #lines == 0 then
    -- "Draws nothing when there is nothing to say" (PRD §5): an empty frame is worse than no frame.
    if hud_box then
      hud_box:hide()
    end
    hud_last_text = nil
    return
  end

  -- The header is IDENTITY, and it should be the quietest line in the box.
  --
  -- `LOOTRYX` in bold caps was the widest, loudest thing on screen in every state, so the eye landed
  -- on the product name instead of on the item and the clock. In a one-colour, one-weight box the
  -- only hierarchy tools are position, width, caps and whitespace, so spending caps on the brand
  -- was spending the scarcest one on the least useful thing. `Lootryx` carries the same identity
  -- (players run several overlays at once) with far less ink.
  --
  -- The mode tag is RIGHT ALIGNED against the same width the countdown uses, which turns this into
  -- a title bar with a tag rather than a shouted phrase, and gives the box one right column. The tag
  -- is also the colourblind fallback for the mode, which is why it stays capitalised.
  -- The wordmark sits BACK. It is identity, not information: it says which overlay this is and
  -- gives the box something to drag by, and it should lose every contest with the line under it.
  -- The mode tag keeps the box's own colour, so the one word worth reading in the header is the
  -- one that says how urgent this is.
  local header = HUD_DIM .. 'Lootryx' .. HUD_RESET
  if mode and mode ~= 'event' then
    local tag = string.upper(mode)
    -- Measured on the visible text: `header` now carries colour markup, and counting it would
    -- shove the tag off the right edge.
    local plain = hud_lib.plain(header)
    local gap = (width or #plain) - #plain - #tag
    if gap < 2 then
      gap = 2
    end
    header = header .. string.rep(' ', gap) .. tag
  end
  local text = header .. '\n' .. table.concat(lines, '\n')

  local box = hud_ensure_box()
  if text ~= hud_last_text then
    box:text(text)
    hud_last_text = text
  end
  -- Recoloured only on a MODE change, not every frame, for the same reason the text is only
  -- rewritten when it differs: this runs sixty times a second and the overlay is idle in almost
  -- all of them.
  if mode ~= hud_last_mode then
    hud_apply_mode_color(box, mode)
    hud_last_mode = mode
  end
  box:show()
end

-- `//lootryx hud [on|off|pos <x> <y>]`. Local only: nothing here touches the network.
local function do_hud(args)
  local sub = args[1] and string.lower(args[1]) or nil

  if sub == 'on' or sub == 'off' then
    settings.hud_enabled = (sub == 'on')
    save_settings()
    log('hud ' .. sub .. '.')
    if sub == 'on' and next(hud_state) == nil then
      -- Being told the overlay is on while it draws nothing would read as broken, so say why.
      log('  nothing to show yet: run //lootryx auctions, //lootryx windows or //lootryx dkp.')
    end
    return
  end

  if sub == 'pos' then
    local x, y = tonumber(args[2]), tonumber(args[3])
    if not x or not y then
      log('usage: //lootryx hud pos <x> <y>   (or just drag it)')
      return
    end
    settings.hud_x, settings.hud_y = math.floor(x), math.floor(y)
    save_settings()
    hud_apply_position()
    log('hud moved to ' .. tostring(settings.hud_x) .. ', ' .. tostring(settings.hud_y) .. '.')
    return
  end

  if sub == nil then
    log('hud is ' .. (settings.hud_enabled and 'on' or 'off') .. ' at ' .. tostring(settings.hud_x) .. ', ' .. tostring(settings.hud_y) .. '.')
    log('  //lootryx hud on|off        show or hide the overlay')
    log('  //lootryx hud pos <x> <y>   move it (it is also draggable)')
    return
  end

  log('unknown hud option "' .. tostring(args[1]) .. '". Try //lootryx hud on|off|pos <x> <y>.')
end

-- ─────────────────────── Party Finder (world-wide LFG) ───────────────────────
-- All three POST to /party-finder/* over the SAME HMAC transport. The server derives the
-- world from this key's shell region and the host from the key's member. READS + POSTS only ·
-- the addon never touches the game. Verified server-side by addon/mock-party-finder.mjs.

-- Pure renderer for ONE Party Finder listing row: `{ id, host, mode, role, category,
-- voiceChatRequirement, comment, members, maxSize, status }`, the exact shape
-- `POST /party-finder/list` returns (apps/api/src/modules/ingest/handlers.ts). Uses the same
-- A23-27 safe-coercion discipline as say.dkp_reply_lines/say.hnm_window_line above: the response carries
-- no HMAC of its own (only the request is signed, invariant 8), so a malformed field degrades to a
-- placeholder instead of throwing on concat. `id` is printed in full (a cuid, not shortened):
-- `//lootryx pf join <id>` needs the exact string back, and a truncated id would silently fail to
-- match.
function say.pf_listing_line(listing)
  --[[
    The host name is a LABEL when `hostVerified` is false, and it has to LOOK like one.

    A world-scoped key is mintable by anyone at `/pair/world` with any character name, and nothing on
    an unauthenticated route can prove who controls a character. The server has always sent
    `hostVerified` for exactly this reason; this renderer ignored it, so pairing as a well-known
    player and posting a listing put their name on the board with nothing to distinguish it. The
    README makes the claim that boards mark these, so this is also that claim being made true.

    Absent or non-boolean degrades to UNVERIFIED, the same safe-coercion discipline as every other
    field here: the response carries no signature of its own, so the cautious reading is the right
    default rather than the trusting one.
  ]]
  local unverified = (listing.hostVerified ~= true) and ' (unverified)' or ''
  local host = safe_str(listing.host, '(unknown)') .. unverified
  local mode = safe_str(listing.mode, '?')
  local category = safe_str(listing.category, '?')
  local role = safe_str(listing.role, '?')
  local size = '(' .. safe_num(listing.members, 0) .. '/' .. safe_num(listing.maxSize, 0) .. ')'
  local full_suffix = (listing.status == 'FULL') and ' [FULL]' or ''
  local comment = (type(listing.comment) == 'string' and listing.comment ~= '') and (' - ' .. listing.comment) or ''
  local id = safe_str(listing.id, '?')
  return '  ' .. host .. ' ' .. mode .. ' ' .. category .. '/' .. role .. ' ' .. size .. full_suffix .. comment .. '  id:' .. id
end

-- Pure renderer for the whole /party-finder/list response: `{ world, listings: [...] }`.
-- R12-ADDON (2026-08-02): replaces a prior version that dumped the raw JSON response straight to
-- chat (`log('party finder: ' .. tostring(response))`), unreadable in an FFXI chat window and, for
-- a full 20-listing response, long enough to run past the client's per-line display limit. Renders
-- one line per listing instead, matching the same human-readable-line discipline dkp/standings/
-- windows already use above.
function say.pf_list_reply_lines(reply)
  local listings = type(reply.listings) == 'table' and reply.listings or {}
  local world = safe_str(reply.world, 'your world')
  if #listings == 0 then
    return { 'party finder: no open listings on ' .. world .. '.' }
  end
  local lines = { 'party finder (' .. world .. '), ' .. #listings .. ' open:' }
  for _, listing in ipairs(listings) do
    if type(listing) == 'table' then
      lines[#lines + 1] = say.pf_listing_line(listing)
    end
  end
  return lines
end

--[[
  Pure renderer for `GET /api/public/linkshells`. Shows the one fact that changes what a reader
  does next: `joinPolicy` OPEN means join, REQUEST means apply and wait, CLOSED means neither.
  A shell that is listed but not recruiting still appears, dimmer, because a full linkshell today
  may not be one next month.
]]
function say.shells_reply_lines(decoded, world)
  local lines = {}
  local shells = type(decoded) == 'table' and decoded.linkshells or nil
  if type(shells) ~= 'table' or #shells == 0 then
    lines[#lines + 1] = 'no linkshells are listed on ' .. tostring(world) .. ' yet.'
    lines[#lines + 1] = '  browse every world, or start your own: ' .. site_url() .. '/ls'
    return lines
  end
  lines[#lines + 1] = #shells .. ' linkshell' .. (#shells == 1 and '' or 's') .. ' on ' .. tostring(world) .. ':'
  for _, shell in ipairs(shells) do
    local name = tostring(shell.name or '?')
    local members = tostring(shell.members or 0)
    local policy = tostring(shell.joinPolicy or 'REQUEST')
    local badge = shell.recruiting and ' RECRUITING' or ''
    lines[#lines + 1] = '  ' .. name .. '  ' .. members .. ' members  ' .. policy .. badge
    if type(shell.blurb) == 'string' and shell.blurb ~= '' then
      lines[#lines + 1] = '      ' .. shell.blurb
    end
    if type(shell.slug) == 'string' and shell.slug ~= '' then
      -- /ls/, not /shells/. The directory is browsable with no account at all, so the address it
      -- prints has to be the genuinely public recruiting page; /shells/<slug> is the member view and
      -- bounces a signed-out reader to a login screen, which defeats the point of the listing.
      lines[#lines + 1] = '      ' .. site_url() .. '/ls/' .. shell.slug
    end
  end
  lines[#lines + 1] = '  every world, and how to start one: ' .. site_url() .. '/ls'
  return lines
end

-- //lootryx shells : the recruiting directory, readable with no account and no linkshell.
local function do_shells()
  local status, response = get_public('/linkshells?region=' .. url_escape(settings.world))
  if status ~= 200 then
    log('could not read the linkshell directory [' .. tostring(status) .. '].')
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('linkshells: could not parse the server response.')
    return
  end
  for _, line in ipairs(say.shells_reply_lines(decoded, settings.world)) do
    log(line)
  end
  hud_state.shells = type(decoded.linkshells) == 'table' and decoded.linkshells or {}
  window_refresh()
end

local function do_pf_list()
  -- Being unconfigured is NOT an error here, unlike every other command. The board is public, so a
  -- fresh install with no key still reads it; only posting and joining need credentials. A signed
  -- read is still preferred when we have a key, because the server then derives the world from the
  -- shell rather than trusting a local setting.
  local status, response
  if is_unconfigured() then
    status, response = get_public('/party-finder?world=' .. url_escape(settings.world))
  else
    status, response = post(settings.api_base .. '/party-finder/list', json_encode({}))
  end
  if status ~= 200 then
    log('pf list failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return
  end
  local parse_ok, decoded = pcall(json.decode, response)
  if not parse_ok or type(decoded) ~= 'table' then
    log('pf list: could not parse the server response.')
    return
  end
  for _, line in ipairs(say.pf_list_reply_lines(decoded)) do
    log(line)
  end
  -- Cached for the window, which draws from what has already been fetched rather than asking again.
  local listings = type(decoded.listings) == 'table' and decoded.listings or {}
  local lfg, lfm = 0, 0
  for _, listing in ipairs(listings) do
    if listing.mode == 'LFG' then
      lfg = lfg + 1
    else
      lfm = lfm + 1
    end
  end
  hud_state.pf = { listings = listings, lfg = lfg, lfm = lfm, roleSlotsSupported=decoded.roleSlotsSupported==true }
  window_refresh()
end

-- Pure renderer for a successful /party-finder/post response's `listing` block (`{ id }`,
-- apps/api/src/modules/ingest/handlers.ts's `ctx.json({ ok: true, listing: { id } }, 201)`). The
-- id is surfaced so the poster can hand it to someone, or use it themselves later; everything else
-- about the listing is already what the player just typed.
function say.pf_post_reply_message(decoded)
  local listing = type(decoded) == 'table' and decoded.listing or nil
  if type(listing) == 'table' and type(listing.id) == 'string' then
    return 'listing posted (id ' .. listing.id .. ').'
  end
  return 'listing posted.'
end

-- The valid values, mirroring packages/validators' partyCategorySchema and partyRoleSchema. They
-- are here so the window can offer them rather than making somebody guess and read a 400 back.
local PF_CATEGORIES = { 'EXP', 'MISSION', 'BCNM', 'MENTOR', 'CRAFT', 'OTHER' }
local PF_ROLES = { 'ANY', 'TANK', 'HEALER', 'SUPPORT', 'DPS' }

--[[
  Whether a role means anything for this kind of listing.

  It does not for crafting. Nobody is a tank at Goldsmithing: what a crafting listing needs to say
  is which craft and what skill level, and that is what the comment is for. Asking for a role there
  is a field that cannot be answered, and a listing that answers it anyway is misleading.
]]
local function category_uses_role(category)
  return category ~= 'CRAFT'
end

--- Shared by `//lootryx pf post` and the window's composer: both assemble the same request, and
--- differ only in how the player chose the values.
local function send_pf_post(mode, category, role, comment, slots)
  local body = json_encode({
    mode = mode or 'LFM',
    category = category or 'EXP',
    role = role or 'ANY',
    comment = comment or '',
    maxSize = slots and slots.maxSize or nil,
    roleSlots = slots and slots.roleSlots or nil,
  })
  local status, response = post(settings.api_base .. '/party-finder/post', body)
  if status ~= 201 then
    host.ui_tools.post_error=ingest_errors.describe_failure(status,response)
    log('pf post failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
    return false
  end
  -- A 201 already means the post succeeded server-side; a parse failure here only costs the id in
  -- the confirmation line, never the success confirmation itself (same discipline as do_link).
  local parse_ok, decoded = pcall(json.decode, response)
  log(say.pf_post_reply_message(parse_ok and decoded or nil))
  return true
end

-- //lootryx pf post <CATEGORY> <ROLE> [comment...]  e.g. //lootryx pf post EXP HEALER Colibri camp
local function do_pf_post(args)
  send_pf_post('LFM', (args[2] or 'EXP'):upper(), (args[3] or 'ANY'):upper(), table.concat(args, ' ', 4))
end

-- //lootryx pf join <listingId> [ROLE]
local function do_pf_join(args)
  local id = args[2]
  if not id or id == '' then
    log('usage: //lootryx pf join <listingId> [role]')
    return
  end
  local role = (args[3] or 'ANY'):upper()
  local status, response = post(settings.api_base .. '/party-finder/join', json_encode({ listingId = id, role = role }))
  if status == 200 then
    -- What actually happened, because "joined" overstates it. The addon cannot invite anyone: it
    -- never sends anything to the game server (README section 1). Joining puts you on the
    -- listing's roster, and the host invites you in game the ordinary way.
    log('you are on that party\'s roster. The host still has to invite you in game.')
  else
    log('pf join failed [' .. tostring(status) .. ']: ' .. ingest_errors.describe_failure(status, response))
  end
end

local function do_pf(args)
  local sub = (args[1] or 'list'):lower()
  if sub == 'list' then
    do_pf_list()
  elseif sub == 'post' then
    do_pf_post(args)
  elseif sub == 'join' then
    do_pf_join(args)
  else
    log('usage: //lootryx pf list | pf post <CATEGORY> <ROLE> [comment] | pf join <id> [role]')
  end
end

-- Read-only status/diagnostics: prints the addon's own local config + the outcome of
-- the LAST ingest attempt (populated by post() above). No network call, no game action,
-- just a report of state already in memory. Never prints the secret.
local function do_status()
  log('status:')
  log('  version      ' .. _addon.version .. '  (see addon/README.md §8 for what changed at this version)')
  log('  shell        ' .. shell_label())
  log('  api_base     ' .. settings.api_base)
  log('  key_id       ' .. mask_key(settings.key_id))
  log('  auto         ' .. (settings.auto and ('ON, every ' .. settings.interval .. 's') or 'OFF'))
  log('  heartbeat    ' .. (settings.heartbeat and ('ON, every ' .. settings.heartbeat_interval .. 's (reports your zone)') or 'OFF'))
  -- Surfaced even when everything else looks healthy: a buffer that quietly holds or discards
  -- captures is worse than no buffer, because it removes the symptom that would prompt a question.
  local waiting = queue_lib.status_line(snapshot_queue, os.time())
  if waiting then
    log('  retry queue  ' .. waiting)
  end
  -- Printed here as well as on every capture. `status` is where someone looks when DKP came out
  -- wrong, and "an officer set a roster correction and forgot" is exactly that kind of answer.
  local correction = roster_lib.describe(roster_adjustment)
  if correction then
    log('  roster       ' .. correction)
  end
  if not last_ingest.at then
    log('  last ingest  none yet this session (try //lootryx snap)')
  elseif last_ingest.ok then
    log(
      '  last ingest  OK, '
        .. format_ago(last_ingest.at)
        .. ' ('
        .. tostring(last_ingest.endpoint)
        .. ', HTTP '
        .. tostring(last_ingest.status)
        .. ')'
    )
  else
    log('  last ingest  FAILED, ' .. format_ago(last_ingest.at) .. ' (' .. tostring(last_ingest.endpoint) .. ')')
    log('  last error   ' .. tostring(last_ingest.error))
  end
end

--[[
  `//lootryx selftest` : every check the addon can make without the network, in one command.

  README section 6 is a page of things only confirmable inside a real client, and most of it has
  never been ticked because ticking it meant working through prose one command at a time. This
  turns that into one command whose output is pasteable.

  It matters more than a convenience because packages/addon-harness runs this code under LuaJIT
  while Windower runs stock Lua 5.1: different implementations, different number and string
  handling, and a hand-vendored pure-Lua SHA-256 sitting on top of both. "The signature is right
  under LuaJIT" is not the same claim as "the signature is right in the client", and the known
  answer tests below are the first thing that has ever checked the second one where it matters.

  READS AND LOCAL COMPUTATION ONLY. No request, no file write, no game action. Running a diagnostic
  must never be the thing that changes something, and the compliance suite holds this to it.
]]
local function do_selftest()
  local checks = {}
  local function check(name, fn)
    checks[#checks + 1] = { name = name, fn = fn }
  end

  check('addon build', function()
    return true, 'v' .. tostring(_addon.version)
  end)

  check('character read', function()
    local player = client_reader.player()
    if not player or not player.name then
      return false, 'get_player() gave no name. Are you logged in to a character?'
    end
    return true, player.name
  end)

  check('alliance read', function()
    local names = collect_alliance()
    if #names == 0 then
      return selftest_lib.WARN, 'nobody read. Normal if you are solo; re-run in a party to check it.'
    end
    return true, tostring(#names) .. ' member(s): ' .. table.concat(names, ', ')
  end)

  -- Exercise the same identity-matched party read used by heartbeat, without sending it.
  check('own zone read', function()
    local zone = own_zone_id()
    if zone then
      return true, 'zone ' .. tostring(zone) .. ' from your character-matched party row'
    end
    return selftest_lib.WARN,
      'location unavailable. Re-run after zoning finishes; heartbeat omits zone until it is available.'
  end)

  check('settings loaded', function()
    if not settings.shell_slug or settings.shell_slug == '' then
      return false, 'no shell_slug in data/settings.xml'
    end
    if settings.key_id == DEMO_KEY_ID or settings.secret == DEMO_SECRET then
      return selftest_lib.WARN, 'still on the built-in dev credentials. Paste your own into data/settings.xml.'
    end
    return true, settings.shell_slug .. ' via ' .. settings.api_base
  end)

  -- The two that justify the whole command. Known-answer vectors, so a Lua 5.1 that computes
  -- SHA-256 differently from the LuaJIT the tests run under is caught HERE rather than by every
  -- request being silently rejected as a bad signature.
  check('sha-256 known answer', function()
    local got = sha2.sha256('abc')
    local want = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    if got ~= want then
      return false, 'wrong digest for "abc": got ' .. tostring(got)
    end
    return true, 'correct'
  end)

  check('hmac-sha256 known answer', function()
    local got = sha2.hmac_sha256('key', 'The quick brown fox jumps over the lazy dog')
    local want = 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8'
    if got ~= want then
      return false, 'wrong HMAC: got ' .. tostring(got)
    end
    return true, 'correct'
  end)

  check('request signing', function()
    local signature = sign('1700000000', 'abc123', '{"hello":"world"}')
    if type(signature) ~= 'string' or not signature:match('^[0-9a-f][0-9a-f]*$') or #signature ~= 64 then
      return false, 'sign() did not produce 64 hex characters: ' .. tostring(signature)
    end
    return true, '64 hex characters'
  end)

  check('json encode', function()
    -- The empty table is the case that actually broke: Lua cannot tell `{}` from `[]`, and an
    -- encoder that guessed wrong silently broke four shipped commands.
    local empty = json_encode({})
    if empty ~= '{}' then
      return false, 'an empty table encoded as ' .. tostring(empty) .. ', expected {}'
    end
    local body = json_encode({ shell = 'a', characters = { 'One', 'Two' } })
    if not body:match('"characters"%s*:%s*%[') then
      return false, 'a list did not encode as a JSON array: ' .. tostring(body)
    end
    -- An EXPLICIT null, which is a different instruction from an omitted field: omitted means
    -- "leave this alone" and null means "clear it". A Lua table cannot hold nil, so this rides a
    -- sentinel, and a sentinel that stopped encoding as null would silently turn every "clear my
    -- second job" into "keep my second job" with nothing to see.
    local cleared = json_encode({ second = JSON_NULL })
    if not cleared:match('"second"%s*:%s*null') then
      return false, 'an explicit null encoded as ' .. tostring(cleared)
    end
    return true, 'objects, arrays, nulls and the empty case'
  end)

  --[[
    The item catalog the drop composer, the wishlist and the lookup screen all pick from.

    Windower-only, and the one dependency the harness genuinely cannot exercise: `resources` does
    not exist outside a client, so every test run stubs it. A failure here is invisible rather than
    loud, because the pickers degrade to no suggestions, which looks exactly like an item nobody has
    heard of. Worth a check precisely because nothing else can catch it.
  ]]
  check('item catalog', function()
    local names = item_names()
    if type(names) ~= 'table' or #names == 0 then
      return selftest_lib.WARN, "Windower's resources gave no item names. The pickers will suggest nothing; " ..
        'typing a full name still works.'
    end
    return true, tostring(#names) .. ' item names'
  end)

  check('json decode', function()
    local decoded = json.decode('{"ok":true,"n":2,"rows":[{"name":"One"}]}')
    if type(decoded) ~= 'table' or decoded.ok ~= true or decoded.n ~= 2 then
      return false, 'did not decode a simple object'
    end
    if type(decoded.rows) ~= 'table' or decoded.rows[1].name ~= 'One' then
      return false, 'did not decode a nested array'
    end
    return true, 'objects, nesting and arrays'
  end)

  check('timestamp format', function()
    local stamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
    if not tostring(stamp):match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then
      return false, 'capturedAt would be malformed: ' .. tostring(stamp)
    end
    return true, tostring(stamp) .. ' (UTC)'
  end)

  check('https transport', function()
    if not (settings.api_base or ''):match('^https://') then
      return selftest_lib.WARN, 'api_base is not https. Fine for local testing, not for live use.'
    end
    if not https_ok then
      return false, 'api_base is https but LuaSec is missing, so every request will fail.'
    end
    return true, 'luasec present'
  end)

  check('overlay', function()
    -- Create, write, hide and release a throwaway box. This is the only check that allocates
    -- anything, so it also cleans up after itself: a diagnostic that leaves a box on screen would
    -- be reporting a problem it caused.
    local box = texts.new('', { flags = { draggable = false }, text = { font = 'Consolas', size = 10 } })
    if not box then
      return false, 'the texts library did not return an object'
    end
    box:text('lootryx selftest')
    box:hide()
    if type(box.destroy) == 'function' then
      box:destroy()
      return true, 'created, drawn, hidden and destroyed'
    end
    return selftest_lib.WARN, 'created and hidden, but this build of texts has no destroy()'
  end)

  check('overlay content builder', function()
    local lines = hud_lib.build_lines({ event = { alliance = 6, auto = true, snapOk = true } }, 1700000000000)
    if type(lines) ~= 'table' or #lines == 0 then
      return false, 'built no lines from a populated state'
    end
    return true, tostring(#lines) .. ' line(s) from a sample state'
  end)

  check('retry buffer', function()
    local probe = queue_lib.new({ max_age_seconds = 60 })
    queue_lib.push(probe, 'http://example.invalid/snapshot', '{}', 1000)
    if queue_lib.size(probe) ~= 1 then
      return false, 'a capture did not go into the buffer'
    end
    if queue_lib.take(probe, 5000) ~= nil then
      return false, 'an expired capture was handed back, which would credit the wrong event'
    end
    return true, 'holds, expires and refuses stale captures'
  end)

  check('roster correction', function()
    local probe = roster_lib.new()
    roster_lib.parse_into(probe, { '+Selftest', '-Removeme' })
    local names = roster_lib.apply({ 'Keepme', 'Removeme' }, probe)
    if #names ~= 2 or names[1] ~= 'Keepme' or names[2] ~= 'Selftest' then
      return false, 'applied incorrectly: ' .. table.concat(names, ', ')
    end
    return true, 'adds and excludes correctly'
  end)

  check('macro folder', function()
    local dir = macros_lib.resolve_macro_dir(settings.macro_dir)
    if not dir then
      return selftest_lib.WARN, 'not resolved. Only needed for //lootryx macros; set macro_dir in settings.xml.'
    end
    return true, dir
  end)

  local lines, summary = selftest_lib.run(checks)
  log('selftest (no network, no game action, nothing written):')
  for _, line in ipairs(lines) do
    log('  ' .. line)
  end
  log('  ' .. selftest_lib.summary_line(summary))
end

--[[
  `//lootryx help`, in two sizes.

  It grew to forty-five lines under one heading, ordered by the date each command was added rather
  than by anything a player wants. FFXI's chat log shows a fraction of that at once, so running help
  meant watching the useful half scroll past.

  The short form leads with the WINDOW, because most of this is clickable now and a list of typed
  commands undersells that; then the handful still worth typing. `help all` prints everything,
  grouped by what you are trying to do. Every command still appears in a `//lootryx <name>` line,
  which is what the discoverability guard in compliance.test.ts requires.
]]
local HELP_GROUPS = {
  {
    'Getting set up',
    {
      '  //lootryx setup <code>   ONE command: fetch your key and link this character',
      '  //lootryx key <id> <secret>  the manual alternative, if you prefer',
      '  //lootryx link <code>   verify your character with a site link code',
      '  //lootryx setup world   no linkshell, no account: party finder only',
      '  //lootryx claim   get a code to keep this character on your lootryx.com account',
    },
  },
  {
    'Attendance',
    {
      '  //lootryx snap          post an alliance attendance snapshot now',
      '  //lootryx show          print the alliance read (no network)',
      '  //lootryx auto on|off   toggle auto snapshots',
      '  //lootryx roster +A,B -C   count people the 18-slot alliance cannot show (or `clear`)',
      '  //lootryx tod <target name>   report a Time of Death you just witnessed (you get the credit)',
    },
  },
  {
    'Loot and DKP',
    {
      '  //lootryx drop <item> <winner>  report a drop you saw awarded (winner is the LAST word)',
      '  //lootryx auctions             what is open for bidding right now',
      '  //lootryx bid <n> <amount|N%>  bid on auction <n> (add "low" for the low lane)',
      '  //lootryx allin <n>            offer your whole balance on auction <n> (asks you to confirm)',
      '  //lootryx auction <item>       OFFICER: open an auction on a pool drop',
      '  //lootryx dkp                 your own DKP balance (every wallet, never summed)',
      '  //lootryx standings [pool]    top 10 by current balance',
      '  //lootryx wish [add|remove] <item>   your loot wishlist (no argument lists it)',
      '  //lootryx wishlist            the same thing, spelled out',
      '  //lootryx wish max <amount|off> <item>   your standing sealed pre-bid on it',
      '  //lootryx item <name>         what it is, and what your shell values it at',
    },
  },
  {
    'Your linkshell',
    {
      '  //lootryx events              what is scheduled, and whether a check-in is open',
      '  //lootryx signup <n> <going|late|maybe|out>   answer event n, as the job you are on',
      '  //lootryx windows             tracked HNM targets, next window + a countdown',
      '  //lootryx bounties            what the shell is paying DKP to have brought in',
      '  //lootryx loot                the most recent drops and where they went',
      '  //lootryx bank                what the shell is holding, and what of it is sellable',
      '  //lootryx polls               what the shell is deciding, and how the vote stands',
      '  //lootryx poll                the same list, singular',
      '  //lootryx vote <poll> <choice>   answer one; the same choice again takes it back',
      '  //lootryx myjobs [job|here|-] [2nd] [3rd]   your ranked jobs; "here" = the job you are on',
      '  //lootryx jobs                the same thing, shorter',
    },
  },
  {
    'Finding people',
    {
      '  //lootryx shells       linkshells recruiting on your world (no account needed)',
      '  //lootryx pf list       open Party Finder listings on your world (no account needed)',
      '  //lootryx pf post <CAT> <ROLE> [comment]   post a listing',
      '  //lootryx pf join <id> [role]              join a listing',
      '  //lootryx statics             who is recruiting a static, and who is looking',
      '  //lootryx seekers             the same board, from the other side',
      '  //lootryx unseek              take yourself off the seeker board',
    },
  },
  {
    'The window and the overlay',
    {
      '  //lootryx window      tabs, boards, and most of this list as buttons',
      "  //lootryx theme [name]  recolour the window (Vana'diel, Bastok, San d'Oria, ...)",
      '  //lootryx hud on|off   a small overlay with whatever is most urgent, no network',
    },
  },
  {
    'Your macros',
    {
      '  //lootryx macros push   read + push changed macro books to Lootryx',
      '  //lootryx macros pull <activeBookIndex>   pull + write web-edited books to your local files',
    },
  },
  {
    'When something looks wrong',
    {
      '  //lootryx status        connection + the last ingest result',
      '  //lootryx pointer       pointer reader and display dimensions',
      '  //lootryx selftest      check everything that works without the network, and report',
      '  //lootryx heartbeat on|off  report your zone so the shell can see who is where (off by default)',
    },
  },
}

local function print_help(args)
  local wants_all = type(args) == 'table' and type(args[1]) == 'string' and args[1]:lower() == 'all'
  if wants_all then
    for _, group in ipairs(HELP_GROUPS) do
      log(group[1] .. ':')
      for _, line in ipairs(group[2]) do
        log(line)
      end
    end
    return
  end

  log('Lootryx v' .. tostring(_addon.version) .. '. Most of this is clickable:')
  log('  //lootryx window      tabs, boards, and every command below as a button')
  log('worth typing:')
  log('  //lootryx setup <code>   first time here? this links you')
  log('  //lootryx snap        post an attendance snapshot now')
  log('  //lootryx dkp         your own balance')
  log('  //lootryx item <name>   what it is, and what your shell values it at')
  log('  //lootryx tod <target>   report a Time of Death you just witnessed')
  log('  //lootryx help all    every command, grouped by what you are doing')
end

-- //lootryx auto on | off. Unlike every other subcommand-taking command in this file (macros, pf),
-- a prior version accepted ANY argument other than exactly "on" as an implicit "off": a typo like
-- "//lootryx auto onn" silently turned auto snapshots OFF (or left them off) while still printing a
-- confirmation line, so a player who intended to turn them ON could read "auto snapshots OFF" and
-- believe that was the mode they had actually asked for, with no error to flag the typo. R12-ADDON
-- (2026-08-02): now validates the argument and refuses (no state change) on anything that is not
-- exactly "on" or "off", matching the usage-guard discipline every other multi-word command here
-- already has (macros push|pull, pf list|post|join). Extracted to its own function, like every
-- other command, so it is directly testable (packages/addon-harness) instead of living inline in
-- the dispatcher below.
local function do_auto(args)
  local mode = (args[1] or ''):lower()
  if mode == 'on' then
    settings.auto = true
  elseif mode == 'off' then
    settings.auto = false
  else
    log('usage: //lootryx auto on | off  (currently ' .. (settings.auto and 'ON' or 'OFF') .. ', unchanged)')
    return
  end
  save_settings()
  log('auto snapshots ' .. (settings.auto and 'ON' or 'OFF'))
end


local function window_tier()
  -- Public-only keys authenticate party actions but grant no linkshell membership.
  -- A different character's saved credentials are still treated as unconfigured.
  if is_unconfigured() then return 'guest' end
  return settings.shell_slug == '' and 'paired' or 'member'
end

local function window_state()
  local tier = window_tier()
  local counts = {
    lfg = hud_state.pf and hud_state.pf.lfg or nil,
    lfm = hud_state.pf and hud_state.pf.lfm or nil,
    shells = hud_state.shells and #hud_state.shells or nil,
    auctions = hud_state.auctions and #hud_state.auctions or nil,
    windows = hud_state.windows and #hud_state.windows or nil,
  }
  if hud_state.pf and hud_state.pf.listings then
    counts.lfg,counts.lfm=0,0
    for _,listing in ipairs(hud_state.pf.listings) do
      local mine=listing.isMine==true or (listing.isMine==nil and listing.host==self_name())
      if not mine then
        if listing.mode=='LFG' then counts.lfg=counts.lfg+1 elseif listing.mode=='LFM' then counts.lfm=counts.lfm+1 end
      end
    end
  end
  local tab = window_lib.resolve_tab(tier, window_tab, counts)
  window_tab = tab
  host.ui_tools.pf_focused=false
  local rows, empty = window_rows_for(tab, tier)
  local freshness=host.ui_tools.refresh_row((host.ui_tools.board_key and host.ui_tools.board_key()) or tab)
  rows=host.ui_tools.present(tab,tier,rows,freshness)
  return {
    tier = tier,
    surface_layout=true,
    unread_notifications=host.ui_tools.unread or 0,
    focused_view=host.ui_tools.pf_focused,
    find_layout=tab=='lfg' or tab=='lfm',
    tab = tab,
    board = board_view,
    counts = counts,
    rows = rows,
    empty = empty,
    shell = tier == 'member' and shell_label() or nil,
    world = settings.world,
    jobs = self_name() or '',
    name = self_name() or '',
    dkp = hud_state.dkp and hud_state.dkp.balance or nil,
    count_label = host.jobs and host.jobs.busy() and (host.ui_tools.request_label or 'Background check in progress') or ({home=settings.world,me='Character',settings='Preferences',shell='Linkshell records',
      auctions=host.ui_tools.surfaces.auction_tab=='results' and ('Results: '..tostring(#(host.ui_tools.auction_results or {}))) or (tostring(counts.auctions or 0)..((counts.auctions or 0)==1 and ' auction' or ' auctions')),windows=tostring(counts.windows or 0)..' targets'})[tab]
      or ((tab=='lfg' or tab=='lfm') and not host.ui_tools.pf_focused and host.ui_tools.surfaces.find_counts[tab]) or (tab=='shells' and (counts.shells==nil and 'Directory not loaded' or tostring(counts.shells)..(counts.shells==1 and ' linkshell' or ' linkshells'))) or 'Party finder',
    theme = settings.theme,
    hover = panel_lib.hover(),
    page = window_page,
  }
end

--- Fetch each public board at most once a session. Everything else still waits to be asked.
local window_prefetched = false
local function window_prefetch()
  if window_prefetched then
    return
  end
  window_prefetched = true
  host.ui_tools.begin(5)
  local ok,err=host.protect(function() do_pf_list();do_shells() end)
  host.ui_tools.finish(function(line) host.chat(207, 'Lootryx: '..line) end)
  if not ok then log('Public boards could not load: '..tostring(err)) end
end

local function window_canvas()
  return window_lib.build(window_state(), panel_lib.measure, panel_lib.room())
end

window_refresh = function()
  if panel_lib.visible() then
    panel_lib.draw(window_canvas())
  end
end

-- The renderer rebuilds through this when the hovered control changes, so the pointer can light
-- one up without the model needing to know a mouse exists.
panel_lib.bind(window_lib, window_canvas, function(x, y)
  settings.window_x, settings.window_y = x, y
  save_settings()
end)
if panel_lib.pointer_alignment then panel_lib.pointer_alignment.configure(settings,function() config.save(settings) end) end
panel_lib.set_position(settings.window_x, settings.window_y)

--[[
  Rows for each tab, and what a click does.

  Everything is drawn from state already fetched. Opening the window makes no request at all, which
  is the same promise the overlay makes: the addon talks to the network when you ask it to, never
  because a UI appeared.
]]

--[[
  The one action awaiting confirmation, or nil: `{ action = <the action id>, offer = <n> }`.

  Two things in this window report outward and cannot be taken back: a bid spends DKP, and a
  time-of-death writes a window the whole shell then camps (and can award DKP). Both take two
  clicks. The first arms and says what the second will do, and anything else you click clears it,
  so an armed button cannot sit waiting to catch a later stray press.

  Keyed by the ACTION ID, which carries the auction's or the target's own identity, never a position
  in a list: that is the trap `//lootryx allin` documents and sidesteps by making the word "confirm"
  carry the state. A variable remembering a NUMBER will happily attach itself to a different row
  after the list refreshes underneath it. Confirming re-finds the subject by id and refuses if it
  has gone, so the worst a stale arm can do is nothing.
]]
local window_armed = nil

--[[
  What is currently typed into the drop composer.

  Kept OUTSIDE the field module because it survives the box losing focus: you fill in the item, the
  keyboard goes back to the game, you check who actually won, then you fill in the winner. A draft
  that vanished on blur would make the second half impossible.
]]
local drop_draft = { open = false, item = '', winner = '' }

--- Which focused board is open, or nil for the tab's own hub. One at a time, so each view is
--- bounded by its own list rather than by whatever else happens to share the tab. Shell owns four
--- of these and Me owns the wishlist; a tab only ever answers to its own names, and switching tabs
--- clears it so clicking Shell always lands on the Shell hub.
board_view = nil

--[[
  The Party Finder composer: what is currently being written, and whether it is open at all.

  `Post listing` used to print the setup steps, on every tier, whether or not you were linked. It
  opens this instead. Category and role are CYCLED rather than typed, because both are short fixed
  lists and a typo in either is a 400 the player has to decode; only the comment is free text.
]]
local pf_draft = { open = false, category = 'EXP', role = 'ANY', needed={ANY=true}, comment = '' }

--[[
  The auction opener.

  Bidding shipped before opening did, so the tab was a board a member could act on and an officer
  could not: the one command that starts an auction was typed-only, and it is typed standing over a
  treasure pool with about four minutes on the clock. That is the worst possible moment to be
  spelling an item name into a chat box.

  `pool` is what the two window types mean: a pool drop closes with the treasure pool, and a long
  auction runs an ordinary multi-hour window.
]]
local auction_draft = { open = false, item = '', pool = true }

--[[
  The setup code, typed into the window.

  This is the first thing a new member does and it was the worst thing the addon asked of them: read
  a URL out of a chat line, open a browser, copy a code, alt-tab back, and type `//lootryx setup
  <code>` into the chat box without a typo. Every step of that is now on one row: a button that opens
  the page, a box to paste into, and a button that links.

  A mismatched alt sees the same row, because for that character the answer is the same: it needs its
  own key, and this is where it gets one.
]]
local setup_draft = { code = '' }

--- What is being added to the wishlist. Same item picker the drop composer uses, because it is the
--- same question ("which item?") and a second way to answer it would be a second way to typo it.
local wish_draft = { item = '' }
local AUCTION_WINDOWS = { 'Treasure pool', 'Long auction' }

--[[
  Which dropdown is open, if any.

  One at a time: opening a second closes the first, and anything else you click closes it, the same
  discipline the armed confirm slot follows. Two menus open at once would overlap each other.
]]
local open_menu = nil

--- A dropdown: the control, plus its choices when it is open.
local function select_rows(rows, id, title, options, current, label_of)
  local open = open_menu == id
  local function shown(value)
    return label_of and label_of(value) or value
  end
  rows[#rows + 1] = {
    kind = 'select',
    title = title,
    value = shown(current),
    open = open,
    action_id = 'menu:' .. id,
  }
  if open and id=='pf.category' then
    local choices={}
    for _,option in ipairs(options) do choices[#choices+1]={id='set:'..id..':'..option,label=shown(option),selected=option==current} end
    rows[#rows+1]={kind='choices',compact=true,options=choices}
  elseif open then
    for _, option in ipairs(options) do
      rows[#rows + 1] = {
        kind = 'option',
        -- The label is what a person reads; the id is what gets stored and sent.
        title = shown(option),
        selected = option == current,
        action_id = 'set:' .. id .. ':' .. option,
      }
    end
  end
  return rows
end

--- Rows for one text box, plus its live suggestions when it has focus.
local function field_rows(rows, id, title, value, placeholder, source)
  local focused = field_lib.id() == id
  rows[#rows + 1] = {
    kind = 'field',
    title = title,
    value = focused and field_lib.display('') or value,
    placeholder = placeholder,
    focused = focused,
    action_id = 'focus:' .. id,
  }
  if focused then
    -- Suggestions come from the live text, not the saved draft: they have to move as you type.
    for _, name in ipairs(field_lib.suggest(field_lib.value(), source, 5)) do
      rows[#rows + 1] = {
        kind = 'option',
        action_id = 'pick:' .. name,
        title = name,
        tag = 'PICK',
        accent = 'dim',
        action = { id = 'pick:' .. name, label = 'Use' },
      }
    end
  end
  return rows
end

local function pf_rows(mode)
  host.ui_tools.pf_focused=pf_draft.open or (host.ui_tools.recruitment and (host.ui_tools.recruitment.party_only or host.ui_tools.recruitment.detail or host.ui_tools.recruitment.invites or host.ui_tools.recruitment.feedback)) or false
  if host.ui_tools.recruitment and (host.ui_tools.recruitment.party_only or host.ui_tools.recruitment.detail or host.ui_tools.recruitment.invites or host.ui_tools.recruitment.feedback) then return host.ui_tools.recruitment.rows() end
  local rows = {}


  -- The composer takes over the tab while it is open. You are writing a listing, not reading the
  -- board, and on a 720p client the two together do not fit.
  if pf_draft.open then
    host.ui_tools.pf_composer.enable_counts(pf_draft,hud_state.pf and hud_state.pf.roleSlotsSupported)
    rows={}
    if pf_draft.error then rows[#rows+1]={kind='text',text=pf_draft.error,accent='bad'} end
    if pf_draft.edit_id then rows[#rows+1]={kind='toolbar',title=mode=='LFG' and 'Edit availability' or 'Edit recruitment'} end
    rows[#rows+1]={kind='choices',compact=true,options={
      {id='pf:mode:LFG',label='Looking for a group',selected=mode=='LFG'},
      {id='pf:mode:LFM',label='Recruiting members',selected=mode=='LFM'}}}
    if not (mode=='LFM' and pf_draft.counted) then rows[#rows+1]={title=self_name() or 'Your character',tag='ME',art='character',
      subtitle=mode=='LFG' and 'Choose what you can play. Players contact you to form a party.' or (pf_draft.counted and 'Allocate the places after you. Game invitations remain separate.' or 'Choose the role you need most. Game invitations remain separate.')}
    end
    if mode=='LFM' and pf_draft.counted then
      field_rows(rows,'pf.capacity','Party size',tostring(pf_draft.maxSize),'2 to 18, including you')
      for _,r in ipairs(host.ui_tools.pf_composer.count_rows(pf_draft)) do rows[#rows+1]=r end
    elseif category_uses_role(pf_draft.category) then
      rows[#rows+1]={kind='header',title=mode=='LFG' and 'Your role: choose one' or 'Role needed: choose one'}
      rows[#rows+1]=host.ui_tools.pf_composer.choices(pf_draft,mode)
    end
    select_rows(rows,'pf.category','Activity',PF_CATEGORIES,pf_draft.category)
    field_rows(rows,'pf.comment','Comment',pf_draft.comment,mode=='LFG' and 'What would you like to do?' or 'Where, when and places available',nil)
    rows[#rows+1]={kind='actions',title=pf_draft.edit_id and 'Save listing changes' or (mode=='LFG' and 'Make yourself available' or 'Open your recruitment'),
      subtitle=mode=='LFM' and (pf_draft.counted and 'Lootryx roster only. Send game invitations yourself.' or 'Choose Any when several roles are welcome; describe them in your comment.') or 'Players can contact you. You choose which party to join.',
      actions={{id='pf:cancel',label='Cancel'},{id='pf:send',label=pf_draft.edit_id and 'Save changes' or (mode=='LFG' and 'Start looking' or 'Open recruitment'),primary=true}}}
    return rows
  end

  rows[#rows+1]={kind='toolbar',title=mode=='LFG' and 'Looking for a group' or 'Recruiting members',accent='bright',
    actions={{id='post',label=mode=='LFG' and 'Find a group' or 'Create recruitment',primary=true}}}
  rows[#rows+1]={kind='toolbar',title='',actions={{id='pf:party',label='Your game party'},{id='pf:inbox',label='Invitations'}}}
  do
    local fresh=host.ui_tools.refresh_row('pf')
    rows[#rows+1]={kind='toolbar',title=fresh and fresh.title or 'Not refreshed yet',accent=fresh and fresh.accent,
      actions={{id='refresh_pf',label='Refresh'}}}
    if fresh and fresh.accent=='bad' then rows[#rows+1]={kind='toolbar',title=fresh.subtitle,accent='bad'} end
  end
  local visible_count=0
  if mode == 'LFM' then
    local statics = type(hud_state.statics) == 'table' and hud_state.statics or nil
    rows[#rows + 1] = {
      title = 'Linkshell statics',
      tag = denied('statics') and 'LOCK' or 'LFS',
      accent = denied('statics') and 'bad'
        or (statics == nil and 'accent' or (#statics > 0 and 'good' or 'dim')),
      subtitle = denied('statics') and 'your role cannot see this'
        or (statics == nil and 'not fetched yet')
        or (#statics > 0 and (#statics .. ' recruiting') or 'nobody recruiting'),
      action = not denied('statics') and { id = 'board:statics', label = 'View teams' } or nil,
    }
  end

  local listings = hud_state.pf and hud_state.pf.listings or {}
  for _, listing in ipairs(listings) do
    if listing.mode == mode then
      visible_count=visible_count+1
      local size = tostring(listing.members or 0) .. '/' .. tostring(listing.maxSize or 6)
      -- Your own listing has no Join on it. The server would refuse it, and offering a button whose
      -- only outcome is an error is worse than offering nothing.
      local mine = listing.isMine==true or (listing.isMine==nil and listing.host and self_name() and tostring(listing.host) == self_name())
      local category = tostring(listing.category or 'OTHER')
      local role = tostring(listing.role or 'ANY')
      rows[#rows + 1] = {
        title = tostring(listing.host or '?')..(mode=='LFM' and "'s party" or ''),
        badge = '[' .. category .. ']',
        badge_colour = window_lib.category_colour(listing.category),
        -- A craft listing carries no meaningful role, so its row does not print one either.
        subtitle = (listing.openRoles and (host.ui_tools.pf_composer.open_summary(listing.openRoles)..' / ') or ((listing.hostJob and (tostring(listing.hostJob)..' / ') or '') .. (category ~= 'CRAFT' and (role .. ' / ') or ''))) .. tostring(listing.comment or listing.zone or ''),
        meta = mode=='LFM' and size or nil,
        accent = mine and 'good' or 'info',
        tag = mine and 'YOURS' or (mode~='LFM' and (category == 'CRAFT' and 'CRFT' or role:sub(1, 4)) or nil),
        role_icon = mode=='LFG' and category~='CRAFT' and role or nil,
        art = mode=='LFM' and 'pennant' or nil,
        action = listing.id
          and { id = 'pfdetail:' .. tostring(listing.id), label = mine and 'Manage' or (mode=='LFG' and 'Contact' or 'View party') }
          or nil,
      }
    end
  end
  if visible_count==0 then
    rows[#rows+1]={title=mode=='LFG' and 'Nobody is looking for a group yet' or 'No parties are recruiting yet',
      subtitle=mode=='LFG' and 'Use Find a group to share your availability.' or 'Create a recruitment to start your party.',art='pennant',accent='dim'}
  end
  return rows
end

local function shell_rows()
  local rows = {}
  for _, shell in ipairs(hud_state.shells or {}) do
    rows[#rows + 1] = {
      title = tostring(shell.name or '?'),
      badge = shell.recruiting and '[RECRUITING]' or nil,
      badge_colour = 'good',
      subtitle = tostring(shell.blurb or shell.joinPolicy or ''),
      meta = tostring(shell.members or 0),
      meta_colour = 'dim',
      accent = shell.recruiting and 'good' or 'dim',
      tag = 'LS',
      action = shell.slug and { id = 'shell:' .. tostring(shell.slug), label = 'Open' } or nil,
    }
  end
  return rows
end

--[[
  Auctions, and the only place in this window where a click spends something.

  A button is offered only where ONE number is the obvious offer and the window is not inventing it:
  a tier minimum, or a fixed price. A percentage bid and an all-in are decisions about how much, so
  they keep their typed command and get no button; all-in additionally already has its own
  confirmation word.

  Numbering matches `//lootryx auctions` because both filter on the same thing (a row needs a string
  id to be biddable), so the number printed here is the number that command takes.
]]
-- Manual composers share the existing command transport and server validation.
function auction_draft.handle(id)
  auction_draft.bid_drafts=auction_draft.bid_drafts or {}
  if id:sub(1,8)=='dkppool:' then auction_draft.dkp_pool=id:sub(9);window_armed=nil;window_refresh();return true end
  if id:sub(1, 8) == 'editbid:' then
    if auction_draft.bid_id then auction_draft.bid_drafts[auction_draft.bid_id]={amount=auction_draft.amount,lane=auction_draft.lane} end
    auction_draft.bid_id, auction_draft.amount, auction_draft.lane = id:sub(9), '', 'MAIN'
    window_armed=nil;auction_draft.error=nil
    for _,a in ipairs(hud_state.auctions or {}) do
      if a.id==auction_draft.bid_id and type(a.myBid)=='table' then
        auction_draft.amount=tostring(a.myBid.percent or a.myBid.amount or '')
        auction_draft.lane=a.myBid.lane=='LOW' and 'LOW' or 'MAIN'
      end
    end
    local draft=auction_draft.bid_drafts[auction_draft.bid_id]
    if draft then auction_draft.amount=draft.amount;auction_draft.lane=draft.lane end
  elseif id == 'bidcancel' then
    if auction_draft.bid_id then auction_draft.bid_drafts[auction_draft.bid_id]={amount=auction_draft.amount,lane=auction_draft.lane} end
    auction_draft.bid_id = nil
  elseif id == 'bidlane' then auction_draft.lane = auction_draft.lane == 'LOW' and 'MAIN' or 'LOW'
  elseif id == 'bidsend' then
    local current
    for _, a in ipairs(hud_state.auctions or {}) do if a.id == auction_draft.bid_id then current = a end end
    if not current or safe_num(current.endsAtMs, 0) <= os.time() * 1000 then
      window_armed = nil;auction_draft.error='That auction has closed. Return to auctions and refresh.';return true
    end
    local input = current.mode == 'ALL_IN' and '100%' or auction_draft.amount
    if current.mode == 'PERCENTAGE' and not input:find('%', 1, true) then input = input .. '%' end
    local _, amount, percent, lane, err = parse_bid_args({'1', input, auction_draft.lane == 'LOW' and 'low' or nil})
    if err then auction_draft.error=err;window_armed=nil;field_lib.focus('bid.amount',auction_draft.amount);return true end
    auction_draft.error=nil
    local signature = current.id .. ':' .. input .. ':' .. lane
    if window_armed and window_armed.action == id and window_armed.offer == signature then
      window_armed = nil
      if send_bid({id=current.id, name=current.itemName}, amount, percent, lane) then
        auction_draft.bid_drafts[current.id]=nil
        auction_draft.bid_id = nil
        do_auctions()
      else auction_draft.error=host.ui_tools.bid_error or 'Could not confirm the bid. Check the auction before retrying.' end
    else window_armed = {action=id, offer=signature} end
  elseif id == 'todsend' then
    if not auction_draft.target or auction_draft.target == '' then
      hud_state.tod_feedback = {message='Enter the name of the target you saw die.', ok=false}
      field_lib.focus('tod.target', '')
      return true
    end
    local stamp, problem = field_lib.tod.parse(auction_draft.killed_at)
    if not stamp then
      hud_state.tod_feedback = {message=problem, ok=false}
      return true
    end
    local offer = auction_draft.target .. '|' .. (auction_draft.killed_at or '')
    if window_armed and window_armed.action == id and window_armed.offer == offer then
      local confirmed_time = window_armed.killed_at
      window_armed = nil
      if do_tod({auction_draft.target}, confirmed_time) then
        auction_draft.killed_at = nil
        do_windows()
      end
    else window_armed = {action=id, offer=offer, killed_at=stamp} end
  elseif id == 'poolread' then
    auction_draft.treasure = {}
    local ok, pool = pcall(host.read_treasure)
    local rok, res = pcall(host.resources)
    if ok and type(pool) == 'table' and rok then
      for slot, item in pairs(pool) do
        local resource = type(item) == 'table' and res.items[item.item_id]
        if resource and resource.en then
          auction_draft.treasure[#auction_draft.treasure+1] = {slot=slot, name=resource.en, item_id=item.item_id, timestamp=item.timestamp}
        end
      end
      table.sort(auction_draft.treasure, function(a,b) return tostring(a.slot)<tostring(b.slot) end)
    end
  elseif id:sub(1, 9) == 'poolpick:' then
    local chosen = (auction_draft.treasure or {})[tonumber(id:sub(10))]
    if chosen then auction_draft.item, auction_draft.pool, auction_draft.selected = chosen.name, true, chosen end
    auction_draft.treasure = nil
  else return false end
  return true
end

local function auction_rows()
  local rows = {}

  if auction_draft.bid_id then
    local current
    for _, a in ipairs(hud_state.auctions or {}) do if a.id == auction_draft.bid_id then current = a end end
    rows[#rows+1] = {kind='pagehead',title=current and current.itemName or 'Auction unavailable', subtitle=(current and hud_lib.format_auction_countdown(math.max(0,math.floor((safe_num(current.endsAtMs,0)-os.time()*1000)/1000))) or '')..' / Your sealed offer stays private.',
      meta=current and hud_lib.format_auction_countdown(math.max(0,math.floor((safe_num(current.endsAtMs,0)-os.time()*1000)/1000))),meta_colour='accent'}
    if auction_draft.error then rows[#rows+1]={kind='text',text=auction_draft.error,accent='bad'} end
    if current then
      rows[1].fit_content=true
      local available='Not fetched'
      for _,wallet in ipairs(hud_state.dkp and hud_state.dkp.wallets or {}) do
        if wallet.poolName==current.dkpPoolName then available=tostring(wallet.currentBalance or 0)..' DKP (cached)' end
      end
      rows[#rows+1]={kind='metrics',items={
        {title=(current.dkpPoolName or 'Default')..' balance',value=available,art='coins'},
        {title=current.mode=='FIXED' and 'Fixed price' or 'Minimum offer',value=tostring(current.mode=='FIXED' and (current.fixedPrice or 0) or (current.tierMinimum or 0))..' DKP',art='coffer'},
        {title='Offers received',value=tostring(current.bidCount or 0),art='envelope'}}}
      if current.mode=='TIERED' or current.mode=='PRE_BID' then
        rows[#rows+1]={kind='banner',art='coffer',title='Your maximum, not the charge',subtitle='Minimum or runner-up + increment, capped at your bid.'}
      end
      if type(current.myBid)=='table' then rows[#rows+1]={title='Your recorded bid',subtitle=tostring(current.myBid.percent and (tostring(current.myBid.percent)..'%') or (tostring(current.myBid.amount or 0)..' DKP'))..' | '..safe_str(current.myBid.lane,'MAIN'),tag='BID',accent='good'} end
      if safe_num(current.endsAtMs,0)<=os.time()*1000 then
        rows[#rows+1]={title='Bidding ended, awaiting server result',subtitle='Refresh to check settlement. The timer alone does not identify a winner.',tag='TIME',action={id='refresh',label='Check result'}}
        rows[#rows+1]={title='Back to all auctions',tag='BACK',action={id='bidcancel',label='Back'}}
        return rows
      end
      if current.mode ~= 'ALL_IN' then
        field_rows(rows, 'bid.amount', current.mode == 'PERCENTAGE' and 'Percent' or 'DKP', auction_draft.amount, current.mode == 'PERCENTAGE' and '1 to 100 percent of your wallet' or 'Whole DKP amount')
      else rows[#rows+1] = {title='ALL-IN: your entire wallet balance', tag='ALL', accent='bad'} end
      rows[#rows+1] = {kind='toolbar',title='Priority: ' .. (auction_draft.lane=='LOW' and 'Low priority' or 'Main priority'), actions={{id='bidlane',label='Change priority'},{id='auctionweb:'..current.id,label='View on web'}}}
      local armed = window_armed and window_armed.action == 'bidsend'
      rows[#rows+1] = {title=armed and 'Confirm this sealed offer' or 'Review your offer', subtitle=(current.dkpPoolName or 'Default wallet')..' / '..(current.mode == 'ALL_IN' and 'Offers 100% of this wallet' or (auction_draft.amount~='' and (auction_draft.amount..(current.mode=='PERCENTAGE' and '%' or ' DKP maximum')) or 'Enter an amount')), tag=armed and 'CONFIRM' or 'BID', action={id='bidsend',label=armed and 'Confirm bid' or 'Review bid'}}
    end
    rows[#rows+1] = {title='Back to all auctions',tag='BACK',action={id='bidcancel',label='Back'}}
    return rows
  end
  if auction_draft.open then
    if hud_state.you and type(hud_state.you.canRun)=='table' and hud_state.you.canRun.auctions==false then
      return {{kind='banner',title='Auction access changed',subtitle='Your current permissions do not allow opening auctions.',action={id='auc:cancel',label='Back to auctions'}}}
    end
    if #(hud_state.auctions or {})>0 then rows[#rows+1]={title=tostring(#hud_state.auctions)..' existing auctions',subtitle='Return to view bids and live countdowns',tag='BID',action={id='auc:cancel',label='View auctions'}} end
    rows[#rows + 1] = { kind = 'header', title = 'Open an auction' }
    field_rows(rows, 'auction.item', 'Item', auction_draft.item, 'click here, then type', item_names())
    rows[#rows+1] = {title='Choose from your treasure pool', subtitle='Read current pool items, then select one below', tag='LOOT', action={id='poolread',label='Read pool'}}
    if auction_draft.treasure then
      if #auction_draft.treasure == 0 then rows[#rows+1] = {title='No items available in the treasure pool',tag='LOOT'} end
      for i, item in ipairs(auction_draft.treasure) do
        rows[#rows+1] = {title=item.name,item_name=item.name,subtitle='Pool slot ' .. tostring(item.slot),action={id='poolpick:'..i,label='Select'}}
      end
    end
    select_rows(rows, 'auction.window' , 'Closes', AUCTION_WINDOWS,
      auction_draft.pool and AUCTION_WINDOWS[1] or AUCTION_WINDOWS[2])

    if auction_draft.pool and auction_draft.selected then
      local stamp=auction_draft.selected.timestamp
      local known=type(stamp)=='number' and stamp>1000000000 and stamp<=os.time()
      rows[#rows+1]={title=known and ('In pool for ' .. format_duration_short(os.time()-stamp)) or 'Pool timing unavailable',
        subtitle=known and 'Bidding deadline uses the original drop time and shell safety buffer.' or 'Read the pool again. Unknown timing cannot open a pool auction.',tag='TIME'}
    end
    if hud_state.dkp and #(hud_state.dkp.pools or {})>0 then
      rows[#rows+1]={kind='header',title='DKP wallet: choose where the winner pays'}
      local options={}
      for _,p in ipairs(hud_state.dkp.pools) do
        options[#options+1]={id='dkppool:'..p.id,label=p.name,selected=auction_draft.dkp_pool==p.id}
        if #options==2 then rows[#rows+1]={kind='choices',compact=true,options=options};options={} end
      end
      if #options>0 then rows[#rows+1]={kind='choices',compact=true,options=options} end
      for _,p in ipairs(hud_state.dkp.pools) do if p.id==auction_draft.dkp_pool then rows[#rows+1]={kind='toolbar',title='Winner pays from: '..p.name} end end
    end
    local ready = auction_draft.item ~= ''
    local armed = window_armed and window_armed.action == 'auc:send'
    rows[#rows + 1] = {
      title = ready and auction_draft.item or 'Name the item first',
      subtitle = armed and 'click again to open it for the whole shell'
        or (auction_draft.pool and 'Uses the shell pool timer; select a pool item to account for its age.' or 'an ordinary auction window'),
      tag = armed and 'CONFIRM' or 'OPEN',
      accent = armed and 'bad' or (ready and 'good' or 'dim'),
      action = ready and { id = 'auc:send', label = armed and 'Confirm' or 'Open it' } or nil,
    }
    rows[#rows + 1] = {
      title = 'Cancel', tag = 'BACK', accent = 'dim',
      subtitle = 'back to the board without opening one',
      action = { id = 'auc:cancel', label = 'Back' },
    }
    return rows
  end

  local number = 0
  for _, auction in ipairs(hud_state.auctions or {}) do
    if type(auction.id) == 'string' then
      number = number + 1
      local mode = safe_str(auction.mode, 'TIERED')
      local left = math.max(0, math.floor((safe_num(auction.endsAtMs, 0) - os.time() * 1000) / 1000))
      local armed = window_armed and window_armed.action == ('bid:' .. auction.id)

      -- What a single click would offer, if anything.
      local offer, verb
      if mode == 'FIXED' and safe_num(auction.fixedPrice, 0) > 0 then
        offer, verb = safe_num(auction.fixedPrice, 0), 'Buy'
      elseif mode == 'TIERED' and safe_num(auction.tierMinimum, 0) > 0 then
        offer, verb = safe_num(auction.tierMinimum, 0), 'Bid'
      end

      local subtitle
      if armed then
        subtitle = 'Review maximum offer: ' .. tostring(offer) .. ' DKP'
      elseif mode == 'PERCENTAGE' then
        subtitle = 'Choose a percentage bid'
      elseif mode == 'ALL_IN' then
        subtitle = 'All-in: your full available balance'
      elseif offer then
        subtitle = 'Minimum ' .. tostring(offer) .. ' DKP; or choose Custom bid'
      else
        subtitle = 'Enter a sealed bid, then confirm'
      end

      -- Your own bid, never anyone else's: the sealed rule holds here exactly as it does everywhere.
      local chip
      if type(auction.myBid) == 'table' then
        chip = 'you bid'
      end

      rows[#rows + 1] = {
        title = safe_str(auction.itemName, '(unknown item)'),
        item_name = auction.itemName,
        badge = type(auction.tier) == 'string' and auction.tier or nil,
        subtitle = subtitle,
        tag = armed and 'CONFIRM' or (mode == 'ALL_IN' and 'ALL' or 'BID'),
        chip = chip,
        chip_colour = 'info',
        meta = left>0 and hud_lib.format_auction_countdown(left) or 'Awaiting result',
        meta_colour = left < 300 and 'bad' or 'bright',
        accent = armed and 'bad' or 'accent',
        action = left<=0 and {id='refresh',label='Check result'} or offer and {
          id = 'bid:' .. auction.id,
          label = 'Review '..tostring(offer)..' DKP',
        } or { id = 'editbid:' .. auction.id, label = 'Enter bid' },
      }
      if offer then rows[#rows+1] = {title='Choose another offer', tag='BID', action={id='editbid:'..auction.id,label='Custom bid'}} end
    end
  end
  for _,result in ipairs(host.ui_tools.auction_results or {}) do
    local winner=result.won and 'You won' or (result.winnerName and ('Won by '..result.winnerName) or 'Closed without a winner')
    local charge=type(result.charge)=='number' and ('Charged '..result.charge..' DKP') or 'Charge unavailable'
    rows[#rows+1]={result=true,title=result.itemName,item_name=result.itemName,subtitle=winner..' / '..(result.winnerName and charge or 'No award'),tag='BID',accent=result.won and 'good' or 'dim',action={id='auctionweb:'..result.id,label='View result'}}
    rows[#rows+1]={result=true,kind='text',text=(result.dkpPoolName and ('Wallet: '..result.dkpPoolName..' / ') or '')..(type(result.closedAtMs)=='number' and ('Settled '..os.date('%b %d %H:%M',math.floor(result.closedAtMs/1000))) or 'Settlement time unavailable')..(type(result.winningBid)=='number' and (' / Winning bid '..result.winningBid..' DKP') or '')}
    if result.mode=='TIERED' or result.mode=='PRE_BID' then rows[#rows+1]={result=true,kind='text',text='Maximum-bid pricing: one bidder pays the minimum; otherwise just above the runner-up, capped at the winning offer.'} end
  end
  return rows
end

--[[
  HNM windows, and where you report a kill.

  It used to be a list you could only read, with a ToD button that printed the command for you to
  type. The row already knows the target's name, which is the whole argument `//lootryx tod` takes,
  so it can send it. It confirms first, for the same reason bidding does.

  Ordering is the server's (OPEN soonest-to-close, then WAITING, then MISSED, then unknown) and is
  deliberately not re-sorted here.
]]
local function window_rows()
  local rows = {}
  if hud_state.tod_feedback then
    rows[#rows+1]={kind='text',text=(hud_state.tod_feedback.ok and 'ToD recorded: ' or 'ToD needs attention: ')..hud_state.tod_feedback.message,accent=hud_state.tod_feedback.ok and 'good' or 'bad'}
  end
  local target_names, seen = {}, {}
  for _, target in ipairs(hud_state.windows or {}) do
    if type(target.name) == 'string' then target_names[#target_names+1] = target.name; seen[target.name:lower()] = true end
  end
  for _, name in ipairs(field_lib.tod.targets) do
    if not seen[name:lower()] then target_names[#target_names+1] = name end
  end
  field_rows(rows, 'tod.target', 'Target', auction_draft.target or '', 'Type part of a name, then click Use', target_names)
  field_rows(rows, 'tod.time', 'Kill time', auction_draft.killed_at or '', 'Blank / now, 2m ago, or local time 19:45')
  rows[#rows+1] = {kind='text',text='Tracked targets, witnessed kills within 5 minutes only. Older corrections: website or Discord.'}
  local armed = window_armed and window_armed.action == 'todsend'
  rows[#rows+1] = {title=armed and ('Confirm ' .. (auction_draft.target or '')) or 'Report a witnessed time of death', subtitle=armed and ('Kill time: ' .. tostring(window_armed.killed_at) .. ' (UTC). Confirm to send.') or 'Enter a target and time, then review and confirm.',tag=armed and 'CONFIRM' or 'HNM',action={id='todsend',label=armed and 'Confirm ToD' or 'Review ToD'}}
  local now_ms = os.time() * 1000
  for _, target in ipairs(hud_state.windows or {}) do
    local name = safe_str(target.name, '(unknown target)')
    local status = safe_str(target.status, 'UNKNOWN')
    local armed = window_armed and window_armed.action == ('tod:' .. name)

    local tag, accent, meta, meta_colour, subtitle
    if status == 'OPEN' then
      tag, accent, meta_colour = 'OPEN', 'good', 'good'
      meta = hud_lib.format_countdown(math.max(0, math.floor((safe_num(target.closeAtMs, now_ms) - now_ms) / 1000)))
      subtitle = 'open now, closes in'
    elseif status == 'WAITING' then
      tag, accent, meta_colour = 'WAIT', 'info', 'bright'
      meta = hud_lib.format_countdown(math.max(0, math.floor((safe_num(target.openAtMs, now_ms) - now_ms) / 1000)))
      subtitle = 'opens in'
    elseif status == 'MISSED' then
      tag, accent, meta_colour = 'MISS', 'bad', 'bad'
      meta = hud_lib.format_countdown(math.max(0, math.floor((now_ms - safe_num(target.closeAtMs, now_ms)) / 1000)))
      subtitle = 'missed, closed'
    else
      tag, accent = 'HNM', 'dim'
      subtitle = 'no time of death recorded yet'
    end

    rows[#rows + 1] = {
      title = name,
      badge = type(target.zone) == 'string' and target.zone or nil,
      subtitle = armed and 'click again to report it dead NOW' or subtitle,
      tag = armed and 'CONFIRM' or tag,
      accent = armed and 'bad' or accent,
      meta = meta,
      meta_colour = meta_colour,
      action = target.name and {
        id = 'tod:' .. name,
        label = armed and 'Confirm' or 'Log ToD',
      } or nil,
    }
  end
  return rows
end

--[[
  Home: the account and status hub.

  This is the first thing on screen every login, so it answers the questions in the order somebody
  actually has them. WHO am I and is this character connected. What needs me right now. What is
  happening on the server. Link state leads, because until that is settled nothing else on the
  window can do anything, and it used to be answered only by a line of chat that scrolled away.
]]
local function home_rows(tier)
  local rows = {}

  -- What needs you, and ONLY when something does. A section that says "nothing" every login is a
  -- section people stop reading, and the link banner that used to sit at the top of this page was
  -- exactly that: a permanent red notice about a one-time chore. It lives on Me now.
  local urgent = {}
  if tier == 'member' then
    -- First, because it is the only one of these with a deadline you can miss by standing still.
    -- A check-in that is open means a snapshot posted NOW counts and one posted after it closes
    -- does not, which is the whole reason attendance disputes happen.
    local now_ms = os.time() * 1000
    for _, event in ipairs(hud_state.events or {}) do
      if safe_num(event.checkInOpenUntilMs, 0) > now_ms then
        urgent[#urgent + 1] = {
          title = safe_str(event.title, 'an event'),
          tag = 'CHECK IN', accent = 'good',
          subtitle = 'check-in open, ' ..
            hud_lib.format_countdown(math.floor((safe_num(event.checkInOpenUntilMs, 0) - now_ms) / 1000)) .. ' left',
          action = { id = 'cmd:snap', label = 'Post' },
        }
        break
      end
    end
    for _, auction in ipairs(hud_state.auctions or {}) do
      urgent[#urgent + 1] = {
        title = tostring(auction.itemName or 'an auction'), tag = 'BID', accent = 'accent',
        subtitle = 'sealed bid, closing soonest',
        action = { id = 'tab:auctions', label = 'Open' },
      }
      break
    end
    for _, target in ipairs(hud_state.windows or {}) do
      urgent[#urgent + 1] = {
        title = tostring(target.name or '?'), tag = 'HNM', accent = 'info',
        subtitle = 'window tracked',
        action = { id = 'tab:windows', label = 'Open' },
      }
      break
    end
  end
  if #urgent > 0 then
    rows[#rows + 1] = { kind = 'header', title = 'Needs you' }
    for _, row in ipairs(urgent) do
      rows[#rows + 1] = row
    end
  end

  rows[#rows + 1] = { kind = 'header', title = 'On ' .. tostring(settings.world) }
  local pf = hud_state.pf
  rows[#rows + 1] = {
    title = 'Party Finder', tag = 'LFG', accent = 'info',
    subtitle = pf and ((pf.lfg or 0) .. ' looking, ' .. (pf.lfm or 0) .. ' recruiting')
      or 'Server-wide. No linkshell needed to look.',
    action = { id = 'refresh_pf', label = pf and 'Refresh' or 'Look' },
  }
  rows[#rows + 1] = {
    title = 'Linkshells recruiting', tag = 'LS', accent = 'good',
    subtitle = hud_state.shells and (#hud_state.shells .. ' listed on the directory')
      or 'Find one, then apply on the website.',
    action = { id = 'refresh_shells', label = hud_state.shells and 'Browse' or 'Look' },
  }

  if tier == 'member' then
    rows[#rows + 1] = { kind = 'header', title = shell_label() }
    rows[#rows + 1] = {
      title = 'Your DKP', tag = 'DKP', accent = 'accent',
      subtitle = hud_state.dkp and 'balance across every wallet' or 'not fetched yet',
      meta = hud_state.dkp and tostring(hud_state.dkp.balance or '?') or '-',
      meta_colour = 'accent',
      action = { id = 'cmd:dkp', label = 'Check' },
    }
  else
    rows[#rows + 1] = { kind = 'header', title = 'This character' }
    rows[#rows + 1] = {
      title = tostring(self_name() or '?'), tag = 'GUEST', accent = 'dim',
      subtitle = 'not linked to a linkshell',
      action = { id = 'tab:me', label = 'Me' },
    }
  end
  return rows
end

--[[
  Me: everything about the character you are logged in on.

  Split out of Home because link state is a one-time chore. A red banner about it on the front page
  every login nags rather than informs, and this is where you would go to look at yourself anyway.
]]
--[[
  The window's row builders, in one table.

  Lua 5.1 allows a function 200 locals and the addon's main chunk is one function, so every
  file-scope `local function` spends part of a fixed budget; adding the wishlist board is what
  finally hit it. These are all builders for the same window, so a shared namespace is what they
  wanted anyway, and it costs one local instead of seven.
]]
local view = {}

--[[
  Your job declaration, as its own screen.

  Ranked rather than listed: the first slot is the one loot priority reads, so the order IS the
  answer to "which of these do you most want gear for".

  The whole reason this is worth having in game is the row at the top. You are standing here as a
  job; claiming it should not mean typing its abbreviation into a chat command and hoping. A locked
  declaration offers nothing to click, because a button that can only refuse is worse than no
  button.
]]
function view.myjobs_rows()
  if window_armed and window_armed.action=='tools:jobs' then
    return {{kind='pagehead',title='Review job plans'},
      {kind='banner',title='Current priorities',subtitle=window_armed.before},
      {kind='banner',title='New priorities',subtitle=window_armed.after},
      {kind='text',text=window_armed.effect..' No DKP charge. These priorities affect loot eligibility.'},
      {kind='toolbar',actions={{id='tools:plans-cancel',label='Cancel review'},{id='tools:jobs',label='Confirm plans',variant='primary'}}}}
  end
  local rows = { { kind = 'header', title = 'Current character jobs' },
    {title='Read jobs from this character',subtitle='Preview actual levels. Your plans and loot eligibility stay unchanged.',tag='JOB',action={id='jobs:preview',label='Preview sync'}} }
  local draft=host.ui_tools.job_preview
  if draft then
    for _,slot in ipairs({'main','sub'}) do local v=draft.observation[slot];if v then rows[#rows+1]={title=slot .. ': ' .. v.job .. ' ' .. v.level,tag='JOB'} end end
    local codes={};for code in pairs(draft.observation.levels) do codes[#codes+1]=code end;table.sort(codes)
    for _,code in ipairs(codes) do rows[#rows+1]={title=code .. ' Lv' .. draft.observation.levels[code],subtitle='Observed level to sync',tag='JOB'} end
    rows[#rows+1]={title='Sync these observed levels',subtitle='Missing jobs are preserved on the website.',tag='JOB',action={id='jobs:sync',label='Sync to Lootryx'}}
  end
  local current=hud_state.observed_jobs
  rows[#rows+1]={title=current and current.jobsObservedAt and ('Last received: ' .. current.jobsObservedAt) or 'No job sync received yet',subtitle=host.ui_tools.job_feedback or 'Read character progress separately from your priorities.',tag='INFO'}
  rows[#rows+1]={kind='header',title='Job plans and priorities'}
  local decl = hud_state.myjobs
  if type(decl) ~= 'table' then
    rows[#rows + 1] = {
      title = 'Not fetched yet', tag = 'JOB', accent = 'dim',
      subtitle = 'which jobs you have claimed, in order',
      action = { id = 'cmd:myjobs', label = 'Refresh plans' },
    }
    return rows
  end

  local locked = decl.locked == true
  if not locked then
    field_rows(rows,'tools.jobs','Priorities',host.ui_tools.draft.jobs or '', 'Example: PLD BRD WHM; use - to clear a slot')
    rows[#rows+1]={title='Save ranked job plans',subtitle='Sets loot priority. Changes lock for '..tostring(decl.lockDays or '?')..' days; no DKP charge.',
      action={id='tools:jobs',label=window_armed and window_armed.action=='tools:jobs' and 'Confirm plans' or 'Review plans'}}
  end
  if host.ui_tools.plan_feedback then rows[#rows+1]={kind='text',text=host.ui_tools.plan_feedback} end
  local main, sub_job = self_jobs()
  if locked then
    local left = safe_num(decl.lockDaysRemaining, 0)
    rows[#rows + 1] = {
      title = 'Locked', tag = 'LOCK', accent = 'bad',
      subtitle = 'an officer can change it for you',
      meta = tostring(left) .. (left == 1 and ' day' or ' days'),
      meta_colour = 'bright',
    }
  elseif main then
    -- The one thing this surface can offer that no other can.
    local already = safe_str(decl.declaredMain, '') == main
    rows[#rows + 1] = {
      title = already and ('Already claimed as ' .. main) or ('Claim ' .. main .. ' as your first'),
      tag = 'HERE',
      accent = already and 'dim' or 'good',
      subtitle = already and 'the job you are on is already your first'
        or ('the job you are standing here as' .. (sub_job and ('  (/' .. sub_job .. ')') or '')),
      action = (not already) and { id = 'jobs:here', label = 'Review claim' } or nil,
    }
  else
    rows[#rows + 1] = {
      title = 'No job readable', tag = 'JOB', accent = 'dim',
      subtitle = 'log in to claim the job you are on',
    }
  end

  local slots = {
    { label = '1st', job = decl.declaredMain },
    { label = '2nd', job = decl.declaredSecondary },
    { label = '3rd', job = decl.declaredTertiary },
  }
  for _, slot in ipairs(slots) do
    local job = safe_str(slot.job, '')
    rows[#rows + 1] = {
      title = job ~= '' and job or 'Not claimed',
      tag = slot.label,
      accent = job ~= '' and 'accent' or 'dim',
      subtitle = job ~= '' and (slot.label == '1st' and 'what loot priority reads' or 'a further claim')
        or 'nothing in this slot',
    }
  end

  if decl.jobsDeclaredAt == nil and not locked then
    -- Never declared is a different state from unlocked-again, and this is the moment to say the
    -- first one costs nothing.
    rows[#rows + 1] = {
      title = 'No DKP charge for job plans', accent = 'info',
      subtitle = 'Saving changed priorities starts the configured job lock.',
    }
  end
  return rows
end

--- The wishlist, as its own screen: the Add box, then what is on it. Bounded by its own list, so
--- adding a ninth item cannot cost you the rest of the Me tab.
function view.wishlist_rows()
  local rows = { { kind = 'header', title = 'Your wishlist' } }
  rows[#rows + 1] = {
    title = 'Back to your character', tag = 'BACK', accent = 'dim',
    subtitle = 'the rest of the tab',
    action = { id = 'board:hub', label = 'Back' },
  }
  -- The editor goes ABOVE the list on purpose. A screen is trimmed from the bottom, so whatever
  -- sits last is what disappears; with the box last, a member with four items lost the very control
  -- they opened it to use.
  field_rows(rows, 'wish.item', 'Item', wish_draft.item, 'type an item name', item_names())
  if host.ui_tools.wish_feedback then rows[#rows+1]={kind='text',text=host.ui_tools.wish_feedback} end
  if wish_draft.item ~= '' then
    rows[#rows+1]={kind='banner',title='Editing: '..wish_draft.item,subtitle='Priority ranks your wishlist. A standing pre-bid automatically joins eligible auctions up to your limit.'}
    rows[#rows+1]={kind='choices',compact=true,options={}}
    for _,priority in ipairs({1,2,3}) do rows[#rows].options[#rows[#rows].options+1]={id='wishpriority:'..priority,label='Priority '..priority,selected=(wish_draft.priority or 2)==priority} end
    field_rows(rows,'tools.ceiling','Pre-bid',host.ui_tools.draft.ceiling or '', 'Whole DKP amount, or off to clear')
    rows[#rows+1]={kind='actions',title=window_armed and window_armed.action=='wish:save' and 'Confirm item settings' or 'Review item settings',
      subtitle=wish_draft.item..' / Priority '..tostring(wish_draft.priority or 2)..' / Pre-bid '..(host.ui_tools.draft.ceiling or 'off'),
      actions={{id='wish:cancel',label='Cancel'},{id='wish:save',label=window_armed and window_armed.action=='wish:save' and 'Confirm save' or 'Review changes',variant='primary'}}}
  else rows[#rows+1]={kind='text',text='Choose Edit on an item to change its priority or standing pre-bid, or enter a new item above.'} end
  for _, entry in ipairs(hud_state.wishlist or {}) do
    local got = safe_str(entry.status, 'WANTED') == 'OBTAINED'
    local ceiling = safe_num(entry.maxDkp, 0)
    rows[#rows + 1] = {
      title = safe_str(entry.itemName, '(unknown item)'),
        item_name = entry.itemName,
      tag = tostring(safe_num(entry.priority, 2)),
      accent = got and 'dim' or 'accent',
      subtitle = got and 'you have this one'
        or (ceiling > 0 and ('pre-bid up to ' .. tostring(ceiling)) or 'wanted'),
      chip = ceiling > 0 and 'sealed' or nil,
      chip_colour = 'info',
      -- Removing is one click. A wishlist entry is a preference, not a commitment: nothing is
      -- spent, nothing is announced, and putting it back costs one more click.
      action = { id = 'wish:edit:' .. safe_str(entry.itemName, ''), label = 'Edit' },
      secondary_action = {id='wish:remove:'..safe_str(entry.itemName,''),label='Remove',variant='danger'},
    }
  end
  if hud_state.wishlist ~= nil and #hud_state.wishlist == 0 then
    rows[#rows + 1] = {
      title = 'Nothing on it yet', tag = 'WISH', accent = 'dim',
      subtitle = 'add what you are hoping drops',
    }
  elseif hud_state.wishlist==nil then
    rows[#rows+1]={kind='banner',title='Wishlist not fetched yet',subtitle='Refresh to load your saved preferences.',action={id='wish:refresh',label='Refresh wishlist'}}
  end
  return rows
end

local function me_rows(tier)
  local rows = {}
  if tier == 'member' and board_view == 'wishlist' then
    return view.wishlist_rows()
  end
  if tier == 'member' and board_view == 'myjobs' then
    local out = view.myjobs_rows()
    -- Same position the board dispatcher uses for its own views: second row, where the trim cannot
    -- reach it however long the screen gets.
    table.insert(out, 2, {
      title = 'Back to your character', tag = 'BACK', accent = 'dim',
      subtitle = 'the rest of the tab',
      action = { id = 'board:hub', label = 'Back' },
    })
    return out
  end
  local name = self_name() or '(not logged in)'
  rows[#rows + 1] = { kind = 'header', title = 'Character' }
  if tier == 'member' then
    local role = type(hud_state.you) == 'table' and safe_str(hud_state.you.role, '') or ''
    rows[#rows + 1] = {
      title = name,
      tag = role ~= '' and role or 'LINKED', art = 'character',
      accent = 'good',
      subtitle = shell_label() .. '   key ' .. mask_key(settings.key_id),
      -- Your role, once any read has taught the addon what it is. It explains every refusal the
      -- other tabs can show you, and a refusal you cannot explain is one you cannot act on.
      meta = role ~= '' and role:lower() or nil,
      meta_colour = 'info',
    }
    rows[#rows + 1] = {
      title = 'DKP', tag = 'DKP', accent = 'accent',
      subtitle = hud_state.dkp and 'your balance across every wallet' or 'not fetched yet',
      meta = hud_state.dkp and tostring(hud_state.dkp.balance or '?') or '-',
      meta_colour = 'accent',
      action = { id = 'cmd:dkp', label = 'Check' },
    }
    rows[#rows + 1] = {
      title = 'Macros', tag = 'MCR', accent = 'info',
      subtitle = 'upload local books or download web edits',
      action = { id = 'board:macros', label = 'Macro books' },
    }
    rows[#rows + 1] = {
      title = 'Jobs', tag = 'JOB',
      accent = type(hud_state.myjobs) ~= 'table' and 'accent'
        or (hud_state.myjobs.locked == true and 'dim' or 'good'),
      subtitle = type(hud_state.myjobs) ~= 'table' and 'not fetched yet'
        or (safe_str(hud_state.myjobs.declaredMain, '') ~= ''
          and ('1st ' .. safe_str(hud_state.myjobs.declaredMain, ''))
          or 'nothing claimed yet'),
      action = { id = 'board:myjobs', label = 'View plans' },
    }

    -- The wishlist is the one thing on this tab with no ceiling, and it was pushing Connection off
    -- the bottom at eight items. It gets the same treatment the Shell boards got: a summary row
    -- here, the editor and the list on their own screen.
    rows[#rows + 1] = { kind = 'header', title = 'Wishlist' }
    rows[#rows + 1] = {
      title = 'Your wishlist', tag = 'WISH',
      accent = hud_state.wishlist == nil and 'accent' or (#hud_state.wishlist > 0 and 'good' or 'dim'),
      subtitle = hud_state.wishlist == nil and 'not fetched yet'
        or (#hud_state.wishlist == 0 and 'nothing on it yet'
          or (#hud_state.wishlist .. (#hud_state.wishlist == 1 and ' item' or ' items'))),
      action = { id = 'board:wishlist', label = hud_state.wishlist == nil and 'Check' or 'Open' },
    }

    rows[#rows + 1] = { kind = 'header', title = 'Connection' }
    rows[#rows + 1] = {
      title = 'Account connection', tag = 'ADD', accent = 'dim',
      subtitle = 'link this character or claim a public identity',
      action = { id = 'signin', label = 'Open' },
    }
  else
    rows[#rows + 1] = {
      title = name, tag = 'GUEST', accent = 'bad',
      subtitle = 'not linked to a linkshell',
      action = { id = 'signin', label = 'Link' },
    }
    rows[#rows + 1] = {
      title = 'Get a code', tag = '1', accent = 'accent',
      subtitle = 'opens your characters page in a browser',
      action = { id = 'setup:open', label = 'Open' },
    }
    field_rows(rows, 'setup.code', 'Code', setup_draft.code, 'paste it here', nil)
    rows[#rows + 1] = {
      title = setup_draft.code ~= '' and ('Link ' .. name) or 'Paste the code first',
      tag = '2', accent = setup_draft.code ~= '' and 'good' or 'dim',
      subtitle = 'the code lasts ten minutes and works once',
      action = setup_draft.code ~= '' and { id = 'setup:go', label = 'Link' } or nil,
    }
    rows[#rows + 1] = { kind = 'header', title = 'What linking unlocks' }
    rows[#rows + 1] = {
      title = 'Attendance, DKP, auctions, HNM', tag = 'LS', accent = 'dim',
      subtitle = 'linkshell data, so it needs a linkshell',
    }
  end
  return rows
end

--- Shell: the linkshell-wide boards that are reads rather than actions.
--- The drop composer, as its own screen. Same shape the listing and auction composers take: one
--- thing at a time, and a fixed ceiling no amount of shell activity can push past.
function view.drop_composer_rows()
  local rows = {}
  rows[#rows + 1] = { kind = 'header', title = 'Report a drop' }
  field_rows(rows, 'drop.item', 'Item', drop_draft.item, 'click here, then type', item_names())
  field_rows(rows, 'drop.winner', 'Winner', drop_draft.winner, 'who received it', collect_alliance())

  local ready = drop_draft.item ~= '' and drop_draft.winner ~= ''
  local armed = window_armed and window_armed.action == 'dropgo'
  rows[#rows + 1] = {
    title = ready and (drop_draft.item .. '  to  ' .. drop_draft.winner) or 'Fill both boxes',
    tag = armed and 'CONFIRM' or 'DROP',
    accent = armed and 'bad' or (ready and 'good' or 'dim'),
    subtitle = armed and 'click again to send it' or 'reported drops are visible to the whole shell',
    action = ready and { id = 'dropgo', label = armed and 'Confirm' or 'Report' } or nil,
  }
  rows[#rows + 1] = {
    title = 'Cancel', tag = 'BACK', accent = 'dim',
    subtitle = 'back to the board without reporting',
    action = { id = 'drop:cancel', label = 'Back' },
  }
  return rows
end

--[[
  The Shell tab: what the linkshell is doing, and the things you do to it.

  Ordered by what gets LOST when the tab outgrows the screen. Trimming takes from the bottom, so the
  actions sit above the boards; with three events and three bounties on the calendar this tab was
  losing the drop composer entirely, which is the same failure the wishlist Add box and the listing
  Post button both had. Measured, not guessed: the tab trimmed by four rows before this.
]]
--[[
  The four boards the Shell hub opens into, each its own bounded list.

  They were inline sections on one tab until that tab grew past the screen and started trimming the
  bottom half away unreachably. Split out, each is opened deliberately and is the only thing on
  screen while it is, which is the same shape the composers take.
]]
function view.event_rows()
  local rows = { { kind = 'header', title = 'Upcoming events' } }
  if denied('events') then
    rows[#rows + 1] = {
      title = 'Your role cannot see this', tag = 'LOCK', accent = 'bad',
      subtitle = 'Ask an officer for access to the event calendar.',
    }
    return rows
  end
  rows[#rows+1]={kind='toolbar',title='Capture or manage check-in',actions={{id='attendance:open',label='Attendance'}}}

  if hud_state.events == nil or #hud_state.events == 0 then
    rows[#rows + 1] = {
      title = hud_state.events == nil and 'Not fetched yet' or 'Nothing scheduled',
      tag = 'CAL', accent = 'dim',
      subtitle = 'what is scheduled, and whether a snapshot would land',
      action = { id = 'cmd:events', label = hud_state.events == nil and 'Check' or 'Refresh' },
    }
    return rows
  end
  local now_ms = os.time() * 1000
  for _, event in ipairs(hud_state.events) do
    local open_until = safe_num(event.checkInOpenUntilMs, 0)
    local live = open_until > now_ms
    local starts_in = math.floor((safe_num(event.scheduledAtMs, now_ms) - now_ms) / 1000)
    rows[#rows + 1] = {
      title = safe_str(event.title, '(untitled event)'),
      badge = type(event.type) == 'string' and event.type or nil,
      subtitle = live and 'Check-in open'
        or (starts_in > 0 and 'Upcoming' or 'Check-in closed'),
      tag = live and 'OPEN' or 'SOON',
      accent = live and 'good' or 'dim',
      meta = live and hud_lib.format_countdown(math.floor((open_until - now_ms) / 1000))
        or (starts_in > 0 and hud_lib.format_countdown(starts_in) or nil),
      meta_colour = live and 'good' or 'bright',
      chip = type(event.mySignup) == 'string' and event.mySignup ~= '' and 'you: ' .. event.mySignup:lower() or nil,
      chip_colour = 'info',
      -- Event details separate an RSVP from attendance reporting.
      action = safe_str(event.id, '') ~= ''
        and { id = 'board:event:' .. safe_str(event.id, ''), label = 'View event' }
        or nil,
    }
  end
  return rows
end

--[[
  Answering one event.

  Its own screen for the same reason every other composer has one: four choices plus context does
  not share a list with seven other events, and a screen that is only ever about one thing cannot be
  trimmed into ambiguity.

  The job you are on is shown rather than asked for. That is the whole advantage this transport has
  over the other two: Discord makes you type a job and get it right, and the addon already knows,
  because you are standing in the game as it.
]]
function view.event_answer_rows(event_id)
  local event = nil
  for _, row in ipairs(hud_state.events or {}) do
    if safe_str(row.id, '') == event_id then
      event = row
      break
    end
  end
  if not event then
    -- The list moved under us (a refresh, an event that ended). Say so rather than drawing an
    -- answer screen for something that is no longer there.
    return {
      { kind = 'header', title = 'That event is gone' },
      {
        title = 'It is no longer on the calendar', tag = 'CAL', accent = 'dim',
        subtitle = 'the list may have moved on since you opened this',
        action = { id = 'board:events', label = 'Back' },
      },
    }
  end

  local now_ms = os.time() * 1000
  local open_until = safe_num(event.checkInOpenUntilMs, 0)
  local live = open_until > now_ms
  local answered = safe_str(event.mySignup, '')
  local main, sub_job = self_jobs()

  local rows = { { kind = 'header', title = safe_str(event.title, '(untitled event)') } }
  rows[#rows + 1] = {
    title = 'Back to the calendar', tag = 'BACK', accent = 'dim',
    subtitle = 'the other events',
    action = { id = 'board:events', label = 'Back' },
  }
  rows[#rows + 1] = {
    title = answered ~= '' and ('You are marked ' .. answered:lower()) or 'You have not answered',
    tag = answered ~= '' and 'YOU' or 'ASK',
    accent = answered ~= '' and 'good' or 'accent',
    subtitle = main and ('answering as ' .. main .. (sub_job and ('/' .. sub_job) or ''))
      or 'answering with no job (not logged in)',
    meta = live and hud_lib.format_countdown(math.floor((open_until - now_ms) / 1000)) or nil,
    meta_colour = 'good',
  }

  for _, choice in ipairs(SIGNUP_CHOICES) do
    local current = answered == choice.status
    rows[#rows + 1] = {
      title = choice.label,
      tag = current and 'NOW' or choice.status:sub(1, 3),
      accent = current and 'good' or 'dim',
      subtitle = current and 'this is your answer' or choice.blurb,
      action = (not current) and { id = 'rsvp:' .. choice.status .. ':' .. event_id, label = 'Set' } or nil,
    }
  end

  -- This entry also reaches officer start when no check-in is open.
  rows[#rows + 1] = {
      title = 'Attendance check-in', tag = 'SNAP', accent = 'good',
      subtitle = live and 'Review the current event and roster before capturing' or 'Check attendance status. Officers can open scheduled or unscheduled check-in.',
      action = { id = 'attendance:open', label = 'View attendance' },
    }
  return rows
end

--[[
  The item lookup, as its own screen.

  A box, the same picker the drop composer uses, and the answer underneath. The draft lives on
  `hud_state` rather than in its own file-scope local for the reason recorded twice above: Lua 5.1
  caps a function at 200 locals and this addon's main chunk is one function.
]]
function view.item_rows()
  -- No Back row here: the board dispatcher inserts one at index 2 for every focused view it
  -- builds, so writing another produced TWO on this screen. One place owns it.
  local rows = { { kind = 'header', title = 'Look up an item' } }
  field_rows(rows, 'item.name', 'Item', safe_str(hud_state.item_draft, ''), 'type a name', item_names())
  if safe_str(hud_state.item_draft, '') ~= '' then
    rows[#rows + 1] = {
      title = safe_str(hud_state.item_draft, ''), tag = 'FIND', accent = 'good',
      subtitle = 'what it is, and what your shell values it at',
      action = { id = 'item:go', label = 'Look up' },
    }
  end

  local found = hud_state.item
  if type(found) ~= 'table' then
    if safe_str(hud_state.item_query, '') ~= '' then
      -- Asked and answered: nothing matched. A different fact from "you have not asked yet", and
      -- the screen has to keep them apart or a typo looks like an empty box.
      rows[#rows + 1] = {
        title = 'Nothing matched', tag = 'MISS', accent = 'bad',
        subtitle = 'no item named like "' .. safe_str(hud_state.item_query, '') .. '"',
      }
    end
    return rows
  end

  local item = type(found.item) == 'table' and found.item or {}
  local detail = type(found.shell) == 'table' and found.shell or nil
  local bits = {}
  if safe_str(item.slot, '') ~= '' then
    bits[#bits + 1] = safe_str(item.slot, '')
  end
  if safe_num(item.level, 0) > 0 then
    bits[#bits + 1] = 'Lv' .. tostring(safe_num(item.level, 0))
  end
  rows[#rows + 1] = {
    title = safe_str(item.name, '(unnamed)'),
    item_name = item.name,
    tag = 'ITEM', accent = 'accent',
    subtitle = #bits > 0 and table.concat(bits, '  ') or safe_str(item.category, 'item'),
    meta = job_list(item.jobs) ~= '' and job_list(item.jobs) or nil,
    meta_colour = 'bright',
  }
  if safe_str(item.source, '') ~= '' then
    rows[#rows + 1] = {
      title = 'Drops from', tag = 'FROM', accent = 'dim',
      subtitle = safe_str(item.source, ''),
    }
  end

  if detail then
    local tier = safe_str(detail.tier, '')
    local value = detail.dkpValue
    rows[#rows + 1] = {
      title = (tier ~= '' or value ~= nil) and 'What your shell says' or 'Your shell has not catalogued this',
      tag = 'DKP',
      accent = (tier ~= '' or value ~= nil) and 'good' or 'dim',
      subtitle = tier ~= '' and ('tier ' .. tier) or 'no tier set',
      meta = value ~= nil and (tostring(safe_num(value, 0)) .. ' DKP') or nil,
      meta_colour = 'accent',
    }
    local wants = type(detail.wishlistedBy) == 'table' and detail.wishlistedBy or {}
    for _, who in ipairs(wants) do
      rows[#rows + 1] = {
        title = tostring(who), tag = 'WANT', accent = 'info',
        subtitle = 'has this on their wishlist',
      }
    end
  end
  return rows
end

--[[
  The Static Finder board, both halves on one screen.

  Recruiting first, because a listing has seats that fill; a member looking for one will still be
  looking tomorrow. Open seats and the jobs still wanted are what decide whether a listing is worth
  a click, so they sit on the row rather than a click deeper.
]]
function view.statics_rows()
  local rows = { { kind = 'header', title = 'Linkshell statics' } }
  if denied('statics') then
    rows[#rows + 1] = {
      title = 'Your role cannot see this', tag = 'LOCK', accent = 'bad',
      subtitle = 'Ask an officer for access to linkshell teams.',
    }
    return rows
  end
  if hud_state.statics == nil then
    rows[#rows + 1] = {
      title = 'Not fetched yet', tag = 'LFS', accent = 'dim',
      subtitle = 'who is recruiting a static, and who is looking',
      action = { id = 'cmd:statics', label = 'Check' },
    }
    return rows
  end

  rows[#rows + 1] = view.statics_you_row()

  rows[#rows + 1] = { kind = 'header', title = 'Recruiting' }
  if #hud_state.statics == 0 then
    rows[#rows + 1] = {
      title = 'Nobody is recruiting', tag = 'LFS', accent = 'dim',
      subtitle = 'no linkshell static is taking applications',
    }
  end
  for _, row in ipairs(hud_state.statics) do
    local open = safe_num(row.openSlots, 0)
    local jobs = job_list(row.openJobs)
    rows[#rows + 1] = {
      title = safe_str(row.title, '(untitled)'),
      tag = 'LFS', accent = open > 0 and 'good' or 'dim',
      subtitle = safe_str(row.hostName, '') ~= '' and ('hosted by ' .. safe_str(row.hostName, ''))
        or 'no host recorded',
      meta = open > 0 and (tostring(open) .. (open == 1 and ' seat' or ' seats')) or 'full',
      meta_colour = open > 0 and 'good' or 'dim',
      chip = jobs ~= '' and jobs or nil,
      chip_colour = 'info',
    }
  end

  local seekers = type(hud_state.seekers) == 'table' and hud_state.seekers or {}
  if #seekers > 0 then
    rows[#rows + 1] = { kind = 'header', title = 'Looking for a static' }
    for _, row in ipairs(seekers) do
      local job = safe_str(row.mainJob, '')
      local sub_job = safe_str(row.secondaryJob, '')
      rows[#rows + 1] = {
        title = safe_str(row.name, '(someone)'),
        tag = 'SEEK', accent = 'accent',
        subtitle = safe_str(row.commitment, '') ~= '' and safe_str(row.commitment, ''):lower()
          or 'no commitment set',
        meta = job ~= '' and (job .. (sub_job ~= '' and ('/' .. sub_job) or '')) or nil,
        meta_colour = 'bright',
      }
    end
  end
  return rows
end

function view.statics_you_row()
  return hud_state.seeking == true and {
    title = 'You are listed as looking', tag = 'SEEK', accent = 'good',
    subtitle = 'hosts can see you and your availability',
    action = { id = 'cmd:unseek', label = 'Remove' },
  } or {
    title = 'You are not on this board', tag = 'SEEK', accent = 'dim',
    -- Listing yourself is a form, not a button: it needs a timezone and availability the addon has
    -- no honest way to ask for, and a half-filled profile wastes a host's time rather than saving
    -- yours. So it says where to do it instead of offering a button that would do it badly.
    subtitle = 'list yourself on lootryx.com, where availability lives',
  }
end

--[[
  The shell's open polls, one screen.

  A poll is the linkshell asking itself a question, and the answer is usually "when can you make
  it", which you know while sitting in the game rather than later at a browser. Each option is a
  button: clicking one you already hold takes it back, the same as the Discord buttons, so there is
  no separate unvote to find.
]]
function view.poll_rows()
  local rows = { { kind = 'header', title = 'Open polls' } }
  if denied('polls') then
    rows[#rows + 1] = {
      title = 'Your role cannot see this', tag = 'LOCK', accent = 'bad',
      subtitle = 'Ask an officer for access to linkshell polls.',
    }
    return rows
  end
  if hud_state.polls == nil then
    rows[#rows + 1] = {
      title = 'Not fetched yet', tag = 'POLL', accent = 'dim',
      subtitle = 'what the shell is deciding',
      action = { id = 'cmd:polls', label = 'Check' },
    }
    return rows
  end
  if #hud_state.polls == 0 then
    rows[#rows + 1] = {
      title = 'Nothing to decide', tag = 'POLL', accent = 'dim',
      subtitle = 'no poll is open on this shell',
    }
    return rows
  end

  local now_ms = os.time() * 1000
  for _, poll in ipairs(hud_state.polls) do
    local closes = safe_num(poll.closesAtMs, 0)
    -- The question is a ROW, not a header. A header is a section label and the renderer uppercases
    -- it, which turns a question into shouting; and a poll's question is the content of this
    -- screen rather than a label over it.
    local total = 0
    for _, option in ipairs(type(poll.options) == 'table' and poll.options or {}) do
      total = total + safe_num(option.votes, 0)
    end
    rows[#rows + 1] = {
      title = safe_str(poll.question, '(no question)'),
      tag = safe_str(poll.kind, '') == 'TIME' and 'WHEN' or 'POLL',
      accent = 'accent',
      subtitle = closes > now_ms
        and ('closes in ' .. hud_lib.format_countdown(math.floor((closes - now_ms) / 1000)))
        or (tostring(total) .. (total == 1 and ' vote so far' or ' votes so far')),
      meta = closes > now_ms and (tostring(total) .. (total == 1 and ' vote' or ' votes')) or nil,
      meta_colour = 'bright',
    }
    for _, option in ipairs(type(poll.options) == 'table' and poll.options or {}) do
      local mine = option.mine == true
      rows[#rows + 1] = {
        title = safe_str(option.label, '(unlabelled)'),
        tag = mine and 'YOURS' or 'VOTE',
        accent = mine and 'good' or 'info',
        subtitle = mine and 'click again to take it back' or 'click to vote for this',
        meta = tostring(safe_num(option.votes, 0)),
        meta_colour = 'accent',
        action = { id = 'vote:' .. safe_str(poll.id, '') .. ':' .. safe_str(option.id, ''), label = mine and 'Undo' or 'Vote' },
      }
    end
  end
  return rows
end

function view.bounty_rows()
  local rows = { { kind = 'header', title = 'Open bounties' } }
  if denied('bounties') then
    rows[#rows + 1] = {
      title = 'Your role cannot see this', tag = 'LOCK', accent = 'bad',
      subtitle = 'Ask an officer for access to linkshell bounties.',
    }
    return rows
  end

  if hud_state.bounties == nil or #hud_state.bounties == 0 then
    rows[#rows + 1] = {
      title = hud_state.bounties == nil and 'Not fetched yet' or 'No open bounties',
      tag = 'BTY', accent = 'dim',
      subtitle = 'standing rewards you could go and earn',
      action = { id = 'cmd:bounties', label = hud_state.bounties == nil and 'Check' or 'Refresh' },
    }
    return rows
  end
  for _, bounty in ipairs(hud_state.bounties) do
    -- nil slotsLeft means UNLIMITED, which is a different fact from "none left" and has to look
    -- like one: showing 0 for unlimited would read as a bounty nobody can still claim.
    local left = bounty.slotsLeft
    rows[#rows + 1] = {
      title = safe_str(bounty.title, '(untitled)'),
      subtitle = left == nil and 'unlimited claims' or (tostring(safe_num(left, 0)) .. ' left to claim'),
      tag = 'BTY',
      accent = (left ~= nil and safe_num(left, 0) == 0) and 'dim' or 'good',
      meta = tostring(safe_num(bounty.dkpReward, 0)) .. ' DKP',
      meta_colour = 'accent',
    }
  end
  return rows
end

function view.bank_rows()
  local rows = { { kind = 'header', title = 'The bank' } }
  if denied('bank') then
    rows[#rows + 1] = {
      title = 'Your role cannot see this', tag = 'LOCK', accent = 'bad',
      subtitle = 'Ask an officer for access to bank records.',
    }
    return rows
  end

  local bank = hud_state.bank
  if type(bank) ~= 'table' then
    rows[#rows + 1] = {
      title = 'Not fetched yet', tag = 'GIL', accent = 'dim',
      subtitle = 'what the shell is holding',
      action = { id = 'cmd:bank', label = 'Check' },
    }
    return rows
  end
  rows[#rows + 1] = {
    title = tostring(safe_num(bank.totalItems, 0)) .. ' items held',
    tag = 'GIL', accent = 'accent',
    subtitle = 'of which sellable',
    meta = tostring(safe_num(bank.sellableGil, 0)) .. ' gil',
    meta_colour = 'bright',
    action = { id = 'cmd:bank', label = 'Refresh' },
  }
  for _, row in ipairs(type(bank.rows) == 'table' and bank.rows or {}) do
    local qty = safe_num(row.quantity, 1)
    rows[#rows + 1] = {
      title = safe_str(row.itemName, '(unknown item)'),
        item_name = row.itemName,
      subtitle = row.sellable == true and 'sellable' or 'held',
      tag = 'ITEM', accent = row.sellable == true and 'good' or 'dim',
      meta = qty > 1 and ('x' .. tostring(qty)) or nil,
    }
  end

  -- Currency is a stock you spend rather than items on a mule, so it reads as its own section:
  -- what is held now, and what has passed through. A denomination nobody has recorded shows
  -- nothing at all, rather than a row of zeroes.
  local money = type(hud_state.currency) == 'table' and hud_state.currency or {}
  if #money > 0 then
    rows[#rows + 1] = { kind = 'header', title = 'Currency' }
    for _, row in ipairs(money) do
      local spent = safe_num(row.spent, 0)
      rows[#rows + 1] = {
        title = safe_str(row.currency, '(currency)'),
        tag = 'CUR', accent = safe_num(row.stock, 0) > 0 and 'accent' or 'dim',
        subtitle = spent > 0 and (tostring(spent) .. ' spent so far') or 'none spent yet',
        meta = tostring(safe_num(row.stock, 0)) .. ' held',
        meta_colour = 'bright',
      }
    end
  end
  return rows
end

function view.loot_rows()
  local rows = { { kind = 'header', title = 'Recent loot' } }
  if denied('loot') then
    rows[#rows + 1] = {
      title = 'Your role cannot see this', tag = 'LOCK', accent = 'bad',
      subtitle = 'Ask an officer for access to loot history.',
    }
    return rows
  end

  if hud_state.loot == nil or #hud_state.loot == 0 then
    rows[#rows + 1] = {
      title = hud_state.loot == nil and 'Not fetched yet' or 'Nothing recorded yet',
      tag = 'LOOT', accent = 'dim',
      subtitle = "the shell's most recent drops and where they went",
      action = { id = 'cmd:loot', label = hud_state.loot == nil and 'Check' or 'Refresh' },
    }
    return rows
  end
  local now_ms = os.time() * 1000
  for _, drop in ipairs(hud_state.loot) do
    local who = safe_str(drop.recipientName, '')
    rows[#rows + 1] = {
      title = safe_str(drop.itemName, '(unknown item)'),
        item_name = drop.itemName,
      subtitle = safe_str(drop.disposition, '?'):lower():gsub('_', ' ') ..
        (who ~= '' and ('  to ' .. who) or ''),
      tag = 'LOOT', accent = 'dim',
      meta = hud_lib.format_countdown(
        math.max(0, math.floor((now_ms - safe_num(drop.createdAtMs, now_ms)) / 1000))
      ) .. ' ago',
    }
  end
  return rows
end

--[[
  The Shell tab, as a hub.

  It grew to five sections (do, standings, events, bounties, bank, loot) and stopped fitting: with a
  busy calendar the bottom half was trimmed away and simply unreachable, which is worse than not
  having built it. A tab is trimmed from the BOTTOM, and no amount of reordering fixes a tab whose
  content has no ceiling.

  So each board is ONE summary row that opens a focused view, the same "one thing at a time" shape
  the drop, listing and auction composers already use. The hub has a fixed height, every board is
  reachable, and each detail view is bounded by its own list.
]]
function view.board_summary(title, tag, state, empty_label, describe, block)
  -- A refusal outranks every other summary. Without this the hub row for a block the caller's role
  -- may not read said "not fetched yet", inviting them to click a board that can only ever refuse.
  if block and denied(block) then
    return { title = title, tag = 'LOCK', accent = 'bad', subtitle = 'your role cannot see this' }
  end
  if state == nil then
    return { title = title, tag = tag, accent = 'accent', subtitle = 'not fetched yet' }
  end
  if #state == 0 then
    return { title = title, tag = tag, accent = 'dim', subtitle = empty_label }
  end
  return { title = title, tag = tag, accent = 'good', subtitle = describe(#state) }
end

local function shell_rows_tab()
  local rows = {}

  if drop_draft.open then
    return view.drop_composer_rows()
  end

  -- A focused board. Back sits directly UNDER THE HEADER, not at the end: a list long enough to
  -- overflow would otherwise trim away the only way out, and a full bank does exactly that. Second
  -- row is the one position the trim can never reach.
  if board_view ~= nil then
    -- One event's answer screen, keyed by its id.
    if board_view:sub(1, 6) == 'event:' then
      return view.event_answer_rows(board_view:sub(7))
    end
    local build = (board_view == 'item' and view.item_rows)
      or (board_view == 'polls' and view.poll_rows)
      or (board_view == 'statics' and view.statics_rows)
      or (board_view == 'events' and view.event_rows)
      or (board_view == 'bounties' and view.bounty_rows)
      or (board_view == 'bank' and view.bank_rows)
      or (board_view == 'loot' and view.loot_rows)
    if build then
      local out = build()
      table.insert(out, 2, {
        title = 'Back to the linkshell', tag = 'BACK', accent = 'dim',
        subtitle = 'the rest of the board',
        action = { id = 'board:hub', label = 'Back' },
      })
      return out
    end
  end

  -- No snapshot row here. The status strip already carries "Post snapshot" as this tab's primary
  -- action (status_action in lib/window.lua), so a second copy a hundred pixels below was the same
  -- button twice. Removing it is also exactly the row the hub needed to stay on one page: a
  -- navigation screen you have to page through is worse than one that fits.
  rows[#rows + 1] = { kind = 'header', title = 'Do' }
  rows[#rows + 1] = {
    title = 'Report a drop', tag = 'DROP', accent = 'info',
    subtitle = 'name the item and who received it',
    action = { id = 'drop:open', label = 'Report' },
  }
  rows[#rows + 1] = {
    title = 'Preview the alliance read', tag = 'EYE', accent = 'dim',
    subtitle = 'what a snapshot would send, without sending it',
    action = { id = 'cmd:show', label = 'Preview' },
  }

  rows[#rows + 1] = { kind = 'header', title = 'The linkshell' }
  rows[#rows + 1] = {
    title = 'Standings', tag = 'TOP', accent = 'accent',
    subtitle = 'top 10 by current balance',
    action = { id = 'board:standings', label = 'Open' },
  }

  -- An open check-in is the one thing on this hub with a deadline, so the events row says so rather
  -- than counting rows at you.
  local now_ms = os.time() * 1000
  local live = nil
  for _, event in ipairs(hud_state.events or {}) do
    if safe_num(event.checkInOpenUntilMs, 0) > now_ms then
      live = event
      break
    end
  end
  local events_row = view.board_summary('Events', 'CAL', hud_state.events, 'nothing scheduled', function(n)
    return n .. (n == 1 and ' upcoming' or ' upcoming')
  end, 'events')
  if live then
    events_row.subtitle = 'check-in open: ' .. safe_str(live.title, 'an event')
    events_row.accent = 'good'
  end
  events_row.action = not denied('events') and { id = 'board:events', label = 'View events' } or nil
  rows[#rows + 1] = events_row

  local bounty_row = view.board_summary('Bounties', 'BTY', hud_state.bounties, 'none open', function(n)
    return n .. (n == 1 and ' open' or ' open')
  end, 'bounties')
  bounty_row.action = not denied('bounties') and { id = 'board:bounties', label = 'View bounties' } or nil
  rows[#rows + 1] = bounty_row

  rows[#rows + 1] = {
    title = 'Bank',
    tag = denied('bank') and 'LOCK' or 'GIL',
    accent = denied('bank') and 'bad' or (hud_state.bank == nil and 'accent' or 'dim'),
    subtitle = denied('bank') and 'your role cannot see this'
      or (hud_state.bank == nil and 'not fetched yet')
      or (tostring(safe_num(hud_state.bank.totalItems, 0)) .. ' items held'),
    meta = (not denied('bank')) and hud_state.bank ~= nil
      and (tostring(safe_num(hud_state.bank.sellableGil, 0)) .. ' gil') or nil,
    meta_colour = 'bright',
    action = not denied('bank') and { id = 'board:bank', label = 'View bank' } or nil,
  }

  local polls_row = view.board_summary('Polls', 'POLL', hud_state.polls, 'nothing to decide', function(n)
    return n .. (n == 1 and ' open' or ' open')
  end, 'polls')
  polls_row.action = not denied('polls') and { id = 'board:polls', label = 'View polls' } or nil
  rows[#rows + 1] = polls_row

  rows[#rows + 1] = {
    title = 'Look up an item', tag = 'FIND', accent = 'info',
    subtitle = 'what it is, and what your shell values it at',
    action = { id = 'board:item', label = 'Open' },
  }

  local loot_row = view.board_summary('Recent loot', 'LOOT', hud_state.loot, 'nothing recorded', function(n)
    return n .. (n == 1 and ' drop' or ' drops')
  end, 'loot')
  if not denied('loot') then
    loot_row.accent = 'dim'
  end
  loot_row.action = not denied('loot') and { id = 'board:loot', label = 'View loot' } or nil
  rows[#rows + 1] = loot_row

  return rows
end

--- Settings: every toggle the addon has, in one place, showing its CURRENT value rather than
--- making you run status to find out.
local function settings_rows(tier)
  local rows = {}
  rows[#rows + 1] = { kind = 'header', title = 'Display' }
  -- Six themes behind a Next button meant clicking through five you did not want to see the one
  -- you did, with no way back. Same control as the composer's, same reason.
  select_rows(rows, 'theme', 'Theme', window_lib.theme_names(), settings.theme, function(value)
    return window_lib.theme(value).label
  end)
  rows[#rows + 1] = {
    title = 'Open on login', art = 'setting-window', art_size = 24, tag = settings.open_on_login ~= false and 'ON' or 'OFF',
    accent = settings.open_on_login ~= false and 'good' or 'dim',
    subtitle = 'show this window when the addon loads',
    action = { id = 'cmd:openlogin', label = settings.open_on_login ~= false and 'Turn off' or 'Turn on' },
  }
  rows[#rows + 1] = {
    title = 'Compact overlay', art = 'setting-compact', art_size = 24, tag = settings.hud_enabled and 'ON' or 'OFF',
    accent = settings.hud_enabled and 'good' or 'dim',
    subtitle = 'the small box shown while this window is closed',
    action = { id = 'cmd:hud', label = settings.hud_enabled and 'Turn off' or 'Turn on' },
  }
  if tier == 'member' then
    rows[#rows + 1] = { kind = 'toolbar', title = 'Reporting', actions={{id='board:reporting',label='About'}} }
    rows[#rows + 1] = {
      title = 'Automatic attendance capture', art = 'setting-snapshot', art_size = 24, tag = settings.auto and 'ON' or 'OFF',
      accent = settings.auto and 'good' or 'dim',
      subtitle = 'Capture your alliance every ' .. tostring(settings.interval) .. 's. Requires open check-in.',
      action = { id = 'cmd:auto', label = settings.auto and 'Turn off' or 'Turn on' },
    }
    rows[#rows + 1] = {
      title = 'Share my current zone', art = 'setting-compass', art_size = 24, tag = settings.heartbeat and 'ON' or 'OFF',
      accent = settings.heartbeat and 'good' or 'dim',
      subtitle = 'Share your character and zone every ' .. tostring(settings.heartbeat_interval) .. 's.',
      action = { id = 'cmd:heartbeat', label = settings.heartbeat and 'Turn off' or 'Turn on' },
    }
    local correction = roster_lib.describe(roster_adjustment)
    rows[#rows + 1] = {
      title = 'Attendance: include/exclude players', art = 'setting-quill', art_size = 24, tag = correction and 'SET' or 'NONE',
      accent = correction and 'info' or 'dim',
      subtitle = correction or 'Optional adjustments for players outside your alliance.',
      action = { id = 'board:corrections', label = 'Edit' },
    }
  end
  if panel_lib.pointer_alignment then
    rows[#rows+1]={title='Pointer alignment',subtitle='Correct cursor and click positions for this display',action={id='pointer:align',label='Align pointer'},secondary_action={id='pointer:reset',label=window_armed and window_armed.action=='pointer:reset' and 'Confirm reset' or 'Reset'}}
  end
  rows[#rows + 1] = { kind = 'header', title = 'Diagnostics' }
  rows[#rows+1]={title='Network',action={id='board:network',label='Timing'},tag='INFO'}
  rows[#rows+1]={title='Results',tag='INFO',art='setting-diagnostic',subtitle='Recent output, stored only for this session',action={id='board:results',label='Open'}}
  rows[#rows + 1] = {
    title = 'Connection status', art = 'setting-connection', art_size = 24, tag = 'INFO', accent = 'info',
    subtitle = 'local config and the last ingest result',
    action = { id = 'cmd:status', label = 'Show' },
  }
  rows[#rows + 1] = {
    title = 'Self test', art = 'setting-diagnostic', art_size = 24, tag = 'TEST', accent = 'dim',
    subtitle = 'checks everything that works without the network',
    action = { id = 'cmd:selftest', label = 'Run' },
  }
  return rows
end

window_rows_for = function(tab, tier)
  if board_view=='attendance' then return host.ui_tools.attendance.rows() end
  if board_view=='network' then
    return {{kind='pagehead',title='Network timing',actions={{id='settings',label='Back'}}},
      {kind='banner',title=https and https.last_ms and ('Last request: '..https.last_ms..' ms') or 'No HTTPS request measured yet',
        subtitle=https and https.max_ms and ('Slowest: '..https.max_ms..' ms / '..https.request_count..' requests this session') or 'Timing is recorded locally after a request finishes.'},
      {kind='banner',title='Network waits run between frames',subtitle='Encrypted DNS and network waits run between frames. TLS still uses CPU.'}}
  end
  if board_view=='notifications' then
    if not host.ui_tools.notice_preferences then return host.ui_tools.notification_rows(),'No notifications.' end
    return host.ui_tools.preference_rows(settings),'No notification preferences.'
  end
  if board_view == 'standings' and tier=='member' then
    local rows={{kind='header',title='DKP standings'},
      {title='Back to the linkshell',tag='BACK',action={id='board:hub',label='Back'}}}
    rows[#rows+1]={kind='choices',compact=true,options={}}
    local wallets=hud_state.dkp and hud_state.dkp.wallets or {}
    local selected=host.ui_tools.draft.pool
    for _,wallet in ipairs(wallets) do
      rows[#rows].options[#rows[#rows].options+1]={id='standpool:'..wallet.poolName,label=wallet.poolName,selected=selected==wallet.poolName or ((not selected or selected=='') and hud_state.standings and hud_state.standings.poolName==wallet.poolName)}
    end
    if #wallets==0 then rows[#rows+1]={kind='toolbar',title='Load named wallets',actions={{id='cmd:dkp',label='Load wallets'}}} end
    rows[#rows+1]={kind='toolbar',actions={{id='tools:standings',label='Refresh standings'}}}
    if hud_state.standings_error then rows[#rows+1]={kind='banner',title='Standings unavailable',subtitle=hud_state.standings_error,accent='bad'} end
    if hud_state.standings then
      rows[#rows+1]={kind='toolbar',title='Pool: '..safe_str(hud_state.standings.poolName,'Default')}
      rows[#rows+1]={kind='columns',columns={0.15,0.6,0.25},cells={'Rank','Member','DKP'}}
      for _,entry in ipairs(hud_state.standings.rows or {}) do
        rows[#rows+1]={kind='record',columns={0.15,0.6,0.25},cells={tostring(entry.rank or ''),safe_str(entry.name,'Unknown'),tostring(entry.dkp or 0)}}
      end
      if #(hud_state.standings.rows or {})==0 then rows[#rows+1]={kind='banner',title='No standings yet',subtitle=hud_state.standings.poolName or ''} end
    elseif not hud_state.standings_error then
      rows[#rows+1]={kind='text',text='Choose a wallet to load its standings, or refresh the default wallet.'}
    end
    return rows
  end
  if board_view == 'connection' then
    local rows={{kind='header',title='Connect your character'},
      {title='Back',tag='BACK',action={id='board:hub',label='Back'}},
      {title='Get a website pairing code',tag='LINK',art='claim',action={id='setup:open',label='Open'}}}
    field_rows(rows,'setup.code','Code',setup_draft.code,'Paste your website pairing code')
    if host.ui_tools.pair_feedback then rows[#rows+1]={kind='text',text=host.ui_tools.pair_feedback} end
    rows[#rows+1]={title=setup_draft.code~='' and 'Link this character' or 'Paste the code first',tag='LINK',art='claim',action=setup_draft.code~='' and {id='setup:go',label='Link',variant='primary'} or nil}
    if tier=='guest' then
      rows[#rows+1]={title='Use party finder without an account',tag='LFG',art='pennant',subtitle='Creates an unverified character identity for public listings',action={id='tools:world',label='Connect'}}
    else
      rows[#rows+1]={title='Claim an unlinked identity on the website',tag='LINK',art='claim',subtitle='Get a one-use claim code for your existing public identity',action={id='tools:claim',label='Get code'}}
    end
    return rows
  end
  if board_view == 'results' then return host.ui_tools.results(), 'No results yet.' end
  if tier == 'member' and board_view == 'macros' then
    local reviewing=window_armed and window_armed.action=='tools:pull'
    local rows={{kind='header',title='Macro books'},
      {title='From game to website',art='macrobook',subtitle='Reads changed local books.',action={id='cmd:macros',label='Upload books'}},
      {kind='header',title='From website to game'}}
    field_rows(rows,'tools.book','Active book',host.ui_tools.draft.book,'Current in-game book number (1-20)')
    if host.ui_tools.macro_feedback then rows[#rows+1]={kind='text',text=host.ui_tools.macro_feedback} end
    rows[#rows+1]={kind='text',text=reviewing and ('Review: write pending website edits to local macro files. Active book '..host.ui_tools.draft.book..' is excluded. Backups are kept.') or 'Downloads write local macro files. Enter the active book to protect it.'}
    rows[#rows+1]={kind='toolbar',actions=reviewing and {{id='tools:pull-cancel',label='Cancel review'},{id='tools:pull',label='Confirm download',variant='primary'}} or {{id='tools:pull',label='Review download',variant='primary'}}}
    rows[#rows+1]={kind='toolbar',actions={{id='board:results',label='Transfer history'}}}
    return rows
  end
  if tier == 'member' and board_view == 'reporting' then
    local event=hud_state.event or {}
    local capture=event.lastSnapAtMs and ((event.snapOk and 'Last capture accepted: ' or 'Last capture failed: ')..os.date('%H:%M:%S',math.floor(event.lastSnapAtMs/1000))..(event.snapReason and ('. '..event.snapReason) or '')) or nil
    if (host.ui_tools.attendance.capture_at or 0)>=(event.lastSnapAtMs or 0) and host.ui_tools.attendance.capture_feedback then capture=host.ui_tools.attendance.capture_feedback end
    return host.ui_tools.reporting_rows(settings,roster_lib.describe(roster_adjustment),{linked=not is_unconfigured(),active=host.ui_tools.attendance.capture_target(),capture=capture})
  end
  if tier == 'member' and board_view == 'corrections' then
    local rows={{kind='header',title='Attendance adjustments'},
      {title='Back to settings',tag='BACK',action={id='board:hub',label='Back'}},
      {kind='banner',title='Include extra attendees or exclude players',
       subtitle='Separate names with commas or spaces. Leave a field blank for nobody.'}}
    field_rows(rows,'tools.include','Include',host.ui_tools.draft.include,'Example: Blade, Pipiri')
    field_rows(rows,'tools.exclude','Exclude',host.ui_tools.draft.exclude,'Example: Altname')
    rows[#rows+1]={kind='banner',title='Future manual and automatic captures only',subtitle='Cleared on reload. Added names are marked as manually asserted.'}
    rows[#rows+1]={kind='banner',title=host.ui_tools.draft.roster_feedback or (roster_lib.describe(roster_adjustment) or 'No adjustments active'),subtitle='Does not rename players, change your party, or edit past attendance.'}
    rows[#rows+1]={kind='actions',actions={{id='tools:reset',label='Clear'},{id='tools:correct',label='Save adjustments'}}}
    return rows
  end
  if tab == 'home' then
    return home_rows(tier), 'Nothing needs you.'
  elseif tab == 'lfg' then
    return pf_rows('LFG'), 'Nobody is looking for a group. Refresh to check.'
  elseif tab == 'lfm' then
    if board_view == 'statics' then
      local out = view.statics_rows()
      table.insert(out, 2, {
        title = 'Back to the board', tag = 'BACK', accent = 'dim',
        subtitle = 'parties recruiting right now',
        action = { id = 'board:hub', label = 'Back' },
      })
      return out
    end
    return pf_rows('LFM'), 'No parties are recruiting. Refresh to check.'
  elseif tab == 'shells' then
    return shell_rows(), 'No linkshells fetched yet. Refresh to look.'
  elseif tab == 'auctions' then
    return auction_rows(), hud_state.auctions and 'No auctions are open.' or 'Auctions not fetched. Use Refresh to try again.'
  elseif tab == 'windows' then
    return window_rows(), 'No HNM windows tracked.'
  elseif tab == 'me' then
    return me_rows(tier), 'Nothing to show.'
  elseif tab == 'shell' then
    return shell_rows_tab(), 'Nothing to show.'
  elseif tab == 'settings' then
    return settings_rows(tier), 'Nothing to show.'
  end
  return {}, 'Nothing here.'
end

--- Switch the window's theme, or list what is available. Purely local: a colour choice, saved to
--- your own settings file, that nothing else in the addon or on the server ever sees.
local function do_theme(name)
  if not name or name == '' then
    local current = settings.theme or window_lib.DEFAULT_THEME
    log('themes (in use: ' .. tostring(current) .. '):')
    for _, id in ipairs(window_lib.theme_names()) do
      local theme = window_lib.theme(id)
      log('  ' .. id .. (id == current and '   <- in use' or '') .. '   ' .. theme.label)
    end
    log('  //lootryx theme <name>')
    return
  end
  name = tostring(name):lower()
  if not window_lib.THEMES[name] then
    log('no theme called "' .. name .. '". //lootryx theme lists them.')
    return
  end
  settings.theme = name
  local saved = save_settings()
  log('theme: ' .. window_lib.theme(name).label)
  warn_if_not_saved(saved)
  window_refresh()
end

--[[
  Enter in a text box, and Escape out of one.

  Enter commits what was typed to the draft rather than sending anything: a drop still needs the
  second box filled and the Report button confirmed. Nothing here reports outward, which is
  deliberate, because Enter is the key somebody hits reflexively.
]]
field_submit = function(value, id)
  value = tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if id:sub(1,11)=='attendance.' then
    host.ui_tools.attendance.set_field(id:sub(12),value)
  elseif id == 'hnm.search' then
    host.ui_tools.hnm.set_search(value);window_page=1
  elseif id == 'surface.search' then
    host.ui_tools.surfaces.search[window_tab]=value;window_page=1
  elseif id == 'tools.pool' then
    host.ui_tools.draft.pool=value
  elseif id == 'tools.ceiling' then
    host.ui_tools.draft.ceiling=value;window_armed=nil
  elseif id == 'tools.jobs' then
    host.ui_tools.draft.jobs=value:upper()
    window_armed=nil
  elseif id == 'tools.book' then
    host.ui_tools.draft.book=value;window_armed=nil;host.ui_tools.macro_feedback=nil
  elseif id == 'tools.include' or id == 'tools.exclude' then
    host.ui_tools.draft[id:sub(7)]=value
    host.ui_tools.draft.roster_feedback=nil
  elseif id == 'drop.item' then
    drop_draft.item = value
  elseif id == 'drop.winner' then
    drop_draft.winner = value
  elseif id == 'pf.character' then
    host.ui_tools.recruitment.character=value
  elseif id == 'pf.comment' then
    pf_draft.comment = value;pf_draft.error=nil
  elseif id == 'pf.capacity' then
    pf_draft.maxSize=value;pf_draft.error=nil
  elseif id == 'bid.amount' then
    auction_draft.amount = value;auction_draft.error=nil;window_armed=nil
  elseif id == 'tod.time' then
    auction_draft.killed_at = value:match('^%s*(.-)%s*$')
    hud_state.tod_feedback = nil
    window_armed = nil
  elseif id == 'tod.target' then
    auction_draft.target = value
    hud_state.tod_feedback = nil
  elseif id == 'auction.item' then
    if auction_draft.selected then auction_draft.selected = {invalid=true} end
    auction_draft.item = value
  elseif id == 'setup.code' then
    -- Codes carry no spaces, and a paste out of a browser very often brings one along.
    setup_draft.code = value:gsub('%s', '');host.ui_tools.pair_feedback=nil
  elseif id == 'wish.item' then
    wish_draft.item = value;wish_draft.editing=false;wish_draft.priority=2;host.ui_tools.draft.ceiling='off';window_armed=nil
  elseif id == 'item.name' then
    hud_state.item_draft = value
  end
  window_refresh()
end

field_cancel = function()
  window_refresh()
end

--[[
  Leave a text box, keeping what is in it.

  Blur on its own only drops focus; it does not write anything back, so every click outside a box
  threw the typing away. That is the wrong default by a mile: a person filling in a form clicks
  between its fields constantly, and losing a line of text for it is indistinguishable from the
  addon being broken.

  Enter and clicking away now do the same thing, which is what a text box everywhere else does.
  Escape is the one that discards, and it says so.
]]
local function field_commit()
  local id = field_lib.id()
  if not id then
    return
  end
  local value = field_lib.value()
  if host.ui_tools.local_navigation and host.jobs and host.jobs.busy() then
    host.ui_tools.pending_drafts=host.ui_tools.pending_drafts or {}
    host.ui_tools.pending_drafts[id..':'..window_tab]={id=id,value=value,tab=window_tab}
  end
  field_lib.blur()
  field_submit(value, id)
end

--- What a click does. Every branch either changes what is displayed, runs a read the player could
--- have typed, prints a command for them to run, or (Confirm on an auction, and only there) places
--- a bid the player has already confirmed once. All of it goes to the Lootryx API over HTTP.
--- Nothing here reaches the GAME server, and nothing here automates any gameplay action.
host.ui_tools.job_action=function(id)
  if id == 'jobs:preview' then
    local ok,raw=pcall(host.read_jobs or function() return client_reader.player() end)
    local observation=ok and client_state.job_observation(raw)
    host.ui_tools.job_preview=observation and {name=self_name(),observation=observation} or nil
    host.ui_tools.job_feedback=observation and 'Review the observed levels, then sync.' or 'No reliable levels available. Log in and retry.'
    window_refresh();return
  elseif id == 'jobs:sync' then
    local draft=host.ui_tools.job_preview
    if not draft or draft.name~=self_name() then host.ui_tools.job_feedback='Character changed. Preview again.';window_refresh();return end
    local status,response=post(settings.api_base .. '/myjobs',json_encode({observation=draft.observation,characterName=draft.name}))
    local ok,decoded=pcall(json.decode,response)
    if status==200 and ok and type(decoded)=='table' and type(decoded.current)=='table' then
      hud_state.observed_jobs=decoded.current;hud_state.myjobs=decoded.declaration
      host.ui_tools.job_preview=nil;host.ui_tools.job_feedback='Synced successfully. Plans unchanged.'
    else host.ui_tools.job_feedback='Sync failed. Your preview is kept; retry Sync.';log(ingest_errors.describe_failure(status,response)) end
    window_refresh();return
  end
end
host.ui_tools.auction_tick=function(now)
  do
    host.ui_tools.auction_expired=host.ui_tools.auction_expired or {}
    for _,a in ipairs(hud_state.auctions or {}) do
      local deadline_key=tostring(a.id)..':'..tostring(a.endsAtMs)
      if type(a.id)=='string' and safe_num(a.endsAtMs,0)<=now*1000 and not host.ui_tools.auction_expired[deadline_key] then
        host.ui_tools.auction_expired[deadline_key]=true
        host.ui_tools.notify(safe_str(a.itemName,'Auction')..': bidding timer ended. Awaiting server settlement.',settings.notify_auction_deadline~=false,log)
      end
    end
  end
end
function say.do_refresh_live_auctions(now)
  if hud_state.you and type(hud_state.you.canRead)=='table' and hud_state.you.canRead.auctions==false then return false end
  if settings.live_auctions==false or settings.shell_slug=='' or is_unconfigured() then return false end
  -- New-auction discovery must continue even when no auction is currently followed.
  if settings.notify_new_auctions==false and #(hud_state.auctions or {})==0 and not (panel_lib.visible() and window_tab=='auctions') then return false end
  if not host.ui_tools.auction_checked then host.ui_tools.auction_checked=now;return false end
  if now-(host.ui_tools.auction_checked or now)<math.max(10,tonumber(settings.auction_refresh_interval) or 15)*(host.ui_tools.auction_backoff or 1) then return false end
  host.ui_tools.auction_checked=now
  local ok=do_auctions(true)
  host.ui_tools.auction_backoff=ok and 1 or math.min(8,(host.ui_tools.auction_backoff or 1)*2)
  return true
end
host.ui_tools.pf_composer=loadfile(host.addon_path..'lib/pf-composer.lua')()
host.ui_tools.detail_layout=loadfile(host.addon_path..'lib/detail-layout.lua')()
host.ui_tools.hnm=loadfile(host.addon_path..'lib/hnm-view.lua')().new()
host.ui_tools.surfaces=loadfile(host.addon_path..'lib/surfaces.lua')()
host.ui_tools.present=function(tab,tier,rows,freshness)
  local search={}
  local query=host.ui_tools.surfaces.search[tab] or ''
  if tab=='lfg' or tab=='lfm' or tab=='shells' then
    field_rows(search,'surface.search','Search',query,'Name, activity or comment')
    if field_lib.id()=='surface.search' then query=field_lib.value() end
  end
  if (tab=='home' or tab=='me') and (host.ui_tools.observation_name~=self_name() or os.time()-(host.ui_tools.observation_at or 0)>=5) then
    local ok,raw=pcall(host.read_jobs or function() return client_reader.player() end)
    host.ui_tools.observation=ok and client_state.job_observation(raw) or nil
    host.ui_tools.observation_at=os.time();host.ui_tools.observation_name=self_name()
  end
  if tab=='windows' then
    rows=host.ui_tools.hnm.rows({targets=hud_state.windows,world=tostring(settings.world),now_ms=os.time()*1000,freshness=freshness,
      search_value=field_lib.id()=='hnm.search' and field_lib.value() or nil,
      search_display=field_lib.id()=='hnm.search' and field_lib.display() or nil,search_focused=field_lib.id()=='hnm.search'},rows)
  end
  return host.ui_tools.surfaces.present({detail_layout=host.ui_tools.detail_layout,hnm_presented=tab=='windows',tab=tab,tier=tier,hud=hud_state,name=self_name() or 'Adventurer',now=os.time(),
    world=tostring(settings.world),shell=tier=='member' and shell_label() or 'Not linked',board=board_view,
    focused=board_view~=nil or drop_draft.open or (tab=='auctions' and (auction_draft.open or auction_draft.bid_id)) or host.ui_tools.pf_focused,
    observation=host.ui_tools.observation,preview=host.ui_tools.job_preview and host.ui_tools.job_preview.name==self_name() and host.ui_tools.job_preview or nil,feedback=host.ui_tools.job_feedback,
    jobs_rows=tab=='me' and tier=='member' and view.myjobs_rows() or nil,freshness=freshness,search_row=search[1],search_value=query,role_matches=host.ui_tools.pf_composer.matches},rows)
end
host.ui_tools.chat_prefill=loadfile(host.addon_path..'lib/chat-prefill.lua')()
host.ui_tools.recruitment=loadfile(host.addon_path..'lib/recruitment.lua')().new({
  composer=host.ui_tools.pf_composer,
  request=function(path,body)
    local status,response=post(settings.api_base..path,json_encode(body))
    if status~=200 then return nil,ingest_errors.describe_failure(status,response) end
    local ok,reply=pcall(json.decode,response)
    if not ok or type(reply)~='table' then return nil,'Could not read recruitment response.' end
    return reply
  end,
  observe_listing=function(d) if host.ui_tools.activity then host.ui_tools.activity.listing(d) end end,
  observe_invites=function(list) if host.ui_tools.activity then host.ui_tools.activity.invitations(list) end end,
  contact_field=function(rows,name) field_rows(rows,'pf.character','Character',name,'Actual FFXI character name, not account name') end,
  prefill=function(action,name)
    field_lib.blur()
    local ok,message=host.ui_tools.chat_prefill.prepare(host,action,name)
    if host.ui_tools.chat_prefill.pending then host.ui_tools.chat_prefill.pending.owner=self_name() end
    if ok then log(message) end
    return ok,message
  end,
  edit=function(d)
    host.ui_tools.recruitment.action('pf:back')
    pf_draft.edit_id=d.id;pf_draft.category=d.category or 'EXP';pf_draft.role=d.role or 'ANY'
    pf_draft.maxSize=d.maxSize;pf_draft.roleSlots=d.roleSlots
    pf_draft.needed={[pf_draft.role]=true};pf_draft.comment=d.comment or '';pf_draft.error=nil;pf_draft.open=true
    window_tab=d.mode=='LFG' and 'lfg' or 'lfm';window_refresh()
  end,
  recruit=function() host.ui_tools.recruitment.action('pf:back');window_tab='lfg';do_pf_list();window_refresh() end,
  create=function() host.ui_tools.recruitment.action('pf:back');pf_draft.edit_id=nil;pf_draft.open=true;window_tab='lfm';window_refresh() end,
  listings=function() return hud_state.pf and hud_state.pf.listings or {} end,
  zone_name=function(id)
    local ok,res=pcall(host.resources)
    local zone=ok and type(res)=='table' and res.zones and res.zones[id]
    return type(zone)=='table' and (zone.en or zone.name) or nil
  end,
  party=function() return client_reader.members() end,
  self_name=function() return self_name() end,
  refresh=function() do_pf_list() end,
  redraw=function() window_page=1;window_refresh() end,
})
host.ui_tools.attendance=loadfile(host.addon_path..'lib/attendance.lua')().new({
  request=function(path,body)
    local status,response=post(settings.api_base..path,json_encode(body))
    if status~=200 then return nil,ingest_errors.describe_failure(status,response) end
    local ok,reply=pcall(json.decode,response)
    if not ok or type(reply)~='table' then return nil,'Could not read attendance response. Refresh and try again.' end
    return reply
  end,
  snapshot=function() return build_snapshot('checkin') end,
  field=field_rows,
  now=os.time,
  opened=function() host.ui_tools.attendance_opened=true end,
  enabled=function() return settings.live_attendance~=false and not is_unconfigured() and self_name()~=nil end,
  interval=function() return math.max(15,tonumber(settings.attendance_refresh_interval) or 30) end,
  notify=function(message) host.ui_tools.notify(message,settings.notify_checkin~=false,log,{id='attendance:open',label='Attendance'}) end,
  redraw=function(reset_page)
    if reset_page~=false then window_page=1 end
    if board_view=='attendance' or reset_page~=false then window_refresh() end
  end,
})
host.ui_tools.make_activity=function()
  return loadfile(host.addon_path..'lib/activity-notices.lua')().new({
    name=self_name,party=function() return client_reader.members() end,
    listings=function() return hud_state.pf and hud_state.pf.listings or {} end,
    request=host.ui_tools.recruitment.request,
    interval=function() return math.max(15,tonumber(settings.recruitment_refresh_interval) or 30) end,
    enabled=function() return settings.live_recruitment~=false and not is_unconfigured() and self_name()~=nil end,
    notify=function(kind,message,id)
      local target=id and ('listing:'..id) or (kind=='notify_party' and 'party' or 'invites')
      host.ui_tools.notify(message,settings[kind]~=false,log,{id='activity:'..target,label='Open'})
    end,
    updated=function(d)
      if host.ui_tools.recruitment.detail and host.ui_tools.recruitment.detail.id==d.id then host.ui_tools.recruitment.detail=d;window_refresh() end
    end,
  })
end
host.ui_tools.activity=host.ui_tools.make_activity()
host.ui_tools.activity_name=self_name()
host.ui_tools.local_activity=function(now)
  if host.ui_tools.activity_name~=self_name() then
    host.ui_tools.activity_name=self_name();host.ui_tools.activity=host.ui_tools.make_activity()
    host.ui_tools.attendance.reset()
    if host.ui_tools.chat_prefill.pending and host.ui_tools.chat_prefill.pending.owner~=self_name() then host.ui_tools.chat_prefill.pending=nil end
  end
  host.ui_tools.activity.party(now)
  local ok,message=host.ui_tools.chat_prefill.poll(host,function(action,name)
    if action~='kick' then return true end
    for _,member in ipairs(client_reader.members()) do if member.own_party and member.name==name then return true end end
    return false
  end)
  if ok~=nil then host.ui_tools.recruitment.feedback=message;log(message);window_refresh() end
end
function say.do_refresh_recruitment(now) return host.ui_tools.activity.poll(now) end
function say.do_refresh_attendance(now) return host.ui_tools.attendance.poll(now) end
host.ui_tools.board_key=function() return board_view end
host.ui_tools.reset_connection=function()
  for key in pairs(hud_state) do hud_state[key]=nil end
  snapshot_queue.entries={}
  last_auction_list={}
  roster_adjustment=roster_lib.new()
  host.ui_tools.history={}
  host.ui_tools.clear_notices();host.ui_tools.export_feedback=nil
  host.ui_tools.export_path=nil;host.ui_tools.heartbeat_status=nil;host.ui_tools.heartbeat_feedback=nil;host.ui_tools.heartbeat_last_success=nil
  host.ui_tools.wish_feedback=nil;host.ui_tools.post_error=nil;host.ui_tools.bid_error=nil
  host.ui_tools.detail_layout.relink=false
  pf_draft.edit_id=nil;pf_draft.open=false;pf_draft.comment='';pf_draft.error=nil
  pf_draft.roleSlots=nil;pf_draft.maxSize=nil;pf_draft.counted=false
  host.ui_tools.find_pages={};host.ui_tools.last_find=nil
  host.ui_tools.activity=host.ui_tools.make_activity()
  host.ui_tools.attendance.reset()
  host.ui_tools.attendance_opened=nil
  host.ui_tools.chat_prefill.pending=nil
  host.ui_tools.job_preview=nil;host.ui_tools.job_feedback=nil
  host.ui_tools.recruitment.detail=nil;host.ui_tools.recruitment.detail_id=nil;host.ui_tools.recruitment.return_detail=nil;host.ui_tools.recruitment.invites=nil;host.ui_tools.recruitment.feedback=nil;host.ui_tools.recruitment.character='';host.ui_tools.recruitment.party_only=false
  host.ui_tools.refreshes={}
  host.ui_tools.auction_results={};host.ui_tools.auction_seen={};host.ui_tools.auction_followed={};host.ui_tools.auction_expired={};host.ui_tools.auction_checked=nil
  window_armed=nil
  board_view=nil
  auction_draft={open=false,item='',pool=true,handle=auction_draft.handle}
  drop_draft={open=false,item='',winner=''}
  wish_draft.item=''
  host.ui_tools.draft={book='',include='',exclude=''}
  field_lib.blur()
end
host.ui_tools.setup_steps=print_setup_steps
host.ui_tools.claim=do_claim
host.ui_tools.unconfigured=is_unconfigured
host.ui_tools.save_roster=function()
  local adjustment,err=roster_lib.from_fields(host.ui_tools.draft.include,host.ui_tools.draft.exclude)
  if adjustment then roster_adjustment=adjustment end
  host.ui_tools.draft.roster_feedback=err or ('Saved: '..(roster_lib.describe(roster_adjustment) or 'no adjustments'))
end
host.ui_tools.load_roster=function()
  host.ui_tools.draft.include=table.concat(roster_adjustment.added, ', ')
  host.ui_tools.draft.exclude=table.concat(roster_adjustment.removed, ', ')
  host.ui_tools.draft.roster_feedback=nil
end
host.ui_tools.wish_action=function(id)
  if id:sub(1,10)=='wish:edit:' then
    wish_draft.item=id:sub(11);wish_draft.editing=true;window_armed=nil;host.ui_tools.wish_feedback=nil
    for _,entry in ipairs(hud_state.wishlist or {}) do if entry.itemName==wish_draft.item then wish_draft.priority=entry.priority or 2;host.ui_tools.draft.ceiling=entry.maxDkp and tostring(entry.maxDkp) or 'off' end end
    window_refresh();return true
  elseif id:sub(1,13)=='wishpriority:' then
    wish_draft.priority=tonumber(id:sub(14)) or 2;window_armed=nil;window_refresh();return true
  elseif id=='wish:cancel' then wish_draft.item='';wish_draft.editing=false;window_armed=nil;window_refresh();return true
  elseif id=='wish:save' or id=='wish:add' then
    id='wish:save'
    local raw=(host.ui_tools.draft.ceiling or ''):lower();if raw=='' then raw='off' end
    local amount=tonumber(raw)
    if wish_draft.item=='' or (raw~='off' and (not amount or amount<1 or amount~=math.floor(amount))) then
      host.ui_tools.wish_feedback='Select an item and enter a whole positive DKP pre-bid, or off to clear it.';window_armed=nil;window_refresh();return true
    end
    local signature=wish_draft.item..':'..tostring(wish_draft.priority or 2)..':'..raw
    if not window_armed or window_armed.action~=id or window_armed.offer~=signature then window_armed={action=id,offer=signature};window_refresh();return true end
    window_armed=nil
    local body=json_encode({action='add',itemName=wish_draft.item,priority=wish_draft.priority or 2,maxDkp=amount})
    if raw=='off' then body=body:sub(1,-2)..',"maxDkp":null}' end
    local status,response=post(settings.api_base..'/wishlist',body)
    host.ui_tools.wish_feedback=status==200 and ('Saved settings for '..wish_draft.item) or ingest_errors.describe_failure(status,response)
    if status==200 then fetch_wishlist(true);wish_draft.item='';wish_draft.editing=false end
    window_refresh();return true
  end
  return false
end
host.ui_tools.run_macro=function(args)
  local before=host.ui_tools.history_sequence or 0
  do_macros(args)
  local messages={}
  for i=math.max(1,#host.ui_tools.history-(host.ui_tools.history_sequence or 0)+before+1),#host.ui_tools.history do
    local line=host.ui_tools.history[i]
    if i==#host.ui_tools.history or line:find('failed',1,true) or line:find('cannot',1,true) or line:find('NOT written',1,true) then messages[#messages+1]=line end
  end
  host.ui_tools.macro_feedback=#messages>0 and table.concat(messages,' ') or 'Transfer finished. See Transfer history for details.'
end
host.ui_tools.plan_current=function()
  local main=self_jobs();if main then host.ui_tools.draft.jobs=main end
  return main
end
local function window_action(id)
  local restore_page
  if id:sub(1,6)~='focus:' and id:sub(1,5)~='pick:' then field_commit() end
  if id:sub(1,6)=='focus:' and field_lib.id() and field_lib.id()~=id:sub(7) then field_commit() end
  if id=='wish:refresh' then do_wishlist({});window_refresh();return end
  if id:sub(1,13)=='notices:open:' then
    id=host.ui_tools.open_notice(id:sub(14))
    if not id then window_refresh();return end
  end
  if host.ui_tools.wish_action(id) then return end
  if id:sub(1,9)=='pf:count:' then
    local role,delta=id:match('^pf:count:([A-Z]+):(-?%d+)$')
    if role then host.ui_tools.pf_composer.adjust(pf_draft,role,tonumber(delta));pf_draft.error=nil end
    window_refresh();return
  end
  -- An open dropdown closes on anything that is not itself or one of its own choices, so it can
  -- never be left hanging over the rows underneath it.
  if id:sub(1, 5) ~= 'menu:' and id:sub(1, 4) ~= 'set:' then
    open_menu = nil
  end
  -- Clicking anywhere that is not a text box, or its own suggestion list, hands the keyboard back.
  -- A box that kept focus while you clicked off to another tab would eat the keys you then used to
  -- move, with nothing on screen still showing a caret to explain it.
  if id=='cmd:snap' then id='attendance:open' end
  if id=='attendance:website' then
    local eventId=host.ui_tools.attendance.capture_target()
    open_in_browser('/shells/'..settings.shell_slug..'/events'..(eventId and ('/'..eventId) or ''));return
  end
  if id=='attendance:back' then
    host.ui_tools.attendance.cancel_review();board_view=nil;window_tab='shell';window_page=1;window_refresh();return
  end
  if id:sub(1,11)=='attendance:' then
    window_tab='shell';board_view='attendance'
    host.ui_tools.attendance.action(id);window_page=1;window_refresh();return
  end
  if id:sub(1,4)=='nav:' or id:sub(1,4)=='tab:' then
    host.ui_tools.attendance.cancel_review()
    host.ui_tools.find_pages=host.ui_tools.find_pages or {}
    if (window_tab=='lfg' or window_tab=='lfm' or window_tab=='shells') and not board_view then
      host.ui_tools.last_find=window_tab
      if not host.ui_tools.pf_focused then host.ui_tools.find_pages[window_tab]=window_page end
    end
    if id=='nav:lfg' then id='nav:'..(host.ui_tools.last_find or 'lfg') end
    if id:sub(5)==window_tab and not board_view and not host.ui_tools.pf_focused then window_refresh();return end
    restore_page=host.ui_tools.find_pages[id:sub(5)]
    host.ui_tools.recruitment.leave()
  end
  -- Anything that is not a second press of the armed control disarms it, including arming a
  -- different one: there is never more than one live confirmation.
  if not (window_armed and window_armed.action == id) then
    window_armed = nil
  end
  local hnm_intent=host.ui_tools.hnm.action(id)
  if hnm_intent then
    if hnm_intent.kind=='setup' then open_in_browser('/shells/'..tostring(settings.shell_slug)..'/hnm?tab=manage')
    elseif hnm_intent.kind=='form' and hnm_intent.target then auction_draft.target=hnm_intent.target
    elseif hnm_intent.kind=='current' then
      local ok,name=pcall(host.read_target or function() return nil end)
      if ok and type(name)=='string' and name~='' then auction_draft.target=name
      else log('No current target available. Select a target in-game or enter its name.') end
    end
    host.ui_tools.surfaces.tod_open=host.ui_tools.hnm.open
    window_page=1;window_refresh();return
  end
  if id=='surface:clear' or id=='surface:clearsearch' then field_lib.blur() end
  if host.ui_tools.surfaces.action(id,window_tab) then window_page=1;window_refresh();return end
  if id=='pointer:align' and panel_lib.pointer_alignment then panel_lib.pointer_alignment.start();window_refresh();return end
  if id=='pointer:reset' and panel_lib.pointer_alignment then
    if window_armed and window_armed.action==id then panel_lib.pointer_alignment.reset();window_armed=nil
    else window_armed={action=id};log('Reset saved pointer alignment? Click Confirm reset to continue.') end
    window_refresh();return
  end
  if id=='tools:plans-cancel' then window_armed=nil;window_refresh();return end
  if id=='tools:jobs' then
    local jobs={};for code in (host.ui_tools.draft.jobs or ''):gmatch('%S+') do jobs[#jobs+1]=code:upper() end
    local decl=hud_state.myjobs or {}
    if #jobs==0 or #jobs>3 then host.ui_tools.plan_feedback='Enter one to three job abbreviations in priority order.';window_refresh();return end
    if decl.locked then host.ui_tools.plan_feedback='Your job plans are locked. Ask an officer.';window_refresh();return end
    if type(decl.lockDays)~='number' then host.ui_tools.plan_feedback='Refresh job plans to read the configured lock before saving.';window_refresh();return end
    local signature=table.concat(jobs,' ')
    if window_armed and window_armed.action==id and window_armed.offer==signature then window_armed=nil;do_myjobs(jobs)
    else
      local old={safe_str(decl.declaredMain,'-'),safe_str(decl.declaredSecondary,'-'),safe_str(decl.declaredTertiary,'-')}
      local proposed={jobs[1] or old[1],jobs[2] or old[2],jobs[3] or old[3]}
      local changed=table.concat(old,' / ')~=table.concat(proposed,' / ')
      window_armed={action=id,offer=signature,before=table.concat(old,' / '),after=table.concat(proposed,' / '),effect=changed and ('Lock: '..decl.lockDays..' days.') or 'Unchanged: no new lock.',summary='Was: '..table.concat(old,' / ')..'. New: '..table.concat(proposed,' / ')..'. '..(changed and ('Lock: '..decl.lockDays..' days.') or 'Unchanged: no new lock.')..' No DKP charge.'}
      host.ui_tools.plan_feedback=nil
    end
    window_refresh();return
  end
  if id:sub(1,10)=='standpool:' then host.ui_tools.draft.pool=id:sub(11);do_standings({host.ui_tools.draft.pool});window_refresh();return end
  if id=='connection:relink' then host.ui_tools.detail_layout.relink=true;window_refresh();return end
  if id=='connection:cancel' then host.ui_tools.detail_layout.relink=false;window_refresh();return end
  if id:sub(1,9)=='boardweb:' then
    local paths={statics='/find/static-finder',bounties='/dkp/bounties',bank='/treasury/bank',loot='/loot'}
    local path=paths[id:sub(10)];if path then open_in_browser('/shells/'..settings.shell_slug..path) end;return
  end
  if id=='tools:standings' then
    do_standings({host.ui_tools.draft.pool or ''});board_view='standings';window_refresh();return
  end
  if id=='tools:world' then
    if host.ui_tools.unconfigured() then do_setup({'world'}) end
    window_refresh();return
  end
  if id=='tools:claim' then host.ui_tools.claim();board_view='results';window_refresh();return end
  if id=='tools:prebid' then
    if window_armed and window_armed.action==id then
      window_armed=nil;do_wishlist({'max',host.ui_tools.draft.ceiling or '',wish_draft.item})
    else
      window_armed={action=id};log('Save a standing pre-bid for '..wish_draft.item..'? Click Confirm.')
    end
    window_refresh();return
  end
  if id=='tools:export' then host.ui_tools.export(host.addon_path);window_refresh();return end
  if id=='tools:open-export' then
    local path=host.ui_tools.export_path
    if path and path==host.addon_path..'lootryx-results.txt' then
      local url='file:///'..path:gsub('\\','/'):gsub('%%','%%25'):gsub(' ','%%20'):gsub('#','%%23')
      local ok,result=pcall(function() return type(host.open_url)=='function' and host.open_url(url) end)
      if not ok or result==false then host.ui_tools.export_feedback='Open the saved text file manually: '..path end
    end
    window_refresh();return
  end
  if id=='tools:clear' then host.ui_tools.history={};window_refresh();return end
  if id=='tools:reset' then
    do_roster({'clear'});host.ui_tools.draft.include='';host.ui_tools.draft.exclude='';host.ui_tools.draft.roster_feedback='No adjustments active'
    window_refresh();return
  end
  if id=='tools:correct' then
    host.ui_tools.save_roster()
    log(host.ui_tools.draft.roster_feedback);window_refresh();return
  end
  if id=='tools:pull-cancel' then window_armed=nil;host.ui_tools.macro_feedback=nil;window_refresh();return end
  if id=='tools:pull' then
    local book=tonumber(host.ui_tools.draft.book)
    if not host.ui_tools.valid_book(book) then
      host.ui_tools.macro_feedback='Choose the current in-game macro book number, 1-'..host.ui_tools.max_books..'.'
      log(host.ui_tools.macro_feedback)
    elseif window_armed and window_armed.action==id and window_armed.book==book then
      window_armed=nil;host.ui_tools.run_macro({'pull',host.ui_tools.draft.book})
    else
      host.ui_tools.macro_feedback=nil;window_armed={action=id,book=book};log('Download writes local macro files, excluding active book '..book..'. Review before confirming.')
    end
    window_refresh();return
  end
  if id:sub(1,9)=='pfdetail:' and window_tab=='home' then window_tab='lfm' end
  if id:sub(1,8)=='editbid:' and window_tab=='home' then window_tab='auctions' end
  if id:sub(1,9)=='activity:' then
    window_tab='lfm';board_view=nil
    local target=id:sub(10)
    host.ui_tools.recruitment.action(target:sub(1,8)=='listing:' and ('pfdetail:'..target:sub(9)) or (target=='party' and 'pf:party' or 'pf:inbox'))
    return
  end
  if id:sub(1,11)=='pfwithdraw:' then
    host.ui_tools.recruitment.action('pfdetail:'..id:sub(12))
    if host.ui_tools.recruitment.detail and host.ui_tools.recruitment.detail.isMine then host.ui_tools.recruitment.action('pfaction:close') end
    return
  end
  if host.ui_tools.recruitment.action(id) then return end
  if auction_draft.handle(id) then window_refresh(); return end
  -- Paging is the ONE action that must not reset the page, so it is handled before everything
  -- else and returns immediately.
  if id:sub(1, 5) == 'page:' then
    window_page = tonumber(id:sub(6)) or 1
    window_refresh()
    return
  end
  -- Everything else changes what the list is, or which list it is, so the page goes back to the
  -- first: a page number counted against one list means nothing against another, and staying on
  -- page 3 of a list that just got shorter is how you end up staring at an empty screen.
  window_page = restore_page or 1

  if id=='notices:preferences' then host.ui_tools.notice_preferences=true;host.ui_tools.notice_detail=nil
  elseif id:sub(1,14)=='notices:group:' then host.ui_tools.preference_section=id:sub(15)
  elseif id:sub(1,15)=='notices:detail:' then
    local notice=host.ui_tools.mark_read(id:sub(16));host.ui_tools.notice_detail=notice and notice.id or tonumber(id:sub(16))
  elseif id=='notices:list' then host.ui_tools.notice_detail=nil
  elseif id=='notices:clear' then host.ui_tools.clear_notices()
  elseif id=='notices:read-all' then host.ui_tools.mark_all_read()
  elseif id:sub(1,13)=='notices:read:' then host.ui_tools.mark_read(id:sub(14))
  elseif id:sub(1,7)=='notice:' then
    local key=id:sub(8)
    if key=='live_auctions' or key=='notify_new_auctions' or key=='notify_auction_results' or key=='notify_auction_deadline' or key=='live_recruitment' or key=='notify_party' or key=='notify_recruitment' or key=='notify_invites' or key=='notify_ready' or key=='live_attendance' or key=='notify_checkin' then settings[key]=settings[key]==false;save_settings() end
  elseif id=='notifications' then
    host.ui_tools.notice_preferences=false
    host.ui_tools.notice_detail=nil
    window_tab='settings';board_view='notifications'
  elseif id=='settings' then
    window_tab='settings';board_view=nil
  elseif id:sub(1, 4) == 'nav:' then
    window_tab = id:sub(5)
    board_view = nil
  elseif id:sub(1, 4) == 'tab:' then
    window_tab = id:sub(5)
    -- Clicking a tab goes to that tab, not to whatever board you were last inside on it.
    board_view = nil
  elseif id == 'close' or id == 'mini' then
    panel_lib.show(false)
    settings.window_open = false
    save_settings()
    log('window closed. //lootryx window to bring it back.')
    return
  elseif id == 'refresh' then
    if board_view=='results' or board_view=='macros' or board_view=='corrections' or board_view=='connection' or board_view=='standings' then window_refresh()
    elseif board_view=='events' then do_events()
    elseif board_view=='bank' then do_bank()
    elseif board_view=='loot' then do_loot()
    elseif board_view=='bounties' then do_bounties()
    elseif board_view=='polls' then do_polls()
    elseif board_view=='statics' then do_statics()
    elseif board_view=='wishlist' then do_wishlist({})
    elseif board_view=='myjobs' then do_myjobs({})
    elseif window_tab=='me' then do_dkp()
    elseif window_tab=='settings' or window_tab=='shell' then window_refresh()
    elseif window_tab == 'shells' then
      do_shells()
    elseif window_tab == 'auctions' then
      do_auctions(true)
    elseif window_tab == 'windows' then
      do_windows()
    else
      do_pf_list()
    end
    return
  elseif id == 'refresh_pf' then
    if window_tab=='home' then window_tab='lfg' end
    do_pf_list()
    return
  elseif id == 'refresh_shells' then
    window_tab = 'shells'
    do_shells()
    return
  elseif id:sub(1, 5) == 'vote:' then
    -- `vote:<pollId>:<optionId>`. Both travel in the id so a click cannot be answered against
    -- whichever poll happened to be on screen when the request landed.
    local rest = id:sub(6)
    local split = rest:find(':')
    if split then
      send_vote(rest:sub(1, split - 1), rest:sub(split + 1))
      window_refresh()
    end
    return
  elseif id == 'cmd:polls' then
    do_polls()
    return
  elseif id == 'cmd:statics' then
    do_statics()
    return
  elseif id == 'cmd:unseek' then
    do_unseek()
    return
  elseif id == 'cmd:myjobs' then
    do_myjobs({})
    return
  elseif id:sub(1, 4) == 'cmd:' then
    -- Every remaining command, reached by name. Each is the same call the typed command makes, so
    -- the window adds no capability: it is a shorter way to ask for what you could already ask for.
    local which = id:sub(5)
    if which == 'dkp' then
      do_dkp()
    elseif which == 'standings' then
      do_standings({})
    elseif which == 'roster' then
      do_roster({})
    elseif which == 'events' then
      do_events()
    elseif which == 'wishlist' then
      do_wishlist({})
    elseif which == 'bounties' then
      do_bounties()
    elseif which == 'loot' then
      do_loot()
    elseif which == 'bank' then
      do_bank()
    elseif which == 'snap' then
      do_snap(false)
    elseif which == 'show' then
      do_show();board_view='results'
    elseif which == 'macros' then
      host.ui_tools.run_macro({ 'push' })
    elseif which == 'status' then
      do_status();board_view='results'
    elseif which == 'selftest' then
      do_selftest();board_view='results'
    elseif which == 'auto' then
      do_auto({ settings.auto and 'off' or 'on' })
    elseif which == 'heartbeat' then
      do_heartbeat_toggle({ settings.heartbeat and 'off' or 'on' })
    elseif which == 'hud' then
      do_hud({ settings.hud_enabled and 'off' or 'on' })
    elseif which == 'openlogin' then
      settings.open_on_login = settings.open_on_login == false
      save_settings()
      log('window on login: ' .. (settings.open_on_login and 'on' or 'off'))
    elseif which == 'drop' then
      log('report a drop with: //lootryx drop <item name> <winner>')
    end
    window_refresh()
    return
  elseif id == 'post' then
    -- Opens the composer. It used to print the setup steps, on every tier, linked or not.
    host.ui_tools.recruitment.detail=nil;host.ui_tools.recruitment.detail_id=nil;host.ui_tools.recruitment.invites=nil;host.ui_tools.recruitment.feedback=nil;host.ui_tools.recruitment.party_only=false
    pf_draft.open = true;pf_draft.edit_id=nil;pf_draft.error=nil
    window_page=1
    window_refresh()
    return
  -- `board:`, not `shell:`. That prefix is already taken by `shell:<slug>`, which opens a
  -- linkshell's public page in a browser, and this branch sits above it: using it here swallowed
  -- every Open button in the directory. Caught by the test that clicks one.
  elseif id:sub(1, 6) == 'board:' then
    local which = id:sub(7)
    if which=='hub' then
      local previous=host.ui_tools.board_returns and host.ui_tools.board_returns[board_view]
      board_view=previous and previous.board or nil
      window_page=previous and previous.page or 1
      window_refresh();return
    end
    host.ui_tools.board_returns=host.ui_tools.board_returns or {}
    if which~=board_view then host.ui_tools.board_returns[which]={board=board_view,page=host.ui_tools.route_page or 1} end
    if window_tab=='home' then window_tab='shell' end
    if which=='wishlist' or which=='macros' or which=='myjobs' or which=='connection' then window_tab='me'
    elseif which=='events' or which=='standings' or which=='more' then window_tab='shell' end
    if which=='myjobs' then host.ui_tools.surfaces.jobs_tab='plans' end
    if which=='corrections' then
      host.ui_tools.load_roster()
    end
    board_view = which ~= 'hub' and which or nil
    -- Opening a board that has never been fetched fetches it, so the first click does the obvious
    -- thing rather than showing an empty list with a second button on it.
    if host.ui_tools.local_navigation then window_refresh();return end
    if which == 'events' and hud_state.events == nil then
      do_events()
    elseif which == 'bounties' and hud_state.bounties == nil then
      do_bounties()
    elseif which == 'bank' and hud_state.bank == nil then
      do_bank()
    elseif which == 'loot' and hud_state.loot == nil then
      do_loot()
    elseif which == 'statics' and hud_state.statics == nil then
      do_statics()
    elseif which == 'polls' and hud_state.polls == nil then
      do_polls()
    elseif which == 'wishlist' and hud_state.wishlist == nil then
      do_wishlist({})
    elseif which == 'myjobs' and hud_state.myjobs == nil then
      do_myjobs({})
    end
    -- `item` is deliberately absent from that list: it answers a QUERY, and there is nothing to
    -- fetch until something has been typed. Opening it fetches nothing.
    window_refresh()
    return
  elseif id == 'jobs:preview' or id == 'jobs:sync' then
    host.ui_tools.job_action(id);window_refresh();return
  elseif id == 'jobs:here' then
    -- Claims the job you are standing here as, in the first slot, leaving the other two alone.
    if host.ui_tools.plan_current() then window_action('tools:jobs') end
    window_refresh()
    return
  elseif id == 'item:go' then
    do_item({ safe_str(hud_state.item_draft, '') })
    return
  elseif id:sub(1, 5) == 'rsvp:' then
    -- `rsvp:<STATUS>:<eventId>`. The id carries both, so the click cannot be answered against
    -- whichever event happened to be open when the request landed.
    local rest = id:sub(6)
    local split = rest:find(':')
    if split then
      send_signup(rest:sub(split + 1), rest:sub(1, split - 1))
      window_refresh()
    end
    return
  elseif id == 'drop:open' then
    drop_draft.open = true
    window_refresh()
    return
  elseif id == 'drop:cancel' then
    drop_draft.open = false
    window_refresh()
    return
  elseif id == 'wish:add' then
    if wish_draft.item == '' then
      log('type an item name first.')
    else
      local item = wish_draft.item
      wish_draft.item = ''
      do_wishlist({ 'add', item })
    end
    window_refresh()
    return
  elseif id:sub(1, 12) == 'wish:remove:' then
    host.ui_tools.wish_feedback=nil
    do_wishlist({ 'remove', id:sub(13) })
    window_refresh()
    return
  elseif id == 'setup:open' then
    open_in_browser(setup_path())
    return
  elseif id == 'setup:go' then
    if setup_draft.code == '' then
      log('paste the code first.')
    else
      -- One click, not two. A setup code is single-use and expires in ten minutes, so the worst a
      -- misclick costs is a fresh code; there is nothing here to take back.
      local code = setup_draft.code
      if do_setup({ code }) then setup_draft.code = '';host.ui_tools.detail_layout.relink=false;board_view='connection';window_tab='me' end
    end
    window_refresh()
    return
  elseif id == 'auction' then
    if not (hud_state.you and type(hud_state.you.canRun)=='table' and hud_state.you.canRun.auctions==true) then
      do_auctions(true)
      if not (hud_state.you and type(hud_state.you.canRun)=='table' and hud_state.you.canRun.auctions==true) then
        log('Opening auctions requires Run auctions permission. Refresh the board or ask a shell officer.');window_refresh();return
      end
    end
    auction_draft.open = true
    window_refresh()
    return
  elseif id == 'auc:cancel' then
    auction_draft.open = false
    window_refresh()
    return
  elseif id == 'auc:send' then
    if auction_draft.item == '' then
      log('name the item first.')
    elseif hud_state.dkp and #(hud_state.dkp.pools or {})>0 and not auction_draft.dkp_pool then
      log('Choose the DKP wallet the winner will pay from first.')
    elseif window_armed and window_armed.action == 'auc:send' then
      window_armed = nil
      -- Two clicks, like a bid. An auction is announced to the whole shell and cannot be called
      -- back from in game, and the item name is the one thing nobody else can correct for you.
      if send_auction_open(auction_draft.item, auction_draft.pool, auction_draft.selected, auction_draft.dkp_pool) then
        auction_draft.open, auction_draft.item, auction_draft.selected = false, '', nil
        do_auctions()
      end
    else
      window_armed = { action = 'auc:send' }
      log('click again to open ' .. auction_draft.item .. ' for bidding.')
    end
    window_refresh()
    return
  elseif id=='pf:mode:LFG' or id=='pf:mode:LFM' then
    if pf_draft.edit_id then pf_draft.error='An existing listing cannot change type. Save or cancel, then create the other type.';window_refresh();return end
    window_tab=id=='pf:mode:LFG' and 'lfg' or 'lfm';open_menu=nil;window_page=1;window_refresh();return
  elseif id == 'pf:cancel' then
    pf_draft.open = false;pf_draft.edit_id=nil;pf_draft.error=nil
    window_refresh()
    return
  elseif id:sub(1, 5) == 'menu:' then
    -- Toggle. Clicking the open one closes it, which is what a second click on a dropdown does.
    local which = id:sub(6)
    open_menu = (open_menu == which) and nil or which
    window_refresh()
    return
  elseif id:sub(1, 4) == 'set:' then
    local rest = id:sub(5)
    local which, value = rest:match('^([^:]+):(.*)$')
    if which == 'pf.category' then
      pf_draft.category = value
    elseif which == 'pf.role' then
      host.ui_tools.pf_composer.pick(pf_draft,value,window_tab=='lfg' and 'LFG' or 'LFM')
    elseif which == 'theme' then
      do_theme(value)
    elseif which == 'auction.window' then
      auction_draft.pool = value == AUCTION_WINDOWS[1]
    end
    open_menu = nil
    window_refresh()
    return
  elseif id == 'pf:send' then
    -- One click. A listing is public, but it expires on its own and carries nothing but what you
    -- just chose on screen, so it does not earn the two-click treatment a bid or a kill report does.
    local mode = window_tab == 'lfg' and 'LFG' or 'LFM'
    -- Whatever role was chosen before the category changed, a craft listing goes out without one
    -- rather than carrying a stale TANK nobody picked for it.
    local role,comment=host.ui_tools.pf_composer.payload(pf_draft,mode)
    local slots,slot_error=host.ui_tools.pf_composer.count_payload(pf_draft,mode)
    if slot_error then pf_draft.error=slot_error;window_refresh();return end
    if #comment>200 then pf_draft.error='Comment must be 200 characters or fewer.';field_lib.focus('pf.comment',pf_draft.comment);window_refresh();return end
    pf_draft.error=nil
    local saved,problem
    if pf_draft.edit_id then saved,problem=host.ui_tools.recruitment.request('/party-finder/edit',{listingId=pf_draft.edit_id,category=pf_draft.category,role=role,comment=comment,maxSize=slots and slots.maxSize,roleSlots=slots and slots.roleSlots})
    else saved=send_pf_post(mode, pf_draft.category, role, comment,slots) end
    if saved then
      pf_draft.edit_id=nil
      pf_draft.open, pf_draft.comment = false, ''
      host.ui_tools.surfaces.action('surface:clear',window_tab);field_lib.blur();window_page=1
      -- Show the board again with the new listing on it, rather than an empty tab.
      do_pf_list()
    else pf_draft.error=problem or host.ui_tools.post_error or 'Could not save. Your draft is retained. Try again.' end
    window_refresh()
    return
  elseif id == 'signin' or id == 'withdraw' then
    window_tab='me';board_view='connection';window_refresh()
    return
  elseif id:sub(1,11)=='auctionweb:' then
    open_in_browser('/shells/'..settings.shell_slug..'/loot/auctions/'..id:sub(12));return
  elseif id:sub(1, 6) == 'shell:' then
    -- The public recruiting page, for the same reason the printed link uses it: whoever clicked
    -- this may have no account, and the member view would meet them with a login screen.
    open_in_browser('/ls/' .. id:sub(7))
    return
  elseif id:sub(1, 5) == 'join:' then
    do_pf_join({ 'join', id:sub(6) })
    do_pf_list()
    window_refresh()
    return
  elseif id:sub(1, 6) == 'focus:' then
    -- Clicking a box takes the keyboard. Clicking the one that already has it re-selects, so typing
    -- replaces rather than appends.
    local which = id:sub(7)
    local current
    if which:sub(1,11)=='attendance.' then current=host.ui_tools.attendance.field_value(which:sub(12))
    elseif which == 'surface.search' then current=host.ui_tools.surfaces.search[window_tab] or ''
    elseif which == 'hnm.search' then current=host.ui_tools.hnm.search
    elseif which == 'tools.pool' then
      current=host.ui_tools.draft.pool or ''
    elseif which == 'tools.ceiling' then
      current=host.ui_tools.draft.ceiling or ''
    elseif which == 'tools.jobs' then
      current=host.ui_tools.draft.jobs or ''
    elseif which == 'tools.book' then
      current=host.ui_tools.draft.book
    elseif which == 'tools.include' or which == 'tools.exclude' then
      current=host.ui_tools.draft[which:sub(7)] or ''
    elseif which == 'drop.item' then
      current = drop_draft.item
    elseif which == 'drop.winner' then
      current = drop_draft.winner
    elseif which == 'pf.character' then
      current=host.ui_tools.recruitment.character or ''
    elseif which == 'pf.comment' then
      current = pf_draft.comment
    elseif which == 'pf.capacity' then
      current = tostring(pf_draft.maxSize or 6)
    elseif which == 'bid.amount' then
      current = auction_draft.amount
    elseif which == 'tod.time' then
      current = auction_draft.killed_at
    elseif which == 'tod.target' then
      current = auction_draft.target
    elseif which == 'auction.item' then
      if auction_draft.selected then auction_draft.selected = {invalid=true} end
      current = auction_draft.item
    elseif which == 'setup.code' then
      current = setup_draft.code
    elseif which == 'wish.item' then
      current = wish_draft.item
    elseif which == 'item.name' then
      current = safe_str(hud_state.item_draft, '')
    end
    field_lib.focus(which, current)
    window_refresh()
    return
  elseif id:sub(1, 5) == 'pick:' then
    -- A suggestion was clicked. It fills the box that is open and hands the keyboard back, because
    -- picking from the list IS the commit: there is nothing left to type.
    local name = id:sub(6)
    local which = field_lib.id()
    field_lib.blur()
    if which and which:sub(1,11)=='attendance.' then
      field_submit(name,which)
    elseif which == 'drop.item' then
      drop_draft.item = name
    elseif which == 'drop.winner' then
      drop_draft.winner = name
    elseif which == 'tod.target' then
      auction_draft.target = name
      hud_state.tod_feedback = nil
    elseif which == 'auction.item' then
      if auction_draft.selected then auction_draft.selected = {invalid=true} end
      auction_draft.item = name
    elseif which == 'wish.item' then
      wish_draft.item = name
    elseif which == 'item.name' then
      hud_state.item_draft = name
    end
    window_refresh()
    return
  elseif id == 'dropgo' then
    if drop_draft.item == '' or drop_draft.winner == '' then
      log('fill in both the item and the winner first.')
    elseif window_armed and window_armed.action == 'dropgo' then
      window_armed = nil
      -- The same call the typed command ends in. The composer only ever assembled its arguments.
      do_drop({ drop_draft.item, drop_draft.winner })
      drop_draft.item, drop_draft.winner = '', ''
      drop_draft.open = false
    else
      window_armed = { action = 'dropgo' }
      log('click again to report ' .. drop_draft.item .. ' to ' .. drop_draft.winner .. '.')
    end
    window_refresh()
    return
  elseif id:sub(1, 4) == 'tod:' then
    -- The row IS the target, so this is the one argument-taking command the window can supply
    -- without a text field. It still confirms: a wrong time of death sends the whole shell to camp
    -- the wrong window, and the server may award DKP for the report.
    local target = id:sub(5)
    if window_armed and window_armed.action == id then
      window_armed = nil
      do_tod({ target })
    else
      window_armed = { action = id }
      log('click again to report ' .. target .. ' as dead JUST NOW. Anything else cancels.')
    end
    window_refresh()
    return
  elseif id:sub(1, 4) == 'bid:' then
    local auction_id = id:sub(5)

    -- Re-read the auction from the CURRENT list rather than trusting what was on screen when the
    -- button was armed. The list refreshes on its own, so between the two clicks an auction can
    -- close, or its terms can change; either way the offer that gets sent is the one that is true
    -- now, or none at all.
    local auction
    for _, row in ipairs(hud_state.auctions or {}) do
      if row.id == auction_id then
        auction = row
      end
    end
    if not auction then
      window_armed = nil
      log('that auction is no longer open. Refresh to see what is.')
      window_refresh()
      return
    end

    local mode = safe_str(auction.mode, 'TIERED')
    local offer
    if mode == 'FIXED' then
      offer = safe_num(auction.fixedPrice, 0)
    elseif mode == 'TIERED' then
      offer = safe_num(auction.tierMinimum, 0)
    end
    if not offer or offer < 1 then
      window_armed = nil
      log('this one needs an amount you choose: //lootryx bid <number> <amount|N%>')
      window_refresh()
      return
    end

    auction_draft.handle('editbid:'..auction_id)
    if not auction.myBid then auction_draft.amount=tostring(offer) end
    window_refresh()
    return
  end
  -- Entering the board must hydrate it after load or account linking.
  -- Manual navigation uses the same server read and exact bid IDs as the command.
  if not host.ui_tools.local_navigation and (id:sub(1, 4) == 'tab:' or id:sub(1, 4) == 'nav:') and window_tab == 'auctions' then
    do_auctions()
  elseif not host.ui_tools.local_navigation and (id:sub(1,4)=='tab:' or id:sub(1,4)=='nav:') and window_tab=='windows' then
    do_windows()
  end
  window_refresh()
end

-- ─────────────────────────── events ───────────────────────────

-- Shared cooperative transport, using only each loader's bundled socket/TLS libraries.
host.protect=pcall
if host.network_socket and type(host.network_socket.tcp)=='function' then
  host.async=loadfile(host.addon_path..'lib/async-jobs.lua')()
  host.protect=host.async.protect
  host.network=loadfile(host.addon_path..'lib/async-http.lua')().new(host.network_socket,host.network_ssl,
    host.addon_path..'assets/cacert.pem',loadfile(host.addon_path..'lib/http-response.lua')(),
    loadfile(host.addon_path..'lib/verified-https.lua')(),
    loadfile(host.addon_path..'lib/doh-resolver.lua')(),json)
  host.network.TIMEOUT=REQUEST_TIMEOUT_SECONDS
  host.network.dns_seconds=math.max(30,math.min(3600,tonumber(settings.network_dns_cache_seconds) or 300))
  http=host.network;https=host.network
  host.jobs=host.async.new(function()
    local p=client_reader.player()
    return host.logged_in() and p and tostring(p.id)..':'..tostring(p.name) or 'offline'
  end,log,function()
    local drafts=host.ui_tools.pending_drafts
    host.ui_tools.pending_drafts=nil
    if drafts then
      local tab=window_tab
      for _,draft in pairs(drafts) do if draft.id=='wish.item' then window_tab=draft.tab;field_submit(draft.value,draft.id) end end
      for _,draft in pairs(drafts) do if draft.id~='wish.item' then window_tab=draft.tab;field_submit(draft.value,draft.id) end end
      window_tab=tab
    end
    local route=host.ui_tools.pending_route
    if route then window_tab=route.tab;board_view=route.board;window_page=route.page;host.ui_tools.pending_route=nil end
    host.ui_tools.busy_warned=nil
    host.ui_tools.request_label=nil
    host.ui_tools.finish(function(line) host.chat(207,'Lootryx: '..line) end)
    pcall(window_refresh)
  end)
  host.original_register=host.register_event
  host.register_event=function(name,fn)
    if name=='addon command' or name=='load' then
      return host.original_register(name,function(...)
        local args={...}
        if host.jobs.busy() then
          if name=='addon command' and (args[1]=='window' or args[1]=='status' or args[1]=='help') then
            local pending,limit=host.ui_tools.pending,host.ui_tools.limit
            fn(...)
            host.ui_tools.pending,host.ui_tools.limit=pending,limit
            return
          end
          log('A request is pending. Wait for its result before trying again.');return
        end
        host.jobs.run(fn,unpack(args))
        if host.jobs.busy() then field_commit();window_refresh() end
      end)
    end
    return host.original_register(name,fn)
  end
end
host.ui_tools.dispatch_action=function(id)
  host.ui_tools.route_page=window_page
  local local_action=id=='close' or id=='mini' or id=='settings' or id=='notifications' or id=='signin'
    or id=='pf:back' or id=='connection:cancel' or id=='attendance:back'
    or id=='attendance:cancel' or id=='attendance:cancel-review' or id=='pf:cancel-review'
    or id=='tools:plans-cancel' or id=='tools:pull-cancel' or id=='wish:cancel'
    or id=='pf:cancel' or id=='drop:cancel' or id=='auc:cancel' or id=='bidcancel'
    or id=='notices:list' or id=='notices:preferences' or id=='notices:clear' or id=='notices:read-all'
    or id:match('^notices:detail:') or id:match('^notices:read:') or id:match('^notices:group:') or id:match('^notice:')
    or id:match('^nav:') or id:match('^tab:') or id:match('^board:')
    or id:match('^page:') or id:match('^focus:') or id:match('^pick:')
    or id:match('^surface:') or id:match('^menu:') or id:match('^set:')
  if not host.jobs then return window_action(id) end
  if host.jobs.busy() then
    if local_action then
      host.ui_tools.local_navigation=true
      local ok,err=pcall(window_action,id)
      host.ui_tools.local_navigation=nil
      -- Explicit discard must not be undone by replaying a pre-discard edit after the request.
      local discard=id=='wish:cancel' and 'wish.' or id=='attendance:cancel' and 'attendance.' or nil
      if discard then
        for key,draft in pairs(host.ui_tools.pending_drafts or {}) do
          if draft.id:sub(1,#discard)==discard then host.ui_tools.pending_drafts[key]=nil end
        end
      end
      host.ui_tools.pending_route={tab=window_tab,board=board_view,page=window_page}
      if not ok then error(err) end
    elseif not host.ui_tools.busy_warned then
      host.ui_tools.busy_warned=true
      log('A request is pending. You can keep browsing; retry this action when it finishes.')
    end
    return
  end
  local labels={['wish:save']='Saving wishlist', ['setup:go']='Connecting character', ['tools:pull']='Downloading macro edits', ['cmd:macros']='Uploading macro books', ['cmd:dkp']='Refreshing balances', ['tools:jobs']='Saving job plans'}
  host.ui_tools.request_label=labels[id] or (id:match('^board:') and ('Loading '..id:sub(7))) or (id:match('^attendance:') and 'Updating attendance') or (id:match('^pf') and 'Updating recruitment') or 'Request in progress'
  host.jobs.run(window_action,id)
  if not host.jobs.busy() then host.ui_tools.request_label=nil end
  if host.jobs.busy() then field_commit();window_refresh() end
end

host.register_event('addon command', function(command, ...)
  command = (command or 'help'):lower()
  local args = { ... }
  if command ~= 'selftest' and not (command == 'help' and args[1] == 'all') then host.ui_tools.begin(12) end

  -- Every command runs inside a pcall, and unlike the render loop this one reports EVERY time: you
  -- typed something and are owed an answer. A raw Lua error here is a stack trace addressed to
  -- nobody -- the player cannot read it, and it does not say which command produced it. Inline
  -- rather than extracted for the same reason as the prerender loop: the compliance guard reads
  -- this registration to prove which handlers are command-triggered.
  local ok, err = host.protect(function()
    if command == 'link' then
      do_link(args[1])
    elseif command == 'snap' then
      do_snap(false)
    elseif command == 'theme' then
      do_theme(args[1])
    elseif command == 'window' then
      local open = panel_lib.toggle()
      settings.window_open = open
      save_settings()
      if open then
        window_refresh()
        log('window open. drag the title bar to move it, click the x to close.')
      else
        log('window closed. //lootryx window to bring it back.')
      end
    elseif command == 'shells' then
      do_shells()
    elseif command == 'pf' then
      do_pf(args)
    elseif command == 'macros' then
      do_macros(args)
    elseif command == 'tod' then
      do_tod(args)
    elseif command == 'drop' then
      do_drop(args)
    elseif command == 'dkp' then
      do_dkp()
    elseif command == 'standings' then
      do_standings(args)
    elseif command == 'windows' then
      do_windows()
    elseif command == 'events' then
      do_events()
    elseif command == 'wish' or command == 'wishlist' then
      do_wishlist(args)
    elseif command == 'bounties' then
      do_bounties()
    elseif command == 'loot' then
      do_loot()
    elseif command == 'bank' then
      do_bank()
    elseif command == 'signup' then
      do_signup(args)
    elseif command == 'item' then
      do_item(args)
    elseif command == 'statics' or command == 'seekers' then
      do_statics()
    elseif command == 'unseek' then
      do_unseek()
    elseif command == 'claim' then
      do_claim()
    elseif command == 'polls' or command == 'poll' then
      do_polls()
    elseif command == 'vote' then
      do_vote(args)
    elseif command == 'myjobs' or command == 'jobs' then
      do_myjobs(args)
    elseif command == 'auctions' then
      do_auctions()
    elseif command == 'bid' then
      do_bid(args)
    elseif command == 'allin' then
      do_allin(args)
    elseif command == 'auction' then
      do_auction_open(args)
    elseif command == 'hud' then
      do_hud(args)
    elseif command == 'setup' then
      do_setup(args)
    elseif command == 'key' then
      do_key(args)
    elseif command == 'roster' then
      do_roster(args)
    elseif command == 'show' then
      do_show()
    elseif command == 'selftest' then
      do_selftest()
    elseif command == 'pointer' then
      if panel_lib.pointer_alignment and args[1]=='align' then panel_lib.pointer_alignment.start();panel_lib.show(true);window_refresh()
      elseif panel_lib.pointer_alignment and args[1]=='reset' then panel_lib.pointer_alignment.reset();window_refresh() end
      for _,line in ipairs(host.pointer_status and host.pointer_status() or {'Pointer: Ashita native input'}) do log(line) end
    elseif command == 'status' then
      do_status()
    elseif command == 'auto' then
      do_auto(args)
    elseif command == 'heartbeat' then
      do_heartbeat_toggle(args)
    else
      print_help(args)
    end
  end)

  if not ok then
    log('"' .. command .. '" failed with an internal error: ' .. tostring(err))
    log('  that is a bug in the addon, not something you typed wrong. Please report it.')
  end
  host.ui_tools.finish(function(line) host.chat(207, 'Lootryx: '..line) end)
end)

-- Seeded to the load time, NOT to 0. At 0 the very first rendered frame satisfied
-- `now - last_auto >= interval` for any interval, so an addon loaded with `auto` already on in
-- settings.xml fired a blocking POST on frame one -- routinely mid-zone, which is the worst moment
-- to hitch. The first auto capture now lands one full interval after load, like every one after it.
local last_auto = os.time()

-- Exponential backoff for the AUTO loop only (a typed `//lootryx snap` always tries, because a
-- person asking for something deserves an answer or a real error).
--
-- Without this, an api_base that is down costs a bounded-but-real stall every single interval, for
-- as long as the client is open: 5s of frozen client every 5 minutes, forever, for a server that is
-- never coming back this session. Doubling the wait per consecutive failure turns that into a
-- handful of hitches that fade to one every half hour, and the queue keeps the captures.
local auto_failures = 0
local auto_retry_at = 0
local AUTO_BACKOFF_CAP_SECONDS = 1800

-- Held captures are retried faster than fresh ones are taken, because a queued capture is racing an
-- expiry (lib/queue.lua) while a fresh one can simply be taken again next interval. Still only ever
-- one pending task, and still under the backoff above, so a dead endpoint cannot turn
-- a full buffer into a stall every minute.
local QUEUE_DRAIN_INTERVAL_SECONDS = 60
local last_drain = 0
-- Seeded to load time, like `last_auto`, so loading the addon never pings on frame one.
local last_heartbeat = os.time()

-- Frame-loop errors must never become a wall of text. Windower prints a line for EVERY uncaught
-- error and `prerender` fires every frame, so one bad state would emit thousands of identical
-- lines a second and bury the player's chat log -- including whatever error would have told them
-- what actually broke. Report the first occurrence, then stay silent.
local render_error_reported = false
host.ui_tools.window_last_second = 0

-- Cheap per-frame gate; starts a snapshot once per interval when auto is on.
host.register_event('prerender', function()
  local function frame_work()
  -- pcall, because this runs every frame: an error escaping here is not one bad line, it is a
  -- permanently unusable chat log. The body is INLINE rather than a named function so the
  -- compliance guard (packages/addon-harness/src/compliance.test.ts, A23-28) can still read which
  -- `do_*` handlers this loop reaches -- moving it out of the registration would have hidden the
  -- auto-loop's call surface from the very test that exists to police it.
  local ok, err = host.protect(function()
    -- Draw first, and unconditionally: the overlay is pure formatting of state already in memory,
    -- so it must not be gated behind the auto-snapshot switch below. It issues no request (see the
    -- HUD section). Three things in this loop can touch the network: `do_snap`,
    -- `do_drain_queued`, and `do_heartbeat`. They are mutually exclusive per frame and named `do_*` so the
    -- compliance guard can see them.
    hud_refresh_operational_state()
    hud_render()

    local now = os.time()
    if panel_lib.visible() and now ~= host.ui_tools.window_last_second then
      host.ui_tools.window_last_second = now
      window_refresh()
    end
    host.ui_tools.auction_tick(now)
    host.ui_tools.local_activity(now)
    if host.ui_tools.attendance_opened then
      host.ui_tools.attendance_opened=nil
      last_auto=now-settings.interval;auto_retry_at=0;auto_failures=0
    end
    if now < auto_retry_at then
      if not say.do_refresh_live_auctions(now) and not say.do_refresh_recruitment(now) then say.do_refresh_attendance(now) end
      return
    end

    -- Start at most one periodic request task, and held captures go first.
    --
    -- Draining takes priority over taking a new snapshot because a queued capture is the one with a
    -- deadline: it expires out of the buffer once it is too old to credit safely, while a fresh
    -- capture can always be taken again next interval. The drain cadence is faster than the
    -- snapshot interval for the same reason, and both sit under the same backoff, so an endpoint
    -- that is down does not turn a full buffer into a stall every minute.
    -- Each periodic job decides for itself whether it is due, and they are deliberately INDEPENDENT.
    -- All three used to sit behind one `if not settings.auto then return end`, which was wrong twice
    -- over: a capture from a TYPED `//lootryx snap` would sit in the retry buffer forever on a
    -- client with auto off, and a solo camper (who has no alliance to snapshot and every reason to
    -- leave auto off) would never heartbeat at all, which is precisely the case watch coverage
    -- exists for. Only the auto SNAPSHOT was ever meant to be gated on `auto`.
    local drain_due = queue_lib.size(snapshot_queue) > 0 and (now - last_drain >= QUEUE_DRAIN_INTERVAL_SECONDS)
    local snap_due = settings.auto == true and settings.interval > 0 and (now - last_auto >= settings.interval)
    local snapped
    if drain_due then
      last_drain = now
      snapped = do_drain_queued()
    elseif snap_due then
      last_auto = now
      snapped = do_snap(true)
    elseif say.do_refresh_live_auctions(now) then
      -- One bounded website refresh for auctions already being followed. Never bids or game actions.
    elseif say.do_refresh_recruitment(now) then
      -- One cooperative read; never enrolls or accepts an invitation automatically.
    elseif say.do_refresh_attendance(now) then
      -- Read check-in status only. Starting, closing and capturing require an explicit click.
    elseif settings.heartbeat == true and (now - last_heartbeat >= settings.heartbeat_interval) then
      -- LAST in the chain, and only when nothing else claimed this frame. A heartbeat is the least
      -- urgent thing here (a missed one costs a gap in a coverage board; a missed capture costs
      -- somebody's attendance), and the one-request-per-frame ceiling is what keeps the render loop
      -- honest no matter how many periodic jobs accumulate here.
      last_heartbeat = now
      snapped = do_heartbeat()
    end

    if snapped == 'deferred' then
      last_auto=now-settings.interval
    elseif snapped == false then
      auto_failures = auto_failures + 1
      local wait = settings.interval * (2 ^ auto_failures)
      if wait > AUTO_BACKOFF_CAP_SECONDS then
        wait = AUTO_BACKOFF_CAP_SECONDS
      end
      auto_retry_at = now + wait
    elseif snapped == true then
      auto_failures = 0
      auto_retry_at = 0
    end
  end)

  if not ok and not render_error_reported then
    render_error_reported = true
    log('the overlay/auto loop hit an error and has been quieted for this session: ' .. tostring(err))
    log('  //lootryx hud off, then //lua reload lootryx, and please report this.')
  end
  end
  if host.jobs then
    local ok=pcall(function()
      hud_refresh_operational_state();hud_render()
      local now=os.time()
      if panel_lib.visible() and now~=host.ui_tools.window_last_second then host.ui_tools.window_last_second=now;window_refresh() end
      host.ui_tools.auction_tick(now)
    host.ui_tools.local_activity(now)
      host.jobs.tick()
      if not host.jobs.busy() then host.jobs.run(frame_work) end
    end)
    if not ok and not render_error_reported then
      render_error_reported=true;host.jobs.cancel(true)
      log('The display loop failed. Reload Lootryx and report this error.')
    end
  else frame_work() end
end)

host.register_event('load', function()
  panel_lib.set_position(settings.window_x, settings.window_y)
  log('v' .. _addon.version .. ' loaded. shell=' .. shell_label() .. ' key=' .. mask_key(settings.key_id) .. '. //lootryx help or //lootryx status')
  -- The one moment a new member is definitely reading their chat log. Spending it on the setup
  -- steps beats letting them find out command by command that none of them work yet.
  if settings.open_on_login ~= false then
    panel_lib.show(true)
    window_refresh()
    -- Fill the public boards ONCE, so the window has something in it on the first look. Opening to
    -- three empty tabs and a Refresh button reads as broken rather than as idle.
    --
    -- This is the one place the addon reaches the network without being asked, and the bound is
    -- what makes that acceptable: two unauthenticated GETs to public endpoints, at most once per
    -- session, never repeated and never on a timer. The thing the overlay promises never to do is
    -- POLL, and this does not poll.
    window_prefetch()
  end
  log('  //lootryx window opens the window (tabs, listings, clickable buttons).')
  if is_unconfigured() then
    print_setup_steps()
  end
end)

-- Give back what we took. A Windower text object outlives the addon that made it: without this,
-- `//lua unload lootryx` left the overlay stranded on screen with nothing left to hide it, and the
-- only way back was a full client restart. Anything this addon creates, it destroys here.
--[[
  Mouse routing for the window.

  Windower delivers every mouse event to every addon; returning true stops it reaching the game.
  That return is the safety-critical part. A click that falls through while you are fighting could
  target or move your character, so anything landing inside the panel is swallowed, and everything
  outside it is passed along untouched.

  This hook cannot cause a game action. It has no way to: the addon sends nothing to the game
  server, and the handler's only outputs are redraws, local chat lines, and the same HTTP reads a
  typed command would make.
]]
host.register_event('mouse', function(kind, x, y, delta, blocked)
  if blocked then
    return false
  end
  if not host.jobs or not host.jobs.busy() then host.ui_tools.begin(5) end
  local ok, consumed = pcall(panel_lib.mouse, kind, x, y, host.jobs and host.ui_tools.dispatch_action or window_action, delta)
  if not host.jobs or not host.jobs.busy() then host.ui_tools.finish(function(line) host.chat(207,'Lootryx: '..line) end) end
  if not ok then
    return false
  end
  return consumed == true
end)

--[[
  Keys, but ONLY while a text box in the window has focus.

  With no focus this returns false immediately and the game sees every key exactly as it always did,
  which is the normal state: the handler is inert unless you clicked into a box. With focus it
  consumes everything, printable or not, so a letter cannot double as a macro trigger mid-word.

  `field_lib.guard` is what makes it safe to consume at all. An error thrown anywhere inside here
  would otherwise leave the keyboard blocked, and a player who cannot move or type is a far worse
  outcome than a lost keystroke. The guard releases the lock and re-throws.
]]
host.register_event('keyboard', field_lib.guard(function(dik, down, _flags, key_blocked)
  if not field_lib.state() then
    return false
  end
  -- Our own block marks events blocked; the focused box still has to see them.
  if key_blocked and not field_lib.blocked() then
    return false
  end
  local consumed = field_lib.key(dik, down, field_submit, field_cancel)
  window_refresh()
  return consumed == true
end))

host.register_event('unload', function()
  if host.jobs then host.jobs.cancel(true) end
  -- First, and outside any pcall that could swallow it: give the keyboard back. Everything else
  -- here is cosmetic by comparison.
  pcall(field_lib.blur)
  pcall(panel_lib.destroy)
  if not hud_box then
    return
  end
  -- `hide` first, then `destroy` only if the library offers it.
  --
  -- `destroy` is the correct teardown and Windower's texts library documents it, but this addon has
  -- never executed in a real client (README §6), so calling it unconditionally would turn a wrong
  -- guess about that API into a Lua error at the worst possible moment: during unload, when there
  -- is nothing left to catch it and the player is already trying to leave. `hide` is the half that
  -- fixes the visible problem and exists on every version, so it runs unconditionally and first.
  hud_box:hide()
  if type(hud_box.destroy) == 'function' then
    hud_box:destroy()
  end
  hud_box = nil
end)
