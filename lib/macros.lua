--[[
  macros.lua · pure-Lua decoder + encoder for the FFXI macro book DAT format (Windower4, Lua 5.1).

  EPIC MACRO M2 added DECODE-ONLY reads. EPIC MACRO M4 (this revision) adds the ENCODER and the
  LOCAL write-back used by `//lootryx macros pull` (lootryx.lua). Per the amended CLAUDE.md
  invariant 1 (owner decision 2026-07-18), writing the player's OWN local macro files is permitted:
  it is local-config editing (same as re-typing a macro in-game), never a server action, never
  game-memory/packet manipulation. Every write in this file funnels through
  `write_bytes_verified`, which is a HARD GATE checked immediately before every single `io.open`
  write-open (not just the final target): it opens a file for writing ONLY if the basename matches
  `^mcr%d*%.dat$` or `^mcr%.ttl$` (the live macro file) OR that same shape with a `.bak`/`.tmp`
  suffix (the backup-before-write and atomic-staged-write siblings write_whitelisted_file creates
  around every live write), AND the path resolves under the caller's macro_dir; anything else is
  refused, never written. There is no other `io.open(...'w'...)`, `:write(`, `send_command`, or
  `windower.ffxi.*` call anywhere in this file (grep-auditable, see addon/README.md §1b/§8). Network
  transport still lives entirely in lootryx.lua; this module never touches a socket.

  Format (public FFXI game knowledge, independently re-derived here, not copied from any other
  project):
    mcrN.dat  = one PAGE = 7624 bytes
                = 24-byte header (4 version + 4 flags + 16 MD5, opaque here, see "header handling"
                  below)
                + 20 macros x 380 bytes (4-byte reserved/skip field, not interpreted, only carried
                  forward byte-for-byte on write, + 6x61-byte command lines + 10-byte name)
    A BOOK is 10 pages. file_index = (book-1)*10 + (page-1); book 1's pages are named
    mcr.dat (index 0), mcr1.dat, ..., mcr9.dat (index 9); book 2 starts at mcr10.dat; etc.
    Of the 20 macros per page, slots 1-10 are the Ctrl set (Ctrl+F1..F10) and slots 11-20 are the
    Alt set (Alt+F1..F10), matching the in-game macro book UI layout.
    mcr.ttl = book TITLES = 24-byte header + one 16-byte null-padded entry per book (20 books).

  Header handling (VERIFY IN-GAME, see addon/README.md §6): this module never interprets or
  recomputes the 24-byte header (version/flags/MD5). The encoder always CARRIES IT FORWARD
  VERBATIM from the page file already on disk (read immediately before writing, by
  `M.parse_page_file`), for both unchanged and edited macro content. This guarantees a byte-
  identical file for unchanged content (the round-trip fidelity test below proves the byte math),
  and for edited content it means the MD5 field goes stale relative to the new bytes rather than
  guessing an unconfirmed hash formula. Whether the FFXI client validates that MD5 on load, or
  simply ignores it (many community macro-editing tools over the years have not recomputed it and
  have loaded fine), is NOT independently confirmed against a real client; carrying it forward is
  the safer of the two unverifiable choices (a stale-but-plausible hash vs. a fabricated one). Only
  when NO original file exists at all (a page the client itself never created, a rare edge case
  since FFXI pre-creates every macro page file it has ever shown) does the encoder fall back to a
  zeroed 24-byte header (`M.default_header()`), an even-less-verified path, also flagged below.

  API:
    local macros = loadfile(windower.addon_path .. 'lib/macros.lua')()
    macros.resolve_macro_dir(override) -> dir_string_or_nil
    macros.parse_titles(ttl_path)      -> titles { [book_index] = title_string, ... }, header(24B),
                                          confirmed_missing(bool, true only when ttl_path provably
                                          does not exist yet, see the function's own comment)
    macros.parse_book(macro_dir, book_index) -> pages (array of 10 { pageNumber, macros[20] })
    macros.parse_page_file(path)       -> macros[20], header(24B), reserved_by_slot[20](4B each)
    macros.hash_book(pages)            -> 64-char lowercase sha256 hex digest
    macros.is_blank_book(pages)        -> true if every macro in every page is empty
    macros.blank_macros()              -> 20 empty macro entries (used for an unreadable/missing page)
    macros.macros_to_slots(list)       -> dense 20-slot array from a (possibly partial) macro list
    macros.default_header()            -> 24 zero bytes, the no-original-file fallback
    macros.encode_page_bytes(macros, header, reserved_by_slot) -> 7624-byte string, or nil, err
    macros.encode_titles_bytes(titles, header) -> encoded mcr.ttl bytes, or nil, err
    macros.write_page_file(macro_dir, file_index, bytes) -> true, or false, refusal/error reason
    macros.write_titles_file(macro_dir, bytes) -> true, or false, refusal/error reason
]]

local sha2, game_path = ...
assert(type(sha2) == 'table', 'macro codec requires the shared SHA-256 dependency')

local M = {}

-- ─────────────────────────── format constants ───────────────────────────

M.PAGES_PER_BOOK = 10
M.MACROS_PER_PAGE = 20
M.BOOKS_MAX = 20

local PAGE_SIZE = 7624
local HEADER_SIZE = 24
local MACRO_SIZE = 380
local SKIP_SIZE = 4
local LINE_SIZE = 61
local LINES_PER_MACRO = 6
local NAME_SIZE = 10
local TITLE_SIZE = 16

-- ─────────────────────────── byte helpers ───────────────────────────

-- Returns (data), or (nil, open_err, open_errno) on failure. `open_errno` is the platform errno
-- Lua's io.open reports for the failed open (confirmed under this repo's LuaJIT: 2 == ENOENT, "No
-- such file or directory"; 13 == EACCES, "Permission denied", the shape a locked/AV-held file
-- reports on Windows), so a caller that needs to tell "never created" apart from "exists but
-- unreadable right now" can (see M.parse_titles / Finding AB-49).
local function read_file(path)
  local f, open_err, open_errno = io.open(path, 'rb')
  if not f then
    return nil, open_err, open_errno
  end
  local data = f:read('*a')
  f:close()
  return data
end

-- Fixed-width field -> string: cut at the first NUL byte (the game null-terminates and NUL-pads
-- any unused width, see the module header's format note). Deliberately does NOT trim trailing
-- whitespace inside that content (Finding MACRO-03 hardening, 2026-07-19): an earlier version
-- trimmed trailing whitespace here, which meant decode -> encode was not byte-identical whenever a
-- macro line legitimately ended in a space (encode_page_bytes/pad_field NUL-pads, it never restores
-- a trimmed space), so a book pulled with no real edit could silently drop a player's trailing
-- space on write-back. Cutting at the NUL is the actual field boundary the game itself writes;
-- nothing past it is meaningful content, so returning everything up to (not including) the NUL,
-- unmodified, is both simpler and round-trip-safe. See verify-macro-roundtrip.mjs's "trailing
-- whitespace preserved" fixture.
local function cstring(raw)
  local nul = raw:find('\0', 1, true)
  return nul and raw:sub(1, nul - 1) or raw
end

-- ─────────────────────────── macro dir resolution ───────────────────────────

local function normalize_dir(dir)
  if not dir:match('[\\/]$') then
    dir = dir .. '\\'
  end
  return dir
end

-- Resolves the folder containing mcrN.dat / mcr.ttl. `override` is the `macro_dir` settings key
-- (see data/settings.example.xml): if set, it wins outright, since the real FFXI macro folder lives
-- under a per-account content-id subfolder Windower's Lua API cannot enumerate, so an explicit path
-- is the reliable path. Falls back to a best-effort guess off windower.ffxi_path for the common
-- single-account install. VERIFY IN-GAME: neither the exact ffxi_path shape nor whether the
-- single-account fallback resolves straight to the USER folder (vs. needing the content-id
-- subfolder appended) has been confirmed against a real client; `//lootryx macros push` reports
-- which files it could not read rather than failing silently, so a wrong guess is diagnosable.
function M.resolve_macro_dir(override)
  if override and override ~= '' then
    return normalize_dir(override)
  end
  if game_path then
    return normalize_dir(game_path .. 'USER\\')
  end
  return nil
end

-- ─────────────────────────── page / book decode ───────────────────────────

-- file_index 0 -> "mcr.dat" (no digit); file_index N>0 -> "mcrN.dat".
function M.page_filename(file_index)
  if file_index == 0 then
    return 'mcr.dat'
  end
  return 'mcr' .. file_index .. '.dat'
end

function M.blank_macros()
  local macros = {}
  for i = 1, M.MACROS_PER_PAGE do
    local set, position
    if i <= 10 then
      set, position = 'Ctrl', i
    else
      set, position = 'Alt', i - 10
    end
    macros[i] = { set = set, position = position, name = '', lines = { '', '', '', '', '', '' } }
  end
  return macros
end

-- Decodes one page's raw 7624-byte buffer into 20 macro entries, PLUS the raw 24-byte header and
-- each slot's raw 4-byte reserved field (both opaque, never interpreted, only returned so a
-- write-back caller can carry them forward byte-for-byte, see the module header). Returns a single
-- nil for anything that is not a well-formed page (wrong size, e.g. a file the game has not
-- created yet) so a read-only caller (parse_book, used by push) can fall back to a blank page
-- rather than mis-decode garbage; existing single-value callers are unaffected by the two extra
-- return values (Lua truncates multi-returns used inside a larger expression).
function M.parse_page_bytes(data)
  if not data or #data ~= PAGE_SIZE then
    return nil
  end
  local header = data:sub(1, HEADER_SIZE)
  local macros = {}
  local reserved_by_slot = {}
  for i = 0, M.MACROS_PER_PAGE - 1 do
    local base = HEADER_SIZE + i * MACRO_SIZE
    reserved_by_slot[i + 1] = data:sub(base + 1, base + SKIP_SIZE)
    local lines = {}
    for j = 0, LINES_PER_MACRO - 1 do
      local off = base + SKIP_SIZE + j * LINE_SIZE
      lines[j + 1] = cstring(data:sub(off + 1, off + LINE_SIZE))
    end
    local name_off = base + SKIP_SIZE + LINES_PER_MACRO * LINE_SIZE
    local name = cstring(data:sub(name_off + 1, name_off + NAME_SIZE))
    local set, position
    if i < 10 then
      set, position = 'Ctrl', i + 1
    else
      set, position = 'Alt', i - 10 + 1
    end
    macros[i + 1] = { set = set, position = position, name = name, lines = lines }
  end
  return macros, header, reserved_by_slot
end

-- (macros, header, reserved_by_slot), or a single nil if the file is missing/unreadable/wrong
-- size. `local m = M.parse_page_file(p) or M.blank_macros()` (parse_book's usage) still only ever
-- looks at the first value, unaffected by this signature growing.
function M.parse_page_file(path)
  return M.parse_page_bytes(read_file(path))
end

-- Reads all 10 pages of one book (1..20). A missing/unreadable page becomes a blank page rather
-- than aborting the whole book, since not every book/page a player has is necessarily populated.
function M.parse_book(macro_dir, book_index)
  local pages = {}
  for page_number = 1, M.PAGES_PER_BOOK do
    local file_index = (book_index - 1) * M.PAGES_PER_BOOK + (page_number - 1)
    local path = macro_dir .. M.page_filename(file_index)
    local macros = M.parse_page_file(path) or M.blank_macros()
    pages[page_number] = { pageNumber = page_number, macros = macros }
  end
  return pages
end

-- Returns (titles, header, confirmed_missing): header is the raw 24 bytes at the top of mcr.ttl,
-- opaque here, only captured so a write-back caller can carry it forward byte-for-byte (see the
-- module header). `confirmed_missing` is ONLY true when header is nil AND the read failed with
-- ENOENT (errno 2), i.e. mcr.ttl provably does not exist on disk yet (a legitimate first-write
-- case). When header is nil and `confirmed_missing` is false, the file exists but could not be
-- read for some other reason (locked by an AV/sync handle, a permissions error): a caller must NOT
-- treat that the same as "safe to create fresh", since encoding a blank titles table over a header
-- read failure would zero every book's title, not just the one being changed (Finding AB-49,
-- 2026-07-24 hardening: an earlier version could not tell these two cases apart and always fell
-- back to the fresh-file/blank path, silently blanking the other 19 books). Existing single-value
-- callers (`local titles = macros_lib.parse_titles(...)`) are unaffected.
function M.parse_titles(ttl_path)
  local data, _, errno = read_file(ttl_path)
  local titles = {}
  if not data then
    return titles, nil, errno == 2
  end
  local header = data:sub(1, HEADER_SIZE)
  local offset = HEADER_SIZE
  local index = 1
  while offset + TITLE_SIZE <= #data and index <= M.BOOKS_MAX do
    titles[index] = cstring(data:sub(offset + 1, offset + TITLE_SIZE))
    offset = offset + TITLE_SIZE
    index = index + 1
  end
  return titles, header, false
end

-- Pure decision, no I/O: is it safe to encode + write mcr.ttl for a title change, given this
-- SAME call's parse_titles() result and whether the CALLER's pull run has already proven mcr.ttl
-- exists (a prior book in the same run successfully read a header)? Returns true when safe (a real
-- header was read, or this is a provable first-ever write with nothing earlier in the run to
-- contradict it), or false plus a human reason when not (Finding AB-49, 2026-07-24): refuses rather
-- than letting a caller fall through to encode_titles_bytes' zeroed-header/blank-titles fallback,
-- which would silently wipe the other 19 books' titles for either of two real causes: (1) mcr.ttl
-- is locked/inaccessible right now (confirmed_missing false), not actually absent; (2) mcr.ttl WAS
-- read successfully earlier in this exact run but now reads as missing, meaning this run's own
-- prior write to it removed the live file and then failed to rename the replacement back into
-- place, so "missing" here is not "never created", it's "mid-failure".
function M.title_write_is_safe(ttl_header, confirmed_missing, ttl_confirmed_existing_this_run)
  if ttl_header then
    return true
  end
  if ttl_confirmed_existing_this_run then
    return false, 'mcr.ttl went missing mid-run (an earlier write may not have completed)'
  end
  if not confirmed_missing then
    return false, 'could not read mcr.ttl (locked or inaccessible)'
  end
  return true
end

-- ─────────────────────────── hash + emptiness ───────────────────────────

-- Content fingerprint for push-dedup: sha2.sha256 (vendored, GM-audited byte-for-byte, see
-- lib/sha2.lua) over the book's meaningful bytes concatenated in a FIXED page/macro/line order
-- (never Lua's `pairs()`, whose iteration order is not guaranteed), so identical macro content
-- always hashes identically and any real edit changes the digest.
function M.hash_book(pages)
  local parts = {}
  for p = 1, M.PAGES_PER_BOOK do
    local page = pages[p]
    local page_macros = (page and page.macros) or M.blank_macros()
    for m = 1, M.MACROS_PER_PAGE do
      local macro = page_macros[m]
      parts[#parts + 1] = macro.name
      for l = 1, LINES_PER_MACRO do
        parts[#parts + 1] = macro.lines[l]
      end
    end
  end
  return sha2.sha256(table.concat(parts, '\0'))
end

function M.is_blank_book(pages)
  for p = 1, M.PAGES_PER_BOOK do
    local page = pages[p]
    if page then
      for m = 1, M.MACROS_PER_PAGE do
        local macro = page.macros[m]
        if macro.name ~= '' then
          return false
        end
        for l = 1, LINES_PER_MACRO do
          if macro.lines[l] ~= '' then
            return false
          end
        end
      end
    end
  end
  return true
end

-- Converts a (possibly partial, e.g. only the populated slots) macro list, as pulled over the
-- wire, into the dense 20-slot array encode_page_bytes expects, using the SAME slot numbering
-- parse_page_bytes decodes (1-10 = Ctrl 1-10, 11-20 = Alt 1-10). Any slot the list does not cover
-- defaults to blank, never leaves a hole.
function M.macros_to_slots(macros_list)
  local slots = M.blank_macros()
  for _, macro in ipairs(macros_list or {}) do
    local slot
    if macro.set == 'Ctrl' then
      slot = macro.position
    elseif macro.set == 'Alt' then
      slot = 10 + macro.position
    end
    if slot and slot >= 1 and slot <= M.MACROS_PER_PAGE then
      slots[slot] = { set = macro.set, position = macro.position, name = macro.name or '', lines = macro.lines or {} }
    end
  end
  return slots
end

-- ─────────────────────────── encode (EPIC MACRO M4) ───────────────────────────

-- No original file to carry a header/reserved-bytes forward from (see the module header's
-- "Header handling" note): a zeroed 24-byte header, the least-verified of the two fallback paths.
function M.default_header()
  return string.rep('\0', HEADER_SIZE)
end

-- Right-pads `text` to exactly `width` bytes with NUL, matching the game's own null-padded fixed
-- fields; a `width`-length `text` is returned as-is (no room for a terminator, and none is needed,
-- decode reads the full field literally in that case, see parse_page_bytes/cstring). Returns
-- nil, error when `text` is longer than the field can hold (should never happen: every caller of
-- the encoder already validated name<=10/line<=61 upstream, at the ingest schema or the web PATCH
-- schema, packages/validators/src/schema/macros.ts; this is a defensive last check, not the
-- primary guard).
local function pad_field(text, width)
  text = text or ''
  if #text > width then
    return nil, 'field is ' .. #text .. ' bytes, exceeds the ' .. width .. '-byte DAT field width'
  elseif #text == width then
    return text
  end
  return text .. string.rep('\0', width - #text)
end

-- Encodes 20 dense macro slots (see macros_to_slots) into the exact 7624-byte page layout.
-- `header` (24 bytes) and `reserved_by_slot` (20 x 4 bytes) are OPAQUE fields this module never
-- interprets; callers MUST supply them from the freshly-read original file on disk when one
-- exists (M.parse_page_file), so unchanged bytes round-trip byte-identical and an edited page
-- keeps every field this decoder does not understand untouched. Missing values fall back to
-- zero-filled defaults (a brand-new page with no prior file), the least-verified path, see the
-- module header. Returns the encoded string, or nil, error on a malformed input (never a partial
-- write: this function only ever returns a complete, correctly-sized buffer or nothing at all).
function M.encode_page_bytes(macros, header, reserved_by_slot)
  header = header or M.default_header()
  if #header ~= HEADER_SIZE then
    return nil, 'header is ' .. #header .. ' bytes, expected exactly ' .. HEADER_SIZE
  end
  local parts = { header }
  for i = 0, M.MACROS_PER_PAGE - 1 do
    local slot = i + 1
    local macro = macros and macros[slot]
    local reserved = (reserved_by_slot and reserved_by_slot[slot]) or string.rep('\0', SKIP_SIZE)
    if #reserved ~= SKIP_SIZE then
      return nil, 'reserved bytes for slot ' .. slot .. ' are ' .. #reserved .. ' bytes, expected ' .. SKIP_SIZE
    end
    parts[#parts + 1] = reserved
    for j = 1, LINES_PER_MACRO do
      local line = macro and macro.lines and macro.lines[j] or ''
      local encoded_line, line_err = pad_field(line, LINE_SIZE)
      if not encoded_line then
        return nil, 'macro slot ' .. slot .. ' line ' .. j .. ': ' .. line_err
      end
      parts[#parts + 1] = encoded_line
    end
    local encoded_name, name_err = pad_field(macro and macro.name or '', NAME_SIZE)
    if not encoded_name then
      return nil, 'macro slot ' .. slot .. ' name: ' .. name_err
    end
    parts[#parts + 1] = encoded_name
  end
  local encoded = table.concat(parts)
  if #encoded ~= PAGE_SIZE then
    return nil, 'internal encode error: produced ' .. #encoded .. ' bytes, expected ' .. PAGE_SIZE
  end
  return encoded
end

-- Encodes the 20-book titles table (see parse_titles) into the exact mcr.ttl layout. `header`
-- (24 bytes), same opaque-carry-forward rule as encode_page_bytes.
function M.encode_titles_bytes(titles, header)
  header = header or M.default_header()
  if #header ~= HEADER_SIZE then
    return nil, 'header is ' .. #header .. ' bytes, expected exactly ' .. HEADER_SIZE
  end
  local parts = { header }
  for i = 1, M.BOOKS_MAX do
    local encoded_title, title_err = pad_field((titles and titles[i]) or '', TITLE_SIZE)
    if not encoded_title then
      return nil, 'title ' .. i .. ': ' .. title_err
    end
    parts[#parts + 1] = encoded_title
  end
  local encoded = table.concat(parts)
  local expected = HEADER_SIZE + M.BOOKS_MAX * TITLE_SIZE
  if #encoded ~= expected then
    return nil, 'internal encode error: produced ' .. #encoded .. ' bytes, expected ' .. expected
  end
  return encoded
end

-- ─────────────────────────── whitelisted local write-back (EPIC MACRO M4) ───────────────────────────
-- HARD GATE. Every write in this module funnels through write_bytes_verified below, which checks
-- assert_write_target immediately before its own `io.open(...'wb'...)`, so EVERY write-open in this
-- file is gated, not just the final live-file target. Whitelisted basenames are the two live macro
-- file shapes PLUS their `.bak`/`.tmp` siblings (write_whitelisted_file's backup-before-write and
-- atomic-staged-write steps write those two derived paths before the live file is ever touched, see
-- Finding 10 hardening below: an earlier version wrote the `.bak`/`.tmp` siblings directly, bypassing
-- this gate). The full path must also resolve under the caller-supplied macro_dir; anything else is
-- refused with no write attempted. There is no other `io.open(...'w'...)` anywhere in this file.
local DAT_PATTERN = '^mcr%d*%.dat$'
local TTL_PATTERN = '^mcr%.ttl$'
local DAT_BAK_PATTERN = '^mcr%d*%.dat%.bak$'
local DAT_TMP_PATTERN = '^mcr%d*%.dat%.tmp$'
local TTL_BAK_PATTERN = '^mcr%.ttl%.bak$'
local TTL_TMP_PATTERN = '^mcr%.ttl%.tmp$'

local function basename(path)
  return path:match('([^\\/]+)$') or path
end

local function is_whitelisted_basename(name)
  return name:match(DAT_PATTERN) ~= nil
    or name:match(TTL_PATTERN) ~= nil
    or name:match(DAT_BAK_PATTERN) ~= nil
    or name:match(DAT_TMP_PATTERN) ~= nil
    or name:match(TTL_BAK_PATTERN) ~= nil
    or name:match(TTL_TMP_PATTERN) ~= nil
end

-- true, nil on an allowed target; false, reason otherwise. `path` must be macro_dir concatenated
-- with a filename THIS MODULE generated (M.page_filename / the literal 'mcr.ttl', optionally with a
-- '.bak'/'.tmp' suffix THIS MODULE appended), never a caller- or network-supplied path, so the
-- "resolves under macro_dir" check is a real containment guarantee and not just string comparison
-- against an attacker-chosen prefix.
local function assert_write_target(macro_dir, path)
  if not macro_dir or macro_dir == '' then
    return false, 'refused: no macro directory resolved'
  end
  if path:sub(1, #macro_dir) ~= macro_dir then
    return false, 'refused: path does not resolve under the configured macro directory'
  end
  local name = basename(path)
  if not is_whitelisted_basename(name) then
    return false,
      'refused: "' .. name .. '" is not a whitelisted macro file (must match mcr%d*.dat, mcr.ttl, or a .bak/.tmp sibling)'
  end
  return true
end

-- Writes `bytes` to `path` and VERIFIES it actually landed before returning success: checks every
-- io.open/file:write/file:close return value, then re-opens the file and confirms its on-disk byte
-- length matches what was meant to be written. Stock Lua exposes no fsync/flush-to-disk call, so
-- this re-open-and-length-check is the strongest signal available that a short write (e.g. disk
-- full) didn't silently truncate the file. On ANY failure the partially-written file at `path` is
-- removed (never left as a corrupt/truncated stray) and false+reason is returned; the CALLER's
-- pre-existing file at that same path, if any, is untouched by this function; only
-- write_whitelisted_file below ever removes/replaces a live macro file, and only after this
-- succeeds for both the backup and the staged write (see Finding MACRO-02 hardening below).
--
-- Re-checks assert_write_target on `path` itself before opening (Finding 10 hardening,
-- 2026-07-19): this is the ONE function that ever calls `io.open(...'wb'...)` in this module, so
-- gating HERE (rather than trusting every call site to have already gated its own path) means every
-- write-open is covered, including the `.bak`/`.tmp` siblings write_whitelisted_file writes below,
-- which previously called this function directly with no gate on those derived paths.
local function write_bytes_verified(macro_dir, path, bytes)
  local gate_ok, gate_reason = assert_write_target(macro_dir, path)
  if not gate_ok then
    return false, gate_reason
  end
  local f, open_err = io.open(path, 'wb')
  if not f then
    return false, 'could not open ' .. path .. ' for writing: ' .. tostring(open_err)
  end
  local write_ok, write_err = f:write(bytes)
  local close_ok, close_err = f:close()
  if not write_ok then
    os.remove(path)
    return false, 'write failed for ' .. path .. ': ' .. tostring(write_err)
  end
  if not close_ok then
    os.remove(path)
    return false, 'close failed for ' .. path .. ' (data may not be flushed to disk): ' .. tostring(close_err)
  end
  local verify = read_file(path)
  if not verify or #verify ~= #bytes then
    os.remove(path)
    return false,
      path .. ': verification read-back failed (expected ' .. #bytes .. ' bytes, got ' .. (verify and #verify or 0) .. ')'
  end
  return true
end

-- Backs up whatever currently exists at `path` to `path .. '.bak'` FIRST (so a bad encode can
-- always be recovered by hand), writes the new bytes to a `.tmp` sibling, and VERIFIES both of
-- those writes (see write_bytes_verified above) BEFORE the live file at `path` is ever touched
-- (Finding MACRO-02 hardening, 2026-07-19: a prior version called os.remove(path) / overwrote the
-- original before confirming the backup and staged bytes actually made it to disk, so a disk-full
-- or other short write could destroy the live macro AND leave a truncated backup, with no way back
-- for the player). If either the backup or the staged write fails verification, the write is
-- aborted here and the original file at `path` is left completely untouched, no os.remove has run
-- yet. Only once both are confirmed good does the `.tmp` get swapped into place: stock Lua's
-- os.rename cannot overwrite an existing file on Windows (there is no atomic replace available
-- without a WinAPI call this environment does not expose), so this final step is remove-then-
-- rename; the now-verified `.bak` means the pre-write bytes are always recoverable by hand even in
-- the narrow window between those two calls.
local function write_whitelisted_file(macro_dir, path, bytes)
  local ok, reason = assert_write_target(macro_dir, path)
  if not ok then
    return false, reason
  end

  local original = read_file(path)
  if original then
    local bak_ok, bak_err = write_bytes_verified(macro_dir, path .. '.bak', original)
    if not bak_ok then
      return false, 'backup failed, original left untouched: ' .. bak_err
    end
  end

  local tmp_path = path .. '.tmp'
  local tmp_ok, tmp_err = write_bytes_verified(macro_dir, tmp_path, bytes)
  if not tmp_ok then
    return false, 'staged write failed, original left untouched: ' .. tmp_err
  end

  os.remove(path)
  local renamed, err = os.rename(tmp_path, path)
  if not renamed then
    return false,
      'rename failed: ' .. tostring(err) .. ' (staged bytes remain at ' .. tmp_path .. ', restore from ' .. path .. '.bak if needed)'
  end
  return true
end

-- Writes one encoded 7624-byte page. `file_index` is the same 0-based index page_filename() uses.
function M.write_page_file(macro_dir, file_index, bytes)
  if #bytes ~= PAGE_SIZE then
    return false, 'refused: encoded page is ' .. #bytes .. ' bytes, expected exactly ' .. PAGE_SIZE
  end
  return write_whitelisted_file(macro_dir, macro_dir .. M.page_filename(file_index), bytes)
end

-- Writes the encoded mcr.ttl titles file.
function M.write_titles_file(macro_dir, bytes)
  local expected = HEADER_SIZE + M.BOOKS_MAX * TITLE_SIZE
  if #bytes ~= expected then
    return false, 'refused: encoded titles file is ' .. #bytes .. ' bytes, expected exactly ' .. expected
  end
  return write_whitelisted_file(macro_dir, macro_dir .. 'mcr.ttl', bytes)
end

return M
