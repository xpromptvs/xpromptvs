import { contextFor, type ClientContext } from "../instance/context";
import type { IBufferCell, Terminal } from "@xterm/xterm";
import { GlyphAtlas, type AtlasFont } from "./atlas";
import { Flag, Selection, newResolved, resolveCell, type CellLike, type Override, type Palette } from "./cell-model";
import { onGpuLost, readyGpu, requestGpu } from "./device";
import { GRADIENT_DEFAULTS, GRADIENT_SOURCES, gradientTuning, hexToHsl, hexToRgba, type GradientTuning, type Hsl } from "./gradient";
import { TERMINAL_WGSL } from "./shaders";
import { claimCanvas, surfaceFor, type GpuSurface } from "./surface";
import { BG_CORNER_RADIUS_PX } from "../bg-corners";
import { clipBox, overscanCount } from "../overscan-rows";

/// **AN OPTIONAL xterm.js RENDERER ON WEBGPU** (docs/superpowers/specs/2026-10-03-gpu-terminal-renderer-spike.md:
/// the DOM renderer's per-frame work, 5–22 ms, drops to 1–2 ms on a GPU). It is installed the way xterm.js's
/// own WebGL addon installs its renderer — `_renderService.setRenderer` — and implements the same contract
/// (`IRenderer`: `dimensions`, `onRequestRedraw`, `renderRows` and the handlers), so xterm.js keeps its
/// buffer, parser, selection, mouse and scrolling and asks this only to DRAW. The DOM renderer comes back
/// whenever this cannot draw: no hardware adapter, xterm.js's internals not as expected, or the device lost.
///
/// - **ONE device, one glyph atlas per font, three pipelines — shared by every terminal** (device.ts,
///   atlas.ts). Each terminal owns its instance buffers; the CANVAS is its area's, one for every terminal in
///   it (surface.ts), and only the terminal whose view claimed it draws — nothing synchronizes a DOM change
///   with a WebGPU frame, so a switch or a snapshot's swap changes what is drawn, never which canvas shows.
/// - **Cells are the DOM renderer's size** — fractional, `charSizeService.width × dpr` — so changing renderer
///   never changes the grid the host is told. Column x positions are rounded once, in `colX`, and the shader
///   reads them (shaders.ts).
/// - Every frame redraws the whole viewport from the instance buffers; `renderRows` rebuilds only the rows
///   xterm.js says changed (a full rebuild when the atlas was cleared under them).
/// - **The MODEL is the screen's rows plus the lines beyond each edge** (model row m is buffer row
///   ydisp + m - above). With smooth scrolling on, the canvas reaches past each edge as far as the clip box
///   — `overscan-rows.ts`'s own count (`overscanCount`: enough rows to reach the clip edge, plus the one a
///   shift uncovers, measured against `clipBox`, re-measured when the terminal or the clip box resizes) — and
///   draws them: the lines a glide brings in, and the inset they fill at rest. ONE row each side was not
///   enough: xterm.js draws the ROUNDED row, so the shift is up to half a row, and a line leaving the screen
///   vanished at its MIDDLE wherever the inset was taller than that (2026-10-03). Off, none are drawn. Only
///   lines that EXIST are read: xterm.js's line list is circular and `getLine` checks nothing.
/// - **Background blocks round their outer corners** (bg-corners.ts's rule, per cell: a corner rounds when
///   both neighbours at it — beside, and above or below — have the default background; a selected or
///   cursor cell stays square). A row's corners depend on its neighbours, so a changed row recomputes the
///   rows either side of it too; the lines beyond the screen are real neighbours, so a block crossing the
///   edge stays one block.
/// - **A box's light corners round with half the blocks' radius** (`┌ ┐ └ ┘` and `╭ ╮ ╰ ╯`, box-corners.ts — the
///   atlas draws them; the buffer, and so a copy, keep the character).
/// - **EXPERIMENTAL: the diff's green and red as gradients** (`setBackgroundGradient`, Terminal Settings →
///   Gradient backgrounds, on by default): a cell drawn in one of the two colours (webgpu/gradient.ts
///   `GRADIENT_SOURCES`) takes the blend of that colour's STORED top and bottom colours by where it sits in the
///   AREA, not in its block — so a line changes as it scrolls, as iMessage's bubbles do. Per pixel in the
///   background pass, in HSL, dithered (shaders.ts `blend`, `dither`); which colour a cell takes is decided by
///   the colour DRAWN, so a selected cell or the block cursor never takes one. Every other colour stays flat.

interface Disposable { dispose(): void }
type Ev<T> = (listener: (e: T) => void) => Disposable;
interface IColor { css: string; rgba: number }
interface ThemeColors {
  foreground: IColor; background: IColor; cursor: IColor; cursorAccent: IColor;
  selectionBackgroundOpaque: IColor; selectionInactiveBackgroundOpaque: IColor; selectionForeground?: IColor;
  ansi: IColor[];
}
interface Decoration { backgroundColorRGB?: IColor; foregroundColorRGB?: IColor }
/// A link under the pointer (xterm.js's `ILinkifierEvent`): SCREEN rows, which may run off it; `x2` exclusive.
interface LinkEvent { x1: number; y1: number; x2: number; y2: number; cols: number }
interface RenderOptions {
  fontFamily: string; fontSize: number; fontWeight: string | number; fontWeightBold: string | number;
  letterSpacing: number; lineHeight: number; cursorStyle?: string; cursorInactiveStyle?: string; cursorWidth?: number;
  cursorBlink?: boolean; drawBoldTextInBrightColors?: boolean;
}
export interface RenderDimensions {
  css: { canvas: { width: number; height: number }; cell: { width: number; height: number } };
  device: {
    canvas: { width: number; height: number }; cell: { width: number; height: number };
    char: { width: number; height: number; left: number; top: number };
  };
}

/// The PRIVATE parts of xterm.js 6 this reads — the WebGL addon's own list. `privateCore` checks every one.
interface Core {
  screenElement: HTMLElement;
  _renderService: { setRenderer(r: unknown): void; handleResize(cols: number, rows: number): void };
  _createRenderer(): unknown;
  _charSizeService: { width: number; height: number; hasValidSize: boolean };
  _coreBrowserService: { dpr: number; isFocused: boolean };
  coreService: { isCursorInitialized: boolean; isCursorHidden: boolean; decPrivateModes: { cursorStyle?: string; cursorBlink?: boolean } };
  _themeService: { colors: ThemeColors; onChangeColors: Ev<unknown> };
  optionsService: { rawOptions: RenderOptions; onOptionChange: Ev<string> };
  _decorationService: { forEachDecorationAtCell(x: number, y: number, layer: "bottom" | "top", cb: (d: Decoration) => void): void };
  /// Optional: without it a hovered link is simply not underlined.
  linkifier?: { onShowLinkUnderline?: Ev<LinkEvent>; onHideLinkUnderline?: Ev<LinkEvent> };
}

export function privateCore(term: Terminal): Core | null {
  const c = (term as unknown as { _core?: Partial<Core> })._core;
  if (!c || !(c.screenElement instanceof HTMLElement) || typeof c._renderService?.setRenderer !== "function"
    || typeof c._createRenderer !== "function" || typeof c._charSizeService?.width !== "number"
    || typeof c._coreBrowserService?.dpr !== "number" || typeof c.coreService?.decPrivateModes !== "object"
    || !c._themeService?.colors || typeof c._themeService.onChangeColors !== "function"
    || !c.optionsService?.rawOptions || typeof c.optionsService.onOptionChange !== "function"
    || typeof c._decorationService?.forEachDecorationAtCell !== "function") return null;
  return c as Core;
}

// ------------------------------------------------------------------------------------------ shared state

interface Shared {
  device: GPUDevice;
  format: GPUTextureFormat;
  layout: GPUBindGroupLayout;
  bg: GPURenderPipeline;
  glyph: GPURenderPipeline;
  line: GPURenderPipeline;
  atlases: Map<string, GlyphAtlas>;
  redraws: Set<() => void>;
}
const sharedByDevice = new WeakMap<GPUDevice, Shared>();

function sharedFor(device: GPUDevice): Shared {
  const hit = sharedByDevice.get(device);
  if (hit) return hit;
  const format = navigator.gpu.getPreferredCanvasFormat();
  const module = device.createShaderModule({ code: TERMINAL_WGSL });
  const V = GPUShaderStage.VERTEX, F = GPUShaderStage.FRAGMENT;
  const layout = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: V | F, buffer: { type: "uniform" } },
      { binding: 1, visibility: V, buffer: { type: "read-only-storage" } },
      { binding: 2, visibility: V, buffer: { type: "read-only-storage" } },
      { binding: 3, visibility: V, buffer: { type: "read-only-storage" } },
      { binding: 4, visibility: F, texture: { sampleType: "float" } },
    ],
  });
  const pipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [layout] });
  const blend: GPUBlendState = {
    color: { srcFactor: "one", dstFactor: "one-minus-src-alpha" },
    alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha" },
  };
  const make = (vs: string, fs: string) => device.createRenderPipeline({
    layout: pipelineLayout,
    vertex: { module, entryPoint: vs },
    fragment: { module, entryPoint: fs, targets: [{ format, blend }] },
    primitive: { topology: "triangle-list" },
  });
  const s: Shared = {
    device, format, layout, bg: make("bgVs", "bgFs"), glyph: make("glyphVs", "glyphFs"), line: make("lineVs", "lineFs"),
    atlases: new Map(), redraws: new Set(),
  };
  sharedByDevice.set(device, s);
  // A font that finishes loading after glyphs were rasterized drew them in a fallback: start over.
  document.fonts?.addEventListener?.("loadingdone", () => {
    for (const a of s.atlases.values()) a.clear();
    for (const redraw of s.redraws) redraw();
  });
  return s;
}

function atlasFor(s: Shared, font: AtlasFont): GlyphAtlas {
  const key = `${font.family}|${font.size}|${font.weight}|${font.weightBold}|${font.dpr}|${font.cellH}`;
  let atlas = s.atlases.get(key);
  if (!atlas) { atlas = new GlyphAtlas(s.device, font); s.atlases.set(key, atlas); }
  return atlas;
}

const BLINK_MS = 600;               // xterm.js's own cursor blink interval
const UNIFORM_BYTES = 128;

/// The two colours that take the gradient, as a cell's background is packed (0xRRGGBBAA).
const GREEN = hexToRgba(GRADIENT_SOURCES.green), RED = hexToRgba(GRADIENT_SOURCES.red);

/// The experimental gradient is on, and its stored colours (and as HSL, for the uniforms) — one value for every
/// terminal on the page.
let backgroundGradient = true;
let gradient: GradientTuning = gradientTuning(GRADIENT_DEFAULTS);
const defaultGradientHsl = stopsHsl(gradient);
let gradientHsl = defaultGradientHsl;
const renderers = new Set<WebgpuRenderer>();

function stopsHsl(t: GradientTuning): Hsl[] {
  return [t.green.top, t.green.bottom, t.red.top, t.red.bottom].map(hexToHsl);
}

/// EXPERIMENTAL: the diff's green and red drawn as gradients anchored to the terminal area (shaders.ts `blend`);
/// every WebGPU terminal redraws. The DOM renderer draws none.
export function setBackgroundGradient(on: boolean): void {
  if (on === backgroundGradient) return;
  backgroundGradient = on;
  for (const r of renderers) if (!r.clientContext) r.redrawEverything();
}
export function backgroundGradientEnabled(): boolean { return backgroundGradient; }

/// The gradient's stored colours (gradient.ts: `GRADIENT_DEFAULTS` until changed — the design workbench picks
/// them); every WebGPU terminal redraws.
export function setBackgroundGradientTuning(t: GradientTuning): void {
  gradient = gradientTuning(t);
  gradientHsl = stopsHsl(gradient);
  for (const r of renderers) if (!r.clientContext) r.redrawEverything();
}
export function backgroundGradientTuning(): GradientTuning { return gradientTuning(gradient); }

function emptyDimensions(): RenderDimensions {
  return {
    css: { canvas: { width: 0, height: 0 }, cell: { width: 0, height: 0 } },
    device: { canvas: { width: 0, height: 0 }, cell: { width: 0, height: 0 }, char: { width: 0, height: 0, left: 0, top: 0 } },
  };
}

// --------------------------------------------------------------------------------------------- renderer

export class WebgpuRenderer {
  readonly clientContext: ClientContext | undefined;
  readonly dimensions: RenderDimensions = emptyDimensions();
  private readonly redrawListeners = new Set<(e: { start: number; end: number }) => void>();
  readonly onRequestRedraw: Ev<{ start: number; end: number }> = (listener) => {
    this.redrawListeners.add(listener);
    return { dispose: () => { this.redrawListeners.delete(listener); } };
  };

  private readonly device: GPUDevice;
  /// The area's one canvas (surface.ts); drawn into only while this terminal's view owns it.
  private readonly surface: GpuSurface;
  /// Where the screen's top-left sits in that canvas, device px (`measureOrigin`).
  private originX = 0;
  private originY = 0;
  /// The area's height in device px — the experimental gradient's span (`measureOrigin`).
  private areaH = 0;
  private readonly uniformData = new ArrayBuffer(UNIFORM_BYTES);
  private readonly uniformF32 = new Float32Array(this.uniformData);
  private readonly uniformU32 = new Uint32Array(this.uniformData);
  private readonly uniforms: GPUBuffer;
  private colX = new Uint32Array(1);
  private cellData = new Uint32Array(0);
  private glyphData = new Uint32Array(0);
  private colXBuffer: GPUBuffer | null = null;
  private cellBuffer: GPUBuffer | null = null;
  private glyphBuffer: GPUBuffer | null = null;
  private bindGroup: GPUBindGroup | null = null;
  private bound: GlyphAtlas | null = null;
  private atlas: GlyphAtlas | null = null;
  private atlasGen = -1;
  private cols = 0;
  private rows = 0;
  /// Model rows: the lines above the screen, the screen's, the lines below it (`overscanCount` each edge).
  private mrows = 0;
  private above = 0;
  private below = 0;
  /// The edges must be measured again before the next frame (a resize of the terminal or its clip box).
  private edgeStale = true;
  /// Rows past the overscan cap drawn above the screen while a held resize has moved it down (`relayout`).
  private extraAbove = 0;
  private edgeWatch: ResizeObserver | null = null;
  private watchedClip: HTMLElement | null = null;
  /// Smooth scrolling is on: the lines beyond the screen are drawn.
  private overscan = false;
  /// Smooth scrolling's fractional shift, in CSS px (whole device px), drawn by THIS renderer (`setShift`).
  private shift = 0;
  /// Per model cell: its own background is not the default; it is drawn square (selected, the cursor).
  private filled = new Uint8Array(0);
  private square = new Uint8Array(0);
  private palette: Palette;
  private readonly selection = new Selection();
  private readonly resolved = newResolved();
  private readonly cell: IBufferCell & CellLike;
  private readonly bottom: Override = { bg: null, fg: null };
  private readonly top: Override = { bg: null, fg: null };
  /// The link under the pointer — underlined while it is (the DOM renderer's `_setCellUnderline`).
  private link: LinkEvent | null = null;
  private blinkVisible = true;
  private blinkTimer: ReturnType<typeof setInterval> | null = null;
  private readonly disposables: Disposable[] = [];
  private readonly redrawAll = () => this.requestRedraw(0, this.term.rows - 1);
  private disposed = false;

  constructor(private readonly term: Terminal, private readonly core: Core, private readonly shared: Shared, overscan: boolean,
              host: HTMLElement, private readonly token: object) {
    this.clientContext = contextFor(host);
    if (this.clientContext) {
      const off = this.clientContext.onPreference(key => { if (key === "rdev.terminalBgGradient") this.redrawAll(); });
      this.disposables.push({dispose: off});
    }
    this.overscan = overscan;
    this.device = shared.device;
    this.surface = surfaceFor(host, this.device, shared.format);
    this.uniforms = this.device.createBuffer({ size: UNIFORM_BYTES, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    this.cell = term.buffer.active.getNullCell() as IBufferCell & CellLike;
    this.palette = this.readPalette();
    // Its background lets the canvas UNDER it through (style.css `.xterm-gpu`).
    term.element?.classList.add("xterm-gpu");
    this.surface.attach(token, { claimed: () => this.drawAll(), hostResized: () => { this.edgeStale = true; this.drawAll(); } });
    this.disposables.push(core._themeService.onChangeColors(() => { this.palette = this.readPalette(); this.redrawAll(); }));
    this.disposables.push(core.optionsService.onOptionChange(() => { this.handleResize(this.term.cols, this.term.rows); this.updateBlink(); }));
    shared.redraws.add(this.redrawAll);
    renderers.add(this);
    const lk = core.linkifier;
    const redrawLink = (e: LinkEvent) => this.requestRedraw(Math.max(0, e.y1), Math.min(this.term.rows - 1, e.y2));
    if (typeof lk?.onShowLinkUnderline === "function" && typeof lk.onHideLinkUnderline === "function") {
      this.disposables.push(lk.onShowLinkUnderline((e) => { this.link = e; redrawLink(e); }));
      this.disposables.push(lk.onHideLinkUnderline((e) => { this.link = null; redrawLink(e); }));
    }
    this.handleResize(term.cols, term.rows);
    this.updateBlink();
  }

  // ---- the IRenderer contract --------------------------------------------------------------------------

  /// A new device pixel ratio (another display): the area's canvas starts its buffer again at it — the canvas
  /// maps its buffer to CSS px by the ratio it was sized at, so drawing at the new one would be the wrong scale.
  handleDevicePixelRatioChange(): void { this.surface.grow(); this.handleResize(this.term.cols, this.term.rows); }
  handleCharSizeChanged(): void { this.handleResize(this.term.cols, this.term.rows); }

  handleResize(cols: number, rows: number): void {
    if (this.disposed) return;
    this.updateDimensions(cols, rows);
    this.redrawAll();
  }

  handleBlur(): void { this.updateBlink(); this.redrawAll(); }
  handleFocus(): void { this.updateBlink(); this.redrawAll(); }

  handleSelectionChanged(start: [number, number] | undefined, end: [number, number] | undefined, columnSelectMode: boolean): void {
    this.selection.update(start, end, columnSelectMode);
    this.redrawAll();
  }

  handleCursorMove(): void { this.restartBlink(); }

  /// **THE SMOOTH SCROLL'S SHIFT IS DRAWN, NOT A CSS TRANSFORM** (2026-10-03): `px` moves every row (the
  /// `originY` of all three passes) where the DOM renderer has `.xterm-screen` translated — xterm-view.ts
  /// routes the offset here while this renderer draws. WebKit on iOS showed the canvas's new frame a frame
  /// AFTER a transform written with it, so at every row crossing the transform for the new row sat over the
  /// old rows — on a flick, every other frame a row off (reported on an iPhone). Drawn, the canvas alone says
  /// where the text is, so the two cannot disagree. The draw reuses what was filled: only the origin moves.
  setShift(px: number): void {
    if (px === this.shift) return;
    this.shift = px;
    if (this.disposed || !this.ready() || !this.surface.owns(this.token)) return;
    const atlas = this.atlas;
    if (atlas && this.atlasGen === atlas.generation && !this.edgeStale) this.draw(atlas);
    else this.redrawAll();
  }

  /// The picture was moved by a held resize (xterm-view.ts's `holdShift`, a transform on `.xterm`): where the screen
  /// sits is read again, and `extraAbove` rows past the cap are drawn above it — the gap a grow opens, filled
  /// from the scrollback as the host's snapshot will fill it.
  relayout(extraAbove: number): void {
    this.extraAbove = Math.max(0, extraAbove);
    this.edgeStale = true;
    this.drawAll();
  }

  /// Smooth scrolling turned on or off: the lines beyond the screen are drawn, or not.
  setOverscan(on: boolean): void {
    if (on === this.overscan) return;
    this.overscan = on;
    this.edgeStale = true;
    this.handleResize(this.term.cols, this.term.rows);
  }

  clear(): void {
    this.cellData.fill(0);
    this.glyphData.fill(0);
    this.filled.fill(0);
    this.square.fill(0);
    this.restartBlink();
    this.redrawAll();
  }

  clearTextureAtlas(): void { this.atlas?.clear(); this.redrawAll(); }

  /// Every row, at xterm.js's next frame (a page-wide drawing option changed).
  redrawEverything(): void { this.redrawAll(); }

  /// Its view claimed the canvas, or the area resized: everything, NOW — measured where it sits, every row
  /// refilled (a terminal that did not own the canvas kept nothing current).
  private drawAll(): void {
    if (this.disposed || !this.surface.owns(this.token)) return;
    this.measureOrigin();
    this.atlasGen = -1;
    this.renderRows(0, this.term.rows - 1);
  }

  renderRows(start: number, end: number): void {
    if (this.disposed || !this.ready()) return;
    // Not the canvas's: nothing drawn, and every row stale for the claim that makes it so.
    if (!this.surface.owns(this.token)) { this.atlasGen = -1; return; }
    const atlas = this.ensureAtlas();
    if (!atlas) return;
    if (this.edgeStale) this.updateDimensions(this.cols, this.rows);   // a resize moved the clip edges
    // Model rows: the screen's start..end, `above` down; the lines beyond the screen are refilled every frame
    // (output below a scrolled-back screen changes the lines after it, and xterm.js redraws no screen row).
    const A = this.above, last = this.mrows - 1, firstBelow = A + this.rows;
    let from = Math.max(0, start) + A, to = Math.min(this.rows - 1, end) + A;
    if (this.atlasGen !== atlas.generation) { from = 0; to = last; }
    let gen = atlas.generation;
    const fill = () => {
      this.fillRows(from, to, atlas);
      if (A > 0 && from > 0) this.fillRows(0, A - 1, atlas);
      if (firstBelow <= last && to < last) this.fillRows(firstBelow, last, atlas);
    };
    fill();
    if (atlas.generation !== gen) {         // the atlas filled up mid-frame: what was placed before is gone
      gen = atlas.generation;
      from = 0; to = last;
      fill();
    }
    this.atlasGen = gen;
    // Corners read the rows either side; the lines beyond the screen are always refilled.
    const a = Math.max(0, from - 1), b = Math.min(last, to + 1);
    this.corners(a, b);
    this.upload(a, b);
    if (A > 0 && a > 0) { this.corners(0, A); this.upload(0, A); }
    if (firstBelow <= last && b < last) { this.corners(firstBelow - 1, last); this.upload(firstBelow - 1, last); }
    this.draw(atlas);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    if (this.blinkTimer !== null) clearInterval(this.blinkTimer);
    this.edgeWatch?.disconnect();
    for (const d of this.disposables) d.dispose();
    this.shared.redraws.delete(this.redrawAll);
    renderers.delete(this);
    this.redrawListeners.clear();
    this.term.element?.classList.remove("xterm-gpu");
    this.surface.detach(this.token);
    this.core.screenElement.style.width = "";
    this.core.screenElement.style.height = "";
    this.uniforms.destroy();
    this.colXBuffer?.destroy();
    this.cellBuffer?.destroy();
    this.glyphBuffer?.destroy();
  }

  // ---- internals -----------------------------------------------------------------------------------------

  private requestRedraw(start: number, end: number): void {
    for (const listener of this.redrawListeners) listener({ start, end });
  }

  private ready(): boolean {
    return this.core.screenElement.isConnected && this.core._charSizeService.hasValidSize
      && this.dimensions.device.cell.width > 0 && this.cols > 0 && this.mrows > 0;
  }

  private readPalette(): Palette {
    const c = this.core._themeService.colors;
    return {
      foreground: c.foreground.rgba >>> 0, background: c.background.rgba >>> 0,
      cursor: c.cursor.rgba >>> 0, cursorAccent: c.cursorAccent.rgba >>> 0,
      selection: c.selectionBackgroundOpaque.rgba >>> 0, selectionInactive: c.selectionInactiveBackgroundOpaque.rgba >>> 0,
      selectionForeground: c.selectionForeground ? c.selectionForeground.rgba >>> 0 : null,
      ansi: Uint32Array.from(c.ansi, (x) => x.rgba >>> 0),
    };
  }

  /// The DOM renderer's arithmetic (`DomRenderer._updateDimensions`), so both renderers lay out one grid.
  private updateDimensions(cols: number, rows: number): void {
    const cs = this.core._charSizeService, o = this.core.optionsService.rawOptions;
    const dpr = this.core._coreBrowserService.dpr, d = this.dimensions;
    if (!cs.width || !cs.height || cols <= 0 || rows <= 0) return;
    d.device.char.width = cs.width * dpr;
    d.device.char.height = Math.ceil(cs.height * dpr);
    d.device.cell.width = d.device.char.width + Math.round(o.letterSpacing);
    d.device.cell.height = Math.floor(d.device.char.height * o.lineHeight);
    d.device.char.left = 0;
    d.device.char.top = 0;
    d.device.canvas.width = d.device.cell.width * cols;
    d.device.canvas.height = d.device.cell.height * rows;
    d.css.canvas.width = Math.round(d.device.canvas.width / dpr);
    d.css.canvas.height = Math.round(d.device.canvas.height / dpr);
    d.css.cell.width = d.css.canvas.width / cols;
    d.css.cell.height = d.css.canvas.height / rows;

    const edges = this.measureEdges(rows, d.css.cell.height);
    const resized = cols !== this.cols || rows !== this.rows || edges.above !== this.above || edges.below !== this.below;
    this.cols = cols; this.rows = rows; this.above = edges.above; this.below = edges.below;
    this.mrows = this.above + rows + this.below;
    this.colX = new Uint32Array(cols + 1);
    for (let i = 0; i <= cols; i++) this.colX[i] = Math.round(i * d.device.cell.width);
    this.core.screenElement.style.width = `${d.css.canvas.width}px`;
    this.core.screenElement.style.height = `${d.css.canvas.height}px`;
    this.measureOrigin();

    const n = cols * this.mrows;
    if (resized || this.cellData.length !== n * 4) {
      this.cellData = new Uint32Array(n * 4);
      this.glyphData = new Uint32Array(n * 4);
      this.filled = new Uint8Array(n);
      this.square = new Uint8Array(n);
      this.cellBuffer?.destroy();
      this.glyphBuffer?.destroy();
      const usage = GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST;
      this.cellBuffer = this.device.createBuffer({ size: Math.max(16, n * 16), usage });
      this.glyphBuffer = this.device.createBuffer({ size: Math.max(16, n * 16), usage });
    }
    this.colXBuffer?.destroy();
    this.colXBuffer = this.device.createBuffer({ size: Math.max(16, (cols + 1) * 4), usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    this.device.queue.writeBuffer(this.colXBuffer, 0, this.colX);
    this.bindGroup = null;
    this.atlasGen = -1;
  }

  /// How many lines beyond each edge to draw: `overscan-rows.ts`'s rule against the same clip box, the screen
  /// measured where it sits UNSHIFTED (its transform is the smooth scroll's fraction, not layout). None with
  /// smooth scrolling off. Watches the terminal and its clip box, so a layout change re-measures.
  private measureEdges(rows: number, cellCss: number): { above: number; below: number } {
    this.edgeStale = false;
    const el = this.term.element;
    if (!this.overscan || !el || !(cellCss > 0)) return { above: 0, below: 0 };
    const clip = clipBox(el);
    if (!clip) return { above: 0, below: 0 };
    if (this.watchedClip !== clip && typeof ResizeObserver === "function") {
      this.edgeWatch?.disconnect();
      this.edgeWatch = new ResizeObserver(() => { this.edgeStale = true; this.redrawAll(); });
      this.edgeWatch.observe(el);
      this.edgeWatch.observe(clip);
      this.watchedClip = clip;
    }
    const screen = this.core.screenElement, view = el.ownerDocument.defaultView;
    const t = view?.getComputedStyle(screen).transform;
    const shift = t && t !== "none" && view?.DOMMatrixReadOnly ? new view.DOMMatrixReadOnly(t).m42 : 0;
    const top = screen.getBoundingClientRect().top - shift;
    const c = clip.getBoundingClientRect();
    const clipTop = c.top + clip.clientTop, clipBottom = clipTop + clip.clientHeight;
    return { above: overscanCount(top - clipTop, cellCss, this.extraAbove), below: overscanCount(clipBottom - (top + rows * cellCss), cellCss) };
  }

  /// Where the screen's top-left sits in the area's canvas, in whole device px — read from layout, so only
  /// when it can have moved (a claim, a resize of the grid or the area), never per frame. The smooth scroll's
  /// shift is not a transform on this path (`setShift`), so the screen's box is where its rows sit at rest.
  private measureOrigin(): void {
    const s = this.core.screenElement.getBoundingClientRect(), c = this.surface.canvas.getBoundingClientRect();
    const dpr = this.core._coreBrowserService.dpr;
    // Rects include ancestor transforms (the landing phone is scaled), while
    // drawing-buffer coordinates do not. Map through the canvas itself so the
    // DOM-to-GPU handoff preserves the same text inset.
    const pxX = c.width > 0 ? this.surface.canvas.width / c.width : dpr;
    const pxY = c.height > 0 ? this.surface.canvas.height / c.height : dpr;
    this.originX = Math.round((s.left - c.left) * pxX);
    this.originY = Math.round((s.top - c.top) * pxY);
    this.areaH = Math.round(this.surface.host.clientHeight * dpr);
  }

  private ensureAtlas(): GlyphAtlas | null {
    const o = this.core.optionsService.rawOptions, d = this.dimensions;
    if (d.device.cell.height <= 0) return null;
    const atlas = atlasFor(this.shared, {
      family: o.fontFamily, size: o.fontSize, weight: o.fontWeight, weightBold: o.fontWeightBold,
      dpr: this.core._coreBrowserService.dpr, cellH: d.device.cell.height,
    });
    if (atlas !== this.atlas) { this.atlas = atlas; this.atlasGen = -1; this.bindGroup = null; }
    return atlas;
  }

  private cursorStyle(): string {
    const o = this.core.optionsService.rawOptions;
    if (!this.core._coreBrowserService.isFocused) return o.cursorInactiveStyle ?? "outline";
    return this.core.coreService.decPrivateModes.cursorStyle ?? o.cursorStyle ?? "block";
  }

  /// Fill MODEL rows `start`…`end` (model row m is buffer row ydisp + m - 1).
  private fillRows(start: number, end: number, atlas: GlyphAtlas): void {
    const buf = this.term.buffer.active, cols = this.cols, colX = this.colX;
    const cells = this.cellData, glyphs = this.glyphData, palette = this.palette, cell = this.cell;
    const filled = this.filled, square = this.square, A = this.above, firstBelow = A + this.rows;
    const core = this.core, focused = core._coreBrowserService.isFocused;
    const boldBright = core.optionsService.rawOptions.drawBoldTextInBrightColors !== false;
    const ydisp = buf.viewportY;
    const cursorRow = buf.baseY + buf.cursorY;
    const cursorX = Math.min(buf.cursorX, cols - 1);
    const cursorOn = core.coreService.isCursorInitialized && !core.coreService.isCursorHidden && this.blinkVisible;
    const style = this.cursorStyle();
    const shape = style === "underline" ? 1 : style === "bar" ? 2 : style === "outline" ? 3 : 0;
    const decorations = core._decorationService;
    const bottom = this.bottom, top = this.top;
    const takeBottom = (d: Decoration) => {
      if (d.backgroundColorRGB) bottom.bg = d.backgroundColorRGB.rgba >>> 0;
      if (d.foregroundColorRGB) bottom.fg = d.foregroundColorRGB.rgba >>> 0;
    };
    const takeTop = (d: Decoration) => {
      if (d.backgroundColorRGB) top.bg = d.backgroundColorRGB.rgba >>> 0;
      if (d.foregroundColorRGB) top.fg = d.foregroundColorRGB.rgba >>> 0;
    };
    for (let y = start; y <= end; y++) {
      const row = y + ydisp - A;
      const beyond = y < A || y >= firstBelow;
      // BOUNDED, as overscan-rows.ts is: xterm.js's line list is CIRCULAR and `getLine` checks nothing, so a
      // row off the buffer wraps — the alternate screen (exactly `rows` lines) drew its TOP line in the
      // inset below the screen (Codex full screen, 2026-10-03), and a full scrollback its oldest line.
      const line = (beyond && !this.overscan) || row < 0 || row >= buf.length ? undefined : buf.getLine(row);
      let cursorEnd = -1;
      for (let x = 0; x < cols; x++) {
        const k = y * cols + x, i = k * 4;
        if (!line) { cells.fill(0, i, i + 4); glyphs.fill(0, i, i + 4); filled[k] = 0; square[k] = 0; continue; }
        line.getCell(x, cell);
        const width = cell.getWidth();
        bottom.bg = bottom.fg = top.bg = top.fg = null;
        decorations.forEachDecorationAtCell(x, row, "bottom", takeBottom);
        decorations.forEachDecorationAtCell(x, row, "top", takeTop);
        const r = resolveCell(cell, palette, this.selection.has(x, row), focused, boldBright, this.resolved,
          bottom.bg !== null || bottom.fg !== null ? bottom : null, top.bg !== null || top.fg !== null ? top : null);
        let bg = r.bg, fg = r.fg, flags = r.flags;
        if (this.link && inLink(this.link, x, y - A)) flags = (flags & ~Flag.UNDERLINE_MASK) | 1;
        let isSquare = this.selection.has(x, row);
        if (cursorOn && row === cursorRow) {
          if (x === cursorX) cursorEnd = x + Math.max(1, width) - 1;
          if (x >= cursorX && x <= cursorEnd) {
            isSquare = true;
            if (style === "block") { bg = palette.cursor; fg = palette.cursorAccent; }
            else if (x === cursorX && shape !== 0) {
              flags |= (shape << Flag.CURSOR_SHIFT) | (Math.max(1, width) << Flag.SPAN_SHIFT);
            }
          }
        }
        // The diff's green and red take their gradient — by the colour DRAWN, so a selected cell or the block
        // cursor (the UI's colours) never does.
        const slot = bg === GREEN ? 1 : bg === RED ? 2 : 0;
        if (slot) flags |= slot << Flag.GRADIENT_SHIFT;
        cells[i] = bg; cells[i + 1] = flags; cells[i + 2] = fg; cells[i + 3] = r.underline;
        filled[k] = r.filled ? 1 : 0;
        square[k] = isSquare ? 1 : 0;
        if (r.glyph && width > 0) {
          const g = atlas.get(cell.getChars(), r.bold, r.italic, colX[Math.min(x + width, cols)]! - colX[x]!);
          glyphs[i] = g.x | (g.y << 16);
          glyphs[i + 1] = (g.w | (g.h << 16) | (g.color ? 0x80000000 : 0)) >>> 0;
          glyphs[i + 2] = ((g.left & 0xffff) | ((g.top & 0xffff) << 16)) >>> 0;
          glyphs[i + 3] = fg;
        } else {
          glyphs[i] = 0; glyphs[i + 1] = 0; glyphs[i + 2] = 0; glyphs[i + 3] = 0;
        }
      }
    }
  }

  /// The rounded corners of model rows `start`…`end` (bg-corners.ts's rule), into each cell's flags. Off
  /// the model counts as the default background.
  private corners(start: number, end: number): void {
    const cols = this.cols, mrows = this.mrows, filled = this.filled, square = this.square, cells = this.cellData;
    const f = (x: number, y: number) => x >= 0 && x < cols && y >= 0 && y < mrows && filled[y * cols + x] === 1;
    for (let y = start; y <= end; y++) {
      for (let x = 0; x < cols; x++) {
        const k = y * cols + x, i = k * 4 + 1;
        let mask = 0;
        if (filled[k] === 1 && square[k] === 0) {
          const left = !f(x - 1, y), right = !f(x + 1, y), up = !f(x, y - 1), down = !f(x, y + 1);
          mask = (left && up ? 1 : 0) | (right && up ? 2 : 0) | (right && down ? 4 : 0) | (left && down ? 8 : 0);
        }
        cells[i] = ((cells[i]! & ~Flag.CORNER_MASK) | (mask << Flag.CORNER_SHIFT)) >>> 0;
      }
    }
  }

  private upload(from: number, to: number): void {
    if (!this.cellBuffer || !this.glyphBuffer || to < from) return;
    const at = from * this.cols * 4, n = (to - from + 1) * this.cols * 4;
    this.device.queue.writeBuffer(this.cellBuffer, at * 4, this.cellData, at, n);
    this.device.queue.writeBuffer(this.glyphBuffer, at * 4, this.glyphData, at, n);
  }

  private draw(atlas: GlyphAtlas): void {
    if (!this.cellBuffer || !this.glyphBuffer || !this.colXBuffer || !this.surface.owns(this.token)) return;
    if (!this.bindGroup || this.bound !== atlas) {
      this.bindGroup = this.device.createBindGroup({
        layout: this.shared.layout,
        entries: [
          { binding: 0, resource: { buffer: this.uniforms } },
          { binding: 1, resource: { buffer: this.colXBuffer } },
          { binding: 2, resource: { buffer: this.cellBuffer } },
          { binding: 3, resource: { buffer: this.glyphBuffer } },
          { binding: 4, resource: atlas.texture.createView() },
        ],
      });
      this.bound = atlas;
    }
    const d = this.dimensions, m = atlas.metrics, f = this.uniformF32, u = this.uniformU32;
    const dpr = this.core._coreBrowserService.dpr;
    const canvas = this.surface.canvas;
    f[0] = canvas.width; f[1] = canvas.height;
    // Model row 0 is the first line ABOVE the screen; the smooth scroll's shift moves them all.
    f[2] = d.device.cell.height; f[3] = this.originY - this.above * d.device.cell.height + Math.round(this.shift * dpr);
    u[4] = this.cols; u[5] = this.mrows;
    f[6] = m.thickness; f[7] = m.underline; f[8] = m.strike; f[9] = Math.max(1, m.thickness);
    u[10] = this.palette.cursor;
    f[11] = Math.max(1, Math.round((this.core.optionsService.rawOptions.cursorWidth ?? 1) * dpr));
    f[12] = BG_CORNER_RADIUS_PX * dpr; f[13] = dpr; f[14] = this.originX; f[15] = this.areaH;
    // The gradient's stops, HSL (hue in turns): green top, green bottom, red top, red bottom; then the switches.
    (this.clientContext ? defaultGradientHsl : gradientHsl).forEach((c, k) => { f[16 + k * 4] = c.h / 360; f[17 + k * 4] = c.s; f[18 + k * 4] = c.l; f[19 + k * 4] = 0; });
    f[19] = (this.clientContext ? this.clientContext.preferences.get("rdev.terminalBgGradient") === "on" : backgroundGradient) ? 1 : 0;
    f[23] = gradient.dither ? 1 : 0;
    this.device.queue.writeBuffer(this.uniforms, 0, this.uniformData);

    const bgc = this.palette.background;
    const encoder = this.device.createCommandEncoder();
    const pass = encoder.beginRenderPass({
      colorAttachments: [{
        view: this.surface.context.getCurrentTexture().createView(),
        clearValue: { r: ((bgc >>> 24) & 255) / 255, g: ((bgc >>> 16) & 255) / 255, b: ((bgc >>> 8) & 255) / 255, a: 1 },
        loadOp: "clear", storeOp: "store",
      }],
    });
    const n = this.cols * this.mrows;
    pass.setBindGroup(0, this.bindGroup);
    pass.setPipeline(this.shared.bg); pass.draw(6, n);
    pass.setPipeline(this.shared.glyph); pass.draw(6, n);
    pass.setPipeline(this.shared.line); pass.draw(6, n);
    pass.end();
    this.device.queue.submit([encoder.finish()]);
  }

  // ---- the cursor's blink (xterm.js's: 600 ms, while focused, restarted visible by a move) ----------------

  private blinking(): boolean {
    const o = this.core.optionsService.rawOptions;
    return (this.core.coreService.decPrivateModes.cursorBlink ?? o.cursorBlink ?? false) && this.core._coreBrowserService.isFocused;
  }

  private updateBlink(): void {
    const on = this.blinking();
    if (on && this.blinkTimer === null) this.startBlink();
    else if (!on && this.blinkTimer !== null) { clearInterval(this.blinkTimer); this.blinkTimer = null; this.blinkVisible = true; }
  }

  private restartBlink(): void {
    this.blinkVisible = true;
    if (this.blinkTimer !== null) { clearInterval(this.blinkTimer); this.startBlink(); }
  }

  private startBlink(): void {
    this.blinkTimer = setInterval(() => {
      if (!this.blinking()) { this.updateBlink(); return; }
      this.blinkVisible = !this.blinkVisible;
      const y = this.term.buffer.active.cursorY;
      this.requestRedraw(y, y);
    }, BLINK_MS);
  }
}

/// Cell `x` of SCREEN row `y` is in the hovered link (its end exclusive, as the DOM renderer walks it).
function inLink(e: LinkEvent, x: number, y: number): boolean {
  if (y < e.y1 || y > e.y2) return false;
  if (y === e.y1 && x < e.x1) return false;
  if (y === e.y2 && x >= e.x2) return false;
  return true;
}

// ---------------------------------------------------------------------------------------------- attaching

export interface WebgpuHandle {
  /// The WebGPU renderer is drawing (false while the device is awaited, or after a fallback).
  readonly active: boolean;
  /// Smooth scrolling on: draw the lines beyond the screen (overscan-rows.ts's job for the DOM renderer).
  setOverscan(on: boolean): void;
  /// Smooth scrolling's fractional shift in CSS px, drawn by the renderer (`WebgpuRenderer.setShift`).
  setShift(px: number): void;
  /// A held resize moved the picture (`WebgpuRenderer.relayout`).
  relayout(extraAbove: number): void;
  /// This terminal takes its area's one canvas (surface.ts): it draws there from now, and the one that drew
  /// before stops. A MANAGED terminal (`host` given — the deck's) draws only once claimed; an unmanaged one
  /// claims its own area when it is attached.
  claim(): void;
  /// Stop. `restore`: the DOM renderer draws again — false when the terminal is being disposed with it
  /// (xterm.js disposes the renderer itself then).
  dispose(restore?: boolean): void;
}

/// Draw `term` (an OPENED terminal) with WebGPU once the shared device is ready; until then, and whenever
/// it cannot, the DOM renderer draws. `host`: the AREA whose one canvas it draws into (surface.ts) — the deck's
/// `#xterm`, MANAGED: it draws only once its view claims the canvas. Absent: the terminal's own container,
/// claimed at once. `token`: the view's identity in that claim (a view on the DOM renderer claims with it too,
/// and the canvas clears). `onChange` hears every switch.
export function attachWebgpuRenderer(term: Terminal, overscan: boolean,
                                     o: { host?: HTMLElement; token?: object; onChange?: (active: boolean) => void } = {}): WebgpuHandle {
  let disposed = false;
  let renderer: WebgpuRenderer | null = null;
  let shift = 0;
  const core = privateCore(term);
  const token = o.token ?? {};
  const host = o.host ?? term.element?.parentElement ?? null;
  const onChange = o.onChange;
  if (!o.host && host) claimCanvas(host, token);
  const restoreDom = () => {
    const c = privateCore(term);
    if (!c) return;
    c._renderService.setRenderer(c._createRenderer());
    c._renderService.handleResize(term.cols, term.rows);
  };
  const offLost = onGpuLost(() => {
    if (!renderer) return;
    renderer = null;
    restoreDom();
    onChange?.(false);
  });
  const start = (device: GPUDevice | null) => {
    if (disposed || !device || !core || !host) return;
    try {
      const r = new WebgpuRenderer(term, core, sharedFor(device), overscan, host, token);
      r.setShift(shift);
      core._renderService.setRenderer(r);   // disposes the DOM renderer
      renderer = r;
      onChange?.(true);
    } catch (e) {
      console.warn("[webgpu] the renderer could not start; the DOM renderer draws", e);
    }
  };
  // Already there (the session asked early — `requestGpu`): draw with it from the first frame.
  const now = readyGpu();
  if (core && now) start(now);
  else if (core) void requestGpu().then(start);
  return {
    get active() { return renderer !== null; },
    setOverscan(on: boolean) { overscan = on; renderer?.setOverscan(on); },
    setShift(px: number) { shift = px; renderer?.setShift(px); },
    relayout(extraAbove: number) { renderer?.relayout(extraAbove); },
    claim() { if (host) claimCanvas(host, token); },
    dispose(restore = true) {
      if (disposed) return;
      disposed = true;
      offLost();
      if (renderer && restore) restoreDom();
      renderer = null;
    },
  };
}
