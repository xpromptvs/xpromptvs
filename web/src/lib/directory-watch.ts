import { rootId as hashRoot, type DirectorySession } from "@rdev/protocol";
import { base64urlDecode, base64urlEncode } from "./base64url";
import { parseSessionRows, signDirectoryRequest, type DirectoryIdentity } from "./directory-api";
import { ReconnectingSocket } from "./reconnecting-socket";
import type { WebSocketLike } from "./signaling";

/**
 * **§12.2's directory as a STREAM** — `docs/superpowers/specs/2026-09-24-live-device-list-design.md`.
 *
 * The Worker hands this socket a challenge; it answers with a `subscribe` signed exactly as `list`
 * is, and receives the identity's live Macs as FULL snapshots whenever they change. Renewal re-signs
 * the challenge the last `subscribed` handed over, at HALF its `renew_in` so a hidden tab's throttled
 * timers still land inside the challenge's 120 s life. Liveness is `ReconnectingSocket`'s watchdogs
 * plus a ping every 20 s the Worker always answers.
 *
 * **POLLING IS NEVER REPLACED.** A refusal (4401/4403/4429) or a `/watch` that never opens stops
 * this stream and says so; the dashboard's poll carries on either way.
 */
export const WATCH_PING_MS = 20_000;
export const WATCH_STALE_MS = 45_000;
export const WATCH_CONNECT_TIMEOUT_MS = 10_000;
export const WATCH_GIVE_UP_AFTER = 3;
const TERMINAL = new Set([4401, 4403, 4429]);

export type WatchEvent =
  | { kind: "sessions"; sessions: DirectorySession[] }
  | { kind: "down" }
  | { kind: "stopped"; reason: "refused" | "unavailable"; code?: number };

export interface WatchOptions {
  base: string;
  identity: DirectoryIdentity;
  onEvent: (e: WatchEvent) => void;
  signal: AbortSignal;
  socket?: (url: string) => WebSocketLike;
  schedule?: (fn: () => void, ms: number) => unknown;
  clear?: (t: unknown) => void;
  hidden?: () => boolean;
  random?: (n: number) => Uint8Array;
}

export function watchDirectory (opts: WatchOptions): { ping: () => void } {
  const schedule = opts.schedule ?? ((fn, ms) => setTimeout(fn, ms));
  const clear = opts.clear ?? ((t) => clearTimeout(t as ReturnType<typeof setTimeout>));
  const random = opts.random ?? ((n) => crypto.getRandomValues(new Uint8Array(n)));
  const hidden = opts.hidden
    ?? (() => typeof document !== "undefined" && document.visibilityState === "hidden");
  const url = `${opts.base.replace(/^http/, "ws")}/directory/`
    + `${base64urlEncode(hashRoot(opts.identity.root))}/watch`;

  let pingTimer: unknown = null;
  let renewTimer: unknown = null;
  let stopped = false;
  let openedThisAttempt = false;
  let unopened = 0;

  const rs = new ReconnectingSocket(() => (opts.socket ?? ((u) => new WebSocket(u)))(url), {
    connectTimeoutMs: WATCH_CONNECT_TIMEOUT_MS, staleAfterMs: WATCH_STALE_MS,
    staleDeferred: hidden, schedule, clear,
  });

  const stopTimers = (): void => {
    if (pingTimer !== null) { clear(pingTimer); pingTimer = null; }
    if (renewTimer !== null) { clear(renewTimer); renewTimer = null; }
  };
  const send = (m: unknown): void => { try { rs.send(JSON.stringify(m)); } catch { /* reconnecting */ } };
  const stop = (e: WatchEvent): void => {
    if (stopped) return;
    stopped = true;
    stopTimers();
    rs.close();
    opts.onEvent(e);
  };
  const subscribe = (challenge: unknown): void => {
    const bytes = typeof challenge === "string" ? base64urlDecode(challenge) : null;
    const fields = bytes && signDirectoryRequest("subscribe", bytes, opts.identity, random(32),
                                                 new Uint8Array(0));
    if (!fields) { stop({ kind: "stopped", reason: "refused" }); return; }
    send({ t: "subscribe", ...fields });
  };
  const pingLoop = (): void => {
    pingTimer = schedule(() => { pingTimer = null; send({ t: "ping" }); pingLoop(); }, WATCH_PING_MS);
  };

  rs.addEventListener("open", () => {
    openedThisAttempt = true;
    unopened = 0;
    stopTimers();
    pingLoop();
  });
  rs.addEventListener("message", (e: { data: unknown }) => {
    let m: Record<string, unknown> | null = null;
    try { m = JSON.parse(String(e.data)) as Record<string, unknown>; } catch { return; }
    switch (m?.t) {
      case "challenge": subscribe(m.challenge); break;
      case "subscribed": {
        if (renewTimer !== null) clear(renewTimer);
        const seconds = typeof m.renew_in === "number" && m.renew_in > 0 ? m.renew_in : 60;
        const next = m.challenge;
        renewTimer = schedule(() => { renewTimer = null; subscribe(next); }, seconds * 500);
        break;
      }
      case "sessions": {
        const rows = parseSessionRows(m.sessions);
        if (rows) opts.onEvent({ kind: "sessions", sessions: rows });
        break;
      }
      default: break;
    }
  });
  rs.onDown(({ code }) => {
    stopTimers();
    if (code !== undefined && TERMINAL.has(code)) {
      stop({ kind: "stopped", reason: "refused", code });
      return;
    }
    if (!openedThisAttempt) unopened += 1;
    openedThisAttempt = false;
    if (unopened >= WATCH_GIVE_UP_AFTER) { stop({ kind: "stopped", reason: "unavailable" }); return; }
    opts.onEvent({ kind: "down" });
    // `onDown` runs BEFORE the backoff is scheduled, so the kick has to come a tick later.
    if (code === 4408) schedule(() => rs.kick(), 0);
  });
  opts.signal.addEventListener("abort", () => { stopped = true; stopTimers(); rs.close(); });

  return { ping: () => send({ t: "ping" }) };
}
