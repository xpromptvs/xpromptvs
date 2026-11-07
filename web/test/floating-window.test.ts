import { describe, expect, it, test } from "vitest";
import { applyAspectLock, aspectRatioFromDims, clampToViewport, initFloatingWindow, rectFromResize, rectFromFreeResize, type Rect } from "../src/client/floating-window";

test("applyAspectLock derives height from width and ratio", () => {
  expect(applyAspectLock(390, 999, 390 / 844)).toEqual({ w: 390, h: 844 });
  expect(applyAspectLock(195, 1, 390 / 844)).toEqual({ w: 195, h: 422 });
});

test("clampToViewport keeps the window within bounds", () => {
  const r: Rect = { x: -50, y: -50, w: 200, h: 400 };
  const c = clampToViewport(r, 1000, 800, 24);
  expect(c.x).toBeGreaterThanOrEqual(24 - r.w); // at least `margin` visible on the right edge
  expect(c.y).toBeGreaterThanOrEqual(0);
});

test("clampToViewport pins an off-right window so a margin stays visible", () => {
  const r: Rect = { x: 2000, y: 2000, w: 200, h: 400 };
  const c = clampToViewport(r, 1000, 800, 24);
  expect(c.x).toBeLessThanOrEqual(1000 - 24);
  expect(c.y).toBeLessThanOrEqual(800 - 24);
});

test("rectFromResize keeps the top-right corner fixed and locks aspect", () => {
  // bottom-left grip: dragging left (-dx) widens; height follows ratio.
  const start: Rect = { x: 600, y: 100, w: 200, h: 432 };
  const ratio = 390 / 844;
  const out = rectFromResize(start, -40, 0, ratio, { w: 160 }, { h: 900 });
  const right = start.x + start.w;
  expect(out.x + out.w).toBeCloseTo(right, 5);   // right edge fixed
  expect(out.y).toBe(start.y);                    // top edge fixed
  expect(out.w).toBe(240);
  expect(out.h).toBeCloseTo(240 / ratio, 5);
});

test("rectFromResize respects the minimum width", () => {
  const start: Rect = { x: 600, y: 100, w: 200, h: 432 };
  const out = rectFromResize(start, 400, 0, 390 / 844, { w: 160 }, { h: 900 });
  expect(out.w).toBe(160);
});

describe("aspectRatioFromDims", () => {
  it("returns w/h for valid dims", () => {
    expect(aspectRatioFromDims(390, 844)).toBeCloseTo(390 / 844, 6);
    expect(aspectRatioFromDims(1920, 1080)).toBeCloseTo(16 / 9, 6);
  });
  it("falls back to a sane portrait ratio for zero/invalid dims", () => {
    expect(aspectRatioFromDims(0, 844)).toBeCloseTo(390 / 844, 6);
    expect(aspectRatioFromDims(390, 0)).toBeCloseTo(390 / 844, 6);
  });
});

describe("setRatio reflows from inline styles (never collapses to 0×0)", () => {
  // Regression: window-capture (`win:*`) windows rendered 0×0/invisible on the desktop floating layout.
  // Root cause: setRatio reflowed from getBoundingClientRect(), which is 0×0 for an un-laid-out element —
  // jsdom returns 0×0 for ALL elements (no layout engine), so this test reproduces exactly that condition.
  const mk = () => {
    const el = document.createElement("div");
    el.style.left = "32px"; el.style.top = "72px"; el.style.width = "280px";
    const drag = document.createElement("div"), grip = document.createElement("div");
    el.append(drag, grip); document.body.append(el);
    return { el, api: initFloatingWindow({ el, dragHandle: drag, resizeHandles: [{ el: grip, corner: "sw" as const }], ratio: 390 / 844, minW: 160, maxH: 800 }) };
  };

  it("keeps the intended width + a non-zero aspect-locked height even when getBoundingClientRect is 0", () => {
    const { el, api } = mk();
    api.setRatio(390 / 844);
    expect(parseFloat(el.style.width)).toBe(280);                         // from the inline style, not the 0 measurement
    expect(parseFloat(el.style.height)).toBeCloseTo(280 / (390 / 844), 0); // ≈606, NOT 0
    document.body.removeChild(el);
  });

  it("recovers a window already stuck at 0 to the minimum width", () => {
    const { el, api } = mk();
    el.style.width = "0px";                                               // simulate a previously-collapsed window
    api.setRatio(390 / 844);
    expect(parseFloat(el.style.width)).toBe(160);                        // minW floor
    expect(parseFloat(el.style.height)).toBeGreaterThan(0);
    document.body.removeChild(el);
  });
});

describe("applyAspectLock with chrome", () => {
  it("adds the chrome height on top of the body aspect", () => {
    // body 400x300 (ratio 4/3) plus a 28px titlebar => element is 328 tall, so the BODY is exactly 300.
    expect(applyAspectLock(400, 0, 4 / 3, 28)).toEqual({ w: 400, h: 328 });
  });
  it("defaults to no chrome (unchanged behavior)", () => {
    expect(applyAspectLock(400, 0, 4 / 3)).toEqual({ w: 400, h: 300 });
  });
});

describe("rectFromResize with chrome", () => {
  it("keeps the BODY on-ratio while the element carries the titlebar", () => {
    const start: Rect = { x: 100, y: 50, w: 400, h: 328 };
    const r = rectFromResize(start, -100, 0, 4 / 3, { w: 160 }, { h: Infinity }, 28);
    expect(r.w).toBe(500);
    expect(r.h).toBe(500 / (4 / 3) + 28);   // body 375 + chrome
  });
});

describe("rectFromFreeResize", () => {
  const start: Rect = { x: 100, y: 50, w: 400, h: 300 };
  it("widens when the bottom-left grip moves LEFT and keeps the top-right corner fixed", () => {
    const r = rectFromFreeResize(start, -60, 0, { w: 160, h: 120 });
    expect(r.w).toBe(460);
    expect(r.x + r.w).toBe(start.x + start.w);   // right edge pinned
    expect(r.y).toBe(50);                        // top edge pinned
  });
  it("changes width and height INDEPENDENTLY (no aspect lock)", () => {
    const r = rectFromFreeResize(start, -100, 200, { w: 160, h: 120 });
    expect(r).toEqual({ x: 0, y: 50, w: 500, h: 500 });
  });
  // All four corners resize; each anchors the OPPOSITE corner, exactly as a native window does.
  it("anchors the opposite corner for every corner", () => {
    const min = { w: 160, h: 120 };
    // se: drag right+down grows both, top-left pinned.
    expect(rectFromFreeResize(start, 50, 40, min, "se")).toEqual({ x: 100, y: 50, w: 450, h: 340 });
    // sw: drag left grows width leftwards, top-RIGHT pinned (today's only corner).
    expect(rectFromFreeResize(start, -50, 40, min, "sw")).toEqual({ x: 50, y: 50, w: 450, h: 340 });
    // ne: drag up grows height upwards, bottom-LEFT pinned.
    expect(rectFromFreeResize(start, 50, -40, min, "ne")).toEqual({ x: 100, y: 10, w: 450, h: 340 });
    // nw: both, bottom-RIGHT pinned.
    expect(rectFromFreeResize(start, -50, -40, min, "nw")).toEqual({ x: 50, y: 10, w: 450, h: 340 });
  });

  it("holds the anchored corner still once a drag passes the minimum size", () => {
    // The anchor is taken from the FAR EDGE rather than by adding the delta, so a drag that overshoots the
    // minimum parks the window instead of letting it creep away under the pointer.
    const min = { w: 160, h: 120 };
    const r = rectFromFreeResize(start, 9999, 9999, min, "nw");
    expect(r.x + r.w).toBe(start.x + start.w);   // right edge still pinned
    expect(r.y + r.h).toBe(start.y + start.h);   // bottom edge still pinned
    expect(r.w).toBe(160);
    expect(r.h).toBe(120);
  });

  it("defaults to the bottom-left corner", () => {
    expect(rectFromFreeResize(start, -60, 0, { w: 160, h: 120 }))
      .toEqual(rectFromFreeResize(start, -60, 0, { w: 160, h: 120 }, "sw"));
  });

  it("clamps to the minimums instead of inverting", () => {
    const r = rectFromFreeResize(start, 9999, -9999, { w: 160, h: 120 });
    expect(r.w).toBe(160);
    expect(r.h).toBe(120);
    expect(r.x + r.w).toBe(start.x + start.w);
  });
});

test("a window cannot be dragged up under the tab bar", () => {
  const r = { x: 100, y: -40, w: 300, h: 200 };
  expect(clampToViewport(r, 1280, 800, 24, 64).y).toBe(64);
});

test("the top clamp defaults to 0, so callers that don't pass it are unchanged", () => {
  expect(clampToViewport({ x: 100, y: -40, w: 300, h: 200 }, 1280, 800).y).toBe(0);
});

test("the bottom clamp still wins over the top clamp for a short viewport", () => {
  expect(clampToViewport({ x: 0, y: 999, w: 300, h: 200 }, 1280, 800, 24, 64).y).toBe(800 - 24);
});
test("capture loss stops a window drag from following later pointer moves",()=>{
 const el=document.body.appendChild(document.createElement('div')),bar=el.appendChild(document.createElement('div'));
 bar.setPointerCapture=()=>{};bar.releasePointerCapture=()=>{};
 initFloatingWindow({el,dragHandle:bar,resizeHandles:[],ratio:1,minW:100,maxH:800});
 const pointer=(type:string,x:number)=>Object.assign(new Event(type),{pointerId:1,clientX:x,clientY:20});
 bar.dispatchEvent(pointer('pointerdown',20));bar.dispatchEvent(pointer('pointermove',100));
 const before=el.style.left;bar.dispatchEvent(pointer('lostpointercapture',100));bar.dispatchEvent(pointer('pointermove',200));
 expect(el.style.left).toBe(before);el.remove();
});
