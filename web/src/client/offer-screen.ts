import { Inflate } from "fflate";
import type { Theme } from "../shared/theme";
import { mountXterm, type XtermView, type XtermViewOpts } from "./xterm-view";

// THE OFFER'S SCREEN (2026-10-05, asked for: "maybe we could even send the measurements on join, the host would
// change tab size, then send the focused tab contents together with tab names?"; docs/sources-and-focus.md, "The
// offer carries the tab bar"). The page says its terminal grid as it joins — `client-confirm`'s app_hello, inside
// its §11 session — the host resizes every tab to it as that page's own `resize` would, and the host's first offer
// carries the active tab's SCREEN at that grid beside the tab bar. The page paints it, inert, under the tab's slot
// until the terminal channel's own snapshot fades in over it.

export interface Grid { cols: number; rows: number }

/// What the page says as it joins (`client-confirm`'s app_hello; `JoinHello` on the host), inside its §11 session:
/// its JOIN INTENT (docs/sources-and-focus.md, "The join intent") and its terminal grid — without a grid the host
/// resizes nothing and the offer carries no screen.
export function joinHello(said: { grid: Grid | null; intent: "connect" | "reconnect"; fastData?: 1 }): Uint8Array {
  const { grid, intent } = said;
  return new TextEncoder().encode(JSON.stringify({ ...(grid ? { grid: { cols: grid.cols, rows: grid.rows } } : {}), intent, ...(said.fastData === 1 ? {fastData: 1} : {}) }));
}

/// The offer's `term-screen`: a tab's screen as a FRESH instance at `cols`×`rows` is written it, no scrollback.
export interface TermScreen { id: string; cols: number; rows: number; bytes: Uint8Array }

/// `{t:"term-screen", id, cols, rows, data}` — `data` one raw-DEFLATE stream (as the terminal channel's), base64.
/// Null for anything else, and for a payload that does not inflate: the screen is a nicety, never a fault.
export function parseTermScreen(msg: unknown): TermScreen | null {
  const m = msg as { t?: unknown; id?: unknown; cols?: unknown; rows?: unknown; data?: unknown } | null;
  if (!m || m.t !== "term-screen" || typeof m.id !== "string" || typeof m.data !== "string") return null;
  const { cols, rows } = m;
  if (!Number.isInteger(cols) || !Number.isInteger(rows) || (cols as number) < 1 || (rows as number) < 1) return null;
  try {
    const packed = Uint8Array.from(atob(m.data), (c) => c.charCodeAt(0));
    const parts: Uint8Array[] = [];
    new Inflate((b) => { parts.push(b); }).push(packed);
    const bytes = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let at = 0;
    for (const p of parts) { bytes.set(p, at); at += p.length; }
    return { id: m.id, cols: cols as number, rows: rows as number, bytes };
  } catch {
    return null;
  }
}

/// How long the preview stays under a tab whose content has come: the slot's first-content fade (180 ms) and a frame
/// or two — under WebGPU nothing synchronizes the DOM with the canvas's first draw (docs/client-web.md).
export const PREVIEW_HANDOVER_MS = 260;
/// …and how long at most, whatever happens: a terminal channel that never delivers leaves no stale picture.
export const PREVIEW_MAX_MS = 10_000;

/// **THE OFFER'S SCREEN ON SCREEN**: one INERT instance in the terminal area — DOM renderer, no input, no replies,
/// no focus (`inert`) — UNDER the tab slots (`.xterm-preview`, before them in `#xterm`), showing the active tab's
/// screen until the deck shows that tab's own content over it, or until anything says it is not what will show.
export class TermPreview {
  private el: HTMLElement | null = null;
  private view: XtermView | null = null;
  private timer: ReturnType<typeof setTimeout> | undefined;
  /// The tab whose screen is shown, or null.
  tab: string | null = null;

  constructor(private readonly container: HTMLElement,
              private readonly mount: (el: HTMLElement, opts: XtermViewOpts) => XtermView = mountXterm) {}

  show(screen: TermScreen, opts: { fontSize: number; theme: Theme }): void {
    this.remove();
    const el = document.createElement("div");
    el.className = "xterm-preview";
    el.inert = true;
    el.setAttribute("aria-hidden", "true");
    const inst = document.createElement("div");
    inst.className = "xterm-inst";
    el.append(inst);
    // UNDER every slot: before the first, after the area's canvas (webgpu/surface.ts) — slots the deck adds later
    // are appended after it.
    this.container.insertBefore(el, this.container.querySelector(":scope > .xterm-tab"));
    const view = this.mount(inst, {
      fontSize: opts.fontSize, theme: opts.theme, renderer: "dom",
      widths: screen.id.startsWith("tmux:") ? "tmux" : "pty",
      onData: () => {}, onReply: () => {}, onFit: () => {},
    });
    view.resizeTo(screen.cols, screen.rows);
    view.write(screen.bytes);
    this.el = el; this.view = view; this.tab = screen.id;
    this.timer = setTimeout(() => this.remove(), PREVIEW_MAX_MS);
  }

  /// Gone — at once, or `afterMs` later (the real slot fading in over it).
  remove(afterMs = 0): void {
    clearTimeout(this.timer);
    if (afterMs > 0 && this.el) { this.timer = setTimeout(() => this.remove(), afterMs); return; }
    this.view?.dispose();
    this.el?.remove();
    this.el = null; this.view = null; this.tab = null;
  }
}
