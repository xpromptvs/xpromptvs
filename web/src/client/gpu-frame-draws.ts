import type { ScrollSurface } from "./smooth-scroll";

/// The WebGPU renderer's part a view routes the smooth scroll's shift to (webgpu/renderer.ts `WebgpuHandle`).
export interface GpuShift {
  readonly active: boolean;
  setShift(px: number): void;
}

/// The view's frame clock (xterm-view.ts `viewClock`): a frame's work, and whether one is running now.
export interface FrameRunner {
  frame(cb: (now: number) => void): number;
  cancelFrame(id: number): void;
  inFrame(): boolean;
}

/// **WHILE THE WEBGPU RENDERER DRAWS, A SCROLL OUTSIDE A FRAME DRAWS IN THE NEXT ONE** (2026-10-07). A scroll
/// notification draws at once — the rows it moved to (`drawNow`), then the shift (`setScreenOffset`, which this
/// renderer DRAWS) — and the smooth scroll's own steps make them inside the animation frame (`viewClock`): on an
/// iPhone, draws between rendering updates showed a previous buffer. But xterm.js scrolls by itself too, outside
/// any frame: its `Viewport._sync` after output (a line at the bottom, a full scrollback trimming), a keystroke's
/// jump to the bottom, a trim's snap. Measured on the GPU: a wheel scroll while output streamed into a full
/// scrollback put 27 of 368 submits between frames, every one through `drawNow`. Here such a scroll only MARKS
/// its rows and shift, and the next frame draws both — together, as `drawNow` exists to keep them — with the
/// LATEST shift. A finger's drag stays immediate (`holding`): its draws ride the touch events, and on the iPhone
/// a drag never showed the stale buffer, where a frame's delay would put the text behind the finger. The DOM
/// renderer is untouched: its rows and transform are one paint wherever they are written.
///
/// Installs itself on `surface` (its `drawNow` and `setScreenOffset`); returns the teardown.
export function routeGpuFrameDraws(surface: ScrollSurface, gpu: GpuShift, clock: FrameRunner,
                                   holding: () => boolean): () => void {
  const drawRows = surface.drawNow;
  const cssShift = surface.setScreenOffset;
  let latest = 0, rowsPending = false, shiftPending = false, frameId: number | null = null;
  const drawsNow = () => !gpu.active || clock.inFrame() || holding();
  const applyShift = (px: number) => {
    if (gpu.active) { cssShift(0); gpu.setShift(px); }
    else { gpu.setShift(0); cssShift(px); }
  };
  const flush = () => {
    frameId = null;
    const rows = rowsPending, shift = shiftPending;
    rowsPending = shiftPending = false;
    if (rows) drawRows();
    if (shift) applyShift(latest);
  };
  const later = () => { if (frameId === null) frameId = clock.frame(flush); };
  surface.drawNow = () => {
    if (drawsNow()) { rowsPending = false; drawRows(); return; }
    rowsPending = true;
    later();
  };
  surface.setScreenOffset = (px) => {
    latest = px;
    if (drawsNow()) { shiftPending = false; applyShift(px); return; }
    shiftPending = true;
    later();
  };
  return () => {
    if (frameId !== null) clock.cancelFrame(frameId);
    frameId = null;
    rowsPending = shiftPending = false;
  };
}
