import type { Terminal, IDecoration, IMarker, ITheme, IBufferCell } from "@xterm/xterm";
import { ANSI_KEYS, XTERM_DEFAULT_PALETTE, xtermCubeColor } from "./xterm-view";

/// Renders predicted (local-echo) text as an OPAQUE overlay on top of xterm, covering the input cells — so
/// the authoritative buffer underneath (which may be mid-replay of a lagged edit) is hidden. This is Mosh's
/// display model: predictions composite over the framebuffer; the raw echo replay never shows. The overlay
/// is driven from the prediction model (which chars, at which anchor); this module is only the renderer.
///
/// **ITS COLOURS ARE THE TERMINAL'S, CELL BY CELL** (2026-10-01): each predicted character is painted on the
/// background of the cell it covers — the theme's for a default cell, the palette's or the RGB value for a
/// coloured one — in that cell's foreground, dimmed; the block cursor in the theme's cursor colours. They
/// were fixed (`#000000` behind every ghost, `#d0d0d0` for the cursor), which drew a black box over each
/// predicted cell on the dark theme (`#262526`), the light one and any coloured line alike. The foreground
/// is the one xterm.js DRAWS: bold-as-bright and dim included (`resolveCellColors`).
export interface OverlayTheme {
  fontFamily: string;
  fontSize: number;   // px
  cellHeight: number; // px (line height)
}

/// A cell's colour attributes, as xterm.js's `IBufferCell` reports them.
export interface CellColorAttrs {
  fgMode: "default" | "palette" | "rgb"; fg: number;
  bgMode: "default" | "palette" | "rgb"; bg: number;
  inverse: boolean;
  bold: boolean;
  dim: boolean;
}

/// `#rrggbb` for a palette index under `theme`: 0–15 the theme's ANSI colours, 16–255 its extended slots
/// or xterm.js's fixed cube and greys — each falling back to xterm.js's own default, as xterm.js does.
function paletteColor(index: number, theme: ITheme | undefined): string {
  if (index < 16) return theme?.[ANSI_KEYS[index]!] ?? XTERM_DEFAULT_PALETTE.ansi[index] ?? "#000000";
  return theme?.extendedAnsi?.[index - 16] ?? xtermCubeColor(index);
}

const rgbColor = (v: number) => `#${(v & 0xffffff).toString(16).padStart(6, "0")}`;

/// The colours xterm.js paints a cell in, as its DOM renderer decides them (`DomRendererRowFactory.createRow`
/// at `minimumContrastRatio` 1, xterm.js 6): INVERSE swaps foreground and background first, colour and mode
/// alike; then a BOLD cell whose foreground is palette 0–7 is drawn 8–15 when `boldIsBright`
/// (`drawBoldTextInBrightColors`, on by default) — the foreground only; and a DIM cell's text is drawn at
/// half alpha (`fgAlpha`), except an RGB foreground, whose inline colour beats the `.xterm-dim` class.
export function resolveCellColors(a: CellColorAttrs, theme: ITheme | undefined, boldIsBright = true): { fg: string; bg: string; fgAlpha: number } {
  const [fgMode, fgValue, bgMode, bg] = a.inverse ? [a.bgMode, a.bg, a.fgMode, a.fg] : [a.fgMode, a.fg, a.bgMode, a.bg];
  const themeFg = theme?.foreground ?? XTERM_DEFAULT_PALETTE.fg;
  const themeBg = theme?.background ?? XTERM_DEFAULT_PALETTE.bg;
  const fg = fgMode === "palette" && a.bold && boldIsBright && fgValue < 8 ? fgValue + 8 : fgValue;
  return {
    fg: fgMode === "palette" ? paletteColor(fg, theme) : fgMode === "rgb" ? rgbColor(fg) : a.inverse ? themeBg : themeFg,
    bg: bgMode === "palette" ? paletteColor(bg, theme) : bgMode === "rgb" ? rgbColor(bg) : a.inverse ? themeFg : themeBg,
    fgAlpha: a.dim && fgMode !== "rgb" ? 0.5 : 1,
  };
}

/// A cell's colour attributes, read from xterm.js's buffer (absent: a default cell).
export function cellColorAttrs(cell: IBufferCell | undefined): CellColorAttrs {
  if (!cell) return { fgMode: "default", fg: 0, bgMode: "default", bg: 0, inverse: false, bold: false, dim: false };
  const mode = (palette: boolean, rgb: boolean) => (palette ? "palette" as const : rgb ? "rgb" as const : "default" as const);
  return {
    fgMode: mode(cell.isFgPalette(), cell.isFgRGB()), fg: cell.getFgColor(),
    bgMode: mode(cell.isBgPalette(), cell.isBgRGB()), bg: cell.getBgColor(),
    inverse: cell.isInverse() !== 0,
    bold: cell.isBold() !== 0,
    dim: cell.isDim() !== 0,
  };
}

/// `color` at `alpha`, for the ghost TEXT only — the background stays opaque, or the authoritative cell
/// would show through. A colour that is not `#rrggbb` is used as it is.
function dimmed(color: string, alpha: number): string {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(color);
  return m ? `rgba(${parseInt(m[1]!, 16)}, ${parseInt(m[2]!, 16)}, ${parseInt(m[3]!, 16)}, ${alpha})` : color;
}
const GHOST_ALPHA = 0.6;

export class PredictionOverlay {
  private elements: HTMLElement[] = [];
  private decos: IDecoration[] = [];
  private markers: IMarker[] = [];   // one per run; disposing a decoration does NOT dispose its marker

  constructor(private term: Terminal, private theme: OverlayTheme) {}

  /// Show `text` starting at buffer cell (row, col) with a cursor block at the end. Absolute buffer row.
  /// Splits across the terminal width so a wrapped prediction stays aligned, and wherever the covered
  /// cells' colours change, so each predicted character sits on its own cell's background. Re-renders from
  /// scratch (cheap for short input lines). `cursorAtEnd` draws the block cursor after the text.
  ///
  /// The PREVIOUS generation of decorations is disposed a frame LATER (after the new ones have painted),
  /// not synchronously — xterm paints a freshly-registered decoration on its next render cycle, so disposing
  /// the old ones first would leave a one-frame empty gap through which the authoritative buffer (possibly
  /// mid-replay) flashes. Deferring keeps the old covering until the new is up.
  show(row: number, col: number, text: string, cursorAtEnd: boolean, cursorOffset = text.length, pendingCells?: readonly boolean[]): void {
    for (const el of this.elements) el.remove();
    this.elements = [];
    const staleDecos = this.decos, staleMarkers = this.markers;
    this.decos = []; this.markers = [];
    this.disposeNextFrame(staleDecos, staleMarkers);
    const cols = this.term.cols;
    const theme = this.term.options.theme;
    const boldIsBright = this.term.options.drawBoldTextInBrightColors !== false;
    // One decoration per visual row-run of cells that share their colours.
    let r = row, c = col, i = 0;
    let run: { row: number; col: number; text: string; fg: string; bg: string } | null = null;
    const flush = () => { if (run) this.addRun(run.row, run.col, run.text, run.fg, run.bg); run = null; };
    while (i < text.length) {
      if (c >= cols) { flush(); c = 0; r += 1; }   // an anchor in the pending-wrap column (cursorX === cols)
      const { fg, bg, fgAlpha } = resolveCellColors(cellColorAttrs(this.term.buffer.active.getLine(r)?.getCell(c)), theme, boldIsBright);
      const ghost = dimmed(fg, (pendingCells?.[i] === false ? 1 : GHOST_ALPHA) * fgAlpha);
      if (run && run.row === r && run.fg === ghost && run.bg === bg) run.text += text[i];
      else { flush(); run = { row: r, col: c, text: text[i]!, fg: ghost, bg }; }
      i += 1; c += 1;
    }
    flush();
    if (cursorAtEnd) {
      r = row + Math.floor((col + cursorOffset) / cols);
      c = (col + cursorOffset) % cols;
      const cursorBg = theme?.cursor ?? theme?.foreground ?? XTERM_DEFAULT_PALETTE.cursor;
      const cursorFg = theme?.cursorAccent ?? theme?.background ?? XTERM_DEFAULT_PALETTE.bg;
      this.addRun(r, c, text[cursorOffset] ?? " ", cursorFg, cursorBg);   // retain the glyph under an interior cursor
    }
  }

  private addRun(row: number, col: number, text: string, fg: string, bg: string): void {
    // xterm hides its decoration layer in the alternate buffer. Paint directly on
    // its screen using the renderer's measured cell grid (DOM and WebGL alike).
    if (this.term.buffer.active.type === "alternate") {
      const screen = this.term.element?.querySelector<HTMLElement>(".xterm-screen");
      const cell = (this.term as unknown as { _core?: { _renderService?: { dimensions?: {
        css?: { cell?: { width: number; height: number } }
      } } } })._core?._renderService?.dimensions?.css?.cell;
      if (!screen || !cell?.width || !cell.height) return;
      const el = screen.ownerDocument.createElement("div");
      el.className = "prediction-overlay-run";
      el.textContent = text;
      Object.assign(el.style, {
        position: "absolute", left: `${col * cell.width}px`,
        top: `${(row - this.term.buffer.active.viewportY) * cell.height}px`,
        width: `${text.length * cell.width}px`, height: `${cell.height}px`,
        font: `${this.theme.fontSize}px ${this.theme.fontFamily}`,
        lineHeight: `${cell.height}px`, whiteSpace: "pre", overflow: "hidden",
        background: bg, color: fg, zIndex: "10", pointerEvents: "none",
      });
      screen.append(el);
      this.elements.push(el);
      return;
    }
    // Marker is anchored relative to the CURRENT cursor line; offset the target row from it.
    const base = this.term.buffer.active.baseY + this.term.buffer.active.cursorY;
    const marker = this.term.registerMarker(row - base);
    if (!marker) return;
    const deco = this.term.registerDecoration({ marker, x: col, width: text.length, height: 1, layer: "top" });
    if (!deco) { marker.dispose(); return; }
    this.markers.push(marker);
    deco.onRender((el) => {
      const t = this.theme;
      el.textContent = text;
      el.style.font = `${t.fontSize}px ${t.fontFamily}`;
      el.style.lineHeight = `${t.cellHeight}px`;
      el.style.whiteSpace = "pre";
      el.style.overflow = "hidden";
      el.style.boxSizing = "border-box";
      el.style.background = bg;   // opaque → hides the authoritative cell underneath
      el.style.color = fg;
      el.style.zIndex = "10";
    });
    this.decos.push(deco);
  }

  // Clear disposes immediately: the overlay is vanishing (fully confirmed / Enter / passive), and the
  // authoritative buffer underneath already holds the matching text, so there's no gap to bridge.
  clear(): void {
    for (const el of this.elements) el.remove();
    this.elements = [];
    for (const d of this.decos) d.dispose();
    for (const m of this.markers) m.dispose();
    this.decos = [];
    this.markers = [];
  }

  // Dispose a generation of decorations + their markers on the next frame (see show()). Disposing a
  // decoration does NOT dispose its marker, so both are torn down explicitly.
  private disposeNextFrame(decos: IDecoration[], markers: IMarker[]): void {
    if (decos.length === 0 && markers.length === 0) return;
    const raf = typeof requestAnimationFrame === "function" ? requestAnimationFrame : (cb: () => void) => setTimeout(cb, 16);
    raf(() => { for (const d of decos) d.dispose(); for (const m of markers) m.dispose(); });
  }

  dispose(): void { this.clear(); }
}
