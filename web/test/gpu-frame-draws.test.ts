import { describe, expect, it } from "vitest";
import { routeGpuFrameDraws } from "../src/client/gpu-frame-draws";
import type { ScrollSurface } from "../src/client/smooth-scroll";

// **WHILE THE WEBGPU RENDERER DRAWS, A SCROLL OUTSIDE A FRAME DRAWS IN THE NEXT ONE** (2026-10-07): xterm.js's own
// scrolls (output, a keystroke's jump, a trim's snap) drew the rows and the shift between frames.
function rig({ active = true, holding = false } = {}) {
  const log: string[] = [];
  const surface = {
    drawNow: () => log.push("rows"),
    setScreenOffset: (px: number) => log.push(`css ${px}`),
  } as unknown as ScrollSurface;
  const gpu = { active, setShift: (px: number) => log.push(`gpu ${px}`) };
  const frames: ((now: number) => void)[] = [];
  let depth = 0;
  const clock = {
    frame: (cb: (now: number) => void) => frames.push(cb),
    cancelFrame: (id: number) => { frames[id - 1] = () => {}; },
    inFrame: () => depth > 0,
  };
  const state = { holding };
  const off = routeGpuFrameDraws(surface, gpu, clock, () => state.holding);
  const runFrame = () => { const cbs = frames.splice(0); depth++; try { for (const cb of cbs) cb(0); } finally { depth--; } };
  const inFrame = (fn: () => void) => { depth++; try { fn(); } finally { depth--; } };
  return { log, surface, gpu, frames, runFrame, inFrame, state, off };
}

describe("routeGpuFrameDraws", () => {
  it("defers a scroll's rows and shift made outside a frame to the next frame, together", () => {
    const r = rig();
    r.surface.drawNow();
    r.surface.setScreenOffset(-3);
    expect(r.log).toEqual([]);
    expect(r.frames).toHaveLength(1);                     // one frame for both
    r.runFrame();
    expect(r.log).toEqual(["rows", "css 0", "gpu -3"]);   // the rows first, then the shift: one state
  });

  it("draws at once inside a frame", () => {
    const r = rig();
    r.inFrame(() => { r.surface.drawNow(); r.surface.setScreenOffset(-2); });
    expect(r.log).toEqual(["rows", "css 0", "gpu -2"]);
    expect(r.frames).toHaveLength(0);
  });

  it("draws the LATEST shift when its frame comes", () => {
    const r = rig();
    r.surface.setScreenOffset(-1);
    r.surface.setScreenOffset(-4);
    r.runFrame();
    expect(r.log).toEqual(["css 0", "gpu -4"]);
  });

  it("drops a pending draw that a draw inside a frame already made", () => {
    const r = rig();
    r.surface.drawNow();
    r.surface.setScreenOffset(-1);
    r.inFrame(() => { r.surface.drawNow(); r.surface.setScreenOffset(-5); });   // the controller's own frame
    r.runFrame();
    expect(r.log).toEqual(["rows", "css 0", "gpu -5"]);                        // nothing stale after it
  });

  it("keeps a finger's drag immediate", () => {
    const r = rig({ holding: true });
    r.surface.drawNow();
    r.surface.setScreenOffset(-6);
    expect(r.log).toEqual(["rows", "css 0", "gpu -6"]);
    expect(r.frames).toHaveLength(0);
  });

  it("leaves the DOM renderer alone: everything at once, the shift a transform", () => {
    const r = rig({ active: false });
    r.surface.drawNow();
    r.surface.setScreenOffset(-2);
    expect(r.log).toEqual(["rows", "gpu 0", "css -2"]);
    expect(r.frames).toHaveLength(0);
  });

  it("draws a pending shift as a transform if the renderer is gone by its frame", () => {
    const r = rig();
    r.surface.setScreenOffset(-3);
    (r.gpu as { active: boolean }).active = false;
    r.runFrame();
    expect(r.log).toEqual(["gpu 0", "css -3"]);
  });

  it("cancels its frame on teardown", () => {
    const r = rig();
    r.surface.drawNow();
    r.off();
    r.runFrame();
    expect(r.log).toEqual([]);
  });
});
