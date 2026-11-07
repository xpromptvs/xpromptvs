import { contextFor, activeWithin } from "./instance/context";
/// THE MENU every long press and right-click opens — the tab bar's, the terminal's and a window's
/// (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §2.1; the tab menu's design is
/// docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md §4). A MANUAL popover in the top layer,
/// which this dismisses itself: a press outside, Escape (in the CAPTURE phase, before a focused terminal
/// takes it as a keystroke for the shell), a resize, the window blurring.
///
/// THE PRESS THAT CLOSES A MENU IS SWALLOWED WHOLE (asked for 2026-10-01; until 2026-10-02 it "still did what
/// it does"): it closes the menu and nothing else — no tab switched, no caret put in the terminal (on a phone
/// that raises the keyboard), no strip key, no click through a window's picture onto the Mac, no drag or hold
/// begun, no browser menu and no other menu on a right-click. Taken in the WINDOW'S CAPTURE phase, so no
/// element or document listener sees any of it: its pointer's down, moves and release, its touches, the
/// compatibility mouse events, `click`, `dblclick`, `auxclick` and `contextmenu`. The down and the touch's
/// release are PREVENTED — no compatibility mouse events, no synthesized click, no focus moved — and, as after
/// a hold (`press-hold.ts`), the mouse events iOS synthesizes LATE are swallowed for `CLICK_SWALLOW_MS` after
/// the release. ONE click is the press's. WHILE IT IS DOWN nothing but a blur ends it: a key does not, and a
/// second finger landing is the press's too (swallowed whole, its release as well — a gesture that began by
/// closing a menu is all the menu's); a blur does at any time, since a release outside the window may never
/// come. Once it is released, the next real press, a key or a blur ends it at once.
/// A swipe that starts outside still pans what the BROWSER pans (the touches are only stopped, never
/// prevented: a non-passive window `touchmove` would make every scroll in the app wait on the main thread).
import { CLICK_SWALLOW_MS } from "./press-hold";

export interface MenuItem { action: string; label: string; disabled?: boolean; selected?: boolean }
export interface Box { left: number; top: number; right: number; bottom: number }
export interface Area { left: number; top: number; width: number; height: number }

/// The menu keeps this far from the visible area's edges.
const MENU_MARGIN_PX = 8;
const MENU_GAP_PX = 4;

/// Where the menu goes: under the anchor and aligned with it (above when there is no room below), or at
/// the pointer for a right-click — always inside the VISIBLE area, which a soft keyboard moves. `above`: the
/// other way round, as a text selection's menu goes (iOS's own) — the selection's handles are below it. `gap`:
/// how far from the anchor (the handles' knobs need clearing).
export function menuPosition(anchor: Box, menu: { width: number; height: number }, view: Area,
                             at?: { x: number; y: number }, opts: { above?: boolean; gap?: number } = {}): { left: number; top: number } {
  const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(v, Math.max(lo, hi)));
  const minX = view.left + MENU_MARGIN_PX, maxX = view.left + view.width - menu.width - MENU_MARGIN_PX;
  const minY = view.top + MENU_MARGIN_PX, maxY = view.top + view.height - menu.height - MENU_MARGIN_PX;
  if (at) return { left: clamp(at.x, minX, maxX), top: clamp(at.y, minY, maxY) };
  const gap = opts.gap ?? MENU_GAP_PX;
  const below = anchor.bottom + gap, above = anchor.top - gap - menu.height;
  const top = opts.above ? (above >= minY ? above : below) : (below > maxY ? above : below);
  return { left: clamp(anchor.left, minX, maxX), top: clamp(top, minY, maxY) };
}

/// Every menu of a live session. ONE MENU AT A TIME: the tab bar's, the terminal's and a window's are
/// separate instances, and opening one closes whichever other is up — two menus over each other would
/// each claim the next press.
const menus = new Set<ContextMenu>();

export class ContextMenu {
  private el: HTMLElement | null = null;
  /// The press that closed this menu, being swallowed: its pointers (the first, and any that landed while it
  /// was down) until each is released, whether the FIRST is still down, and — once it is released — until
  /// when (`Date.now()`) the events that trail it are still its.
  private press: { ids: Set<number>; first: number; down: boolean; until: number } | null = null;
  /// Presses that close the menu WITHOUT being swallowed (`open`'s `passThrough`): a terminal selection's handles.
  private passThrough: ((n: Node | null) => boolean) | null = null;

  constructor(private readonly signal: AbortSignal, private readonly onPick: (action: string) => void,
              private readonly onClosed?: () => void, private readonly extraClass?: string, private readonly owner?: HTMLElement) {
    const opts = { signal };
    if (!signal.aborted) menus.add(this);
    // Escape closes the menu BEFORE anything else sees it — a focused terminal would otherwise take it as
    // a keystroke for the shell (and xterm.js's handling cancels the popover's own).
    window.addEventListener("keydown", (e) => {
      if (!this.owns(e)) return;
      if (!this.press?.down) this.press = null;           // a key DURING the press does not end it
      if (!this.isOpen) return;
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        this.close();
      } else if ((e.key === "ArrowDown" || e.key === "ArrowUp") && this.el?.contains(this.activeElement())) {
        e.preventDefault();
        this.step(e.key === "ArrowDown" ? 1 : -1);
      }
    }, { signal, capture: true });
    // The menu goes on a press anywhere else — which is SWALLOWED WHOLE (above) —, a resize, or the window
    // losing focus.
    const capture = { signal, capture: true };
    const swallow = (e: Event) => { if (e.cancelable) e.preventDefault(); e.stopImmediatePropagation(); };
    const holding = () => !!this.press && (this.press.down || Date.now() < this.press.until);
    const own = (e: PointerEvent) => !!this.press?.ids.has(e.pointerId);
    window.addEventListener("pointerdown", (e) => {
      if (!this.owns(e)) return;
      if (this.isOpen && !this.contains(e.composedPath()[0] as Node | null)) {
        this.close();
        if (this.passThrough?.(e.composedPath()[0] as Node | null)) return;   // the menu goes; the press is the target's
        this.press = { ids: new Set([e.pointerId]), first: e.pointerId, down: true, until: 0 };
        swallow(e);
      } else if (this.press?.down) {
        this.press.ids.add(e.pointerId);                    // a finger landing while it is held is its too
        swallow(e);
      } else if (this.press) {
        this.press = null;                                  // the next real press is its own
      }
    }, capture);
    window.addEventListener("pointermove", (e) => { if (own(e)) e.stopImmediatePropagation(); }, capture);
    for (const type of ["pointerup", "pointercancel"] as const) {
      window.addEventListener(type, (e) => {
        const p = this.press;
        if (!p || !own(e)) return;
        e.stopImmediatePropagation();
        p.ids.delete(e.pointerId);
        if (e.pointerId === p.first) { p.down = false; p.until = Date.now() + CLICK_SWALLOW_MS; }
      }, capture);
    }
    // PASSIVE: stopping is all a start or a move needs, and a non-passive one would hold every scroll.
    for (const type of ["touchstart", "touchmove"] as const) {
      window.addEventListener(type, (e) => { if (this.owns(e) && holding()) e.stopImmediatePropagation(); }, { ...capture, passive: true });
    }
    for (const type of ["touchend", "touchcancel"] as const) {
      window.addEventListener(type, (e) => { if (this.owns(e) && holding()) swallow(e); }, { ...capture, passive: false });
    }
    for (const type of ["mousedown", "mouseup", "dblclick", "auxclick", "contextmenu"] as const) {
      window.addEventListener(type, (e) => { if (this.owns(e) && holding()) swallow(e); }, capture);
    }
    window.addEventListener("click", (e) => {
      if (!this.owns(e) || !holding()) return;
      swallow(e);
      this.press = null;                                    // ONE click is the press's
    }, capture);
    window.addEventListener("resize", () => this.close(), opts);
    window.addEventListener("blur", () => { this.press = null; this.close(); }, opts);
    signal.addEventListener("abort", () => {
      menus.delete(this);
      this.el?.remove();
      this.el = null;
    });
  }

  private get context() { return this.owner ? contextFor(this.owner) : undefined; }
  private owns(e: Event): boolean { return !this.context || this.context.input.owns(e); }
  private activeElement() { return this.owner ? activeWithin(this.owner) : document.activeElement; }
  get isOpen(): boolean { return this.context ? !!this.el && !this.el.hidden : this.el?.matches(":popover-open") ?? false; }
  contains(n: Node | null): boolean { return !!n && !!this.el?.contains(n); }

  /// Open with `items`: under `anchor`, or at `at` (a right-click's pointer). False where there is no
  /// Popover API: NO TOP LAYER, NO MENU — the bar CLIPS, so a menu anywhere below the top layer is cut
  /// off by whatever holds its anchor. Every engine the product targets has it. `passThrough`: presses that
  /// close it and still reach what they land on (a terminal selection's handles, touch-selection.ts); `above`
  /// and `gap`: where it goes against `anchor` (`menuPosition`).
  open(items: readonly MenuItem[], anchor: DOMRect | null, at?: { x: number; y: number },
       opts: { parent?: HTMLElement; passThrough?: (n: Node | null) => boolean; above?: boolean; gap?: number } = {}): boolean {
    if (!this.context && typeof HTMLElement.prototype.showPopover !== "function") return false;
    for (const m of menus) if (m !== this && m.context === this.context) m.close();
    this.passThrough = opts.passThrough ?? null;
    const el = this.ensure();
    if (this.isOpen) this.close();
    (this.context?.ui ?? opts.parent ?? document.body).append(el);
    el.replaceChildren(...items.map((it) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "ctx-menu-item";
      b.dataset.action = it.action;
      b.setAttribute("role", it.selected === undefined ? "menuitem" : "menuitemradio");
      if (it.selected !== undefined) b.setAttribute("aria-checked", String(it.selected));
      b.textContent = it.label;
      b.disabled = !!it.disabled;
      return b;
    }));
    el.style.left = "0px";
    el.style.top = "0px";
    if (this.context) { el.removeAttribute("popover"); el.hidden=false; el.style.zIndex="250"; } else el.showPopover();
    const r = el.getBoundingClientRect();
    const vv = window.visualViewport;
    const view = this.context?.viewport.rect() ?? (vv ? { left: vv.offsetLeft, top: vv.offsetTop, width: vv.width, height: vv.height }
                    : { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight });
    const box = anchor ?? { left: at?.x ?? 0, top: at?.y ?? 0, right: at?.x ?? 0, bottom: at?.y ?? 0 };
    const pos = menuPosition(box, { width: r.width, height: r.height }, view, at, { above: opts.above, gap: opts.gap });
    el.style.left = `${Math.round(pos.left - (this.context?.viewport.rect().left ?? 0))}px`;
    el.style.top = `${Math.round(pos.top - (this.context?.viewport.rect().top ?? 0))}px`;
    return true;
  }

  focusFirst(): void { this.el?.querySelector<HTMLButtonElement>(".ctx-menu-item:not(:disabled)")?.focus(); }

  close(): void {
    if (!this.isOpen) return;
    if (this.context) { this.el!.hidden = true; this.onClosed?.(); } else this.el!.hidePopover();
  }

  private ensure(): HTMLElement {
    if (this.el) return this.el;
    const el = document.createElement("div");
    el.className = `ctx-menu${this.extraClass ? ` ${this.extraClass}` : ""}`;
    // MANUAL, NOT `auto`: an auto popover's light dismiss closes on the release of the very press that
    // opened it — a right-click's mouseup, a held finger's lift — since both land outside it. Measured:
    // the menu never stayed open. The listeners above do the dismissing instead.
    el.setAttribute("popover", "manual");
    el.setAttribute("role", "menu");
    // A press on the menu must not take focus: the terminal or a window's input keeps it, and on a phone
    // its blur would drop the soft keyboard. A pick that wants focus moves it itself.
    el.addEventListener("mousedown", (e) => e.preventDefault());
    el.addEventListener("click", (e) => {
      const b = (e.target as Element).closest<HTMLButtonElement>(".ctx-menu-item");
      if (!b || b.disabled) return;
      // The pick FIRST, while the menu is still the one it was opened as: the tab bar's reads the tab its
      // `onClosed` forgets. (A browser fires `toggle` a task later, so the other order only happened to work.)
      try { this.onPick(b.dataset.action!); } finally { this.close(); }
    });
    el.addEventListener("toggle", (e) => {
      if ((e as ToggleEvent).newState === "closed") this.onClosed?.();
    });
    if (this.context) { el.removeAttribute("popover"); el.hidden=true; }
    (this.context?.ui ?? document.body).append(el);
    this.el = el;
    return el;
  }

  private step(d: 1 | -1): void {
    const items = [...this.el!.querySelectorAll<HTMLButtonElement>(".ctx-menu-item:not(:disabled)")];
    const at = items.indexOf(this.activeElement() as HTMLButtonElement);
    items[(at + d + items.length) % items.length]?.focus();
  }
}
