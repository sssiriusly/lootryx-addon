# Game interaction and GM audit guide

This guide maps the addon's game-client reads, local writes and network requests
to the source files for Windower 4 and Ashita v4. Server staff decide whether
these capabilities are allowed on their server.

## Boundary: game client versus Lootryx service

The addon reads supported client state. It makes authenticated requests to Lootryx
for community features. Creating an auction, joining a recruitment roster or capturing
attendance changes Lootryx records, not the FFXI server's party or loot state.
The code does not send gameplay packets or automate movement, targeting, combat,
lot/pass or chat-command submission. Local chat-buffer and macro-file writes are
explicit exceptions to a read-only-client description and are detailed below.

## Client reads

| Capability | Purpose | Review source |
| --- | --- | --- |
| Own character, login, main/subjob and available learned job levels | Identity, session isolation and reviewed job sync | `lootryx.lua`, `lib/windower-host.lua`, `lib/windower-state.lua`, `lib/ashita-host.lua`, `lib/ashita-state.lua`, `lib/client-state.lua` |
| Party/alliance names, IDs and zones | Roster preview, attendance, own-party display and optional zone reporting | Same host/state adapters, `lib/roster.lua`, `lib/attendance.lua` |
| Current selected target name | Explicit ToD target suggestion; does not select or change a target | Host `read_target` methods, `lib/tod-input.lua` |
| Treasure-pool entries and available timestamps | Explicit item selection and auction deadline checks; no lot/pass | `lootryx.lua`, host adapters |
| Local item ROM records and resource names | Item-name lookup and local icon decoding | `lib/item-icons.lua`, host resource adapters |
| Local macro books and titles | Explicit upload, comparison and guarded download | `lib/macros.lua`, `lootryx.lua` |
| Current unsent chat input | Preserve an existing draft before explicit prefill | `lib/chat-prefill.lua`, host adapters |
| Clipboard on supported paste actions, mouse and keyboard events | Addon fields, pointer alignment and GUI navigation | `lib/field.lua`, `lib/ashita-input.lua`, `lib/windower-pointer.lua`, host adapters |

There is no chat-log subscription or combat/death packet monitoring. A witnessed time
of death is a manual report, not detection of a kill. Client observations are not
server-attested proof. Manually included attendance names are distinguished from
client-observed names by the roster policy.

## Local writes and user control

- **Chat input:** only validated `/tell`, `/pcmd add` and `/pcmd kick` drafts.
  Names accept 3 to 15 letters. A nonempty unrelated draft is preserved. When the
  game chat prompt is closed, the draft is held for up to 30 seconds and inserted
  after the player opens chat. The addon does not simulate Enter or send it.
  Inspect `build`, `prepare` and `poll` in `lib/chat-prefill.lua` and the host
  `get_chat_draft`, `chat_is_open` and `set_chat_draft` implementations.
- **Macro files:** explicit download can write local `mcr*.dat` and `mcr.ttl` with
  safety/backup siblings. The active book is supplied by the player, not detected
  automatically. The writer refuses that book and restricts destination filenames.
  Inspect `lib/macros.lua` and the macro handlers in `lootryx.lua`.
- **Settings:** Windower config data and Ashita `config/lootryx/<name>_<server-id>.json`
  contain connection settings and preferences. Ashita uses staged writes and backups.
  Treat these files as secrets and exclude them from bug reports and redistribution.
- **Item images:** Windower decodes local game artwork into numeric BMP cache entries
  under `assets/item-cache/`. It does not modify DAT files. Extracted artwork is not
  included in this export. Ashita draws through its resource/texture facilities.
- **Results:** an explicit Results export writes `lootryx-results.txt` in the addon
  folder. Review its contents for private information before sharing.
- **GUI resources:** drawing allocates addon UI resources. Ashita FFI is used for
  rendering and SDK interoperability; its presence is not evidence of packet use.

Explicit website links use the loader's URL-opening facility. Export opening uses
the host's file-opening facility. There is no separate executable or helper process
bundled with this addon. Loader-provided facilities and libraries are dependencies,
not implementations audited by this repository.

## External traffic and data

The default service base is `https://lootryx.com/api/ingest`. The configured HTTPS
base can differ. The transport permits plain HTTP only for loopback development.
Requests use the configured identity and signing credentials; never disclose them.

| Trigger | Data or operation |
| --- | --- |
| Pairing | Pairing code and character identity used to establish the connection |
| Manual capture or enabled automatic snapshots | Character/alliance names, event/report context and roster adjustments |
| Enabled zone heartbeat | Own identity and zone context for eligible linkshell coverage |
| Reviewed job sync | Observed own job levels and equipped jobs |
| Explicit macro upload | Local macro titles/commands and synchronization information |
| Explicit listing, bid, event, ToD or other community action | The fields entered/reviewed for that Lootryx action |
| Enabled refresh/notification polling | Reads for supported community activity and result changes |

Review endpoint construction and payload assembly in `lootryx.lua`,
`lib/attendance.lua` and `lib/recruitment.lua`. Automatic snapshots and zone heartbeat
are off by default. Notification/background preferences can initiate reads without
another click. Disabling chat alerts is not necessarily disabling background refresh;
inspect the separate preferences. No automatic kill reporting is implemented.

**Separate DNS destination:** `lib/doh-resolver.lua` resolves the service hostname
through `https://cloudflare-dns.com/dns-query`. The resolver receives the queried
hostname and normal connection metadata; the addon does not attach Lootryx signing
headers or gameplay-report bodies to that DNS request. This is a third-party network
connection and should be considered in server review.

Review `lib/async-http.lua`, `lib/verified-https.lua`, `lib/doh-resolver.lua`,
`lib/http-response.lua` and `lib/async-jobs.lua` for frame-stepped transport, bounded
requests, certificate-chain/hostname checks, redirect refusal and cancellation.
The bundled trust roots are static release data, not a runtime download. This is
not a guarantee of zero frame-time cost on every client or network stack.

## Audit entry points

Start with the explicit host selection in `lootryx.lua`, then review each host adapter.
Windower registers load, addon-command, prerender, mouse, keyboard and unload handlers.
Ashita bridges supported command, frame, input and unload events into the shared code.
Inspect `register_event` call sites and the Ashita registration layer directly.

Useful searches from the repository root:

```text
rg -n 'register_event|events.register' lootryx.lua lib
rg -n 'io.open|os.rename|os.remove|set_chat_draft|SetInputText|set_input' lootryx.lua lib
rg -n 'https://|request|post\(' lootryx.lua lib
rg -n 'inject|send_packet|queue_command|os.execute|io.popen' lootryx.lua lib
```

Matches can be comments or prohibitions. Read the surrounding implementation instead
of treating keyword presence or absence as proof. Review the JSON, hashing, macro,
icon and TLS code as well as the main entry point. Verify source hashes against
`MANIFEST.sha256` and examine changes between revisions.

## Approval and test limits

Phoenix staff reviewed this addon and approved it for use on Phoenix (2026-09-22).
Any change to its features is resubmitted for review before release; cosmetic
changes are not. This is not a game-vendor endorsement and says nothing about
other servers' rules. See
[validation](VALIDATION.md) for automated results and the remaining two-client,
real-loader acceptance steps. Third-party rights are listed in
[the notices](../THIRD-PARTY-NOTICES.md).
