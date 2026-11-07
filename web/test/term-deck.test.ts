import { afterEach, describe, expect, it, vi } from "vitest";
import { FIRST_CONTENT_MAX_MS, FIT_HOLD_MS, TermDeck, hasVisibleContent } from "../src/client/term-deck";
import type { XtermView, XtermViewOpts } from "../src/client/xterm-view";

/// What the terminal area fits — ONE area, shared by every instance, as in the page.
const area = { cols: 100, rows: 30 };

class FakeView {
  c = 80; r = 24; disposed = false; written = ""; focused = 0;
  /// Disposed while its textarea still HELD focus: removing it sends focus to <body> on the way.
  disposedHoldingFocus = false;
  /// Stands in for xterm's helper textarea, so focus is REAL DOM focus the tests can observe.
  readonly ta = document.createElement("textarea");
  constructor(readonly el: HTMLElement, readonly opts: XtermViewOpts) { el.append(this.ta); this.term.element = el; }
  readonly bells: (() => void)[] = [];
  /// What the instance's screen shows, a line per row (`print`), and who hears a write parsed.
  screen: string[] = [];
  readonly parsed = new Set<() => void>();
  term = { rows: 24, element: null as HTMLElement | null, refresh: () => {}, onSelectionChange: (_cb: () => void) => ({ dispose() {} }),
           onBell: (cb: () => void) => { this.bells.push(cb); return { dispose() {} }; },
           onWriteParsed: (cb: () => void) => { this.parsed.add(cb); return { dispose: () => { this.parsed.delete(cb); } }; },
           buffer: { active: { viewportY: 0, baseY: 0, cursorY: 23, getLine: (y: number) => ({ translateToString: () => this.screen[y] ?? "" }) } } };
  /// Every picture move a held resize asked of it (`holdShift`), and the one standing.
  shifts: number[] = [];
  holdShift(rows: number) { this.shifts.push(rows); }
  get shift() { return this.shifts.at(-1) ?? 0; }
  /// Output reached this instance's screen (`text` on its first row, or a blank write with none).
  print(text: string) { this.screen[0] = text; for (const cb of [...this.parsed]) cb(); }
  /// The program in this instance's tab printed a BEL.
  ring() { for (const cb of this.bells) cb(); }
  cols() { return this.c; } rows() { return this.r; }
  resizeTo(c: number, r: number) { this.c = c; this.r = r; this.term.rows = r; }
  fit() { this.resizeTo(area.cols, area.rows); }
  measure() { return { ...area }; }
  write() {} writeAsync(t: string) { this.written += t; return Promise.resolve(); }
  focus() { this.focused++; this.ta.focus(); }
  dispose() { this.disposedHoldingFocus = document.activeElement === this.ta; this.disposed = true; this.ta.remove(); }
  isAltScreen() { return false; } appCursor() { return false; } setTheme() {}
  cursor() { return { row: 0, col: 0 }; } cellAt() { return " "; }
  smoothSet: boolean[] = [];
  setSmoothScroll(on: boolean) { this.smoothSet.push(on); }
  /// Whether its trailing blank lines are taken as not there (`hideTrailingBlanks`) — the last word it was given.
  tailHidden = false;
  hideTrailingBlanks(on: boolean) { this.tailHidden = on; }
  hiddenRows() { return 0; }
  smooth = { stops: 0, stop() { this.stops++; } };
}

function deck(o: { driver?: boolean; softKeyboard?: boolean; smoothScroll?: boolean; fadeIn?: "always" | "new"; holdShift?: boolean } = {}) {
  const made: FakeView[] = [];
  const data: [string, string][] = [];
  const replies: [string, string][] = [];
  const fits: [number, number][] = [];
  const visible: (string | null)[] = [];
  const rang: string[] = [];
  const container = document.createElement("div");
  document.body.append(container);                                         // focus needs a connected tree
  const d = new TermDeck({
    container, fontSize: 14, theme: "dark", smoothScroll: o.smoothScroll ?? false, fadeIn: o.fadeIn,
    holdShift: () => o.holdShift ?? false,
    focusPolicy: () => ({ driver: o.driver ?? true, mayAutofocus: true, softKeyboard: o.softKeyboard ?? false }),
    onData: (tab, s) => data.push([tab, s]),
    onReply: (tab, s) => replies.push([tab, s]),
    onFit: (c, r) => fits.push([c, r]),
    onVisibleChange: (_v, tab) => visible.push(tab),
    onBell: (tab) => rang.push(tab),
    mount: (el, opts) => { const v = new FakeView(el, opts); made.push(v); return v as unknown as XtermView; },
  });
  return { d, made, data, replies, fits, visible, rang, container };
}

// Every deck mounts into document.body (focus needs a connected tree); a test must not inherit the
// last one's focused textarea as "something else holding focus".
afterEach(() => { (document.activeElement as HTMLElement | null)?.blur?.(); document.body.replaceChildren(); area.cols = 100; area.rows = 30; });

describe("a tab's first content fades in", () => {
  const slot = (container: HTMLElement, tab: string) => container.querySelector<HTMLElement>(`.xterm-tab[data-tab="${tab}"]`)!;
  const snapshot = (d: TermDeck, made: FakeView[], tab: string, gen: number, text: string) => {
    d.begin(tab, 80, 24, gen);
    made.at(-1)!.screen = text ? [text] : [];
    d.commit(tab, gen);
  };
  afterEach(() => { vi.useRealTimers(); });

  it("a snapshot with text: shown at its commit with ONE fade; a later snapshot swaps in with none", () => {
    const { d, made, container } = deck();
    d.show("pty:1");
    const s = slot(container, "pty:1") ?? (d.begin("pty:1", 80, 24, 0), slot(container, "pty:1"));
    snapshot(d, made, "pty:1", 1, "you@mac ~ % ");
    expect(s.hasAttribute("data-awaiting-content")).toBe(false);
    expect(s.classList.contains("is-fading-in")).toBe(true);
    s.dispatchEvent(new Event("animationend"));
    expect(s.classList.contains("is-fading-in")).toBe(false);
    snapshot(d, made, "pty:1", 2, "you@mac ~ % ls");                                  // a resize, a resume
    expect(s.classList.contains("is-fading-in")).toBe(false);
  });

  it("a new shell's EMPTY snapshot stays transparent until its first output with text, which fades it in", () => {
    const { d, made, container } = deck();
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "");
    const s = slot(container, "pty:1");
    expect(s.hasAttribute("data-awaiting-content")).toBe(true);
    made.at(-1)!.print("   ");                                                        // blank: nothing to see yet
    expect(s.hasAttribute("data-awaiting-content")).toBe(true);
    made.at(-1)!.print("you@mac ~ % ");
    expect(s.hasAttribute("data-awaiting-content")).toBe(false);
    expect(s.classList.contains("is-fading-in")).toBe(true);
  });

  it("the next instance is the one watched: a second empty snapshot, then its own output", () => {
    const { d, made, container } = deck();
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "");
    const first = made.at(-1)!;
    snapshot(d, made, "pty:1", 2, "");
    first.print("stale");                                                             // a released instance says nothing
    expect(slot(container, "pty:1").hasAttribute("data-awaiting-content")).toBe(true);
    made.at(-1)!.print("you@mac ~ % ");
    expect(slot(container, "pty:1").hasAttribute("data-awaiting-content")).toBe(false);
  });

  it("content that arrives in a HIDDEN tab shows it with no fade, and switching to it later fades nothing", () => {
    const { d, made, container } = deck();
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "one");
    snapshot(d, made, "pty:2", 2, "two");
    const s = slot(container, "pty:2");
    expect(s.hasAttribute("data-awaiting-content")).toBe(false);
    expect(s.classList.contains("is-fading-in")).toBe(false);
    d.show("pty:2", "user");
    expect(s.classList.contains("is-fading-in")).toBe(false);
  });

  it("fadeIn \"new\" (This Mac): another tab's first content APPEARS; a NEW terminal this client asked for fades", () => {
    const { d, made, container } = deck({ fadeIn: "new" });
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "");                                  // a tab restored at launch, say
    made.at(-1)!.print("you@mac ~ % ");
    expect(slot(container, "pty:1").hasAttribute("data-awaiting-content")).toBe(false);
    expect(slot(container, "pty:1").classList.contains("is-fading-in"), "it appears").toBe(false);
    d.expectOpenedTab({ kind: "pty", known: new Set(["pty:1"]) });      // New terminal
    d.show("pty:2", "user");
    snapshot(d, made, "pty:2", 2, "you@mac ~ % ");
    expect(slot(container, "pty:2").classList.contains("is-fading-in"), "the new one fades").toBe(true);
  });

  it("a NEW terminal whose content came while hidden fades the first time it is shown — and only then", () => {
    const { d, made, container } = deck({ fadeIn: "new" });
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "one");
    d.expectOpenedTab({ kind: "pty", known: new Set(["pty:1"]) });
    snapshot(d, made, "pty:2", 2, "you@mac ~ % ");                     // its content before the host's list names it
    expect(slot(container, "pty:2").classList.contains("is-fading-in")).toBe(false);
    d.show("pty:2", "user");                                            // named: shown now
    const s = slot(container, "pty:2");
    expect(s.classList.contains("is-fading-in")).toBe(true);
    s.dispatchEvent(new Event("animationend"));
    d.show("pty:1", "user");
    d.show("pty:2", "user");
    expect(s.classList.contains("is-fading-in"), "a later switch fades nothing").toBe(false);
  });

  it("an EXISTING tmux session opened (an id, not a kind) is not new: it appears", () => {
    const { d, made, container } = deck({ fadeIn: "new" });
    d.expectOpenedTab({ id: "tmux:$5" });
    d.show("tmux:$5", "user");
    snapshot(d, made, "tmux:$5", 1, "work");
    expect(slot(container, "tmux:$5").classList.contains("is-fading-in")).toBe(false);
  });

  it("whenContent: called when a tab that has no slot yet gets its first content — hidden, so showing it then fades nothing", () => {
    const { d, made, container } = deck();
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "one");
    const calls: string[] = [];
    d.whenContent("pty:2", () => { calls.push("pty:2"); d.show("pty:2", "user"); });  // as a local open lands
    snapshot(d, made, "pty:2", 2, "");                                                 // a new shell's empty snapshot
    expect(calls).toEqual([]);
    made.at(-1)!.print("you@mac ~ % ");
    expect(calls).toEqual(["pty:2"]);
    expect(slot(container, "pty:2").classList.contains("is-fading-in"), "it arrived whole").toBe(false);
  });

  it("whenContent: at once for a tab that already has it; a cancelled one is never called", () => {
    const { d, made } = deck();
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "one");
    let now = 0, later = 0;
    d.whenContent("pty:1", () => { now++; });
    expect(now).toBe(1);
    const cancel = d.whenContent("pty:3", () => { later++; });
    cancel();
    snapshot(d, made, "pty:3", 3, "three");
    expect(later).toBe(0);
  });

  it("a tab that prints nothing is shown after FIRST_CONTENT_MAX_MS", () => {
    vi.useFakeTimers();
    const { d, made, container } = deck();
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "");
    vi.advanceTimersByTime(FIRST_CONTENT_MAX_MS - 1);
    expect(slot(container, "pty:1").hasAttribute("data-awaiting-content")).toBe(true);
    vi.advanceTimersByTime(1);
    expect(slot(container, "pty:1").hasAttribute("data-awaiting-content")).toBe(false);
  });

  it("an animation INSIDE the tab (the cursor's blink) does not end its fade; reduced motion's none ends on a timer", () => {
    vi.useFakeTimers();
    const { d, made, container } = deck();
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "text");
    const s = slot(container, "pty:1");
    made.at(-1)!.el.dispatchEvent(new Event("animationend", { bubbles: true }));
    expect(s.classList.contains("is-fading-in")).toBe(true);
    vi.advanceTimersByTime(2000);
    expect(s.classList.contains("is-fading-in")).toBe(false);
  });

  it("a tab closed while it waits leaves nothing waiting", () => {
    vi.useFakeTimers();
    const { d, made } = deck();
    d.show("pty:1");
    snapshot(d, made, "pty:1", 1, "");
    const v = made.at(-1)!;
    d.close("pty:1");
    expect(v.parsed.size).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("hasVisibleContent reads the screen for a character that is not blank", () => {
    const term = (lines: string[]) => ({ rows: 3, buffer: { active: { viewportY: 0, getLine: (y: number) => ({ translateToString: () => lines[y] ?? "" }) } } });
    expect(hasVisibleContent(term(["", "  ", ""]) as never)).toBe(false);
    expect(hasVisibleContent(term(["", "", "$ "]) as never)).toBe(true);
  });
});

describe("TermDeck", () => {
  // Terminal Settings → WebGPU rendering: a tab moves over at its next snapshot, which mounts a fresh
  // instance — so the setting must reach the NEXT mount and leave the instances already up alone.
  it("a renderer change reaches the next instance mounted, not the ones already up", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    expect(made.at(-1)!.opts.renderer, "what the deck was made with (none: the DOM renderer)").toBeUndefined();
    d.setRenderer("webgpu");
    const before = made.length;
    d.begin("pty:1", 80, 24, 2);
    expect(made.length).toBe(before + 1);
    expect(made.at(-1)!.opts.renderer).toBe("webgpu");
    d.setRenderer("dom");
    d.begin("pty:2", 80, 24, 3);
    expect(made.at(-1)!.opts.renderer).toBe("dom");
  });

  it("a bell from any tab's CURRENT instance is reported with its tab — shown or hidden, live or pending", () => {
    const { d, made, rang } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    const shown = made.at(-1)!;
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    const hidden = made.at(-1)!;
    shown.ring();
    hidden.ring();
    d.begin("pty:2", 80, 24, 3);                              // a re-snapshot: output after its end can reach it
    const pending = made.at(-1)!;
    pending.ring();
    expect(rang).toEqual(["pty:1", "pty:2", "pty:2"]);
  });

  it("a superseded or closed instance rings nothing", () => {
    const { d, made, rang } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    const old = made.at(-1)!;
    d.begin("pty:1", 80, 24, 2); d.commit("pty:1", 2);
    old.ring();
    const live = made.at(-1)!;
    d.close("pty:1");
    live.ring();
    expect(rang).toEqual([]);
  });

  it("a snapshot builds a PENDING instance at the snapshot's size, invisible until committed", () => {
    const { d, made } = deck();
    d.begin("pty:1", 70, 20, 1);
    const v = made.at(-1)!;
    expect([v.c, v.r]).toEqual([70, 20]);
    expect(d.viewFor("pty:1", 1)).toBe(v as unknown as XtermView);
    expect(v.el.classList.contains("is-pending")).toBe(true);
    expect(d.liveView("pty:1")).toBeNull();
    d.commit("pty:1", 1);
    expect(v.el.classList.contains("is-pending")).toBe(false);
    expect(d.liveView("pty:1")).toBe(v as unknown as XtermView);
  });

  it("a tmux tab's instance counts widths as tmux does, a pty tab's as SwiftTerm does", () => {
    const { d, made } = deck();
    d.begin("tmux:$3", 80, 24, 1);
    expect(made.at(-1)!.opts.widths).toBe("tmux");
    d.begin("pty:1", 80, 24, 2);
    expect(made.at(-1)!.opts.widths).toBe("pty");
  });

  it("a re-snapshot swaps instances without disposing the live one early", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    const old = made.at(-1)!;
    d.begin("pty:1", 80, 24, 2);
    expect(old.disposed).toBe(false);
    expect(d.visibleView()).toBe(old as unknown as XtermView);
    d.commit("pty:1", 2);
    expect(old.disposed).toBe(true);
    expect(d.visibleView()).toBe(made.at(-1) as unknown as XtermView);
  });

  it("a stale generation's commit is ignored", () => {
    const { d } = deck();
    d.begin("pty:1", 80, 24, 1); d.begin("pty:1", 80, 24, 2);
    d.commit("pty:1", 1);
    expect(d.liveView("pty:1")).toBeNull();
  });

  it("a switch shows another instance, fits it and reports ONE grid", () => {
    const { d, fits, visible } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    d.show("pty:2");
    expect(d.visibleId()).toBe("pty:2");
    expect(visible.at(-1)).toBe("pty:2");
    expect(fits.at(-1)).toEqual([100, 30]);
    expect(d.liveView("pty:1")!.cols()).toBe(100);                          // every instance shares the grid
    const slots = [...(d as unknown as { slots: Map<string, { el: HTMLElement }> }).slots.values()];
    expect(slots.map((s) => s.el.classList.contains("is-hidden"))).toEqual([true, false]);
  });

  it("only the visible live instance's TYPING reaches the sink, named with its tab", () => {
    const { d, made, data } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    const one = made.at(-1)!;
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    const two = made.at(-1)!;
    d.show("pty:2");
    one.opts.onData("\x1b[O");                                               // a hidden instance's focus-out report
    two.opts.onData("ls\r");
    expect(data).toEqual([["pty:2", "ls\r"]]);
  });

  // N1 (2026-09-27): the host leaves EVERY query that reached this client to it, because it cannot know
  // which tab the client shows — a switch in flight, a host-opened tab before its term-list. So a HIDDEN
  // instance answers its own tab's query, and the reply names THAT tab (a `term-reply`, not a keystroke).
  it("a hidden tab's instance answers its own tab's query, as a reply naming that tab", () => {
    const { d, made, data, replies } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    const one = made.at(-1)!;
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    const two = made.at(-1)!;
    d.show("pty:2");
    one.opts.onReply!("\x1b[0n");
    two.opts.onReply!("\x1b[?1;2c");
    expect(replies).toEqual([["pty:1", "\x1b[0n"], ["pty:2", "\x1b[?1;2c"]]);
    expect(data).toEqual([]);
  });

  // Final review I1(c): output right after a snapshot's end can be merged into the drain queued BEFORE
  // the commit, so it is parsed by the still-PENDING instance. The host counted those bytes as reaching
  // this client and stays silent, so a device query in them must be answered from here.
  it("a PENDING instance answers a query in the bytes written into it, visible tab or not", () => {
    const { d, made, replies } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    d.begin("pty:1", 80, 24, 3);
    made.at(-1)!.opts.onReply!("\x1b[0n");
    d.begin("pty:2", 80, 24, 4);
    made.at(-1)!.opts.onReply!("\x1b[1;1R");
    expect(replies).toEqual([["pty:1", "\x1b[0n"], ["pty:2", "\x1b[1;1R"]]);
  });

  it("a superseded or closed instance never answers — each byte is parsed by exactly one instance", () => {
    const { d, made, replies } = deck();
    d.begin("pty:2", 80, 24, 4);
    const superseded = made.at(-1)!;
    d.begin("pty:2", 80, 24, 5);
    superseded.opts.onReply!("\x1b[0n");                                    // disposed: nothing reaches it
    d.commit("pty:2", 5);
    const live = made.at(-1)!;
    d.close("pty:2");
    live.opts.onReply!("\x1b[0n");
    expect(replies).toEqual([]);
  });

  it("a snapshot for a hidden tab never reveals it", () => {
    const { d, visible } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    const before = visible.length;
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    expect(d.visibleId()).toBe("pty:1");
    expect(visible.length).toBe(before);
  });

  it("showing a tab before its first snapshot reveals it on commit", () => {
    const { d, visible } = deck();
    d.show("pty:3");
    expect(d.visibleView()).toBeNull();
    d.begin("pty:3", 80, 24, 1); d.commit("pty:3", 1);
    expect(d.visibleView()).not.toBeNull();
    expect(visible.at(-1)).toBe("pty:3");
  });

  it("close disposes both instances and, when visible, reports none", () => {
    const { d, made, visible } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    d.begin("pty:1", 80, 24, 2);
    d.close("pty:1");
    expect(made.slice(-2).every((v) => v.disposed)).toBe(true);
    expect(d.ids()).toEqual([]);
    expect(visible.at(-1)).toBeNull();
  });

  it("retain drops a tab the host no longer lists once a NEW WIRE has not snapshotted it", () => {
    const { d } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    d.newWire();                                                            // pty:1 closed while disconnected
    d.begin("pty:2", 80, 24, 3); d.commit("pty:2", 3);
    d.retain(new Set(["pty:2"]));
    expect(d.ids()).toEqual(["pty:2"]);
  });

  // Review I1: `term-list` rides `control`, the snapshots ride `terminal` — two SCTP streams with no
  // order between them. A list built before a tab opened, arriving after its snapshot committed, closed
  // that tab's slot for good: no second snapshot follows, so every byte after it was dropped.
  it("a term-list OLDER than a tab's snapshot never disposes it — only the wire's `closed` does", () => {
    const { d } = deck();
    d.newWire();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    d.retain(new Set(["pty:1"]));                                           // stale: predates pty:2
    expect(d.ids()).toEqual(["pty:1", "pty:2"]);
    expect(d.liveView("pty:2")).not.toBeNull();
    d.begin("pty:3", 80, 24, 3);                                            // mid-snapshot, not yet committed
    d.retain(new Set(["pty:1"]));
    expect(d.ids()).toContain("pty:3");
    d.close("pty:2");
    expect(d.ids()).toEqual(["pty:1", "pty:3"]);
  });

  // Review C1: a commit (resume, reconnect, re-snapshot) must never move DOM focus.
  it("a commit of the visible tab leaves focus in a remote window's input where it is", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1", "user");
    const win = document.createElement("div");
    win.className = "source-window";
    const input = document.createElement("input");
    win.append(input); document.body.append(win);
    input.focus();
    expect(document.activeElement).toBe(input);
    d.begin("pty:1", 80, 24, 2); d.commit("pty:1", 2);                     // the resume's re-snapshot
    expect(document.activeElement).toBe(input);
    expect(made.at(-1)!.focused).toBe(0);
    win.remove();
  });

  it("a commit hands focus on when the replaced instance held it", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1", "user");
    expect(document.activeElement).toBe(made.at(-1)!.ta);
    d.begin("pty:1", 80, 24, 2); d.commit("pty:1", 2);
    expect(document.activeElement).toBe(made.at(-1)!.ta);
  });

  // A resize re-sends the visible tab (docs/terminal.md, "A RESIZE RE-SENDS EVERY TAB"), so on a phone
  // this commit follows every keyboard opening. Focus must go from the old instance to the new one while
  // BOTH are in the page — as a tab switch hands it on — never through <body>: iOS drops the soft
  // keyboard when the focused element is removed.
  it("a commit hands focus on BEFORE the replaced instance goes, on a touch device too", () => {
    for (const softKeyboard of [false, true]) {
      const { d, made } = deck({ softKeyboard });
      d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1", "user");
      made.at(-1)!.focus();                                                 // a tap on the terminal
      const old = made.at(-1)!;
      d.begin("pty:1", 80, 24, 2); d.commit("pty:1", 2);
      expect(old.disposed).toBe(true);
      expect(old.disposedHoldingFocus, `softKeyboard ${softKeyboard}`).toBe(false);
      expect(document.activeElement).toBe(made.at(-1)!.ta);
      document.body.replaceChildren();
    }
  });

  it("a host-driven show takes no focus it did not hold; a user switch does; a passive client never", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    const one = made[0]!, two = made[1]!;
    d.show("pty:1");                                                        // host, nothing focused
    expect(one!.focused).toBe(0);
    d.show("pty:2", "user");
    expect(document.activeElement).toBe(two!.ta);
    d.show("pty:1");                                                        // host, the terminal held focus
    expect(document.activeElement).toBe(one!.ta);
    const passive = deck({ driver: false });
    passive.d.begin("pty:1", 80, 24, 1); passive.d.commit("pty:1", 1); passive.d.show("pty:1", "user");
    expect(passive.made.at(-1)!.focused).toBe(0);
  });

  it("fit with no tab measures a throwaway instance, so the host learns the grid before any tab exists", () => {
    const { d, fits, made, container } = deck();
    d.fit();
    expect(fits).toEqual([[100, 30]]);
    expect(made.length).toBe(1);
    expect(made[0]!.disposed).toBe(true);
    expect(container.children.length).toBe(0);                             // nothing left behind
  });

  // A HOLD reports the new grid and resizes nothing: the host re-sends every tab at it, and each snapshot's
  // commit takes the grid — ONE layout, the host's, instead of xterm.js's reflow and then the host's.
  describe("a hold", () => {
    afterEach(() => { vi.useRealTimers(); });
    const twoTabs = (o: { holdShift?: boolean } = { holdShift: true }) => {
      const k = deck(o);
      k.d.begin("pty:1", 80, 24, 1); k.d.commit("pty:1", 1);
      k.d.begin("pty:2", 80, 24, 2); k.d.commit("pty:2", 2); k.d.show("pty:1");
      const [one, two] = [k.made.at(-2)!, k.made.at(-1)!];
      one.c = 120; one.r = 40; two.c = 120; two.r = 40;
      k.fits.length = 0;
      return { ...k, one, two };
    };

    it("reports the new grid and resizes no instance; each snapshot's commit takes it", () => {
      vi.useFakeTimers();
      const { d, fits, made, one, two } = twoTabs();
      area.cols = 90; area.rows = 28;
      d.fit({ hold: true });
      expect(fits).toEqual([[90, 28]]);
      expect([one.c, one.r, two.c, two.r]).toEqual([120, 40, 120, 40]);
      d.begin("pty:1", 90, 28, 3); d.commit("pty:1", 3);
      expect([made.at(-1)!.c, made.at(-1)!.r]).toEqual([90, 28]);
      expect([two.c, two.r], "the hidden tab still waits for ITS snapshot").toEqual([120, 40]);
    });

    it("resizes whatever its snapshot missed once the hold runs out", () => {
      vi.useFakeTimers();
      const { d, one, two } = twoTabs();
      area.cols = 90; area.rows = 28;
      d.fit({ hold: true });
      vi.advanceTimersByTime(FIT_HOLD_MS - 1);
      expect([one.c, two.c]).toEqual([120, 120]);
      vi.advanceTimersByTime(1);
      expect([one.c, one.r, two.c, two.r]).toEqual([90, 28, 90, 28]);
    });

    it("a fit to the same grid while it waits previews nothing; one to another grid resizes as ever", () => {
      vi.useFakeTimers();
      const { d, fits, one, two } = twoTabs();
      area.cols = 90; area.rows = 28;
      d.fit({ hold: true });
      d.fit();
      expect([one.c, two.c], "a tab switch or a late observer must not bring the preview back").toEqual([120, 120]);
      expect(fits).toEqual([[90, 28], [90, 28]]);
      area.cols = 70; area.rows = 20;
      d.fit();
      expect([one.c, one.r, two.c, two.r]).toEqual([70, 20, 70, 20]);
      vi.advanceTimersByTime(FIT_HOLD_MS);
      expect([one.c, two.c], "the abandoned hold resizes nothing later").toEqual([70, 70]);
    });

    it("a hold whose grid did not change has nothing to wait for", () => {
      vi.useFakeTimers();
      const { d, one } = twoTabs();
      area.cols = 90; area.rows = 28;
      d.fit();                                       // 90×28, previewed: the deck's grid
      d.fit({ hold: true });
      d.fit();
      expect([one.c, one.r]).toEqual([90, 28]);
    });

    it("the held picture moves where the host's resize will put it — bottom-aligned over a prompt at the bottom — and back on a resize", () => {
      vi.useFakeTimers();
      const { d, one, two } = twoTabs();
      one.term.buffer.active.cursorY = 39;           // a prompt on the last of 40 rows
      two.term.buffer.active.cursorY = 2;            // a fresh shell: its prompt near the top
      area.cols = 120; area.rows = 22;               // the keyboard came up
      d.fit({ hold: true });
      expect([one.shift, two.shift], "18 rows lost: under the prompt nothing moves, over the fresh shell nothing needs to").toEqual([-18, 0]);
      vi.advanceTimersByTime(FIT_HOLD_MS);
      expect([one.r, one.shift, two.shift], "resized here: the picture goes back where its own rows put it").toEqual([22, 0, 0]);
    });

    it("an agent's footer below the cursor is the agent's to draw again: its picture moves bottom-aligned", () => {
      vi.useFakeTimers();
      const { d, one, two } = twoTabs();
      one.term.buffer.active.cursorY = 35;           // Claude Code's input box, its rules and footer under it
      one.screen[37] = "  ⏵⏵ auto mode on (shift+tab to cycle)";
      two.term.buffer.active.cursorY = 35;           // the same cursor over blank rows: they simply go
      area.cols = 120; area.rows = 22;
      d.follow();
      expect([one.shift, two.shift]).toEqual([-18, -14]);
    });

    it("follow moves it in the frame the area changes, ahead of the fit, and the fit's hold keeps it there", () => {
      vi.useFakeTimers();
      const { d, fits, one } = twoTabs();
      one.term.buffer.active.cursorY = 39;
      area.cols = 120; area.rows = 22;
      d.follow();
      expect([one.shift, one.r, fits.length], "moved, nothing resized, nothing reported").toEqual([-18, 40, 0]);
      d.fit({ hold: true });
      expect([one.shift, fits.length]).toEqual([-18, 1]);
      area.rows = 40;                                // the keyboard went again before any snapshot
      d.follow();
      expect(one.shift, "back at its own grid: nothing to move").toBe(0);
    });

    it("a desktop's held picture stays top-left: neither follow nor the hold moves it", () => {
      vi.useFakeTimers();
      const { d, fits, one } = twoTabs({ holdShift: false });
      one.term.buffer.active.cursorY = 39;
      area.cols = 120; area.rows = 22;
      d.follow();
      d.fit({ hold: true });
      expect([one.shift, fits.length], "nothing moved, the grid still reported and held").toEqual([0, 1]);
      expect([one.r], "nor resized while it holds").toEqual([40]);
    });

    it("a snapshot's commit is the host's picture at the new grid: the new instance moves nothing", () => {
      vi.useFakeTimers();
      const { d, made, one } = twoTabs();
      one.term.buffer.active.cursorY = 39;
      area.cols = 120; area.rows = 22;
      d.fit({ hold: true });
      d.begin("pty:1", 120, 22, 3); d.commit("pty:1", 3);
      expect([one.disposed, made.at(-1)!.shift]).toEqual([true, 0]);
    });

    it("dispose drops a waiting hold", () => {
      vi.useFakeTimers();
      const { d, one } = twoTabs();
      area.cols = 90; area.rows = 28;
      d.fit({ hold: true });
      d.dispose();
      expect(vi.getTimerCount()).toBe(0);
    });
  });

  it("a fit that cannot measure (the terminal surface hidden) reports nothing", () => {
    const { d, made, fits } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    const before = fits.length;
    (made.at(-1) as unknown as { fit: () => boolean }).fit = () => false;
    d.fit();
    expect(fits.length).toBe(before);
  });

  it("a throwaway fit that throws leaves nothing behind, reports nothing and never escapes", () => {
    const fits: [number, number][] = [];
    const container = document.createElement("div");
    const d = new TermDeck({
      container, fontSize: 14, theme: "dark", onData: () => {}, onReply: () => {}, onFit: (c, r) => fits.push([c, r]), onVisibleChange: () => {},
      mount: (el, opts) => {
        const v = new FakeView(el, opts);
        v.fit = () => { throw new Error("This API only accepts integers"); };
        return v as unknown as XtermView;
      },
    });
    expect(() => d.fit()).not.toThrow();
    expect(fits).toEqual([]);
    expect(container.children.length).toBe(0);
  });

  // Becoming the driver goes through the same policy: a claim or an auto-promotion must not take
  // focus from a remote window's input, nor focus a terminal the user is not looking at.
  it("activate focuses the visible terminal only when nothing else holds focus and its surface is shown", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    const v = made.at(-1)!;
    const win = document.createElement("div");
    win.className = "source-window";
    const input = document.createElement("input");
    win.append(input); document.body.append(win);
    input.focus();
    d.activate(true);
    expect(document.activeElement).toBe(input);
    expect(v.focused).toBe(0);
    input.blur();
    d.activate(false);                                                      // the window surface is on screen
    expect(v.focused).toBe(0);
    d.activate(true);
    expect(document.activeElement).toBe(v.ta);
    win.remove();
  });

  // "Move here" with the active tab's snapshot queued behind an earlier tab's: the control-state
  // (becoming the driver) lands before the visible tab has a view. The intent must wait for it.
  it("activate before the visible tab has a view focuses it when its first view commits", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1);                                            // tab 1 still being written
    d.show("pty:2");                                                        // host-active tab: no slot yet
    d.activate(true);                                                       // nothing to focus yet
    d.commit("pty:1", 1);                                                   // an earlier tab lands: not visible
    expect(document.activeElement).toBe(document.body);
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    expect(document.activeElement).toBe(made.at(-1)!.ta);
    // Consumed: a later repaint of the visible tab after focus moved away takes nothing.
    (document.activeElement as HTMLElement).blur();
    d.begin("pty:2", 80, 24, 3); d.commit("pty:2", 3);
    expect(made.at(-1)!.focused).toBe(0);
  });

  it("a remembered activate keeps the same policy: never steals from a remote input, never while passive", () => {
    const win = document.createElement("div");
    win.className = "source-window";
    const input = document.createElement("input");
    win.append(input); document.body.append(win);
    {
      const { d, made } = deck();
      d.show("pty:1");
      d.activate(true);
      input.focus();                                                        // the user typed into a window meanwhile
      d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
      expect(document.activeElement).toBe(input);
      expect(made.at(-1)!.focused).toBe(0);
    }
    input.blur();
    {
      const { d, made } = deck();
      d.show("pty:1");
      d.activate(false);                                                    // the window surface is on screen
      d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
      expect(made.at(-1)!.focused).toBe(0);
    }
    {
      let surface = false;
      const { d, made } = deck();
      d.show("pty:1");
      d.activate(() => surface);                                            // read when the view lands
      surface = true;
      d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
      expect(made.at(-1)!.focused).toBe(1);
    }
    {
      const { d, made } = deck();
      d.show("pty:1");
      d.activate(true);
      d.deactivate();                                                       // went passive before it landed
      d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
      expect(made.at(-1)!.focused).toBe(0);
    }
    win.remove();
  });

  // Review N1 — b41deb0d focused on every visible change; these are the two cases fix round 1 lost.
  it("the visible tab exiting while it held focus hands focus to the next tab shown", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    const two = made.at(-1)!;
    d.show("pty:1", "user");
    d.close("pty:1");                                                       // `exit`
    d.show("pty:2");                                                        // the host's term-list follows
    expect(document.activeElement).toBe(two.ta);
  });

  it("focus carries to a next tab shown BEFORE its snapshot commits", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1", "user");
    d.close("pty:1");
    d.show("pty:3");                                                        // term-list first: no view yet
    d.begin("pty:3", 80, 24, 2); d.commit("pty:3", 2);
    expect(document.activeElement).toBe(made.at(-1)!.ta);
  });

  // N6: the expectation NAMES the tab. An unrelated new tab landing first (a restored tmux session, a
  // tab of the other kind) used to consume it — that tab took focus, and the one the user asked for
  // arrived without it.
  it("an unrelated new tab landing first does not take the focus meant for the requested one", () => {
    const { d, made } = deck();
    d.expectOpenedTab({ kind: "tmux", known: new Set(["tmux:$2"]) });
    d.begin("pty:9", 80, 24, 1); d.commit("pty:9", 1); d.show("pty:9");  // another kind
    expect(document.activeElement).not.toBe(made.at(-1)!.ta);
    d.begin("tmux:$2", 80, 24, 2); d.commit("tmux:$2", 2); d.show("tmux:$2");   // a restore
    expect(document.activeElement).not.toBe(made.at(-1)!.ta);
    d.begin("tmux:$3", 80, 24, 3); d.commit("tmux:$3", 3); d.show("tmux:$3");   // the one asked for
    expect(document.activeElement).toBe(made.at(-1)!.ta);
  });

  it("an open-tmux focuses exactly the session it named", () => {
    const { d, made } = deck();
    d.expectOpenedTab({ id: "tmux:$5" });
    d.begin("tmux:$4", 80, 24, 1); d.commit("tmux:$4", 1); d.show("tmux:$4");
    expect(document.activeElement).not.toBe(made.at(-1)!.ta);
    d.show("tmux:$5");                                                     // term-list first
    d.begin("tmux:$5", 80, 24, 2); d.commit("tmux:$5", 2);
    expect(document.activeElement).toBe(made.at(-1)!.ta);
  });

  it("a tmux tab the host refused focuses nothing later; a refusal of another leaves it", () => {
    const { d, made } = deck();
    d.expectOpenedTab({ kind: "tmux", known: new Set() });
    d.cancelOpenedTmux(null);                                               // new-tmux failed
    d.begin("tmux:$7", 80, 24, 1); d.commit("tmux:$7", 1); d.show("tmux:$7");
    expect(document.activeElement).not.toBe(made.at(-1)!.ta);
    d.expectOpenedTab({ id: "tmux:$8" });
    d.cancelOpenedTmux("$9");                                               // a restore's gone session
    d.begin("tmux:$8", 80, 24, 2); d.commit("tmux:$8", 2); d.show("tmux:$8");
    expect(document.activeElement).toBe(made.at(-1)!.ta);
  });

  // Fix round M5.
  it("two quick open-terminals focus the SECOND new tab, not the first", () => {
    const { d, made } = deck();
    d.expectOpenedTab({ kind: "pty", known: new Set() });
    d.expectOpenedTab({ kind: "pty", known: new Set() });
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    expect(document.activeElement).not.toBe(made.at(-1)!.ta);
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2); d.show("pty:2");
    expect(document.activeElement).toBe(made.at(-1)!.ta);
  });

  it("a failed open-terminal cancels its expectation — one of two failing leaves the other", () => {
    const a = deck();
    a.d.expectOpenedTab({ kind: "pty", known: new Set() });
    a.d.cancelOpenedPty();
    a.d.begin("pty:3", 80, 24, 1); a.d.commit("pty:3", 1); a.d.show("pty:3");
    expect(document.activeElement).not.toBe(a.made.at(-1)!.ta);
    const b = deck();
    b.d.expectOpenedTab({ kind: "pty", known: new Set() });
    b.d.expectOpenedTab({ kind: "pty", known: new Set() });
    b.d.cancelOpenedPty();
    b.d.begin("pty:4", 80, 24, 1); b.d.commit("pty:4", 1); b.d.show("pty:4");
    expect(document.activeElement).toBe(b.made.at(-1)!.ta);
  });

  it("a refused reopen-terminal (nothing closed, the cap) cancels its expectation", () => {
    const { d, made } = deck();
    d.expectOpenedTab({ kind: "any", known: new Set() });
    d.cancelOpenedPty();
    d.begin("tmux:$3", 80, 24, 1); d.commit("tmux:$3", 1); d.show("tmux:$3");
    expect(document.activeElement).not.toBe(made.at(-1)!.ta);
  });

  it("a reopened tab of either kind takes focus when it lands", () => {
    const { d, made } = deck();
    d.expectOpenedTab({ kind: "any", known: new Set() });
    d.begin("tmux:$3", 80, 24, 1); d.commit("tmux:$3", 1); d.show("tmux:$3");
    expect(document.activeElement).toBe(made.at(-1)!.ta);
  });

  it("a tmux-error naming ANOTHER session leaves a pending new-tmux expectation", () => {
    const { d, made } = deck();
    d.expectOpenedTab({ kind: "tmux", known: new Set() });
    d.cancelOpenedTmux("$9");                                               // a restore's gone session
    d.begin("tmux:$3", 80, 24, 1); d.commit("tmux:$3", 1); d.show("tmux:$3");
    expect(document.activeElement).toBe(made.at(-1)!.ta);
  });

  it("a tab the user opened takes focus when its first snapshot commits, term-list first or not", () => {
    const a = deck();
    a.d.expectOpenedTab({ kind: "pty", known: new Set() });
    a.d.show("pty:5");                                                      // term-list before the snapshot
    a.d.begin("pty:5", 80, 24, 1); a.d.commit("pty:5", 1);
    expect(document.activeElement).toBe(a.made.at(-1)!.ta);
    (document.activeElement as HTMLElement).blur();
    const b = deck();
    b.d.expectOpenedTab({ kind: "pty", known: new Set() });
    b.d.begin("pty:6", 80, 24, 1); b.d.commit("pty:6", 1);                 // snapshot first, hidden
    b.d.show("pty:6");
    expect(document.activeElement).toBe(b.made.at(-1)!.ta);
  });

  it("a user-opened tab never takes focus from a remote window's input", () => {
    const { d, made } = deck();
    const win = document.createElement("div"); win.className = "source-window";
    const input = document.createElement("input"); win.append(input); document.body.append(win);
    d.expectOpenedTab({ kind: "pty", known: new Set() });
    input.focus();
    d.show("pty:7");
    d.begin("pty:7", 80, 24, 1); d.commit("pty:7", 1);
    expect(document.activeElement).toBe(input);
    expect(made.at(-1)!.focused).toBe(0);
    win.remove();
  });

  // Review N2.
  it("activate is not refused by the hidden claim button still reported as focused", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    const claim = document.createElement("div"); claim.id = "claim";
    const btn = document.createElement("button"); btn.id = "claim-button";
    claim.append(btn); document.body.append(claim);
    btn.focus();
    d.activate(true);
    expect(document.activeElement).toBe(made.at(-1)!.ta);
    claim.remove();
  });

  // "Move here" is scoped to a TAB — the one the deck shows for the host when the intent is made —
  // and FOLLOWS the host's newest active tab if that moves before the view commits. Never resolved
  // by another tab's commit, and never stranded on a tab the host has left.
  describe("a remembered activate is scoped to the host's active tab, and follows it", () => {
    const live = (made: FakeView[], tab: string) =>
      made.filter((v) => !v.disposed && v.el.closest(`[data-tab="${tab}"]`)).at(-1)!;

    it("a reshuffle to a tab WITH a view resolves it there, at once", () => {
      const { d, made } = deck();
      d.begin("pty:3", 80, 24, 1); d.commit("pty:3", 1);                     // tab 3 already has a view
      d.show("pty:2");                                                        // host-active: no view yet
      d.activate(true);
      expect(document.activeElement).toBe(document.body);
      d.show("pty:3");                                                        // the host moved on
      expect(document.activeElement).toBe(live(made, "pty:3").ta);
      // Consumed there: tab 2's view landing later (hidden) moves nothing.
      (document.activeElement as HTMLElement).blur();
      d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
      expect(document.activeElement).toBe(document.body);
    });

    it("a reshuffle to a tab WITHOUT a view: the ABANDONED tab's commit resolves nothing, the new one's does", () => {
      const { d, made } = deck();
      d.show("pty:2");
      d.activate(true);
      d.show("pty:3");                                                        // before tab 2's view commits
      d.begin("pty:2", 80, 24, 1); d.commit("pty:2", 1);                     // the tab the intent was made on
      expect(document.activeElement).toBe(document.body);
      expect(live(made, "pty:2").focused).toBe(0);
      d.begin("pty:3", 80, 24, 2); d.commit("pty:3", 2);
      expect(document.activeElement).toBe(live(made, "pty:3").ta);
    });

    it("a rapid there-and-back resolves on the tab the host ended on, once", () => {
      const { d, made } = deck();
      d.show("pty:2");
      d.activate(true);
      d.show("pty:3");
      d.show("pty:2");                                                        // back before either committed
      d.begin("pty:3", 80, 24, 1); d.commit("pty:3", 1);                     // hidden now: nothing
      expect(document.activeElement).toBe(document.body);
      d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
      expect(document.activeElement).toBe(live(made, "pty:2").ta);
      expect(live(made, "pty:3").focused).toBe(0);
    });

    it("the intended tab closing hands the intent to the next tab the host shows", () => {
      const { d, made } = deck();
      d.begin("pty:1", 80, 24, 1);                                            // tab 1 being written, pending
      d.show("pty:1");
      d.activate(true);
      d.close("pty:1");                                                       // it exited before committing
      d.show("pty:4");                                                        // the host's term-list follows
      d.begin("pty:4", 80, 24, 2); d.commit("pty:4", 2);
      expect(document.activeElement).toBe(live(made, "pty:4").ta);
    });

    it("the surface is read when the FOLLOWED tab's view lands, not when the intent was made", () => {
      let surface = true;
      const { d, made } = deck();
      d.show("pty:2");
      d.activate(() => surface);
      d.show("pty:3");
      surface = false;                                                        // the window surface came up
      d.begin("pty:3", 80, 24, 1); d.commit("pty:3", 1);
      expect(live(made, "pty:3").focused).toBe(0);
    });
  });
});

describe("TermDeck.dispose", () => {
  it("disposes every instance, live AND pending, and forgets every tab", () => {
    const { d, made, container } = deck();
    d.begin("pty:1", 80, 24, 1);
    d.commit("pty:1", 1);
    d.begin("pty:2", 80, 24, 1);          // committed below
    d.commit("pty:2", 1);
    d.begin("pty:2", 80, 24, 2);          // a second snapshot, still PENDING
    d.show("pty:1");
    d.dispose();
    expect(made.length).toBeGreaterThanOrEqual(3);          // a fit may have measured a scratch instance too
    expect(made.every((v) => v.disposed)).toBe(true);
    expect(container.children.length).toBe(0);
    expect(d.ids()).toEqual([]);
    expect(d.visibleId()).toBeNull();
  });
});

describe("TermDeck on a soft-keyboard device", () => {
  /// A touch device: a tab switch raises no keyboard unless one was already up (term-view-policy.ts).
  it("on a soft-keyboard device a tab switch focuses only when the terminal already held focus", () => {
    const { d, made } = deck({ softKeyboard: true });
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    d.begin("pty:2", 80, 24, 1); d.commit("pty:2", 1);
    d.show("pty:1", "user");
    const one = made[0]!, two = made[1]!;
    expect(one.focused).toBe(0);                                  // keyboard down: stays down
    d.show("pty:2", "user");
    expect(two.focused).toBe(0);
    two.ta.focus();                                               // the user tapped the terminal
    d.show("pty:1", "user");
    expect(one.focused).toBe(1);                                  // keyboard up: handed on
    expect(document.activeElement).toBe(one.ta);
  });
});

// The host LANDED the person on a terminal tab after the window holding the keys went (SessionState.landing):
// the visible tab takes them — on a touch only typing keys, so a keyboard up stays up and none comes up
// uninvited — and with no view shown yet the next one shown takes them.
describe("TermDeck.takeWindowKeys", () => {
  it("the visible tab takes a window's keys", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    expect(d.takeWindowKeys(false)).toBe(true);
    expect(document.activeElement).toBe(made[0]!.ta);
  });
  it("on a touch only typing keys: the picture's keys raise no keyboard", () => {
    const { d, made } = deck({ softKeyboard: true });
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    expect(d.takeWindowKeys(false)).toBe(false);
    expect(made[0]!.focused).toBe(0);
    expect(d.takeWindowKeys(true)).toBe(true);
    expect(document.activeElement).toBe(made[0]!.ta);
  });
  it("a passive client's terminal takes nothing", () => {
    const { d, made } = deck({ driver: false });
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    expect(d.takeWindowKeys(true)).toBe(false);
    expect(made[0]!.focused).toBe(0);
  });
  it("with no view shown yet, the next view shown takes them", () => {
    const { d, made } = deck();
    d.show("pty:1");                                                   // the host's tab, no snapshot yet
    expect(d.takeWindowKeys(false)).toBe(true);
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    expect(document.activeElement).toBe(made[0]!.ta);
  });
});

describe("TermDeck smooth scrolling", () => {
  it("mounts every instance with the saved preference, and switches them all live", () => {
    const { d, made } = deck({ smoothScroll: true });
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    d.begin("pty:1", 80, 24, 2);                       // a pending re-snapshot of the same tab
    expect(made.map((v) => v.opts.smoothScroll)).toEqual([true, true]);
    d.setSmoothScroll(false);
    expect(made.map((v) => v.smoothSet)).toEqual([[false], [false]]);
    d.begin("pty:2", 80, 24, 3);
    expect(made[2]!.opts.smoothScroll).toBe(false);
  });

  it("stops a glide on the tab being hidden, and only that one", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    d.begin("pty:2", 80, 24, 2); d.commit("pty:2", 2);
    d.show("pty:1");
    const [a, b] = made;
    d.show("pty:2");
    expect(a!.smooth.stops).toBe(1);
    expect(b!.smooth.stops).toBe(0);
    d.show("pty:2");                                   // no change of tab, nothing to stop
    expect(b!.smooth.stops).toBe(0);
  });
});

// docs/terminal.md, "A claim says its grid": a passive page's pictures stopped when control left; the claim overlay
// hid them, and a claim uncovered them until the host's snapshots came (up to 150 ms since the host waits for a
// resized tab's redraw) — this device's terminal as it last saw it.
describe("going passive", () => {
  it("takes every tab's picture away, and each comes back at its next snapshot, unfaded", () => {
    const { d, made, container, visible } = deck();
    d.begin("pty:1", 80, 24, 1); made.at(-1)!.screen = ["one"]; d.commit("pty:1", 1);
    d.begin("pty:2", 80, 24, 2); made.at(-1)!.screen = ["two"]; d.commit("pty:2", 2);
    d.show("pty:1");
    const one = made[0]!, two = made[1]!;
    const slot = (tab: string) => container.querySelector<HTMLElement>(`.xterm-tab[data-tab="${tab}"]`)!;
    expect(slot("pty:1").classList.contains("is-hidden")).toBe(false);
    d.begin("pty:2", 80, 24, 3);                                            // a snapshot the old wire never finished
    const unfinished = made.at(-1)!;

    d.deactivate();
    expect([one.disposed, two.disposed, unfinished.disposed]).toEqual([true, true, true]);
    expect(d.visibleView()).toBeNull();
    expect(visible.at(-1)).toBeNull();
    expect(slot("pty:1").classList.contains("is-hidden")).toBe(true);
    expect(slot("pty:2").classList.contains("is-hidden")).toBe(true);
    expect(d.viewFor("pty:1", 1)).toBeNull();                               // a write queued for it finds nothing

    d.newWire();                                                            // the claim's wire
    d.begin("pty:1", 100, 30, 4); made.at(-1)!.screen = ["fresh"]; d.commit("pty:1", 4);
    expect(slot("pty:1").classList.contains("is-hidden")).toBe(false);
    expect(slot("pty:1").classList.contains("is-fading-in")).toBe(false);
    expect(visible.at(-1)).toBe("pty:1");
    expect(d.visibleView()).toBe(made.at(-1) as unknown as XtermView);
  });

  it("measures the area with no picture left: a claim still says its grid", () => {
    const { d, made, fits } = deck();
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1); d.show("pty:1");
    d.deactivate();
    const before = made.length;
    d.fit({ hold: true });
    expect(fits.at(-1)).toEqual([area.cols, area.rows]);
    expect(made.length, "a throwaway instance measured it").toBe(before + 1);
    expect(made.at(-1)!.disposed).toBe(true);
  });
});

// SCROLLBACK COMES AFTER THE SCREEN (docs/terminal.md): a generation begun by a screen snapshot is rebuilt from its late
// history in an instance of its own, swapped in whole.
describe("the late history's rebuild", () => {
  const onScreen = (d: TermDeck, tab: string, gen: number) => { d.begin(tab, 80, 24, gen); d.commit(tab, gen); d.show(tab); };

  it("writes keep reaching the generation's instance while the rebuild is built; the commit swaps it in", () => {
    const { d, made } = deck();
    onScreen(d, "pty:1", 1);
    const screen = made.at(-1)!;
    expect(d.rebaseBegin("pty:1", 1, 80, 24)).toBe(true);
    const rebuild = made.at(-1)!;
    expect(rebuild).not.toBe(screen);
    expect(d.viewFor("pty:1", 1)).toBe(screen as unknown as XtermView);      // NOT the rebuild: it would steal the live writes
    expect(d.rebaseView("pty:1", 1)).toBe(rebuild as unknown as XtermView);
    expect(d.rebaseCommit("pty:1", 1)).toBe(true);
    expect(d.viewFor("pty:1", 1)).toBe(rebuild as unknown as XtermView);
    expect(d.visibleView()).toBe(rebuild as unknown as XtermView);
    expect(screen.disposed).toBe(true);
    expect(d.rebaseView("pty:1", 1)).toBeNull();
  });

  it("a rebuild's replies and bells are muted until it is in: its bytes were answered by the instance it replaces", () => {
    const { d, made, replies, rang } = deck();
    onScreen(d, "pty:1", 1);
    d.rebaseBegin("pty:1", 1, 80, 24);
    const rebuild = made.at(-1)!;
    rebuild.opts.onReply!("\x1b[0n");
    rebuild.ring();
    expect(replies).toEqual([]);
    expect(rang).toEqual([]);
    d.rebaseCommit("pty:1", 1);
    rebuild.opts.onReply!("\x1b[0n");
    expect(replies).toEqual([["pty:1", "\x1b[0n"]]);
  });

  it("a generation still PENDING is replaced in place, and its commit commits the rebuild", () => {
    const { d, made } = deck();
    d.begin("pty:1", 80, 24, 1);                                             // a held resize: its commit still to come
    const screen = made.at(-1)!;
    d.rebaseBegin("pty:1", 1, 80, 24);
    const rebuild = made.at(-1)!;
    expect(d.rebaseCommit("pty:1", 1)).toBe(true);
    expect(screen.disposed).toBe(true);
    expect(d.viewFor("pty:1", 1)).toBe(rebuild as unknown as XtermView);
    d.commit("pty:1", 1);
    d.show("pty:1");
    expect(d.visibleView()).toBe(rebuild as unknown as XtermView);
  });

  it("a newer generation, a close or an abandon releases a rebuild, and a superseded commit changes nothing", () => {
    const { d, made } = deck();
    onScreen(d, "pty:1", 1);
    d.rebaseBegin("pty:1", 1, 80, 24);
    const first = made.at(-1)!;
    d.begin("pty:1", 80, 24, 2);
    expect(first.disposed).toBe(true);
    expect(d.rebaseCommit("pty:1", 1)).toBe(false);
    expect(d.rebaseBegin("pty:1", 1, 80, 24)).toBe(false);                  // generation 1 is gone
    d.commit("pty:1", 2);
    d.rebaseBegin("pty:1", 2, 80, 24);
    const second = made.at(-1)!;
    d.rebaseAbandon("pty:1", 1);                                             // a stale generation's give-up
    expect(second.disposed, "another generation's rebuild is not its to release").toBe(false);
    d.rebaseAbandon("pty:1", 2);
    expect(second.disposed).toBe(true);
    d.rebaseBegin("pty:1", 2, 80, 24);
    const third = made.at(-1)!;
    d.close("pty:1");
    expect(third.disposed).toBe(true);
  });
});

describe("an agent's tab has no trailing blank lines (trailing-blanks.ts)", () => {
  it("every instance of an agent's tab hides them — live, pending, and one mounted later — and no other tab's does", () => {
    const { d, made } = deck();
    d.begin("tmux:$0", 80, 24, 1); d.commit("tmux:$0", 1);
    d.begin("pty:1", 80, 24, 1); d.commit("pty:1", 1);
    d.begin("tmux:$0", 80, 24, 2);                                   // a snapshot on its way
    const [agentLive, shell, agentPending] = [made[0]!, made[1]!, made[2]!];
    d.setAgentTabs(new Set(["tmux:$0"]));
    expect([agentLive.tailHidden, shell.tailHidden, agentPending.tailHidden]).toEqual([true, false, true]);
    d.commit("tmux:$0", 2);
    d.begin("tmux:$0", 80, 24, 3);                                   // mounted after: told at once
    expect(made.at(-1)!.tailHidden).toBe(true);
    d.setAgentTabs(new Set());                                       // the agent went
    expect(made.filter((v) => !v.disposed).map((v) => v.tailHidden)).toEqual([false, false, false]);
  });
});
