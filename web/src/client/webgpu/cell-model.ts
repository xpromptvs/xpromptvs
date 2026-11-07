/// **WHAT A CELL LOOKS LIKE — COLOURS AND LINES — FROM XTERM.JS'S PACKED ATTRIBUTES.** Pure, so it is
/// tested against a real xterm.js in jsdom (web/test/webgpu-cell-model.test.ts); the renderer
/// (renderer.ts) turns the result into instance data.
///
/// The rules are xterm.js's own (its WebGL addon's `CellColorResolver` and the DOM renderer's row
/// factory, MIT): bold draws palette 0-7 as 8-15 (`drawBoldTextInBrightColors`); inverse swaps the two,
/// a default foreground becoming the theme's background and the reverse; a selected cell takes the OPAQUE
/// selection colour and is not dim (the DOM renderer's look — the WebGL addon blends instead, and the
/// renderers must agree); decorations override below ('bottom') and above ('top') the selection; dim draws
/// the foreground at half alpha. Underlined is xterm.js's `isUnderline()`: the flag, OR an extended
/// underline style — which an OSC 8 link's cells report as dashed (its `ExtendedAttrs`) with no flag set.
///
/// Colours are packed 0xRRGGBBAA, as xterm.js's `IColor.rgba`. A background of 0 is the DEFAULT one —
/// nothing is drawn for it (the canvas is cleared to the theme's).

// xterm.js's attribute layout (common/buffer/Constants.ts).
const CM_MASK = 0x3000000, CM_P16 = 0x1000000, CM_P256 = 0x2000000, CM_RGB = 0x3000000;
const RGB_MASK = 0xffffff;
const FG_INVERSE = 0x4000000, FG_BOLD = 0x8000000, FG_UNDERLINE = 0x10000000, FG_INVISIBLE = 0x40000000,
  FG_STRIKE = 0x80000000;
const BG_ITALIC = 0x4000000, BG_DIM = 0x8000000, BG_HAS_EXTENDED = 0x10000000, BG_OVERLINE = 0x40000000;

/// The theme's colours, as xterm.js resolved them (its `ThemeService.colors`, rgba).
export interface Palette {
  foreground: number;
  background: number;
  cursor: number;
  cursorAccent: number;
  selection: number;
  selectionInactive: number;
  selectionForeground: number | null;
  /// 256 entries — the 16 of the theme, then the cube and the greys (an app's OSC 4 changes them here).
  ansi: ArrayLike<number>;
}

/// What a cell needs read from it — xterm.js's `CellData` (`buffer.getNullCell()`, filled by `getCell`).
export interface CellLike {
  fg: number;
  bg: number;
  extended?: { underlineStyle: number; underlineColor: number };
  getCode(): number;
  getChars(): string;
  getWidth(): number;
}

/// A colour a decoration sets, rgba.
export interface Override { bg: number | null; fg: number | null }

/// The per-cell flags word (`cells[i * 4 + 1]`) the line shader reads.
export const Flag = {
  /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed (xterm.js's `UnderlineStyle`).
  UNDERLINE_MASK: 0x7,
  STRIKE: 1 << 3,
  OVERLINE: 1 << 4,
  /// 0 none, 1 underline, 2 bar, 3 outline (a block cursor is the cell's colours instead).
  CURSOR_SHIFT: 5,
  CURSOR_MASK: 0x7 << 5,
  /// How many cells the cell's line quad spans (a wide glyph's cursor covers both).
  SPAN_SHIFT: 8,
  /// The background's rounded corners (renderer.ts `cornerMask`): top left, top right, bottom right,
  /// bottom left, from this bit up.
  CORNER_SHIFT: 10,
  CORNER_MASK: 0xf << 10,
  /// The experimental gradient the cell's background takes (webgpu/gradient.ts): 0 none, 1 the diff's green,
  /// 2 its red.
  GRADIENT_SHIFT: 14,
  GRADIENT_MASK: 0x3 << 14,
} as const;

export interface Resolved {
  /// rgba; 0 is the default background (nothing drawn).
  bg: number;
  /// The cell's OWN background is not the default — before the selection (and the cursor) paint over it:
  /// what the rounded corners read (bg-corners.ts's rule).
  filled: boolean;
  fg: number;
  /// The underline's colour (its own when SGR 58 set one).
  underline: number;
  flags: number;
  /// The cell has a glyph to draw (not invisible, not empty).
  glyph: boolean;
  bold: boolean;
  italic: boolean;
}

export function newResolved(): Resolved {
  return { bg: 0, filled: false, fg: 0, underline: 0, flags: 0, glyph: false, bold: false, italic: false };
}

/// A colour attribute (fg, bg or an underline colour) as rgba, or null for its default.
export function attrColor(attr: number, palette: Palette): number | null {
  switch (attr & CM_MASK) {
    case CM_P16:
    case CM_P256: return palette.ansi[attr & 0xff] ?? null;
    case CM_RGB: return (((attr & RGB_MASK) << 8) | 0xff) >>> 0;
    default: return null;
  }
}

const withAlpha = (c: number, a: number) => (((c >>> 8) << 8) | a) >>> 0;

/// Resolve `cell` into `out`. `selected`: the cell is in the selection; `focused`: the terminal has focus
/// (the selection's two colours); `boldBright`: xterm.js's `drawBoldTextInBrightColors`; `bottom` / `top`:
/// the decorations' overrides below and above the selection (null for none).
export function resolveCell(
  cell: CellLike, palette: Palette, selected: boolean, focused: boolean, boldBright: boolean,
  out: Resolved, bottom: Override | null = null, top: Override | null = null,
): Resolved {
  const fgAttr = cell.fg, bgAttr = cell.bg;
  const bold = (fgAttr & FG_BOLD) !== 0;
  let fgSource = fgAttr;
  if (boldBright && bold && (fgAttr & CM_MASK) === CM_P16 && (fgAttr & 0xff) < 8) fgSource = fgAttr + 8;
  const ownFg = attrColor(fgSource, palette);
  const ownBg = attrColor(bgAttr, palette);
  let fg: number, bg: number;
  if (fgAttr & FG_INVERSE) {
    fg = ownBg ?? palette.background;
    bg = ownFg ?? palette.foreground;
  } else {
    fg = ownFg ?? palette.foreground;
    bg = ownBg ?? 0;
  }
  if (bottom?.bg != null) bg = bottom.bg;
  if (bottom?.fg != null) fg = bottom.fg;
  const filled = bg !== 0 || (top?.bg != null);
  if (selected) {
    bg = withAlpha(focused ? palette.selection : palette.selectionInactive, 0xff);
    if (palette.selectionForeground !== null) fg = palette.selectionForeground;
  }
  if (top?.bg != null) bg = top.bg;
  if (top?.fg != null) fg = top.fg;
  if ((bgAttr & BG_DIM) && !selected) fg = withAlpha(fg, 0x80);

  let flags = 0;
  const ext = bgAttr & BG_HAS_EXTENDED ? cell.extended : undefined;
  const style = ext ? ext.underlineStyle : 0;
  if (style !== 0) flags |= style & Flag.UNDERLINE_MASK;
  else if (fgAttr & FG_UNDERLINE) flags |= 1;
  if (fgAttr & FG_STRIKE) flags |= Flag.STRIKE;
  if (bgAttr & BG_OVERLINE) flags |= Flag.OVERLINE;
  const ownUnderline = ext && ext.underlineColor ? attrColor(ext.underlineColor, palette) : null;

  out.bg = bg >>> 0;
  out.filled = filled;
  out.fg = fg >>> 0;
  out.underline = ownUnderline ?? out.fg;
  out.flags = flags;
  out.glyph = (fgAttr & FG_INVISIBLE) === 0 && cell.getCode() !== 0 && cell.getChars() !== " ";
  out.bold = bold;
  out.italic = (bgAttr & BG_ITALIC) !== 0;
  return out;
}

/// xterm.js's selection, as its renderers model it (`SelectionRenderModel`, MIT): rows are BUFFER rows.
export class Selection {
  private start: [number, number] | null = null;
  private end: [number, number] | null = null;
  private column = false;

  update(start: [number, number] | undefined, end: [number, number] | undefined, columnSelectMode: boolean): void {
    if (!start || !end || (start[0] === end[0] && start[1] === end[1])) { this.start = this.end = null; return; }
    this.start = start; this.end = end; this.column = columnSelectMode;
  }

  /// Whether column `x` of buffer row `row` is selected.
  has(x: number, row: number): boolean {
    const s = this.start, e = this.end;
    if (!s || !e) return false;
    if (this.column) {
      const lo = Math.min(s[0], e[0]), hi = Math.max(s[0], e[0]);
      return row >= s[1] && row <= e[1] && x >= lo && x < hi;
    }
    if (row > s[1] && row < e[1]) return true;
    if (s[1] === e[1]) return row === s[1] && x >= s[0] && x < e[0];
    if (row === s[1]) return x >= s[0];
    if (row === e[1]) return x < e[0];
    return false;
  }
}
