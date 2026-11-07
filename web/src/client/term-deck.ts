import { contextFor, activeWithin } from "./instance/context";
import { windowResizeSettle } from "./resize-settle";
// ONE xterm.js INSTANCE PER OPEN TAB (docs/terminal.md, "Live tabs"). Every open tab streams into its
// own instance; the visible one is shown, the rest are mounted and hidden, and a switch shows another
// — no bytes, no repaint. A snapshot builds a FRESH instance (the emitter targets one), hidden inside
// the tab's slot while its bytes are written, and swapped in at `commit` — so a re-serialized tab
// never flashes a blank frame. All instances share the terminal area: a grid change resizes every
// one and is reported ONCE.
//
// DOM: container > .xterm-tab (one slot per tab, in flow, 100%×100%) > .xterm-inst (absolute, inset 0;
// `.is-pending` while its snapshot is written). With no tab visible, `fit` measures a THROWAWAY
// instance (mounted, measured, disposed), so the host learns the grid before the first tab exists and
// no permanent extra `.xterm-screen` sits in the DOM for checks to trip over.
//
// `begin`, `commit`, `close` and `retain` DISPOSE instances. main.ts runs every one of them INSIDE its
// one op chain (`enqueue`), in wire order with the writes, so nothing is ever written into an instance
// after it is torn down, and each event lands in the same order relative to the bytes as on the wire.
// (A write to a disposed xterm.js, or one in flight at `dispose()`, still calls back — measured in
// Chromium — so this is about order and not writing into a dead terminal, not about the chain hanging.)
import type { Terminal } from "@xterm/xterm";
import type { Theme } from "../shared/theme";
import { fontNames } from "./instance/styles";
import { mountXterm, mountMeasuringXterm, releaseCanvas, type XtermView, type XtermViewOpts } from "./xterm-view";
import { holdShiftRows } from "./hold-shift";
import { elementHoldsFocus, isRequestedTab, terminalTakesFocus, terminalTakesWindowKeys, type OpenRequest, type VisibleChangeReason } from "./term-view-policy";

export interface TermDeckOpts {
  container: HTMLElement;
  fontSize: number;
  theme: Theme;
  /// Smooth scrolling of the scrollback (smooth-scroll.ts): the saved preference; `setSmoothScroll`
  /// changes it for every instance, later ones included.
  smoothScroll?: boolean;
  /// `false` leaves a scroll's rows to xterm.js's frame (`?scrollsync=0`; xterm-view.ts, `scrollSync`).
  scrollSync?: boolean;
  /// `false` leaves a trackpad's wheel to xterm.js, unresampled (`?wheelresample=0`; xterm-view.ts).
  wheelResample?: boolean;
  /// Which renderer every instance draws with (`?renderer=webgpu`; xterm-view.ts).
  renderer?: "dom" | "webgpu";
  /// Which tabs' first content FADES in (`watchFirstContent`): every tab's (`"always"`, the default), or only a NEW
  /// terminal's this client asked for (`"new"` — `expectOpenedTab` for a kind) while every other tab's appears.
  /// This Mac is `"new"` (2026-10-04, asked: "on This Mac none of the terminals should have any fade-in", then
  /// "in new terminals we should use fade-in even on This Mac").
  fadeIn?: "always" | "new";
  /// TYPING (keys, paste, mouse and focus reports) from the VISIBLE tab's live instance, named with its
  /// tab — the host drops it if that is not its active tab. Hidden instances never type.
  onData(tab: string, data: string): void;
  /// A device-query REPLY from ANY tab's current instance (live or pending, shown or hidden), named with
  /// THAT tab: the host leaves every query that reached this client to the instance that parsed it,
  /// because it cannot know which tab is shown (TerminalManager.handleTabOutput, `term-reply`).
  onReply(tab: string, data: string): void;
  /// A BEL from ANY tab's current instance (live or pending, shown or hidden), named with THAT tab — what
  /// the person has seen is the session's to decide (term-bell.ts). A snapshot carries no bell: it is a
  /// state, not a stream (web/test/term-bell.test.ts holds every emitted fixture to that).
  onBell?(tab: string): void;
  /// An IMAGE PATH printed in a tab was clicked or tapped (term-paths.ts), named with THAT tab: a relative path is
  /// relative to what runs in it.
  onPath?(tab: string, path: string): void;
  /// Whether a HELD resize moves the picture to where the host will put it (hold-shift.ts) — read on every resize.
  /// A touch device's (a phone's keyboard opening): bottom-aligned, less motion. Absent or false — a desktop, the
  /// app's windows: the held picture stays TOP-LEFT, as a window's edge pulls it (asked 2026-10-06: "In the
  /// desktop app, anchor the terminal to top-left instead of bottom-left. This looks better on resize").
  holdShift?(): boolean;
  onFit(cols: number, rows: number): void;
  onVisibleChange(view: XtermView | null, tab: string | null): void;
  /// Whether this client may give the terminal focus at all: the driver, off glasses. The deck decides
  /// WHEN (`terminalTakesFocus`): a user switch, or handing on focus the terminal already held — never
  /// a repaint, which would take it from a remote window mid-typing.
  /// Absent: the terminal never takes focus (the synthetic-DOM checks).
  /// `softKeyboard`: focusing raises one (a touch device) — then only a focus already held is handed on.
  focusPolicy?(userOpened?: boolean): { driver: boolean; mayAutofocus: boolean; softKeyboard?: boolean };
  /// Tests inject a fake; the product mounts real xterm.js.
  mount?: (el: HTMLElement, opts: XtermViewOpts) => XtermView;
}

interface Instance { el: HTMLElement; view: XtermView; gen: number }

/// How long a HOLD (`TermDeck.fit`) waits for the host's snapshots before resizing what is still at the old
/// grid itself: a round trip and a snapshot — about 30 ms to This Mac (measured 2026-10-02).
export const FIT_HOLD_MS = 300;
/// How long a tab waits for its FIRST CONTENT before it is shown anyway (`watchFirstContent`): a program that
/// prints nothing, or a login shell slower than this, still appears.
export const FIRST_CONTENT_MAX_MS = 1200;

/// **THE GRID THE TERMINAL AREA HOLDS, BEFORE ANY DECK EXISTS** — what a page says as it joins (offer-screen.ts,
/// `client-confirm`'s app_hello) — measured as `fit` measures with no tab shown: a throwaway instance in a throwaway
/// slot, mounted, measured, disposed. Null when the area cannot be measured (the terminal surface hidden behind the
/// window surface on a phone) or the terminal's font has not loaded: a grid measured in a fallback font is a grid the
/// deck will not report, and the host would resize every tab twice.
// Repeated startup fits ask about the same empty area before its first snapshot.
// Cache the measured grid, not guessed character widths, for embedded clients only.
const measuredGrids = new WeakMap<HTMLElement, {key:string;cols:number;rows:number}>();
const fontIds = new WeakMap<FontFace,number>();
let nextFontId=0;
function measurementKey(container:HTMLElement,fontSize:number,theme:Theme,family:string): string | null {
  const context=contextFor(container),doc=container.ownerDocument;
  if(!context)return null;
  const style=doc.defaultView!.getComputedStyle(container);
  // WebKit may not deliver FontFaceSet events for every programmatic addition.
  // Include face identity/status and descriptors rather than relying on events alone.
  const faces=Array.from(doc.fonts??[],face=>{
    let id=fontIds.get(face);if(id===undefined){id=++nextFontId;fontIds.set(face,id);}
    return [id,face.status,face.family,face.weight,face.style,face.stretch,face.unicodeRange];
  });
  return JSON.stringify([style.width,style.height,style.padding,style.boxSizing,fontSize,theme,family,
    doc.defaultView!.devicePixelRatio,faces,container.className]);
}

export function measureTerminalGrid(container: HTMLElement, opts: { fontSize: number; theme: Theme; fontFamily?: string },
                                    mount: (el: HTMLElement, o: XtermViewOpts) => XtermView = mountXterm): { cols: number; rows: number } | null {
  // A null cache key used to conflate hidden geometry with uncacheable fonts,
  // allocating scratch terminals even for display:none phone surfaces.
  // Injected mounts retain their synthetic-geometry contract in unit tests.
  if(mount===mountXterm&&!container.getClientRects().length)return null;
  const family = opts.fontFamily ?? `"${contextFor(container) ? fontNames.mono : 'JetBrains Mono'}"`;
  // FontFaceSet.status can remain loading after these faces are already loaded.
  // Check the font used for xterm's cell measurement, then fingerprint the actual
  // faces below; unrelated or delayed FontFaceSet events cannot stale a grid.
  if (container.ownerDocument.fonts && !container.ownerDocument.fonts.check(`${opts.fontSize}px ${family}`, 'W')) return null;
  const key=mount===mountXterm?measurementKey(container,opts.fontSize,opts.theme,family):null;
  const cached=measuredGrids.get(container);
  if(key!==null&&cached?.key===key)return {cols:cached.cols,rows:cached.rows};
  const scratch = document.createElement("div");
  scratch.className = "xterm-tab xterm-measure";
  const inst = document.createElement("div");
  inst.className = "xterm-inst";
  scratch.append(inst);
  container.append(scratch);
  let v: ReturnType<typeof mountMeasuringXterm> | null = null;
  try {
    v = (mount === mountXterm ? mountMeasuringXterm : mount)(inst, { fontSize: opts.fontSize, theme: opts.theme, onData: () => {}, onFit: () => {} });
    const dims = v.measure();
    if(dims && dims.cols > 0 && dims.rows > 0){
      if(key!==null)measuredGrids.set(container,{key,...dims});
      return dims;
    }
    return null;
  } catch {
    return null;
  } finally {
    v?.dispose();
    scratch.remove();
  }
}

/// Something to SEE: a character that is not blank on the screen (`watchFirstContent`).
export function hasVisibleContent(term: Pick<Terminal, "rows" | "buffer">): boolean {
  const b = term.buffer.active;
  for (let y = 0; y < term.rows; y++) {
    if (b.getLine(b.viewportY + y)?.translateToString(true).trim()) return true;
  }
  return false;
}

/// `wire`: the wire the slot was last snapshotted on (`newWire` counts them).
/// `serial`: creation order, so `expectOpenedTab` can tell a slot created after the request.
/// `shown`: the slot has had its FIRST CONTENT (`watchFirstContent`) — until then it is transparent.
/// `contentWatch`/`contentTimer`: what is waiting for it.
/// `isNew`: a NEW terminal this client asked for (`expectOpenedTab` with a kind) — it fades in whatever `fadeIn`
/// says; `fadeOnReveal`: its first content came while it was hidden, so it fades the first time it is shown.
interface Slot {
  id: string; el: HTMLElement; live: Instance | null; pending: Instance | null; wire: number; serial: number;
  /// THE LATE HISTORY's rebuild (`rebaseBegin`): neither live nor pending, so `viewFor` never returns it.
  rebase?: Instance | null;
  shown: boolean; contentWatch?: { dispose(): void }; contentTimer?: ReturnType<typeof setTimeout>;
  isNew: boolean; fadeOnReveal?: boolean;
}

export class TermDeck {
  private readonly slots = new Map<string, Slot>();
  /// Waiting for a tab's FIRST CONTENT (`whenContent`) — a tab that may not have a slot yet.
  private readonly contentWaiters = new Map<string, Set<() => void>>();
  private visible: string | null = null;
  private wire = 0;
  private serial = 0;
  /// The terminal held focus when the visible tab went away (`exit`) or was replaced by one with no
  /// view yet: the next VIEW shown takes it (unless something else took focus in between).
  private focusCarry = false;
  /// Set by `expectOpenedTab`: the tab the user asked for (`isRequestedTab`), the serial at the request,
  /// and — for a kind — how many of that kind are still coming (two quick `open-terminal`s: the SECOND
  /// takes focus) and the new tabs already counted against it.
  private opened: { req: OpenRequest; after: number; remaining: number; seen: Set<string> } | null = null;
  /// `activate` found no visible VIEW (the host-active tab's snapshot queued behind an earlier tab's, on
  /// another channel than the control-state): becoming the driver is remembered until a view is shown,
  /// and decided THEN, by the same policy with the surface read at that moment. Voided by `deactivate`.
  ///
  /// **SCOPED TO A TAB** — `tab` is the tab the deck showed for the host when the intent was made (the
  /// driver re-asserts exactly that one, `switchReset`), and only a view of THAT tab being shown
  /// resolves it, whatever it decides. **It FOLLOWS the host**: every `show` retargets it, so if the
  /// active tab moves before the view commits (a new tab, a closed neighbour, a there-and-back), the
  /// intent lands on the host's NEWEST active tab — at once if that tab already has a view. Why follow
  /// rather than stay put or be voided: "Move here" asks for the terminal the person will be typing
  /// into, and keys go only to the host's active tab (`key{term}` is dropped anywhere else), so
  /// focusing the tab it was made on after the host has left it would focus a tab that drops every
  /// key; voiding it instead would leave the claim with no focus at all — the defect `activate`'s
  /// memory exists to fix. A commit of any OTHER tab, the abandoned one included, never resolves it.
  private activatePending: { tab: string | null; shown: () => boolean } | null = null;
  private grid: { cols: number; rows: number } | null = null;
  /// A HOLD is waiting for the host's snapshots at `grid` (`fit`); its timer resizes what they missed.
  private holdTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly selectionListeners: (() => void)[] = [];
  private readonly mount: (el: HTMLElement, opts: XtermViewOpts) => XtermView;
  private theme: Theme;
  private smoothScroll: boolean;
  /// The tabs an agent runs in (`setAgentTabs`): their instances take trailing blank lines as not there.
  private agentTabs: ReadonlySet<string> = new Set();

  constructor(private readonly o: TermDeckOpts) {
    this.mount = o.mount ?? mountXterm;
    this.theme = o.theme;
    this.smoothScroll = o.smoothScroll ?? false;
  }

  begin(tab: string, cols: number, rows: number, gen: number): void {
    const slot = this.slotFor(tab);
    slot.wire = this.wire;
    if (slot.pending) this.release(slot.pending);
    if (slot.rebase) { this.release(slot.rebase); slot.rebase = null; }   // its generation is over
    slot.pending = this.mountInstance(tab, slot, cols, rows, gen);
  }

  /// A hidden instance for `tab`'s slot: mounted, sized, its input, replies, bells, paths and selection wired — each
  /// only while the instance is the tab's CURRENT one (live or pending), so a rebuild (`rebaseBegin`) stays silent.
  private mountInstance(tab: string, slot: Slot, cols: number, rows: number, gen: number): Instance {
    const el = document.createElement("div");
    el.className = "xterm-inst is-pending";
    slot.el.append(el);
    const inst: Instance = { el, gen, view: undefined as unknown as XtermView };
    inst.view = this.mount(el, {
      fontSize: this.o.fontSize, theme: this.theme, smoothScroll: this.smoothScroll, scrollSync: this.o.scrollSync,
      wheelResample: this.o.wheelResample, renderer: this.o.renderer, onFit: () => {},
      widths: tab.startsWith("tmux:") ? "tmux" : "pty",
      // EVERY instance draws into the area's ONE canvas, once it is the shown one (`reveal`): a switch or a
      // snapshot's swap changes what is drawn there, never which canvas shows (webgpu/surface.ts).
      gpuHost: this.o.container,
      // Typing: the visible tab's LIVE instance only (the pending one holds no focus; a hidden one is
      // not what the user is typing into).
      onData: (d) => {
        if (this.visible === tab && this.slots.get(tab) === slot && slot.live === inst) this.o.onData(tab, d);
      },
      // Replies: the tab's CURRENT instance — live or PENDING (final review I1(c): output that follows
      // a snapshot's end can be merged into the drain queued before the commit and parsed by the
      // pending instance), shown or HIDDEN (N1: the host answers no query that reached this client,
      // since it cannot know which tab is shown). Each byte is written into exactly one instance
      // (`viewFor` by generation), so no query is answered twice. A superseded or closed instance is
      // neither, and sends nothing.
      onReply: (d) => { if (this.current(tab, slot, inst)) this.o.onReply(tab, d); },
      onPath: (path) => { this.o.onPath?.(tab, path); },
    });
    inst.view.hideTrailingBlanks(this.agentTabs.has(tab));
    inst.view.term.onBell(() => { if (this.current(tab, slot, inst)) this.o.onBell?.(tab); });
    inst.view.term.onSelectionChange(() => {
      if (this.visible === tab && slot.live === inst) for (const f of this.selectionListeners) f();
    });
    if (cols > 0 && rows > 0) inst.view.resizeTo(cols, rows);
    return inst;
  }

  /// `inst` is still one of `tab`'s two instances (not superseded, not closed).
  private current(tab: string, slot: Slot, inst: Instance): boolean {
    return this.slots.get(tab) === slot && (slot.live === inst || slot.pending === inst);
  }

  viewFor(tab: string, gen: number): XtermView | null {
    const s = this.slots.get(tab);
    if (s?.pending?.gen === gen) return s.pending.view;
    if (s?.live?.gen === gen) return s.live.view;
    return null;
  }

  commit(tab: string, gen: number): void {
    const s = this.slots.get(tab);
    if (!s?.pending || s.pending.gen !== gen) return;
    const old = s.live;
    // Read BEFORE the old instance goes: only focus the terminal already held is handed on.
    const hadFocus = this.visible === tab && (this.holdsFocus(s.el) || this.focusCarry);
    s.live = s.pending;
    s.pending = null;
    s.live.el.classList.remove("is-pending");
    if (this.grid) s.live.view.resizeTo(this.grid.cols, this.grid.rows);
    if (!s.shown) this.watchFirstContent(s);
    if (this.visible === tab) this.reveal(tab, "commit", hadFocus);
    // Released AFTER the reveal: focus the old instance held goes to the new one while both are in the
    // page, as a tab switch hands it on. Removed first, the focused element sent focus through <body>,
    // and iOS drops the soft keyboard — and a resize re-sends the tab, so this follows every keyboard
    // opening on a phone (docs/terminal.md, "A RESIZE RE-SENDS EVERY TAB").
    if (old) this.release(old);
  }

  /// **THE LATE HISTORY** (docs/terminal.md, "Scrollback comes after the screen"): begin rebuilding generation `gen` of
  /// `tab` — a hidden instance at the history's grid, which `rebaseView` is written (the full snapshot, then the live
  /// text since) and `rebaseCommit` swaps in. False when the slot holds no instance of `gen` any more (superseded).
  rebaseBegin(tab: string, gen: number, cols: number, rows: number): boolean {
    const s = this.slots.get(tab);
    // Its generation's instance is the pending one, or the live one with nothing newer pending (a newer generation
    // replaces it anyway).
    if (!s || !(s.pending?.gen === gen || (s.live?.gen === gen && !s.pending))) return false;
    if (s.rebase) this.release(s.rebase);
    s.rebase = this.mountInstance(tab, s, cols, rows, gen);
    return true;
  }

  /// The rebuild of generation `gen` of `tab`, while one is under way.
  rebaseView(tab: string, gen: number): XtermView | null {
    const r = this.slots.get(tab)?.rebase;
    return r && r.gen === gen ? r.view : null;
  }

  /// The rebuild has everything its generation's instance has, and its scrollback: it REPLACES that instance. A pending
  /// one (its commit still to come — a held resize's settle) is replaced in place, and the pending commit commits the
  /// rebuild; a live one goes through `commit` — focus handed on, the reveal, the old instance released. False when the
  /// generation is gone (nothing changes).
  rebaseCommit(tab: string, gen: number): boolean {
    const s = this.slots.get(tab);
    const r = s?.rebase;
    if (!s || !r || r.gen !== gen) return false;
    s.rebase = null;
    if (s.pending?.gen === gen) { this.release(s.pending); s.pending = r; return true; }
    if (s.live?.gen !== gen || s.pending) { this.release(r); return false; }
    s.pending = r;
    this.commit(tab, gen);
    return true;
  }

  /// Give up the rebuild of generation `gen` of `tab` (its live text outgrew what is kept, or the generation is gone):
  /// the tab keeps its screen-only instance. A rebuild of ANOTHER generation is not this one's to release.
  rebaseAbandon(tab: string, gen: number): void {
    const s = this.slots.get(tab);
    if (s?.rebase && s.rebase.gen === gen) { this.release(s.rebase); s.rebase = null; }
  }

  close(tab: string): void {
    const s = this.slots.get(tab);
    if (!s) return;
    // Read BEFORE the focused instance goes: a tab exiting under the user's fingers hands focus on.
    if (this.visible === tab && this.holdsFocus(s.el)) this.focusCarry = true;
    if (s.live) this.release(s.live);
    if (s.pending) this.release(s.pending);
    if (s.rebase) { this.release(s.rebase); s.rebase = null; }
    this.stopWatching(s);
    s.el.remove();
    this.slots.delete(tab);
    if (this.visible === tab) this.show(null);
  }

  /// A new wire started (its first frame, `[4, 0]`): slots snapshotted on an older wire can no longer
  /// receive a `closed` for a tab closed in between.
  newWire(): void { this.wire++; }

  /// A `term-list` may drop an unlisted slot ONLY if that slot's last snapshot came from an OLDER wire.
  ///
  /// Never one snapshotted on the CURRENT wire: `term-list` rides `control` and the snapshots ride
  /// `terminal`, two streams with no order between them, so a list older than a tab's snapshot would
  /// dispose a live tab for good (no second snapshot follows). On the current wire only that wire's
  /// `closed` frame disposes a slot.
  ///
  /// Why an older wire's slot may go: a tab closed while that wire was down gets no `closed` frame on
  /// any wire — the new wire snapshots only the tabs still open — so without this its hidden instance
  /// would stay for the life of the page. Why it is safe: that slot's wire is gone, so nothing can reach
  /// it any more; and if the tab IS still open, its new wire's snapshot is already in flight and
  /// rebuilds the slot.
  retain(ids: Set<string>): void {
    for (const [id, s] of [...this.slots]) if (!ids.has(id) && s.wire < this.wire) this.close(id);
  }

  /// Show a tab. `reason` decides focus (term-view-policy.ts): a `user` switch takes it; anything else
  /// only hands on focus the terminal already held.
  show(tab: string | null, reason: VisibleChangeReason = "host"): void {
    const prev = this.visible !== null ? this.slots.get(this.visible) : undefined;
    if (this.activatePending) this.activatePending.tab = tab;   // the intent follows the active tab
    this.reveal(tab, reason, (!!prev && this.holdsFocus(prev.el)) || this.focusCarry);
  }

  /// This user just asked for a new tab (`open-terminal`, `new-tmux`, `open-tmux`): when THAT tab lands —
  /// shown by the host's term-list or by its first commit, in either order — it takes focus. Any other
  /// tab landing meanwhile leaves the expectation where it is (`isRequestedTab`).
  /// A second request for the SAME kind while one is pending adds to it: the last one to land focuses.
  expectOpenedTab(req: OpenRequest): void {
    const o = this.opened;
    if (o && "kind" in o.req && "kind" in req && o.req.kind === req.kind) { o.remaining++; return; }
    this.opened = { req, after: this.serial, remaining: 1, seen: new Set() };
  }

  /// The host refused a tmux tab (`tmux-error`): `session` names the session an `open-tmux` or a restore
  /// asked for, and is null only for a failed `new-tmux`. Only the expectation for THAT tab is void —
  /// a restore failing for another session leaves a pending `new-tmux` alone.
  cancelOpenedTmux(session: string | null): void {
    const r = this.opened?.req;
    if (!r) return;
    if ("id" in r ? session !== null && r.id === `tmux:${session}` : r.kind === "tmux" && session === null) this.cancelOne();
  }

  /// The host refused an `open-terminal` or a `reopen-terminal` (`term-error`: the tab cap, nothing closed to
  /// bring back): one pending new shell — or reopened tab — is not coming.
  cancelOpenedPty(): void {
    const r = this.opened?.req;
    if (r && "kind" in r && (r.kind === "pty" || r.kind === "any")) this.cancelOne();
  }

  private cancelOne(): void {
    if (this.opened && --this.opened.remaining <= 0) this.opened = null;
  }

  private reveal(tab: string | null, reason: VisibleChangeReason, terminalHadFocus: boolean): void {
    // A glide on the tab going out of sight stops there — it would otherwise scroll a hidden instance.
    if (this.visible !== tab) this.visibleView()?.smooth?.stop();
    this.visible = tab;
    for (const s of this.slots.values()) s.el.classList.toggle("is-hidden", s.id !== tab || !s.live);
    const v = this.visibleView();
    // The area's one canvas follows what is shown — AFTER the classes, so the instance claiming it measures
    // where it sits on screen (webgpu/surface.ts).
    if (v) v.claimCanvas?.(); else releaseCanvas(this.o.container);
    if (v) { v.term.refresh(0, v.term.rows - 1); this.fit(); }
    this.o.onVisibleChange(v, v ? tab : null);
    if (!v) { this.focusCarry = terminalHadFocus; return; }   // carried until a view is shown
    this.focusCarry = false;
    // Only a view of the intent's OWN tab resolves it (`activatePending`).
    const pending = this.activatePending;
    const activated = pending !== null && pending.tab === tab ? pending.shown : null;
    if (activated) this.activatePending = null;
    const slot = this.slots.get(tab!)!;
    // A new terminal whose first content came while the placeholder was still on screen: its fade is now.
    if (slot.fadeOnReveal) { slot.fadeOnReveal = false; this.fade(slot.el); }
    const o = this.opened;
    let userOpened = o !== null && !o.seen.has(slot.id) && isRequestedTab(o.req, slot.id, slot.serial > o.after);
    if (o && userOpened) {
      o.seen.add(slot.id);
      if (--o.remaining > 0) userOpened = false;            // another of this kind is still coming
      else this.opened = null;
    }
    const policy = this.o.focusPolicy?.(userOpened) ?? { driver: false, mayAutofocus: false };
    const otherHoldsFocus = this.otherHoldsFocus(userOpened);
    if (terminalTakesFocus({ reason, terminalHadFocus, userOpened, otherHoldsFocus, ...policy })
      || (activated !== null && terminalTakesFocus({ reason: "activate", terminalHadFocus: false, otherHoldsFocus, surfaceShown: activated(), ...policy }))) v.focus();
  }

  /// Something OUTSIDE the terminal holds focus (term-view-policy.ts, `elementHoldsFocus`).
  private otherHoldsFocus(userOpened = false): boolean {
    const c = contextFor(this.o.container);
    // Closing the embedded palette can leave focus on the page body while the requested tab starts.
    if (c && !c.input.focused()) return !userOpened || elementHoldsFocus(c.root.ownerDocument.activeElement);
    const a = activeWithin(this.o.container);
    return elementHoldsFocus(a) && !this.o.container.contains(a);
  }

  /// This client just became the driver: focus the visible terminal only if nothing else holds focus
  /// and `surfaceShown` (term-view-policy.ts, `activate`). With no visible VIEW yet the intent is
  /// REMEMBERED for the tab the deck shows now and decided when a view of the host's active tab is
  /// shown (`activatePending`: scoped to that tab, following it if the host moves on) — pass a
  /// function so the surface is read then, not now.
  activate(surfaceShown: boolean | (() => boolean)): void {
    const shown = typeof surfaceShown === "function" ? surfaceShown : () => surfaceShown;
    const v = this.visibleView();
    if (!v) { this.activatePending = { tab: this.visible, shown }; return; }
    this.activatePending = null;
    const otherHoldsFocus = this.otherHoldsFocus();
    const policy = this.o.focusPolicy?.() ?? { driver: false, mayAutofocus: false };
    if (terminalTakesFocus({ reason: "activate", terminalHadFocus: false, otherHoldsFocus, surfaceShown: shown(), ...policy })) v.focus();
  }

  /// A WINDOW that held the keys went and the host LANDED the person on the terminal (`SessionState.landing`):
  /// the visible tab takes them, as a switch hands focus on (`terminalTakesWindowKeys`); with no view shown
  /// yet they are carried to the next one shown. False when the terminal declines them.
  takeWindowKeys(typing: boolean): boolean {
    const policy = this.o.focusPolicy?.() ?? { driver: false, mayAutofocus: false };
    if (!terminalTakesWindowKeys({ typing, ...policy })) return false;
    const v = this.visibleView();
    if (v) v.focus();
    else this.focusCarry = true;
    return true;
  }

  /// This client went passive: a remembered `activate` is void, and EVERY TAB'S PICTURE GOES — each slot's
  /// instances are released (the slots stay: no fade when they come back), the area shows nothing and the canvas is
  /// cleared. Those pictures stopped the moment control left (the wire is the new driver's), and the claim overlay
  /// hid them; kept, they were what the overlay uncovered when control came back — this device's terminal as it
  /// last saw it, for as long as the host's snapshots took (since 2026-10-07 the host takes a resized tab's only once
  /// its program has redrawn: up to 150 ms; docs/terminal.md, "A claim says its grid"). Now each tab shows again at
  /// its first snapshot on the new wire. Outside the op chain, unlike `close`: a write queued for a released
  /// instance finds no view (`viewFor`), and one in flight still calls back.
  deactivate(): void {
    this.activatePending = null;
    for (const s of this.slots.values()) {
      for (const i of [s.live, s.pending, s.rebase]) if (i) this.release(i);
      s.live = s.pending = s.rebase = null;
    }
    this.reveal(this.visible, "host", false);
  }

  private holdsFocus(el: HTMLElement): boolean {
    const a = activeWithin(el);
    return !!a && a !== el.ownerDocument.body && el.contains(a);
  }

  /// Fit the visible instance and give EVERY live instance that grid; one `onFit`. With none visible,
  /// a throwaway instance in a throwaway slot is measured and disposed.
  ///
  /// `hold`: the grid is measured and REPORTED, and nothing is resized. The host answers a grid change by
  /// re-sending every tab at the new size (docs/terminal.md, "A RESIZE RE-SENDS EVERY TAB"), and each
  /// snapshot's commit takes the grid — so the person sees ONE layout, the host's, where a fit shows
  /// xterm.js's own reflow first and the host's ~30 ms later, wrapped differently (measured on an
  /// expand: 33 of 48 rows moved between the two). Whatever is still at the old grid after `FIT_HOLD_MS`
  /// is resized here — no snapshot is coming (a passive client, a dead channel). While a hold waits, a
  /// fit to the SAME grid changes nothing; one to another grid resizes as ever. Asked for by the end of a
  /// controlled window resize (`resize-settle.ts` — every fit it deferred) and by EVERY fit `#stage`'s size
  /// brings (`session.ts`: a soft keyboard, a rotation, an edge drag — which previewed until 2026-10-03).
  fit(opts: { hold?: boolean } = {}): void {
    if ((contextFor(this.o.container)?.resizeSettle ?? windowResizeSettle).defer(this, "fit", () => this.fit({ hold: true }))) return;
    let v: ReturnType<typeof mountMeasuringXterm> | null = this.visibleView();
    if(!v && this.mount===mountXterm){
      const dims=measureTerminalGrid(this.o.container,{fontSize:this.o.fontSize,theme:this.theme});
      if(!dims)return;
      this.grid=dims;this.clearHold();this.resizeLive();this.o.onFit(dims.cols,dims.rows);
      return;
    }
    let scratch: HTMLElement | null = null;
    if (!v) {
      scratch = document.createElement("div");
      scratch.className = "xterm-tab xterm-measure";
      const inst = document.createElement("div");
      inst.className = "xterm-inst";
      scratch.append(inst);
      this.o.container.append(scratch);
      v = (this.mount === mountXterm ? mountMeasuringXterm : this.mount)(inst, { fontSize: this.o.fontSize, theme: this.theme, onData: () => {}, onFit: () => {} });
    }
    // A container that cannot be measured (the terminal surface hidden behind the window surface on
    // a phone) leaves the grid as it is and reports NOTHING — the next fit, when the surface shows,
    // does it. Reporting the unchanged grid would tell the host a size nobody measured.
    const measureOnly = !scratch && (opts.hold === true || this.holdTimer !== null);
    let fitted = false, cols = 0, rows = 0;
    try {
      if (measureOnly) {
        const dims = v.measure();
        if (dims) { fitted = true; cols = dims.cols; rows = dims.rows; }
      } else {
        fitted = v.fit() !== false;
        cols = v.cols(); rows = v.rows();
      }
    } catch (e) {
      // A fit is called from activation and visibility callbacks; one that throws must not abort them.
      console.warn("[term] fit failed", e);
    } finally {
      if (scratch) { v.dispose(); scratch.remove(); }   // never left behind, whatever the fit did
    }
    if (!fitted || cols <= 0 || rows <= 0) return;
    const changed = !this.grid || this.grid.cols !== cols || this.grid.rows !== rows;
    this.grid = { cols, rows };
    if (measureOnly && (changed ? opts.hold === true : this.holdTimer !== null)) {
      if (changed) {
        this.clearHold();
        this.holdTimer = setTimeout(() => { this.holdTimer = null; this.resizeLive(); }, FIT_HOLD_MS);
        if (this.o.holdShift?.()) this.shiftHeld(rows);
      }
    } else {
      this.clearHold();
      this.resizeLive();
    }
    this.o.onFit(cols, rows);
  }

  /// A HOLD is waiting for snapshots at exactly this grid: a snapshot of it answers the hold, and its commit
  /// waits for the program's redraw (`snapshot-settle.ts`).
  holdingFor(cols: number, rows: number): boolean {
    return this.holdTimer !== null && this.grid?.cols === cols && this.grid?.rows === rows;
  }

  /// A HOLD is waiting for the host's snapshots at a new grid.
  holding(): boolean { return this.holdTimer !== null; }

  /// **THE AREA CHANGED SIZE AND ITS FIT HAS NOT COME YET** (session.ts's `#stage` observer, ahead of its 100 ms
  /// debounce — a soft keyboard, a rotation; only where `holdShift` says so): every live instance's picture moves NOW, in
  /// the frame the area changed, to where the host's resize will put it (hold-shift.ts). Nothing is resized or
  /// reported — the fit that follows does that, and holds. Waiting for that fit left the old grid top-aligned and
  /// clipped for its debounce, then moved it: the prompt under the keyboard, then a jump.
  follow(): void {
    if (!this.o.holdShift?.()) return;
    const v = this.visibleView();
    const dims = v?.measure();
    if (dims) this.shiftHeld(dims.rows);
  }

  /// Every live instance's picture where the host's resize from its grid to `rowsNew` rows will put it: a prompt at
  /// the bottom stays at the bottom (`holdShiftRows`). Scrolled back into the scrollback, it stays put — the
  /// snapshot lands at the bottom whatever is shown.
  private shiftHeld(rowsNew: number): void {
    for (const s of this.slots.values()) {
      const view = s.live?.view;
      if (!view) continue;
      const b = view.term.buffer.active;
      let drawnBelow = false;
      for (let y = b.cursorY + 1; y < view.rows() && !drawnBelow; y++) {
        drawnBelow = (b.getLine(b.viewportY + y)?.translateToString(true).trim() ?? "") !== "";
      }
      view.holdShift(b.viewportY < b.baseY ? 0 : holdShiftRows({
        rowsOld: view.rows(), rowsNew, cursorY: b.cursorY, scrollback: b.baseY, drawnBelow,
        alt: view.isAltScreen(), tmux: s.id.startsWith("tmux:"),
      }));
    }
  }

  /// Every live instance not yet at the grid takes it — and its picture goes back where its own rows put it.
  private resizeLive(): void {
    const g = this.grid;
    if (!g) return;
    for (const s of this.slots.values()) {
      const view = s.live?.view;
      if (!view) continue;
      if (view.cols() !== g.cols || view.rows() !== g.rows) view.resizeTo(g.cols, g.rows);
      view.holdShift(0);
    }
  }

  private clearHold(): void {
    if (this.holdTimer !== null) clearTimeout(this.holdTimer);
    this.holdTimer = null;
  }

  visibleId(): string | null { return this.visible; }
  visibleView(): XtermView | null { return this.visible ? this.liveView(this.visible) : null; }
  liveView(tab: string): XtermView | null { return this.slots.get(tab)?.live?.view ?? null; }
  ids(): string[] { return [...this.slots.keys()]; }

  setFontSize(size: number): void {
    this.o.fontSize = size;
    for (const s of this.slots.values()) for (const i of [s.live, s.pending, s.rebase]) {
      if (i) i.view.term.options.fontSize = size;
    }
    this.fit();
  }

  /// The renderer every instance mounted from now on draws with (xterm-view.ts). Instances already up keep
  /// theirs: a tab moves over at its next snapshot (session.ts asks the host for one of every tab).
  setRenderer(kind: "dom" | "webgpu"): void { this.o.renderer = kind; }

  /// **AN AGENT'S TAB HAS NO TRAILING BLANK LINES** (trailing-blanks.ts): the tabs an agent runs in, from the host's
  /// `term-list` (session.ts). Every instance of theirs — live, pending, a rebuild, and each mounted later — ends its
  /// view at its last line of content; every other tab's is as it was.
  setAgentTabs(ids: ReadonlySet<string>): void {
    this.agentTabs = ids;
    for (const s of this.slots.values()) for (const i of [s.live, s.pending, s.rebase]) i?.view.hideTrailingBlanks(ids.has(s.id));
  }

  setSmoothScroll(on: boolean): void {
    this.smoothScroll = on;
    for (const s of this.slots.values()) for (const i of [s.live, s.pending, s.rebase]) i?.view.setSmoothScroll(on);
  }

  setTheme(t: Theme): void {
    this.theme = t;
    for (const s of this.slots.values()) for (const i of [s.live, s.pending, s.rebase]) i?.view.setTheme(t);
  }

  onSelectionChange(cb: () => void): void { this.selectionListeners.push(cb); }

  /// The session is over (`session.ts`): every instance, pending or live, is disposed and its element
  /// removed, and nothing the deck was told to remember survives. SILENT — no `onVisibleChange`, since
  /// nobody is left to tell.
  dispose(): void {
    (contextFor(this.o.container)?.resizeSettle ?? windowResizeSettle).cancel(this);
    this.clearHold();
    for (const s of this.slots.values()) {
      for (const i of [s.live, s.pending, s.rebase]) if (i) this.release(i);
      this.stopWatching(s);
      s.el.remove();
    }
    this.slots.clear();
    this.visible = null;
    this.opened = null;
    this.activatePending = null;
    this.selectionListeners.length = 0;
  }

  private slotFor(tab: string): Slot {
    let s = this.slots.get(tab);
    if (!s) {
      const el = document.createElement("div");
      el.className = "xterm-tab is-hidden";
      el.dataset.tab = tab;
      el.dataset.awaitingContent = "";
      this.o.container.append(el);
      const o = this.opened;
      const isNew = !!o && "kind" in o.req && o.req.kind !== "any" && isRequestedTab(o.req, tab, true);
      s = { id: tab, el, live: null, pending: null, wire: this.wire, serial: ++this.serial, shown: false, isNew };
      this.slots.set(tab, s);
    }
    return s;
  }

  /// **A TAB'S FIRST CONTENT FADES IN** (2026-10-03; docs/client-web.md, "A tab's first content fades in"): a
  /// new slot is TRANSPARENT (`data-awaiting-content`) until its live instance holds something to see — a
  /// snapshot with text, or, after a new shell's empty one, its first output (the prompt) — and then fades
  /// in, ONCE per slot: every later snapshot (a resize, a resume, a new wire) swaps in with no fade. Shown when
  /// it arrives: the fade (`.is-fading-in`). Hidden: it is simply there when switched to — a tab switch never
  /// fades. Its background is `#stage`'s own colour, so only the text fades. `FIRST_CONTENT_MAX_MS` after the
  /// first commit it is shown with whatever it has. Re-armed by each commit while waiting: the next instance
  /// is the one that will print.
  private watchFirstContent(s: Slot): void {
    const inst = s.live;
    if (!inst) return;
    s.contentWatch?.dispose();
    s.contentWatch = undefined;
    if (hasVisibleContent(inst.view.term)) { this.firstContent(s); return; }
    s.contentWatch = inst.view.term.onWriteParsed(() => {
      if (s.live === inst && hasVisibleContent(inst.view.term)) this.firstContent(s);
    });
    s.contentTimer ??= setTimeout(() => this.firstContent(s), FIRST_CONTENT_MAX_MS);
  }

  /// Call `cb` once tab `id` has its FIRST CONTENT — something to see, or `FIRST_CONTENT_MAX_MS` after its first
  /// commit (`watchFirstContent`) — at once if it already has; a tab that has no slot yet is waited for. Returns
  /// the cancel. (Local Mac mode opens a terminal onto its first content in one step: session.ts `openTerminal`.)
  whenContent(id: string, cb: () => void): () => void {
    if (this.slots.get(id)?.shown) { cb(); return () => {}; }
    let set = this.contentWaiters.get(id);
    if (!set) { set = new Set(); this.contentWaiters.set(id, set); }
    set.add(cb);
    return () => {
      set.delete(cb);
      if (!set.size && this.contentWaiters.get(id) === set) this.contentWaiters.delete(id);
    };
  }

  private firstContent(s: Slot): void {
    if (s.shown || this.slots.get(s.id) !== s) return;
    s.shown = true;
    this.stopWatching(s);
    delete s.el.dataset.awaitingContent;
    if (this.o.fadeIn !== "new" || s.isNew) {
      if (this.visible === s.id) this.fade(s.el);
      // A NEW terminal shown a moment later (the host's list naming it after its content): it fades then.
      else if (s.isNew) s.fadeOnReveal = true;
    }
    // AFTER the fade's decision: a waiter that shows the tab now shows it whole, never fading.
    const waiting = this.contentWaiters.get(s.id);
    if (waiting) { this.contentWaiters.delete(s.id); for (const cb of waiting) cb(); }
  }

  private fade(el: HTMLElement): void {
    el.classList.add("is-fading-in");
    // Its OWN animation's end: one inside it (the cursor's blink) bubbles here too. With motion reduced
    // there is no animation, so a timer takes the class away as well.
    const end = (e?: AnimationEvent) => {
      if (e && e.target !== el) return;
      el.classList.remove("is-fading-in");
      el.removeEventListener("animationend", end);
      el.removeEventListener("animationcancel", end);
    };
    el.addEventListener("animationend", end);
    el.addEventListener("animationcancel", end);
    setTimeout(() => end(), 2000);
  }

  private stopWatching(s: Slot): void {
    s.contentWatch?.dispose();
    s.contentWatch = undefined;
    if (s.contentTimer !== undefined) clearTimeout(s.contentTimer);
    s.contentTimer = undefined;
  }

  private release(i: Instance): void {
    i.view.dispose();
    i.el.remove();
  }
}
