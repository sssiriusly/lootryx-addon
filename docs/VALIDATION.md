# Testing and release verification

## Compatibility

Lootryx supports Windower 4 and Ashita v4. Both have been tested in game.

## Automated checks

The v0.40.31 runtime passed 1,188 checks across 71 test files and syntax checks
for 43 Lua files using Windower Lua 5.1. Tests cover input and layouts, pairing,
recruitment, auctions, attendance, notifications, network failures, macro safety,
permissions and persistence.

The test harness is maintained separately from this addon repository. Runtime
tests loaded this addon export; static checks also used the matching development
source. These checks use fixtures and do not replace live-client testing.

README screenshots use demo data rendered from the shared Lua layouts. Native
fonts and rendering can differ.

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
