import { tryDrawBoxCorner } from "./box-corners";
import { tryDrawCustomChar } from "./custom-glyphs";

/// **ONE GLYPH TEXTURE PER FONT, SHARED BY EVERY WEBGPU TERMINAL USING IT** (renderer.ts). Each glyph is
/// rasterized ONCE, in white, by Canvas 2D, and TINTED by the shader with its cell's colour — so the
/// atlas holds a glyph once however many colours it is drawn in (xterm.js's WebGL atlas bakes the colours
/// in, one entry per glyph/colour pair). A COLOUR glyph (an emoji: its pixels are not grey) is drawn as is.
///
/// Box drawing, block elements and powerline symbols are drawn to the cell (`custom-glyphs.ts`, vendored
/// from xterm.js): the product's JetBrains Mono subset carries none of them, and a font's would not join
/// cell to cell. They are rasterized at the cell's exact device width — cells are FRACTIONAL (renderer.ts
/// matches the DOM renderer's grid), so that width is 16 or 17 px at 16.8 — and keyed by it, so a line
/// of `─` tiles with no seam.
///
/// Packed in shelves into a 2048² texture; when that is full it is CLEARED (`generation` moves on) and
/// every terminal redraws all its rows, which re-adds what is on screen.

export interface AtlasFont {
  family: string;
  /// CSS px.
  size: number;
  weight: string | number;
  weightBold: string | number;
  dpr: number;
  /// The row height in device px (an integer, as the DOM renderer's).
  cellH: number;
}

export interface Glyph {
  /// The bitmap's place in the atlas, in texels; `w` 0 is no glyph (a space, an empty cluster).
  x: number; y: number; w: number; h: number;
  /// The bitmap's top-left relative to its cell's top-left, in device px (negative: it overhangs).
  left: number; top: number;
  /// Drawn as is (an emoji), not tinted.
  color: boolean;
}

/// Where a row's lines sit, from its top, in device px.
export interface LineMetrics {
  baseline: number;
  underline: number;
  strike: number;
  thickness: number;
}

const NONE: Glyph = Object.freeze({ x: 0, y: 0, w: 0, h: 0, left: 0, top: 0, color: false });

/// Drawn to the cell rather than from the font (custom-glyphs.ts covers these ranges).
export function isCellGlyph(chars: string): boolean {
  if (chars.length > 2) return false;
  const cp = chars.codePointAt(0) ?? 0;
  return (cp >= 0x2500 && cp <= 0x259f) || (cp >= 0xe0a0 && cp <= 0xe0d7);
}

export class GlyphAtlas {
  static readonly SIZE = 2048;
  readonly texture: GPUTexture;
  /// Moves on whenever the atlas is cleared: every glyph handed out before is gone.
  generation = 0;
  metrics: LineMetrics;
  private readonly cache = new Map<string, Glyph>();
  /// An ELEMENT, not an OffscreenCanvas: custom-glyphs.ts draws its shade patterns through
  /// `ctx.canvas.ownerDocument`, which an OffscreenCanvas does not have (measured: ░▒▓ threw).
  private readonly canvas: HTMLCanvasElement;
  private readonly ctx: CanvasRenderingContext2D;
  private readonly pad: number;
  private shelfX = 0;
  private shelfY = 0;
  private shelfH = 0;

  constructor(private readonly device: GPUDevice, readonly font: AtlasFont) {
    this.texture = device.createTexture({
      size: [GlyphAtlas.SIZE, GlyphAtlas.SIZE],
      format: "rgba8unorm",
      // RENDER_ATTACHMENT: `copyExternalImageToTexture` requires it of its destination.
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
    });
    this.pad = Math.ceil(font.cellH * 0.5);
    const w = Math.ceil(font.size * font.dpr * 4) + this.pad * 2;
    const h = font.cellH + this.pad * 2;
    this.canvas = document.createElement("canvas");
    this.canvas.width = w;
    this.canvas.height = h;
    const ctx = this.canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx) throw new Error("no 2D context for the glyph atlas");
    this.ctx = ctx;
    this.metrics = this.measure();
  }

  /// The glyph for `chars` in this style. `cells` is its width in cells; `cellWidth` the device width of
  /// those cells where it starts (only a cell-drawn glyph depends on it).
  get(chars: string, bold: boolean, italic: boolean, cellWidth: number): Glyph {
    const cell = isCellGlyph(chars);
    const key = cell ? `c${cellWidth}|${chars}` : `${bold ? "b" : ""}${italic ? "i" : ""}|${chars}`;
    const hit = this.cache.get(key);
    if (hit) return hit;
    const glyph = this.rasterize(chars, bold, italic, cell, cellWidth);
    this.cache.set(key, glyph);
    return glyph;
  }

  /// Forget every glyph (a full atlas, a font that finished loading): the texture is reused.
  clear(): void {
    this.cache.clear();
    this.shelfX = 0; this.shelfY = 0; this.shelfH = 0;
    this.generation++;
    this.metrics = this.measure();
  }

  destroy(): void { this.texture.destroy(); }

  private fontString(bold: boolean, italic: boolean): string {
    const f = this.font;
    return `${italic ? "italic " : ""}${bold ? f.weightBold : f.weight} ${f.size * f.dpr}px ${f.family}`;
  }

  /// The baseline as CSS places it in a line box the height of a row (centred content area), and the
  /// lines from the font's own extents.
  private measure(): LineMetrics {
    const ctx = this.ctx, f = this.font;
    ctx.font = this.fontString(false, false);
    const m = ctx.measureText("Mg");
    const ascent = m.fontBoundingBoxAscent || m.actualBoundingBoxAscent || f.size * f.dpr * 0.8;
    const descent = m.fontBoundingBoxDescent || m.actualBoundingBoxDescent || f.size * f.dpr * 0.2;
    const xHeight = ctx.measureText("x").actualBoundingBoxAscent || ascent * 0.5;
    const baseline = Math.round((f.cellH - (ascent + descent)) / 2 + ascent);
    const thickness = Math.max(1, Math.floor((f.size * f.dpr) / 15));
    const underline = Math.min(f.cellH - thickness, baseline + Math.max(1, Math.round(descent * 0.35)));
    const strike = Math.round(baseline - xHeight / 2 - thickness / 2);
    return { baseline, underline, strike, thickness };
  }

  private rasterize(chars: string, bold: boolean, italic: boolean, cell: boolean, cellWidth: number): Glyph {
    const ctx = this.ctx, pad = this.pad, f = this.font;
    const W = this.canvas.width, H = this.canvas.height;
    ctx.clearRect(0, 0, W, H);
    ctx.save();
    ctx.fillStyle = "#ffffff";
    ctx.strokeStyle = "#ffffff";
    ctx.font = this.fontString(bold, italic);
    ctx.textBaseline = "alphabetic";
    // A box's light corners are ours (box-corners.ts: half the blocks' radius); every other cell glyph custom-glyphs.ts's.
    const drawn = cell && (tryDrawBoxCorner(ctx, chars, pad, pad, cellWidth, f.cellH, f.dpr)
      || tryDrawCustomChar(ctx, chars, pad, pad, cellWidth, f.cellH, f.size, f.dpr));
    if (!drawn) ctx.fillText(chars, pad, pad + this.metrics.baseline);
    ctx.restore();

    // The tight box, and whether any pixel is not grey (a colour glyph). Canvas 2D hands back
    // UNPREMULTIPLIED values, so white text is 255/255/255 at every coverage.
    const data = ctx.getImageData(0, 0, W, H).data;
    let minX = W, minY = H, maxX = -1, maxY = -1, color = false;
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        const i = (y * W + x) * 4;
        if (data[i + 3] === 0) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        if (!color) {
          const r = data[i]!, g = data[i + 1]!, b = data[i + 2]!;
          if (Math.abs(r - g) > 8 || Math.abs(g - b) > 8) color = true;
        }
      }
    }
    if (maxX < 0) return NONE;
    const w = maxX - minX + 1, h = maxY - minY + 1;
    const place = this.place(w, h);
    if (!place) return NONE;
    this.device.queue.copyExternalImageToTexture(
      { source: this.canvas, origin: { x: minX, y: minY } },
      { texture: this.texture, origin: { x: place.x, y: place.y }, premultipliedAlpha: true },
      { width: w, height: h },
    );
    return { x: place.x, y: place.y, w, h, left: minX - pad, top: minY - pad, color };
  }

  /// A place for a `w`×`h` bitmap, shelf by shelf, one texel apart. A full atlas is cleared first — the
  /// caller's frame then redraws everything (the generation moved on).
  private place(w: number, h: number): { x: number; y: number } | null {
    const S = GlyphAtlas.SIZE;
    if (w > S || h > S) return null;
    if (this.shelfX + w > S) { this.shelfY += this.shelfH + 1; this.shelfX = 0; this.shelfH = 0; }
    if (this.shelfY + h > S) this.clear();
    const at = { x: this.shelfX, y: this.shelfY };
    this.shelfX += w + 1;
    this.shelfH = Math.max(this.shelfH, h);
    return at;
  }
}
