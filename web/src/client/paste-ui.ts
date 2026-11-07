import type { ChannelLike } from "../lib/channel";
import { ContextMenu, type MenuItem } from "./context-menu";
import { attachPressHold } from "./press-hold";
import { onTerminalScrollbar } from "./touch-scroll";
import {
  carriesFiles, carriesLink, canReadClipboard, fileSources, pickFiles, readClipboard, transferContents, type ClipboardRead,
} from "./paste-sources";
import { folderQuestion, pathPieces, sizeQuestion, type FolderQuestion, type LocalFile, type LocalPasteApi, type PreparedFile } from "./paste-local";
import type { Delivery, Outcome, PasteSource, PasteUploader } from "./paste-upload";
import {
  fitName, fitType, PASTE_FILE_MAX_BYTES, PASTE_MAX_ITEMS, PASTE_TEXT_MAX_BYTES, PASTE_TOTAL_MAX_BYTES, PASTE_WARN_BYTES,
  type PastePoint, type PasteReply, type PasteTo,
} from "./paste-wire";
import { tabKind } from "./tab-order";

/// PASTE AND DROP, as a person meets it (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §1, §2):
/// the menus' items, what each does, the question before an unbracketed multi-line paste, and the notes.
/// The transport is `PasteUploader`'s; the gestures are `press-hold.ts`'s. The items are offered by its own
/// two menus — the terminal's, and a window's (its titlebar, or full screen's ⌨) — and by a TAB's
/// (`menuItems`, `pickForTab`, `tabTakesPaste`), which the tab bar shows after Rename and Close.

type Failure = Extract<Outcome, { ok: false }>["reason"];

export const MULTILINE_QUESTION = (n: number) =>
  `Paste ${n} lines? The program isn't expecting a paste, so each line runs as it arrives.`;

/// Once every byte has left the channel the Mac still has the delivery to save, convert and paste — seconds for
/// a big image — so it says so (2026-10-02): a percentage that stops short of the answer reads as stuck.
export function progressNote(label: string, sent: number, total: number): string {
  if (sent >= total) return `Sending ${label} — waiting for the Mac…`;
  return `Sending ${label} — ${Math.floor((sent / total) * 100)}%`;
}

/// What a delivery is called in a note: its file's name, "N files", or "text".
export function labelOf(d: Delivery): string {
  const first = d.items[0];
  return d.items.length > 1 ? `${d.items.length} files` : !first || first.kind === "text" ? "text" : first.name;
}

const NOT_DRIVER = "Not pasted: control moved to another device";
const NO_TARGET = "Not pasted: that tab or window has closed";
const NO_TAB = "Not pasted: no terminal tab is open";
const NO_SWITCH = "Not pasted: the Mac did not switch to that tab";
const TOO_MANY = "Not pasted: too much at once — 1 GB and 32 files at most";

/// How long text bound for a terminal tab that is not on screen waits for the switch to it to land on both
/// ends, and how often it looks.
export const SWITCH_WAIT_MS = 2000;
const SWITCH_POLL_MS = 50;

/// Whether a TAB's menu offers the paste items. A terminal tab always does. A window tab only while its window
/// can take one: the host resolves a window target at the delivery's END (`SimManager.pasteTarget`) and
/// refuses a MINIMIZED window — offered there, a person would upload up to 1 GB to read that the window "has
/// closed", which is false. A window-less session's policy refuses every window target.
export function tabTakesPaste(key: string, s: { windowless: boolean; windows: readonly { source: string; minimized: boolean }[] }): boolean {
  const kind = tabKind(key);
  if (kind === "terminal") return true;
  if (kind !== "window" || s.windowless) return false;
  const w = s.windows.find((x) => x.source === key);
  return !!w && !w.minimized;
}

/// Where a pick goes: the VISIBLE terminal tab (the terminal's own menu, a drop on it), a terminal tab NAMED
/// by its tab's menu, or a window.
type Target = { kind: "term" } | { kind: "tab"; tab: string } | { kind: "win"; source: string };

/// Where a dropped link is TEXT — a text field, an editable element — the browser inserts it and navigates
/// nowhere, so such a drop stays the browser's.
function takesText(t: EventTarget | null): boolean {
  return t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement || (t instanceof HTMLElement && t.isContentEditable === true);
}

export function failureNote(reason: Failure, d: Delivery): string | null {
  switch (reason) {
    case "too-large": {
      const big = d.items.find((it) => it.kind === "text"
        ? new TextEncoder().encode(it.text).length > PASTE_TEXT_MAX_BYTES : it.blob.size > PASTE_FILE_MAX_BYTES);
      if (big?.kind === "text") return "Not pasted: the text is larger than 4 MB";
      if (big) return `Not pasted: ${big.name} is larger than 1 GB`;
      return TOO_MANY;
    }
    case "disk": return "Not pasted: the Mac could not save it";
    case "not-driver": return NOT_DRIVER;
    case "closed": return "Not pasted: the connection dropped";
    case "no-target": return NO_TARGET;
    case "timeout": return "Not pasted: the Mac did not answer";
    // No `paste-accepted` within 5 s: the Mac's Xpromptvs ignores paste — an older build does.
    case "unanswered": return "Not pasted: the Mac did not answer — Xpromptvs there may need updating";
    case "failed": return "Not pasted: the Mac could not paste it";
    case "busy": case "malformed": return "Not pasted — try again";
    case "cancelled": return null;
  }
}

export interface PasteUIDeps {
  signal: AbortSignal;
  owner?: HTMLElement;
  /// This client drives (a passive one pastes nothing).
  enabled(): boolean;
  visibleTab(): string | null;
  /// The VISIBLE terminal instance: xterm.js's own paste, and whether its program enabled ?2004.
  terminal(): { paste(text: string): void; bracketed(): boolean } | null;
  uploader: Pick<PasteUploader, "busy" | "onReply" | "fail" | "cancel" | "deliver">;
  /// A message (`StatusNote.flash`, 6 s, held while a mouse is on it): an outcome that is not a failure —
  /// "Dropped as a paste", "Nothing to paste".
  note(text: string): void;
  /// A FAILURE's message. It STAYED until the next note until 2026-10-02 (§2.6); asked, it goes after 6 s like
  /// any other message — the session wires both to `StatusNote.flash`, and the two stay apart for the tests.
  fail(text: string): void;
  /// The "Sending…" note, a STATE until it is cleared; null clears it.
  progress(text: string | null): void;
  /// A modal yes/no in the top layer; `yes` names its confirming button (default "Paste").
  confirm(question: string, yes?: string): Promise<boolean>;
  /// THE APP'S VIEW OF WHAT FINDER COPIED (paste-local.ts) — absent in a browser, which is never told a path.
  local?: LocalPasteApi | null;
  /// This session's host is THIS Mac (the app's local window): a path here is a path there.
  sameMac?: boolean;
  /// What to do with folders pasted to ANOTHER Mac: this Mac's path, a zip, or nothing (null).
  chooseFolder?(q: FolderQuestion): Promise<"path" | "send" | null>;
  /// The HOST's terminal tabs (its last `term-list`): which are open, and which is ACTIVE — the one a
  /// keystroke must name, or the host drops it.
  hostTabs(): { ids: readonly string[]; active: string | null };
  /// Show terminal tab `key` as a tap on it does: the terminal surface, and a switch when it is not the
  /// visible tab.
  showTab(key: string): void;
  /// For tests: the picker.
  pick?(): Promise<File[]>;
  /// A finger's text selection in the terminal (touch-selection.ts): a hold selects the word under it and the
  /// menu leads with Copy. Absent: the hold opens the paste menu alone.
  selection?(): TerminalSelection | null;
  /// Write `text` to the clipboard — inside the pick's click (Safari ties the permission to the gesture).
  copy?(text: string): void;
}

/// How far a selection's menu stays from it: past a handle's knob (6 px out, 6 px round) and a finger's slop.
const SELECTION_MENU_GAP_PX = 22;

/// What the terminal menu needs of a touch selection (touch-selection.ts `TouchSelection`).
export interface TerminalSelection {
  holdAt(at: { x: number; y: number }): boolean;
  readonly active: boolean;
  readonly busy: boolean;
  text(): string;
  anchor(): DOMRect | null;
  owns(n: Node | null): boolean;
  menuClosed(): void;
}

export class PasteUI {
  readonly menu: ContextMenu;
  private target: Target = { kind: "term" };
  private lastProgress = 0;
  /// How many `prepare`s the app is still making (a folder zipping): Stop sending stops them.
  private preparing = 0;

  constructor(private readonly deps: PasteUIDeps) {
    // The menu closing takes a terminal selection with it — a pick, a press elsewhere, Escape — unless a finger
    // is moving one of its ends, which closed it (touch-selection.ts).
    this.menu = new ContextMenu(deps.signal, (a) => this.pick(a, this.target), () => deps.selection?.()?.menuClosed(), undefined, deps.owner);
    // The session ending stops a zip the app is still making: nobody is left to send it.
    deps.signal.addEventListener("abort", () => { if (this.preparing) deps.local?.cancel(); });
    // A FILE OR A LINK DROPPED ANYWHERE ELSE IN THE SESSION IS REFUSED: a browser opens a dropped file, and
    // follows a dropped link, by NAVIGATING to it, which ends the session — on the tab bar, a titlebar, the
    // status bar. A target that took the drop prevented it first (it is deeper); a text field takes a link as
    // its text and navigates nowhere, so that drop stays the browser's.
    const refuse = (e: DragEvent) => {
      if (e.defaultPrevented) return;
      if (!carriesFiles(e.dataTransfer) && !(carriesLink(e.dataTransfer) && !takesText(e.target))) return;
      e.preventDefault();
      if (e.dataTransfer) e.dataTransfer.dropEffect = "none";
    };
    (deps.owner ?? document).addEventListener("dragover", refuse as EventListener, { signal: deps.signal });
    (deps.owner ?? document).addEventListener("drop", refuse as EventListener, { signal: deps.signal });
  }

  /// The items of EVERY paste menu — the terminal's, a window's, a tab's: one rule, so they never differ.
  menuItems(): MenuItem[] {
    const out: MenuItem[] = [];
    if (canReadClipboard()) out.push({ action: "paste", label: "Paste" });
    out.push({ action: "file", label: "Paste Image/File…" });
    if (this.deps.uploader.busy || this.preparing) out.push({ action: "stop", label: "Stop sending" });
    return out;
  }

  openTerminalMenu(at: { x: number; y: number }): void {
    if (!this.deps.enabled()) return;
    this.target = { kind: "term" };
    this.menu.open(this.menuItems(), null, at);
  }

  /// The terminal menu for a finger's selection: Copy first, then the paste items, ABOVE the selection (below
  /// only without room) and clear of its handles' knobs — iOS's place; under it, it covered the end's handle. A
  /// press on a handle closes it and drags the handle (`ContextMenu`'s pass-through).
  openSelectionMenu(anchor: DOMRect): void {
    const sel = this.deps.selection?.();
    if (!this.deps.enabled() || !sel?.active) return;
    this.target = { kind: "term" };
    this.menu.open([{ action: "copy", label: "Copy" }, ...this.menuItems()], anchor, undefined,
                   { passThrough: (n) => sel.owns(n), above: true, gap: SELECTION_MENU_GAP_PX });
  }

  /// A hold on the terminal: the word under the finger selected, its menu — or, on blank space, the paste menu.
  private terminalHold(at: { x: number; y: number }): void {
    if (!this.deps.enabled()) return;
    const sel = this.deps.selection?.();
    const anchor = sel?.holdAt(at) ? sel.anchor() : null;
    if (anchor) this.openSelectionMenu(anchor); else this.openTerminalMenu(at);
  }

  openWindowMenu(source: string, at: { x: number; y: number }): void {
    if (!this.deps.enabled()) return;
    this.target = { kind: "win", source };
    this.menu.open(this.menuItems(), null, at);
  }

  /// A pick from a TAB's menu (`TabBarCallbacks.onExtra`), for the tab it names — called inside the item's
  /// click, like a pick from this module's own menus. A window tab's goes to that window, wherever it is (the
  /// host raises what it pastes into); a terminal tab's files go to THAT tab, shown or not (the host types the
  /// paths into the tab a delivery names), and its text is `pasteIntoTerminalTab`'s.
  pickForTab(key: string, action: string): void {
    const kind = tabKind(key);
    if (kind === null) return;
    this.pick(action, kind === "window" ? { kind: "win", source: key } : { kind: "tab", tab: key });
  }

  /// The terminal surface: the hold, ⌘V carrying an image, drops.
  attachTerminal(el: HTMLElement): void {
    const signal = this.deps.signal;
    // Never on the scrollbar: a finger resting on its thumb is a scroll about to move (touch-scroll.ts).
    attachPressHold(el, { accepts: (e) => this.deps.enabled() && !onTerminalScrollbar(e.target), onHold: (at) => this.terminalHold(at) }, signal);
    // ⌘V WITH AN IMAGE: xterm.js reads only text/plain and would drop it silently. CAPTURE, so it is seen
    // before xterm.js's textarea; every other paste — any with text — is xterm.js's, unchanged.
    // IN THE APP, a paste carrying files asks the app what Finder copied: a FOLDER reaches the page as a 0-byte
    // file with no type, and only the app can say it is one, and where.
    el.addEventListener("paste", (e) => {
      const dt = (e as ClipboardEvent).clipboardData;
      if (!dt || !dt.files?.length || dt.getData("text/plain") || !this.deps.enabled()) return;
      e.preventDefault();
      e.stopPropagation();
      const files = fileSources([...dt.files]);     // now: the event's DataTransfer is emptied once it is over
      const local = this.deps.local;
      if (!local) { this.toTerminal(files); return; }
      void local.files().then((copied) => {
        if (this.deps.signal.aborted) return;
        if (copied.some((f) => f.dir)) void this.pasteFolders({ kind: "term" }, copied);
        else this.toTerminal(files);
      });
    }, { signal, capture: true });
    el.addEventListener("dragover", (e) => {
      if (!this.deps.enabled() || !e.dataTransfer) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
    }, { signal });
    el.addEventListener("drop", (e) => {
      if (!this.deps.enabled()) return;
      e.preventDefault();
      const { files, text } = transferContents(e.dataTransfer);
      if (files.length) this.toTerminal(fileSources(files));
      else if (text) void this.pasteTextIntoTerminal(text);
    }, { signal });
  }

  /// A drop on a window's picture, at the point (§5).
  windowDrop(source: string, at: PastePoint, dt: DataTransfer | null): void {
    if (!this.deps.enabled()) return;
    const { files, text } = transferContents(dt);
    if (files.length) this.deliver({ win: source }, fileSources(files), at);
    else if (text) this.deliver({ win: source }, [{ kind: "text", text }], at);
  }

  /// Text into terminal tab `tab`, named by its tab's menu. Text goes through the VISIBLE tab's instance and
  /// every keystroke names its tab — the host DROPS one naming a tab it does not have active, never redirects
  /// it (docs/terminal.md) — so a tab that is not on screen is switched to first, exactly as a tap on it does,
  /// and the text waits until BOTH ends show it: the deck's visible tab and the host's `term-list`. The wait is
  /// bounded (`SWITCH_WAIT_MS`); a switch that never lands types nothing and says so — unless the person
  /// moved on to another tab meanwhile, which is not a failure.
  async pasteIntoTerminalTab(tab: string, text: string | readonly string[]): Promise<void> {
    if (!this.driving()) return;
    const listed = () => this.deps.hostTabs().ids.includes(tab);
    // Closed while the clipboard's bubble was up: a switch to a tab that is gone would show nothing.
    if (!listed()) { this.deps.fail(NO_TARGET); return; }
    this.deps.showTab(tab);
    // The instance too: a tab's snapshot may still be on its way, and with none there is nothing to type into.
    const landed = () => this.deps.visibleTab() === tab && this.deps.hostTabs().active === tab && this.deps.terminal() !== null;
    await this.until(() => landed() || !listed() || !this.deps.enabled(), SWITCH_WAIT_MS);
    if (this.deps.signal.aborted || !this.driving()) return;
    if (!listed()) { this.deps.fail(NO_TARGET); return; }
    if (!landed()) {
      // The deck still shows the tab and the host never confirmed it: the Mac's. The deck showing ANOTHER tab
      // is the person having moved on — a tap on a tab — and blaming the Mac for that would be false.
      if (this.deps.visibleTab() === tab) this.deps.fail(NO_SWITCH);
      return;
    }
    await this.pasteTextIntoTerminal(text);
  }

  /// Text into the VISIBLE tab through xterm.js's own paste (§2.4): nothing new crosses the network. PIECES
  /// (paths, `pathPieces`) are pasted one by one, each its own bracketed paste.
  async pasteTextIntoTerminal(text: string | readonly string[]): Promise<void> {
    if (!this.driving()) return;
    const t = this.deps.terminal();
    // No tab, nowhere to type — and said, as every failure is (§2.6).
    if (!t || !this.deps.visibleTab()) { this.deps.fail(NO_TAB); return; }
    const pieces = typeof text === "string" ? [text] : text;
    const lines = pieces.join("").split(/\r\n|\r|\n/).length;
    if (lines > 1 && !t.bracketed()) {
      const tab = this.deps.visibleTab();
      if (!(await this.deps.confirm(MULTILINE_QUESTION(lines)))) return;
      // The question is modal, but control can move (or the session end) while it is up: a passive client
      // types nothing.
      if (this.deps.signal.aborted || !this.driving()) return;
      // AND THE TAB CAN CHANGE UNDER IT, with no word from the person — a shell exiting, a tmux session
      // killed. The yes was for THAT tab: typing whose tab disagrees with the screen is dropped, never
      // redirected (docs/terminal.md). The same tab's instance is read again: a snapshot may have swapped a
      // fresh one in.
      if (this.deps.visibleTab() !== tab) { this.deps.fail(NO_TARGET); return; }
      const now = this.deps.terminal();
      for (const p of pieces) now?.paste(p);
      return;
    }
    for (const p of pieces) t.paste(p);
  }

  onReply(r: PasteReply): void { this.deps.uploader.onReply(r); }
  passive(): void { this.menu.close(); this.deps.uploader.fail("not-driver"); }
  /// `ch` closed: a delivery running on it fails now, not at its reply timeout — and only one on IT.
  channelClosed(ch: ChannelLike): void { this.deps.uploader.fail("closed", ch); }

  private pick(action: string, target: Target): void {
    if (action === "copy") {
      // A finger's selection (touch-selection.ts), written INSIDE this click; the menu closing then takes it.
      const text = this.deps.selection?.()?.text() ?? "";
      if (text) { this.deps.copy?.(text); this.deps.note("Copied"); }
      return;
    }
    if (action === "stop") {
      if (this.preparing) this.deps.local?.cancel();
      this.deps.uploader.cancel();
      return;
    }
    if (action === "file") {
      // NOTHING WAITS ON THE PICKER: a browser that fires no `cancel` never settles it, so a busy state held
      // until it answered would be held for good.
      void (this.deps.pick ?? (() => pickFiles()))().then((files) => {
        if (!files.length || this.deps.signal.aborted) return;
        const items = fileSources(files);
        this.toTarget(target, items);
      });
      return;
    }
    // "paste": `readClipboard` is called SYNCHRONOUSLY here, inside the item's click — the activation it needs.
    // Anything a paste waits on (a switch to a hidden tab) comes AFTER the read, never before it.
    const read = readClipboard();
    const local = this.deps.local;
    if (!local) { void read.then((r) => this.fromClipboard(r, target)); return; }
    // IN THE APP, WHAT FINDER COPIED WINS: Finder puts the files' ICON and names on the pasteboard beside them,
    // which the clipboard read would paste as `pasted.png` — and a folder is otherwise nothing at all.
    void local.files().then((copied) => {
      if (this.deps.signal.aborted) return;
      if (!copied.length) void read.then((r) => this.fromClipboard(r, target));
      else if (copied.some((f) => f.dir)) void this.pasteFolders(target, copied);
      else void this.sendLocal(target, copied);
    });
  }

  /// The clipboard's own text or image (`readClipboard`), to where the pick was made.
  private fromClipboard(r: ClipboardRead, target: Target): void {
    if (this.deps.signal.aborted) return;
    // A dismissed read (iOS's Paste bubble declined) is not a failure: nothing happens and nothing is said.
    if (!r.ok) { if (r.why === "empty") this.deps.note("Nothing to paste"); return; }
    // A terminal's TEXT is typed (§2.4); a window's text, and an image anywhere, are a delivery.
    if (r.source.kind === "text" && target.kind === "term") void this.pasteTextIntoTerminal(r.source.text);
    else if (r.source.kind === "text" && target.kind === "tab") void this.pasteIntoTerminalTab(target.tab, r.source.text);
    else this.toTarget(target, [r.source]);
  }

  /// FOLDERS COPIED IN FINDER (with any files beside them). On THIS Mac every path is typed — it is a path
  /// there. To ANOTHER Mac the person chooses: this Mac's path (typed into a terminal, a window's text), or the
  /// folders zipped and sent with the files as they are.
  private async pasteFolders(at: Target, copied: readonly LocalFile[]): Promise<void> {
    if (!this.driving()) return;
    const target = this.bound(at);
    const paths = copied.map((f) => f.path);
    if (this.deps.sameMac) { await this.typePaths(target, paths); return; }
    const choice = await (this.deps.chooseFolder?.(folderQuestion(copied)) ?? Promise.resolve(null));
    // The question is modal, but control can move (or the session end) while it is up.
    if (choice === null || this.deps.signal.aborted || !this.driving()) return;
    if (choice === "path") await this.typePaths(target, paths);
    else await this.sendLocal(target, copied);
  }

  /// Paths typed as the host types a pasted file's (`pathPieces`: quoted, each its own paste); into a WINDOW,
  /// the bare paths as text, a line each — what a text field there wants.
  private async typePaths(target: Target, paths: readonly string[]): Promise<void> {
    if (target.kind === "win") { this.deliver({ win: target.source }, [{ kind: "text", text: paths.join("\n") }]); return; }
    const pieces = pathPieces(paths);
    if (target.kind === "tab") await this.pasteIntoTerminalTab(target.tab, pieces);
    else await this.pasteTextIntoTerminal(pieces);
  }

  /// What Finder copied, SENT: the app zips each folder and serves each file as it is; over 50 MB the person
  /// is told the size first (sent on yes), over a cap nothing is read. Read only once the person said send.
  private async sendLocal(at: Target, copied: readonly LocalFile[]): Promise<void> {
    const local = this.deps.local;
    if (!local || !this.driving()) return;
    const target = this.bound(at);
    const zipping = copied.some((f) => f.dir);
    const label = copied.length === 1 ? copied[0]!.name : `${copied.length} items`;
    // The caps a delivery has, said before the app makes anything (the bridge takes 32 paths at most).
    if (copied.length > PASTE_MAX_ITEMS) { this.deps.fail(TOO_MANY); return; }
    if (zipping) this.deps.progress(`Compressing ${label}…`);
    let prepared: PreparedFile[];
    this.preparing++;
    try {
      prepared = await local.prepare(copied.map((f) => f.path));
    } catch (e) {
      if (zipping) this.deps.progress(null);
      const why = e instanceof Error ? e.message : "";
      // Stopped (Stop sending, the session ending) is not a failure: nothing is said.
      if (!this.deps.signal.aborted && why !== "cancelled") {
        this.deps.fail(why === "too-large" ? `Not pasted: ${label} is larger than 1 GB compressed`
          : `Not pasted: Xpromptvs could not ${zipping ? "compress" : "read"} ${label}`);
      }
      return;
    } finally {
      this.preparing--;
    }
    if (zipping) this.deps.progress(null);
    const urls = prepared.map((p) => p.url);
    if (this.deps.signal.aborted || !this.driving()) { local.discard(urls); return; }
    const total = prepared.reduce((n, p) => n + p.size, 0);
    const over = prepared.find((p) => p.size > PASTE_FILE_MAX_BYTES);
    if (over || total > PASTE_TOTAL_MAX_BYTES) {
      local.discard(urls);
      this.deps.fail(over ? `Not pasted: ${over.name} is larger than 1 GB` : TOO_MANY);
      return;
    }
    if (total > PASTE_WARN_BYTES) {
      const what = prepared.length > 1 ? `${prepared.length} files` : prepared[0]!.name;
      const yes = await this.deps.confirm(sizeQuestion(what, total), "Send");
      if (!yes || this.deps.signal.aborted || !this.driving()) { local.discard(urls); return; }
    }
    let items: PasteSource[];
    try {
      items = await Promise.all(prepared.map(async (p): Promise<PasteSource> =>
        ({ kind: "file", name: fitName(p.name), type: fitType(p.type), blob: await local.read(p.url) })));
    } catch {
      local.discard(urls);
      if (!this.deps.signal.aborted) this.deps.fail(`Not pasted: Xpromptvs could not read ${label}`);
      return;
    }
    if (this.deps.signal.aborted) return;
    this.toTarget(target, items, true);
  }

  /// A paste that WAITS (a question, a zip) is bound NOW to the terminal tab on screen: a switch meanwhile must
  /// not redirect it — a zip's path typed into another tab, maybe into a running program. With none open it
  /// stays the terminal's, and says so when it gets there.
  private bound(target: Target): Target {
    if (target.kind !== "term") return target;
    const tab = this.deps.visibleTab();
    return tab ? { kind: "tab", tab } : target;
  }

  /// One delivery to where the pick was made. `warned`: the person already said send to its size.
  private toTarget(target: Target, items: PasteSource[], warned = false): void {
    if (target.kind === "term") this.toTerminal(items, warned);
    else if (target.kind === "tab") this.deliver({ term: target.tab }, items, undefined, warned);
    else this.deliver({ win: target.source }, items, undefined, warned);
  }

  private toTerminal(items: PasteSource[], warned = false): void {
    const tab = this.deps.visibleTab();
    // With no terminal tab open a file has nowhere to go: said, never silently dropped.
    if (!tab) { if (this.driving()) this.deps.fail(NO_TAB); return; }
    this.deliver({ term: tab }, items, undefined, warned);
  }

  /// The uploader's progress (`UploaderDeps.onProgress`), at most ten notes a second — and always the last.
  progress(sent: number, total: number, d: Delivery): void {
    if (this.deps.signal.aborted) return;           // a piece in flight as the session ended: no note left
    const now = Date.now();
    if (now - this.lastProgress < 100 && sent < total) return;
    this.lastProgress = now;
    this.deps.progress(progressNote(labelOf(d), sent, total));
  }

  /// Resolves once `done` holds, at `ms`, or when the session ends — POLLED: what a switch waits on (the
  /// deck's visible tab, the host's `term-list`, the tab's instance) changes in more places than one. Its
  /// timer goes with the session.
  private until(done: () => boolean, ms: number): Promise<void> {
    const signal = this.deps.signal;
    return new Promise((resolve) => {
      const deadline = Date.now() + ms;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const end = () => { clearTimeout(timer); signal.removeEventListener("abort", end); resolve(); };
      const check = () => {
        if (signal.aborted || done() || Date.now() >= deadline) end();
        else timer = setTimeout(check, SWITCH_POLL_MS);
      };
      signal.addEventListener("abort", end);
      check();
    });
  }

  /// Still the driver — asked again where a paste waited (the clipboard's bubble, the picker, the question):
  /// control can move meanwhile, and the host would only refuse what a passive client sends.
  private driving(): boolean {
    if (this.deps.enabled()) return true;
    this.deps.fail(NOT_DRIVER);
    return false;
  }

  private deliver(to: PasteTo, items: PasteSource[], at?: PastePoint, warned = false): void {
    if (!this.driving()) return;
    // A 0-BYTE FILE IS SKIPPED: the host refuses a size of 0 as malformed, which would sink every file
    // beside it. An empty clipboard image or an empty file picked alone is nothing to paste.
    const some = items.filter((it) => (it.kind === "text" ? it.text !== "" : it.blob.size > 0));
    if (!some.length) { this.deps.note("Nothing to paste"); return; }
    const d: Delivery = at ? { to, at, items: some } : { to, items: some };
    // A BIG PASTE IS SENT AFTER A WARNING, NOT REFUSED (2026-10-02): over 50 MB the person is told its size
    // first. One over a CAP is not asked about — the uploader refuses it, and says why.
    const sizes = some.map((it) => (it.kind === "file" ? it.blob.size : 0));
    const total = sizes.reduce((n, x) => n + x, 0);
    const capped = sizes.some((x) => x > PASTE_FILE_MAX_BYTES) || total > PASTE_TOTAL_MAX_BYTES;
    // THE PASTE'S SIZE, not a file's: the person asked to be warned when what is SENT is over 50 MB.
    if (warned || capped || total <= PASTE_WARN_BYTES) { void this.send(d); return; }
    void this.deps.confirm(sizeQuestion(labelOf(d), total), "Send").then((yes) => {
      if (!yes || this.deps.signal.aborted || !this.driving()) return;
      void this.send(d);
    });
  }

  private async send(d: Delivery): Promise<void> {
    const out = await this.deps.uploader.deliver(d);
    // The session may have ended while it ran: its notes are gone with it.
    if (this.deps.signal.aborted) return;
    this.deps.progress(null);
    if (out.ok) { if (out.how === "paste" && d.at) this.deps.note("Dropped as a paste"); return; }
    const n = failureNote(out.reason, d);
    if (n) this.deps.fail(n);
  }
}
