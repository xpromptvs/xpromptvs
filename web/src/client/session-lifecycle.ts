import type { Transport } from "./connection";
import { createSession, type Session, type SessionHost, type SessionOptions } from "./session";
import type { SessionDom } from "./session-dom";
import type { LayoutMode } from "./layout-mode";
import { parsePairing } from "./pairing";
import { shellstormMotion } from "./shellstorm-motion";
import { ViewportFit } from "./viewport-fit";
import type { ClientContext } from "./instance/context";

/// The page's ONE session lifecycle: connect, cancel, disconnect, the page's own events, and the
/// fence on everything a session reports. Created once per page; a session is a `createSession`
/// call in THIS document, never a frame (docs/superpowers/specs/2026-09-27-session-without-iframe-design.md).
///
/// Nothing here touches the address bar. Pairing lives in JS from the dashboard's submit to the
/// session's options; a later session's state can never be mistaken for the current one's, because
/// every session reports through a host bound to its GENERATION.

/// **DEV ONLY — THE DESIGN WORKBENCH'S MOCK HOST** (`web/src/design/`, docs/ui-design.md): a workbench frame
/// stands a mock Mac in for the relay by setting this global, and a connect to that Mac's code gets it.
/// Read only under `import.meta.env.DEV`, which is `false` in every build, so neither the read nor the
/// global exists in the shipped client. Absent (every page but a workbench frame), the relay as always.
function designTransport(code: string): Transport | undefined {
  return (globalThis as { __rdevDesignTransport?: (code: string) => Transport | undefined }).__rdevDesignTransport?.(code);
}

/// A connect target, split out of the `?code=…&token=…#pair=…` string the dashboard hands over.
export interface ConnectTarget { code: string; token: string; carrier: string | null }

/// **THE FRAGMENT IS SPLIT OFF FIRST.** `URLSearchParams` does not strip one, so parsing
/// `?code=c&token=t#pair=S` whole reads the token as `t#pair=S` and loses the seed — the host is sent
/// a wrong token and the handshake gets no psk. The iframe controller this replaced (deleted
/// 2026-09-28) shipped exactly that for every seeded Quick connect from the browser dashboard.
export function splitConnectSearch(search: string): ConnectTarget | null {
  const hash = search.indexOf("#");
  const query = new URLSearchParams(hash >= 0 ? search.slice(0, hash) : search);
  const fragment = new URLSearchParams(hash >= 0 ? search.slice(hash + 1) : "");
  const code = query.get("code") ?? "";
  const token = query.get("token") ?? "";
  if (!code || !token) return null;
  return { code, token, carrier: fragment.get("pair") };
}

/// What the controller needs from `motion.js`; `ShellstormMotion` satisfies it.
export interface ControllerMotion {
  prepareSession(): void;
  close(done: () => void): void;
  finish(): void;
  unlight(row: HTMLElement): void;
}

export interface ControllerDeps {
  context?: ClientContext;
  onState?: SessionHost["state"];
  transport?: (code: string) => Transport | undefined;
  /// The page's own options (layout, render, …), READ AT EACH CONNECT; every session gets them with its
  /// pairing set. Read, never captured once: URL mode strips its query when its session ends, and a
  /// dashboard session after it must carry none of that page's parameters. Production: the address
  /// bar's query (`main.ts`).
  pageParams: () => URLSearchParams;
  layout: () => LayoutMode;
  dom: SessionDom;
  /// `#session`, whose `ss-session-moving` class says the slide is running.
  sessionRoot: HTMLElement;
  /// `#welcome`: where the connecting row is found, and what is shown when there is no motion runtime.
  welcome: HTMLElement | null;
  /// After Disconnect disposed the session, BEFORE the slide (URL mode mounts the dashboard here).
  onDisconnect?: () => void;
  /// After the slide, once the DOM is gone (URL mode strips its query here).
  onClosed?: () => void;
  /// The current session followed its Mac to another room (`host-follow.ts`): URL mode's address names it now.
  onMoved?: (room: { code: string; token: string }) => void;
  /// A bfcache RESTART whose rebuild threw, with the reason. Nothing else can say it: the session had
  /// been revealed, so the dashboard is hidden and no Connect is waiting on an answer. A failed
  /// CONNECT is not reported here — its caller has `connect`'s false and the error event.
  onRestartFailed?: (reason: string) => void;
  /// Injected for tests; production uses the real ones.
  create?: (opts: SessionOptions, host: SessionHost) => Session;
  motion?: () => ControllerMotion | undefined;
  parsePsk?: (carrier: string) => Promise<Uint8Array | null>;
  /// Pins <body> to the visual viewport and returns the release. Production: `ViewportFit` on a
  /// coarse pointer, nothing elsewhere.
  pin?: () => () => void;
  win?: Window;
}

export interface SessionController {
  disconnect(): void;
  /// Start a session. FALSE while one is pending, live or closing (nothing happens), and FALSE when
  /// the string names no pairing or the session could not be built — both SAID, as a
  /// `connection-state` error, because welcome has already begun the morph by then.
  connect(search: string): boolean;
  /// Start a session over a transport the PAGE supplies — the app's local window, a socket to its own
  /// host (docs/client-web.md, "The connection"). No pairing: the transport is the authentication. FALSE
  /// while one is pending, live or closing, and when the session could not be built (said, as `connect`).
  connectTransport(transport: Transport): boolean;
  /// The dashboard's busy button (through `motion.js`): dispose at once, unmount at once.
  cancel(): void;
  /// A session exists or is sliding out: a connect now would be ignored.
  busy(): boolean;
  readonly current: Session | undefined;
  /// Page teardown. Tests only — the page never ends its controller.
  dispose(): void;
}

export function createSessionController(deps: ControllerDeps): SessionController {
  const win = deps.win ?? window;
  const create = deps.create ?? createSession;
  const motion = deps.motion ?? (deps.context ? () => undefined : shellstormMotion);
  const parsePsk = deps.parsePsk ?? (async (carrier: string) => (await parsePairing(carrier))?.psk ?? null);
  const pin = deps.pin ?? ((): (() => void) =>
    !deps.context && win.matchMedia?.("(pointer: coarse)").matches ? new ViewportFit(win.document.body).start() : () => {});
  const page = new AbortController();
  let current: Session | undefined;
  let constructing = false;
  /// The current session's options, kept for a bfcache restart; cleared when it ends.
  let options: Omit<SessionOptions, "generation"> | undefined;
  /// **SEEDED FROM THE CLOCK, NOT FROM ZERO.** The glasses' history entries carry a session's
  /// generation (`glasses-history.ts`) and outlive a reload; a count restarted at zero on every page
  /// load would hand a later page's session an earlier page's number, and it would adopt its screens.
  let generation = Date.now();
  let closing = false;
  /// The dashboard row that is lit for the current session, put out when it closes.
  let row: HTMLElement | null = null;
  let leftIntoCache = false;
  /// The body pin's release while the session DOM is mounted.
  let unpin: (() => void) | undefined;

  /// **THE BODY PIN LIVES WITH THE MOUNTED DOM, NOT WITH THE ENGINE** (spec §Viewport: "from create to
  /// unmount"). Disconnect disposes the engine at the START of the slide; a pin released then would
  /// drop the sliding session from the visible band to the layout viewport with the keyboard up.
  function mount(): void {
    deps.dom.mount();
    unpin = pin();
  }
  function unmount(): void {
    const release = unpin;
    unpin = undefined;
    try { release?.(); } finally { deps.dom.unmount(); }
  }

  /// A connect that failed AFTER welcome began the morph. Said DIRECTLY, never through a host: the
  /// session never got one, or no longer has a current generation to say it with. `motion.js` paints
  /// it as the phase; welcome keeps it on the error line and restores the button.
  function refuse(text: string): false {
    emitState({ state: "error", text });
    return false;
  }

  function emitState(detail: Parameters<SessionHost["state"]>[0]): void {
    deps.onState?.(detail);
    if (!deps.context) win.document.dispatchEvent(new CustomEvent("shellstorm:connection-state", { detail }));
  }

  const hostFor = (gen: number): SessionHost => ({
    // THE FENCE ON WHAT REACHES THE DASHBOARD IS THE GENERATION, AND ONLY THE GENERATION. Every way a
    // session stops being current — cancel, Disconnect, a bfcache restart, page teardown — goes
    // through `stop()`, which advances it in the same tick; so a closing session is ALREADY stale and
    // a `|| closing` term here could never be the one that drops a report. `motion.js` paints these as
    // the connect phase, and `main.ts` forwards them to the native shell.
    state: (detail) => {
      if (gen !== generation) return;
      emitState(detail);
    },
    requestClose: () => { if (gen === generation) close(); },
    requestReconnect: () => { if (gen === generation) restart(); },
    // A FOLLOWED MAC: a bfcache restart starts in the room it shares in, not the one it left — and with no seed,
    // which was for that room.
    moved: (room) => {
      if (gen !== generation || !options) return;
      const params = new URLSearchParams(options.params);
      params.set("code", room.code);
      params.set("token", room.token);
      options = { ...options, params, code: room.code, token: room.token, psk: Promise.resolve(null) };
      deps.onMoved?.(room);
    },
  });

  /// FALSE when the session could not be built, with everything released and the failure SAID.
  const START_FAILED = "Could not start the session.";

  function start(next: Omit<SessionOptions, "generation">): boolean {
    generation += 1;
    const gen = generation;
    constructing = true;
    options = next;
    // After the DOM and the pending reveal, and synchronously: network init must not wait for motion.
    try {
      mount();
      motion()?.prepareSession();
      const built = create({ ...next, generation: gen, ...(deps.context ? {context: deps.context} : {}) }, hostFor(gen));
      if (gen !== generation || page.signal.aborted) { built.dispose(); return false; }
      constructing = false;
      current = built;
      return true;
    } catch (e) {
      // A session that failed to BUILD leaves nothing behind. `createSession` released what it had
      // built before rethrowing; here: no DOM (a mount with no unmount would make the next connect's
      // mount throw — `session-dom.ts`), no pin, no options, and a generation that fences anything the
      // half-built session said before it threw.
      if (gen !== generation || page.signal.aborted) return false;
      constructing = false;
      console.error("[session] could not start the session", e);
      generation += 1;
      options = undefined;
      row = null;
      unmount();
      return refuse(START_FAILED);
    }
  }

  /// Dispose the current session and advance the generation, so anything it still says is stale.
  function stop(): void {
    const s = current;
    current = undefined;
    constructing = false;
    generation += 1;
    s?.dispose();
  }

  function connect(search: string): boolean {
    if (current || constructing || closing || page.signal.aborted) return false;
    const target = splitConnectSearch(search);
    if (!target) return refuse("That link has no pairing code.");
    const params = new URLSearchParams(deps.pageParams());
    params.set("code", target.code);
    params.set("token", target.token);
    const psk = target.carrier ? parsePsk(target.carrier).catch(() => null) : Promise.resolve(null);
    row = deps.welcome?.querySelector<HTMLElement>(".device-card.is-connecting") ?? null;
    const designed = deps.transport?.(target.code) ?? (!deps.context && import.meta.env.DEV ? designTransport(target.code) : undefined);
    return start({ params, code: target.code, token: target.token, psk, layout: deps.layout,
                   ...(designed ? { transport: designed } : {}) });
  }

  function connectTransport(transport: Transport): boolean {
    if (current || constructing || closing || page.signal.aborted) return false;
    row = null;
    return start({ params: new URLSearchParams(deps.pageParams()), code: "", token: "",
                   psk: Promise.resolve(null), layout: deps.layout, transport });
  }

  function cancel(): void {
    if ((!current && !constructing) || closing) return;
    stop();
    options = undefined;
    row = null;
    unmount();
  }

  /// DISCONNECT: the engine goes NOW; the painted DOM stays for the slide-out, its input handlers
  /// already gone, and is removed when the slide ends.
  function close(): void {
    if ((!current && !constructing) || closing) return;
    closing = true;
    stop();
    options = undefined;
    deps.onDisconnect?.();
    const finished = (): void => {
      unmount();
      const lit = row;
      row = null;
      if (lit) motion()?.unlight(lit);
      closing = false;
      deps.onClosed?.();
    };
    const m = motion();
    if (m) m.close(finished);
    else { deps.welcome?.classList.remove("hidden"); finished(); }
  }

  const { signal } = page;
  function restart(): void {
    const again = options;
    if (!current || !again || closing) return;
    stop();
    unmount();
    if (!start(again)) deps.onRestartFailed?.(START_FAILED);
  }

  // A DELIBERATE close on navigation: tell the control plane now rather than letting it hold this
  // client for the 180 s grace window (sources-and-focus.md). Fired for bfcache too.
  win.addEventListener("pagehide", (e) => { leftIntoCache = e.persisted; current?.leave(); }, { signal });
  // **A PAGE RESTORED FROM THE BACK/FORWARD CACHE RESTARTS ITS SESSION IN PLACE.** The goodbye above
  // ended it; the same pairing (psk included) starts a fresh one — no reload, the dashboard intact.
  win.addEventListener("pageshow", (e) => {
    if (!e.persisted || !leftIntoCache) return;
    leftIntoCache = false;
    restart();
  }, { signal });
  // **INPUT SETTLES THE SLIDE FIRST.** Window CAPTURE, and registered by a controller created before
  // the layout watcher, the glasses nav and any key strip: listeners on one target and phase run in
  // registration order, so nothing maps a coordinate against a surface still mid-transform.
  const settle = (event: Event): void => {
    if (deps.context && !event.composedPath().includes(deps.context.root)) return;
    if (deps.sessionRoot.classList.contains("ss-session-moving")) motion()?.finish();
  };
  for (const type of ["pointerdown", "pointermove", "keydown", "wheel"] as const) {
    win.addEventListener(type, settle, { capture: true, passive: true, signal });
  }
  // The debug hook is the CURRENT session's, and there is none between sessions.
  if (!deps.context) Object.defineProperty(win, "__rdev", { configurable: true, get: () => current?.debug });

  return {
    connect,
    connectTransport,
    disconnect: close,
    cancel,
    busy: () => current !== undefined || constructing || closing,
    get current() { return current; },
    dispose() {
      page.abort();
      stop();
      options = undefined;
      const release = unpin;
      unpin = undefined;
      release?.();
      if (!deps.context) Object.defineProperty(win, "__rdev", { configurable: true, writable: true, value: undefined });
    },
  };
}
