# Lootryx Addon

[Lootryx](https://lootryx.com) helps Final Fantasy XI linkshells organize events,
track attendance and DKP, distribute loot, and follow HNM spawn windows.

The addon brings your linkshell's DKP, auctions and attendance into the game,
with support for **Windower 4 and Ashita v4**. Use the website for planning,
administration and detailed records, and the addon while you play.

## Download

| Windower 4 | Ashita v4 |
| --- | --- |
| **[Download for Windower 4](https://github.com/sssiriusly/lootryx-addon/releases/download/v0.40.34/Lootryx-v0.40.34-Windower.zip)** | **[Download for Ashita v4](https://github.com/sssiriusly/lootryx-addon/releases/download/v0.40.34/Lootryx-v0.40.34-Ashita.zip)** |
| `//lua load lootryx` | `/addon load lootryx` |

Extract the ZIP and copy its `lootryx` folder into your loader's `addons` folder.
Each download includes installation instructions for that loader. Both contain the
same shared addon runtime, which detects Windower or Ashita automatically.

[Release notes and checksums](https://github.com/sssiriusly/lootryx-addon/releases/tag/v0.40.34)
 · [Full installation guide](docs/INSTALL.md)

![Home with an active auction and separate DKP balances](docs/screenshots/01-home.png)

*Previews use the v0.40.34 Lua window layouts and fictional demo data, rendered
in a browser. They are not live game captures. Native fonts and Ashita's ImGui
presentation can differ.*

## DKP and bidding

Check your balances and standings, including separate DKP wallets when your
linkshell enables them. Open an auction, check its wallet and rules, enter your
offer, then review before submitting. The amount charged follows the auction's
configured rules and is not necessarily your bid.

![Review an auction offer, wallet and minimum](docs/screenshots/05-auction.png)

## Camps, events and ready checks

Join a session explicitly, then answer **Present and ready** or **AFK / unavailable**
when a timed attendance check opens. You can respond through the addon or website.
The addon never answers for you.

Officers choose the attendance rules and wallet before starting a session. After
ending it, they review attendance, record exceptions and post the reviewed DKP.
Estimates are not spendable points. An immediate **Ready check now** checks
availability only and awards no DKP.

![Answer a timed attendance check](docs/screenshots/09-ready-check.png)

[Member and officer attendance walkthrough](docs/ATTENDANCE.md)

## HNM windows and time of death

Browse tracked windows, manually report a witnessed time of death, and follow a
hunt in the compact overlay while the main window is minimized. The overlay shows
your linkshell and the tracked window countdown. It does not detect spawns or kills.

![Tracked HNM windows](docs/screenshots/07-hnm-windows.png)

## Connect and customize

Get a pairing code from Lootryx, open **Me > Connection**, and paste the code or
complete setup command. Keep it private. Settings include background opacity,
notification preferences and optional reporting controls.

[Install, pair and update](docs/INSTALL.md) · [Browse all previews](docs/screenshots/README.md)

## Optional tools

Party finding and linkshell discovery are available through **Community tools** in
Settings, off by default. Recruitment is separate from your actual game party.
Tell, Invite and Kick actions prepare chat drafts for you to review and send.

Local macro-book upload and download are also available. Downloads write your
local macro files after review, with safeguards and backups.

## How the addon interacts with FFXI

The addon reads supported client state and sends selected reports to Lootryx. It does
not automate movement, targeting, combat, lot/pass, or submit chat commands. Explicit
chat actions read/preserve the current draft and write only the local input buffer;
the player submits it. Optional macro downloads write the player's local macro files.
It also writes addon settings, an item-icon cache and explicitly exported result text.

The [GM audit guide](docs/GAME-INTERACTION.md) maps reads, local writes, network traffic,
background behavior and dependencies to source files.

Phoenix staff reviewed this addon and approved it for use on Phoenix. Any change to
its features is resubmitted for review before release; cosmetic changes are not.

## Documentation and feedback

- [Install, pair, update and troubleshoot](docs/INSTALL.md)
- [Game interaction and GM audit guide](docs/GAME-INTERACTION.md)
- [Testing and release verification](docs/VALIDATION.md)
- [Website documentation](https://lootryx.com/docs/addon)
- [Report an issue](https://github.com/sssiriusly/lootryx-addon/issues)

For bug reports, include the addon version, loader/version, screen or command, expected
behavior and exact error. Remove pairing codes, secrets and private member information.
Do not attach settings files. See [SECURITY.md](SECURITY.md) for security reporting.

## License

[Source-available, with restrictions](LICENSE), not open source. Player use, source
inspection and private modifications are permitted. Resale, commercial code reuse and
redistribution require permission, subject to the license's exceptions. Ordinary use in
monetized gameplay videos or streams is permitted. Third-party material retains its own
terms: [third-party notices](THIRD-PARTY-NOTICES.md).
