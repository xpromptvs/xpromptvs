import { describe, it, expect } from "vitest";
import { containedRect, videoContentRect } from "../src/client/pointer-map";
import {
  FALLBACK_MAX_ZOOM, FIT_VIEW, anchoredZoom, clampView, maxZoom, transformFor, videoViewRect, zoomedRect,
} from "../src/client/view-zoom";

// The case `docs/client-web.md` measured: a 420x646 body showing 16:9 paints 420x236 with 205px bars.
const BOX = { w: 420, h: 646 };
const NATURAL = { w: 16, h: 9 };
const FIT = containedRect(BOX, NATURAL);   // { x: 0, y: 204.875, w: 420, h: 236.25 }

describe("zoomedRect", () => {
  it("is EXACTLY containedRect at z = 1, whatever the offsets say", () => {
    // THE PROPERTY THE WHOLE DESIGN RESTS ON. At z = 1 the picture fits on both axes, so both are
    // centred — which is where containedRect already puts it. Unconditional: no caller has to hand
    // in a pre-clamped view for this to hold, which is what makes FIT_VIEW a usable default before
    // anything has been laid out.
    expect(zoomedRect(FIT, FIT_VIEW, BOX)).toEqual(FIT);
    expect(zoomedRect(FIT, { z: 1, ox: 999, oy: -999 }, BOX)).toEqual(FIT);
  });

  it("grows the picture by z and centres an axis that still fits", () => {
    // z = 2 -> 840x472.5. Width now overflows the 420 box; height still fits inside 646.
    const r = zoomedRect(FIT, { z: 2, ox: -100, oy: 0 }, BOX);
    expect(r.w).toBeCloseTo(840);
    expect(r.h).toBeCloseTo(472.5);
    expect(r.x).toBeCloseTo(-100);              // pannable: inside [-420, 0]
    expect(r.y).toBeCloseTo((646 - 472.5) / 2); // NOT pannable: centred
  });

  it("stops a panned axis with the picture's edge at the body's edge", () => {
    expect(zoomedRect(FIT, { z: 2, ox: 100, oy: 0 }, BOX).x).toBe(0);        // no gap on the left
    expect(zoomedRect(FIT, { z: 2, ox: -9999, oy: 0 }, BOX).x).toBe(-420);   // no gap on the right
  });
});

describe("clampView", () => {
  it("holds z inside [1, zMax]", () => {
    expect(clampView({ z: 0.2, ox: 0, oy: 0 }, BOX, FIT, 2.33).z).toBe(1);
    expect(clampView({ z: 99, ox: 0, oy: 0 }, BOX, FIT, 2.33).z).toBeCloseTo(2.33);
  });

  it("returns the offsets zoomedRect would draw at, so storing it is idempotent", () => {
    const once = clampView({ z: 2, ox: 500, oy: 500 }, BOX, FIT, 4);
    expect(clampView(once, BOX, FIT, 4)).toEqual(once);
    const r = zoomedRect(FIT, once, BOX);
    expect(once.ox).toBe(r.x);
    expect(once.oy).toBe(r.y);
  });

  it("never lets zMax below 1 pin the picture smaller than its fit", () => {
    // A source with fewer native pixels than the phone paints — zooming buys nothing, but the
    // FLOOR is still the fit, never a shrunk picture.
    expect(clampView({ z: 1, ox: 0, oy: 0 }, BOX, FIT, 0.4).z).toBe(1);
  });
});

describe("anchoredZoom", () => {
  it("holds the anchor's source coordinate fixed across the zoom", () => {
    const before = { z: 1, ox: FIT.x, oy: FIT.y };
    const anchor = { x: 210, y: 300 };
    const after = anchoredZoom(before, anchor, 2);
    // The fraction of the picture under the anchor is what must not move.
    const fracBefore = (anchor.x - before.ox) / (FIT.w * before.z);
    const fracAfter = (anchor.x - after.ox) / (FIT.w * after.z);
    expect(fracAfter).toBeCloseTo(fracBefore);
    expect((anchor.y - after.oy) / (FIT.h * after.z))
      .toBeCloseTo((anchor.y - before.oy) / (FIT.h * before.z));
  });
});

describe("maxZoom", () => {
  it("is native parity: one host native pixel on one device pixel", () => {
    // 2940 native px across a 420px-wide picture on a dpr-3 phone.
    expect(maxZoom(420, 2940, 3)).toBeCloseTo(2940 / 1260);
  });

  it("is floored at 1 when the picture already has every native pixel", () => {
    expect(maxZoom(420, 800, 3)).toBe(1);
  });

  it("falls back when an input is unknown rather than dividing by zero", () => {
    // `pixelSizes` is absent for a simulator and for any window before its first capture push.
    expect(maxZoom(420, 0, 3)).toBe(FALLBACK_MAX_ZOOM);
    expect(maxZoom(0, 2940, 3)).toBe(FALLBACK_MAX_ZOOM);
    expect(maxZoom(420, 2940, 0)).toBe(FALLBACK_MAX_ZOOM);
  });
});

describe("transformFor", () => {
  it("round-trips: applying it to the fit rect yields the target", () => {
    const target = zoomedRect(FIT, { z: 2, ox: -100, oy: 0 }, BOX);
    const t = transformFor(FIT, target);
    expect(t.z).toBeCloseTo(2);
    // transform-origin: 0 0 -> a point p maps to t + z*p.
    expect(t.tx + t.z * FIT.x).toBeCloseTo(target.x);
    expect(t.ty + t.z * FIT.y).toBeCloseTo(target.y);
  });
});

describe("videoViewRect", () => {
  it("is videoContentRect exactly at the fit view", () => {
    const body = { left: 10, top: 20, width: 420, height: 646 };
    expect(videoViewRect(body, NATURAL, FIT_VIEW)).toEqual(videoContentRect(body, NATURAL));
  });

  it("offsets the zoomed picture into client coordinates", () => {
    const body = { left: 10, top: 20, width: 420, height: 646 };
    const r = videoViewRect(body, NATURAL, { z: 2, ox: -100, oy: 0 });
    expect(r.left).toBeCloseTo(10 - 100);
    expect(r.width).toBeCloseTo(840);
    expect(r.top).toBeCloseTo(20 + (646 - 472.5) / 2);
  });
});

import { ViewGesture } from "../src/client/view-zoom";

describe("ViewGesture", () => {
  const fit = { z: 1, ox: 0, oy: 0 };

  it("pans by one finger's own movement, with no zoom", () => {
    const g = new ViewGesture();
    g.down(1, { x: 100, y: 100 });
    const next = g.move(1, { x: 130, y: 90 }, { z: 2, ox: -50, oy: -20 });
    expect(next).toEqual({ z: 2, ox: -20, oy: -30 });   // +30, -10; z untouched
  });

  it("scales z by the spread ratio, composing across sequential moves", () => {
    // FINGERS ARRIVE ONE AT A TIME — that is what a real pointer stream is, and it is why the
    // machine is incremental. Spread 50 -> 75 -> 100 across two moves, so z is 1 * 1.5 * (4/3) = 2.
    const g = new ViewGesture();
    g.down(1, { x: 100, y: 100 });
    g.down(2, { x: 200, y: 100 });   // centroid 150,100; mean spread 50
    const next = g.move(1, { x: 50, y: 100 }, { z: 1, ox: 0, oy: 0 });
    const then = g.move(2, { x: 250, y: 100 }, next!);
    expect(then!.z).toBeCloseTo(2);
  });

  it("zooms about the centroid AND pans by how far that centroid travelled", () => {
    // One finger moves, so both halves happen at once and the arithmetic is checkable by hand:
    //   spread 50 -> 100, so z: 1 -> 2, anchored at the NEW centroid 100
    //     anchoredZoom -> ox = 100 - (100 - 0) * 2 = -100
    //   the centroid itself moved 150 -> 100, so the picture follows it
    //     ox = -100 + (100 - 150) = -150
    // THE ANCHOR IS NOT A FIXED POINT OF `move`, and must not be asserted as one: the centroid moved,
    // so the content is meant to move with it. `anchoredZoom` holds its fixed point; this composes it
    // with a pan.
    const g = new ViewGesture();
    g.down(1, { x: 100, y: 100 });
    g.down(2, { x: 200, y: 100 });
    const next = g.move(1, { x: 0, y: 100 }, { z: 1, ox: 0, oy: 0 });
    expect(next!.z).toBeCloseTo(2);
    expect(next!.ox).toBeCloseTo(-150);
  });

  it("re-baselines on a pointer count change instead of jumping", () => {
    // The centroid of two fingers 100px apart moves by 50 when one lifts. Without a re-baseline the
    // survivor's next move would pan by that jump, which is a visible lurch on every lift.
    const g = new ViewGesture();
    g.down(1, { x: 100, y: 100 });
    g.down(2, { x: 200, y: 100 });
    g.up(2);
    const next = g.move(1, { x: 110, y: 100 }, { z: 2, ox: 0, oy: 0 });
    expect(next!.ox).toBeCloseTo(10);   // 10, not 60
  });

  it("ignores a pointer it never saw, and forgets everything on clear", () => {
    const g = new ViewGesture();
    g.down(1, { x: 0, y: 0 });
    expect(g.move(7, { x: 50, y: 50 }, fit)).toBeNull();
    expect(g.active).toBe(true);
    g.clear();
    expect(g.active).toBe(false);
    expect(g.move(1, { x: 50, y: 50 }, fit)).toBeNull();
  });
});

import { visibleSourceRect } from "../src/client/view-zoom";

describe("visibleSourceRect", () => {
  it("is the WHOLE source at the fit view, so the feature is inert unzoomed", () => {
    // The same shape of property as zoomedRect reducing to containedRect: at z = 1 the picture fits
    // inside the body on both axes, so all of it is visible.
    expect(visibleSourceRect(FIT, FIT_VIEW, BOX)).toEqual({ x: 0, y: 0, w: 1, h: 1 });
  });

  it("is the part of the picture still inside the body when zoomed and panned", () => {
    // z = 2 -> the picture is 840x472.5 in a 420x646 body. Width overflows and is panned 100px left;
    // height fits, so it stays centred and fully visible.
    const r = visibleSourceRect(FIT, { z: 2, ox: -100, oy: 0 }, BOX);
    expect(r.x).toBeCloseTo(100 / 840);   // 100px of picture is off the left edge
    expect(r.w).toBeCloseTo(420 / 840);   // half of it fits across
    expect(r.y).toBeCloseTo(0);
    expect(r.h).toBeCloseTo(1);           // the whole height is on screen
  });

  it("never reports anything outside the source", () => {
    for (const view of [{ z: 3, ox: 0, oy: 0 }, { z: 3, ox: -9999, oy: -9999 },
                        { z: 1.2, ox: 50, oy: 50 }]) {
      const r = visibleSourceRect(FIT, view, BOX);
      expect(r.x).toBeGreaterThanOrEqual(0);
      expect(r.y).toBeGreaterThanOrEqual(0);
      expect(r.x + r.w).toBeLessThanOrEqual(1.0001);
      expect(r.y + r.h).toBeLessThanOrEqual(1.0001);
      expect(r.w).toBeGreaterThan(0);
      expect(r.h).toBeGreaterThan(0);
    }
  });
});
