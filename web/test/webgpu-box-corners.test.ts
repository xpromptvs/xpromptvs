import { describe, expect, it } from "vitest";
import { BOX_CORNER_RADIUS_PX, tryDrawBoxCorner } from "../src/client/webgpu/box-corners";
import { tryDrawCustomChar } from "../src/client/webgpu/custom-glyphs";

/// A box's light corners, drawn by the WebGPU atlas with half the blocks' radius (webgpu/box-corners.ts). One
/// recording context drives both our corner and custom-glyphs.ts's `─` and `│` (vendored), so the corner
/// is held to THEIR coordinates and width — the only way it meets them on the same pixels. What the
/// corner looks like on a GPU: `e2e/term-webgpu-check.mjs` arm N.

type Call = [string, ...number[]];

function recorder(): { ctx: CanvasRenderingContext2D; calls: Call[]; widths: number[] } {
  const calls: Call[] = [], widths: number[] = [];
  const ctx = {
    fillStyle: "#ffffff", strokeStyle: "",
    set lineWidth(v: number) { widths.push(v); },
    beginPath() {}, closePath() {}, stroke() { calls.push(["stroke"]); },
    moveTo(x: number, y: number) { calls.push(["moveTo", x, y]); },
    lineTo(x: number, y: number) { calls.push(["lineTo", x, y]); },
    arcTo(x1: number, y1: number, x2: number, y2: number, r: number) { calls.push(["arcTo", x1, y1, x2, y2, r]); },
    bezierCurveTo(...a: number[]) { calls.push(["bezierCurveTo", ...a]); },
  };
  return { ctx: ctx as unknown as CanvasRenderingContext2D, calls, widths };
}

/// Where custom-glyphs.ts puts `─`'s row and `│`'s column, and its stroke width, in a `w`×`h` cell.
function lines(w: number, h: number, dpr: number): { cx: number; cy: number; width: number } {
  const horizontal = recorder();
  tryDrawCustomChar(horizontal.ctx, "─", 0, 0, w, h, 14, dpr);
  const vertical = recorder();
  tryDrawCustomChar(vertical.ctx, "│", 0, 0, w, h, 14, dpr);
  const [, , cy] = horizontal.calls.find((c) => c[0] === "moveTo")!;
  const [, cx] = vertical.calls.find((c) => c[0] === "moveTo")!;
  return { cx: cx!, cy: cy!, width: horizontal.widths.at(-1)! };
}

describe("a box's light corners — half the blocks' radius, on custom-glyphs.ts's strokes", () => {
  for (const [w, h, dpr] of [[17, 34, 2], [9, 17, 1], [8, 17, 1], [25, 51, 3]] as const) {
    it(`┌ meets ─ and │ on the same pixels, with a ${BOX_CORNER_RADIUS_PX} px arc (${w}×${h} @${dpr}×)`, () => {
      const { cx, cy, width } = lines(w, h, dpr);
      const r = Math.min(BOX_CORNER_RADIUS_PX * dpr, w - cx, h - cy);
      const { ctx, calls, widths } = recorder();
      expect(tryDrawBoxCorner(ctx, "┌", 0, 0, w, h, dpr)).toBe(true);
      expect(calls).toEqual([["moveTo", cx, h], ["arcTo", cx, cy, w, cy, r], ["lineTo", w, cy], ["stroke"]]);
      expect(widths).toEqual([width]);
    });
  }

  it("draws every corner toward its own edges, offset into its cell", () => {
    const w = 17, h = 34, dpr = 2, { cx, cy } = lines(w, h, dpr), r = BOX_CORNER_RADIUS_PX * dpr;
    const at = (c: string) => { const { ctx, calls } = recorder(); tryDrawBoxCorner(ctx, c, 100, 200, w, h, dpr); return calls; };
    expect(at("┐")).toEqual([["moveTo", 100 + cx, 200 + h], ["arcTo", 100 + cx, 200 + cy, 100, 200 + cy, r], ["lineTo", 100, 200 + cy], ["stroke"]]);
    expect(at("└")).toEqual([["moveTo", 100 + cx, 200], ["arcTo", 100 + cx, 200 + cy, 100 + w, 200 + cy, r], ["lineTo", 100 + w, 200 + cy], ["stroke"]]);
    expect(at("┘")).toEqual([["moveTo", 100 + cx, 200], ["arcTo", 100 + cx, 200 + cy, 100, 200 + cy, r], ["lineTo", 100, 200 + cy], ["stroke"]]);
  });

  it("draws the arcs ╭ ╮ ╰ ╯ exactly as the square corners — one corner for a table and a program's box", () => {
    const draw = (c: string) => { const { ctx, calls } = recorder(); tryDrawBoxCorner(ctx, c, 0, 0, 17, 34, 2); return calls; };
    expect(draw("╭")).toEqual(draw("┌"));
    expect(draw("╮")).toEqual(draw("┐"));
    expect(draw("╰")).toEqual(draw("└"));
    expect(draw("╯")).toEqual(draw("┘"));
  });

  it("never draws an arc wider than the strokes it joins — a phone's small cell", () => {
    const w = 5, h = 9, dpr = 2, { cx, cy } = lines(w, h, dpr);
    const { ctx, calls } = recorder();
    tryDrawBoxCorner(ctx, "┌", 0, 0, w, h, dpr);
    expect(calls[1]).toEqual(["arcTo", cx, cy, w, cy, Math.min(w - cx, h - cy)]);
    expect(Math.min(w - cx, h - cy)).toBeLessThan(BOX_CORNER_RADIUS_PX * dpr);
  });

  it("leaves everything else to custom-glyphs.ts — lines, joints, heavy and double corners, text", () => {
    for (const c of ["─", "│", "┬", "┼", "┏", "┛", "╔", "╝", "a", ""]) {
      const { ctx, calls } = recorder();
      expect(tryDrawBoxCorner(ctx, c, 0, 0, 17, 34, 2)).toBe(false);
      expect(calls).toEqual([]);
    }
  });
});

describe("the corner's size", () => {
  it("is half a background block's radius — a fixed 1.5 CSS px", () => {
    expect(BOX_CORNER_RADIUS_PX).toBe(1.5);
  });
});
