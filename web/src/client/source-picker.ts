/// Pure parsing + view-model for the unified source picker, plus the view-set accessors. Mirrors the
/// host's source-list / view-set messages (Phase 3a/3b). The DOM controller (SourcePicker) is thin; the
/// functions here are unit-tested in isolation.

/// A simulator's lifecycle state (`source-list`, `source-status`); absent means "not a simulator".
export type SimStateWire = "booted" | "booting" | "shutdown" | "shutting-down";
export interface Source { id: string; kind: string; name: string; inputCapable: boolean; running: boolean; w?: number; h?: number; simState?: SimStateWire }
/// What the host can currently capture. ABSENT MEANS UNKNOWN — never assume "ok".
///
/// A sleeping display is online but NOT active, which empties the host's display list and kills
/// capture on every source while windows still enumerate. The client needs this to explain an empty
/// grid instead of rendering one.
export interface HostDisplay {
  availability: "ok" | "asleep" | "none";
  /// Absent means unknown, which is NOT the same as unlocked.
  locked?: boolean;
}
export interface SourceListMsg { sources: Source[]; display?: HostDisplay }
/// `codec` is what the client ASKED for; `activeCodec` is what the track's answer settled on and is
/// ABSENT until it resolves — the UI must be able to tell that from "resolved and equal to the request".
/// `activeDelivery` is the transport the host ACTUALLY routed this source over, and `dcIndex` the
/// slot it assigned on the multiplexed video channel. Both ABSENT until resolved — the same rule
/// `activeCodec` follows — and `dcIndex` rides only with `dc`, since an index without the channel
/// would let the client bind symbols to a source not delivered over it.
///
/// These are SUB-LEVEL fields, so unlike the top-level ones they survive `parseViewSet` by riding
/// the array cast rather than needing to be reconstructed there.
export interface ViewSub {
  source: string; scale: number; fps: number; bitrateBps: number;
  presentation?: unknown;
  codec?: string; activeCodec?: string;
  activeDelivery?: "rtp" | "dc"; dcIndex?: number;
  /// Whether the host is SENDING this source's audio to this client. ABSENT MEANS UNKNOWN, never
  /// "off" — the `activeCodec` rule. A host that predates audio must not render as muted.
  audio?: boolean;
  /// Set only when this source YIELDED: the id of the source carrying its application's audio.
  /// `audio: false` with NO owner is MUTED — a setting the user chose. `audio: false` WITH one is
  /// yielded — a fact about the host they did not. They sound identical and must not look identical.
  audioOwner?: string;
}
/// ONE WINDOW OF THE HOST'S SESSION STATE (`view-set.windows`, tab order): open or minimized, and
/// where the desktop layout last put it. A minimized window is still the session's — its tab stays
/// in the bar — but the host captures nothing for it. `x`/`y` are the stage's CSS px, TOGETHER OR
/// NEITHER; absent means the client cascades it. `name` is the one the driver gave it (`rename-tab`),
/// absent when it has none — its tab and titlebar then show the source's own name.
export interface SessionWindowMsg { source: string; minimized: boolean; x?: number; y?: number; name?: string }
/// What the session shows (`view-set.view`): the terminal or the windows on a pinned layout, and the
/// window that is full screen, if any.
export interface SessionViewMsg { surface: "terminal" | "windows" | "agents"; fullscreen: string | null }
export interface SessionAgentMsg { id: string; title: string; cwd: string; name?: string; status?: "active"|"idle"|"notLoaded"|"systemError"; activeFlags?:string[] }
/// A fresh host's view, and what an absent `view` reads as.
export const DEFAULT_SESSION_VIEW: Readonly<SessionViewMsg> = Object.freeze({ surface: "terminal", fullscreen: null });
/// `recoveryOverrideBp` is SESSION-WIDE, not per subscription — one forced FEC overhead for the whole
/// connection, which every window's titlebar renders.
///
/// IT IS OPTIONAL BECAUSE THE WIRE MAKES IT OPTIONAL: the host omits the field entirely under adaptive
/// control, so absent and `null` mean the same thing and a host that predates this feature reads as
/// Auto rather than as a forced zero. `parseViewSet` normalises absent to `null`; read it as
/// `?? null` anywhere a hand-built message can reach.
/// `activeRecovery` is the stack the connection ACTUALLY runs, absent until the answer settles it —
/// absent means UNKNOWN, never "degraded", the same rule `activeCodec` follows.
export interface ViewSetMsg {
  agents?: SessionAgentMsg[];
  selectedAgent?: string | null;
  subs: ViewSub[];
  focused: string | null;
  recoveryOverrideBp?: number | null;
  activeRecovery?: string | null;
  /// The session's playout-delay FLOOR in ms. ABSENT MEANS AUTO, the same rule as
  /// `recoveryOverrideBp` — and the reason an older host reads as Auto rather than a forced zero.
  playoutDelayMinMs?: number | null;
  /// The explicit ceiling the session asked for; absent is the host's configured ceiling.
  playoutDelayMaxMs?: number | null;
  /// Whether the host's screen curtain is UP. ABSENT MEANS UNKNOWN — never "down" — the same rule
  /// `activeRecovery` and `activeCodec` follow. A host that predates this field must read as "no
  /// opinion" rather than asserting a state the UI would then render confidently.
  curtainUp?: boolean | null;
  /// THE HOST'S SESSION STATE, windows half (docs/superpowers/specs/2026-09-29-host-session-state-design.md):
  /// every window of the session in tab order — minimized ones included — its desktop position, and
  /// the view. REQUIRED here because `parseViewSet` always fills them (absent ⇒ none / the terminal / 0).
  /// `subs` stays what it always was: the LIVE echo of the windows being streamed.
  windows: SessionWindowMsg[];
  view: SessionViewMsg;
  /// THE TAB BAR'S ORDER — every terminal tab and window, interleaved as the driver arranged them
  /// (`move-tab`; docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md). Absent ⇒ empty, which
  /// `tabBarOrder` reads as today's bar: the terminals, then the windows.
  tabOrder: string[];
  /// Increments on every change of the state.
  version: number;
}
export interface SubPrefs { scale: number; fps: number; bitrateBps: number }
export interface SourceRow { id: string; kind: string; name: string; running: boolean; inputCapable: boolean; current: boolean; simState?: SimStateWire }
export interface SourceStatus { id: string; live: boolean; w?: number; h?: number; pxW?: number; pxH?: number; simState?: SimStateWire }
export interface SourceStatusMsg { statuses: SourceStatus[] }

/// `w`/`h` are OPTIONAL point sizes. Absent = unknown (never zero); present must be a positive number.
/// A present-but-wrong-typed size is a protocol error, so the whole message is rejected rather than
/// silently dropping the field and rendering at the wrong size.
/// Optional size fields are either absent (UNKNOWN) or a positive finite number — never 0. Shared by
/// `Source` and `SourceStatus`; a `Source` carrying pxW/pxH would validate and be ignored, which is the
/// harmless forward-compatible outcome if `source-list` ever gains them.
function validOptionalSize(v: Record<string, unknown>): boolean {
  const okDim = (d: unknown) => d === undefined || (typeof d === "number" && Number.isFinite(d) && d > 0);
  return okDim(v.w) && okDim(v.h) && okDim(v.pxW) && okDim(v.pxH);
}

function isSource(v: unknown): v is Source {
  if (typeof v !== "object" || v === null) return false;
  const s = v as Record<string, unknown>;
  return typeof s.id === "string" && typeof s.kind === "string" && typeof s.name === "string"
    && typeof s.inputCapable === "boolean" && typeof s.running === "boolean" && validOptionalSize(s) && validSimState(s);
}

const SIM_STATES: readonly SimStateWire[] = ["booted", "booting", "shutdown", "shutting-down"];
/// `simState` is OPTIONAL — absent is "not a simulator". Present, it must be one the protocol has.
function validSimState(s: Record<string, unknown>): boolean {
  return s.simState === undefined || SIM_STATES.includes(s.simState as SimStateWire);
}

function parseHostDisplay(v: unknown): HostDisplay | undefined {
  if (typeof v !== "object" || v === null) return undefined;
  const d = v as { availability?: unknown; locked?: unknown };
  if (d.availability !== "ok" && d.availability !== "asleep" && d.availability !== "none") return undefined;
  const out: HostDisplay = { availability: d.availability };
  if (typeof d.locked === "boolean") out.locked = d.locked;
  return out;
}

/// Narrow a decoded control-channel JSON message to a SourceListMsg, or null if it isn't one.
export function parseSourceList(msg: unknown): SourceListMsg | null {
  if (typeof msg !== "object" || msg === null) return null;
  const m = msg as { t?: unknown; sources?: unknown; display?: unknown };
  if (m.t !== "source-list" || !Array.isArray(m.sources) || !m.sources.every(isSource)) return null;
  // A malformed display block degrades to "unknown" and MUST NOT discard the sources — the list is
  // the message's job; the display block only explains it.
  const display = parseHostDisplay(m.display);
  return display ? { sources: m.sources as Source[], display } : { sources: m.sources as Source[] };
}

function isViewSub(v: unknown): v is ViewSub {
  if (typeof v !== "object" || v === null) return false;
  const s = v as Record<string, unknown>;
  return typeof s.source === "string" && typeof s.scale === "number"
    && typeof s.fps === "number" && typeof s.bitrateBps === "number";
}

function parseSessionWindow(v: unknown): SessionWindowMsg | null {
  if (typeof v !== "object" || v === null) return null;
  const w = v as Record<string, unknown>;
  if (typeof w.source !== "string" || typeof w.minimized !== "boolean") return null;
  if (w.name !== undefined && typeof w.name !== "string") return null;
  const out: SessionWindowMsg = { source: w.source, minimized: w.minimized };
  if (typeof w.name === "string") out.name = w.name;
  // TOGETHER OR NEITHER: half a position cannot place a window, so it is no position at all.
  if (typeof w.x === "number" && Number.isFinite(w.x) && typeof w.y === "number" && Number.isFinite(w.y)) {
    out.x = w.x; out.y = w.y;
  }
  return out;
}

function parseSessionView(v: unknown): SessionViewMsg {
  if (typeof v !== "object" || v === null) return { ...DEFAULT_SESSION_VIEW };
  const o = v as Record<string, unknown>;
  return {
    surface: o.surface === "agents" ? "agents" : o.surface === "windows" ? "windows" : "terminal",
    fullscreen: typeof o.fullscreen === "string" ? o.fullscreen : null,
  };
}

/// Narrow a decoded control-channel JSON message to a ViewSetMsg, or null if it isn't one.
export function parseViewSet(msg: unknown): ViewSetMsg | null {
  if (typeof msg !== "object" || msg === null) return null;
  const m = msg as {
    t?: unknown; subs?: unknown; focused?: unknown;
    recoveryOverrideBp?: unknown; activeRecovery?: unknown;
    playoutDelayMinMs?: unknown; playoutDelayMaxMs?: unknown; curtainUp?: unknown;
    windows?: unknown; view?: unknown; version?: unknown; tabOrder?: unknown; agents?: unknown; selectedAgent?: unknown;
  };
  if (m.t !== "view-set" || !Array.isArray(m.subs) || !m.subs.every(isViewSub)) return null;
  if (m.agents !== undefined && (!Array.isArray(m.agents) || m.agents.length > 100 || !m.agents.every(a =>
    a && typeof a.id === "string" && a.id.length > 0 && a.id.length <= 128 && typeof a.title === "string" &&
    typeof a.cwd === "string" && (a.name === undefined || typeof a.name === "string") &&
    (a.status===undefined||["active","idle","notLoaded","systemError"].includes(a.status)) &&
    (a.activeFlags===undefined||(Array.isArray(a.activeFlags)&&a.activeFlags.every((f:unknown)=>f==="waitingOnApproval"||f==="waitingOnUserInput")))))) return null;
  // THE STATE IS READ WHOLE OR NOT AT ALL, like `subs`: a window list with one malformed entry would
  // render a session that is not the host's — a window missing, or a minimized one shown open.
  let windows: SessionWindowMsg[] = [];
  if (m.windows !== undefined) {
    if (!Array.isArray(m.windows)) return null;
    const parsed = m.windows.map(parseSessionWindow);
    if (parsed.some((w) => w === null)) return null;
    windows = parsed as SessionWindowMsg[];
  }
  // The same rule for the bar's order: a malformed one would draw a bar that is not the host's.
  let tabOrder: string[] = [];
  if (m.tabOrder !== undefined) {
    if (!Array.isArray(m.tabOrder) || !m.tabOrder.every((k) => typeof k === "string")) return null;
    tabOrder = m.tabOrder as string[];
  }
  const focused = typeof m.focused === "string" ? m.focused : null;
  const recoveryOverrideBp = typeof m.recoveryOverrideBp === "number" ? m.recoveryOverrideBp : null;
  // EVERY FIELD ViewSetMsg DECLARES MUST BE READ HERE. `activeRecovery` was declared and never parsed,
  // and because main.ts assigns `lastViewSet = vs` wholesale, the field was permanently undefined and
  // the footer's `no FEC` cell could never render on any build. Adding a field to the interface without
  // adding it here is silent — tsc cannot see the omission, since every field is optional.
  const activeRecovery = typeof m.activeRecovery === "string" ? m.activeRecovery : null;
  const playoutDelayMinMs = typeof m.playoutDelayMinMs === "number" ? m.playoutDelayMinMs : null;
  const playoutDelayMaxMs = typeof m.playoutDelayMaxMs === "number" ? m.playoutDelayMaxMs : null;
  const curtainUp = typeof m.curtainUp === "boolean" ? m.curtainUp : null;
  const version = typeof m.version === "number" && Number.isFinite(m.version) && m.version >= 0 ? m.version : 0;
  return { subs: m.subs as ViewSub[], focused, recoveryOverrideBp, activeRecovery,
           playoutDelayMinMs, playoutDelayMaxMs, curtainUp,
           windows, view: parseSessionView(m.view), tabOrder, version,
           agents: (m.agents ?? []) as SessionAgentMsg[], selectedAgent: typeof m.selectedAgent === "string" ? m.selectedAgent : null };
}

function isSourceStatus(v: unknown): v is SourceStatus {
  if (typeof v !== "object" || v === null) return false;
  const s = v as Record<string, unknown>;
  return typeof s.id === "string" && typeof s.live === "boolean" && validOptionalSize(s) && validSimState(s);
}

/// Narrow a decoded control-channel JSON message to a SourceStatusMsg, or null if it isn't one. Per-window
/// runtime liveness (Task: window-liveness); a source ABSENT from `statuses` is treated as live by callers.
export function parseSourceStatus(msg: unknown): SourceStatusMsg | null {
  if (typeof msg !== "object" || msg === null) return null;
  const m = msg as { t?: unknown; statuses?: unknown };
  if (m.t !== "source-status" || !Array.isArray(m.statuses) || !m.statuses.every(isSourceStatus)) return null;
  return { statuses: m.statuses as SourceStatus[] };
}

/// The subscribed source id (cap 1: subs[0]), or null when nothing is subscribed.
export function subscribedSource(vs: Pick<ViewSetMsg, "subs">): string | null {
  return vs.subs[0]?.source ?? null;
}

/// All subscribed source ids, in view-set order (the multi-select generalization of `subscribedSource`).
export function subscribedSources(vs: Pick<ViewSetMsg, "subs">): string[] {
  return vs.subs.map((s) => s.source);
}

/// The prefs of the subscribed source (to reflect the fps/res/bitrate controls), or null when nothing
/// is subscribed.
export function subscribedPrefs(vs: Pick<ViewSetMsg, "subs">): SubPrefs | null {
  const s = vs.subs[0];
  return s ? { scale: s.scale, fps: s.fps, bitrateBps: s.bitrateBps } : null;
}

/// The windows the host should be streaming: open and not minimized, in tab order. THE SESSION'S
/// answer — `subscribedSources` is the host's live echo, which lags it (a restored window is in the
/// state before its stream is re-established).
export function streamedWindows(vs: Pick<ViewSetMsg, "windows">): string[] {
  return vs.windows.filter((w) => !w.minimized).map((w) => w.source);
}

/// Map sources + the subscribed SET to render-ready rows (each subscribed id flagged `current`).
export function sourceRows(sources: Source[], current: string[]): SourceRow[] {
  const set = new Set(current);
  return sources.map((s) => ({
    id: s.id, kind: s.kind, name: s.name, running: s.running, inputCapable: s.inputCapable,
    current: set.has(s.id),
  }));
}

/// A source row's secondary state label for the picker, or null. This increment: a WINDOW that is not
/// running is minimized (the only listed-but-not-running window case); sims convey shut-down via the greyed
/// dot alone, so they never get a label here.
export function sourceStateLabel(row: SourceRow): string | null {
  if (row.kind === "sim") {
    switch (row.simState) {
      case "shutdown": return "shut down";
      case "booting": return "booting…";
      case "shutting-down": return "shutting down…";
      default: return null;
    }
  }
  return row.kind === "window" && !row.running ? "minimized" : null;
}

/// The picker button label: the sole subscribed source's name, a count for multiple, or a placeholder
/// for none.
export function currentSourceLabel(sources: Source[], current: string[]): string {
  if (current.length === 0) return "No source";
  if (current.length === 1) {
    const c = sources.find((s) => s.id === current[0]);
    return c ? c.name : "No source";
  }
  return `${current.length} sources`;
}

/// DOM controller for the unified topbar source picker — one flat list of sources (sims + windows),
/// MULTI-SELECT: every subscribed source is marked, clicking a subscribed row unsubscribes it and
/// clicking an unsubscribed row subscribes it (active clients only), refresh on open. Kept thin; the
/// logic above is what's unit-tested.
export class SourcePicker {
  private sources: Source[] = [];
  private current: string[] = [];
  private isActive = false;
  private open = false;

  constructor(
    private readonly els: { button: HTMLButtonElement; menu: HTMLUListElement; list: HTMLUListElement; note: HTMLElement },
    private readonly cb: { onSubscribe(id: string): void; onUnsubscribe(id: string): void; onList(): void },
  ) {
    this.els.button.addEventListener("click", () => this.toggle());
    document.addEventListener("click", (e) => {
      if (this.open && !this.els.menu.contains(e.target as Node) && e.target !== this.els.button) this.close();
    });
  }

  update(sources: Source[], current: string[], isActive: boolean): void {
    this.sources = sources; this.current = current; this.isActive = isActive;
    this.renderButton();
    if (this.open) this.renderList();
  }

  /// Show a transient status/permission note (or clear it when undefined).
  setNote(text: string | undefined): void { this.els.note.textContent = text ?? ""; }

  private toggle(): void { this.open ? this.close() : this.openMenu(); }

  private openMenu(): void {
    this.open = true;
    this.els.menu.classList.remove("hidden");
    this.els.button.setAttribute("aria-expanded", "true");
    this.cb.onList();   // request a fresh source list
    this.renderList();
  }

  private close(): void {
    this.open = false;
    this.els.menu.classList.add("hidden");
    this.els.button.setAttribute("aria-expanded", "false");
  }

  private renderButton(): void {
    this.els.button.textContent = `${currentSourceLabel(this.sources, this.current)} ▾`;
  }

  private renderList(): void {
    const rows = sourceRows(this.sources, this.current);
    this.els.list.replaceChildren();
    for (const r of rows) {
      const li = document.createElement("li");
      li.setAttribute("role", "option");
      const disabled = !this.isActive;
      if (disabled) li.setAttribute("aria-disabled", "true");
      const dot = document.createElement("span");
      dot.className = `sim-dot${r.running ? " running" : ""}`;
      const kind = document.createElement("span");
      kind.className = "source-kind";
      kind.textContent = r.kind === "window" ? "▢" : "▣";   // window vs simulator badge
      const name = document.createElement("span");
      name.className = "sim-name";
      name.textContent = r.name;
      li.append(dot, kind, name);
      const state = sourceStateLabel(r);
      if (state) {
        const stateEl = document.createElement("span");
        stateEl.className = "source-state";
        stateEl.textContent = state;
        li.append(stateEl);
      }
      if (r.current) {
        const check = document.createElement("span");
        check.className = "sim-check"; check.textContent = "✓";
        li.append(check);
      }
      li.title = disabled ? "Claim control to switch" : "";
      // Multi-select: a click TOGGLES the row (subscribe / unsubscribe) and the menu stays open so more
      // rows can be picked without reopening — unlike the old single-select "pick and close".
      if (!disabled) li.addEventListener("click", () => { if (r.current) this.cb.onUnsubscribe(r.id); else this.cb.onSubscribe(r.id); });
      this.els.list.append(li);
    }
    const refresh = document.createElement("li");
    refresh.className = "sim-refresh"; refresh.textContent = "↻ refresh";
    refresh.addEventListener("click", (e) => { e.stopPropagation(); this.cb.onList(); });
    this.els.list.append(refresh);
  }
}


export interface WorkspaceFormat {
  format: "workspace-rgb-alpha-hit-v1";
  logicalWidth: 1280; logicalHeight: 800; capturedWidth: 1280; capturedHeight: 800;
  codedWidth: 3840; codedHeight: 800; codec: "av1";
}
/** Explicit protocol contract. Never infer packed pixels from decoded dimensions. */
export function parseWorkspaceFormat(value: unknown): WorkspaceFormat | null {
  if (!value || typeof value !== "object") return null;
  const f = value as Record<string, unknown>;
  return f.format === "workspace-rgb-alpha-hit-v1" && f.logicalWidth === 1280 && f.logicalHeight === 800
    && f.capturedWidth === 1280 && f.capturedHeight === 800 && f.codedWidth === 3840
    && f.codedHeight === 800 && f.codec === "av1" ? f as unknown as WorkspaceFormat : null;
}
export interface WorkspaceApp { id: string; name: string; bundleID?: string }
export interface AppsState {
  applications: WorkspaceApp[];
  members: { app: WorkspaceApp; phase: "shared" | "failed"; error?: string }[];
  source?: string; format: WorkspaceFormat;
  availability: "disabled" | "available" | "failed"; error?: string; recoveryCount: number;
}
export function parseAppsState(value: unknown): AppsState | null {
  if (!value || typeof value !== "object") return null;
  const m = value as Record<string, unknown>;
  const app = (x: unknown): x is WorkspaceApp => !!x && typeof x === "object"
    && typeof (x as WorkspaceApp).id === "string" && typeof (x as WorkspaceApp).name === "string"
    && ((x as WorkspaceApp).bundleID === undefined || typeof (x as WorkspaceApp).bundleID === "string");
  if (m.t !== "apps-state" || !parseWorkspaceFormat(m.format) || !Array.isArray(m.applications)
    || !m.applications.every(app) || !Array.isArray(m.members) || !m.members.every(x => x && app(x.app)
      && (x.phase === "shared" || x.phase === "failed") && (x.error === undefined || typeof x.error === "string"))
    || !["disabled", "available", "failed"].includes(m.availability as string)
    || !Number.isSafeInteger(m.recoveryCount) || (m.recoveryCount as number) < 0
    || (m.source !== undefined && (typeof m.source !== "string" || !m.source.startsWith("apps:")))
    || (m.error !== undefined && typeof m.error !== "string")) return null;
  return m as unknown as AppsState;
}
