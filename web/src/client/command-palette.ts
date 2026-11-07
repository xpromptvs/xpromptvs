import {productFeatures} from "../shared/product-features";
import type { Source, HostDisplay, AppsState } from "./source-picker";
import { galleryTiles, type GalleryTile, type ThumbEntry } from "./source-gallery";
import type { TmuxListMsg } from "./tmux";

/// A banner above the palette's contents. Data only, like everything else here.
export interface PaletteNotice { title: string; detail: string }

const NOTICES: Record<"asleep" | "none" | "locked", PaletteNotice> = {
  asleep: {
    title: "The host Mac's display is asleep",
    detail: "macOS cannot capture a sleeping display, so there is nothing to show. "
          + "It will wake on its own if the host is sharing; otherwise wake it at the Mac.",
  },
  none: {
    title: "No display attached",
    detail: "macOS needs an active display to capture. Attach one, or use a display emulator "
          + "(a dummy HDMI plug).",
  },
  locked: {
    title: "The host Mac's session is locked",
    detail: "You can see it, but Xpromptvs cannot type the password — macOS does not deliver synthetic "
          + "input to the lock screen. Someone has to unlock it at the Mac.",
  },
};

/// An action row. Data only — the id is the dispatch key, resolved in main.ts, which is what makes the
/// whole model assertable in a unit test.
export interface PaletteAction { id: string; glyph: string; label: string; hint: string }

export interface PaletteCtx {
  active: boolean;
  sources: Source[];
  subscribed: ReadonlySet<string>;
  focused: string | null;
  thumbs: Map<string, ThumbEntry>;
  /// What the host can capture. null means the host has not said — never assume "ok".
  display: HostDisplay | null;
  /// The host's tmux sessions; null until the host has answered `list-tmux`.
  tmux: TmuxListMsg | null;
  /// Sessions open as tabs in the host's session (`term-list`'s `tmux:` tabs).
  openTmux: ReadonlySet<string>;
  /// The session of the active terminal tab, when that tab is a tmux one.
  activeTmux: string | null;
  /// A WINDOW-LESS session (the app's own Mac): no picture exists, so no tile, no display notice.
  windowless?: boolean;
  nativeSimulators?: boolean;
  agents?: boolean;
  agentProviders?:readonly string[];
  agentSessions?: { id: string; name?: string; preview?: string; cwd?: string; status?: {type?: string}; provider?: string }[];
  agentSearchNotice?: string;
  apps?: AppsState | null;
}

/// What the palette shows: a short action list, then a grid of window previews.
export interface PaletteModel {
  actions: PaletteAction[]; tiles: GalleryTile[]; notice?: PaletteNotice;
  /// One muted line where the tmux rows would be — tmux is not installed on the host.
  tmuxNote?: string;
}

/// Build the palette's contents for `ctx`, filtered by `query`. Pure, so the whole surface is testable.
///
/// A PASSIVE client gets only what it can actually do — claim control. It gets no grid at all: every tile
/// maps to a host-gated subscribe/focus the host would reject, and offering those would be a UI that lies
/// about what a click does. (The theme toggle lives on the footer, reachable either way.)
///
/// The grid is filtered on the source NAME, which the host formats as "App — Window title", so one query
/// matches by app or by window.
export function paletteModel(ctx: PaletteCtx, query: string, step: "main" | "launch-simulator" = "main"): PaletteModel {
  const q = query.trim().toLowerCase();
  const match = (s: string) => !q || s.toLowerCase().includes(q);

  if (!ctx.active) {
    const claim: PaletteAction = {
      id: "action:claim", glyph: "⇥", label: "Move here", hint: "continue this workspace on this device",
    };
    return { actions: match(`${claim.label} ${claim.hint}`) ? [claim] : [], tiles: [] };
  }

  const simulators = ctx.windowless ? [] : ctx.sources.filter(s => s.id.startsWith("sim:"));
  const stopped = simulators.filter(s => s.simState === "shutdown" || (!s.simState && !s.running));
  if (step === "launch-simulator" && !ctx.windowless) {
    return {
      actions: [
        ...stopped.filter(s => match(s.name)).map(s => ({
          id: `launch:${s.id}`, glyph: "+", label: s.name, hint: "boot and open simulator",
        })),
        { id: "action:back", glyph: "", label: "Back", hint: "return to all commands" },
      ],
      tiles: galleryTiles(simulators.filter(s => s.running), [...ctx.subscribed], ctx.focused, ctx.thumbs)
        .filter(t => match(t.name)),
    };
  }

  const newTerminal: PaletteAction = {
    id: "action:new-terminal", glyph: "+", label: "New terminal", hint: "open a blank shell",
  };
  const actions: PaletteAction[] = match(`${newTerminal.label} ${newTerminal.hint}`) ? [newTerminal] : [];
  if(productFeatures.graphicalAgents&&ctx.agents&&ctx.agentProviders?.includes("claude")&&match("New Claude session agent"))actions.push({id:"action:new-claude",glyph:"+",label:"New Claude session",hint:"start a persistent agent on the host"});
  if (productFeatures.graphicalAgents && ctx.agents) for (const s of ctx.agentSessions ?? []) {
    const label = s.name || s.preview || "Untitled session";
    const provider=s.provider==="claude"||s.id.startsWith("claude:")?"Claude":"Codex";
    if (match(`${label} ${s.cwd ?? ""} ${provider}`)) actions.push({id:`agent:${s.id}`,glyph:"·",label,
      hint:[provider,s.cwd, s.status?.type === "active" ? "running" : s.status?.type === "idle" ? "live" : "saved"].filter(Boolean).join(" · ")});
  }
  const tmuxNote = tmuxActions(ctx, match, actions);
  // Smooth scrolling is a SETTING, not a command: Terminal Settings and the dashboards' Settings hold it — it
  // left the palette on 2026-10-04.
  // A WINDOW-LESS SESSION HAS NO PICTURE TO OFFER: the terminal's actions, and nothing that would
  // subscribe to a window the host refuses it (WindowlessPolicy).
  if (ctx.windowless) return { actions, ...(tmuxNote ? { tmuxNote } : {}), tiles: [] };
  const appsNotice: PaletteNotice | undefined = ctx.apps && (ctx.apps.error || ctx.apps.recoveryCount > 0)
    ? { title: ctx.apps.recoveryCount > 0 ? "Apps needs recovery" : "Apps unavailable",
        detail: [ctx.apps.error, ctx.apps.recoveryCount > 0
          ? `${ctx.apps.recoveryCount} unresolved recovery records. Restore windows manually on the host Mac before archiving the placement journal.` : ""]
          .filter(Boolean).join(" ") }
    : undefined;
  if (ctx.apps) {
    const members = new Set(ctx.apps.members.map(m => m.app.id));
    const workspaceActions: PaletteAction[] = ctx.apps.members.map(m => ({
      id: `apps-remove:${m.app.id}`, glyph: "", label: `Restore ${m.app.name}`,
      hint: m.error ?? "return this app’s windows to the Mac",
    }));
    if (members.size) workspaceActions.push({ id: "action:apps-restore-all", glyph: "", label: "Restore all apps", hint: "return shared windows to the Mac" });
    if (ctx.apps.availability === "available") workspaceActions.push(...ctx.apps.applications.filter(a => !members.has(a.id)).map(a => ({
      id: `apps-add:${a.id}`, glyph: "+", label: `Share app: ${a.name}`,
      hint: "Experimental: moves windows. After a host crash, restore them on the Mac.",
    })));
    actions.push(...workspaceActions.filter(a => match(`${a.label} ${a.hint}`)));
  }
  const launch: PaletteAction = {
    id: "action:launch-simulator", glyph: "+", label: "Launch iOS Simulator", hint: "choose a device to start",
  };
  if (simulators.length && match(`${launch.label} ${launch.hint}`)) actions.push(launch);
  const d = ctx.nativeSimulators ? null : ctx.display;

  // NOTHING IS CAPTURABLE: drop the grid. Every tile maps to a subscribe that would produce a blank
  // picture, and offering those is a UI that lies about what a click does — the same reasoning the
  // passive branch above already carries. The ACTIONS stay: the terminal rides its own data channel
  // and is completely unaffected by display power.
  if (d && d.availability !== "ok") {
    return { actions, tiles: [], notice: appsNotice
      ? { title: appsNotice.title, detail: `${appsNotice.detail} ${NOTICES[d.availability].detail}` }
      : NOTICES[d.availability], ...(tmuxNote ? { tmuxNote } : {}) };
  }

  // LOCKED BUT AWAKE KEEPS THE GRID. Windows genuinely do capture through a lock screen (measured:
  // thumbnails came back off a locked Mac), so hiding them would throw away a working session. What
  // is broken there is INPUT, and the notice says exactly that.
  return {
    actions,
    tiles: galleryTiles(ctx.sources.filter(s => s.id.startsWith("sim:") ? s.running : !ctx.nativeSimulators), [...ctx.subscribed], ctx.focused, ctx.thumbs)
      .filter((t) => match(t.name)),
    ...(appsNotice ? { notice: appsNotice } : d?.locked ? { notice: NOTICES.locked } : {}),
    ...(tmuxNote ? { tmuxNote } : {}),
  };
}

/// New tmux terminal leads the actions when available; session rows follow New terminal. Sessions are ROWS, not tiles — there is no picture to show.
/// Returns the note to show instead when the host has no tmux. The terminal rides its own channel, so
/// none of this depends on display power.
function tmuxActions(ctx: PaletteCtx, match: (s: string) => boolean, actions: PaletteAction[]): string | undefined {
  if (!ctx.tmux) return undefined;
  if (!ctx.tmux.available) return "tmux is not installed on the Mac";
  const newTmux: PaletteAction = {
    id: "action:new-tmux", glyph: "+", label: "New tmux terminal", hint: "a shell that survives restarts",
  };
  if (match(`${newTmux.label} ${newTmux.hint}`)) actions.unshift(newTmux);
  for (const s of ctx.tmux.sessions) {
    if (!match(s.name)) continue;
    actions.push({ id: `tmux:${s.id}`, glyph: "$", label: s.name, hint: "" });
  }
  return undefined;
}

/// The surface a pick LANDS ON — on the pinned layouts, which of the terminal and the windows the
/// screen shows afterwards (`data-tab`). A window pick used to leave it alone, so on a phone showing
/// the terminal the source was subscribed and focused behind it and nothing visible happened. `null`:
/// the pick opens nothing (a claim) and the screen stays where it is.
export function paletteItemSurface(id: string): "terminal" | "window" | null {
  if (id.startsWith("source:") || id.startsWith("launch:sim:")) return "window";
  if (id === "action:new-terminal" || id === "action:new-tmux" || id.startsWith("tmux:")) return "terminal";
  return null;
}

/// LOAD-BEARING: ⌘K binds unconditionally, but Ctrl+K binds ONLY outside the terminal. Ctrl+K is
/// readline's kill-line — binding it globally would break real shell editing for anyone not on an Apple
/// keyboard, in an app whose whole point is a remote shell. **⌘T is ⌘K** (2026-10-03: the palette is where
/// a terminal is opened) — ⌘ only, never Ctrl+T (readline's transpose-chars), and never with ⇧, which is
/// `shouldReopenTerminal`'s. A browser keeps ⌘T for itself (a new browser tab); the app hands it over.
export function shouldOpenPalette(e: KeyboardEvent, terminalHasFocus: boolean): boolean {
  const key = e.key?.toLowerCase();
  if (e.altKey) return false;
  if (key === "t") return !!e.metaKey && !e.shiftKey && !e.ctrlKey;
  if (key !== "k") return false;
  if (e.metaKey) return true;
  return !!e.ctrlKey && !terminalHasFocus;
}

/// ⌘⇧T: the terminal tab closed last comes back (`reopen-terminal`; docs/terminal.md, "Tabs that come
/// back"). ⌘ only, as `shouldOpenPalette`'s ⌘T.
export function shouldReopenTerminal(e: KeyboardEvent): boolean {
  return e.key?.toLowerCase() === "t" && !!e.metaKey && !!e.shiftKey && !e.altKey && !e.ctrlKey;
}

/// ⌘W: close the tab, not the window — in the APP (docs/desktop-app.md, "⌘W closes the tab"). ⌘ only: ⇧⌘W is the
/// app's Close Window, and a browser keeps ⌘W for its own tab whatever a page does.
export function shouldCloseTab(e: KeyboardEvent): boolean {
  return e.key?.toLowerCase() === "w" && !!e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey;
}

// Fixed SVG paths keep the palette's symbols consistent with the window controls.
function actionIcon(id: string): string {
  const path = id === "action:back" ? '<path d="m10 5-7 7 7 7M3 12h18"/>'
    : id === "action:launch-simulator" || id.startsWith("launch:sim:") ? '<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 18h4"/>'
    : id === "action:claim" ? '<path d="M4 12h12m-5-5 5 5-5 5M18 4h3v16h-3"/>'
    : id === "action:new-terminal" ? '<path d="m5 7 5 5-5 5m8 0h6"/>'
    : '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m6 9 3 3-3 3m6 0h5"/>';
  return `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${path}</svg>`;
}

/// The palette overlay: the single place sources are picked (it replaced the standalone snapshot gallery).
/// Thin — `paletteModel` decides the contents; this renders them, tracks the keyboard selection across the
/// action rows AND the grid as one list, and reports activations by id.
export class CommandPalette {
  private ctx: PaletteCtx | null = null;
  private model: PaletteModel = { actions: [], tiles: [] };
  private sel = 0;
  private step: "main" | "launch-simulator" = "main";
  private readonly searchPlaceholder: string;

  constructor(
    private readonly els: {
      overlay: HTMLElement; input: HTMLInputElement; actions: HTMLElement; grid: HTMLElement;
      empty: HTMLElement; close: HTMLButtonElement;
      notice: HTMLElement; noticeTitle: HTMLElement; noticeDetail: HTMLElement;
      tmuxNote: HTMLElement;
    },
    private readonly cb: {
      onRun(id: string): void | Promise<void>;
      /// The session WAITS for this pick (a terminal opening on This Mac, session.ts `openTerminal`): the palette
      /// stays up until it lands, then closes in the tick the tab shows.
      waits?(id: string): boolean;
      onQuery?(query: string): void;
    },
  ) {
    this.searchPlaceholder = els.input.placeholder;
    // Click-outside only exists on desktop: the mobile sheet is full-bleed, so there IS no outside — which
    // is why the close button is always available, including on touch devices.
    this.els.overlay.addEventListener("click", (e) => { if (e.target === this.els.overlay) this.close(); });
    this.els.close.addEventListener("click", () => this.close());
    this.els.input.addEventListener("input", () => { this.rebuild(); this.cb.onQuery?.(this.els.input.value); });
    this.els.input.addEventListener("keydown", (e) => this.onKey(e));
  }

  get isOpen(): boolean { return !this.els.overlay.classList.contains("hidden"); }

  open(ctx: PaletteCtx): void {
    this.ctx = ctx;
    this.step = "main";
    this.els.input.value = "";
    this.els.overlay.classList.remove("hidden");
    this.rebuild();
    this.els.input.focus();
    this.cb.onQuery?.("");
  }

  close(): void { this.els.overlay.classList.add("hidden"); }

  /// A pick waited for (`waits`) is in flight: another pick does nothing until it lands.
  private waiting = false;

  /// Run a pick: most close the palette FIRST; one the session waits for keeps it open (busy) and closes it when
  /// it lands — in the same task the tab shows, so the two are one step.
  private run(id: string): void {
    if (this.waiting) return;
    if (id === "action:launch-simulator" || id === "action:back") {
      this.step = id === "action:back" ? "main" : "launch-simulator";
      this.els.input.value = "";
      this.rebuild();
      this.els.input.focus();
      return;
    }
    if (!this.cb.waits?.(id)) { this.close(); void this.cb.onRun(id); return; }
    const landed = this.cb.onRun(id);
    if (!landed) { this.close(); return; }
    this.waiting = true;
    this.els.overlay.setAttribute("aria-busy", "true");
    void landed.then(()=>this.close(),error=>{
      this.els.notice.classList.remove("hidden");this.els.noticeTitle.textContent="Unable to open session";
      this.els.noticeDetail.textContent=String(error?.message??error);
    }).finally(() => {
      this.waiting = false;
      this.els.overlay.removeAttribute("aria-busy");
    });
  }

  /// Re-render an ALREADY-OPEN palette from fresh context, keeping the typed query. Snapshots and the
  /// source list arrive asynchronously after open, so without this the grid would stay as it was at open —
  /// the same race that used to leave the old text list empty.
  refresh(ctx: PaletteCtx): void {
    if (!this.isOpen) return;
    // WebKit resets this scroller when replaceChildren replaces the gallery, even when its
    // dimensions are unchanged. Replies are updates to the view the person is browsing, not a
    // new query: keep its offset and keyboard choice (a shorter result naturally clamps the offset).
    const body = this.els.grid.closest<HTMLElement>(".palette-body");
    const top = body?.scrollTop;
    const selected = this.entryIds()[this.sel];
    this.ctx = ctx;
    this.rebuild(selected);
    if (body && top !== undefined && body.scrollTop !== top) body.scrollTop = top;
  }

  /// Every keyboard-selectable entry, in visual order: action rows first, then grid tiles.
  private orderedActions(): PaletteAction[] {
    return [
      ...this.model.actions.filter(a => !a.id.startsWith("tmux:") && !a.id.startsWith("agent:")),
      ...this.model.actions.filter(a => a.id.startsWith("tmux:")),
      ...this.model.actions.filter(a => a.id.startsWith("agent:")),
    ];
  }

  private entryIds(): string[] {
    return [...this.orderedActions().map((a) => a.id), ...this.model.tiles.map((t) => `source:${t.id}`)];
  }

  private onKey(e: KeyboardEvent): void {
    if (e.key === "Escape") {
      e.preventDefault(); e.stopPropagation();
      if (this.step !== "main") this.run("action:back");
      else this.close();
      return;
    }
    if (e.key === "ArrowDown") { e.preventDefault(); this.move(1); return; }
    if (e.key === "ArrowUp") { e.preventDefault(); this.move(-1); return; }
    if (e.key === "Enter") {
      e.preventDefault();
      const id = this.entryIds()[this.sel];
      if (id) this.run(id);
    }
  }

  private move(d: number): void {
    const n = this.entryIds().length;
    if (n === 0) return;
    this.sel = (this.sel + d + n) % n;
    this.paint();
  }

  private rebuild(selected?: string): void {
    if (!this.ctx?.active || this.ctx.windowless) this.step = "main";
    this.els.input.placeholder = this.step === "main" ? this.searchPlaceholder : "Choose an iOS Simulator…";
    this.model = this.ctx ? paletteModel(this.ctx, this.els.input.value, this.step) : { actions: [], tiles: [] };
    this.sel = selected ? Math.max(0, this.entryIds().indexOf(selected)) : 0;
    this.paint();
  }

  private paint(): void {
    const ids = this.entryIds();
    const n = this.model.notice;
    this.els.notice.classList.toggle("hidden", !n);
    if (n) { this.els.noticeTitle.textContent = n.title; this.els.noticeDetail.textContent = n.detail; }
    this.els.tmuxNote.textContent = this.model.tmuxNote ?? "";
    this.els.tmuxNote.classList.toggle("hidden", !this.model.tmuxNote);
    // "No matches" under an explanation is noise — the notice already says why the grid is empty.
    const hasChoices = ids.some(id => id !== "action:back");
    this.els.empty.classList.toggle("hidden", hasChoices || !!n);

    let previousSection = "";
    this.els.actions.replaceChildren(...this.orderedActions().flatMap((a, i) => {
      const section = this.step === "launch-simulator" ? "Launch iOS Simulator" : a.id.startsWith("tmux:") ? "Open terminals" : a.id.startsWith("agent:") ? "Agent sessions" : "Commands";
      const heading = document.createElement("h2");
      heading.className = "palette-section-title";
      heading.textContent = section;
      const startsSection = section !== previousSection;
      previousSection = section;
      const row = document.createElement("button");
      row.type = "button";
      row.className = "pal-row" + (i === this.sel ? " on" : "");
      // The glasses D-pad addresses controls by this id; harmless on every other layout. Without it
      // the wearer can reach the query field and the ✕ and nothing between them.
      row.dataset.navId = `palette:${a.id}`;
      const glyph = document.createElement("span"); glyph.className = "pal-glyph"; glyph.innerHTML = actionIcon(a.id);
      const mid = document.createElement("span"); mid.className = "pal-mid";
      const label = document.createElement("span"); label.className = "pal-label"; label.textContent = a.label;
      const hint = document.createElement("span"); hint.className = "pal-hint"; hint.textContent = a.hint;
      mid.append(label);
      if (a.hint) mid.append(hint);
      row.append(glyph, mid);
      row.addEventListener("click", () => this.run(a.id));
      return startsSection ? [heading, row] : [row];
    }));
    if(productFeatures.graphicalAgents&&this.ctx?.agents&&this.ctx.agentSearchNotice){
      const note=document.createElement("p");note.className="palette-section-title";note.setAttribute("role","status");
      note.textContent=this.ctx.agentSearchNotice;this.els.actions.append(note);
    }

    const offset = this.model.actions.length;
    this.els.grid.replaceChildren(...this.model.tiles.map((t, i) => this.renderTile(t, offset + i === this.sel)));
  }

  private renderTile(t: GalleryTile, selected: boolean): HTMLElement {
    const tile = document.createElement("button");
    tile.type = "button";
    tile.className = "source-tile" + (t.subscribed ? " subscribed" : "") + (t.focused ? " focused" : "")
      + (selected ? " on" : "");
    tile.dataset.source = t.id;
    // NOT A NEW GLYPH FOR THE DISPLAY KIND — see source-picker.ts. A CSS accent keyed on this carries
    // the same information with no font-subset risk.
    tile.dataset.kind = t.kind;
    tile.dataset.navId = `palette:source:${t.id}`;   // see the action row above

    const img = document.createElement("div");
    img.className = "source-tile-img" + (t.thumb.kind === "loading" ? " loading" : "");
    if (t.thumb.kind === "image") {
      const el = document.createElement("img");
      el.src = t.thumb.dataUrl; el.alt = ""; el.loading = "lazy";
      img.append(el);
    } else if (t.thumb.kind === "placeholder") {
      img.textContent = t.kind === "sim" ? "▣" : "▢";
    }

    const cap = document.createElement("span"); cap.className = "source-tile-cap";
    const dot = document.createElement("span"); dot.className = "sim-dot" + (t.running ? " running" : "");
    const name = document.createElement("span"); name.className = "source-tile-name"; name.textContent = t.name; tile.title = t.name;
    cap.append(dot, name);
    if (t.subscribed) { const c = document.createElement("span"); c.className = "sim-check"; c.textContent = "✓"; cap.append(c); }
    else if (t.stateLabel) { const s = document.createElement("span"); s.className = "source-tile-state"; s.textContent = t.stateLabel; cap.append(s); }

    tile.append(img, cap);
    tile.addEventListener("click", () => this.run(`source:${t.id}`));
    return tile;
  }
}
