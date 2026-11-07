import { presentationRoot, activeWithin } from "./instance/context";
import type { RenameField } from "./tab-name";

/// Pure parsing + view-model + a thin tab strip for the driver's terminal. Mirrors the host's
/// term-list message. Only the active driver ever sees this (non-drivers see the #claim overlay).

/// `id` is the host's tab id: `pty:<n>` for a shell, `tmux:$<n>` for a tmux session. The prefix is the kind.
/// `name` is the one the driver gave a SHELL tab (`rename-tab`), absent when it has none; a tmux tab never
/// has one — its `title` is its session's name, and renaming it renames the session. `agent` is the host's read of
/// the tab's screen (AgentActivity.swift): an agent in its foreground `working`, or `idle`; absent, none running.
export interface TermTab { id: string; n: number; title: string; name?: string; agent?: AgentState; agentKind?: string }
export type AgentState = "working" | "idle";
export interface TermListMsg { tabs: TermTab[]; activeId: string | null }

function isTermTab(v: unknown): v is TermTab {
  if (typeof v !== "object" || v === null) return false;
  const t = v as Record<string, unknown>;
  return typeof t.id === "string" && typeof t.n === "number" && typeof t.title === "string"
    && (t.name === undefined || typeof t.name === "string")
    && (t.agentKind === undefined || typeof t.agentKind === "string")
    && (t.agent === undefined || t.agent === "working" || t.agent === "idle");
}

/// Narrow a decoded control-channel JSON message to a TermListMsg, or null if it isn't one.
export function parseTermList(msg: unknown): TermListMsg | null {
  if (typeof msg !== "object" || msg === null) return null;
  const m = msg as { t?: unknown; tabs?: unknown; activeId?: unknown };
  if (m.t !== "term-list" || !Array.isArray(m.tabs) || !m.tabs.every(isTermTab)) return null;
  // The retired numeric form is refused, not coerced: a host still sending numbers is a version skew.
  if (m.activeId !== null && m.activeId !== undefined && typeof m.activeId !== "string") return null;
  return { tabs: m.tabs as TermTab[], activeId: (m.activeId as string | null | undefined) ?? null };
}

/// How many terminal tabs a host holds, both kinds counted — the number its `too-many-tabs` refusal is about. The HOST
/// decides (`TabPool.defaultMaxTabs`); this only says it. 100 since 2026-10-09 (it was 8).
export const TERMINAL_TAB_LIMIT = 100;

/// The host refused an `open-terminal` (`reason`: `too-many-tabs` at the cap) — the tab is not coming.
export function parseTermError(msg: unknown): { reason: string } | null {
  const m = msg as { t?: unknown; reason?: unknown } | null;
  if (!m || m.t !== "term-error" || typeof m.reason !== "string") return null;
  return { reason: m.reason };
}

/// What a tab is called when nobody named it: its OSC title (a tmux tab: its session's name), or
/// "Terminal N".
export function autoTabLabel(t: TermTab): string {
  return t.title.trim() !== "" ? t.title : `Terminal ${t.n}`;
}

/// The button label for a tab: the name the driver gave it, else its automatic label.
export function tabLabel(t: TermTab): string {
  return t.name !== undefined && t.name.trim() !== "" ? t.name : autoTabLabel(t);
}

/// What Rename's field opens with for `t`. A tmux tab's label IS its session's name: the field renames
/// the session, and empty means nothing (tmux has no unnamed session).
export function termRenameField(t: TermTab): RenameField {
  const tmux = t.id.startsWith("tmux:");
  const named = !tmux && t.name !== undefined && t.name.trim() !== "";
  return { value: tabLabel(t), placeholder: autoTabLabel(t), named, clearable: !tmux };
}

/// `tmux` marks a tab whose shell tmux owns (it survives a disconnect and a host restart) — read off
/// the id's prefix, never a separate field.
export interface TermTabView { id: string; label: string; selected: boolean; tmux: boolean; working: boolean }

/// The terminal half of the tab bar.
///
/// LOAD-BEARING: this strip used to live inside `#term-surface`, where `.claim-overlay` covered it for
/// free when the client was passive. It now sits in the global tab bar, OUTSIDE that overlay, so the
/// active-gate has to be explicit — otherwise a passive client gets clickable buttons the host rejects.
///
/// A PASSIVE CLIENT SHOWS NO TERMINAL TAB (2026-10-04, asked for). It used to get one static "Terminal" tab —
/// a fake, standing for no shell — kept as the route back to the terminal surface where "Move here" lived; but
/// `#claim` covers the whole stage on EITHER surface, with its own Move here (a passive header hides `+` and
/// disables Search since 2026-10-05), so nothing needs it.
///
/// EVERY tab is closable, the last one too (2026-09-25): an empty terminal is a normal state with its own
/// surface (`#term-empty`), and nothing opens a shell implicitly.
export function terminalTabViews(msg: TermListMsg, active: boolean): TermTabView[] {
  if (!active) return [];
  return msg.tabs.map((t) => ({ id: t.id, label: tabLabel(t), selected: t.id === msg.activeId, tmux: t.id.startsWith("tmux:"),
                                working: t.agent === "working" }));
}

/// The tabs the host saw an agent in, working or idle — whose views end at their content (trailing-blanks.ts).
export function agentTabs(list: TermListMsg): Set<string> {
  return new Set(list.tabs.filter((t) => t.agent !== undefined).map((t) => t.id));
}

/// **AN AGENT FINISHED** (2026-10-05; docs/terminal.md, "An agent's activity"): the tabs whose agent the host saw
/// WORKING in `before` and no longer in `after` — its turn ended (or the tab's agent went). A tab new in `after`
/// finished nothing; one gone from it is the tab list's business.
export function agentsFinished(before: TermListMsg, after: TermListMsg): string[] {
  const was = new Map(before.tabs.map((t) => [t.id, t.agent]));
  return after.tabs.filter((t) => was.get(t.id) === "working" && t.agent !== "working").map((t) => t.id);
}

/// DOM strip: one button per tab. Sends switch/close/open via callbacks; kept thin — `terminalTabViews`
/// above is what's unit-tested. The host caps tabs at 8, which bounds the + button.
export class TerminalTabs {
  private msg: TermListMsg = { tabs: [], activeId: null };
  private active = false;
  /// One element per tab key, for the tab's life (`render`).
  private readonly tabs = new Map<string, TabEl>();

  constructor(
    private readonly root: HTMLElement,
    private readonly cb: {
      onSwitch(id: string): void;
      onClose(id: string): void;
      /// Any terminal tab was clicked — the terminal surface is now showing. Fired even when the tab was
      /// already selected, because under the tabbed layout the
      /// caller has to re-fit xterm: it is display:none on the Sim tab, so FitAddon cannot measure it
      /// until this moment.
      onShowTerminal(): void;
      /// Explicit activation, including a click on the already selected tab.
      onActivate?(id: string): void;
      /// Whether the terminal surface should carry the selected-tab highlight.
      surfaceShown?(): boolean;
      /// True while a tab is being renamed or dragged (`TabBar.busy`): the strip must not rebuild the
      /// tabs under the field or the finger. It keeps the latest list; `refresh` draws it after.
      hold?(): boolean;
      /// The label to show for `key` over the host's `label` — a rename on its way to the host.
      label?(key: string, label: string): string;
      /// The strip was redrawn: its tabs need their place in the bar (`style.order`).
      rendered?(): void;
      /// Whether `key` rang its bell unseen (term-bell.ts): the tab carries `data-bell`.
      bell?(key: string): boolean;
    },
  ) {
    this.render();
  }

  /// Render from a fresh term-list.
  update(msg: TermListMsg): void { this.msg = msg; this.render(); }

  /// Called from SessionControl's active/passive transitions — see `terminalTabViews`.
  setActive(active: boolean): void { this.active = active; this.render(); }

  /// Render the list it has again: after a hold, or when a label the caller overrides changed.
  refresh(): void { this.render(); }

  /// A tab shown before the host named it (`opening-tab.ts`) IS the host's tab `to` now: its element is KEPT and
  /// re-keyed — an element replaced under a tap is a tap iOS drops (`render`) — so the next render finds it.
  rekey(from: string, to: string): void {
    const t = this.tabs.get(from);
    if (!t || this.tabs.has(to)) return;
    this.tabs.delete(from);
    this.tabs.set(to, t);
    t.btn.dataset.tabKey = to;
    t.btn.dataset.navId = `tab:term:${to}`;
  }

  refreshSelection(): void {
    for (const t of this.tabs.values()) {
      const selected = t.view.selected && (this.cb.surfaceShown?.() ?? true);
      t.btn.classList.toggle("on", selected);
      t.btn.setAttribute("aria-selected", String(selected));
    }
  }

  /// Put every tab's bell mark where `bell` says, AND WHILE HELD: a mark is an attribute, never a rebuild,
  /// so a bell during a rename or a drag shows at once rather than at the drop.
  markBells(): void { for (const [key, t] of this.tabs) this.markBell(key, t); }

  private markBell(key: string, t: TabEl): void {
    t.btn.toggleAttribute("data-bell", this.cb.bell?.(key) ?? false);
  }

  /// REDRAWN IN PLACE (2026-10-01): one element per tab KEY for as long as the tab exists, its label and
  /// state updated where they changed. iOS WebKit DROPS A TAP whose element is replaced between the touch
  /// and its click — measured in the iOS 26.5 simulator, 1 tap in 20 registered while the strip was rebuilt
  /// after each press, 20 in 20 without — and a `term-list` arrives on every title change. Only a class
  /// this strip owns (`on`, `data-bell`) is touched; the bar's (`menu-open`, `dragging`, …) are left alone.
  private render(): void {
    if (this.cb.hold?.()) return;
    const views = terminalTabViews(this.msg, this.active);
    const wanted: HTMLElement[] = [];
    const keep = new Set<string>();
    for (const v of views) {
      const key = v.id;
      keep.add(key);
      let t = this.tabs.get(key);
      if (!t) { t = this.build(v); this.tabs.set(key, t); }
      t.view = v;
      const selected = v.selected && (this.cb.surfaceShown?.() ?? true);
      t.btn.classList.toggle("on", selected);
      t.btn.setAttribute("aria-selected", String(selected));
      const text = this.cb.label ? this.cb.label(v.id, v.label) : v.label;
      if (t.label.textContent !== text) t.label.textContent = text;
      // AN AGENT AT WORK in it (the host's read of its screen): a silver shimmer through the label, an attribute — never a
      // rebuild — and `aria-busy` for a screen reader.
      t.btn.toggleAttribute("data-agent-working", v.working);
      if (v.working) t.btn.setAttribute("aria-busy", "true"); else t.btn.removeAttribute("aria-busy");
      this.markBell(key, t);
      wanted.push(t.btn);
    }
    for (const [key, t] of this.tabs) if (!keep.has(key)) { t.btn.remove(); this.tabs.delete(key); }
    placeInOrder(this.root, wanted);
    this.cb.rendered?.();
    // NOTE the `+` button is NOT ours any more: it opens the command palette (new terminal + the
    // window-preview grid) rather than creating a terminal directly, so main.ts owns it; a passive client's
    // header hides it (session.ts, `control-state`) — `#claim`'s Move here is its way back.
  }

  /// One tab's element, built once. Its handlers read `t.view` — the tab's CURRENT state — never the
  /// view it was built with.
  private build(first: TermTabView): TabEl {
    const id = first.id;
    const tab = document.createElement("button");
    tab.type = "button";
    // The glasses D-pad addresses controls by this id (see spatial-nav.ts navOrder). Harmless
    // everywhere else; without it the tab is unreachable on glasses.
    // `data-tab-key` makes it ARRANGEABLE (TabBar: its menu, its drag, its place in the bar).
    tab.dataset.navId = `tab:term:${id}`;
    tab.dataset.tabKey = id;
    tab.className = "rl-tab";
    tab.setAttribute("role", "tab");
    const label = document.createElement("span");
    label.className = "rl-tab-label";
    tab.append(label);
    const t: TabEl = { btn: tab, label, view: first };
    // A WORD, not a glyph (the font subsets carry no dingbats): this tab's shell survives restarts.
    if (first.tmux) {
      const kind = document.createElement("span");
      kind.className = "rl-tab-kind";
      kind.textContent = "tmux";
      tab.append(kind);
    }
    // Every terminal tab switches the surface back to the terminal (matters under the tabbed layout);
    // an unselected one also asks the host to switch shells.
    tab.addEventListener("click", () => {
      presentationRoot(tab).dataset.tab = "terminal";
      this.cb.onShowTerminal();
      this.cb.onActivate?.(t.view.id);
      // The tab's id NOW — a tab shown before the host named it is re-keyed (`rekey`).
      if (!t.view.selected) this.cb.onSwitch(t.view.id);
    });
    // While the TERMINAL holds focus, a tab tap must not take it: `mousedown`'s default action is the
    // focus transfer, and on a phone that blur closed the soft keyboard before the switch could hand
    // focus on (term-view-policy.ts) — typing across a switch always dropped the keyboard. Only then:
    // a window's hidden input kept focused behind the terminal surface would type into the Mac
    // window while the terminal is on screen. `mousedown`, never `pointerdown`, as on the key strip.
    tab.addEventListener("mousedown", (e) => {
      if ((activeWithin(tab) as HTMLElement | null)?.closest(".xterm")) e.preventDefault();
    });
    const x = document.createElement("span");
    x.className = "rl-tab-close";
    x.textContent = "×";
    x.setAttribute("role", "button");
    x.setAttribute("aria-label", "Close tab");
    x.addEventListener("click", (e) => { e.stopPropagation(); this.cb.onClose(t.view.id); });
    tab.append(x);
    return t;
  }
}

interface TabEl { btn: HTMLElement; label: HTMLElement; view: TermTabView }

/// Make `root`'s children exactly `wanted`, in that order, MOVING NOTHING THAT IS ALREADY IN PLACE — a
/// moved element is removed and re-inserted, which is the replacement an iOS tap does not survive.
export function placeInOrder(root: HTMLElement, wanted: readonly HTMLElement[]): void {
  wanted.forEach((el, i) => {
    const at = root.children[i];
    if (at !== el) root.insertBefore(el, at ?? null);
  });
  while (root.children.length > wanted.length) root.lastElementChild!.remove();
}
