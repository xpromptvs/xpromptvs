import { describe, expect, it } from "vitest";
import { attachSimTouch, mouseFingers, SimFingers } from "../src/client/sim-touch";

const P = (x: number, y: number) => ({ x, y });

describe("SimFingers", () => {
  it("is one finger, down to up", () => {
    const f = new SimFingers();
    expect(f.down(1, P(0.2, 0.3))).toEqual([{ t: "sim-touch", phase: "down", points: [P(0.2, 0.3)] }]);
    expect(f.move(1, P(0.25, 0.35))).toEqual([{ t: "sim-touch", phase: "move", points: [P(0.25, 0.35)] }]);
    expect(f.up(1, P(0.25, 0.35))).toEqual([{ t: "sim-touch", phase: "up", points: [P(0.25, 0.35)] }]);
  });

  it("ends the one-finger gesture when a second finger lands, and starts a two-finger one", () => {
    const f = new SimFingers();
    f.down(1, P(0.2, 0.2));
    expect(f.down(2, P(0.8, 0.8))).toEqual([
      { t: "sim-touch", phase: "up", points: [P(0.2, 0.2)] },
      { t: "sim-touch", phase: "down", points: [P(0.2, 0.2), P(0.8, 0.8)] },
    ]);
  });

  /// REVIEW FOCUS 4. Pointer events arrive per finger in any order; a finger keeps its SLOT.
  it("keeps each finger in its slot when the list order flips", () => {
    const f = new SimFingers();
    f.down(5, P(0.1, 0.1)); f.down(3, P(0.9, 0.9));
    expect(f.move(3, P(0.8, 0.8))[0]!.points).toEqual([P(0.1, 0.1), P(0.8, 0.8)]);
    expect(f.move(5, P(0.2, 0.2))[0]!.points).toEqual([P(0.2, 0.2), P(0.8, 0.8)]);
  });

  it("ends the two-finger gesture when one lifts, and the other starts its own", () => {
    const f = new SimFingers();
    f.down(1, P(0.2, 0.2)); f.down(2, P(0.8, 0.8));
    expect(f.up(1, P(0.3, 0.3))).toEqual([
      { t: "sim-touch", phase: "up", points: [P(0.3, 0.3), P(0.8, 0.8)] },
      { t: "sim-touch", phase: "down", points: [P(0.8, 0.8)] },
    ]);
  });

  it("ignores a third finger and a finger it never saw", () => {
    const f = new SimFingers();
    f.down(1, P(0.2, 0.2)); f.down(2, P(0.8, 0.8));
    expect(f.down(3, P(0.5, 0.5))).toEqual([]);
    expect(f.move(3, P(0.5, 0.5))).toEqual([]);
    expect(f.up(3, P(0.5, 0.5))).toEqual([]);
  });

  it("clamps onto the picture and cancels what is down", () => {
    const f = new SimFingers();
    expect(f.down(1, P(-0.2, 1.4))[0]!.points).toEqual([P(0, 1)]);
    expect(f.cancel()).toEqual([{ t: "sim-touch", phase: "up", points: [P(0, 1)] }]);
    expect(f.cancel()).toEqual([]);
  });
});

describe("mouseFingers", () => {
  it("is one finger without ⌥", () => {
    expect(mouseFingers(P(0.3, 0.4), P(0.3, 0.4), false, false)).toEqual([P(0.3, 0.4)]);
  });
  it("pinches about the centre with ⌥", () => {
    const [a, b] = mouseFingers(P(0.3, 0.4), P(0.4, 0.4), true, false);
    expect(a).toEqual(P(0.3, 0.4));
    expect(b!.x).toBeCloseTo(0.7); expect(b!.y).toBeCloseTo(0.6);
  });
  it("pans two fingers together with ⌥⇧", () => {
    const [a, b] = mouseFingers(P(0.35, 0.45), P(0.3, 0.4), true, true);
    expect(a).toEqual(P(0.35, 0.45));
    expect(b!.x).toBeCloseTo(0.75); expect(b!.y).toBeCloseTo(0.65);   // the mirror of the press, moved by +0.05
  });
});

describe("attachSimTouch", () => {
  /// FINAL REVIEW I8. The browser's context menu is suppressed over the PICTURE (AGENTS.md), never gated on focus: a
  /// desktop right-click showed Chrome's video menu, and an Android long press — a `contextmenu` — cancelled the
  /// simulator's own long press.
  it("suppresses the browser's context menu over the picture, focused or not", () => {
    const surface = document.createElement("div");
    document.body.append(surface);
    attachSimTouch(surface, { send: () => {} } as never, {
      isActive: () => false, contentRect: () => ({ left: 0, top: 0, width: 100, height: 100 }),
    });
    const e = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
    surface.dispatchEvent(e);
    expect(e.defaultPrevented).toBe(true);
    surface.remove();
  });
});
