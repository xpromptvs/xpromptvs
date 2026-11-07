# @rdev/web

The rdev **browser client** plus a dev-only **host-harness** peer. Together they prove the
full WebRTC P2P loop in pure TypeScript against the merged control-plane, reusing
`@rdev/protocol` directly. The Swift Mac host is the real peer and speaks the same wire format,
so the harness is drop-in for it — `host.html` is a dev harness, never the product.

**BOTH ENDS NEED AN E2E IDENTITY.** Signalling is E2E-only (`docs/e2e.md`), so a browser holding
no identity cannot connect and is told so, and `host.html` cannot answer one without running the
same §11 machine the Mac runs. The gates mint identities for both ends with
`mint_e2e_identities <origin>` (`scripts/lib.sh`); the acceptance smoke below predates that and no
longer connects as written.

## Develop
- `npm install`
- `npm test` — typecheck + 82 vitest files (jsdom): codec, terminal model, signalling, peer
  orchestration, input mapping, the pure geometry and gesture mappers, the window/palette/settings
  view-models, and the E2E identity layer. **jsdom has no layout engine**, so none of it can see
  geometry — that is what the `e2e/*-check.mjs` scripts are for (`AGENTS.md`, "Client (web)").
- `npm run dev` — Vite dev server (serves `index.html` = client and `host.html` = harness).
- `npm run build` — typecheck + production bundle (also the browser-safety guard for
  `@rdev/protocol`).

`@rdev/protocol` is consumed via a path alias to `../protocol/src/index.ts` (tsconfig
`paths` + vite `resolve.alias`). The browser supplies raw-DEFLATE via `fflate`.

## Two-tab acceptance smoke (PRE-E2E — see the identity note above)
1. In one terminal: `cd ../control-plane && npm run dev` (wrangler dev — note the local URL).
2. In another: `cd ../web && npm run dev`. If the control-plane is on a different origin,
   serve the web app behind it or set the dev proxy so `/pair` and `/session/:code` reach
   wrangler (see vite `server.proxy`).
3. Open the **host-harness**: `http://localhost:5173/host.html`. It calls `POST /pair`,
   shows `code` + `token`, starts the test pattern, and waits.
4. Open the **client** with those values: `http://localhost:5173/?code=CODE&token=TOKEN`.
5. Expect: (a) ICE connects; (b) the client `<video>` shows the moving test pattern;
   (c) the `<canvas>` shows the fake terminal grid with a ticking spinner; (d) typing in the
   client echoes characters into the grid; (e) clicking the video logs `input:` lines in the
   harness; (f) reloading the client repaints every tab from a fresh snapshot (the host sends
   one per tab once the client's terminal channel is open and it has declared `term-mode raw`;
   there is no snapshot request).

> Note on origins: `POST /pair` and `GET /session/:code` are served by the control-plane
> Worker. For local dev, add a `server.proxy` entry in `web/vite.config.ts` forwarding
> `/pair` and `/session` to the `wrangler dev` URL, or run both behind one origin.
