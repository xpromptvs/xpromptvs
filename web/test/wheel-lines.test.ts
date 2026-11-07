import { describe, expect, it } from "vitest";
import { WheelLines, attachWheelLines, lineWheelInit } from "../src/client/wheel-lines";

const sum = (a: number[]) => a.reduce((x, y) => x + y, 0);

describe("WheelLines — trackpad pixels to whole lines", () => {
  it("emits one line per cell height of motion, keeping the sub-line remainder across events", () => {
    const w = new WheelLines();
    // 60 events of 4 px at an 18 px cell: 240 px = 13.33 cells. Stock xterm.js made 240 × 0.3 / 18 = 4.
    const out = Array.from({ length: 60 }, () => w.push(4, 18, 100));
    expect(sum(out)).toBe(13);
    expect(out.every((n) => n === 0 || n === 1)).toBe(true);
  });

  it("does not lose motion to the 50 px line: a big event is SEVERAL lines, not one", () => {
    const w = new WheelLines();
    expect(w.push(120, 18, 100)).toBe(6);   // 6.67 cells; the 0.67 is kept
    expect(w.push(6, 18, 100)).toBe(1);     // 0.67 + 0.33 = 1
  });

  it("carries the sign: up is negative", () => {
    const w = new WheelLines();
    expect(sum([-10, -10, -10, -10].map((d) => w.push(d, 18, 100)))).toBe(-2);
  });

  it("drops the remainder on a reversal, so the new direction answers at once", () => {
    const w = new WheelLines();
    expect(w.push(17, 18, 100)).toBe(0);    // 0.94 pending down
    expect(w.push(-18, 18, 100)).toBe(-1);  // not 0.94 - 1 = -0.06 → 0
  });

  it("caps one event at maxLines (a page), dropping the excess rather than carrying it", () => {
    const w = new WheelLines();
    expect(w.push(10_000, 20, 24)).toBe(24);
    expect(w.push(1, 20, 24)).toBe(0);
  });

  it("emits nothing for a zero delta, an unmeasured cell or a non-finite delta", () => {
    const w = new WheelLines();
    expect(w.push(0, 18, 100)).toBe(0);
    expect(w.push(40, 0, 100)).toBe(0);
    expect(w.push(40, Number.NaN, 100)).toBe(0);
    expect(w.push(Number.POSITIVE_INFINITY, 18, 100)).toBe(0);
  });

  it("reset forgets the remainder", () => {
    const w = new WheelLines();
    w.push(17, 18, 100);
    w.reset();
    expect(w.push(2, 18, 100)).toBe(0);
  });
});

describe("lineWheelInit — the one-line event xterm.js turns into exactly one report", () => {
  it("is a LINE-mode delta of ±1 at the original position, with the modifiers the report encodes", () => {
    const init = lineWheelInit(-1, { clientX: 5, clientY: 7, ctrlKey: true, altKey: false, metaKey: false });
    expect(init).toMatchObject({ deltaY: -1, deltaMode: 1, clientX: 5, clientY: 7, ctrlKey: true, altKey: false, bubbles: true, cancelable: true });
  });
});

describe("attachWheelLines — which wheels are converted", () => {
  type Mode = "none" | "x10" | "vt200" | "drag" | "any";
  /// A fake xterm.js: the handler is consulted from a listener on `el`, as xterm.js's own is, and a
  /// wheel the handler lets through counts as one xterm.js saw.
  function rig(opts: { mode?: Mode; buffer?: "normal" | "alternate"; cell?: number } = {}) {
    let handler: ((ev: WheelEvent) => boolean) | undefined;
    const term = {
      rows: 24,
      modes: { mouseTrackingMode: opts.mode ?? "vt200" },
      buffer: { active: { type: opts.buffer ?? "normal" } },
      attachCustomWheelEventHandler(h: (ev: WheelEvent) => boolean) { handler = h; },
    };
    const parent = document.createElement("div");
    const el = document.createElement("div");
    parent.append(el);
    document.body.append(parent);
    const passed: WheelEvent[] = [];
    let bubbled = 0;
    el.addEventListener("wheel", (e) => { if (handler!(e)) passed.push(e); });
    parent.addEventListener("wheel", () => { bubbled++; });
    attachWheelLines(term, () => opts.cell ?? 18);
    const wheel = (init: WheelEventInit) => {
      const ev = new WheelEvent("wheel", { bubbles: true, cancelable: true, deltaMode: 0, ...init });
      el.dispatchEvent(ev);
      return ev;
    };
    return { passed, wheel, bubbled: () => bubbled };
  }
  const lineEvents = (p: WheelEvent[]) => p.filter((e) => e.deltaMode === 1);

  it.each(["vt200", "drag", "any"] as const)("converts a pixel wheel under the wheel-reporting protocol %s", (mode) => {
    const r = rig({ mode });
    const ev = r.wheel({ deltaY: 40 });
    expect(ev.defaultPrevented).toBe(true);
    expect(lineEvents(r.passed).map((e) => e.deltaY)).toEqual([1, 1]);   // 40 / 18 = 2.2
    expect(r.passed).not.toContain(ev);
  });

  it("converts on the alt screen with no mouse protocol (arrows)", () => {
    const r = rig({ mode: "none", buffer: "alternate" });
    r.wheel({ deltaY: -36 });
    expect(lineEvents(r.passed).map((e) => e.deltaY)).toEqual([-1, -1]);
  });

  it.each(["none", "x10"] as const)("leaves the normal buffer's scrollback to xterm.js under %s", (mode) => {
    const r = rig({ mode, buffer: "normal" });
    const ev = r.wheel({ deltaY: 40 });
    expect(ev.defaultPrevented).toBe(false);
    expect(r.passed).toEqual([ev]);
  });

  it("leaves Shift+wheel, line-mode wheels and horizontal-only wheels to xterm.js", () => {
    const r = rig();
    const shift = r.wheel({ deltaY: 40, shiftKey: true });
    const line = r.wheel({ deltaY: 3, deltaMode: 1 });
    const horiz = r.wheel({ deltaX: 40, deltaY: 0 });
    expect(r.passed).toEqual([shift, line, horiz]);
  });

  it("stops a consumed wheel's propagation, as xterm.js does for a wheel it reports", () => {
    const r = rig({ mode: "none", buffer: "alternate" });
    r.wheel({ deltaY: 40 });
    expect(r.bubbled()).toBe(2);   // the two synthetic lines bubble; the consumed original does not
  });

  it("carries the modifiers the report encodes into each line", () => {
    const r = rig();
    r.wheel({ deltaY: 20, altKey: true, clientX: 11, clientY: 12 });
    expect(lineEvents(r.passed).map((e) => [e.altKey, e.clientX, e.clientY])).toEqual([[true, 11, 12]]);
  });

  it("an unmeasured (hidden) instance consumes the wheel and emits nothing", () => {
    const r = rig({ cell: 0 });
    const ev = r.wheel({ deltaY: 400 });
    expect(ev.defaultPrevented).toBe(true);
    expect(r.passed).toEqual([]);
  });
});
