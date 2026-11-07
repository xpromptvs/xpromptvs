import { describe, expect, it, vi } from "vitest";
import { createSessionController, splitConnectSearch,
         type ControllerDeps, type ControllerMotion } from "../src/client/session-lifecycle";
import type { Session, SessionHost, SessionOptions } from "../src/client/session";
import type { SessionDom } from "../src/client/session-dom";
import type { Transport } from "../src/client/connection";

type FakeSession = Session & { disposeCalls: number; leaveCalls: number };
interface Made { opts: SessionOptions; host: SessionHost; session: FakeSession }

function harness(over: Partial<ControllerDeps> = {}) {
  document.body.innerHTML = `<div id="session"></div>`
    + `<div id="welcome" class="welcome-overlay"><button id="row" class="device-card is-connecting"></button></div>`;
  const made: Made[] = [];
  const events: string[] = [];
  const dom = {
    mounts: 0, unmounts: 0, mounted: false,
    mount() { this.mounts++; this.mounted = true; events.push("mount"); },
    unmount() { this.unmounts++; this.mounted = false; events.push("unmount"); },
  };
  let closeDone: (() => void) | undefined;
  const motion = {
    finishes: 0, unlit: [] as HTMLElement[],
    prepareSession() { events.push("prepare"); },
    close(done: () => void) { events.push("slide"); closeDone = done; },
    finish() { this.finishes++; },
    unlight(row: HTMLElement) { this.unlit.push(row); },
  };
  let throwNext = false;
  const create = (opts: SessionOptions, host: SessionHost): Session => {
    events.push("create");
    if (throwNext) { throwNext = false; throw new Error("WebRTC is disabled"); }
    const session: FakeSession = {
      debug: { role: "client" } as unknown as Session["debug"],
      disposeCalls: 0, leaveCalls: 0,
      navState: () => ({}) as ReturnType<Session["navState"]>,
      leave() { this.leaveCalls++; },
      dispose() { this.disposeCalls++; events.push("dispose"); },
      get disposed() { return this.disposeCalls > 0; },
    };
    made.push({ opts, host, session });
    return session;
  };
  const states: unknown[] = [];
  const onState = (e: Event) => states.push((e as CustomEvent).detail);
  document.addEventListener("shellstorm:connection-state", onState);
  const controller = createSessionController({
    pageParams: () => new URLSearchParams("layout=glasses"),
    layout: () => "glasses",
    dom: dom as unknown as SessionDom,
    sessionRoot: document.getElementById("session")!,
    welcome: document.getElementById("welcome"),
    create,
    motion: () => motion as ControllerMotion,
    parsePsk: async (carrier) => (carrier === "SEED" ? new Uint8Array([7]) : null),
    ...over,
  });
  const finishSlide = () => { const done = closeDone; closeDone = undefined; done?.(); };
  const cleanup = () => { controller.dispose(); document.removeEventListener("shellstorm:connection-state", onState); };
  return { controller, made, events, dom, motion, states, finishSlide, cleanup,
           throwNext: () => { throwNext = true; } };
}

const persisted = (type: string): Event => Object.assign(new Event(type), { persisted: true });

describe("splitConnectSearch", () => {
  it("splits the FRAGMENT off first — `?code=c&token=t#pair=S` is token t and carrier S", () => {
    expect(splitConnectSearch("?code=c&token=t#pair=S")).toEqual({ code: "c", token: "t", carrier: "S" });
  });
  it("no fragment, no carrier", () => {
    expect(splitConnectSearch("?code=c&token=t")).toEqual({ code: "c", token: "t", carrier: null });
  });
  it("decodes percent-encoding in each half", () => {
    expect(splitConnectSearch("?code=a%2Bb&token=t%23x#pair=S%2D1"))
      .toEqual({ code: "a+b", token: "t#x", carrier: "S-1" });
  });
  it("refuses a string missing either half", () => {
    expect(splitConnectSearch("?code=c")).toBeNull();
    expect(splitConnectSearch("?token=t#pair=S")).toBeNull();
    expect(splitConnectSearch("")).toBeNull();
  });
});

describe("createSessionController", () => {
  it("uses an explicit page transport without opening a relay connection", () => {
    const transport = { connect: vi.fn() } as unknown as Transport;
    const factory = vi.fn(() => transport);
    const h = harness({ transport: factory });
    try {
      expect(h.controller.connect("?code=demo&token=mock")).toBe(true);
      expect(factory).toHaveBeenCalledWith("demo");
      expect(h.made[0]!.opts.transport).toBe(transport);
    } finally { h.cleanup(); }
  });
  it("THE PAIRING-FRAGMENT REGRESSION: the session gets token t and the psk, never `t#pair=…`", async () => {
    const h = harness();
    try {
      expect(h.controller.connect("?code=c&token=t#pair=SEED")).toBe(true);
      const { opts } = h.made[0]!;
      expect(opts.code).toBe("c");
      expect(opts.token).toBe("t");
      expect(opts.params.get("token")).toBe("t");
      expect(opts.params.get("layout")).toBe("glasses");   // the page's own options travel along
      expect(await opts.psk).toEqual(new Uint8Array([7]));
      expect(Object.keys(opts).sort()).toEqual(["code", "generation", "layout", "params", "psk", "token"]);
    } finally { h.cleanup(); }
  });

  it("connect mounts the DOM, prepares the reveal, THEN creates the session — network init is not gated", () => {
    const h = harness();
    try {
      h.controller.connect("?code=c&token=t");
      expect(h.events).toEqual(["mount", "prepare", "create"]);
    } finally { h.cleanup(); }
  });

  it("repeated connect/disconnect cycles each dispose their session and unmount their DOM", () => {
    const h = harness();
    try {
      for (let i = 0; i < 3; i++) {
        expect(h.controller.connect("?code=c&token=t")).toBe(true);
        h.made[i]!.host.requestClose();
        h.finishSlide();
      }
      expect(h.made).toHaveLength(3);
      expect(h.made.every((m) => m.session.disposeCalls === 1)).toBe(true);
      expect([h.dom.mounts, h.dom.unmounts]).toEqual([3, 3]);
    } finally { h.cleanup(); }
  });

  it("DISCONNECT disposes the engine SYNCHRONOUSLY; the DOM goes only in the motion callback", () => {
    const h = harness();
    try {
      h.controller.connect("?code=c&token=t");
      h.events.length = 0;
      h.made[0]!.host.requestClose();
      expect(h.events).toEqual(["dispose", "slide"]);
      expect(h.dom.mounted).toBe(true);
      expect(h.controller.busy()).toBe(true);
      expect(h.controller.current).toBeUndefined();
      h.finishSlide();
      expect(h.events).toEqual(["dispose", "slide", "unmount"]);
      expect(h.motion.unlit).toEqual([document.getElementById("row")]);
      expect(h.controller.busy()).toBe(false);
    } finally { h.cleanup(); }
  });

  it("a connect while a session is pending, or while one is closing, is ignored", () => {
    const h = harness();
    try {
      h.controller.connect("?code=c&token=t");
      expect(h.controller.connect("?code=d&token=u")).toBe(false);
      h.made[0]!.host.requestClose();
      expect(h.controller.connect("?code=d&token=u")).toBe(false);
      expect(h.made).toHaveLength(1);
      h.finishSlide();
      expect(h.controller.connect("?code=d&token=u")).toBe(true);
    } finally { h.cleanup(); }
  });

  it("CANCEL while pending disposes and unmounts at once — no slide, no unlight", () => {
    const h = harness();
    try {
      h.controller.connect("?code=c&token=t");
      h.controller.cancel();
      expect(h.made[0]!.session.disposeCalls).toBe(1);
      expect(h.events.slice(-2)).toEqual(["dispose", "unmount"]);
      expect(h.events).not.toContain("slide");
      expect(h.motion.unlit).toEqual([]);
      expect(h.controller.current).toBeUndefined();
      expect(h.controller.busy()).toBe(false);
    } finally { h.cleanup(); }
  });

  it("a STALE session's state never reaches the dashboard; the current one's does", () => {
    const h = harness();
    try {
      h.controller.connect("?code=a&token=t");
      const a = h.made[0]!;
      h.controller.cancel();
      h.controller.connect("?code=b&token=t");
      const b = h.made[1]!;
      a.host.state({ state: "error", text: "late from a" });
      b.host.state({ state: "connecting", text: "from b" });
      expect(h.states).toEqual([{ state: "connecting", text: "from b" }]);
      a.host.requestClose();                         // a stale Disconnect closes nothing
      expect(b.session.disposeCalls).toBe(0);
    } finally { h.cleanup(); }
  });

  it("nothing is forwarded while closing, nor after", () => {
    const h = harness();
    try {
      h.controller.connect("?code=c&token=t");
      const s = h.made[0]!;
      s.host.requestClose();
      s.host.state({ state: "error", text: "while closing" });
      h.finishSlide();
      s.host.state({ state: "error", text: "after" });
      expect(h.states).toEqual([]);
    } finally { h.cleanup(); }
  });

  it("__rdev is a getter onto the CURRENT session only", () => {
    const h = harness();
    try {
      const rdev = () => (window as { __rdev?: unknown }).__rdev;
      expect(rdev()).toBeUndefined();
      h.controller.connect("?code=c&token=t");
      expect(rdev()).toBe(h.made[0]!.session.debug);
      h.controller.cancel();
      expect(rdev()).toBeUndefined();
    } finally { h.cleanup(); }
  });

  it("explicit reconnect restarts only the current session in place", () => {
    const h = harness();
    try {
      h.controller.connect("?code=c&token=t#pair=SEED");
      const first = h.made[0]!;
      first.host.requestReconnect?.();
      expect(first.session.disposeCalls).toBe(1);
      expect(h.made).toHaveLength(2);
      expect(h.made[1]!.opts.code).toBe("c");
      expect(h.made[1]!.opts.psk).toBe(first.opts.psk);
      first.host.requestReconnect?.();
      expect(h.made).toHaveLength(2);
    } finally { h.cleanup(); }
  });

  it("pagehide says goodbye; a bfcache pageshow restarts the session IN PLACE with the same pairing", async () => {
    const h = harness();
    try {
      h.controller.connect("?code=c&token=t#pair=SEED");
      const first = h.made[0]!;
      window.dispatchEvent(persisted("pagehide"));
      expect(first.session.leaveCalls).toBe(1);
      window.dispatchEvent(persisted("pageshow"));
      expect(first.session.disposeCalls).toBe(1);
      expect(h.made).toHaveLength(2);
      const again = h.made[1]!;
      expect([again.opts.code, again.opts.token]).toEqual(["c", "t"]);
      expect(again.opts.psk).toBe(first.opts.psk);
      expect(await again.opts.psk).toEqual(new Uint8Array([7]));
      expect(again.opts.generation).toBeGreaterThan(first.opts.generation ?? 0);
      expect(h.controller.current).toBe(again.session);
      window.dispatchEvent(new Event("pageshow"));           // not from the cache: nothing
      expect(h.made).toHaveLength(2);
    } finally { h.cleanup(); }
  });

  // A connection that followed its Mac to another room (`host-follow.ts`): the restart starts THERE, without the seed
  // (it was for the room the Mac left), and the page is told so its address can follow; a stale session's word is not.
  it("a session that moved restarts in the room it moved to, with no seed", async () => {
    const moved: unknown[] = [];
    const h = harness({ onMoved: (r) => moved.push(r) });
    try {
      h.controller.connect("?code=c&token=t#pair=SEED");
      const first = h.made[0]!;
      first.host.moved?.({ code: "c2", token: "t2" });
      expect(moved).toEqual([{ code: "c2", token: "t2" }]);
      window.dispatchEvent(persisted("pagehide"));
      window.dispatchEvent(persisted("pageshow"));
      const again = h.made[1]!;
      expect([again.opts.code, again.opts.token]).toEqual(["c2", "t2"]);
      expect([again.opts.params.get("code"), again.opts.params.get("token")]).toEqual(["c2", "t2"]);
      expect(again.opts.params.get("layout")).toBe("glasses");
      expect(await again.opts.psk).toBeNull();
      first.host.moved?.({ code: "stale", token: "x" });     // the restarted-away session moves nothing
      expect(moved).toHaveLength(1);
      window.dispatchEvent(persisted("pagehide"));
      window.dispatchEvent(persisted("pageshow"));
      expect(h.made[2]!.opts.code).toBe("c2");
    } finally { h.cleanup(); }
  });

  it("the settle listener finishes the slide on input, and only while the slide runs", () => {
    const h = harness();
    try {
      const root = document.getElementById("session")!;
      window.dispatchEvent(new Event("pointerdown"));
      expect(h.motion.finishes).toBe(0);
      root.classList.add("ss-session-moving");
      window.dispatchEvent(new Event("pointerdown"));
      window.dispatchEvent(new KeyboardEvent("keydown"));
      window.dispatchEvent(new Event("wheel"));
      expect(h.motion.finishes).toBe(3);
    } finally { h.cleanup(); }
  });

  it("onDisconnect runs before the slide, onClosed after the DOM is gone", () => {
    const order: string[] = [];
    const h = harness({ onDisconnect: () => order.push("disconnect"), onClosed: () => order.push("closed") });
    try {
      h.controller.connect("?code=c&token=t");
      h.made[0]!.host.requestClose();
      expect(order).toEqual(["disconnect"]);
      expect(h.dom.unmounts).toBe(0);
      h.finishSlide();
      expect(order).toEqual(["disconnect", "closed"]);
      expect(h.dom.unmounts).toBe(1);
    } finally { h.cleanup(); }
  });

  it("with no motion runtime Disconnect shows the dashboard and unmounts at once", () => {
    const h = harness({ motion: () => undefined });
    try {
      const welcome = document.getElementById("welcome")!;
      welcome.classList.add("hidden");
      h.controller.connect("?code=c&token=t");
      h.made[0]!.host.requestClose();
      expect(welcome.classList.contains("hidden")).toBe(false);
      expect(h.dom.unmounts).toBe(1);
      expect(h.controller.busy()).toBe(false);
    } finally { h.cleanup(); }
  });

  // RULING (T5): the fence is the GENERATION alone. `close()` advances it in the same tick it sets
  // `closing`, so a `|| closing` term could never be the thing that drops a report; this pins what is.
  it("THE FENCE IS THE GENERATION: a report from an earlier generation is dropped even with nothing closing", () => {
    const h = harness();
    try {
      h.controller.connect("?code=c&token=t#pair=SEED");
      const first = h.made[0]!;
      window.dispatchEvent(persisted("pagehide"));
      window.dispatchEvent(persisted("pageshow"));   // restarts in place: generation advances, never closing
      const again = h.made[1]!;
      first.host.state({ state: "error", text: "from the restarted-away session" });
      first.host.requestClose();
      again.host.state({ state: "connecting", text: "current" });
      expect(h.states).toEqual([{ state: "connecting", text: "current" }]);
      expect(again.session.disposeCalls).toBe(0);
      expect(h.controller.busy()).toBe(true);
    } finally { h.cleanup(); }
  });

  // FIX ROUND 1 (I-1): a create that throws is a FAILED CONNECT, said like every other one — the
  // controller logs it, tells the dashboard directly (the session never got a host to say it with),
  // leaves no DOM and no pin, and answers false so welcome takes its button out of the busy state.
  it("a create that THROWS is a failed connect: said to the dashboard, nothing mounted or pinned, false", () => {
    let fail = true;
    document.body.innerHTML = `<div id="session"></div><div id="welcome"></div>`;
    const events: string[] = [];
    const states: unknown[] = [];
    const onState = (e: Event) => states.push((e as CustomEvent).detail);
    document.addEventListener("shellstorm:connection-state", onState);
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const dom = { mounted: false,
      mount() { if (this.mounted) throw new Error("already mounted"); this.mounted = true; events.push("mount"); },
      unmount() { this.mounted = false; events.push("unmount"); } };
    const controller = createSessionController({
      pageParams: () => new URLSearchParams(), layout: () => "floating",
      dom: dom as unknown as SessionDom,
      sessionRoot: document.getElementById("session")!, welcome: document.getElementById("welcome"),
      motion: () => undefined,
      pin: () => { events.push("pin"); return () => events.push("unpin"); },
      create: () => {
        if (fail) throw new Error("boom");
        return { debug: {} as Session["debug"], navState: () => ({}) as ReturnType<Session["navState"]>,
                 leave() {}, dispose() {}, disposed: false };
      },
    });
    try {
      expect(controller.connect("?code=c&token=t")).toBe(false);
      expect(states).toEqual([{ state: "error", text: "Could not start the session." }]);
      expect(errors).toHaveBeenCalled();
      expect(dom.mounted).toBe(false);
      expect(events).toEqual(["mount", "pin", "unpin", "unmount"]);
      expect(controller.current).toBeUndefined();
      expect(controller.busy()).toBe(false);
      fail = false;
      expect(controller.connect("?code=c&token=t")).toBe(true);        // a retry works
      expect(events.slice(4)).toEqual(["mount", "pin"]);
    } finally {
      controller.dispose();
      document.removeEventListener("shellstorm:connection-state", onState);
      errors.mockRestore();
    }
  });

  // FIX ROUND 1 (M-2): the spec pins <body> "from create to UNMOUNT". Disconnect disposes the engine
  // at the START of the slide; the pin must hold until the slide has ended, or with the keyboard up
  // the sliding session jumps from the visible band to the layout viewport.
  it("THE BODY PIN is the controller's: taken at mount, held through the slide, released at unmount", () => {
    const pins: string[] = [];
    const h = harness({ pin: () => { pins.push("pin"); return () => pins.push("unpin"); } });
    try {
      h.controller.connect("?code=c&token=t");
      expect(pins).toEqual(["pin"]);
      h.made[0]!.host.requestClose();
      expect(h.made[0]!.session.disposeCalls).toBe(1);               // the engine went at once…
      expect(pins).toEqual(["pin"]);                                  // …the pin did not
      h.finishSlide();
      expect(pins).toEqual(["pin", "unpin"]);
      h.controller.connect("?code=c&token=t");
      h.controller.cancel();                                          // Cancel releases it at once
      expect(pins).toEqual(["pin", "unpin", "pin", "unpin"]);
    } finally { h.cleanup(); }
  });

  // CARRIED (ruling, T5): a session carries the page's options AS THEY ARE AT ITS CONNECT. URL mode
  // strips its query when its session ends, so a dashboard session afterwards carries none of URL
  // mode's parameters — they are read at connect, never captured once at boot.
  it("the page's options are READ AT EACH CONNECT: a later session carries none of an earlier page's", () => {
    let search = "code=url&token=t&probe=1&layout=glasses";
    const h = harness({ pageParams: () => new URLSearchParams(search) });
    try {
      h.controller.connect("?code=url&token=t");
      expect(h.made[0]!.opts.params.get("probe")).toBe("1");
      h.made[0]!.host.requestClose();
      h.finishSlide();
      search = "";                                                   // URL mode stripped its query
      h.controller.connect("?code=c&token=t2");
      const later = h.made[1]!.opts.params;
      expect([...later.keys()].sort()).toEqual(["code", "token"]);
      expect(later.get("token")).toBe("t2");
    } finally { h.cleanup(); }
  });

  // CARRIED (T6): every session's generation is real and increasing — and no two page loads share
  // one, because the glasses' history entries outlive a reload and carry it (`glasses-history.ts`).
  it("generations increase within a page, and a NEW page (a reload) never reuses an earlier one's", () => {
    const now = vi.spyOn(Date, "now").mockReturnValue(1_000);
    const a = harness();
    const gens: number[] = [];
    try {
      for (let i = 0; i < 3; i++) {
        a.controller.connect("?code=c&token=t");
        gens.push(a.made[i]!.opts.generation!);
        a.controller.cancel();
      }
    } finally { a.cleanup(); }
    now.mockReturnValue(2_000);
    const b = harness();
    try {
      b.controller.connect("?code=c&token=t");
      gens.push(b.made[0]!.opts.generation!);
    } finally { b.cleanup(); now.mockRestore(); }
    expect(gens.every((g) => typeof g === "number" && g > 0)).toBe(true);
    expect(gens.slice(0, 3)).toEqual([...gens.slice(0, 3)].sort((x, y) => x - y));
    expect(new Set(gens).size).toBe(gens.length);
    expect(gens[3]).toBeGreaterThan(gens[2]!);
  });

  // FIX ROUND 1 (O-3): a bfcache restart whose rebuild THROWS has no Connect to report to — the
  // dashboard is hidden once a session is revealed — so the page is TOLD, with the reason, and can
  // land on the dashboard instead of an empty document. A failed CONNECT is not reported this way:
  // welcome is waiting on that one's answer itself.
  it("a bfcache restart that THROWS is reported to the page with its reason; nothing is left busy", () => {
    const failed: string[] = [];
    const h = harness({ onRestartFailed: (reason) => failed.push(reason) });
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      h.controller.connect("?code=c&token=t");
      expect(h.made).toHaveLength(1);
      h.throwNext();                                    // the restart's build throws
      window.dispatchEvent(persisted("pagehide"));
      window.dispatchEvent(persisted("pageshow"));
      expect(failed).toEqual(["Could not start the session."]);
      expect(h.controller.busy()).toBe(false);
      expect(h.controller.current).toBeUndefined();
      expect(h.dom.mounted).toBe(false);
    } finally { h.cleanup(); errors.mockRestore(); }
  });

  it("a failed CONNECT is not a failed restart: onRestartFailed stays silent", () => {
    const failed: string[] = [];
    const h = harness({ onRestartFailed: (reason) => failed.push(reason) });
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      h.throwNext();
      expect(h.controller.connect("?code=c&token=t")).toBe(false);
      expect(failed).toEqual([]);
    } finally { h.cleanup(); errors.mockRestore(); }
  });

  // FIX ROUND 1 (m-2): welcome has already begun the morph by the time a string reaches here, so a
  // refusal must SAY so — the error phase — or the button sits busy with nothing behind it.
  it("a string with no pairing starts nothing, and says so", () => {
    const h = harness();
    try {
      expect(h.controller.connect("?code=c")).toBe(false);
      expect(h.events).toEqual([]);
      expect(h.states).toEqual([{ state: "error", text: "That link has no pairing code." }]);
    } finally { h.cleanup(); }
  });

  it("connectTransport starts a session over the page's own transport, with no pairing", () => {
    const h = harness();
    try {
      const transport = { carriesMedia: false, connect: () => { throw new Error("not in a unit test"); } } as unknown as Transport;
      expect(h.controller.connectTransport(transport)).toBe(true);
      const { opts } = h.made[0]!;
      expect(opts.transport).toBe(transport);
      expect(opts.code).toBe("");
      expect(opts.token).toBe("");
      expect(opts.params.get("layout")).toBe("glasses");
      expect(h.events).toEqual(["mount", "prepare", "create"]);
      expect(h.controller.connectTransport(transport)).toBe(false);   // one session at a time
    } finally { h.cleanup(); }
  });

  it("a bfcache restart of a transport session starts it again over the SAME transport", () => {
    const h = harness();
    try {
      const transport = { carriesMedia: false } as unknown as Transport;
      h.controller.connectTransport(transport);
      window.dispatchEvent(persisted("pagehide"));
      window.dispatchEvent(persisted("pageshow"));
      expect(h.made).toHaveLength(2);
      expect(h.made[1]!.opts.transport).toBe(transport);
    } finally { h.cleanup(); }
  });
});

for (const action of ["dispose", "cancel", "disconnect"] as const) {
  it(`fences a session ${action}d during synchronous construction`, () => {
    const dispose = vi.fn();
    const h = harness({create: () => {
      h.controller[action]();
      return {dispose} as unknown as Session;
    }});
    expect(h.controller.connect("?code=c&token=t")).toBe(false);
    expect(dispose).toHaveBeenCalledTimes(1);
    expect(h.controller.current).toBeUndefined();
    h.cleanup();
  });
}
