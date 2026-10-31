# Install and connect

## Windower 4

1. Download `Lootryx-v0.40.34-Windower.zip` from the README and extract it.
2. Copy its `lootryx` folder into Windower's `addons`
   folder. The entry point must be `addons/lootryx/lootryx.lua`, not nested twice.
3. Keep `lib/` and `assets/` beside `lootryx.lua`.
4. In game, run `//lua load lootryx`, then `//lootryx window`.
5. Sign in at https://lootryx.com and obtain an addon pairing code. In the addon,
   open Me > Connection and paste the code or complete setup command. Treat it as private.
   Alternatively, use `//lootryx setup CODE` in game. Use a fresh code if it expires.
6. Use `//lootryx status` and `//lootryx selftest` to inspect setup problems.

No Node.js, separate executable or background helper is required at runtime.
Windower's supplied Lua libraries must be available, including LuaSocket/LuaSec for
verified HTTPS. Missing TLS support fails closed. Do not disable verification.
Settings are created by the addon. Do not copy a development settings template.

## Ashita v4

Download `Lootryx-v0.40.34-Ashita.zip` from the README and extract it.
Copy its `lootryx` folder into Ashita's `addons` directory. Load with
`/addon load lootryx`, then `/lootryx window` and `/lootryx selftest`.
Use Me > Connection to pair, or run `/lootryx setup CODE` in game.
Use one slash on Ashita and two on Windower. A setup code is not a legacy link code.
Windower credentials are not silently imported.
The host uses Ashita's supplied common, ImGui, Direct3D, FFI, JSON and socket libraries.

## Updating

Unload the addon, back up your settings, and replace only the distributed runtime and
asset files. Preserve `data/` on Windower and Ashita's `config/lootryx/` directory.
Reload afterwards. Never upload these settings directories to GitHub.

## First-use checks

- Optional Find: enable Community tools in Settings, then browse Players or Parties.
- Compact overlay: use Linkshell > HNM > Follow beside your hunt, then minimize.
- Appearance: set Background opacity in Settings.
- Auctions: inspect the selected wallet, minimum, offer and confirmation before bidding.
- Attendance sessions: run `//lootryx camp` on Windower or `/lootryx camp` on Ashita. Join explicitly, then answer Ready or AFK when prompted. Officers start, end, correct and review before posting points. Legacy snapshot capture still requires an open event check-in.
- Notifications: inspect refresh and chat preferences. Offline clients cannot promise
  immediate delivery of changes they have not fetched.
- Macros: back up game macros and correctly identify the active book before downloads.
- Pointer: if game and addon coordinates disagree, use Settings > Align pointer.

## Troubleshooting

Use the GUI first; `//lootryx help` lists commands on Windower and `/lootryx help` on
Ashita. `status` is local diagnostic output. A pending request should finish or time
out before another network operation; local navigation is separate. Check connection
status and TLS dependencies for network errors. Never paste credentials into an issue.

For a missing action, check linkshell membership and role permissions. For missing
listings, clear filters, check the world and refresh. Check-in availability and scoring
are server-side decisions; a local roster preview is not an attendance award.
