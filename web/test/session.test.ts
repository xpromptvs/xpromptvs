import "fake-indexeddb/auto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { decodeSocketFrame, encodeSocketFrame, LEAVE_CLOSE_CODE, type SocketChannelName } from "@rdev/protocol";
import html from "../src/client/instance/session.html?raw";
import { createSession, type Session, type SessionOptions } from "../src/client/session";
import { ClientE2EIdentity } from "../src/client/e2e-identity";
import { WindowManager } from "../src/client/window-manager";
import { socketTransport } from "../src/client/socket-connection";
import type { MessageSocket } from "../src/lib/socket-channels";
import type { ConnectionSink, Transport } from "../src/client/connection";
import { decodeJson, encodeJson } from "../src/lib/codec";
import { LaneLink, type LaneDataChannel } from "../src/lib/lane-channel";

/// The smallest RTCPeerConnection `PeerSession` and the session touch without a host.
class FakePC extends EventTarget {
  static made: FakePC[] = [];
  connectionState: RTCPeerConnectionState = "new";
  signalingState: RTCSignalingState = "stable";
  remoteDescription: RTCSessionDescription | null = null;
  localDescription: RTCSessionDescription | null = null;
  onicecandidate: unknown = null;
  ontrack: unknown = null;
  ondatachannel: unknown = null;
  closed = false;
  closes = 0;
  constructor() { super(); FakePC.made.push(this); }
  setConfiguration(): void {}
  getStats(): Promise<Map<string, unknown>> { return Promise.resolve(new Map()); }
  getReceivers(): unknown[] { return []; }
  close(): void { this.closes += 1; this.closed = true; this.signalingState = "closed"; this.connectionState = "closed"; }
}

/// A WebSocket the test plays the control plane on.
class FakeWS extends EventTarget {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
  static made: FakeWS[] = [];
  readyState = 0;
  sent: string[] = [];
  closedWith: number | undefined;
  closes = 0;
  constructor(readonly url: string) { super(); FakeWS.made.push(this); }
  send(data: string): void { this.sent.push(data); }
  close(code?: number): void { this.closes += 1; this.closedWith = code ?? 1000; this.readyState = 3; }
  open(): void { this.readyState = 1; this.dispatchEvent(new Event("open")); }
  serve(message: unknown): void { this.dispatchEvent(new MessageEvent("message", { data: JSON.stringify(message) })); }
}

const WELCOME = { t: "welcome", turn: { urls: ["stun:127.0.0.1:3478"], username: "u", credential: "c" } };
const FAKE = ["setTimeout", "clearTimeout", "setInterval", "clearInterval",
              "requestAnimationFrame", "cancelAnimationFrame"] as const;

/// index.html's own body — never hand-written markup — minus its module script.
function loadPage(): void {
  const shipped = new DOMParser().parseFromString(html, "text/html");
  document.body.replaceChildren(...[...shipped.body.childNodes]
    .filter((n) => n.nodeName !== "SCRIPT")
    .map((n) => document.importNode(n, true)));
}

/// Registrations on `target` still live: neither removed nor released by an aborted signal.
function trackListeners(target: EventTarget): () => string[] {
  const records: { type: string; fn: unknown; capture: boolean; signal?: AbortSignal; removed: boolean }[] = [];
  const add = target.addEventListener.bind(target);
  const remove = target.removeEventListener.bind(target);
  const captureOf = (o: unknown) => typeof o === "boolean" ? o : !!(o as { capture?: boolean } | undefined)?.capture;
  vi.spyOn(target, "addEventListener").mockImplementation((type, fn, opts) => {
    records.push({ type, fn, capture: captureOf(opts), removed: false,
                   signal: typeof opts === "object" ? opts?.signal : undefined });
    add(type, fn, opts);
  });
  vi.spyOn(target, "removeEventListener").mockImplementation((type, fn, opts) => {
    for (const r of records) if (!r.removed && r.type === type && r.fn === fn && r.capture === captureOf(opts)) r.removed = true;
    remove(type, fn, opts);
  });
  return () => records.filter((r) => !r.removed && !r.signal?.aborted).map((r) => r.type);
}

function start(over: Partial<SessionOptions> = {}) {
  const states: string[] = [];
  const session = createSession({
    params: new URLSearchParams("code=c&token=t"), code: "c", token: "t",
    psk: Promise.resolve(null), layout: () => "floating", ...over,
  }, { state: (d) => states.push(d.text), requestClose: () => {} });
  return { session, states, ws: FakeWS.made.at(-1)!, pc: FakePC.made.at(-1)! };
}

let live: Session | undefined;
beforeEach(() => {
  FakePC.made = [];
  FakeWS.made = [];
  vi.stubGlobal("RTCPeerConnection", FakePC);
  vi.stubGlobal("WebSocket", FakeWS);
  vi.stubGlobal("ResizeObserver", class { observe(): void {} disconnect(): void {} });
  Object.defineProperty(window, "matchMedia", { configurable: true, writable: true,
    value: (media: string) => ({ matches: false, media, addEventListener() {}, removeEventListener() {} }) });
  loadPage();
});
afterEach(() => {
  live?.dispose();
  live = undefined;
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  Reflect.deleteProperty(window, "matchMedia");
});

describe("createSession in the page's own document", () => {
  it("CONTROL: undisposed, a welcome with no identity and no psk reaches the setup panel", async () => {
    const { session, ws } = start();
    live = session;
    ws.open();
    ws.serve(WELCOME);
    await vi.waitFor(() => expect(document.getElementById("e2e-setup")!.hasAttribute("open")).toBe(true),
                     { timeout: 3000 });
  });

  it("dispose MID-HANDSHAKE: nothing after it reaches the host, the panel never opens, the leave is said", async () => {
    const { session, states, ws, pc } = start();
    ws.open();
    ws.serve(WELCOME);
    expect(states).toContain("waiting for host…");        // the welcome's own status, before any await
    const said = states.length;
    session.dispose();
    await new Promise((r) => setTimeout(r, 500));          // well past the identity store's continuation
    expect(states.length).toBe(said);
    expect(document.getElementById("e2e-setup")!.hasAttribute("open")).toBe(false);
    expect(pc.closed).toBe(true);
    expect(ws.closedWith).toBe(LEAVE_CLOSE_CODE);
    expect(session.disposed).toBe(true);
  });

  it("create → dispose leaves no timer behind", () => {
    vi.useFakeTimers({ toFake: [...FAKE] });
    const { session } = start();
    expect(vi.getTimerCount()).toBeGreaterThan(0);         // the heartbeat, the stats ticks, the socket watchdog
    session.dispose();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("create → dispose leaves no window or document listener behind", () => {
    const onWindow = trackListeners(window);
    const onDocument = trackListeners(document);
    const { session } = start();
    expect([...onWindow(), ...onDocument()]).not.toEqual([]);   // it did register some
    session.dispose();
    expect([...onWindow(), ...onDocument()]).toEqual([]);
  });

  it("dispose is idempotent: the second call tears nothing down again", () => {
    const { session, ws, pc } = start();
    session.dispose();
    session.dispose();
    expect(ws.closedWith).toBe(LEAVE_CLOSE_CODE);
    expect(ws.closes).toBe(1);                              // ONE leave, not one per call
    expect(pc.closes).toBe(1);
  });

  it("a teardown step that THROWS still releases the socket, the peer and every timer", () => {
    vi.useFakeTimers({ toFake: [...FAKE] });
    const { session, ws, pc } = start();
    // A session dialog whose close throws: the first UI step of dispose().
    const dialog = document.getElementById("tmux-kill-dialog") as HTMLDialogElement;
    dialog.setAttribute("open", "");
    Object.defineProperty(dialog, "close", { configurable: true, value: () => { throw new Error("boom"); } });
    vi.spyOn(console, "error").mockImplementation(() => {});
    session.dispose();
    expect(session.disposed).toBe(true);
    expect(ws.closedWith).toBe(LEAVE_CLOSE_CODE);
    expect(pc.closed).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
    session.dispose();                                      // and a retry does not re-run it
    expect(ws.closes).toBe(1);
  });

  it("assigns no window.__rdev and listens to no pagehide — both belong to the page", () => {
    Reflect.deleteProperty(window, "__rdev");
    const onWindow = trackListeners(window);
    const { session } = start();
    live = session;
    expect((window as { __rdev?: unknown }).__rdev).toBeUndefined();
    expect(onWindow()).not.toContain("pagehide");
    expect(onWindow()).not.toContain("pageshow");
  });

  // The body pin is the CONTROLLER's, from mount to unmount (session-lifecycle.ts), on every route —
  // URL mode included. A session pinning too would be a second pin released at the start of the
  // Disconnect slide, dropping the sliding session to the layout viewport with the keyboard up.
  it("on a coarse pointer the session does NOT pin <body> — the controller does", () => {
    Object.defineProperty(window, "matchMedia", { configurable: true, writable: true,
      value: (media: string) => ({ matches: media.includes("coarse"), media, addEventListener() {}, removeEventListener() {} }) });
    const vv = Object.assign(new EventTarget(), { height: 600, offsetTop: 0 });
    Object.defineProperty(window, "visualViewport", { configurable: true, value: vv });
    try {
      const { session } = start();
      live = session;
      expect(document.body.style.position).toBe("");
    } finally { Reflect.deleteProperty(window, "visualViewport"); }
  });

  it("dispose while the psk is still being derived: the setup panel never opens", async () => {
    // A thenable, so the test knows the handshake has reached `await opts.psk` — a dispose earlier
    // than that is caught by the gateConfig fence, which the MID-HANDSHAKE test already covers.
    let awaited = false;
    let resolvePsk: (v: Uint8Array | null) => void = () => {};
    const psk = { then(res: (v: Uint8Array | null) => void) { awaited = true; resolvePsk = res; } } as
      unknown as Promise<Uint8Array | null>;
    const { session, ws } = start({ psk });
    ws.open();
    ws.serve(WELCOME);
    await vi.waitFor(() => expect(awaited).toBe(true), { timeout: 3000 });
    session.dispose();
    resolvePsk(null);
    await new Promise((r) => setTimeout(r, 200));
    expect(document.getElementById("e2e-setup")!.hasAttribute("open")).toBe(false);
  });
});

// FIX ROUND 1 (m-3): the key strip's held modifiers are MIRRORED ON THE HOST, and the page's
// `pagehide` reaches the session as `leave()`. The release must go out while the channels can still
// carry it — a listener of the session's own ran after the page's goodbye had already closed them.
describe("leave()", () => {
  class FakeChannel extends EventTarget {
    readyState = "open";
    binaryType = "blob";
    constructor(readonly label: string, private readonly log: string[]) { super(); }
    send(): void { this.log.push(`send:${this.label}`); }
    close(): void { this.readyState = "closed"; this.log.push(`close:${this.label}`); }
  }

  it("releases the strip's held modifiers BEFORE the peer and the socket close", () => {
    const log: string[] = [];
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(WindowManager.prototype, "releaseTouchMods").mockImplementation(() => { log.push("release-mods"); });
    const { session, ws, pc } = start();
    live = session;
    const deliver = pc.ondatachannel as (e: { channel: FakeChannel }) => void;
    for (const label of ["terminal", "input", "control", "bulk"]) deliver({ channel: new FakeChannel(label, log) });
    const close = pc.close.bind(pc);
    pc.close = () => { log.push("pc-close"); close(); };
    const wsClose = ws.close.bind(ws);
    ws.close = (code?: number) => { log.push("ws-close"); wsClose(code); };
    log.length = 0;
    session.leave();
    expect(log).toContain("release-mods");
    const release = log.indexOf("release-mods");
    expect(release).toBeLessThan(log.indexOf("pc-close"));
    expect(release).toBeLessThan(log.indexOf("ws-close"));
  });
});

// A CHANNEL CAN BE OPEN WHEN THE SET IS HANDED OVER, and the session's control-open batch must still go — once. A
// channel the host opened is OPEN when `ondatachannel` runs, its `open` event after: on the SCTP baseline `control`
// has opened before `bulk` completes the set; on the lane, the three streams read open at the hand-over.
describe("a channel already open when the set is handed over", () => {
  const ts = (data: ArrayBufferLike | ArrayBufferView) => decodeJson<{ t: string }>(Uint8Array.from(
    ArrayBuffer.isView(data) ? [...new Uint8Array(data.buffer, data.byteOffset, data.byteLength)] : [...new Uint8Array(data as ArrayBuffer)])).t;
  class FakeChannel extends EventTarget {
    readyState: RTCDataChannelState = "connecting";
    binaryType: BinaryType = "blob";
    bufferedAmount = 0;
    bufferedAmountLowThreshold = 0;
    sent: string[] = [];
    peer: FakeChannel | null = null;
    constructor(readonly label: string) { super(); }
    send(data: ArrayBufferView): void {
      if (this.peer) {   // a lane: the packet crosses to the other end
        const copy = Uint8Array.from([...new Uint8Array(data.buffer, data.byteOffset, data.byteLength)]).buffer;
        const peer = this.peer;
        queueMicrotask(() => peer.dispatchEvent(new MessageEvent("message", { data: copy })));
      } else this.sent.push(ts(data));
    }
    close(): void {
      if (this.readyState === "closed") return;
      this.readyState = "closed";
      this.dispatchEvent(new Event("close"));
      this.peer?.close();
    }
  }
  /// As a browser hands a channel over: open at `ondatachannel`, its own `open` right after.
  const handOver = (deliver: (e: { channel: FakeChannel }) => void, ch: FakeChannel) => {
    ch.readyState = "open";
    deliver({ channel: ch });
    ch.dispatchEvent(new Event("open"));
  };

  it("the SCTP baseline: control opened before bulk completed the set", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { session, pc } = start();
    live = session;
    const deliver = pc.ondatachannel as (e: { channel: FakeChannel }) => void;
    const control = new FakeChannel("control");
    for (const ch of [new FakeChannel("terminal"), new FakeChannel("input"), control, new FakeChannel("bulk")]) handOver(deliver, ch);
    expect(control.sent.filter((t) => t === "client-hello")).toHaveLength(1);
    control.dispatchEvent(new Event("open"));
    expect(control.sent.filter((t) => t === "client-hello"), "once").toHaveLength(1);
  });

  // A THUMBNAIL ARRIVES ON BULK (the host's SimManager.requestThumbs sends it there, off the lane: a 20–35 KB JPEG
  // must not sit ahead of the terminal), and bulk's dispatch is the control dispatch — it reaches the palette's
  // thumbnails, keyed by source id, whatever came before it on control.
  it("a source-thumb arriving on bulk reaches the palette's thumbnails", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { session, pc } = start();
    live = session;
    const deliver = pc.ondatachannel as (e: { channel: FakeChannel }) => void;
    const bulk = new FakeChannel("bulk");
    for (const ch of [new FakeChannel("terminal"), new FakeChannel("input"), new FakeChannel("control"), bulk]) handOver(deliver, ch);
    const payload = encodeJson({ t: "source-thumb", id: "win:42", fmt: "jpeg", data: "AAAA" });
    bulk.dispatchEvent(new MessageEvent("message", { data: payload.slice().buffer }));
    expect(session.debug.thumbs?.()).toEqual([{ id: "win:42", dataUrl: "data:image/jpeg;base64,AAAA" }]);
  });

  it("the lane: the control-open batch reaches the host's end of the lane, once", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { session, pc } = start();
    live = session;
    const deliver = pc.ondatachannel as (e: { channel: FakeChannel }) => void;
    handOver(deliver, new FakeChannel("bulk"));
    const page = new FakeChannel("lane"), host = new FakeChannel("lane");
    page.peer = host; host.peer = page;
    host.readyState = "open";
    const H = new LaneLink(host as unknown as LaneDataChannel, { connected: () => true, seed: 9 });
    const got: string[] = [];
    H.channels[2].addEventListener("message", (e) => got.push(ts((e as MessageEvent).data as ArrayBuffer)));
    handOver(deliver, page);
    await vi.waitFor(() => expect(got).toContain("client-hello"), { timeout: 3000 });
    await new Promise((r) => setTimeout(r, 50));
    expect(got.filter((t) => t === "client-hello"), "once").toHaveLength(1);
    H.close();                                     // both ends: no lane keeps its timers past the test
    expect([page.readyState, host.readyState]).toEqual(["closed", "closed"]);
  });
});

// CARRIED (Task 3 review): §10.1's local reset — the identity-mismatch dialog's Replace — must never
// run for a session that has been disposed. The app's client window asks it mid-connect; Cancel or
// Disconnect can land between the answer and the reset, and a reset then would change the window's
// identity on behalf of a session nobody is looking at any more.
describe("the identity-mismatch Replace", () => {
  const g = globalThis as { __rdevShell?: unknown };
  function mismatchedShell() {
    g.__rdevShell = { signalingBase: "https://cp.test", issueGrant: async () => "",
                      e2eIdentity: async () => "ZZZZ-ZZZZ-ZZZZ-ZZZZ" };
    vi.spyOn(ClientE2EIdentity.prototype, "gateConfig").mockResolvedValue({} as never);
    vi.spyOn(ClientE2EIdentity.prototype, "trustedRoot").mockResolvedValue(new Uint8Array(32).fill(1));
    vi.spyOn(ClientE2EIdentity.prototype, "adoptFromShell")
      .mockResolvedValue({ ok: false, failure: { kind: "shell" } } as never);
    return vi.spyOn(ClientE2EIdentity.prototype, "resetTrust").mockResolvedValue(true);
  }
  const dialog = () => document.getElementById("identity-mismatch") as HTMLDialogElement;
  async function reachDialog() {
    const { session, ws } = start();
    ws.open();
    ws.serve(WELCOME);
    await vi.waitFor(() => expect(dialog().hasAttribute("open")).toBe(true), { timeout: 3000 });
    return session;
  }
  afterEach(() => { delete g.__rdevShell; });

  it("CONTROL: undisposed, Replace resets the trust", async () => {
    const reset = mismatchedShell();
    live = await reachDialog();
    dialog().querySelector<HTMLButtonElement>("[data-identity-mismatch-confirm]")!.click();
    await vi.waitFor(() => expect(reset).toHaveBeenCalledTimes(1));
  });

  it("Replace answered, then the session disposed before the answer lands: the trust is NOT reset", async () => {
    const reset = mismatchedShell();
    const session = await reachDialog();
    dialog().querySelector<HTMLButtonElement>("[data-identity-mismatch-confirm]")!.click();
    session.dispose();                                     // same tick: the answer has not landed yet
    await new Promise((r) => setTimeout(r, 200));
    expect(reset).not.toHaveBeenCalled();
  });
});

// **A SESSION THAT THROWS PART-WAY MUST RELEASE WHAT IT BUILT BEFORE THE THROW.** `buildPeer()` runs
// LAST, so a browser whose `RTCPeerConnection` constructor throws (WebRTC disabled or blocked) did so
// with the signalling socket open, the heartbeat running, the window listeners registered and, on a
// coarse pointer, <body> pinned — none of it reachable by anyone, because no `Session` was returned
// to dispose. Under the iframe, removing the frame released it all; in one document, nothing did.
describe("createSession that throws part-way", () => {
  it("releases its socket, timers and listeners, leaves <body> unpinned, then rethrows", () => {
    vi.useFakeTimers({ toFake: [...FAKE] });
    const onWindow = trackListeners(window);
    const onDocument = trackListeners(document);
    Object.defineProperty(window, "matchMedia", { configurable: true, writable: true,
      value: (media: string) => ({ matches: media.includes("coarse"), media, addEventListener() {}, removeEventListener() {} }) });
    const vv = Object.assign(new EventTarget(), { height: 600, offsetTop: 0 });
    Object.defineProperty(window, "visualViewport", { configurable: true, value: vv });
    vi.stubGlobal("RTCPeerConnection", class { constructor() { throw new Error("WebRTC is disabled"); } });
    try {
      expect(() => start()).toThrow("WebRTC is disabled");
      expect(FakeWS.made.length).toBeGreaterThan(0);                       // it DID open one
      expect(FakeWS.made.every((ws) => ws.closes > 0)).toBe(true);
      expect(FakeWS.made.at(-1)!.closedWith).toBe(LEAVE_CLOSE_CODE);       // said as a deliberate leave
      expect(vi.getTimerCount()).toBe(0);
      expect([...onWindow(), ...onDocument()]).toEqual([]);
      expect(document.body.style.position).toBe("");
      expect(document.documentElement.style.getPropertyValue("--safe-b")).toBe("");
    } finally {
      Reflect.deleteProperty(window, "visualViewport");
    }
  });

  it("a throw MID-BUILD (the stage's ResizeObserver, long before the peer) releases the same", () => {
    vi.useFakeTimers({ toFake: [...FAKE] });
    vi.stubGlobal("ResizeObserver", class { constructor() { throw new Error("no ResizeObserver"); } });
    expect(() => start()).toThrow("no ResizeObserver");
    // The connection is established LAST (`transport.connect`, where the first peer used to be built),
    // so a build that throws midway has opened no socket at all; releasing a socket that WAS opened is
    // the "WebRTC disabled" test's arm.
    expect(FakeWS.made.length).toBe(0);
    expect(FakeWS.made.every((ws) => ws.closes > 0)).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });
});

// **A WINDOW-LESS SESSION** (docs/client-web.md): a transport that carries no media — one message
// socket — renders the terminal only. The view-set's windows, full screen and surface are the windowed
// devices'; following them would build windows it cannot show and switch it to a surface it lacks, and
// the host refuses every window and media message it could send (WindowlessPolicy).
describe("a window-less session (a message socket)", () => {
  /// A WebSocket-shaped socket the test plays the HOST on. Bytes are kept as NUMBER arrays: under jsdom
  /// a `TextEncoder`'s Uint8Array comes from another realm.
  class FakeSocket extends EventTarget implements MessageSocket {
    binaryType: BinaryType = "blob";
    readyState = 0;
    sent: number[][] = [];
    send(data: ArrayBufferLike | ArrayBufferView): void {
      this.sent.push(ArrayBuffer.isView(data) ? [...new Uint8Array(data.buffer, data.byteOffset, data.byteLength)]
                                              : [...new Uint8Array(data as ArrayBuffer)]);
    }
    close(): void { this.readyState = 3; this.dispatchEvent(new Event("close")); }
    opened(): void { this.readyState = 1; this.dispatchEvent(new Event("open")); }
    /// The host sending `obj` on `channel`, wrapped as the session decodes it and framed.
    serve(channel: SocketChannelName, obj: unknown): void {
      const frame = [...encodeSocketFrame(channel, Uint8Array.from([...encodeJson(obj)]))];
      const data = new ArrayBuffer(frame.length);
      new Uint8Array(data).set(frame);
      this.dispatchEvent(new MessageEvent("message", { data }));
    }
    /// The `t` of every message the page sent on `channel`.
    sentOn(channel: SocketChannelName): string[] {
      return this.sent.flatMap((bytes) => {
        const f = decodeSocketFrame(Uint8Array.from(bytes));
        return f?.channel === channel ? [decodeJson<{ t: string }>(Uint8Array.from([...f.payload])).t] : [];
      });
    }
  }

  it("native simulator tabs keep mixed host state and selecting a terminal updates the host view", () => {
    const socket = new FakeSocket();
    const { session } = start({ transport: socketTransport({ clientId: "native", open: () => socket, nativeSimulators: true }) });
    live = session; socket.opened();
    socket.serve("control", { t: "control-state", active: true, clients: 1 });
    socket.serve("control", { t: "term-list", activeId: "pty:1", tabs: [{ id: "pty:1", n: 1, title: "zsh" }] });
    socket.serve("control", { t: "view-set", subs: [], focused: "sim:one",
      windows: [{ source: "sim:one", minimized: false }, { source: "win:42", minimized: false }, { source: "dsp:1", minimized: false }],
      view: { surface: "windows", fullscreen: null }, tabOrder: ["pty:1", "sim:one", "win:42", "dsp:1"], version: 3 });
    expect(document.querySelectorAll("#win-tabs .rl-tab")).toHaveLength(1);
    expect(document.querySelectorAll(".source-window")).toHaveLength(0);
    expect(socket.sentOn("control")).not.toContain("unsubscribe");
    for (const t of ["set-source-prefs", "set-recovery", "set-playout-delay", "set-visibility"]) expect(socket.sentOn("control")).not.toContain(t);
    (document.querySelector("#term-empty-new") as HTMLElement).click();
    const sent = socket.sent.flatMap(bytes => {
      const f = decodeSocketFrame(Uint8Array.from(bytes));
      return f?.channel === "control" ? [decodeJson<{t: string; surface?: string}>(Uint8Array.from([...f.payload]))] : [];
    });
    expect(sent).toContainEqual({ t: "set-view", surface: "terminal" });
    session.dispose(); live = undefined;
  });

  it("renders the terminal only: it follows no view, builds no window and states none", () => {
    const socket = new FakeSocket();
    const { session } = start({ transport: socketTransport({ clientId: "tab-1", open: () => socket }) });
    live = session;
    const root = document.documentElement;
    expect(root.dataset.windowless).toBe("");
    socket.opened();
    socket.serve("control", { t: "control-state", active: true, clients: 1 });
    socket.serve("control", {
      t: "view-set", subs: [{ source: "win:42", scale: 1, fps: 60, bitrateBps: 8_000_000 }], focused: "win:42",
      windows: [{ source: "win:42", minimized: false }], view: { surface: "windows", fullscreen: "win:42" }, version: 3,
    });
    // The page going away and coming back: the terminal pauses and resumes; there is no media to.
    Object.defineProperty(document, "hidden", { configurable: true, value: true });
    document.dispatchEvent(new Event("visibilitychange"));
    Reflect.deleteProperty(document, "hidden");
    document.dispatchEvent(new Event("visibilitychange"));

    expect(root.dataset.windowless).toBe("");
    expect(document.querySelectorAll(".source-window")).toHaveLength(0);
    expect(root.dataset.tab).toBe("terminal");
    const sent = socket.sentOn("control");
    expect(sent).toContain("client-hello");                               // it did speak on the channel
    expect(sent).toContain("terminal-pause");
    expect(sent).toContain("terminal-resume");
    for (const t of ["set-view", "list-sources", "request-thumbs", "set-visibility"]) expect(sent).not.toContain(t);

    session.dispose();
    live = undefined;
    expect(root.dataset.windowless).toBeUndefined();
  });
});

describe("the tab bar the host's offer carries (docs/sources-and-focus.md, \"The offer carries the tab bar\")", () => {
  /// The window-less arm's socket, carrying MEDIA as the relay does — the design workbench's arrangement — with the
  /// session's sink kept, so the test plays the offer `rtc-connection.ts` hands it.
  class HostSocket extends EventTarget implements MessageSocket {
    binaryType: BinaryType = "blob";
    readyState = 0;
    send(): void {}
    close(): void { this.readyState = 3; this.dispatchEvent(new Event("close")); }
    opened(): void { this.readyState = 1; this.dispatchEvent(new Event("open")); }
    serve(channel: SocketChannelName, obj: unknown): void {
      const frame = [...encodeSocketFrame(channel, Uint8Array.from([...encodeJson(obj)]))];
      const data = new ArrayBuffer(frame.length);
      new Uint8Array(data).set(frame);
      this.dispatchEvent(new MessageEvent("message", { data }));
    }
  }
  function relayLike(socket: HostSocket): { transport: Transport; sink: () => ConnectionSink } {
    let sink: ConnectionSink | undefined;
    const inner = socketTransport({ clientId: "tab-1", open: () => socket });
    const transport: Transport = {
      carriesMedia: true, sameMac: false,
      connect(deps) {
        sink = deps.sink;
        const c = inner.connect(deps);
        return {
          get connectionState() { return c.connectionState; },
          media: { getStats: async () => new Map() as unknown as RTCStatsReport, getReceivers: () => [], localSdp: () => "" },
          closeDialogs: () => c.closeDialogs(), leave: () => c.leave(), close: () => c.close(),
        };
      },
    };
    return { transport, sink: () => sink! };
  }
  const OFFER = (active: boolean) => [
    { t: "control-state", active, clients: 1 },
    { t: "term-list", activeId: "pty:1", tabs: [{ id: "pty:1", n: 1, title: "zsh" }, { id: "tmux:$0", n: 2, title: "work", agent: "working" }] },
    { t: "view-set", subs: [], focused: "win:7", windows: [{ source: "win:7", minimized: false }, { source: "win:9", minimized: true, name: "Notes" }],
      view: { surface: "terminal", fullscreen: null }, tabOrder: ["pty:1", "win:7", "tmux:$0", "win:9"], version: 4 },
    { t: "source-list", sources: [{ id: "win:7", kind: "window", name: "Safari — Docs", inputCapable: true, running: true }] },
  ];
  const labels = (strip: string) => [...document.querySelectorAll(`#${strip} .rl-tab`)].map((t) => t.querySelector(".rl-tab-label")?.textContent);
  const inert = (strip: string) => (document.getElementById(strip) as HTMLElement).inert;

  it("draws the session's real tabs before any channel opens — inert, in the bar's order — and nothing else", () => {
    const socket = new HostSocket();
    const { transport, sink } = relayLike(socket);
    const { session } = start({ transport });
    live = session;
    sink().earlyState?.(OFFER(true));

    expect(labels("term-tabs")).toEqual(["zsh", "work"]);
    expect(labels("win-tabs"), "the listed name, else the window's own").toEqual(["Safari — Docs", "Notes"]);
    expect(inert("term-tabs")).toBe(true);
    expect(inert("win-tabs")).toBe(true);
    const order = (key: string) => (document.querySelector(`[data-tab-key="${key}"]`) as HTMLElement).style.order;
    expect(["pty:1", "win:7", "tmux:$0", "win:9"].map(order)).toEqual(["1", "2", "3", "4"]);
    expect(document.getElementById("tab-skeleton")!.classList.contains("hidden")).toBe(true);
    expect(document.querySelectorAll(".source-window")).toHaveLength(0);
    expect(document.getElementById("term-empty")!.classList.contains("hidden")).toBe(true);
  });

  it("each strip goes back to the host's own list as it lands on `control`: the terminals at the term-list, the windows at the view-set", () => {
    const socket = new HostSocket();
    const { transport, sink } = relayLike(socket);
    const { session } = start({ transport });
    live = session;
    sink().earlyState?.(OFFER(true));
    socket.opened();
    socket.serve("control", { t: "control-state", active: true, clients: 1 });
    expect(labels("term-tabs"), "the offer's tabs stay through control-state — no blank frame").toEqual(["zsh", "work"]);
    socket.serve("control", { t: "term-list", activeId: "pty:3", tabs: [{ id: "pty:3", n: 3, title: "vim" }] });
    expect(labels("term-tabs")).toEqual(["vim"]);
    expect(inert("term-tabs")).toBe(false);
    expect(labels("win-tabs"), "the windows wait for their own list").toEqual(["Safari — Docs", "Notes"]);
    expect(inert("win-tabs")).toBe(true);
    socket.serve("control", { t: "view-set", subs: [], focused: null, windows: [{ source: "win:7", minimized: true }],
                              view: { surface: "terminal", fullscreen: null }, tabOrder: ["pty:3", "win:7"], version: 5 });
    expect(labels("win-tabs"), "the offer's names stand under the host's own listing").toEqual(["Safari — Docs"]);
    expect(inert("win-tabs")).toBe(false);
  });

  it("a client the offer called the driver that is passive by the time `control` speaks is drawn no terminal tab", () => {
    const socket = new HostSocket();
    const { transport, sink } = relayLike(socket);
    const { session } = start({ transport });
    live = session;
    sink().earlyState?.(OFFER(true));
    socket.opened();
    socket.serve("control", { t: "control-state", active: false, clients: 2 });
    socket.serve("control", { t: "term-list", activeId: "pty:1", tabs: [{ id: "pty:1", n: 1, title: "zsh" }] });
    expect(labels("term-tabs")).toEqual([]);
  });

  it("an offer that says this client is passive draws no terminal tab; one after the host's own list changes nothing", () => {
    const socket = new HostSocket();
    const { transport, sink } = relayLike(socket);
    const { session } = start({ transport });
    live = session;
    sink().earlyState?.(OFFER(false));
    expect(labels("term-tabs")).toEqual([]);
    socket.opened();
    socket.serve("control", { t: "control-state", active: true, clients: 1 });
    socket.serve("control", { t: "term-list", activeId: "pty:3", tabs: [{ id: "pty:3", n: 3, title: "vim" }] });
    sink().earlyState?.(OFFER(true));                       // a rebuilt peer's offer, the list long in
    expect(labels("term-tabs")).toEqual(["vim"]);
    expect(inert("term-tabs")).toBe(false);
  });
});

// M-3's retint moved PAGE-LEVEL (main.ts, registered once via onThemeChange, since the theme and the
// tint both outlive any one session) — see e2e/shellstorm-motion-check.mjs for the coverage of that:
// main.ts is page-setup-only and not imported by this file. `session.ts` itself no longer subscribes.

describe('native sources after a media rebuild with retained control', () => {
  class RetainedChannel extends EventTarget {
    readyState: RTCDataChannelState = 'open';
    binaryType: BinaryType = 'arraybuffer';
    bufferedAmount = 0;
    constructor(readonly label: string) { super(); }
    send(): void {}
    receive(message: unknown): void {
      this.dispatchEvent(new MessageEvent('message', { data: encodeJson(message).slice().buffer }));
    }
  }
  async function fixture() {
    const info = { supported: true, generation: 1, revision: 0, visible: true, keyWindow: true };
    const api = {
      nativeSourceWindowsInfo: vi.fn(async () => info),
      syncSourceWindows: vi.fn(async (_manifest: unknown) => info),
      prepareSourceWindow: vi.fn((_source: string, _generation: number) => new Promise<never>(() => {})),
      resetSourceWindows: vi.fn(async () => info),
      sourceWindowCommand: vi.fn(async () => null),
      onSourceWindowEvent: vi.fn(() => () => {}),
    };
    vi.stubGlobal('__rdevShell', api);
    const control = new RetainedChannel('control');
    let sink!: ConnectionSink;
    const transport: Transport = {
      carriesMedia: true, sameMac: false,
      connect(deps) {
        sink = deps.sink;
        sink.channels({ control, terminal: new RetainedChannel('terminal'), input: new RetainedChannel('input'), bulk: new RetainedChannel('bulk') });
        return { connectionState: 'connected', media: { getStats: async () => new Map() as unknown as RTCStatsReport, getReceivers: () => [], localSdp: () => '' }, closeDialogs() {}, leave() {}, close() {} };
      },
    };
    const { session } = start({ transport }); live = session;
    control.receive({ t: 'control-state', active: true, clients: 1 });
    control.receive({ t: 'source-input-capabilities', v: 1 });
    await vi.waitFor(() => expect(api.syncSourceWindows).toHaveBeenLastCalledWith(expect.objectContaining({ driving: true })));
    const open = () => control.receive({ t: 'view-set', version: 1, windows: [{ source: 'win:42', minimized: false }], focused: 'win:42', view: { surface: 'windows', fullscreen: null }, subs: [] });
    return { api, control, sink, session, open };
  }
  it('opens a newly selected source without another control-state or channel-open event', async () => {
    const t = await fixture();
    t.sink.peerClosed?.({ controlRetained: true });
    t.open();
    await vi.waitFor(() => expect(t.api.prepareSourceWindow).toHaveBeenCalledWith('win:42', 1));
    expect((t.session.debug.nativeSourceInput as () => unknown)()).toMatchObject({ capable: true, driving: true });
  });
  it('does not revive sources when the logical admission was lost', async () => {
    const t = await fixture();
    t.sink.peerClosed?.({ controlRetained: false });
    t.open();
    await vi.waitFor(() => expect(t.api.syncSourceWindows).toHaveBeenLastCalledWith(expect.objectContaining({ sources: [expect.objectContaining({ source: 'win:42' })] })));
    expect(t.api.syncSourceWindows.mock.lastCall?.[0]).toMatchObject({ driving: false });
    expect(t.api.prepareSourceWindow).not.toHaveBeenCalled();
    t.control.receive({ t: 'control-state', active: true, clients: 1 });
    await vi.waitFor(() => expect(t.api.prepareSourceWindow).toHaveBeenCalledWith('win:42', 1));
  });
});
