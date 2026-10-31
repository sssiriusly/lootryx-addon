# Testing and release verification

## Compatibility

Lootryx supports Windower 4 and Ashita v4. Both have been tested in game.

## Automated checks

The v0.40.34 source passed 1,214 addon harness tests. The associated website and
service release passed 1,108 website tests and 2,242 API tests, plus workspace
type checks, lint and production build. The public and installed addon exports
each passed seven focused attendance tests. All 44 Lua files compiled using
Windower's Lua 5.1 runtime.

The attendance audit covered explicit joining and responses, session switching,
stale officer reviews, concurrent corrections, permissions and reviewed posting.
The test harness is maintained separately from this addon repository. Its mock
clients do not prove live game rendering, input or notification delivery.

Both loaders have prior in-game testing. Fresh live-client acceptance of the
v0.40.34 attendance changes is still outstanding on Windower and Ashita. Do not
interpret the automated totals as completion of that acceptance.

README previews use the current Lua layouts and fictional data rendered in a
browser. They are Windower-layout previews, not Ashita ImGui or live game captures.

## Release verification

`MANIFEST.sha256` records repository file hashes, excluding itself. Each release
also includes `SHA256SUMS.txt` for the two downloadable ZIPs. Compare downloads
with these SHA-256 hashes to verify their contents.

The Windower and Ashita downloads contain the same addon source and assets,
with installation instructions for each loader. Local settings, credentials,
macro files and generated result exports are excluded.

## Live-client regression checklist

Use this checklist when testing an update. Automated checks and prior in-game
testing do not establish coverage of every item for each release package.

- Fresh install, pairing, reload and saved settings on each loader.
- Pointer alignment, fonts, icons and chat preparation with open and closed chat.
- Listing discovery, recruitment, ready checks and notification preferences.
- Member and officer permissions, event check-in, roster capture and closing.
- Bid confirmation, auction results, wallet charges and connection recovery.
- Macro transfers using backed-up disposable books, including active-book refusal.

For source review, see the [game interaction guide](GAME-INTERACTION.md).
Server approval is separate from technical testing.
