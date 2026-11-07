import type { ViewSetMsg, Source, SessionWindowMsg } from "./source-picker";
import type { RenameField } from "./tab-name";
import { placeInOrder } from "./terminal-tabs";
import type { LayoutMode } from "./layout-mode";

export type Tab = "terminal" | "sim";

export interface WindowTabView { id: string; label: string; active: boolean; minimized: boolean }

/// One tab per window of the HOST'S SESSION (`view-set.windows`), in the session's order, for BOTH
/// layouts. A minimized window keeps its tab — it is still the session's, the host just captures
/// nothing for it — dimmed and never active.
///
/// There is no "Terminal" entry here any more: TerminalTabs owns the terminal side of the bar on both
/// layouts, which is what lets a mobile user switch shells instead of just toggling one Terminal tab.
export function windowTabViews(
  vs: Pick<ViewSetMsg, "windows" | "focused">, sources: Source[], tab: Tab, layout: LayoutMode = "tabbed",
): WindowTabView[] {
  return vs.windows.map((w) => ({
    id: w.source, label: windowLabel(w, sources),
    active: layout !== "floating" && tab === "sim" && !w.minimized && w.source === vs.focused,
    minimized: w.minimized,
  }));
}

/// THE HOST LANDED THE PERSON ON A TERMINAL TAB (`SessionState.landing`, 2026-10-02): the window they were
/// at — the focused one, on the windows surface — left the streamed set (closed, parked, its app quit), and
/// the SAME view-set shows the terminal surface. Nothing else changes both at once: a terminal tab tapped
/// leaves the window streaming, a landing on a WINDOW leaves the surface alone. It is what tells the page to
/// hand that window's keys to the terminal (`WindowManager.sync`'s `keysTo`) rather than to the next window.
export function landedOnTerminal(
  prev: Pick<ViewSetMsg, "windows" | "focused" | "view">, next: Pick<ViewSetMsg, "windows" | "view">,
): boolean {
  if (prev.view.surface !== "windows" || next.view.surface !== "terminal" || prev.focused === null) return false;
  return !next.windows.some((w) => w.source === prev.focused && !w.minimized);
}

/// WHETHER THE PERSON WAS AT `source` as they close or park it — what that intent says as `land`, so the
/// host lands them on the bar's previous tab (`SessionState.landing`). ONLY THE PAGE CAN TELL (review,
/// 2026-10-02): on a PINNED layout it is the window on screen — the windows surface showing, the window
/// focused; on the FLOATING layout every window and the terminal are on screen at once and the surface means
/// nothing (it stays "windows" after a palette pick while the person types in the terminal), so it is the
/// window holding the KEYS (DOM focus in its picture or hidden input). The host's surface gate switched the
/// shell being typed into.
export function personAtWindow(o: { pinned: boolean; windowsSurface: boolean; focused: boolean; holdsKeys: boolean }): boolean {
  return o.pinned ? o.windowsSurface && o.focused : o.holdsKeys;
}

/// The source's own name — what the Mac calls the window — or its id while the source list has not
/// named it yet.
export function sourceName(source: string, sources: Source[]): string {
  return sources.find((x) => x.id === source)?.name ?? source;
}

/// A window's label, on its tab and its titlebar alike: the name the driver gave it, else the source's.
export function windowLabel(w: SessionWindowMsg, sources: Source[]): string {
  return w.name !== undefined && w.name.trim() !== "" ? w.name : sourceName(w.source, sources);
}

/// What Rename's field opens with for a window; empty gives it back its source's name.
export function winRenameField(w: SessionWindowMsg, sources: Source[]): RenameField {
  const named = w.name !== undefined && w.name.trim() !== "";
  return { value: windowLabel(w, sources), placeholder: sourceName(w.source, sources), named, clearable: true };
}

/// The window half of the tab bar. Clicking a tab switches to the source surface (`data-tab="sim"`, which
/// only matters under the tabbed layout) and calls back; the caller sends `focus-source` — or, for a
/// minimized tab, `restore-window`.
export class WindowTabs {
  private views: WindowTabView[] = [];
  /// One element per window, for its tab's life (`render`).
  private readonly tabs = new Map<string, WinTabEl>();

  constructor(
    private readonly els: { root: HTMLElement; strip: HTMLElement },
    private readonly cb: {
      onFocusSource(id: string, minimized: boolean): void;
      /// See `TerminalTabs`: true while a tab is renamed or dragged — keep the views, draw on `refresh`.
      hold?(): boolean;
      /// The label to show for `key` over the session's `label` — a rename on its way to the host.
      label?(key: string, label: string): string;
      /// The strip was redrawn: its tabs need their place in the bar.
      rendered?(): void;
      /// Whether `key` rang its bell unseen — its application raised its Dock badge (term-bell.ts): the tab
      /// carries `data-bell`, as a terminal tab does.
      bell?(key: string): boolean;
    },
  ) {}

  update(views: WindowTabView[]): void {
    this.views = views;
    this.render();
  }

  /// Render the views it has again: after a hold, or when a label the caller overrides changed.
  refresh(): void { this.render(); }

  /// Put every tab's bell mark where `bell` says, AND WHILE HELD: a mark is an attribute, never a rebuild
  /// (`TerminalTabs.markBells`).
  markBells(): void { for (const [key, t] of this.tabs) this.markBell(key, t); }

  private markBell(key: string, t: WinTabEl): void {
    t.btn.toggleAttribute("data-bell", this.cb.bell?.(key) ?? false);
  }

  /// REDRAWN IN PLACE, like `TerminalTabs` and for its reason: iOS WebKit drops a tap whose element is
  /// replaced between the touch and its click. One element per window for the tab's life; only the
  /// classes this strip owns (`on`, `minimized`, `data-bell`) are touched.
  private render(): void {
    if (this.cb.hold?.()) return;
    const wanted: HTMLElement[] = [];
    const keep = new Set<string>();
    for (const v of this.views) {
      keep.add(v.id);
      let t = this.tabs.get(v.id);
      if (!t) { t = this.build(v); this.tabs.set(v.id, t); }
      t.view = v;
      t.btn.classList.toggle("on", v.active);
      t.btn.classList.toggle("minimized", v.minimized);
      t.btn.setAttribute("aria-selected", String(v.active));
      const text = this.cb.label ? this.cb.label(v.id, v.label) : v.label;
      if (t.label.textContent !== text) t.label.textContent = text;
      this.markBell(v.id, t);
      wanted.push(t.btn);
    }
    for (const [key, t] of this.tabs) if (!keep.has(key)) { t.btn.remove(); this.tabs.delete(key); }
    placeInOrder(this.els.strip, wanted);
    this.cb.rendered?.();
  }

  /// One window tab's element, built once; its click reads the tab's CURRENT state.
  private build(first: WindowTabView): WinTabEl {
    const btn = document.createElement("button");
    btn.type = "button";
    // See terminal-tabs.ts: this is how the glasses D-pad addresses the tab.
    btn.dataset.navId = `tab:win:${first.id}`;
    btn.dataset.tabKey = first.id;   // arrangeable: TabBar's menu, drag and place in the bar
    btn.className = "rl-tab";
    btn.setAttribute("role", "tab");
    const label = document.createElement("span");
    label.className = "rl-tab-label";
    btn.append(label);
    const t: WinTabEl = { btn, label, view: first };
    btn.addEventListener("click", () => {
      this.els.root.dataset.tab = "sim";
      this.cb.onFocusSource(t.view.id, t.view.minimized);
    });
    return t;
  }
}

interface WinTabEl { btn: HTMLElement; label: HTMLElement; view: WindowTabView }
