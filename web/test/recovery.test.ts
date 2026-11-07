import { describe, it, expect } from "vitest";
import { recoveryStep, connectionStateEffect, channelLoss, channelsUnopened } from "../src/lib/recovery";

describe("recoveryStep", () => {
  it("brief disconnect goes wobbly and self-heals on reconnect", () => {
    const a = recoveryStep("live", "pcDisconnected", true);
    expect(a.state).toBe("wobbly");
    expect(a.timers.debounce).toBe("start");
    expect(a.timers.grace).toBe("start");
    const b = recoveryStep("wobbly", "pcConnected", true);
    expect(b.state).toBe("live");
    expect(b.timers.debounce).toBe("clear");
    expect(b.timers.grace).toBe("clear");
  });
  it("debounce timeout with a live PC attempts an ICE resume", () => {
    const a = recoveryStep("wobbly", "debounceTimeout", true);
    expect(a.state).toBe("restarting");
    expect(a.attemptResume).toBe("ice");
    expect(a.timers.restart).toBe("start");
    // Grace was already started on live→wobbly; it must NOT restart here (grace spans from the first
    // disconnect, not the debounce boundary).
    expect(a.timers.grace).toBeUndefined();
  });
  it("debounce timeout without a PC rebuilds", () => {
    const a = recoveryStep("wobbly", "debounceTimeout", false);
    expect(a.state).toBe("rebuilding");
    expect(a.attemptResume).toBe("rebuild");
  });
  it("failed skips debounce", () => {
    const a = recoveryStep("live", "pcFailed", true);
    expect(a.state).toBe("restarting");
    expect(a.attemptResume).toBe("ice");
  });
  it("restart timeout escalates to rebuild", () => {
    const a = recoveryStep("restarting", "restartTimeout", true);
    expect(a.state).toBe("rebuilding");
    expect(a.attemptResume).toBe("rebuild");
  });
  it("connected while restarting returns to live", () => {
    expect(recoveryStep("restarting", "pcConnected", true).state).toBe("live");
  });
  it("grace timeout kills from any recovering state", () => {
    expect(recoveryStep("rebuilding", "graceTimeout", true).state).toBe("dead");
    expect(recoveryStep("restarting", "graceTimeout", true).state).toBe("dead");
  });

  // ---- Coverage for the branches the brief's verbatim tests left untested ----

  it("live+pcFailed without a PC rebuilds immediately (skips debounce)", () => {
    expect(recoveryStep("live", "pcFailed", false)).toEqual({
      state: "rebuilding",
      attemptResume: "rebuild",
      timers: { grace: "start", retry: "start" },
    });
  });
  it("live+pcFailed with a PC omits the debounce timer key entirely", () => {
    const fx = recoveryStep("live", "pcFailed", true);
    expect(fx).toEqual({
      state: "restarting",
      attemptResume: "ice",
      timers: { restart: "start", grace: "start" },
    });
    // Explicitly: no spurious `debounce: undefined` key.
    expect(Object.keys(fx.timers).sort()).toEqual(["grace", "restart"]);
  });
  it("wobbly+pcFailed behaves exactly like wobbly+debounceTimeout", () => {
    const viaFailed = recoveryStep("wobbly", "pcFailed", true);
    const viaTimeout = recoveryStep("wobbly", "debounceTimeout", true);
    expect(viaFailed).toEqual(viaTimeout);
    // Coming from wobbly, grace is ALREADY running (started on live→wobbly) → no `grace` key here; the
    // clock spans from the first disconnect, it does not restart at the debounce boundary.
    expect(viaFailed).toEqual({
      state: "restarting",
      attemptResume: "ice",
      timers: { debounce: "clear", restart: "start" },
    });
  });
  it("rebuilding+pcConnected returns to live, clearing grace and retry", () => {
    expect(recoveryStep("rebuilding", "pcConnected", true)).toEqual({
      state: "live",
      timers: { grace: "clear", retry: "clear" },
    });
  });
  it("dead+pcConnected recovers to live, clearing retry", () => {
    expect(recoveryStep("dead", "pcConnected", true)).toEqual({
      state: "live",
      timers: { retry: "clear" },
    });
  });
  it("an unhandled (state,event) pair is a no-op with no spurious timer ops", () => {
    expect(recoveryStep("live", "restartTimeout", true)).toEqual({
      state: "live",
      timers: {},
    });
  });

  it("graceTimeout from a recovering state clears ALL timers", () => {
    expect(recoveryStep("restarting", "graceTimeout", true)).toEqual({
      state: "dead",
      timers: { debounce: "clear", restart: "clear", grace: "clear", retry: "start" },
    });
    expect(recoveryStep("rebuilding", "graceTimeout", false)).toEqual({
      state: "dead",
      timers: { debounce: "clear", restart: "clear", grace: "clear", retry: "start" },
    });
  });
  it("restarting+pcConnected clears restart+grace (full timer object)", () => {
    expect(recoveryStep("restarting", "pcConnected", true)).toEqual({
      state: "live",
      timers: { restart: "clear", grace: "clear" },
    });
  });
  it("restarting+restartTimeout clears restart and does NOT touch grace", () => {
    const fx = recoveryStep("restarting", "restartTimeout", true);
    expect(fx).toEqual({
      state: "rebuilding",
      attemptResume: "rebuild",
      timers: { restart: "clear", retry: "start" },
    });
    expect(fx.timers.grace).toBeUndefined();
  });
});

// The host rebuilding its peer sends a FRESH offer, and the client rebuilds to match — a recovery that
// is already under way, which the old pc's timers must not second-guess with a recycled socket.
describe("pcReplaced", () => {
  it("a wobble is superseded: debounce cleared, grace kept, and the retry armed", () => {
    expect(recoveryStep("wobbly", "pcReplaced", true)).toEqual({
      state: "rebuilding", timers: { debounce: "clear", retry: "start" },
    });
  });
  it("an ICE restart is superseded the same way", () => {
    expect(recoveryStep("restarting", "pcReplaced", true)).toEqual({
      state: "rebuilding", timers: { restart: "clear", retry: "start" },
    });
  });
  it("attempts NOTHING itself — the rebuild has already happened", () => {
    for (const state of ["live", "wobbly", "restarting", "rebuilding", "dead"] as const) {
      expect(recoveryStep(state, "pcReplaced", true).attemptResume).toBeUndefined();
    }
  });
  it("is a no-op when nothing was recovering, or a rebuild already is", () => {
    for (const state of ["live", "rebuilding", "dead"] as const) {
      expect(recoveryStep(state, "pcReplaced", true)).toEqual({ state, timers: {} });
    }
  });
});

// A rebuild's offer can be lost, and nothing else would ever ask again: waiting in `rebuilding` or
// `dead` for a `pcConnected` that cannot come is the "reconnecting…" forever this replaced.
describe("recovery never gives up", () => {
  it("every way into rebuilding arms a retry", () => {
    expect(recoveryStep("wobbly", "debounceTimeout", false).timers.retry).toBe("start");
    expect(recoveryStep("live", "pcFailed", false).timers.retry).toBe("start");
    expect(recoveryStep("restarting", "restartTimeout", true).timers.retry).toBe("start");
  });
  it("a retry rebuilds again and re-arms, in rebuilding AND in dead", () => {
    for (const state of ["rebuilding", "dead"] as const) {
      expect(recoveryStep(state, "retryTimeout", true)).toEqual({
        state, attemptResume: "rebuild", timers: { retry: "start" },
      });
    }
  });
  it("the grace window running out does not stop the retries", () => {
    expect(recoveryStep("restarting", "graceTimeout", true).timers.retry).toBe("start");
  });
  it("a stale retry outside recovery is a no-op", () => {
    for (const state of ["live", "wobbly", "restarting"] as const) {
      expect(recoveryStep(state, "retryTimeout", true)).toEqual({ state, timers: {} });
    }
  });
});

// The Mac shares again in another room and the connection follows it there (`host-follow.ts`): a rebuild into
// that room from EVERY state, the old room's timers cleared and the grace clock started again.
describe("moved", () => {
  const states = ["live", "wobbly", "restarting", "rebuilding", "dead"] as const;
  for (const state of states) {
    it(`from ${state} is a rebuild into the new room`, () => {
      for (const hasPc of [true, false]) {
        expect(recoveryStep(state, "moved", hasPc)).toEqual({
          state: "rebuilding", attemptResume: "rebuild",
          timers: { debounce: "clear", restart: "clear", grace: "start", retry: "start" },
        });
      }
    });
  }
});

describe("connectionStateEffect", () => {
  it("reports connected and feeds the recovery machine", () => {
    expect(connectionStateEffect("connected"))
      .toEqual({ status: { state: "connected", text: "connected" }, event: "pcConnected" });
  });

  it("shows we are trying while negotiating", () => {
    expect(connectionStateEffect("connecting"))
      .toEqual({ status: { state: "connecting", text: "connecting…" }, event: null });
  });

  it("leaves the text to the recovery machine for disconnected/failed", () => {
    expect(connectionStateEffect("disconnected")).toEqual({ status: null, event: "pcDisconnected" });
    expect(connectionStateEffect("failed")).toEqual({ status: null, event: "pcFailed" });
  });

  // Defensive: browsers do NOT fire connectionstatechange for close(), so this branch does not fire in
  // practice — but the fallthrough it replaces would have left the bar claiming "connected" on a dead pc.
  // The real observed defect was the control channel closing; see onControlClose in main.ts.
  it("NEVER leaves a closed connection claiming to be connected, and drives recovery", () => {
    const fx = connectionStateEffect("closed");
    expect(fx.status?.state).toBe("error");
    expect(fx.status?.text).not.toContain("connected");
    expect(fx.event).toBe("pcFailed");
  });

  it("is silent for the initial `new` state", () => {
    expect(connectionStateEffect("new")).toEqual({ status: null, event: null });
  });
});

// A DATA CHANNEL THAT DIED IS A DEAD CONNECTION, WHENEVER IT DIED (docs/sources-and-focus.md, "Recovery never gives
// up and never just waits"). The pc reading "connected" says nothing about rdev's three channels: one that closed
// while the pc was down — ignored then, recovery's to judge — came back from an ICE restart (which keeps the pc and
// cannot reopen a channel) still closed, the footer reading "connected" over a terminal that never updated again.
describe("channelLoss", () => {
  const ch = (control: string, terminal: string, input: string, bulk = "open") =>
    ({ control: { readyState: control }, terminal: { readyState: terminal }, input: { readyState: input },
       bulk: { readyState: bulk } });
  it("names bulk when IT closed: paste and the image viewer ride it, so its loss is the connection's", () => {
    expect(channelLoss("connected", ch("open", "open", "open", "closed"))).toBe("bulk");
  });
  it("is nothing while every channel is open", () => {
    expect(channelLoss("connected", ch("open", "open", "open"))).toBeNull();
  });
  it("names ANY of the three that closed or is closing — not only control", () => {
    expect(channelLoss("connected", ch("closed", "open", "open"))).toBe("control");
    expect(channelLoss("connected", ch("open", "closed", "open"))).toBe("terminal");
    expect(channelLoss("connected", ch("open", "open", "closing"))).toBe("input");
  });
  it("leaves a loss while the pc is down to recovery, and names it once the pc is back", () => {
    const dead = ch("open", "closed", "open");
    for (const s of ["disconnected", "failed", "connecting", "new", "closed"] as RTCPeerConnectionState[]) {
      expect(channelLoss(s, dead)).toBeNull();
    }
    expect(channelLoss("connected", dead)).toBe("terminal");
  });
  it("is nothing for a fresh pc's channels that have not opened yet", () => {
    expect(channelLoss("connected", ch("connecting", "connecting", "connecting"))).toBeNull();
  });
});

// A CONNECTED PC WHOSE CHANNELS NEVER OPEN IS NOT A CONNECTION (review finding 4, 2026-10-11). The host's SCTP gives
// up its INIT after ~24 s since the 3 s RTO cap (pion: 8 retransmits), so an outage starting right after DTLS left a
// pc reading "connected" with no channel ever arriving — and nothing watched for that.
describe("channelsUnopened", () => {
  const ch = (control: string, terminal: string, input: string, bulk = "open") =>
    ({ control: { readyState: control }, terminal: { readyState: terminal }, input: { readyState: input },
       bulk: { readyState: bulk } });
  it("is true while bulk is still connecting", () => {
    expect(channelsUnopened("connected", ch("open", "open", "open", "connecting"))).toBe(true);
  });
  it("is true for a connected pc whose channels never arrived", () => {
    expect(channelsUnopened("connected", undefined)).toBe(true);
  });
  it("is true while any of the three is still connecting, false once all are open", () => {
    expect(channelsUnopened("connected", ch("open", "connecting", "open"))).toBe(true);
    expect(channelsUnopened("connected", ch("open", "open", "open"))).toBe(false);
  });
  it("leaves a channel that opened and closed to channelLoss — the two nets are disjoint", () => {
    expect(channelsUnopened("connected", ch("open", "closed", "open"))).toBe(false);
    expect(channelsUnopened("connected", ch("closing", "open", "open"))).toBe(false);
  });
  it("is false while the pc is not connected — recovery owns that", () => {
    for (const s of ["new", "connecting", "disconnected", "failed", "closed"] as RTCPeerConnectionState[]) {
      expect(channelsUnopened(s, undefined)).toBe(false);
    }
  });
});
