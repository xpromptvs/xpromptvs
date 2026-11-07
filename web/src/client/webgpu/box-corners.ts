import { BG_CORNER_RADIUS_PX } from "../bg-corners";

/// A BOX'S LIGHT CORNERS, DRAWN WITH HALF THE BLOCKS' RADIUS (asked for 2026-10-10: "draw our own ones,
/// with the same radius as we have for blocks", then "make these corners 2x smaller"). `┌ ┐ └ ┘` and the arcs
/// `╭ ╮ ╰ ╯` are all drawn as one corner: two straight strokes joined by a CIRCULAR arc of
/// `BOX_CORNER_RADIUS_PX` CSS px — half a background block's corner (bg-corners.ts), a fixed size, so a table
/// and Claude Code's own boxes round alike at every font size. custom-glyphs.ts (vendored, unchanged) would
/// draw `┌` square and `╭` as a Bézier spanning half the cell, a radius that grows with the font.
///
/// The strokes are custom-glyphs.ts's EXACTLY, so a corner meets the `─` and `│` beside it on the same
/// pixels: the same width (1 device px per device pixel ratio — its normal weight), the same butt ends at
/// the cell's edges, and the cell's centre snapped as its `translateArgs` snaps it (to the nearest half
/// pixel, so a 1 px line at 1× is crisp). `web/test/webgpu-box-corners.test.ts` holds the two to the
/// same coordinates by driving both with one recording context.

/// The corner's radius, in CSS px: half a background block's (`BG_CORNER_RADIUS_PX`, 3) — at 3 the corners
/// read too round on a line one pixel wide.
export const BOX_CORNER_RADIUS_PX = BG_CORNER_RADIUS_PX / 2;

/// Which way each corner's strokes leave the centre: `h` toward the right (+1) or left (-1) edge, `v`
/// toward the bottom (+1) or top (-1) edge.
const CORNERS: ReadonlyMap<string, { h: 1 | -1; v: 1 | -1 }> = new Map([
  ["┌", { h: 1, v: 1 }], ["╭", { h: 1, v: 1 }],
  ["┐", { h: -1, v: 1 }], ["╮", { h: -1, v: 1 }],
  ["└", { h: 1, v: -1 }], ["╰", { h: 1, v: -1 }],
  ["┘", { h: -1, v: -1 }], ["╯", { h: -1, v: -1 }],
]);

/// custom-glyphs.ts's snap of a coordinate inside a cell `max` device px long.
function snap(v: number, max: number): number {
  return v === 0 ? 0 : Math.max(0, Math.min(max, Math.round(v + 0.5) - 0.5));
}

/// Draw `c` if it is a light corner into the cell at (`x`, `y`), `w`×`h` device px, in the context's fill
/// colour; false for anything else (custom-glyphs.ts's turn).
export function tryDrawBoxCorner(
  ctx: CanvasRenderingContext2D, c: string, x: number, y: number, w: number, h: number, dpr: number,
  radiusPx = BOX_CORNER_RADIUS_PX,
): boolean {
  const corner = CORNERS.get(c);
  if (!corner) return false;
  const cx = snap(w / 2, w), cy = snap(h / 2, h);
  const edgeX = corner.h > 0 ? w : 0, edgeY = corner.v > 0 ? h : 0;
  // Never wider than the strokes it joins: a small font's cell is narrower than twice the radius.
  const r = Math.max(0, Math.min(radiusPx * dpr, Math.abs(edgeX - cx), Math.abs(edgeY - cy)));
  ctx.strokeStyle = ctx.fillStyle;
  ctx.lineWidth = dpr;
  ctx.beginPath();
  ctx.moveTo(x + cx, y + edgeY);
  ctx.arcTo(x + cx, y + cy, x + edgeX, y + cy, r);
  ctx.lineTo(x + edgeX, y + cy);
  ctx.stroke();
  return true;
}
