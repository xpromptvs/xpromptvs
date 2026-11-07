import type { WebSocketLike } from "./signaling";

type Listener = (e: any) => void;
interface Opts {
  backoffMinMs?: number;
  backoffMaxMs?: number;
  /**
   * How long an attempt may sit in CONNECTING before it is abandoned. Doubles on each consecutive
   * timeout (to four times this), so a link that is merely SLOW still gets through eventually. 0 is off.
   */
  connectTimeoutMs?: number;
  /**
   * How long an OPEN socket may go without receiving anything before it is presumed dead. Only
   * meaningful when the other end talks regularly — `main.ts` pings every 15 s and the control plane
   * answers every ping. 0 (the default) is off.
   */
  staleAfterMs?: number;
  /**
   * While true, a stale verdict is DEFERRED (re-armed), never acted on. A hidden tab's timers are
   * throttled to as little as once a minute, so the heartbeat that would have kept this socket fresh
   * may simply not have run — silence there is evidence about the scheduler, not the network.
   */
  staleDeferred?: () => boolean;
  schedule?: (fn: () => void, ms: number) => unknown;
  clear?: (t: unknown) => void;
}

/// A WebSocketLike that transparently reconnects. Listeners registered via addEventListener persist across
/// underlying reconnects. `onReconnect` fires after each successful REopen (not the first open) so the
/// caller can re-send hello. Backoff is exponential (min→max, ×2), reset on a clean open. An explicit
/// close() is terminal — no reconnect.
///
/// **A WEAK NETWORK DOES NOT CLOSE SOCKETS, IT STRANDS THEM.** A browser learns a TCP connection died
/// only when the OS gives up on it, which on a dropped Wi-Fi or a phone changing cells is minutes,
/// not seconds — the socket reads OPEN, every `send` vanishes, and nothing reconnects. The same is
/// true of an attempt stuck in CONNECTING behind a SYN nobody answers. So two watchdogs, both
/// opt-in: an attempt that has not opened within `connectTimeoutMs`, and an open socket that has
/// received nothing within `staleAfterMs`, are ABANDONED — detached first, closed second, and
/// treated exactly as an unexpected drop. Detached first because `close()` on a dead link waits for a
/// closing handshake that never comes, and the old socket's late events must not be mistaken for
/// the new one's. The control plane already reclaims a live socket holding the same resume id.
export class ReconnectingSocket implements WebSocketLike {
  private sock: WebSocketLike | null = null;
  private listeners: Record<string, Listener[]> = {};
  private reconnectCbs: (() => void)[] = [];
  private backoff: number;
  private readonly min: number;
  private readonly max: number;
  private readonly schedule: (fn: () => void, ms: number) => unknown;
  private readonly clear: (t: unknown) => void;
  private timer: unknown = null;
  private opened = false;   // have we ever opened? (distinguishes first-open from reconnect)
  private live = false;     // is the CURRENT underlying socket open right now? (drives recycle()'s guard)
  private closedByUs = false;
  private downCbs: ((info: {opened: boolean; failures: number; code?: number}) => void)[] = [];
  private failures = 0;     // consecutive closes since the last successful open
  private readonly connectTimeout: number;
  private readonly staleAfter: number;
  private readonly staleDeferred: () => boolean;
  private connectTimeouts = 0;   // consecutive attempts abandoned in CONNECTING
  private connectTimer: unknown = null;
  private staleTimer: unknown = null;
  private probeTimer: unknown = null;

  constructor(private readonly factory: () => WebSocketLike, opts: Opts = {}) {
    this.min = opts.backoffMinMs ?? 500;
    this.max = opts.backoffMaxMs ?? 8000;
    this.backoff = this.min;
    this.schedule = opts.schedule ?? ((fn, ms) => setTimeout(fn, ms));
    this.clear = opts.clear ?? ((t) => clearTimeout(t as ReturnType<typeof setTimeout>));
    this.connectTimeout = opts.connectTimeoutMs ?? 0;
    this.staleAfter = opts.staleAfterMs ?? 0;
    this.staleDeferred = opts.staleDeferred ?? (() => false);
    this.connect();
  }

  private connect(): void {
    const s = this.factory();
    this.sock = s;
    if (this.connectTimeout > 0) {
      const ms = this.connectTimeout * Math.min(2 ** this.connectTimeouts, 4);
      this.connectTimer = this.schedule(() => {
        this.connectTimer = null;
        if (this.sock !== s || this.live) return;
        this.connectTimeouts += 1;
        this.abandon(s);
      }, ms);
    }
    // Every listener asks whether `s` is STILL the current socket: an abandoned one keeps firing
    // events for as long as its closing handshake takes, and none of them are news any more.
    s.addEventListener("open", () => {
      if (this.sock !== s) return;
      this.stopTimer("connectTimer");
      this.backoff = this.min;                 // reset backoff on success
      this.failures = 0;
      this.connectTimeouts = 0;
      this.live = true;
      this.armStale(s);
      const wasReconnect = this.opened;
      this.opened = true;
      this.emit("open", {});
      if (wasReconnect) this.reconnectCbs.forEach((cb) => cb());
    });
    s.addEventListener("message", (e) => {
      if (this.sock !== s) return;
      this.stopTimer("probeTimer");
      this.armStale(s);
      this.emit("message", e);
    });
    s.addEventListener("close", (e) => {
      if (this.sock !== s) return;
      this.down(typeof e?.code === "number" ? e.code : undefined);
    });
    s.addEventListener("error", () => { /* close will follow; browsers fire both */ });
  }

  /** Detach `s`, close it without waiting on it, and go through the ordinary drop path. */
  private abandon(s: WebSocketLike): void {
    if (this.sock !== s) return;
    this.sock = null;
    try { s.close(); } catch { /* already closing */ }
    this.down();
  }

  /// `code` is the close event's; an ABANDONED socket has none, because it never got to close.
  private down(code?: number): void {
    this.live = false;
    this.stopTimer("connectTimer");
    this.stopTimer("staleTimer");
    this.stopTimer("probeTimer");
    if (this.closedByUs) return;
    this.failures += 1;
    // **A SOCKET THAT NEVER OPENS USED TO BE SILENT.** This class retries forever and swallows
    // `error`, which is right for a blip and wrong for a path that is simply not there: with DNS
    // or TLS failing, every attempt died instantly, nothing changed the status, and the caller's
    // pending connect never settled — the app's dashboard span forever and the session window sat
    // on its last phase. The retry policy is UNCHANGED; the only new thing is that it says so.
    this.downCbs.forEach(cb => cb({opened: this.opened, failures: this.failures,
                                   ...(code !== undefined ? { code } : {})}));
    // A callback may have decided this code means "stop" and called `close()` — honour it, or a
    // timer armed after the callbacks would open a socket nobody wants.
    if (this.closedByUs) return;
    this.scheduleReconnect();
  }

  private armStale(s: WebSocketLike): void {
    if (this.staleAfter <= 0) return;
    this.stopTimer("staleTimer");
    this.staleTimer = this.schedule(() => {
      this.staleTimer = null;
      if (this.sock !== s || !this.live) return;
      if (this.staleDeferred()) this.armStale(s);
      else this.abandon(s);
    }, this.staleAfter);
  }

  private stopTimer(which: "connectTimer" | "staleTimer" | "probeTimer"): void {
    if (this[which] !== null) { this.clear(this[which]); this[which] = null; }
  }

  private scheduleReconnect(): void {
    if (this.timer !== null) return;
    const ms = this.backoff;
    this.backoff = Math.min(this.backoff * 2, this.max);
    this.timer = this.schedule(() => { this.timer = null; this.connect(); }, ms);
  }

  private emit(t: string, e: any): void { (this.listeners[t] ?? []).forEach((cb) => cb(e)); }

  addEventListener(type: string, cb: Listener): void { (this.listeners[type] ??= []).push(cb); }
  onReconnect(cb: () => void): void { this.reconnectCbs.push(cb); }
  /// Fires on every close that will be retried, with `opened` false while this socket has NEVER been
  /// open — which is what separates "the control plane is unreachable" from "the link blipped
  /// mid-session". `failures` counts consecutive closes since the last successful open, so a caller
  /// can wait out a blip before it says anything. Never fires for an explicit close().
  /// `code` is the close code when the socket closed on its own — the caller decides whether a code
  /// means "do not retry" and calls `close()` if so.
  onDown(cb: (info: {opened: boolean; failures: number; code?: number}) => void): void { this.downCbs.push(cb); }
  send(data: string): void { this.sock?.send(data); }
  /// FORWARDS the close code and reason to the underlying socket. LOAD-BEARING: `SignalingClient.leave()`
  /// says "this client is leaving deliberately" purely through the close CODE, and a signature that
  /// dropped its arguments would close with the browser default instead — the control plane would read a
  /// deliberate departure as a network blip and suspend the client for the full grace window. The feature
  /// would be completely inert while its unit test, which uses a fake socket, still passed.
  close(code?: number, reason?: string): void {
    this.closedByUs = true;
    if (this.timer !== null) this.clear(this.timer);
    this.stopTimer("connectTimer");
    this.stopTimer("staleTimer");
    this.stopTimer("probeTimer");
    this.sock?.close(code, reason);
  }

  /// **The network says it is back: stop waiting out the backoff.** A no-op while a socket is open
  /// or an attempt is already in flight — only a PENDING retry is brought forward, so calling this
  /// on every `online` or `visibilitychange` is always safe.
  kick(): void {
    if (this.closedByUs || this.timer === null) return;
    this.clear(this.timer);
    this.timer = null;
    this.backoff = this.min;
    this.connect();
  }

  /// **Make the open socket prove it is alive within `ms`.** The caller has just sent something the
  /// other end always answers (a ping); anything received settles it, and silence ABANDONS the socket
  /// exactly as a stale verdict would. For the moment a phone brings the page back: its socket was
  /// stranded while the app was suspended far more often than it was closed, and the stale watchdog
  /// needs its full `staleAfterMs` of silence to say so — signalling sealed into it in the meantime
  /// is lost. NEVER deferred, unlike the stale verdict: it is asked for when the page is visible,
  /// which is when a silence means the network. A no-op unless a socket is open.
  probe(ms: number): void {
    if (this.closedByUs || !this.live || !this.sock) return;
    const s = this.sock;
    this.stopTimer("probeTimer");
    this.probeTimer = this.schedule(() => {
      this.probeTimer = null;
      if (this.sock === s && this.live) this.abandon(s);
    }, ms);
  }

  /// Force a reconnect even though the socket hasn't dropped on its own — e.g. the PC/media path failed
  /// while the signaling WS itself is still healthy, so the normal close→reconnect→re-hello path would
  /// never fire. Closes the CURRENT underlying socket WITHOUT setting the terminal `closedByUs` flag, which
  /// drives the exact same reconnect logic as an unexpected drop (the socket's own "close" listener sees
  /// `closedByUs===false` and calls scheduleReconnect()). Idempotent / safe no-op when there's no live
  /// socket right now (already down and reconnecting) or after an explicit close().
  /// ABANDONS rather than waits: on the dead link this is usually called for, `close()` alone waits on a
  /// closing handshake that never completes, and the reconnect it was supposed to cause never comes.
  recycle(): void { if (this.closedByUs || !this.live || !this.sock) return; this.abandon(this.sock); }
}
