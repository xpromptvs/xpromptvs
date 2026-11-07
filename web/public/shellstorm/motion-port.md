# Original ShellStorm animation port

Original source snapshot: `docs/design/shellstorm-reference/source/` in the rdev repository.
Its history and checksum manifest are archived alongside it; the retired checkout is not required.
See `docs/ui-design.md` for current accepted behavior and pending architecture work.

These modules began as ports of the prototype's actual animation algorithms. They are no longer
byte-for-byte copies: current adaptations include fixed-width Connect/Cancel controls, raster
halos with opacity-only animation, host/browser lifecycle integration, and the shared debug clock.
The original source hashes below record initial port provenance; `manifest.json` in the archive
records the later final reference snapshot (including working-tree changes).

The source's CardMotion is intentionally dormant (`CardMotion.setReduced(true)` in `app.js`), so
this port does not turn on the dormant card spring. Workspace tabs retain the source's hover fade.

Source SHA-256 values (before the selector/host adaptations):

- `connection-motion.js`: `aeef7f2b1af689191dd9c6be95b6be7318b3c0cf7530859cef89178860bf4cb4`
- `computer-motion.js`: `85148ac3b74788656b3b63822a822545a7627bc0d31cc0a3e1cab4fc99035feb`
- `session-motion.js`: `2f7aa43f883754efa04a5d6fbdf61a71b641c9de024825da974aeffb4d97f1de`
- `motion-debug.js`: `9880973290e821f8c967e165a47094863f5b67863fc2fe99916356eef150d5f3`
- `style.css`: `912a2891d3413aa7805dcbb0513e7ba00a8175fac9ca09f2391643b919b20a5c`
- `app.js`: `8cd70901716640b77bade92fcc9427f536fc977ca5e725d764cd842c32efbc0e`


Glows now use cached canvas-rasterized Gaussian sprites (`glow-raster.js`) instead of live CSS/SVG
blur filters. This avoids missing WebKit SVG halos and Safari cursor filter trails. The computer
halo keeps a fixed footprint and breathes through opacity only; screen ignition and cursor opacity
keyframes retain their original timings. Cursor sprites include dark ink for the light theme.

Connect controls now reserve the measured maximum of “Connect” and “Cancel”, including padding
and borders. While pending they show “Cancel” with a brief fade, without the former width/cross-slot
morph. Mobile rows no longer wrap to accommodate the pending action; status and names remain on
one line. The shared slow-motion clock and reduced-motion behavior still apply.
