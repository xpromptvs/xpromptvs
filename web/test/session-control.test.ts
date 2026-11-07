import { expect, test } from "vitest";
import { CLAIM_INTENT_MS, SessionControl, controlOpenMessages, parseControlState, viewForState } from "../src/client/session-control";
import { decodeJson } from "../src/lib/codec";

test("active state reveals the sim, hides claim, sends a resize", () => {
  expect(viewForState({ active: true, clients: 1 })).toEqual({
    showClaim: false, showSim: true, sendResize: true,
  });
});

test("passive state hides the sim and shows the claim button", () => {
  expect(viewForState({ active: false, clients: 2 })).toEqual({
    showClaim: true, showSim: false, sendResize: false,
  });
});

test("parseControlState narrows a valid message", () => {
  expect(parseControlState({ t: "control-state", active: true, clients: 3 })).toEqual({ active: true, clients: 3 });
  expect(parseControlState({ t: "control-state", active: false, clients: 0 })).toEqual({ active: false, clients: 0 });
});

test("parseControlState rejects other or malformed messages", () => {
  expect(parseControlState({ t: "inputAck", ts: 1 })).toBeNull();
  expect(parseControlState({ t: "control-state", active: "yes" })).toBeNull();
  expect(parseControlState(null)).toBeNull();
});

// THE CONNECT STATES THE CONNECTION, NEVER THE SESSION. The session — windows, terminals, the view — is
// the HOST's state (`view-set`, `term-list`), and a client that replayed its own memory of it would
// fight the host's (docs/superpowers/specs/2026-09-29-host-session-state-design.md). What a connection
// DOES own — its visibility, its playout window, its forced FEC, its terminal palette, its preferences
// — it states on every open, because the host keeps each of them only for that connection.
const VIS = { t: "set-visibility", hidden: false };
const PREFS = { scale: "auto" as const, codec: "auto" as const };
const HELLO = { t: "client-hello", prefs: { scale: "auto", codec: "auto" } };
const open = (over: Partial<Parameters<typeof controlOpenMessages>[0]> = {}) =>
  controlOpenMessages({
    intendedRecoveryBp: null, intendedPlayoutDelayMs: null, intendedPlayoutWindowMs: null,
    delivery: "rtp",
    termPalette: null,
    pageHidden: false,
    prefs: PREFS,
    ...over,
  });

test("control-open asks for the source list first and ends with the hello", () => {
  expect(open()).toEqual([{ t: "list-sources" }, VIS, HELLO]);
});

test("nothing about the session is replayed — no subscribe, no focus, no tmux restore", () => {
  const msgs = open({ intendedRecoveryBp: 500, intendedPlayoutDelayMs: 40, termPalette: null });
  for (const t of ["subscribe", "focus-source", "restore-tmux", "unsubscribe"]) expect(msgs.some((m) => m.t === t)).toBe(false);
});

// THE HELLO IS LAST, and that is the whole ordering rule now: the host starts a driver's video only
// once the hello has arrived, so everything the first frame depends on — the playout window above all —
// must be in before it (docs/engine.md; the window measured 33 ms against 27 when applied late).
test("the hello is the last message, after every per-connection setting", () => {
  const msgs = open({ intendedRecoveryBp: 5000, intendedPlayoutWindowMs: 10, pageHidden: true,
    termPalette: { t: "term-palette", fg: "#e3e1e4", bg: "#2c2b2c", cursor: "#e3e1e4", ansi: Array(16).fill("#000000") } });
  expect(msgs[msgs.length - 1]?.t).toBe("client-hello");
  expect(msgs.filter((m) => m.t === "client-hello")).toHaveLength(1);
});

test("the hello carries the device's preferences as the device chose them", () => {
  const msgs = open({ prefs: { fps: 30, scale: 0.5, bitrateBps: 4_000_000, codec: "av1", pointerMode: "trackpad" } });
  expect(msgs.at(-1)).toEqual({ t: "client-hello",
    prefs: { fps: 30, scale: 0.5, bitrateBps: 4_000_000, codec: "av1", pointerMode: "trackpad" } });
});

// CONTRACT ISSUE 1: the DataChannel instrument (`?dc=1`) asks for its transport per CONNECTION now, so
// a window the host restores comes back on the channel it was asked for.
test("the hello asks for the DataChannel only when this connection wants it", () => {
  expect(open({ delivery: "dc" }).at(-1)).toEqual({ ...HELLO, delivery: "dc" });
  expect(open().at(-1)).not.toHaveProperty("delivery");
});

// A FORCED RECOVERY PERCENTAGE IS PER-CONNECTION HOST STATE, so a peer rebuild drops it: the host
// returns to adaptive, the encoder retargets, and the titlebar honestly follows the host back to Auto.
test("a forced recovery percentage is re-asserted on every open", () => {
  expect(open({ intendedRecoveryBp: 5000 })).toEqual([{ t: "list-sources" }, VIS, { t: "set-recovery", overrideBp: 5000 }, HELLO]);
  expect(open().some((m) => m.t === "set-recovery")).toBe(false);
});

// THE WINDOW GOES FIRST, and it replaces the floor: the two are one setting on the wire.
test("a playout window is asked for straight after the source list, and replaces the floor", () => {
  expect(open({ intendedPlayoutWindowMs: 10, intendedPlayoutDelayMs: 40 })).toEqual([
    { t: "list-sources" }, { t: "set-playout-delay", minMs: 10, maxMs: 10 }, VIS, HELLO,
  ]);
  expect(open({ intendedPlayoutDelayMs: 40 })).toEqual([
    { t: "list-sources" }, VIS, { t: "set-playout-delay", minMs: 40 }, HELLO,
  ]);
});

// THE TERMINAL PALETTE, EVERY TIME: the host answers a tmux tab's colour queries whose bytes reach no
// client as this client's xterm.js would (docs/terminal.md), and keeps a palette only for its connection.
test("the terminal palette is stated on every open, before the hello", () => {
  const termPalette = { t: "term-palette" as const, fg: "#e3e1e4", bg: "#2c2b2c", cursor: "#e3e1e4", ansi: Array(16).fill("#000000") };
  const msgs = open({ termPalette });
  expect(msgs).toContainEqual(termPalette);
  expect(msgs.findIndex((m) => m.t === "term-palette")).toBeLessThan(msgs.findIndex((m) => m.t === "client-hello"));
  expect(open().some((m) => m.t === "term-palette")).toBe(false);
});

// THE MEDIA HALF OF THE LOST RESUME. A `set-visibility` sent from `visibilitychange` can go into a
// control channel that is already dead — the phone case — and the host voids its pause on a rebuild.
test("control-open states the page's visibility, hidden or not, after the window and before the hello", () => {
  for (const pageHidden of [false, true]) {
    const msgs = open({ pageHidden, intendedPlayoutWindowMs: 10 });
    const at = (t: string) => msgs.findIndex((m) => m.t === t);
    expect(msgs.filter((m) => m.t === "set-visibility")).toEqual([{ t: "set-visibility", hidden: pageHidden }]);
    expect(at("set-visibility")).toBeGreaterThan(at("set-playout-delay"));
    expect(at("set-visibility")).toBeLessThan(at("client-hello"));
  }
});

test("becoming active states the page's visibility first — media and terminal — once per transition", () => {
  const log: string[] = [];
  const channel = {
    readyState: "open",
    send: (d: Uint8Array) => {
      const m = decodeJson<{ t: string; hidden?: boolean }>(d);
      log.push(m.hidden === undefined ? m.t : `${m.t}:${m.hidden}`);
    },
  } as unknown as RTCDataChannel;
  let hidden = true;
  const els = { sim: document.createElement("div"), claim: document.createElement("div"), claimButton: document.createElement("button") };
  const sc = new SessionControl(channel, els, () => log.push("activate"), () => log.push("deactivate"), () => hidden);
  sc.apply({ active: true, clients: 2 });
  expect(log).toEqual(["set-visibility:true", "terminal-pause", "activate"]);
  sc.apply({ active: true, clients: 2 });
  expect(log).toHaveLength(3);
  sc.apply({ active: false, clients: 2 });
  hidden = false;
  sc.apply({ active: true, clients: 2 });
  expect(log.slice(3)).toEqual(["deactivate", "set-visibility:false", "terminal-resume", "activate"]);
});

// A WINDOW-LESS client has no media to pause: the host refuses its `set-visibility` (WindowlessPolicy),
// so its activation states the TERMINAL's visibility only. A windowed one is unchanged (the test above).
test("a WINDOW-LESS client becoming active states only the terminal's visibility", () => {
  const log: string[] = [];
  const channel = {
    readyState: "open",
    send: (d: Uint8Array) => {
      const m = decodeJson<{ t: string; hidden?: boolean }>(d);
      log.push(m.hidden === undefined ? m.t : `${m.t}:${m.hidden}`);
    },
  } as unknown as RTCDataChannel;
  let hidden = true;
  const els = { sim: document.createElement("div"), claim: document.createElement("div"), claimButton: document.createElement("button") };
  const sc = new SessionControl(channel, els, () => log.push("activate"), () => log.push("deactivate"), () => hidden,
                                { windowless: true });
  sc.apply({ active: true, clients: 1 });
  expect(log).toEqual(["terminal-pause", "activate"]);
  sc.apply({ active: false, clients: 2 });
  hidden = false;
  sc.apply({ active: true, clients: 2 });
  expect(log.slice(2)).toEqual(["deactivate", "terminal-resume", "activate"]);
  expect(log.some((m) => m.startsWith("set-visibility"))).toBe(false);
});

test("a WINDOW-LESS connection states only what the terminal needs, then the hello", () => {
  const palette = { t: "term-palette" as const, fg: "#ececec", bg: "#000000", cursor: "#ececec", ansi: [] };
  expect(open({ windowless: true, intendedRecoveryBp: 500, intendedPlayoutWindowMs: 10,
                intendedPlayoutDelayMs: 20, termPalette: palette, pageHidden: true }))
    .toEqual([palette, HELLO]);
});

test("both smooth-video choices are restored before video starts on each connection", () => {
  for (const ms of [20, 100]) {
    const msgs = open({ intendedPlayoutDelayMs: ms, intendedPlayoutWindowMs: null });
    expect(msgs.filter(m => m.t === "set-playout-delay")).toEqual([{ t: "set-playout-delay", minMs: ms }]);
    expect(msgs.at(-1)?.t).toBe("client-hello");
  }
});

// A CLAIM SAYS ITS GRID (docs/terminal.md, "A claim says its grid"): measured when the claim is sent, so the host
// snapshots every tab at the claimer's size, not the previous driver's. None measured: the claim says none.
test("the claim carries the grid measured as it is sent, and nothing when none can be measured", () => {
  const sent: unknown[] = [];
  const channel = { readyState: "open", send: (d: Uint8Array) => sent.push(decodeJson(d)) } as unknown as RTCDataChannel;
  const els = { sim: document.createElement("div"), claim: document.createElement("div"), claimButton: document.createElement("button") };
  let grid: { cols: number; rows: number } | null = { cols: 45, rows: 30 };
  let measured = 0;
  new SessionControl(channel, els, () => {}, () => {}, () => false,
                     { claimGrid: () => { measured++; return grid; } });
  els.claimButton.click();
  expect(sent).toEqual([{ t: "claim-control", cols: 45, rows: 30 }]);
  expect(measured, "measured at the claim, not before").toBe(1);
  grid = null;
  els.claimButton.click();
  expect(sent.at(-1)).toEqual({ t: "claim-control" });
});

// MOVE HERE SURVIVES THE CONNECTION (docs/client-web.md): a claim is WANTED until the host says this page drives or
// CLAIM_INTENT_MS passes — said again on a control channel that opens meanwhile, the button saying so meanwhile.
test("a Move here with no answer is said again on the next control channel, until active or expired", () => {
  const sent: string[] = [];
  const channel = { readyState: "closed", send: (d: Uint8Array) => { const t = decodeJson<{ t: string }>(d).t; if (t === "claim-control") sent.push(t); } };
  const btn = document.createElement("button");
  btn.append("Move here", document.createElementNS("http://www.w3.org/2000/svg", "svg"));
  const els = { sim: document.createElement("div"), claim: document.createElement("div"), claimButton: btn };
  let expire: (() => void) | null = null;
  const sc = new SessionControl(channel as unknown as RTCDataChannel, els, () => {}, () => {}, () => false,
                                { timer: (f, ms) => { expect(ms).toBe(CLAIM_INTENT_MS); expire = f; return () => { expire = null; }; } });
  sc.apply({ active: false, clients: 2 });
  btn.click();                                                    // the channel is down: nothing can be sent
  expect(sent).toEqual([]);
  expect([btn.textContent, btn.getAttribute("aria-busy")]).toEqual(["Moving here…", "true"]);
  channel.readyState = "open";
  sc.reclaim();                                                   // a rebuilt channel opened
  expect(sent).toEqual(["claim-control"]);
  sc.apply({ active: false, clients: 2 });                        // a passive state meanwhile changes nothing
  sc.reclaim();
  expect(sent, "still wanted: said on every channel that opens").toEqual(["claim-control", "claim-control"]);
  sc.apply({ active: true, clients: 2 });                         // answered
  expect([btn.textContent, btn.getAttribute("aria-busy"), expire]).toEqual(["Move here", "false", null]);
  sc.reclaim();
  expect(sent).toHaveLength(2);

  sc.apply({ active: false, clients: 2 });
  btn.click();
  expect(sent).toHaveLength(3);
  expire!();                                                      // no answer within CLAIM_INTENT_MS
  expect([btn.textContent, btn.getAttribute("aria-busy")]).toEqual(["Move here", "false"]);
  sc.reclaim();
  expect(sent, "forgotten: a later channel takes no control").toHaveLength(3);
});

test("reference receipt capability is opt-in and the hello stays last", () => {
  expect(open().at(-1)).not.toHaveProperty("av1ReferenceAck");
  expect(open({ av1ReferenceAck: 1 }).at(-1)).toEqual({ ...HELLO, av1ReferenceAck: 1 });
  expect(open({ av1ReferenceAck: 1, windowless: true }).at(-1)).not.toHaveProperty("av1ReferenceAck");
  expect(open({ av1ReferenceAck: 1, delivery: "dc" }).at(-1)).not.toHaveProperty("av1ReferenceAck");
});

test('native media can remain visible while its main terminal is paused', () => {
  const messages: {t:string;hidden?:boolean}[]=[];
  const channel={readyState:'open',send:(data:Uint8Array)=>messages.push(decodeJson(data))} as unknown as RTCDataChannel;
  const els={sim:document.createElement('div'),claim:document.createElement('div'),claimButton:document.createElement('button')};
  const control=new SessionControl(channel,els,()=>{},()=>{},()=>false,{terminalHidden:()=>true});
  control.apply({active:true,clients:1});
  expect(messages).toEqual([{t:'set-visibility',hidden:false},{t:'terminal-pause'}]);
});
