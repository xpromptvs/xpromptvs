# Data-channel protocols (over WebRTC, after connect)

Four channels, created up-front by the host, each delivering its messages whole, in order, exactly once. Since
2026-10-12 the first three are the STREAMS of one data channel, `lane` ("The lane", below), and the paste and image
transfers ride the fourth, `bulk`.

| Channel | Direction | Payload |
|---------|-----------|---------|
| `terminal` | host → client | the terminal WIRE: RZT1, one shared zstd stream per driver wire (docs/terminal.md; `TermFrame.swift`, `web/src/client/term-frame.ts`). Not enveloped. |
| `input` | client → host | touch / key JSON (schema/input.schema.json) |
| `control` | both | resize / ping / pong, and many more (schema/control.schema.json) |
| `bulk` | both | the paste/drop protocol and the image viewer's (`paste-*`, `file-*`, below), and the palette's `source-thumb`s (host → client), enveloped as `control`'s |

## The lane (2026-10-12)

The host creates two data channels: **`lane`** — unordered and reliable (`{ordered: false}`, no `maxRetransmits`) —
whose three STREAMS are `terminal` 0, `input` 1 and `control` 2, and **`bulk`** (below). The page collects both by
label and hands the session its four channels once both are open. On the TEST-ONLY SCTP baseline
(`RDEV_TEST_SCTP_CHANNELS=1`) the host creates `terminal`, `input`, `control` and `bulk` as four reliable, ordered
SCTP channels instead, and no lane; the page takes whichever set completes. Why, the repair rules and every number:
docs/terminal.md, "The lane"; the design, docs/superpowers/specs/2026-10-12-terminal-lane-design.md §2.

A lane PACKET is one data-channel message of at most 1100 bytes, big-endian:

| part | layout |
|---|---|
| header (9 bytes) | `type u8 · pkt u32 · ts u32` — `pkt` numbers every packet a side sends; `ts` is the sender's ms since the lane opened |
| type 1, SOURCE | `esi u32` · one symbol |
| type 2, REPAIR | `firstESI u32 · count u16 · seed u32` · Σ cᵢ·Sᵢ over symbols `firstESI … firstESI+count−1` in GF(256) (polynomial 0x11d), the cᵢ drawn from `seed` by xorshift32 (`state % 255 + 1`; a zero seed starts at 0x9e3779b9) — as long as the longest covered symbol, the others zero-padded |
| type 3, FEEDBACK | `cumESI u32 · n u8 · n × (start u32, len u16) · loss‰ u16 · echoTs u32 · held u16` — every ESI below `cumESI` decoded, and n ≤ 16 decoded ranges above it; the receiver's loss over its last 256 packets; the `ts` of the newest packet it received, and the ms it held that before sending this |

A SYMBOL is `len u16` then `len` bytes of CHUNKS, at most 1080 bytes with its prefix — the prefix is what lets a
symbol rebuilt from zero-padded repair know where it ends. A CHUNK is `stream u8 · offset u32 · len u16 · bytes`: a
slice of that stream's bytes at that offset. Inside a stream, messages are framed `len u32 · message`, a message being
exactly what the channel it replaces carries (1 byte to 1 MiB, the envelope included).

**Counters** — `pkt`, the ESIs and stream offsets — are 32-bit on the wire. Each end keeps 64-bit values and reads a
wire value as the 64-bit one nearest its reference (`unwrapLane32` in both languages), so they wrap. The
layouts, the malformed packets and symbols a decoder must refuse, the coefficients, the seed step and the unwrap are
fixed by `protocol/fixtures/lane-vectors.json`, written by `scripts/gen_lane_vectors.py` (a third implementation,
stdlib Python) and asserted byte for byte by `PionBridge/rdev_lane_vectors_test.go` and
`web/test/lane-vectors.test.ts`; each language also decodes repair built from the vectors' coefficients. A coefficient
mismatch decodes to plausible garbage, not an error — never edit a vector by hand. The two ENGINES' rules (when to
send feedback, which repair to plan) are held to one behaviour by `protocol/fixtures/lane-parity.json`: seeded
two-engine runs whose every packet both suites hash.

## `bulk` (2026-10-12)

A reliable, ordered SCTP channel — ABI slot 3 on the host (`PionChannel.bulk`; slots 0–2 did not move) — for the
transfers where throughput matters and a stall does not: the paste/drop protocol and the image viewer's (below), each
WHOLE on `bulk`, so each keeps its order — and the palette's `source-thumb`s, a 20–35 KB JPEG each, which on the lane's
control stream held the terminal behind them; the page keys them by source id, so they need no order against
`source-list`. Its messages are enveloped as `control`'s, and the host dispatches them by
CONTENT, as it does `control`'s. On a message socket it is channel byte 4.

## Compression envelope
Every message is `[u8 codec][payload]`. Codecs: 0x00 none, 0x01 raw DEFLATE, 0x02 lzfse,
0x03 zstd (future). Send the compressed form only when strictly smaller than raw ("any
savings" rule); otherwise codec 0x00 + raw. Codecs are advertised in `hello`;
`none` is always supported. (For the skeleton both peers default to `deflate`-or-`none`,
so cross-peer codec discovery is not yet load-bearing.) Video is excluded (already codec-compressed by WebRTC).

## input messages
- `{ "t": "touch", "phase": "down"|"move"|"up", "id": 0, "x": 0.5, "y": 0.5, "ts": 12345 }`
  — coords normalized 0..1 against the sim viewport; multi-touch via multiple `id`s.
- `{ "t": "key", "data": "ls\r", "term": "pty:3" }` — raw bytes for the PTY, addressed to the tab the
  client believed it was typing into. `term` is REQUIRED: the host refuses the write when it
  disagrees with the active tab, and cannot infer a target from arrival order because
  `switch-terminal` rides `control` while these bytes ride `input`.
- `{ "t": "term-reply", "data": "\u001b[0n", "term": "pty:3" }` — a DEVICE-QUERY REPLY from the
  client's xterm.js instance for `term`, the tab whose bytes asked (shown or hidden), never typing.
  The host delivers it to that tab while it owes the tab a reply (it forwarded a query in the tab's
  bytes and answered none itself), and holds it to the keystroke rule otherwise (docs/terminal.md,
  "Who answers").

## control messages
- `{ "t": "resize", "cols": 80, "rows": 24 }` — client viewport → host PTY winsize.
- `{ "t": "ping", "ts": N }` / `{ "t": "pong", "ts": N }`.
- `{ "t": "term-palette", "fg": "#f0eef1", "bg": "#262526", "cursor": "#f0eef1", "ansi": ["#110f11", …16], "ext": { "22": "#394634", … } }`
  — client → host, on EVERY control open and on every theme change: the colours this client's xterm.js
  REPORTS to OSC 10/11/12 and OSC 4 (`xtermPalette(theme)`, measured against a real xterm.js), each
  exactly `#rrggbb`, exactly 16 ANSI, and in `ext` only the 16-255 slots the theme REPLACES ("16"…"255"
  → colour; `{}` or absent is none — the rest are xterm.js's fixed cube and greys, which the host
  computes). The dark theme replaces four: Claude Code's diff backgrounds 22/28/52/88 (docs/terminal.md,
  "Claude Code's diff colours"). Ungated and kept per client for the life of its connection;
  the DRIVER's is what the host answers a tmux tab's colour queries from when their bytes reach no
  client (docs/terminal.md, "tmux answers device queries itself"). xterm.js's own defaults until the
  driver has sent one. Anything malformed is dropped.
- `{ "t": "reopen-terminal" }` — the driver → host (⌘⇧T): the tab it CLOSED last comes back as the active
  tab — a `pty:` tab as a new shell in the directory it was in, under its name; a `tmux:` tab re-attached to
  its session, skipped for the one before it when that session has ended or is open again
  (docs/terminal.md, "Tabs that come back"). Driver-only; a window-less client may send it.
- `{ "t": "term-error", "reason": "too-many-tabs" | "nothing-to-reopen" }` — host → the driver: an
  `open-terminal` or a `reopen-terminal` was refused at the tab cap (100, both kinds counted), or a `reopen-terminal` found no closed
  tab to bring back, so the client stops waiting for that tab (docs/terminal.md).
- `{ "t": "term-bell", "term": "pty:3" }` — host → the driver: `term` rang its bell (a BEL xterm.js would
  ring — never an OSC's terminating one) in output that reached NO client context: the driver's page hidden
  and its terminal paused, a resume's gap before the tab's snapshot, a new wire before it, no wire. The
  device-query rule applied to BEL: a bell in output that reached the driver's xterm.js is its own `onBell`,
  never this. At most ONE per tab per withheld stretch (until the tab's output reaches the driver again, or
  its next snapshot); with no driver, nobody hears it. The client rings it only for a tab its `term-list`
  has, and only while it drives (docs/terminal.md, "The bell").
- `{ "t": "window-bell", "sources": ["win:11", "win:13"] }` — host → the driver: the application owning these
  windows raised its Dock badge (a badge appearing, a count growing — never the first reading, never one going
  away; a failed read is no change), so every window of it in the session — minimized ones too — rings. Read
  from the Dock's AX tree about once a second while the host has a driver (or is in its grace) and the session
  has a `win:` window; a bounce is not seen; one sent while the driver's channel is down is lost. The
  client marks them unless the person is looking at one of them, only while it drives, only windows its
  view-set has, never on a window-less client (docs/window-capture-and-input.md, "A window's bell").
- `{ "t": "tmux-error", "session": "$3" | null, "reason": "…" }` — host → the driver: a tmux request was
  refused (`unavailable`, `session-gone`, `too-many-tabs`), or the host closed a tab it could not
  snapshot twice (`snapshot-failed`; the session lives). The client forgets the session — EXCEPT for
  `rename-failed`: tmux refused a `rename-tab` (a duplicate name, the session gone), the tab and its
  session are unchanged, and the client only stops showing the name it asked for.
- **The session state (2026-09-29; docs/sources-and-focus.md, "The session state").**
  - Per connection, from ANY client:
    - `{ "t": "client-hello", "prefs": { "fps"?: n, "scale"?: "auto" | x, "bitrateBps"?: n, "codec"?:
      "auto"|"av1"|"h265"|"h264", "pointerMode"?: "direct"|"trackpad" }, "delivery"?: "rtp"|"dc" }` —
      the LAST message of every control open; the host starts a driver's video only after it. An absent
      field is the host's default, and a malformed one is ignored. `delivery` is the connection's
      transport for every window reconciled for it (the `?dc=1` instrument).
    - `{ "t": "set-prefs", "prefs": {…} }` — the WHOLE preference set, on any change.
  - The DRIVER's intents:
    - `{ "t": "subscribe", "source", "delivery"? }` (open, or un-minimize and focus);
    - `{ "t": "unsubscribe", "source", "land"?: true }` (close);
    - `{ "t": "minimize-window", "source", "land"?: true }`, `{ "t": "restore-window", "source" }`;
    - `land` (2026-10-02): the client says the person was AT the window it closes or parks — on a pinned
      layout the window on screen, on the floating one the window holding the keys — so the host lands them
      on the bar's previous tab, a TERMINAL tab too (its `term-list` first, then a `view-set` whose surface
      is the terminal's; docs/sources-and-focus.md, "The session state"). Absent is false: the window focus
      falls back and nothing else moves. Present, it must be a boolean or the message is malformed.
    - `{ "t": "set-window-position", "source", "x", "y" }` (finite, |v| ≤ 100000, at a drag's END);
    - `{ "t": "set-view", "surface"?: "terminal"|"windows", "fullscreen"?: "<source>"|null }`;
    - `{ "t": "focus-source", "source" }`;
    - `{ "t": "reattach-source", "source" }` — a fresh video track for an OPEN window (the WebCodecs
      stall recovery); the state does not change and nothing is broadcast.
    - **The bar** (2026-10-01; docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md). Both
      name a tab by its KEY — a terminal tab id (`pty:<n>`, `tmux:$<n>`) or a window's source id
      (`win:<n>`, `dsp:<n>`), exactly as the host spells it (`pty:01` is malformed) — and both are
      PERMITTED to a window-less client (they arrange the bar, not the Mac's windows):
      - `{ "t": "move-tab", "tab": "pty:2", "before": "win:4711" | null }` — move the tab to just before
        `before`, or to the END for `null`. `before` is REQUIRED; absent, `""`, a non-key or the tab
        itself is malformed. A key, never an index: a client's bar can be a SUBSET of the session's (a
        window-less client shows no windows). A tab or `before` not in the bar is refused SILENTLY, and
        a move to where the tab already is changes nothing — neither sends a `view-set`, so a client
        showing a drop ahead of its echo must fall back on its own. A moved terminal reorders the
        terminal pool too (`term-list`). With no session state (the `RDEV_TEST_PATTERN` harness) only
        terminals move, `before` a terminal or `null`.
      - `{ "t": "rename-tab", "tab": "pty:2" | "win:4711" | "tmux:$3", "name": "build" }` — `name` is
        REQUIRED: at most 256 UTF-8 BYTES and no control character (Cc), the rule
        `protocol/fixtures/tab-names.json` pins for both languages. `""` CLEARS a `pty:` or window name;
        an empty name for a `tmux:` tab is malformed. A name equal to the current one changes nothing
        and sends nothing. A `tmux:` tab's rename is its SESSION's (`rename-session`, every tmux client
        sees it): its label follows tmux's `%session-renamed` in the next `term-list` `title`, and a
        refusal is `tmux-error` `rename-failed`.
  - `{ "t": "set-source-prefs", "source", "scale"?, "crop"? }` carries only what the client DERIVES per
    window.
  - `restore-tmux` is GONE.
  - Host → every client:
    - `view-set` carries the state: `windows: [{source, minimized, x?, y?, name?}]`, `tabOrder: [key…]`,
      `focused`, `view: {surface, fullscreen}`, `version`, beside `subs` (the live per-window echo) and
      the session-wide echoes. `tabOrder` is EVERY tab of the bar — terminal and window keys interleaved
      — in bar order, the whole order every time (a new tab goes right after the last of its own kind; a
      terminal with none goes first, a window last), and `windows` is in the same relative order as its
      window keys. A window's `name` is present ONLY when set;
    - `term-list` is the terminals half: `tabs: [{id, n, title, name?}]` in the bar's relative order,
      `name` (a `pty:` tab's user name) present ONLY when set — a `tmux:` tab's label is its `title`,
      the session's name. A `term-list` can arrive ahead of the `view-set` that places a new tab.
- **Paste and drop (2026-10-01; docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §3).** A
  DELIVERY is one paste or one drop: one target, one or more items declared up front, then their bytes in
  order. The DRIVER's only (a passive client's `paste-begin` is `not-driver`); a window-less client may
  paste into a `term` and nothing else (`WindowlessPolicy`). `protocol/fixtures/paste-messages.json`
  holds the TypeScript builders and Swift's parser to the same bytes. Every message of it rides `bulk` (on
  `control` until 2026-10-12).
  - Client → host:
    - `{ "t": "paste-begin", "id": "p7", "to": {"term": "pty:3"}, "items": [{"kind": "file", "name":
      "IMG_0042.jpg", "type": "image/jpeg", "size": 3145728}] }`, and for a drop
      `{ "t": "paste-begin", "id": "p8", "to": {"win": "win:4711"}, "at": {"x": 0.42, "y": 0.17},
      "items": [{"kind": "text", "size": 12}] }`;
    - `{ "t": "paste-data", "id": "p7", "item": 0, "seq": 0, "data": "<base64>" }`;
    - `{ "t": "paste-end", "id": "p7" }` and `{ "t": "paste-cancel", "id": "p7" }`.
  - **The limits, enforced by the host whatever the client claims:** `id` 1-64 of `[A-Za-z0-9_-]`, unique
    per connection. `to` is `{"term": <tab id>}` or `{"win": <source id>}` (`win:` or `dsp:`); `at` is a
    drop's, for a `win` only, each coordinate in 0…1. `items`: 1-32. A `file` item has a `name` of at most
    255 UTF-8 bytes and a `type` (a MIME of at most 127 bytes, or `""`); a `text` item is UTF-8, ALONE in
    its delivery and only to a `win` (a terminal's text never leaves the client). `size` is EXACT: a file
    1 byte … 1 GiB, a text 1 byte … 4 MiB, a delivery at most 1 GiB (50 and 100 MiB until 2026-10-02: a
    compressed folder is routinely more, and a big paste is now sent after the CLIENT's warning — over 50 MiB
    it asks first; the host has no such rule). `paste-data` carries the items in
    order, each from `seq` 0 and consecutive; `data` is standard padded base64 of at most **16 KiB**.
  - Host → client: `{ "t": "paste-accepted", "id" }` as soon as a `paste-begin` OPENS its delivery (it
    passed the busy and cap checks; a refused begin gets its `paste-error` instead, never this), then
    `{ "t": "paste-done", "id", "how": "paste" | "drop" }` once delivered (`drop` is a
    real drag-and-drop at `at`; `paste` is the Mac's clipboard and ⌘V, or a terminal's typed path), or
    `{ "t": "paste-error", "id", "reason" }` with `reason` one of `too-large`, `malformed`, `not-driver`,
    `busy`, `no-target`, `disk`, `failed`.
  - **No piece before `paste-accepted` (2026-10-02).** The client sends `paste-begin` and waits for the
    acceptance (or a `paste-error`) before its first `paste-data`; with neither within **5 s** it sends
    `paste-cancel` and gives up — "the Mac did not answer — Xpromptvs there may need updating". A Mac
    built before paste ignores every `paste-*`: it took the whole upload, and the client's note sat at 94%
    until the 60 s reply timeout. That timeout, from `paste-end` to the answer, is unchanged (a big image's
    conversion or a drop can take seconds). No backward compatibility: an older client ignores the new
    reply, a newer client fails fast against an older host.
  - **Pacing, the client's half:** the channel never holds more than 256 KiB unsent (`bufferedAmount`,
    re-checked every 8 ms while above that, and a macrotask yielded every 256 KiB handed over) — the bound that kept
    a control message queued behind an upload to that much while uploads rode `control` (docs/client-web.md, "Paste
    and drop"). **One delivery at a time per client**: a `paste-begin`
    while one is open (until it is ANSWERED, not merely until its `paste-end`) is `busy`.
  - **The host abandons a delivery** — deleting what it saved — on `paste-cancel`, a `malformed` piece (a
    `seq` gap, a size that does not add up, bad base64), the client leaving, losing control or having its
    connection rebuilt, or **30 s with no piece**; a client still there gets a `paste-error`.

- **Opening an image path (2026-10-05; docs/terminal.md, "An image path opens on the client").** A path to an
  image printed in a tab, tapped or clicked, asks for the file. The DRIVER's only (a passive client gets
  `not-driver`); a window-less client may ask. Images only, by extension (`png jpg jpeg gif webp bmp svg avif
  ico` as they are; `heic heif tif tiff` converted by the host to JPEG, upright, at most 4096 px).
  - Client → host: `{ "t": "file-get", "id": "f3", "term": "pty:2", "path": "shots/a.png" }` — `id` a paste
    id's shape (1-64 of `[A-Za-z0-9_-]`), `term` the tab the path was printed in (a relative path is relative
    to what runs there: its foreground process's directory, a tmux pane's `pane_current_path`; `~` is the
    host's home), `path` as printed, unquoted and unescaped, 1-4096 UTF-8 bytes, no NUL.
  - Host → client: `{ "t": "file-begin", "id", "name", "mime", "size", "path" }` (`path` RESOLVED, `size` the
    bytes that follow), then `{ "t": "file-data", "id", "seq", "data" }` from `seq` 0, consecutive, `data`
    standard padded base64 of at most 48 KiB, then `{ "t": "file-end", "id" }`; or instead one
    `{ "t": "file-error", "id", "reason" }` with `reason` one of `not-found`, `not-image`, `too-large` (over
    20 MiB), `unreadable`, `not-driver`. Pieces are PACED: one waits while `bulk` holds more than 256 KiB
    unsent. A newer `file-get` from the same client STOPS an older transfer mid-way (no `file-end` follows),
    as does the channel closing or 30 s without it draining.
  - The client gives up on no `file-begin` within 15 s, and on 15 s without a piece once begun. No backward
    compatibility: an older host ignores `file-get`, and the client says the Mac did not answer.

## Over a message socket

The same four channels can travel over ONE message socket — anything with WebSocket semantics: ordered,
reliable, message-framed, binary. There is no signalling and no media; a client on one is WINDOW-LESS
(docs/sources-and-focus.md). Authentication belongs to the transport. Everything is totally ordered,
which is stronger than the per-stream order the protocol already copes with. A socket never loses a message, so it
has no lane: each channel is its own byte.

A frame is ONE byte naming the channel, then exactly the bytes the data channel would carry:

| byte | channel | payload |
|---|---|---|
| `0x00` | meta | UTF-8 JSON: the client's `hello` |
| `0x01` | control | the compression envelope + JSON, as above |
| `0x02` | input | the compression envelope + JSON, as above |
| `0x03` | terminal | the terminal wire's frames, unenveloped |
| `0x04` | bulk | the compression envelope + JSON: paste and image transfers, thumbnails (2026-10-12) |

**The hello** is the client's FIRST frame: `0x00 {"t":"hello","v":1,"client":"<id>","intent":"connect"|"reconnect"}`.
`v` is exactly 1; `client` is 1-64 characters of `[A-Za-z0-9_-]` (a per-tab id, so a reconnect is
recognised; the host prefixes it `sock:`); `intent` is the join intent. **Unknown fields are ignored**;
every known one must be exactly right. The host sends no answer — what the client sends after it queues
behind it — and on accepting it the channels count as open: terminal, input and control in WebRTC's order, and
`bulk` on the page (the host keeps no open state for `bulk`).

**Refused, and the socket closed**: an empty frame, an unknown channel byte, a channel frame before the
hello, a second hello, a hello with a bad version, id or intent. Close codes: `4400` for a frame the
protocol does not allow (the client's answer to a malformed frame from the host), `4001` for a client
leaving.

`protocol/fixtures/socket-frames.json` — valid frames, hellos and a named malformed set — is generated by
`scripts/gen_socket_frame_fixture.py` (a third implementation) and asserted by RdevCore's `SocketFrame`
and `protocol/src/socket-frame.ts`.

## Fast data v1 (negotiated, WebSocket startup and WebRTC migration)

Advertised as `fastData: 1` inside authenticated app_hello; absent/unknown is legacy.
Records have big-endian `version u8=1 · kind u8 · generation[16] · stream u8`.
Streams are terminal=0, input=1, control=2 only. Kind 1 (data) appends
`offset u64 · size u16 · bytes[size]`, size 1…8192. Kind 2 (ack) appends
`nextOffset u64`; kinds 3/4 (probe/reply) append `nonce u64`. No trailing bytes.
Stream messages have a u32 length prefix, 1…1048576 payload bytes. Counters do
not wrap. WebSocket carries records base64url inside sealed `fast-record` messages;
negotiated WebRTC logical channels carry the same binary records. Independent vectors:
`protocol/fixtures/fast-data-vectors.json`, generated by `scripts/gen_fast_data_vectors.py`.
Bulk/media are never eligible. See the approved fast-start design for lifecycle and
resume semantics; wire support alone does not activate this feature.

### Terminal RZT1 (breaking protocol revision)

Terminal messages bypass the generic compression envelope. Deploy the host and client together and reload
old clients; there is no legacy terminal decoder or negotiated fallback.

All integers are big-endian. START is `RZT1 | u8(0) | u64 epoch | zstd bootstrap`; DATA is
`RZT1 | u8(1) | u64 epoch | u64 sequence | u32 rawLength | zstd continuation`.
Epochs are nonzero and monotonically allocated by the host; DATA sequence starts at zero.
START decompresses to exactly bytes 0 through 31. Each DATA decompresses to one complete raw TermFrame:
`kind | tabIdLength | UTF-8 tabId | [u16 cols | u16 rows] | payload`. Grid is present for kinds 1/2/5/6/7/8;
0 is output, 3 closed, and inner kind 4 is forbidden. Snapshot/history end kinds preserve their existing semantics.

The host uses zstd 1.5.7, level 6, windowLog 17, no workers, flushing each record without ending the frame.
One context spans all tabs and history records. Schedule and cancel raw records BEFORE compression; compressed
records must never be reordered or dropped. FastDelivery messages are at most 2048 bytes, other messages 8192;
raw records reserve 128 bytes for expansion and headers. Receivers reject messages over 60 KiB and windows over
128 KiB. Decode every current-epoch record before any semantic tab/history discard. Sequence/length/codec failure
invalidates the whole wire and uses bounded resync. A new transport resets the epoch namespace.

Raw admission is atomic and bounded to 64 MiB backing plus accounted scratch and 65,536 records. Exhaustion
retires the wire and sends `term-stream-error {reason:"overloaded",epoch:"<decimal UInt64>"}` on control.
The client retains its picture, blocks terminal input and automatic resync, and offers explicit Reconnect.
A non-stale error is authoritative even if START was never sent. Codec retirement uses reason `codec` and bounded
all-wire recovery. Standalone early-offer previews remain independent DEFLATE.
