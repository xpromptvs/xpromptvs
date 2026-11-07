import { suppressHiddenDomRendering } from "./hidden-dom-render";
import { shareGlyphMeasurements } from './shared-font-metrics';
import { fontNames } from "./instance/styles";
import { contextFor, presentationRoot } from "./instance/context";
import { BACKGROUND_COLORS_CHANGED } from "../shared/background-colors";
import { attachWebgpuRenderer, type WebgpuHandle } from "./webgpu/renderer";
import { claimCanvas } from "./webgpu/surface";
import { routeGpuFrameDraws } from "./gpu-frame-draws";
import { Terminal, type ITheme, type ITerminalOptions } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import type { Theme } from "../shared/theme";
import { splitReplies } from "./term-replies";
import { loadRdevUnicode, loadTmuxUnicode } from "./term-unicode";
import { attachWheelLines, wheelIsDiscrete } from "./wheel-lines";
import { wheelPixels } from "./wheel-resample";
import { SmoothScroll, xtermScrollSurface, type FrameClock } from "./smooth-scroll";
import { OverscanRows } from "./overscan-rows";
import { BgCorners } from "./bg-corners";
import { RowCache, type RowCacheStats } from "./row-cache";
import { mountTerminalScrollbar } from "./terminal-scrollbar";
import { TrailingBlanks } from "./trailing-blanks";
import { RevealDraw } from "./reveal-draw";
import { attachTermLinks } from "./term-links";
import { attachPathLinks } from "./term-paths";
import { textEditingBytes } from "./terminal-keys";

/// xterm colours per theme.
///
/// DARK IS "Sonokai Shusia" (https://terminalcolors.com/themes/sonokai/shusia/, asked for 2026-09-29
/// after Dracula, the "Deus Default" profile and Posterpole — `git log -p` on this file has each):
/// its text, background, cursor, selection and all 16 ANSI colours, exactly as the site's Ghostty and
/// Alacritty files give them. Its Terminal.app file agrees on everything but the cursor (yellow there;
/// the text colour in the other two, followed here). Truecolor output is untouched, and so is the font.
///
/// Two things that look like mistakes and are the THEME's: its "cyan" slot is ORANGE (#ef9062 there —
/// Sonokai has no cyan among its accents; its teal is "blue"), and every bright colour is its normal
/// one, bright black apart.
///
/// TWO changes from the theme. The BACKGROUND, asked for the same day ("a bit more gray, a barely
/// noticeable tint", then "even less colored", then "1 tone darker", then "one more tone darker"): it
/// is #262526, not #2d2a2e. #2c2b2c kept the theme's OKLCH lightness (0.2905) at under a third of the
/// chroma (0.0023 against 0.0083), its hue (326) the nearest to the theme's violet (318) of any 8-bit
/// colour that faint; a "tone" is three steps (every channel −3), so #292829 (lightness 0.2783) and
/// then #262526 (0.2659) — the SAME chroma and hue each time, so the tint is unchanged. One step (−1)
/// moves lightness only ~0.004, too little to see. #2b2b2c is fainter still (0.0018) but swings to
/// blue (286).
///
/// The current content background is #181817 (2026-11-06); the earlier tuning above is historical.
///
/// And the TEXT colours are brighter ("make colors a bit more contrasting", the same day): the
/// foreground (with the cursor, white and bright white), the six accents and bright black each +0.04
/// OKLCH lightness at the theme's own hue and chroma, and black −0.04 — so every one moves the same
/// perceptual step away from the background and keeps its colour. Red alone is at the sRGB edge and
/// gives up a little chroma to get there (0.190 to 0.172). Contrast against #262526, theme's → ours:
/// text 11.75 → 13.24, red 5.04 → 5.90, green 8.30 → 9.48, yellow 9.02 → 10.28, blue 8.32 → 9.51,
/// magenta 6.43 → 7.42, orange 6.43 → 7.44, bright black 3.95 → 4.63. The selection is the theme's.
///
/// Light keeps its own 16 colours (the theme is dark only): a dark-tuned shell palette (bright
/// yellows, pale greys) is genuinely unreadable on a light background.
///
/// AND FOUR OF THE 256 ARE THE THEME'S TOO (dark only, asked for 2026-09-29: "Map them to ours"):
/// Claude Code's diff renderer paints with fixed 256-colour slots when it does not see truecolor —
/// removed line 52, removed word 88, added line 22, added word 28 — which xterm.js otherwise draws as
/// the cube's #5f0000 / #870000 / #005f00 / #008700 whatever the theme (`DIFF_SLOTS`).
export function xtermTheme(theme: Theme): ITheme {
  if (theme === "dark") {
    return {
      background: "#181817", foreground: "#f0eef1", cursor: "#f0eef1", cursorAccent: "#181817",
      selectionBackground: "#423f46", selectionForeground: "#f0eef1",
      black: "#110f11", red: "#ff7392", green: "#aada7c", yellow: "#f2d170",
      blue: "#87d9e4", magenta: "#b7aaff", cyan: "#fd9d6e", white: "#f0eef1",
      brightBlack: "#908c95", brightRed: "#ff7392", brightGreen: "#aada7c", brightYellow: "#f2d170",
      brightBlue: "#87d9e4", brightMagenta: "#b7aaff", brightCyan: "#fd9d6e", brightWhite: "#f0eef1",
      extendedAnsi: Array.from({ length: 240 }, (_, i) => DIFF_SLOTS[16 + i] ?? xtermCubeColor(16 + i)),
    };
  }
  return {
    background: "#ffffff", foreground: "#0a0a0a", cursor: "#0a0a0a", cursorAccent: "#ffffff",
    selectionBackground: "rgba(0,0,0,0.14)",
    black: "#0a0a0a", red: "#c81e10", green: "#1a7f37", yellow: "#8a6300",
    blue: "#0a58ca", magenta: "#8250df", cyan: "#0f6f7a", white: "#5a5a5a",
    brightBlack: "#8f8f8f", brightRed: "#e0402f", brightGreen: "#2ea043", brightYellow: "#a97400",
    brightBlue: "#2563eb", brightMagenta: "#a475f9", brightCyan: "#1f8fa0", brightWhite: "#0a0a0a",
  };
}

/// Sonokai's diff backgrounds on the 256-colour slots Claude Code paints diffs with (dark theme).
/// Sonokai Shusia assigns its OWN to exactly two of them — `bg_green` #394634 to 22 and `bg_red`
/// #55393d to 52 (sainnhe/sonokai, autoload/sonokai.vim) — and has no word-level diff colour, so the
/// added-word slot uses a medium cool green to separate it from both the flat and gradient line
/// backgrounds without washing out light text. The removed-word slot retains its stronger red.
export const DIFF_SLOTS: Readonly<Record<number, string>> = { 22: "#394634", 28: "#386b50", 52: "#55393d", 88: "#7d484c" };

/// xterm.js 6's fixed colour for 256-colour index 16-255 — the 6x6x6 cube (0, 5f, 87, af, d7, ff), then
/// the grey ramp from #080808 in steps of 10 — what an index reports unless a theme's `extendedAnsi`
/// replaces it. The host computes the same (`TermPalette.color`).
export function xtermCubeColor(index: number): string {
  const h = (v: number) => v.toString(16).padStart(2, "0");
  if (index >= 232) { const g = 8 + (index - 232) * 10; return `#${h(g)}${h(g)}${h(g)}`; }
  const v = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff], i = index - 16;
  return `#${h(v[Math.floor(i / 36) % 6]!)}${h(v[Math.floor(i / 6) % 6]!)}${h(v[i % 6]!)}`;
}

/// The colours an xterm.js REPORTS to OSC 10/11/12 and OSC 4, as lowercase `#rrggbb` — the
/// `term-palette` control message. The host answers a tmux tab's colour queries from it when their
/// bytes reach no client (docs/terminal.md, "tmux answers device queries itself"). `ext` holds only the
/// 16-255 slots the theme REPLACES (index → colour); the rest are xterm.js's fixed cube and greys, which
/// the host computes itself.
export interface TermPalette { fg: string; bg: string; cursor: string; ansi: string[]; ext: Record<string, string> }

/// xterm.js 6 with no theme (ThemeService's defaults, DEFAULT_ANSI_COLORS 0-15). MEASURED against a
/// real instance by `term-client-queries.test.ts`.
export const XTERM_DEFAULT_PALETTE: TermPalette = {
  fg: "#ffffff", bg: "#000000", cursor: "#ffffff",
  ansi: ["#2e3436", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
         "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"],
  ext: {},
};

/// The theme keys of the 16 ANSI colours, in palette order (0–15).
export const ANSI_KEYS = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
  "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"] as const;

/// What this client's xterm.js reports under `theme` (`xtermTheme` over xterm.js's defaults). Every
/// colour `xtermTheme` sets is a plain `#rrggbb`, which xterm.js reports unchanged.
export function xtermPalette(theme: Theme): TermPalette {
  const t = xtermTheme(theme);
  const d = XTERM_DEFAULT_PALETTE;
  const c = (v: string | undefined, fallback: string) => (v ?? fallback).toLowerCase();
  const ext: Record<string, string> = {};
  (t.extendedAnsi ?? []).forEach((v, i) => { if (v.toLowerCase() !== xtermCubeColor(16 + i)) ext[String(16 + i)] = v.toLowerCase(); });
  return { fg: c(t.foreground, d.fg), bg: c(t.background, d.bg), cursor: c(t.cursor, d.cursor),
           ansi: ANSI_KEYS.map((k, i) => c(t[k], d.ansi[i] ?? "#000000")), ext };
}

/// The `term-palette` control message for `theme` (protocol/datachannels.md).
export function termPaletteMessage(theme: Theme): { t: "term-palette" } & TermPalette {
  return { t: "term-palette", ...xtermPalette(theme) };
}

export interface XtermViewOpts {
  /// Typing, paste, mouse and focus reports.
  onData: (data: string) => void;
  /// A device-query REPLY produced while parsing the tab's bytes (term-replies.ts). Absent: it goes to
  /// `onData` (an instance whose replies nobody routes, like a throwaway measuring one).
  onReply?: (data: string) => void;
  onFit: (cols: number, rows: number) => void;
  fontSize?: number;   // px; defaults to 14 (the floating-layout size). Mobile passes its own, smaller size.
  /// Whose glyph widths this instance counts: a `pty:` tab's host emulator's (SwiftTerm, the default) or
  /// tmux's for a `tmux:` tab (term-unicode.ts; docs/terminal.md, "tmux tabs count as tmux does").
  widths?: "pty" | "tmux";
  theme: Theme;
  /// Smooth scrolling of the scrollback (smooth-scroll.ts) — the saved preference; off when absent.
  smoothScroll?: boolean;
  /// A scroll draws its rows at once, with the shift (smooth-scroll.ts, "the rows and the shift change
  /// together") — on unless `false` (`?scrollsync=0`, to compare).
  scrollSync?: boolean;
  /// A trackpad's wheel over the smooth scrollback is followed a frame at a time (wheel-resample.ts) —
  /// on unless `false` (`?wheelresample=0`, to compare).
  wheelResample?: boolean;
  /// `"webgpu"` draws with the WebGPU renderer (webgpu/renderer.ts) once the shared device is ready; the DOM
  /// renderer draws until then and whenever it cannot (no hardware adapter, a lost device).
  renderer?: "dom" | "webgpu";
  /// The AREA whose one canvas the WebGPU renderer draws into (webgpu/surface.ts) — the deck's `#xterm`, shared
  /// by every tab and every snapshot's instance; it draws there only once `claimCanvas` is called. Absent: the
  /// container is the area, and the terminal claims it at once.
  gpuHost?: HTMLElement;
  /// An IMAGE PATH printed in it was clicked or tapped (term-paths.ts): the path as printed, unquoted. Absent: paths
  /// stay plain text (a throwaway measuring instance, the offer's screen).
  onPath?: (path: string) => void;
}

/// Nobody's: the area's one canvas is cleared (the deck shows no tab).
export function releaseCanvas(host: HTMLElement): void { claimCanvas(host, null); }

export interface XtermView {
  /// Which renderer is drawing now: `"webgpu"` once the WebGPU renderer took over (`opts.renderer`).
  renderer(): "dom" | "webgpu";
  write(data: string | Uint8Array): void;
  writeAsync(data: string | Uint8Array): Promise<void>;   // resolves after xterm has PROCESSED the write
  cols(): number;
  rows(): number;
  cursor(): { row: number; col: number };                 // absolute buffer row (baseY+cursorY) + col
  cellAt(row: number, col: number): string;               // the rune at a buffer cell (" " if blank)
  /// Fit the grid to the container. False when it could not be measured (a hidden container) — the
  /// grid is then unchanged and nothing is reported.
  fit(): boolean;
  /// The grid the container fits, WITHOUT resizing (`TermDeck.fit`'s hold); null when unmeasurable.
  measure(): { cols: number; rows: number } | null;
  resizeTo(cols: number, rows: number): void;
  isAltScreen(): boolean;
  /// DECCKM. Arrows and Home/End are SS3 rather than CSI while this is set; the on-screen strip and
  /// the glasses chips both bypass xterm's own keyboard handling, so they have to ask.
  appCursor(): boolean;
  focus(): void;
  setTheme(theme: Theme): void;
  setSmoothScroll(on: boolean): void;
  /// **A HELD RESIZE's picture moves by `rows` whole rows, positive down** (hold-shift.ts, `TermDeck.fit`): a
  /// transform on xterm.js's own element (`.xterm` — the smooth scroll's is on `.xterm-screen`, inside it), so its
  /// rows, cursor, decorations and every pointer mapping (they read the screen's box) move together; `#xterm`
  /// clips it. A move down opens a gap above, which the rows beyond the screen fill from the scrollback (both
  /// renderers, smooth scrolling on). 0 puts it back — what a resize of this instance does.
  holdShift(rows: number): void;
  /// **TRAILING BLANK LINES DO NOT EXIST** while `on` (trailing-blanks.ts): an agent runs in the tab, so the view
  /// ends at the screen's last line of content, the scrollback making up the rows. The deck says which tabs.
  hideTrailingBlanks(on: boolean): void;
  /// How many of the screen's bottom rows are taken as not there now (0 when off) — the view rests that many
  /// rows into the scrollback, so the cursor is drawn that many rows lower (session.ts, `cursorTop`).
  hiddenRows(): number;
  /// This instance is the one its area shows: it takes the area's canvas (`gpuHost`) — drawn into from now,
  /// everything at once — and whatever drew there stops. On the DOM renderer it only clears that canvas.
  claimCanvas(): void;
  /// The row cache's counters (row-cache.ts) — read by the scroll probe.
  rowStats(): RowCacheStats;
  dispose(): void;
  readonly term: Terminal;
  /// This instance's smooth scrolling — the touch handler drives its drag and glide. Null when xterm.js
  /// no longer has the internals it reads (`xtermScrollSurface`).
  readonly smooth: SmoothScroll | null;
}

/// Real frames and timers for an instance's smooth scrolling; its `dispose` cancels whatever is pending.
///
/// **A frame's work runs just AFTER the animation frame, as a task — never inside it.** xterm.js redraws
/// from a `requestAnimationFrame` it asks for when its row moves, and one asked for from inside an
/// animation frame runs in the NEXT one: a glide stepped from `requestAnimationFrame` painted every frame
/// with the previous frame's rows (review I1 — up to two rows off in WebKit). Posted out of the frame,
/// the scroll lands between frames, as a wheel's or a finger's does, and xterm.js redraws before the
/// next paint.
const frameTasks = new Map<number, { raf: number; cb: (now: number) => void; ts: number }>();
let framePort: MessagePort | null = null;
let frameSeq = 0;
function afterFrame(cb: (now: number) => void): number {
  if (!framePort) {
    const ch = new MessageChannel();
    ch.port1.onmessage = (e: MessageEvent<number>) => {
      const task = frameTasks.get(e.data);
      if (!task) return;                       // cancelled after its animation frame
      frameTasks.delete(e.data);
      // The FRAME's time, not when this task ran: the wheel's frame clock (wheel-resample.ts) steadies
      // frame times, and a task's delivery would add its own wobble. Only a plausible one — a frame's
      // time is on `performance.now()`'s clock in every browser, but not jsdom's, and a clock the
      // wheel's events are not on would leave them never arriving.
      const now = performance.now();
      task.cb(task.ts > 0 && task.ts <= now && now - task.ts < 100 ? task.ts : now);
    };
    framePort = ch.port2;
  }
  const id = ++frameSeq;
  const raf = requestAnimationFrame((ts) => {
    const task = frameTasks.get(id);
    if (task) { task.ts = ts; framePort!.postMessage(id); }
  });
  frameTasks.set(id, { raf, cb, ts: 0 });
  return id;
}
const BROWSER_CLOCK: FrameClock = {
  now: () => performance.now(),
  frame: afterFrame,
  cancelFrame: (id) => {
    const task = frameTasks.get(id);
    if (task) { cancelAnimationFrame(task.raf); frameTasks.delete(id); }
  },
  timeout: (cb, ms) => window.setTimeout(cb, ms),
  clearTimeout: (id) => window.clearTimeout(id),
};

/// **WHILE THE WEBGPU RENDERER DRAWS, A FRAME'S WORK RUNS INSIDE THE ANIMATION FRAME** (2026-10-04). On an iPhone
/// a glide — and only a glide: a finger's drag never — showed a previous buffer every other frame: its steps ran
/// in the task `afterFrame` posts, so every one of its draws (`drawNow`, `setShift`) acquired and submitted the
/// canvas's texture BETWEEN rendering updates, which WebKit on iOS presented as a stale or unfinished buffer.
/// Inside the animation frame the draw is where every WebGPU page draws, presented by that rendering update. The
/// DOM renderer's reason for `afterFrame` does not hold here: a scroll draws its rows inside the scroll
/// (`drawNow` runs xterm.js's pending frame, and this renderer draws as it renders). Decided per frame, so a
/// renderer taking over — or the DOM one coming back — changes where the next one runs.
/// `inFrame`: one of THIS clock's frame callbacks is running (gpu-frame-draws.ts defers a draw made outside one).
function viewClock(gpuDraws: () => boolean): FrameClock & { inFrame(): boolean } {
  const inside = new Map<number, number>();   // frame id → its requestAnimationFrame
  let depth = 0;
  const run = (cb: (now: number) => void) => (now: number) => { depth++; try { cb(now); } finally { depth--; } };
  return {
    ...BROWSER_CLOCK,
    inFrame: () => depth > 0,
    frame: (cb) => {
      if (!gpuDraws()) return afterFrame(run(cb));
      const id = ++frameSeq;
      inside.set(id, requestAnimationFrame((ts) => { inside.delete(id); run(cb)(ts); }));
      return id;
    },
    cancelFrame: (id) => {
      const raf = inside.get(id);
      if (raf === undefined) { BROWSER_CLOCK.cancelFrame(id); return; }
      cancelAnimationFrame(raf);
      inside.delete(id);
    },
  };
}

/// The rendered cell height in CSS px. xterm.js keeps it on its render service (not public API); the
/// screen element divided by the rows is the same number whenever the renderer has not measured yet.
function cssCellHeight(term: Terminal): number {
  const core = (term as unknown as { _core?: { _renderService?: { dimensions?: { css?: { cell?: { height?: number } } } } } })._core;
  const h = core?._renderService?.dimensions?.css?.cell?.height;
  if (h && h > 0) return h;
  const screen = term.element?.querySelector(".xterm-screen");
  const r = screen?.getBoundingClientRect();
  return r && r.height > 0 && term.rows > 0 ? r.height / term.rows : 0;
}

/// Mount xterm.js into `container` and wire the data flow. Matches the host's default 80x24 until the
/// first fit or its tab's snapshot sizes it. Scrollback matches the host's (`Terminal.scrollbackLines`),
/// because a snapshot restores everything the host holds.
// Page-local presentation defaults, set before mounting (e.g. an unfocused live demo).
let cursorDefaults: Pick<ITerminalOptions, "cursorBlink" | "cursorInactiveStyle"> = { cursorBlink: true };
const scopedCursorDefaults = new WeakMap<HTMLElement, Pick<ITerminalOptions, "cursorBlink" | "cursorInactiveStyle">>();
export function setTerminalCursorDefaults(defaults: Pick<ITerminalOptions, "cursorBlink" | "cursorInactiveStyle">, root?: HTMLElement): void {
  if (root) { scopedCursorDefaults.set(root, {cursorBlink: true, ...defaults}); return; }
  cursorDefaults = { cursorBlink: true, ...defaults };
}

// Instance-owned renderer subscriptions for embedders; no global current terminal.
const renderedTerminals = new WeakMap<HTMLElement, Terminal>();
const terminalImageOpeners = new WeakMap<HTMLElement, (path:string)=>void>();
/** Activate the same image-path callback as a terminal link, for embedded presentations. */
export function openTerminalImage(element:HTMLElement,path:string):boolean {
  const open=terminalImageOpeners.get(element);
  if(!open)return false;
  open(path);return true;
}
export function watchTerminalRender(element: HTMLElement, callback: () => void): (() => void) | undefined {
  const term = renderedTerminals.get(element);
  if (!term) return undefined;
  const subscription = term.onRender(callback);
  return () => subscription.dispose();
}

function terminalTheme(container: HTMLElement, theme: Theme): ITheme {
  const background = getComputedStyle(container).getPropertyValue('--terminal-background').trim();
  return {...xtermTheme(theme), ...(background ? {background} : {})};
}

function terminalOptions(container: HTMLElement, opts: XtermViewOpts): ITerminalOptions {
  return {
    fontFamily: `"${contextFor(container) ? fontNames.mono : "JetBrains Mono"}", Menlo, Monaco, "DejaVu Sans Mono", "Courier New", monospace`,
    fontSize: opts.fontSize ?? 14,
    scrollback: 5000,
    ...(scopedCursorDefaults.get(presentationRoot(container)) ?? (contextFor(container) ? { cursorBlink: true } : cursorDefaults)),
    allowProposedApi: true,   // decorations/markers (used by the prediction overlay) are proposed API
    // Box drawing and block elements (U+2500-259F) are in neither JetBrains Mono subset. The DOM renderer
    // draws EVERY character from the font (xterm.js ignores `customGlyphs` there), so they come from the
    // stack's fallback — Menlo on Apple — letter-spaced onto their cells like any glyph, so the grid holds;
    // the WebGPU renderer draws them itself (webgpu/custom-glyphs.ts). A table's light corners are drawn
    // rounded by both (bg-corners.ts).
    // DOM fallback: xterm caches contrast corrections per color pair, including truecolor
    // diff text. WebGPU resolves its own colors and applies its shader's contrast rule.
    minimumContrastRatio: 3.25,
    theme: terminalTheme(container, opts.theme),
  };
}

/** Empty-area geometry needs xterm's font metrics and FitAddon, not a live renderer's
 * scrolling, links, selection, GPU, prediction, and resize listeners. Never parses bytes. */
export function mountMeasuringXterm(container: HTMLElement, opts: XtermViewOpts): Pick<XtermView, 'fit'|'measure'|'cols'|'rows'|'dispose'> {
  // One blank row is enough to establish cell metrics. Keep the normal column count:
  // xterm rounds the canvas width before deriving the CSS cell width from it.
  const term = new Terminal({...terminalOptions(container, opts), rows:1});
  const fit = new FitAddon();
  term.loadAddon(fit);
  try { term.open(container); } catch (error) { term.dispose(); throw error; }
  const measure = () => {
    const dims = fit.proposeDimensions();
    return dims && dims.cols > 0 && dims.rows > 0 ? {cols:dims.cols,rows:dims.rows} : null;
  };
  let fitted: {cols:number;rows:number} | null = null;
  return {
    measure,
    fit: () => { fitted=measure();return fitted!==null; },
    cols:()=>fitted?.cols??term.cols,rows:()=>fitted?.rows??term.rows,dispose:()=>term.dispose(),
  };
}

export function mountXterm(container: HTMLElement, opts: XtermViewOpts): XtermView {
  const term = new Terminal(terminalOptions(container, opts));
  // LOAD-BEARING: glyph widths as the HOST counts them (term-unicode.ts). Without it xterm.js 6 counts
  // Unicode 6 — 😀 one column, 👩‍💻 four — and a restored screen misplaces every cell after an emoji.
  if (opts.widths === "tmux") loadTmuxUnicode(term); else loadRdevUnicode(term);
  const fitAddon = new FitAddon();
  term.loadAddon(fitAddon);
  // ⌥/Ctrl+←→ are word motions, ⌘←→ the line's ends, ⌘⌫ deletes the line — as Ghostty sends them on a Mac
  // (terminal-keys.ts, `textEditingBytes`).
  term.attachCustomKeyEventHandler((e) => {
    if (e.type !== "keydown") return true;
    const bytes = textEditingBytes(e.key, { alt: e.altKey, ctrl: e.ctrlKey, shift: e.shiftKey, meta: e.metaKey });
    if (bytes === null) return true;
    e.preventDefault();
    term.input(bytes, true);
    return false;
  });
  // A link — an OSC 8 hyperlink or a URL in the text — opens in a browser (term-links.ts).
  attachTermLinks(term);
  term.open(container);
  // Unfocused embedded demos need an initialized cursor without taking keyboard focus.
  if (scopedCursorDefaults.has(presentationRoot(container))) term.write("\x1b[?47l");
  // Embedded clients share the same scoped styles and immutable font assets. The
  // cache is per document and keyed by the full font/variant/DPR configuration.
  const domWidths=(term as unknown as {_core?:{_renderService?:{_renderer?:{value?:{_widthCache?:unknown}}}}})._core?._renderService?._renderer?.value?._widthCache;
  const unshareMetrics=contextFor(container) ? shareGlyphMeasurements(domWidths,container.ownerDocument) : ()=>{};
  if (term.element) renderedTerminals.set(term.element, term);
  // An image path opens on the client (term-paths.ts): a link for a mouse, a tap for a finger.
  if(term.element && opts.onPath)terminalImageOpeners.set(term.element,opts.onPath);
  const paths = opts.onPath ? attachPathLinks(term, container, opts.onPath, { gliding: () => smooth?.gliding === true }) : null;
  // The WebGPU renderer (webgpu/renderer.ts), when asked for: it takes over from the DOM renderer once the
  // shared device is ready. The modules below find the DOM renderer only when they need it and stand down
  // while it is not the one drawing.
  const canvasToken = {};
  const gpu: WebgpuHandle | null = opts.renderer === "webgpu"
    ? attachWebgpuRenderer(term, opts.smoothScroll ?? false, { host: opts.gpuHost, token: canvasToken }) : null;

  splitReplies(term, { data: opts.onData, reply: opts.onReply ?? opts.onData });
  // The DOM listeners this mount adds itself, removed together on dispose.
  const listeners = new AbortController();
  let currentTheme = opts.theme;
  container.ownerDocument.addEventListener(BACKGROUND_COLORS_CHANGED, event => {
    if (event.target === container.ownerDocument.documentElement || event.composedPath().includes(presentationRoot(container))) {
      term.options.theme = terminalTheme(container, currentTheme);
    }
  }, {signal: listeners.signal});
  // The soft keyboard's text is SENT, never INSERTED (docs/client-web.md, "Shake to Undo"). xterm.js reads
  // an `insertText` from the `input` event, after the browser has put it into its helper textarea, and
  // every such insertion is an undoable edit: iOS's Shake to Undo offered "Undo Typing" over the terminal
  // (MEASURED, WebKit and Chromium: one soft-keyboard commit and undo is on). Taken at `beforeinput`
  // instead — only where xterm.js's own `_inputEvent` sends it (a plain `insertText` with data, no key
  // held, since a held key's text is its keypress's; not composing; no screen reader) — and handed to
  // xterm.js as input, the same `triggerDataEvent` it would have made. A composition still inserts.
  const ta = term.textarea;
  if (ta) {
    let keyHeld = false;
    const on = { capture: true, signal: listeners.signal };
    ta.addEventListener("keydown", () => { keyHeld = true; }, on);
    ta.addEventListener("keyup", () => { keyHeld = false; }, on);
    ta.addEventListener("beforeinput", (e) => {
      const ie = e as InputEvent;
      if (ie.inputType !== "insertText" || !ie.data || ie.isComposing || keyHeld || term.options.screenReaderMode) return;
      ie.preventDefault();
      term.input(ie.data, true);
    }, on);
  }
  // A trackpad over a mouse-tracking app or the alt screen: one report/arrow per CELL HEIGHT of
  // motion, as a native terminal sends — stock xterm.js sent ~a third of that (wheel-lines.ts).
  attachWheelLines(term, () => cssCellHeight(term));
  // The rows below the content's end, gone while an agent runs (trailing-blanks.ts) — the smooth scroll's and the
  // scrollbar's range ends there.
  const tail = new TrailingBlanks(term);
  const surface = xtermScrollSurface(term, () => cssCellHeight(term), opts.scrollSync ?? true, () => tail.end());
  const clock = viewClock(() => gpu?.active ?? false);
  // WHILE THE WEBGPU RENDERER DRAWS, IT DRAWS THE SHIFT (webgpu/renderer.ts `setShift`) and `.xterm-screen`
  // keeps none: WebKit on iOS showed the canvas a frame after the transform, a row off at every crossing.
  // Routed on EVERY offset — the smooth scroll re-states it on each redraw — so a renderer taking over, or
  // the DOM one coming back after a lost device, has the shift from its first frame. And a scroll xterm.js
  // makes by itself, outside any frame, draws in the next one (gpu-frame-draws.ts).
  let holder: SmoothScroll | null = null;
  const unrouteGpu = surface && gpu ? routeGpuFrameDraws(surface, gpu, clock, () => holder?.holding ?? false) : null;
  const smooth = surface ? new SmoothScroll(surface, clock, opts.smoothScroll ?? false) : null;
  holder = smooth;
  // A trackpad's wheel over the smooth scrollback is RESAMPLED (wheel-resample.ts): taken from xterm.js —
  // its scrollable ignores a prevented wheel — and followed a frame at a time, so events landing 1, 2 or
  // 3 to a frame still move the text evenly. Only where xterm.js would scroll the scrollback itself, by
  // exactly as much; a pinch (⌃) and a wheel that moves nothing stay xterm.js's. Timed when it arrives.
  // AT THE CONTENT'S END A WHEEL DOWN SCROLLS NOTHING (trailing-blanks.ts) — taken before the smooth scroll or xterm.js
  // sees it. Let through, each event moved the view past the end and the clamp put it back: a trackpad's momentum did
  // that once per event until it stopped ("a fast feedback loop", the desktop app, 2026-10-14; trailing-blanks-check
  // T7). A finger's synthetic wheel (touch-scroll.ts, smooth scrolling off) is one of these too.
  term.element?.addEventListener("wheel", (e) => {
    if (e.ctrlKey || !(e.deltaY > 0) || tail.hidden() === 0) return;
    if (term.buffer.active.viewportY >= tail.end()) e.preventDefault();
  }, { capture: true, passive: false, signal: listeners.signal });
  if (smooth && opts.wheelResample !== false) {
    term.element?.addEventListener("wheel", (e) => {
      if (!smooth.enabled || e.defaultPrevented || e.ctrlKey || wheelIsDiscrete(term)) return;
      const px = wheelPixels(e, term.options.scrollSensitivity ?? 1, term.options.fastScrollSensitivity ?? 5);
      if (px === 0) return;
      e.preventDefault();
      smooth.wheel(px, performance.now());
    }, { capture: true, passive: false, signal: listeners.signal });
  }
  // A redraw reuses the rows it would only have moved (row-cache.ts) — FIRST, so bg-corners and the rows
  // beyond the screen wrap it and see a reused row like a built one.
  const rowCache = new RowCache(term);
  // Background blocks round their outer corners (bg-corners.ts) — BEFORE the rows beyond the screen, which
  // are built through the same row factory and so are rounded too.
  const corners = new BgCorners(term);
  // Smooth scrolling's other half: the lines beyond the screen, drawn into the inset (overscan-rows.ts).
  const overscan = new OverscanRows(term, opts.smoothScroll ?? false);
  // Coming into view — a tab switch, the terminal surface shown — its rows are drawn BEFORE the browser
  // paints them (reveal-draw.ts): built while hidden, every glyph sat a cell apart for a frame.
  const restoreHiddenRender = suppressHiddenDomRendering(term);
  const reveal = new RevealDraw(term);
  const disposeScrollbar = mountTerminalScrollbar(term, container, () => smooth?.stop(), surface ?? undefined, () => tail.end());
  const measure = () => {
    const dims = fitAddon.proposeDimensions();
    // NOT `<= 0`: a container that is display:none (the terminal surface behind the window surface
    // on a phone) proposes NaN, which passes `<= 0` and makes `term.resize` THROW — measured, it
    // aborted the whole becoming-active callback, so the empty state never showed.
    return dims && dims.cols > 0 && dims.rows > 0 ? { cols: dims.cols, rows: dims.rows } : null;
  };

  // The rows a held resize moved the picture (`holdShift`).
  let held = 0;
  return {
    term,
    smooth,
    renderer: () => (gpu?.active ? "webgpu" : "dom"),
    write: (data) => term.write(data),
    writeAsync: (data) => new Promise<void>((resolve) => term.write(data, resolve)),
    cols: () => term.cols,
    rows: () => term.rows,
    cursor: () => ({ row: term.buffer.active.baseY + term.buffer.active.cursorY, col: term.buffer.active.cursorX }),
    cellAt: (row, col) => term.buffer.active.getLine(row)?.getCell(col)?.getChars() || " ",
    fit: () => {
      const dims = measure();
      if (!dims) return false;
      term.resize(dims.cols, dims.rows);
      opts.onFit(dims.cols, dims.rows);
      return true;
    },
    measure: () => measure(),
    resizeTo: (cols, rows) => { if (cols > 0 && rows > 0) term.resize(cols, rows); },
    isAltScreen: () => term.buffer.active.type === "alternate",
    appCursor: () => term.modes.applicationCursorKeysMode,
    focus: () => term.focus(),
    setTheme: (theme) => { currentTheme = theme; term.options.theme = terminalTheme(container, theme); },
    setSmoothScroll: (on) => { smooth?.setEnabled(on); overscan.setEnabled(on); gpu?.setOverscan(on); },
    holdShift: (rows) => {
      const el = term.element;
      if (!el || rows === held) return;
      const cell = (term as unknown as { _core?: { _renderService?: { dimensions?: { css?: { cell?: { height?: number } } } } } })
        ._core?._renderService?.dimensions?.css?.cell?.height ?? 0;
      held = cell > 0 ? rows : 0;
      el.style.transform = held ? `translateY(${held * cell}px)` : "";
      overscan.relayout(Math.max(0, held));
      gpu?.relayout(Math.max(0, held));
    },
    hideTrailingBlanks: (on) => tail.set(on),
    hiddenRows: () => tail.hidden(),
    claimCanvas: () => { if (opts.gpuHost) claimCanvas(opts.gpuHost, canvasToken); else gpu?.claim(); },
    rowStats: () => rowCache.stats,
    dispose: () => { unshareMetrics(); if (term.element) { renderedTerminals.delete(term.element); terminalImageOpeners.delete(term.element); } unrouteGpu?.(); gpu?.dispose(false); disposeScrollbar(); paths?.dispose(); listeners.abort(); reveal.dispose(); restoreHiddenRender(); tail.dispose(); overscan.dispose(); corners.dispose(); rowCache.dispose(); smooth?.dispose(); term.dispose(); },
  };
}
