import type { Terminal } from "@xterm/xterm";
import type { RowCacheStats } from "./row-cache";
import { xtermDomRenderer } from "./overscan-rows";

/// `?scrollprobe=1` — AN INSTRUMENT, not the product: how EVENLY does the wheel move the scrollback?
///
/// Smooth scrolling (smooth-scroll.ts) puts every painted row exactly where xterm.js's fractional scroll
/// position says — measured to the pixel in both engines — yet a real trackpad was reported to look less
/// than smooth in Safari AND Chrome (2026-09-29). A browser smooths its OWN scrolling (Chrome resamples
/// the trackpad's deltas to each frame's time), but xterm.js takes the wheel itself, so it gets the raw
/// events: if they arrive unevenly against the frames — two in one frame, none in the next — the text
/// moves in uneven steps, however right each frame is. Nothing automated can produce a real trackpad's
/// stream, so this measures the person's: every wheel event and every frame while they scroll, then, when
/// the gesture ends, a summary and a per-frame chart in an overlay (Copy puts the raw data on the
/// clipboard). Nothing is written to the page while a gesture is being recorded.

/// A wheel event as it reached the terminal.
export interface ProbeEvent { t: number; deltaY: number; deltaMode: number; wheelDeltaY: number }
/// One animation frame while recording: its interval, the wheel events that arrived since the last one,
/// how far the scroll position moved, and how long ago the last wheel event was — and, when the terminal
/// has the row cache (row-cache.ts), the redraw passes since the last one: rows built, rows reused, ms.
export interface ProbeFrame { t: number; dt: number; events: number; moved: number; sinceWheelMs: number; rows?: RowCacheStats }

export interface GestureSummary {
  /// Frames recorded, and those from the first frame with a wheel event to the last one with one.
  frames: number;
  activeFrames: number;
  /// The usual frame interval (median), as a rate.
  hz: number;
  /// Frames over one and a half times the usual interval.
  longFrames: number;
  events: number;
  /// Active frames by how many wheel events they got; the ones that got none.
  perFrame: { 0: number; 1: number; 2: number; "3+": number };
  emptyFrames: number;
  /// Movement the WHEEL made (frames within `WHEEL_RECENT_MS` of an event), in CSS px.
  movedPx: number;
  /// How uneven the per-frame steps are: the mean distance of each step from the average of its two
  /// neighbours, over the mean step. 0 for a constant speed OR a steady acceleration; ~2 for steps that
  /// alternate full and empty.
  unevenness: number;
  eventPxMean: number;
  /// Coefficient of variation of the events' |deltaY|.
  eventPxCv: number;
  eventGapP50: number;
  eventGapP95: number;
  /// px the position moved per px of (pixel-mode) wheel delta.
  gain: number;
  /// The engine's legacy `wheelDeltaY` per `deltaY` (median) — xterm.js scrolls by the former.
  wheelRatio: number | null;
  /// Movement long after the wheel stopped: the settle onto a row.
  settlePx: number;
  settleFrames: number;
  /// The rows' redraw over the frames that ran one: its time per frame, and the rows built and reused.
  /// Null when the frames carry no counters.
  rows: { frames: number; msP50: number; msP95: number; msMax: number; built: number; reused: number } | null;
  /// What was PAINTED: every rendering update (not only those that ran animation frames — WebKit paints
  /// an input's changes at the next display refresh either way), how many ran none, and how many showed
  /// the rows a row or more from the position. Null without updates.
  painted: { updates: number; perSecond: number; withoutFrame: number; rowOff: number; maxRowsOff: number } | null;
}

/// One rendering update while recording — a ResizeObserver notification, which comes in EVERY update,
/// animation frame or not: whether one ran since the previous update, and how far the painted rows sat
/// from the position, in rows (the smooth-scroll shift included).
export interface ProbeUpdate { t: number; frame: boolean; errRows: number }

/// A painted update this far from the position shows the wrong rows. Rounding alone — smooth scrolling
/// off, the rows on xterm.js's rounded row — is at most half a row.
const ROW_OFF = 0.55;

/// A frame this long after the last wheel event is no longer the wheel's.
export const WHEEL_RECENT_MS = 150;

const median = (xs: number[]): number => {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b), m = s.length >> 1;
  return s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
};
const quantile = (xs: number[], q: number): number => {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(q * (s.length - 1)))]!;
};

/// The summary of one gesture. PURE.
export function summarizeGesture(frames: ProbeFrame[], events: ProbeEvent[], updates: ProbeUpdate[] = []): GestureSummary {
  const dts = frames.map((f) => f.dt).filter((d) => Number.isFinite(d) && d > 0);
  const usual = median(dts);
  const first = frames.findIndex((f) => f.events > 0);
  let last = -1;
  for (let i = frames.length - 1; i >= 0; i--) if (frames[i]!.events > 0) { last = i; break; }
  const active = first >= 0 ? frames.slice(first, last + 1) : [];
  const perFrame = { 0: 0, 1: 0, 2: 0, "3+": 0 };
  for (const f of active) {
    if (f.events === 0) perFrame[0]++; else if (f.events === 1) perFrame[1]++;
    else if (f.events === 2) perFrame[2]++; else perFrame["3+"]++;
  }
  const d = active.map((f) => f.moved);
  let jitter = 0;
  for (let i = 1; i + 1 < d.length; i++) jitter += Math.abs(d[i]! - (d[i - 1]! + d[i + 1]!) / 2);
  const meanStep = d.length ? d.reduce((a, v) => a + Math.abs(v), 0) / d.length : 0;
  const interior = Math.max(0, d.length - 2);
  const unevenness = interior > 0 && meanStep > 0 ? jitter / interior / meanStep : 0;

  const wheelFrames = frames.filter((f) => f.sinceWheelMs <= WHEEL_RECENT_MS);
  const settle = frames.filter((f) => f.sinceWheelMs > WHEEL_RECENT_MS && f.moved !== 0);
  const movedPx = wheelFrames.reduce((a, f) => a + Math.abs(f.moved), 0);
  const px = events.map((e) => Math.abs(e.deltaY));
  const eventPxMean = px.length ? px.reduce((a, v) => a + v, 0) / px.length : 0;
  const sd = px.length ? Math.sqrt(px.reduce((a, v) => a + (v - eventPxMean) ** 2, 0) / px.length) : 0;
  const gaps: number[] = [];
  for (let i = 1; i < events.length; i++) gaps.push(events[i]!.t - events[i - 1]!.t);
  const pixelDelta = events.filter((e) => e.deltaMode === 0).reduce((a, e) => a + Math.abs(e.deltaY), 0);
  const ratios = events.filter((e) => e.deltaY !== 0 && Number.isFinite(e.wheelDeltaY)).map((e) => e.wheelDeltaY / e.deltaY);
  return {
    frames: frames.length,
    activeFrames: active.length,
    hz: usual > 0 ? 1000 / usual : 0,
    longFrames: dts.filter((v) => v > usual * 1.5).length,
    events: events.length,
    perFrame,
    emptyFrames: perFrame[0],
    movedPx,
    unevenness,
    eventPxMean,
    eventPxCv: eventPxMean > 0 ? sd / eventPxMean : 0,
    eventGapP50: median(gaps),
    eventGapP95: quantile(gaps, 0.95),
    gain: pixelDelta > 0 ? movedPx / pixelDelta : 0,
    wheelRatio: ratios.length ? median(ratios) : null,
    settlePx: settle.reduce((a, f) => a + Math.abs(f.moved), 0),
    settleFrames: settle.length,
    rows: rowsSummary(frames),
    painted: paintedSummary(updates),
  };
}

function paintedSummary(u: ProbeUpdate[]): GestureSummary["painted"] {
  if (u.length === 0) return null;
  const span = u[u.length - 1]!.t - u[0]!.t;
  const off = u.filter((x) => Math.abs(x.errRows) > ROW_OFF);
  return { updates: u.length, perSecond: span > 0 ? (1000 * (u.length - 1)) / span : 0,
           withoutFrame: u.filter((x) => !x.frame).length, rowOff: off.length,
           maxRowsOff: off.length ? Math.max(...off.map((x) => Math.round(Math.abs(x.errRows)))) : 0 };
}

function rowsSummary(frames: ProbeFrame[]): GestureSummary["rows"] {
  if (!frames.some((f) => f.rows)) return null;
  const redrew = frames.filter((f) => f.rows && f.rows.passes > 0).map((f) => f.rows!);
  const ms = redrew.map((r) => r.ms);
  return { frames: redrew.length, msP50: median(ms), msP95: quantile(ms, 0.95), msMax: ms.length ? Math.max(...ms) : 0,
           built: redrew.reduce((a, r) => a + r.built, 0), reused: redrew.reduce((a, r) => a + r.reused, 0) };
}

/// The browser, briefly, for the overlay's first line.
function browserName(ua: string): string {
  const edge = /Edg\/(\d+)/.exec(ua), chrome = /Chrome\/(\d+)/.exec(ua), ff = /Firefox\/(\d+)/.exec(ua);
  const safari = /Version\/([\d.]+).*Safari/.exec(ua);
  if (edge) return `Edge ${edge[1]}`;
  if (chrome) return `Chrome ${chrome[1]}`;
  if (ff) return `Firefox ${ff[1]}`;
  if (safari) return `Safari ${safari[1]}`;
  return /AppleWebKit/.test(ua) ? "WebKit" : "browser";
}

/// A gesture ends this long after its last wheel event, once the view has also been still this long
/// (the settle waits 200 ms, then eases for 100 ms).
const GESTURE_IDLE_MS = 600;
const STILL_MS = 300;
/// A gesture records at most this many frames (~25 s at 120 Hz).
const MAX_FRAMES = 3000;

export interface ScrollProbeOpts {
  /// Where wheel events are heard (capture phase, passive — the probe never handles one).
  target: HTMLElement;
  /// The terminal being scrolled: the visible tab's.
  term(): Terminal | null;
  /// Whether smooth scrolling is on for it.
  smooth(): boolean;
  /// Its row cache's counters (row-cache.ts) — running totals; the probe records each frame's share.
  rowStats?(): RowCacheStats | null;
  /// Whether a scroll draws its rows with the shift (smooth-scroll.ts; off with `?scrollsync=0`).
  sync?(): boolean;
  /// Whether the wheel is resampled (wheel-resample.ts; off with `?wheelresample=0`).
  resample?(): boolean;
}

/// xterm.js's DOM renderer, the one member the probe wraps. PRIVATE.
interface ProbeRenderer { renderRows(start: number, end: number): void }

interface Recording {
  frames: ProbeFrame[]; events: ProbeEvent[]; lastTop: number; lastNow: number | null; pending: number;
  lastWheel: number; lastMove: number; start: number; cell: number; lastRows: RowCacheStats | null;
  /// Every rendering update since the gesture began, and whether an animation frame ran since the last.
  updates: ProbeUpdate[]; frameSince: boolean;
  /// The row xterm.js has DRAWN (its row at its last full redraw) — what a paint shows — and the screen.
  term: Terminal; drawnY: number; screen: HTMLElement | null;
}

/// Records wheel gestures on the terminal and shows each one's summary in an overlay.
export class ScrollProbe {
  private readonly abort = new AbortController();
  private readonly panel: HTMLElement;
  private readonly text: HTMLElement;
  private readonly canvas: HTMLCanvasElement;
  private raf: number | null = null;
  private recording: Recording | null = null;
  private last: { frames: ProbeFrame[]; events: ProbeEvent[]; updates: ProbeUpdate[]; summary: GestureSummary; cell: number;
    smooth: boolean; sync: boolean; resample: boolean } | null = null;
  /// A 1 px element whose size the probe changes at every wheel event and animation frame: its
  /// ResizeObserver notification comes in the rendering update that paints it, animation frame or not.
  private readonly sentinel: HTMLElement;
  private readonly ro: ResizeObserver | null;
  private pokes = 0;
  private hook: { rend: ProbeRenderer; inner: ProbeRenderer["renderRows"]; wrapper: ProbeRenderer["renderRows"]; own: boolean } | null = null;

  constructor(private readonly o: ScrollProbeOpts) {
    const doc = o.target.ownerDocument;
    this.panel = doc.createElement("div");
    this.panel.style.cssText = "position:fixed;top:72px;right:12px;z-index:2147483000;width:520px;padding:10px 12px;" +
      "background:rgba(12,12,16,.92);color:#e3e1e4;border:1px solid #555;border-radius:10px;" +
      "font:11px/1.45 ui-monospace,Menlo,monospace;pointer-events:auto;user-select:text;-webkit-user-select:text";
    this.text = doc.createElement("div");
    this.text.style.whiteSpace = "pre-wrap";
    this.text.textContent = "scroll probe — scroll the terminal with the trackpad, then let go";
    this.canvas = doc.createElement("canvas");
    this.canvas.style.cssText = "display:block;width:496px;height:96px;margin-top:8px";
    const dpr = doc.defaultView?.devicePixelRatio || 1;
    this.canvas.width = Math.round(496 * dpr); this.canvas.height = Math.round(96 * dpr);
    const buttons = doc.createElement("div");
    buttons.style.cssText = "display:flex;gap:8px;margin-top:8px";
    const button = (label: string, fn: () => void) => {
      const b = doc.createElement("button");
      b.type = "button"; b.textContent = label;
      b.style.cssText = "font:11px ui-monospace,Menlo,monospace;padding:3px 8px;border-radius:6px;border:1px solid #666;background:#222;color:#e3e1e4";
      b.addEventListener("click", fn, { signal: this.abort.signal });
      buttons.append(b);
      return b;
    };
    const copy = button("Copy data", () => { void this.copy(copy); });
    button("Hide", () => { this.panel.style.display = "none"; });
    const legend = doc.createElement("div");
    legend.style.cssText = "margin-top:4px;color:#aaa";
    legend.textContent = "bars: px moved per frame · blue 1 event · orange 2+ · RED none mid-gesture · grey settle";
    this.sentinel = doc.createElement("div");
    this.sentinel.style.cssText = "position:absolute;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none";
    this.panel.append(this.text, this.canvas, legend, buttons, this.sentinel);
    doc.body.append(this.panel);
    const RO = doc.defaultView?.ResizeObserver;
    this.ro = RO ? new RO(() => this.update()) : null;
    this.ro?.observe(this.sentinel);
    o.target.addEventListener("wheel", (e) => this.wheel(e as WheelEvent), { capture: true, passive: true, signal: this.abort.signal });
  }

  dispose(): void {
    this.abort.abort();
    if (this.raf !== null) cancelAnimationFrame(this.raf);
    this.raf = null;
    this.ro?.disconnect();
    this.unhook();
    this.panel.remove();
  }

  /// A new size every time — two changes between updates must not cancel out.
  private poke(): void {
    this.sentinel.style.width = `${1 + (++this.pokes % 64)}px`;
  }

  /// A rendering update is painting: how far are the rows it shows from the position?
  private update(): void {
    const r = this.recording;
    if (!r || !(r.cell > 0)) return;
    const m = /translateY\((-?[\d.e+-]+)px\)/.exec(r.screen?.style.transform ?? "");
    const shift = m ? Number(m[1]) : 0;
    const top = this.position(r.term, r.cell);
    r.updates.push({ t: performance.now(), frame: r.frameSince, errRows: (r.drawnY * r.cell - shift - top) / r.cell });
    r.frameSince = false;
  }

  /// Follow xterm.js's full redraws for the gesture: the row at each is the row the screen shows.
  private hookRenderer(r: Recording): void {
    const rend = xtermDomRenderer(r.term) as unknown as ProbeRenderer | null;
    if (!rend || typeof rend.renderRows !== "function") return;
    const own = Object.prototype.hasOwnProperty.call(rend, "renderRows"), inner = rend.renderRows;
    const self = this, term = r.term;
    const wrapper = function (this: ProbeRenderer, start: number, end: number): void {
      if (self.recording === r && start <= 0 && end >= term.rows - 1) r.drawnY = term.buffer.active.viewportY;
      inner.call(this, start, end);
    };
    rend.renderRows = wrapper;
    this.hook = { rend, inner, wrapper, own };
  }

  /// Taken off only while it is still the one installed; wrapped since, it stays, inert.
  private unhook(): void {
    const h = this.hook;
    this.hook = null;
    if (!h || h.rend.renderRows !== h.wrapper) return;
    if (h.own) h.rend.renderRows = h.inner; else delete (h.rend as Partial<ProbeRenderer>).renderRows;
  }

  /// xterm.js's fractional scroll position (its PRIVATE scrollable, as smooth-scroll.ts reads it), else
  /// the row times the cell height.
  private position(term: Terminal, cell: number): number {
    const sc = (term as unknown as { _core?: { _viewport?: { _scrollableElement?: { getScrollPosition?(): { scrollTop: number } } } } })
      ._core?._viewport?._scrollableElement;
    const top = sc?.getScrollPosition?.().scrollTop;
    return typeof top === "number" && Number.isFinite(top) ? top : term.buffer.active.viewportY * cell;
  }

  /// A COPY of the running totals — the cache mutates its own.
  private rowStats(): RowCacheStats | null {
    const s = this.o.rowStats?.();
    return s ? { ...s } : null;
  }

  private cellHeight(term: Terminal): number {
    const h = (term as unknown as { _core?: { _renderService?: { dimensions?: { css?: { cell?: { height?: number } } } } } })
      ._core?._renderService?.dimensions?.css?.cell?.height;
    return typeof h === "number" && h > 0 ? h : 0;
  }

  private wheel(e: WheelEvent): void {
    const term = this.o.term();
    if (!term) return;
    const now = performance.now();
    if (!this.recording) {
      const cell = this.cellHeight(term);
      this.recording = { frames: [], events: [], lastTop: this.position(term, cell), lastNow: null, pending: 0,
                         lastWheel: now, lastMove: now, start: now, cell, lastRows: this.rowStats(),
                         updates: [], frameSince: false, term, drawnY: term.buffer.active.viewportY,
                         screen: term.element?.querySelector<HTMLElement>(".xterm-screen") ?? null };
      this.hookRenderer(this.recording);
      this.text.textContent = "recording…";
      this.raf = requestAnimationFrame((t) => this.frame(t));
    }
    const r = this.recording;
    r.events.push({ t: now, deltaY: e.deltaY, deltaMode: e.deltaMode,
                    wheelDeltaY: (e as WheelEvent & { wheelDeltaY?: number }).wheelDeltaY ?? Number.NaN });
    r.pending++;
    r.lastWheel = now;
    this.poke();
  }

  private frame(now: number): void {
    this.raf = null;
    const r = this.recording, term = this.o.term();
    if (!r || !term) { this.recording = null; this.unhook(); return; }
    r.frameSince = true;
    this.poke();
    const top = this.position(term, r.cell);
    const moved = top - r.lastTop;
    const stats = this.rowStats(), was = r.lastRows;
    // A counter going BACKWARDS is another tab's cache (the visible tab changed): this frame has no share.
    const rows = stats && was && stats.passes >= was.passes
      ? { passes: stats.passes - was.passes, built: stats.built - was.built, reused: stats.reused - was.reused, ms: stats.ms - was.ms }
      : undefined;
    r.lastRows = stats;
    r.frames.push({ t: now, dt: r.lastNow === null ? Number.NaN : now - r.lastNow, events: r.pending, moved,
                    sinceWheelMs: now - r.lastWheel, ...(rows ? { rows } : {}) });
    r.pending = 0; r.lastTop = top; r.lastNow = now;
    if (moved !== 0) r.lastMove = now;
    const idle = now - r.lastWheel > GESTURE_IDLE_MS && now - r.lastMove > STILL_MS;
    if (idle || r.frames.length >= MAX_FRAMES) { this.finish(); return; }
    this.raf = requestAnimationFrame((t) => this.frame(t));
  }

  private finish(): void {
    const r = this.recording;
    this.recording = null;
    this.unhook();
    if (!r || r.events.length === 0) return;
    const summary = summarizeGesture(r.frames, r.events, r.updates);
    const smooth = this.o.smooth();
    this.last = { frames: r.frames, events: r.events, updates: r.updates, summary, cell: r.cell, smooth, sync: this.o.sync?.() ?? true,
                  resample: this.o.resample?.() ?? true };
    this.render(this.last);
  }

  private render(g: NonNullable<ScrollProbe["last"]>): void {
    const s = g.summary;
    const win = this.o.target.ownerDocument.defaultView;
    const pct = (n: number) => (s.activeFrames ? Math.round((100 * n) / s.activeFrames) : 0);
    const f1 = (n: number) => n.toFixed(1), f2 = (n: number) => n.toFixed(2);
    const dur = g.frames.length ? (g.frames.at(-1)!.t - g.frames[0]!.t) / 1000 : 0;
    const verdict = s.unevenness >= 0.3 || pct(s.emptyFrames) >= 10 ? "UNEVEN" : s.unevenness >= 0.15 ? "slightly uneven" : "even";
    this.text.textContent = [
      `scroll probe · ${browserName(win?.navigator.userAgent ?? "")} · ${Math.round(s.hz)} Hz · dpr ${win?.devicePixelRatio ?? 1} · smooth ${g.smooth ? "ON" : "off"} · rows with the shift ${g.sync ? "ON" : "off"} · wheel resampled ${g.resample ? "ON" : "off"} · row ${f1(g.cell)} px`,
      `gesture ${f1(dur)} s · ${s.activeFrames} frames with the wheel · ${s.events} wheel events · ${Math.round(s.movedPx)} px`,
      `events per frame  0:${s.perFrame[0]}  1:${s.perFrame[1]}  2:${s.perFrame[2]}  3+:${s.perFrame["3+"]}   empty ${pct(s.emptyFrames)}%`,
      `step unevenness ${f2(s.unevenness)} → ${verdict}   (even ≤ 0.15 · visible ≳ 0.3)`,
      `long frames ${s.longFrames} · event ${f1(s.eventPxMean)} px avg (cv ${f2(s.eventPxCv)}) · gap p50 ${f1(s.eventGapP50)} p95 ${f1(s.eventGapP95)} ms`,
      `gain ${f2(s.gain)} px per wheel px · wheelDeltaY/deltaY ${s.wheelRatio === null ? "—" : f2(s.wheelRatio)} · settle ${s.settleFrames} frames, ${f1(s.settlePx)} px`,
      ...(s.rows ? [`rows redrawn in ${s.rows.frames} frames · ${f2(s.rows.msP50)} ms p50 · ${f2(s.rows.msP95)} p95 · ${f2(s.rows.msMax)} max · ` +
        `built ${s.rows.built} · reused ${s.rows.reused} (${s.rows.built + s.rows.reused ? Math.round((100 * s.rows.reused) / (s.rows.built + s.rows.reused)) : 0}%)`] : []),
      ...(s.painted ? [`painted ${s.painted.updates} updates (${Math.round(s.painted.perSecond)}/s), ${s.painted.withoutFrame} without an animation frame · ` +
        `${s.painted.rowOff} showed the rows a row or more off${s.painted.rowOff ? ` (max ${s.painted.maxRowsOff})` : ""}`] : []),
    ].join("\n");
    this.draw(g);
  }

  /// One bar per frame of the gesture: its step in px. Blue got one event, orange two or more, RED got
  /// none while the wheel was going (an empty frame), grey is the settle after it.
  private draw(g: NonNullable<ScrollProbe["last"]>): void {
    const c = this.canvas, ctx = c.getContext("2d");
    if (!ctx) return;
    ctx.clearRect(0, 0, c.width, c.height);
    const frames = g.frames.slice(-c.width);   // at most one device pixel per bar
    const first = frames.findIndex((f) => f.events > 0);
    let last = -1;
    for (let i = frames.length - 1; i >= 0; i--) if (frames[i]!.events > 0) { last = i; break; }
    const max = Math.max(1, ...frames.map((f) => Math.abs(f.moved)));
    const w = c.width / Math.max(1, frames.length);
    frames.forEach((f, i) => {
      const inWheel = i >= first && i <= last;
      ctx.fillStyle = f.sinceWheelMs > WHEEL_RECENT_MS ? "#777" : f.events === 0 ? (inWheel ? "#ff4d4d" : "#555")
        : f.events === 1 ? "#5aa9ff" : "#ffb347";
      // An empty frame mid-gesture moved nothing: a red stub a fifth of the chart tall marks it.
      const h = Math.max(inWheel && f.events === 0 ? c.height * 0.2 : 1, (Math.abs(f.moved) / max) * (c.height - 2));
      ctx.fillRect(Math.floor(i * w), c.height - h, Math.max(1, Math.floor(w) - (w > 3 ? 1 : 0)), h);
    });
  }

  private async copy(button: HTMLButtonElement): Promise<void> {
    const g = this.last;
    if (!g) return;
    const win = this.o.target.ownerDocument.defaultView;
    const data = JSON.stringify({ ua: win?.navigator.userAgent, dpr: win?.devicePixelRatio, smooth: g.smooth, sync: g.sync, resample: g.resample, cell: g.cell,
      summary: g.summary, frames: g.frames.map((f) => [+f.t.toFixed(2), +f.dt.toFixed(2), f.events, +f.moved.toFixed(3), +f.sinceWheelMs.toFixed(1),
        ...(f.rows ? [f.rows.passes, f.rows.built, f.rows.reused, +f.rows.ms.toFixed(3)] : [])]),
      events: g.events.map((e) => [+e.t.toFixed(2), e.deltaY, e.deltaMode, e.wheelDeltaY]),
      updates: g.updates.map((u) => [+u.t.toFixed(2), u.frame ? 1 : 0, +u.errRows.toFixed(3)]) });
    try { await win?.navigator.clipboard.writeText(data); button.textContent = "Copied"; }
    catch { button.textContent = "Copy failed"; }
    setTimeout(() => { button.textContent = "Copy data"; }, 1500);
  }
}
