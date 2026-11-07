import { contextFor, activeWithin } from "./instance/context";
import { openClientDialog, closeClientDialog } from "./instance/overlays";
/// The tab bar's GESTURES: a menu on a right-click or a held finger (Rename, Close, and whatever the session
/// adds — the paste items), renaming a tab in an OVERLAY ALERT (2026-10-04, asked for; it was a field in place of
/// the label), and dragging a tab anywhere in the bar
/// (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md §4).
///
/// It owns no tabs. `TerminalTabs` and `WindowTabs` render them, every arrangeable `.rl-tab` carrying
/// `data-tab-key`, and this listens on the scroller that holds both strips. What a key MEANS — its
/// field, what Close does, what a drop asks the host for — is the session's (`TabBarCallbacks`).
///
/// WHILE A TAB IS PRESSED OR DRAGGED THE BAR IS `busy`, and the strips DEFER their re-render: a `term-list`
/// arrives on every title change, and rebuilding the strip DETACHED the tab under a finger, whose touch and
/// pointer events then reached no listener in the document, so a held tab could not be carried (and destroyed
/// the in-place rename field under the person typing, while there was one). `settled` is the cue to render what
/// waited.
import { ContextMenu, type MenuItem } from "./context-menu";
import { renameIntent, type RenameField } from "./tab-name";

// The menu moved to `context-menu.ts` (the terminal and a window open the same one); its position rule is
// still reachable from here.
export { menuPosition } from "./context-menu";

export interface TabBarCallbacks {
  /// Whether this client may arrange the bar — the driver. A passive client gets no menu and no drag.
  enabled(): boolean;
  /// The field Rename opens for `key`, or null when it cannot be renamed.
  renameField(key: string): RenameField | null;
  /// Ask the host to name `key` `name` (`""` clears a name).
  rename(key: string, name: string): void;
  /// Exactly what the tab's own `×` (or a window's titlebar `×`) does.
  close(key: string): void;
  /// `key` was dropped just before `before`; null — at the end of the bar.
  move(key: string, before: string | null): void;
  /// What the menu offers for `key` AFTER Rename and Close — the session's paste items. The bar knows nothing
  /// of what they do: a pick goes back through `onExtra`, by key.
  extraItems?(key: string): MenuItem[];
  /// One of `extraItems(key)` was picked — called inside the item's click, so a pick that needs the user
  /// activation (reading the clipboard, opening the picker) still has it.
  onExtra?(key: string, action: string): void;
  /// A rename or a drag ended: render whatever the strips deferred meanwhile.
  settled(): void;
}

// The hold's timing lives with the shared gesture module; the tab bar's own hold also starts a DRAG,
// which `press-hold.ts` deliberately does not, so its gesture code stays here.
import { HOLD_MS, TOUCH_SLOP_PX } from "./press-hold";
export { HOLD_MS, TOUCH_SLOP_PX };
/// How far a mouse may move and still be clicking.
export const MOUSE_SLOP_PX = 4;
/// Within this distance of the scroller's edge a drag scrolls the bar, faster nearer the edge.
const EDGE_PX = 40;
const EDGE_MAX_SPEED_PX = 12;
/// How long after a drag or a hold ends its click is still swallowed. NOT one task: iOS dispatches the
/// click it makes of a touch through its gesture system, after the touch sequence (review M3). A new
/// press ends it at once.
const CLICK_SWALLOW_MS = 600;
/// Where a dragged tab lands among the OTHER tabs: how many of their centres (in bar order) its own
/// centre has passed.
export function dropSlot(otherCenters: readonly number[], draggedCenter: number): number {
  return otherCenters.filter((c) => c < draggedCenter).length;
}

/// The slot a tab at `me`, dragged by `dx`, sits over among `others` (in bar order) — read at its LEADING
/// edge, the left one going left and the right one going right; at rest, its centre.
///
/// NOT THE CENTRE WHILE MOVING: the drag is clamped to the bar's ends, and a tab wider than the first one
/// still had its centre past the first tab's at the clamp — it could never be dropped first, nor, wider
/// than the last, last (`tab-menu-check` T2c found it).
export function dragSlot(others: readonly { left: number; width: number }[], me: { left: number; width: number },
                         dx: number): number {
  const probe = dx < 0 ? me.left + dx : dx > 0 ? me.left + me.width + dx : me.left + me.width / 2;
  return dropSlot(others.map((o) => o.left + o.width / 2), probe);
}

/// How many slots the other tab at `j` (its index among the others) steps to make room — -1 left, +1
/// right, 0 none — when the tab dragged from bar index `from` sits over slot `slot`.
export function shiftSteps(j: number, from: number, slot: number): number {
  const before = j < from ? j : j + 1;     // its bar index with the dragged tab still in place
  const after = j < slot ? j : j + 1;      // and with the dragged tab moved to `slot`
  return after - before;
}

/// A span along the bar: a tab's, or the scroller's view.
export interface Span { left: number; right: number }

/// The scroll position that shows `tab` WHOLE inside `view` (both in the scroller's own pixels, as it scrolls now),
/// moving the bar as little as it can (`TabBar.revealSelected`): where it is when the tab already shows whole; the
/// tab's start at the view's start when it is off to the left — or wider than the view — and its end at the view's
/// end when it is off to the right.
export function revealScroll(scrollLeft: number, view: Span, tab: Span): number {
  if (tab.left < view.left || tab.right - tab.left > view.right - view.left) return scrollLeft + tab.left - view.left;
  if (tab.right > view.right) return scrollLeft + tab.right - view.right;
  return scrollLeft;
}

/// A press on a tab, by KEY: a strip rebuilt meanwhile (a `term-list` lands during a hold — the bar is
/// not busy until a drag or a field starts) replaces the element under the finger.
interface Gesture {
  id: number; touch: boolean; key: string;
  x0: number; y0: number; held: boolean; timer: number | null;
}
interface Slot { el: HTMLElement; key: string; left: number; width: number }
interface Drag {
  key: string; slots: Slot[]; from: number; step: number;
  x0: number; scroll0: number; lastX: number; slot: number;
  speed: number; raf: number;
}
interface Edit { key: string; field: RenameField }
/// The rename alert, built once per bar (`renameUi`).
interface RenameUi { dialog: HTMLDialogElement; title: HTMLElement; input: HTMLInputElement }

export class TabBar {
  private readonly menu: ContextMenu;
  private menuKey: string | null = null;
  private gesture: Gesture | null = null;
  private drag: Drag | null = null;
  private edit: Edit | null = null;
  private rename: RenameUi | null = null;
  /// Until when (`Date.now()`) a click on the bar is the end of a drag or a hold, not a press of its own.
  private swallowClicksUntil = 0;
  private focusBefore: HTMLElement | null = null;
  /// What held focus as the last press on the bar BEGAN — before Chromium's mousedown moved it onto the
  /// tab button (review M4).
  private focusAtPress: HTMLElement | null = null;

  constructor(private readonly scroller: HTMLElement, private readonly cb: TabBarCallbacks,
              private readonly signal: AbortSignal) {
    const opts = { signal };
    this.menu = new ContextMenu(signal, (a) => this.onMenuPick(a), () => {
      this.menuKey = null;
      this.markMenuTab(null);
    }, undefined, scroller);
    scroller.addEventListener("contextmenu", (e) => this.onContextMenu(e), opts);
    scroller.addEventListener("pointerdown", (e) => this.onPointerDown(e), opts);
    window.addEventListener("pointermove", (e) => this.onPointerMove(e), opts);
    window.addEventListener("pointerup", (e) => this.onPointerEnd(e, false), opts);
    window.addEventListener("pointercancel", (e) => this.onPointerEnd(e, true), opts);
    // ONCE A FINGER HAS HELD, the bar must not scroll under it — the drag owns the motion. Non-passive,
    // and registered before any touch starts, or the browser may already have committed to its pan.
    scroller.addEventListener("touchmove", (e) => {
      if (this.gesture?.held || this.drag) e.preventDefault();
    }, { signal, passive: false });
    // A drag or a hold ENDS in a click on the tab it started on; that click must not switch tabs.
    scroller.addEventListener("click", (e) => {
      if (Date.now() >= this.swallowClicksUntil) return;
      this.swallowClicksUntil = 0;
      e.stopPropagation();
      e.preventDefault();
    }, { signal, capture: true });
    // A right-click must not take focus either (Chromium focuses a button on any mousedown): the menu's
    // Rename gives focus BACK to what held it, and keys to a window are gated on where focus is.
    scroller.addEventListener("mousedown", (e) => {
      if (e.button === 2 && this.tabFrom(e.target) && this.cb.enabled()) e.preventDefault();
    }, opts);
    // Escape cancels a drag BEFORE anything else sees it — a focused terminal would otherwise take it as a
    // keystroke for the shell. (The menu's own Escape is `ContextMenu`'s.)
    window.addEventListener("keydown", (e) => {
      if ((!contextFor(scroller) || contextFor(scroller)!.input.owns(e)) && e.key === "Escape" && this.drag) {
        e.preventDefault();
        e.stopPropagation();
        // The GESTURE goes too, or the next move would start the drag again and the release drop it.
        this.cancelGesture();
      }
    }, { signal, capture: true });
    // The menu also goes with a scroll of the bar under it.
    scroller.addEventListener("scroll", () => this.closeMenu(), opts);
    // Losing the window loses the pointer: its release may never arrive (review M6).
    window.addEventListener("blur", () => this.cancelGesture(), opts);
    signal.addEventListener("abort", () => {
      this.dropGesture();                      // its hold timer with it: no menu over the dashboard (M8)
      this.endDrag(false, false);
    });
  }

  /// A press or a drag is in progress: the strips must not rebuild the tabs under it. (A rename is in its own
  /// alert, which a rebuild cannot touch.)
  get busy(): boolean { return this.gesture !== null || this.drag !== null; }
  get editingKey(): string | null { return this.edit?.key ?? null; }

  /// Scroll the bar so the SELECTED tab — the one on screen (`.rl-tab.on`) — shows whole (`revealScroll`), its view
  /// the scroller's box inside its padding: the room the tab's curved foot takes, where the first tab sits at rest.
  /// Nothing under a press or a drag. Whether there was a tab to show.
  revealSelected(): boolean {
    if (this.busy) return false;
    const r = this.scroller.querySelector<HTMLElement>(".rl-tab.on")?.getBoundingClientRect();
    if (!r || r.width === 0) return false;
    const box = this.scroller.getBoundingClientRect();
    // A rect carries every transform on the way (the session's slide); the scroll position is the scroller's own px.
    const k = this.scroller.offsetWidth > 0 ? box.width / this.scroller.offsetWidth : 1;
    const cs = getComputedStyle(this.scroller);
    const view = { left: parseFloat(cs.paddingLeft) || 0, right: this.scroller.clientWidth - (parseFloat(cs.paddingRight) || 0) };
    const tab = { left: (r.left - box.left) / k, right: (r.right - box.left) / k };
    this.scroller.scrollLeft = revealScroll(this.scroller.scrollLeft, view, tab);
    return true;
  }

  /// The element that held focus as the bar was touched — given back when a rename ends, so typing goes
  /// on where it was (the terminal, or a window's hidden input) rather than into nothing.
  rememberFocus(): void {
    const a = activeWithin(this.scroller);
    // Focus ON THE BAR is the press's own doing (a tab button Chromium focused): what held it before is
    // what typing goes back to.
    const own = a === null || a === document.body || this.scroller.contains(a);
    this.focusBefore = own ? this.focusAtPress : a instanceof HTMLElement ? a : null;
    this.focusAtPress = null;
  }

  /// End a press or a drag without anything it would have done — no drop, no switch: the client went
  /// passive, Escape, the window lost focus, or a press whose end never came.
  cancelGesture(): void {
    if (!this.gesture && !this.drag) return;
    if (this.drag) {
      this.dropGesture();
      this.endDrag(false);
      this.swallowClicks();
    } else {
      this.clearGesture();
    }
  }

  // MARK: the menu

  /// Open the menu for `key`: under its tab, or at `at` (a right-click's pointer).
  openMenu(key: string, at?: { x: number; y: number }): void {
    const tab = this.tabEl(key);
    if (!tab) return;
    const items: MenuItem[] = [
      { action: "rename", label: "Rename", disabled: this.cb.renameField(key) === null },
      { action: "close", label: "Close" },
      // The session's, after the bar's own two: on a phone a window's titlebar is all controls (its title is
      // hidden), so the tab is where a finger can ask to paste into it.
      ...(this.cb.extraItems?.(key) ?? []),
    ];
    if (!this.menu.open(items, tab.getBoundingClientRect(), at)) return;
    // AFTER open: reopening hides the old one first, and its `toggle` clears the key.
    this.menuKey = key;
    this.markMenuTab(tab);
  }

  closeMenu(): void {
    this.menu.close();
  }

  private onMenuPick(action: string): void {
    const key = this.menuKey;
    if (key === null) return;
    if (action === "rename") this.beginRename(key);
    else if (action === "close") this.cb.close(key);
    else this.cb.onExtra?.(key, action);
  }

  private markMenuTab(tab: HTMLElement | null): void {
    for (const t of this.scroller.querySelectorAll(".rl-tab.menu-open")) t.classList.remove("menu-open");
    tab?.classList.add("menu-open");
  }

  private onContextMenu(e: MouseEvent): void {
    const tab = this.tabFrom(e.target);
    if (!tab || (e.target as Element).closest(".rl-tab-rename") || !this.cb.enabled()) return;
    e.preventDefault();
    // A TOUCH HOLD IS OURS (Android fires `contextmenu` on its own long press, at its own time).
    if (this.gesture?.touch) return;
    this.rememberFocus();
    // A keyboard's context-menu key carries no pointer position: anchor to the tab, and let the keys in.
    const keyboard = e.clientX === 0 && e.clientY === 0;
    this.openMenu(tab.dataset.tabKey!, keyboard ? undefined : { x: e.clientX, y: e.clientY });
    if (keyboard) this.menu.focusFirst();
  }

  // MARK: press, hold, drag

  private onPointerDown(e: PointerEvent): void {
    this.swallowClicksUntil = 0;
    const tab = this.tabFrom(e.target);
    if (!tab || (e.target as Element).closest(".rl-tab-rename") || !this.cb.enabled()) return;
    // BEFORE anything moves focus (the mousedown that follows this event does): see `rememberFocus`.
    const a = activeWithin(this.scroller);
    this.focusAtPress = a instanceof HTMLElement && a !== document.body && !this.scroller.contains(a) ? a : null;
    if (this.gesture) {
      // Another pointer while one is down. A SECOND finger (not primary) is not a press of its own. A
      // PRIMARY pointer — a mouse always is, a finger when no other is down — means the gesture's end was
      // lost, and it must not hold the bar, or ignore every later touch, for good (review M6).
      if (e.isPrimary === false) return;
      this.cancelGesture();
    }
    const touch = e.pointerType !== "mouse";
    // ⌃-click is a right click on a Mac: its `contextmenu` follows, and it must not start a drag.
    if (!touch && (e.button !== 0 || e.ctrlKey)) return;
    this.gesture = {
      id: e.pointerId, touch, key: tab.dataset.tabKey!, x0: e.clientX, y0: e.clientY, held: false,
      timer: touch ? window.setTimeout(() => this.onHold(), HOLD_MS) : null,
    };
  }

  private onHold(): void {
    const g = this.gesture;
    if (!g || this.signal.aborted) return;
    // Control moved to another device during the hold: a passive client arranges nothing (review M7).
    if (!this.cb.enabled()) { this.clearGesture(); return; }
    g.held = true;
    g.timer = null;
    this.rememberFocus();
    this.openMenu(g.key);
  }

  private onPointerMove(e: PointerEvent): void {
    const g = this.gesture;
    if (!g || e.pointerId !== g.id) return;
    // A mouse moving with NO button down was released where nothing told us (outside the window): the
    // press is over, and a tab must not follow a hovering cursor (review M6).
    if (!g.touch && e.buttons === 0) { this.onPointerEnd(e, true); return; }
    if (this.drag) { this.moveDrag(e.clientX); return; }
    const dist = Math.hypot(e.clientX - g.x0, e.clientY - g.y0);
    if (!g.touch) {
      if (dist > MOUSE_SLOP_PX) this.startDrag(g);
    } else if (!g.held) {
      // Moved before the hold: the finger is SCROLLING the bar. Nothing here is a press any more.
      if (dist > TOUCH_SLOP_PX) this.clearGesture();
    } else if (dist > TOUCH_SLOP_PX) {
      // Held, then moved: the tab is being carried. The menu it opened goes.
      this.closeMenu();
      this.startDrag(g);
    }
  }

  private onPointerEnd(e: PointerEvent, cancelled: boolean): void {
    const g = this.gesture;
    if (!g || e.pointerId !== g.id) return;
    if (this.drag) {
      this.dropGesture();                      // FIRST: the drag's own `settled` must find the bar free
      this.endDrag(!cancelled);
      this.swallowClicks();
    } else {
      // The hold opened the menu; lifting the finger leaves it open and switches nothing.
      if (g.held) this.swallowClicks();
      this.clearGesture();
    }
  }

  /// The click a drag's or a hold's release makes is not a press: swallow clicks on the bar for a moment
  /// — bounded, so one that never comes (released off the tab) cannot swallow a later, real one.
  private swallowClicks(): void { this.swallowClicksUntil = Date.now() + CLICK_SWALLOW_MS; }

  /// A press that ends without a drag: the bar is free again, and what the strips deferred renders —
  /// on the NEXT task, after the release's click has reached the tab it was on (a rebuild first would
  /// take that tab out from under the click).
  private clearGesture(): void {
    if (!this.gesture) return;
    this.dropGesture();
    setTimeout(() => { if (!this.signal.aborted && !this.busy) this.cb.settled(); }, 0);
  }

  private dropGesture(): void {
    if (this.gesture?.timer != null) window.clearTimeout(this.gesture.timer);
    this.gesture = null;
  }

  private startDrag(g: Gesture): void {
    if (this.edit) this.endRename(true);
    const sr = this.scroller.getBoundingClientRect();
    const scroll0 = this.scroller.scrollLeft;
    const slots: Slot[] = this.arrangeable()
      .map((el) => ({ el, r: el.getBoundingClientRect() }))
      .filter(({ r }) => r.width > 0)
      .sort((a, b) => a.r.left - b.r.left)
      .map(({ el, r }) => ({ el, key: el.dataset.tabKey!, left: r.left - sr.left + scroll0, width: r.width }));
    const from = slots.findIndex((s) => s.key === g.key);
    if (from < 0) return;
    const tab = slots[from]!.el;
    const gap = parseFloat(getComputedStyle(this.scroller).columnGap) || 0;
    this.drag = {
      key: g.key, slots, from, step: slots[from]!.width + gap,
      x0: g.x0, scroll0, lastX: g.x0, slot: from, speed: 0, raf: 0,
    };
    this.scroller.classList.add("tab-dragging");
    tab.classList.add("dragging");
    for (const s of slots) if (s.el !== tab) s.el.classList.add("tab-shifting");
    try { tab.setPointerCapture(g.id); } catch { /* the pointer is already gone; pointerup ends it */ }
  }

  private moveDrag(x: number): void {
    const d = this.drag!;
    d.lastX = x;
    const me = d.slots[d.from]!;
    const first = d.slots[0]!, last = d.slots[d.slots.length - 1]!;
    // CONTENT coordinates: the pointer's travel plus however far the bar has scrolled under it since.
    const raw = x - d.x0 + (this.scroller.scrollLeft - d.scroll0);
    const dx = Math.max(first.left - me.left, Math.min(raw, last.left + last.width - (me.left + me.width)));
    me.el.style.transform = `translateX(${dx}px)`;
    const others = d.slots.filter((_, i) => i !== d.from);
    const slot = dragSlot(others, me, dx);
    if (slot !== d.slot) {
      d.slot = slot;
      others.forEach((s, j) => {
        const steps = shiftSteps(j, d.from, slot);
        s.el.style.transform = steps === 0 ? "" : `translateX(${steps * d.step}px)`;
      });
    }
    // Near an edge of a bar that scrolls, carry the bar along.
    const sr = this.scroller.getBoundingClientRect();
    const into = x < sr.left + EDGE_PX ? -(sr.left + EDGE_PX - x) : x > sr.right - EDGE_PX ? x - (sr.right - EDGE_PX) : 0;
    d.speed = Math.sign(into) * Math.min(EDGE_MAX_SPEED_PX, Math.ceil(Math.abs(into) / EDGE_PX * EDGE_MAX_SPEED_PX));
    if (d.speed !== 0 && d.raf === 0) d.raf = requestAnimationFrame(() => this.edgeScroll());
  }

  private edgeScroll(): void {
    const d = this.drag;
    if (!d) return;
    d.raf = 0;
    if (d.speed === 0) return;
    const before = this.scroller.scrollLeft;
    this.scroller.scrollLeft = before + d.speed;
    if (this.scroller.scrollLeft !== before) this.moveDrag(d.lastX);
    else d.speed = 0;
  }

  /// End the drag — `drop`: ask for the move it shows; otherwise put everything back. `settle` false only
  /// on teardown, when there is nothing left to render.
  private endDrag(drop: boolean, settle = true): void {
    const d = this.drag;
    if (!d) return;
    this.drag = null;
    if (d.raf) cancelAnimationFrame(d.raf);
    // No transition on the way out: the strips' new `order` lands in this same frame, and tabs animating
    // back from their shifted places would play the move twice.
    for (const s of d.slots) {
      s.el.classList.remove("tab-shifting", "dragging");
      s.el.style.transform = "";
    }
    this.scroller.classList.remove("tab-dragging");
    const others = d.slots.filter((_, i) => i !== d.from);
    if (drop && d.slot !== d.from) this.cb.move(d.key, others[d.slot]?.key ?? null);
    if (settle) this.cb.settled();
  }

  // MARK: rename

  /// **RENAME IS AN OVERLAY ALERT** (2026-10-04, asked for: "move changing tab name into an overlay alert"; it was
  /// a field in place of the label): a modal `<dialog>` in the top layer — the tab's name, all selected, with
  /// Cancel and Rename. Enter or Rename commits (`renameIntent`: the tidied name, `""` clearing a given one, nothing
  /// for an unchanged one); Escape or Cancel sends nothing. The field's placeholder is the name an EMPTY one leaves
  /// (the automatic label); a tmux tab's alert says it renames the SESSION. Its keys are its own. Focus goes back
  /// to what held it before (the terminal, a window's hidden input).
  beginRename(key: string): void {
    if (this.edit) this.endRename(false);
    const field = this.cb.renameField(key);
    if (!field) return;
    const ui = this.renameUi();
    ui.title.textContent = field.clearable ? "Rename Tab" : "Rename Tmux Session";
    ui.input.value = field.value;
    ui.input.placeholder = field.placeholder;
    this.edit = { key, field };
    if (!ui.dialog.open) openClientDialog(ui.dialog);
    ui.input.focus({ preventScroll: true });
    ui.input.select();
  }

  /// Drop the alert without asking for anything — its tab went away underneath it, or the driver went passive.
  cancelRename(): void { this.endRename(false); }

  private endRename(commit: boolean): void {
    const ed = this.edit;
    if (!ed) return;
    this.edit = null;                         // FIRST: closing the dialog fires its `close`
    const ui = this.rename!;
    const ownedFocus = !contextFor(this.scroller) || contextFor(this.scroller)!.input.focused();
    const typed = ui.input.value;
    if (ui.dialog.open) closeClientDialog(ui.dialog);
    if (commit) {
      const name = renameIntent(ed.field, typed);
      if (name !== null) this.cb.rename(ed.key, name);
    }
    const back = this.focusBefore;
    this.focusBefore = null;
    this.cb.settled();
    const a = activeWithin(this.scroller);
    if (ownedFocus && back?.isConnected && (a === null || a === document.body || a === ui.input || this.scroller.contains(a))) {
      back.focus({ preventScroll: true });
    }
  }

  private renameUi(): RenameUi {
    if (this.rename) return this.rename;
    const dialog = document.createElement("dialog");
    dialog.className = "ss-dialog tab-rename-dialog";
    const title = document.createElement("h2");
    title.id = "tab-rename-title";
    dialog.setAttribute("aria-labelledby", title.id);
    const input = document.createElement("input");
    input.type = "text";
    input.className = "tab-rename-input";
    input.spellcheck = false;
    input.autocomplete = "off";
    input.setAttribute("autocapitalize", "off");
    input.enterKeyHint = "done";
    input.setAttribute("aria-label", "Tab name");
    input.dataset.navId = "tab-rename:input";
    const actions = document.createElement("div");
    actions.className = "ss-dialog-actions";
    const button = (label: string, nav: string, commit: boolean) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = label;
      b.dataset.navId = `tab-rename:${nav}`;
      b.addEventListener("click", () => this.endRename(commit));
      return b;
    };
    actions.append(button("Cancel", "cancel", false), button("Rename", "confirm", true));
    dialog.append(title, input, actions);
    input.addEventListener("keydown", (e) => {
      // ITS KEYS ARE ITS OWN: no session shortcut, no terminal, no window may act on them.
      e.stopPropagation();
      if (e.key === "Escape") { e.preventDefault(); this.endRename(false); }
      if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); this.endRename(true); }
    });
    // Escape (the dialog's own cancel) and any other close: nothing is sent.
    dialog.addEventListener("cancel", (e) => { e.preventDefault(); this.endRename(false); });
    dialog.addEventListener("close", () => this.endRename(false));
    (contextFor(this.scroller)?.ui ?? document.body).append(dialog);
    this.signal.addEventListener("abort", () => { closeClientDialog(dialog); dialog.remove(); });
    this.rename = { dialog, title, input };
    return this.rename;
  }

  // MARK: helpers

  private tabFrom(target: EventTarget | null): HTMLElement | null {
    const tab = target instanceof Element ? target.closest<HTMLElement>(".rl-tab[data-tab-key]") : null;
    return tab && this.scroller.contains(tab) ? tab : null;
  }

  private tabEl(key: string): HTMLElement | null {
    return this.arrangeable().find((el) => el.dataset.tabKey === key) ?? null;
  }

  private arrangeable(): HTMLElement[] {
    return [...this.scroller.querySelectorAll<HTMLElement>(".rl-tab[data-tab-key]")];
  }
}
