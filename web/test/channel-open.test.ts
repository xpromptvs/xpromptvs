import { describe, expect, it } from "vitest";
import { whenOpen } from "../src/lib/channel";
import type { ChannelLike } from "../src/lib/channel";

// A CHANNEL CAN BE OPEN WHEN IT IS HANDED OVER: on the SCTP baseline `bulk` comes last, so `control` has opened before
// the set completes; a lane's streams read open at the hand-over. What starts the protocol runs ONCE per channel —
// at once if it is open, else at its `open`.
class FakeChannel extends EventTarget {
  binaryType: BinaryType = "arraybuffer";
  constructor(readonly label: string, public readyState: RTCDataChannelState) { super(); }
  send(): void {}
  open(): void { this.readyState = "open"; this.dispatchEvent(new Event("open")); }
}
const channel = (state: RTCDataChannelState) => new FakeChannel("control", state) as unknown as ChannelLike & FakeChannel;

describe("whenOpen", () => {
  it("runs at once for a channel already open, and its later open runs nothing", () => {
    const ch = channel("open");
    let runs = 0;
    whenOpen(ch, () => { runs++; });
    expect(runs).toBe(1);
    ch.dispatchEvent(new Event("open"));
    expect(runs).toBe(1);
  });

  it("runs at the open of a channel still connecting — once, however often it says so", () => {
    const ch = channel("connecting");
    let runs = 0;
    whenOpen(ch, () => { runs++; });
    expect(runs).toBe(0);
    ch.open();
    ch.dispatchEvent(new Event("open"));
    expect(runs).toBe(1);
  });

  it("two bindings on one channel each run, in the order they were bound", () => {
    for (const state of ["open", "connecting"] as const) {
      const ch = channel(state);
      const order: string[] = [];
      whenOpen(ch, () => order.push("join intent"));
      whenOpen(ch, () => order.push("control-open batch"));
      if (state === "connecting") ch.open();
      expect(order, state).toEqual(["join intent", "control-open batch"]);
    }
  });

  // A LISTENER THAT THROWS AT ONCE ABORTS NOTHING BOUND AFTER IT: the session binds its control-open batch, then `bulk`'s
  // dispatch and the terminal — inline, a throw from the first left a terminal channel nobody listened to, where an
  // `open` listener's throw is isolated by the event dispatch. It is reported, as the browser reports a listener's.
  it("a listener that throws at once aborts nothing bound after it, and is reported", () => {
    const g = globalThis as { reportError?: (e: unknown) => void };
    const saved = g.reportError;
    const reported: unknown[] = [];
    g.reportError = (e) => reported.push(e);
    try {
      const ch = channel("open");
      const order: string[] = [];
      const bind = () => {
        whenOpen(ch, () => { throw new Error("the control-open batch threw"); });
        whenOpen(ch, () => order.push("bound after it"));
      };
      expect(bind, "a throwing listener must not abort its caller").not.toThrow();
      expect(order).toEqual(["bound after it"]);
      expect(reported.map((e) => (e as Error).message)).toEqual(["the control-open batch threw"]);
    } finally {
      g.reportError = saved;
    }
  });

  it("a channel that closes without opening runs nothing", () => {
    const ch = channel("connecting");
    let runs = 0;
    whenOpen(ch, () => { runs++; });
    ch.readyState = "closed";
    ch.dispatchEvent(new Event("close"));
    expect(runs).toBe(0);
  });
});
