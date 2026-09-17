# Lootryx object icons

`art-coffer.png`, `art-envelope.png`, `art-ledger.png` and `art-pennant.png`
are original ImageGen illustrations created individually for the approved addon
design. `art-pearl.png` and `art-clock.png` were drawn locally for this design.
These six PNGs have transparent backgrounds and are displayed at 28px.

Local source studies: `design/addon-preview/icons/`, including the generated
masters and the small-size review sheet. The runtime uses only these bundled PNGs.
The renderer uses white tint for their authored colours, and still uses semantic
theme colours for the original monochrome controls.

No extracted FFXI item art or third-party character sprites are included in this
object family. Local item-icon extraction is a separate implementation.

## Dedicated action icons (2026-09-11)

Eight original illustrations generated separately with the built-in ImageGen tool:
`art-drop.png`, `art-alliance.png`, `art-standings.png`, `art-calendar.png`,
`art-bounty.png`, `art-poll.png`, `art-lookup.png`, and `art-recent.png`.
Bank retains `art-coffer.png`; game item rows retain actual local DAT artwork.

The new files are 64x64 RGBA PNGs, displayed at 28px with white tint. Generated
alpha is preserved through downscaling. Combined compressed size: 67,177 bytes.
Only these small runtime files ship, not the large source images.

Sources: `design/addon-preview/icons/masters/action-*.png`.
Exact prompts: `design/addon-preview/icons/masters/action-icons-prompts.md`.
Review sheet: `design/addon-preview/icons/action-icons-review.png`.
Rebuild: `design/addon-preview/icons/build-action-icons.py`.

## Me and Settings artwork (2026-09-11)

Me uses six individually generated ImageGen illustrations: character, coins,
macrobook, jobs, wishlist and claim. The 64px RGBA PNGs total 39,991 bytes and
render at 28px. Exact prompts: design/addon-preview/icons/masters/me-icons-prompts.md.
Masters remain in that folder; build-me-icons.py preserves generated alpha.

Settings uses seven precisely drawn bronze/teal icons (window, compact overlay,
snapshot ledger, compass, quill, connection links and diagnostic cog), rendered
at 24px. Source: design/addon-preview/icons/build-settings-icons.py. Status badges
remain separate from artwork and retain their semantic theme colors.


## Role emblems (2026-09-15)

role_any/tank/healer/support/dps.png are five newly generated fantasy inventory
illustrations, not game-extracted or copied from Catseye. ImageGen created a
reference sheet then individual transparent assets: golden three-gem party crest,
blue steel shield, ivory/emerald healing staff, purple/gold harp and crossed swords.
Exports are 64px RGBA, 25,408 bytes total; picker displays at 32px without tint.
High-resolution sources remain in design/addon-ui-lab/role-masters. Standard
bicubic export preserves alpha. Text labels and selected markers remain independent.
