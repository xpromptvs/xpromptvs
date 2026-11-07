# Signaling (JSON over the DO WebSocket)

Rendezvous only. Both peers connect to `wss://…/session/:code`, and everything that describes the
WebRTC connection travels **inside a Noise session the relay cannot read**. Validated by
`schema/signaling.schema.json`.

**THERE IS NO PLAINTEXT ARM.** Since 2026-09-13 the DO does not parse `offer`, `answer` or `ice`:
they reach `unknown-type` like any other stranger's message, and neither host nor client sends or
accepts one. That is what makes the old protocol GONE rather than merely unpreferred — a peer cannot
ask for the thing §11 replaced. The reasoning is `docs/e2e.md`, "Signalling is E2E-only"; the
specification is §11 of `docs/superpowers/specs/2026-09-10-e2e-protocol-specification.md`.

## Peer → DO
- `{ "t": "hello", "role": "host"|"client", "token": "…", "codecs": ["deflate","lzfse"],
   "resumeId": "…", "resume": "ice"|"rebuild" }` — and NO join intent: a client says that inside its §11
   session (`client-confirm`'s app_hello, `docs/sources-and-focus.md`, "The join intent"). Any other field — an
   `intent` included — is `invalid`.
- `{ "t": "e2e", "ct": "…", "peer": "…", "mode": "pair"|"enroll"|"auth"|"resume" }` — one §11.3
  envelope. `ct` is base64url Noise ciphertext, forwarded VERBATIM; `mode` rides only the
  initiator's first message. `peer` is routing: a host sends it to address one client of several,
  and the DO drops it on the way out — a client-to-host envelope is tagged with the SOURCE client
  id instead, so a host with several can answer the right one.
- `{ "t": "bye", "reason": "…" }`
- `{ "t": "ping" }` / `{ "t": "pong" }`

## DO → peer
- `{ "t": "welcome", "sessionId": "…", "turn": { "urls": […], "username": "…", "credential": "…", "ttl": 600 } }`
- `{ "t": "peer-joined", "peer": "…" }` / `{ "t": "peer-left", "peer": "…" }`
- `{ "t": "peer-suspended", "peer": "…" }` / `{ "t": "peer-resumed", "peer": "…", "mode": "…" }`
  — nothing about who drives: a client says its join intent inside its §11 session (`client-confirm`'s app_hello,
  docs/sources-and-focus.md, "The join intent"), and a hello carrying `intent` is refused.
- `{ "t": "e2e", "ct": "…", "mode": "…" }` — the peer's envelope, forwarded
- `{ "t": "error", "code": "bad-json"|"invalid"|"unknown-type", "msg": "…" }`

The DO validates `token`, pairs exactly one host + one client per `code`, forwards `e2e` envelopes
opaquely, mints TURN creds, and tracks presence. **It never parses SDP, and now it never sees any.**

## The inner payloads

Once the §11 gate opens, the same signalling JSON the plaintext envelopes used to carry travels
inside Noise transport instead — so both ends kept their existing parsers:

- `{ "t": "offer", "sdp": "…" }` / `{ "t": "answer", "sdp": "…" }`
- `{ "t": "ice", "cand": { … } }`

`schema/signaling.schema.json` describes **both layers**: `hello`, `e2e`, `welcome`, `peer-*`,
`error` are the outer wire, and `offer`/`answer`/`ice` are valid only as the plaintext INSIDE an
`e2e` envelope. A message of the latter three shapes arriving on the socket is an error, whatever
the schema says about its shape — the schema is a shape contract, not a routing one.
