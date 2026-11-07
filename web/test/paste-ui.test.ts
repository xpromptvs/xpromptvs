// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  failureNote, labelOf, MULTILINE_QUESTION, PasteUI, progressNote, tabTakesPaste, type PasteUIDeps,
} from "../src/client/paste-ui";
import type { Delivery, Outcome, PasteUploader } from "../src/client/paste-upload";
import type { LocalFile, LocalPasteApi, PreparedFile } from "../src/client/paste-local";
import { HOLD_MS } from "../src/client/press-hold";

// jsdom has no Popover API and no top layer: the stub is a flag, `:popover-open` reads it (as
// context-menu.test.ts does).
const proto = HTMLElement.prototype as unknown as Record<string, unknown>;
const realMatches = Element.prototype.matches;
beforeEach(() => {
  proto.showPopover = function (this: HTMLElement) { this.dataset.open = "1"; };
  proto.hidePopover = function (this: HTMLElement) { delete this.dataset.open; };
  Element.prototype.matches = function (this: Element, sel: string) {
    return sel === ":popover-open" ? (this as HTMLElement).dataset.open === "1" : realMatches.call(this, sel);
  };
});
afterEach(() => {
  delete proto.showPopover;
  delete proto.hidePopover;
  Element.prototype.matches = realMatches;
  setClipboard(undefined);
  document.body.innerHTML = "";
});

/// `navigator.clipboard` as a secure context has it (`read`), or absent as the LAN dev origin has it.
function setClipboard(read: (() => Promise<unknown>) | undefined): void {
  Object.defineProperty(navigator, "clipboard", { value: read ? { read } : undefined, configurable: true });
}
const clipItem = (types: Record<string, Blob>) => ({ types: Object.keys(types), getType: async (t: string) => types[t] });
// jsdom's Blob has no text(): shimmed here, never in product code.
const textBlob = (s: string) => Object.assign(new Blob([s]), { text: async () => s });
const png = (bytes = 3) => new Blob([new Uint8Array(bytes)], { type: "image/png" });
const file = (name: string, bytes: number, type = "image/jpeg") => new File([new Uint8Array(bytes)], name, { type });
/// A blob that only says how big it is — a 60 MB file costs nothing to describe.
const sized = (size: number) => ({ size }) as Blob;

/// A DataTransfer as a paste event or a drop carries it. A LINK (`uri`) is what a browser's dragged link or image
/// carries: `text/uri-list` with the URL as `text/plain` beside it.
function transfer(o: { files?: File[]; text?: string; uri?: string }): DataTransfer {
  const files = o.files ?? [];
  const text = o.text ?? o.uri;
  const types = [...(files.length ? ["Files"] : []), ...(o.uri !== undefined ? ["text/uri-list"] : []),
                 ...(text !== undefined ? ["text/plain"] : [])];
  return { files, types, dropEffect: "none",
           getData: (t: string) => (t === "text/plain" ? text ?? "" : t === "text/uri-list" ? o.uri ?? "" : "") } as unknown as DataTransfer;
}
/// jsdom has no ClipboardEvent or DragEvent: an Event with the field on it.
function fire(target: EventTarget, type: string, field: "clipboardData" | "dataTransfer", dt: DataTransfer): Event {
  const e = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(e, field, { value: dt });
  target.dispatchEvent(e);
  return e;
}
/// jsdom has no PointerEvent: a MouseEvent of the pointer type (press-hold.test.ts).
const touch = (type: string, x: number, y: number) => {
  const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y });
  for (const [k, v] of Object.entries({ pointerId: 3, pointerType: "touch", isPrimary: true })) Object.defineProperty(e, k, { value: v });
  return e as PointerEvent;
};
const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setTimeout(r, 0)); };

interface RigOpts {
  bracketed?: boolean; answer?: boolean; visible?: string | null; outcome?: Outcome;
  pick?: () => Promise<File[]>; confirm?: (q: string, yes?: string) => Promise<boolean>;
  /// The app's view of what Finder copied (absent: a browser), and whether this session's host is this Mac.
  local?: LocalPasteApi | null; sameMac?: boolean;
  /// The folder question's answer.
  choose?: "path" | "send" | null;
  terminal?: PasteUIDeps["terminal"];
  /// The host's terminal tabs (its last `term-list`) and the one it has active.
  tabs?: string[]; active?: string | null;
  /// A finger's selection (touch-selection.ts) and the clipboard write.
  selection?: PasteUIDeps["selection"]; copy?: PasteUIDeps["copy"];
}
function rig(o: RigOpts = {}) {
  const ac = new AbortController();
  const deliveries: Delivery[] = [];
  const uploader = {
    busy: false,
    outcome: o.outcome ?? ({ ok: true, how: "paste" } as Outcome),
    deliver: vi.fn(async (d: Delivery) => { deliveries.push(d); return uploader.outcome; }),
    cancel: vi.fn(), onReply: vi.fn(), fail: vi.fn(),
  };
  const s = { enabled: true, visible: o.visible === undefined ? "pty:1" : o.visible,
               pasted: [] as string[], notes: [] as string[], fails: [] as string[], progress: [] as (string | null)[],
               questions: [] as string[], yeses: [] as (string | undefined)[], asked: [] as string[],
               tabs: o.tabs ?? ["pty:1"], active: o.active === undefined ? "pty:1" : o.active, shown: [] as string[] };
  const deps: PasteUIDeps = {
    signal: ac.signal,
    enabled: () => s.enabled,
    visibleTab: () => s.visible,
    terminal: o.terminal ?? (() => ({ paste: (t) => { s.pasted.push(t); }, bracketed: () => o.bracketed ?? false })),
    uploader: uploader as unknown as PasteUploader,
    note: (t) => { s.notes.push(t); },
    fail: (t) => { s.fails.push(t); },
    progress: (t) => { s.progress.push(t); },
    confirm: o.confirm ?? (async (q, yes) => { s.questions.push(q); s.yeses.push(yes); return o.answer ?? true; }),
    local: o.local ?? null,
    sameMac: o.sameMac ?? false,
    chooseFolder: async (q) => { s.asked.push(q.title); return o.choose === undefined ? "path" : o.choose; },
    pick: o.pick ?? (async () => []),
    hostTabs: () => ({ ids: s.tabs, active: s.active }),
    showTab: (key) => { s.shown.push(key); },
    selection: o.selection,
    copy: o.copy,
  };
  const term = document.createElement("div");
  const textarea = document.createElement("textarea");      // where xterm.js listens
  term.append(textarea);
  const elsewhere = document.createElement("div");
  document.body.append(term, elsewhere);
  const ui = new PasteUI(deps);
  ui.attachTerminal(term);
  return { ac, ui, uploader, deliveries, s, term, textarea, elsewhere };
}
const items = () => [...document.querySelectorAll(".ctx-menu-item")].map((b) => b.textContent);
const pick = (action: string) => document.querySelector<HTMLButtonElement>(`.ctx-menu-item[data-action="${action}"]`)!.click();

describe("failureNote, progressNote, labelOf — §2.6", () => {
  const d = (items: Delivery["items"]): Delivery => ({ to: { term: "pty:1" }, items });
  const big = { kind: "file" as const, name: "IMG.mov", type: "video/quicktime", blob: sized(1024 * 1024 * 1024 + 1) };
  it("1. too-large names what was too large", () => {
    expect(failureNote("too-large", d([big]))).toBe("Not pasted: IMG.mov is larger than 1 GB");
    expect(failureNote("too-large", d([{ kind: "text", text: "x".repeat(4 * 1024 * 1024 + 1) }])))
      .toBe("Not pasted: the text is larger than 4 MB");
    const four = (n: number) => ({ kind: "file" as const, name: `${n}.bin`, type: "", blob: sized(400 * 1024 * 1024) });
    expect(failureNote("too-large", d([four(1), four(2), four(3)]))).toBe("Not pasted: too much at once — 1 GB and 32 files at most");
    const many = Array.from({ length: 33 }, (_, i) => ({ kind: "file" as const, name: `${i}.txt`, type: "", blob: sized(1) }));
    expect(failureNote("too-large", d(many))).toBe("Not pasted: too much at once — 1 GB and 32 files at most");
  });
  it("1. every other reason has its sentence, and a cancel says nothing", () => {
    const one = d([{ kind: "file", name: "a.png", type: "image/png", blob: sized(1) }]);
    expect(failureNote("disk", one)).toBe("Not pasted: the Mac could not save it");
    expect(failureNote("not-driver", one)).toBe("Not pasted: control moved to another device");
    expect(failureNote("closed", one)).toBe("Not pasted: the connection dropped");
    expect(failureNote("no-target", one)).toBe("Not pasted: that tab or window has closed");
    expect(failureNote("timeout", one)).toBe("Not pasted: the Mac did not answer");
    // No `paste-accepted` within 5 s: a Mac whose Xpromptvs ignores paste (an older build did) — said so.
    expect(failureNote("unanswered", one)).toBe("Not pasted: the Mac did not answer — Xpromptvs there may need updating");
    expect(failureNote("failed", one)).toBe("Not pasted: the Mac could not paste it");
    expect(failureNote("busy", one)).toBe("Not pasted — try again");
    expect(failureNote("malformed", one)).toBe("Not pasted — try again");
    expect(failureNote("cancelled", one)).toBeNull();
  });
  it("2. the progress note — and once every byte is sent, that it waits for the Mac", () => {
    expect(progressNote("IMG_0042.jpg", 40, 100)).toBe("Sending IMG_0042.jpg — 40%");
    expect(progressNote("IMG_0042.jpg", 99.9, 100)).toBe("Sending IMG_0042.jpg — 99%");
    // Sent is not delivered: the Mac still saves, converts and pastes it. A frozen "100%" (or 94%) read as stuck.
    expect(progressNote("IMG_0042.jpg", 100, 100)).toBe("Sending IMG_0042.jpg — waiting for the Mac…");
    expect(labelOf(d([{ kind: "file", name: "IMG_0042.jpg", type: "image/jpeg", blob: sized(1) }]))).toBe("IMG_0042.jpg");
    expect(labelOf(d([{ kind: "file", name: "a", type: "", blob: sized(1) }, { kind: "file", name: "b", type: "", blob: sized(1) }]))).toBe("2 files");
    expect(labelOf({ to: { win: "win:1" }, items: [{ kind: "text", text: "hi" }] })).toBe("text");
  });
});

describe("PasteUI — the terminal (§2.2–§2.6)", () => {
  let r: ReturnType<typeof rig>;
  afterEach(() => r?.ac.abort());

  it("3. the menu offers Paste only with a clipboard to read, and Stop sending only while sending", () => {
    r = rig();
    setClipboard(async () => []);
    r.ui.openTerminalMenu({ x: 5, y: 5 });
    expect(r.ui.menu.isOpen).toBe(true);
    expect(items()).toEqual(["Paste", "Paste Image/File…"]);
    setClipboard(undefined);
    r.ui.openTerminalMenu({ x: 5, y: 5 });
    expect(items()).toEqual(["Paste Image/File…"]);
    r.uploader.busy = true;
    r.ui.openTerminalMenu({ x: 5, y: 5 });
    expect(items()).toEqual(["Paste Image/File…", "Stop sending"]);
    pick("stop");
    expect(r.uploader.cancel).toHaveBeenCalledTimes(1);
  });

  it("4. several lines into a program not expecting a paste ask first, and paste only on yes", async () => {
    for (const answer of [true, false]) {
      r = rig({ answer });
      setClipboard(async () => [clipItem({ "text/plain": textBlob("a\nb") })]);
      r.ui.openTerminalMenu({ x: 1, y: 1 });
      pick("paste");
      await settle();
      expect(r.s.questions).toEqual([MULTILINE_QUESTION(2)]);
      expect(r.s.pasted).toEqual(answer ? ["a\nb"] : []);
      expect(r.deliveries).toEqual([]);            // a terminal's text never leaves the client as a paste
      r.ac.abort();
    }
  });
  it("4. with bracketed paste on it pastes at once; one line never asks", async () => {
    r = rig({ bracketed: true });
    setClipboard(async () => [clipItem({ "text/plain": textBlob("a\nb\nc") })]);
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("paste");
    await settle();
    expect(r.s.questions).toEqual([]);
    expect(r.s.pasted).toEqual(["a\nb\nc"]);
    r.ac.abort();
    r = rig();
    await r.ui.pasteTextIntoTerminal("ls -la");
    expect(r.s.questions).toEqual([]);
    expect(r.s.pasted).toEqual(["ls -la"]);
  });
  it("4. control moving away while the question is up pastes nothing", async () => {
    let answer!: (yes: boolean) => void;
    const asked = new Promise<boolean>((res) => { answer = res; });
    r = rig({ confirm: () => asked });
    const done = r.ui.pasteTextIntoTerminal("a\nb");
    r.s.enabled = false;
    answer(true);
    await done;
    expect(r.s.pasted).toEqual([]);
    expect(r.s.fails).toEqual(["Not pasted: control moved to another device"]);
    expect(r.s.notes).toEqual([]);
  });
  // Typing whose tab disagrees with the screen is DROPPED, never redirected (docs/terminal.md): a shell that
  // exited or a tmux session killed while the question was up moves the visible tab with no word from the
  // person, and the lines they agreed to must not run in a tab they never saw asked about.
  it("4. the visible tab changing while the question is up pastes nothing, and says the tab has gone", async () => {
    let answer!: (yes: boolean) => void;
    r = rig({ confirm: () => new Promise<boolean>((res) => { answer = res; }) });
    const done = r.ui.pasteTextIntoTerminal("rm -rf build\nmake");
    r.s.visible = "pty:2";
    answer(true);
    await done;
    expect(r.s.pasted).toEqual([]);
    expect(r.s.fails).toEqual(["Not pasted: that tab or window has closed"]);
  });
  it("4. ...but the SAME tab's fresh instance (a snapshot swapped it in) takes the paste", async () => {
    let answer!: (yes: boolean) => void;
    const got: string[] = [];
    const before = { paste: (t: string) => { got.push(`old:${t}`); }, bracketed: () => false };
    const after = { paste: (t: string) => { got.push(`new:${t}`); }, bracketed: () => false };
    let view = before;
    r = rig({ confirm: () => new Promise<boolean>((res) => { answer = res; }), terminal: () => view });
    const done = r.ui.pasteTextIntoTerminal("a\nb");
    view = after;
    answer(true);
    await done;
    expect(got).toEqual(["new:a\nb"]);
    expect([r.s.notes, r.s.fails]).toEqual([[], []]);
  });
  it("control moving away while the clipboard or the picker is up sends nothing, and says why", async () => {
    r = rig({ pick: async () => { r.s.enabled = false; return [file("a.jpg", 2)]; } });
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("file");
    await settle();
    r.s.enabled = true;
    setClipboard(async () => { r.s.enabled = false; return [clipItem({ "text/plain": textBlob("ls") })]; });
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("paste");
    await settle();
    expect([r.deliveries, r.s.pasted]).toEqual([[], []]);
    expect(r.s.fails).toEqual(["Not pasted: control moved to another device", "Not pasted: control moved to another device"]);
  });

  it("5. a clipboard IMAGE goes to the visible tab as pasted.png, and success says nothing", async () => {
    r = rig({ visible: "tmux:$2" });
    const img = png(5);
    setClipboard(async () => [clipItem({ "text/plain": textBlob("https://example.com/a.png"), "image/png": img })]);
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("paste");
    await settle();
    expect(r.deliveries).toHaveLength(1);
    expect(r.deliveries[0]).toEqual({ to: { term: "tmux:$2" }, items: [{ kind: "file", name: "pasted.png", type: "image/png", blob: img }] });
    expect(r.s.notes).toEqual([]);
    expect(r.s.pasted).toEqual([]);
    expect(r.s.progress).toEqual([null]);         // whatever "Sending…" said is cleared when it lands
  });

  it("6. a dismissed clipboard read does nothing and says nothing; an empty one says so", async () => {
    r = rig();
    setClipboard(() => Promise.reject(new DOMException("dismissed", "NotAllowedError")));
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("paste");
    await settle();
    expect([r.deliveries, r.s.pasted, r.s.notes, r.s.questions]).toEqual([[], [], [], []]);
    setClipboard(async () => []);
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("paste");
    await settle();
    expect(r.s.notes).toEqual(["Nothing to paste"]);
    expect(r.deliveries).toEqual([]);
  });

  it("7. Paste Image/File… sends every picked file as ONE delivery", async () => {
    const a = file("IMG_1.jpg", 4), b = file("notes.pdf", 9, "application/pdf");
    r = rig({ pick: async () => [a, b] });
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("file");
    await settle();
    expect(r.deliveries).toHaveLength(1);
    expect(r.deliveries[0]!.to).toEqual({ term: "pty:1" });
    expect(r.deliveries[0]!.items.map((i) => (i.kind === "file" ? i.name : "?"))).toEqual(["IMG_1.jpg", "notes.pdf"]);
  });
  it("7. a picker that never answers (no `cancel` event) leaves nothing waiting on it", async () => {
    let calls = 0;
    r = rig({ pick: () => { calls++; return calls === 1 ? new Promise<File[]>(() => {}) : Promise.resolve([file("b.jpg", 2)]); } });
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("file");
    await settle();
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    expect(items()).toEqual(["Paste Image/File…"]);
    pick("file");
    await settle();
    expect(r.deliveries).toHaveLength(1);
  });

  it("ruling 1: a 0-byte file is skipped — picked, dropped or pasted — and nothing left says so", async () => {
    r = rig({ pick: async () => [file("empty.txt", 0, "text/plain"), file("a.jpg", 2)] });
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("file");
    await settle();
    expect(r.deliveries.map((d) => d.items.map((i) => (i.kind === "file" ? i.name : "?")))).toEqual([["a.jpg"]]);
    r.ac.abort();

    r = rig({ pick: async () => [file("empty.txt", 0, "text/plain")] });
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("file");
    await settle();
    fire(r.textarea, "drop", "dataTransfer", transfer({ files: [file("empty.png", 0, "image/png")] }));
    const e = fire(r.textarea, "paste", "clipboardData", transfer({ files: [file("image.png", 0, "image/png")] }));
    setClipboard(async () => [clipItem({ "image/png": png(0) })]);
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("paste");
    await settle();
    expect(r.deliveries).toEqual([]);
    expect(e.defaultPrevented).toBe(true);        // still the upload path's: xterm.js would drop it silently
    expect(r.s.notes).toEqual(["Nothing to paste", "Nothing to paste", "Nothing to paste", "Nothing to paste"]);
  });

  it("8. ⌘V carrying a file and no text is taken and uploaded; one carrying text is xterm.js's", async () => {
    r = rig();
    const reached = vi.fn();
    r.textarea.addEventListener("paste", reached);
    const img = file("image.png", 6, "image/png");
    const e1 = fire(r.textarea, "paste", "clipboardData", transfer({ files: [img], text: "" }));
    await settle();
    expect(e1.defaultPrevented).toBe(true);
    expect(reached).not.toHaveBeenCalled();
    expect(r.deliveries).toHaveLength(1);
    expect(r.deliveries[0]).toMatchObject({ to: { term: "pty:1" }, items: [{ kind: "file", name: "image.png", type: "image/png" }] });
    const e2 = fire(r.textarea, "paste", "clipboardData", transfer({ files: [img], text: "a caption" }));
    const e3 = fire(r.textarea, "paste", "clipboardData", transfer({ text: "echo hi" }));
    await settle();
    expect([e2.defaultPrevented, e3.defaultPrevented]).toEqual([false, false]);
    expect(reached).toHaveBeenCalledTimes(2);
    expect(r.deliveries).toHaveLength(1);
    expect(r.s.questions).toEqual([]);            // ⌘V never asks
  });

  it("9. a drop on the terminal: files are one delivery to the visible tab, text is pasted (asking first)", async () => {
    r = rig({ answer: true });
    const over = fire(r.textarea, "dragover", "dataTransfer", transfer({ files: [file("a.jpg", 1)] }));
    expect(over.defaultPrevented).toBe(true);
    expect((over as unknown as { dataTransfer: DataTransfer }).dataTransfer.dropEffect).toBe("copy");
    const drop = fire(r.textarea, "drop", "dataTransfer", transfer({ files: [file("a.jpg", 1), file("b.jpg", 2)], text: "file:///a.jpg" }));
    await settle();
    expect(drop.defaultPrevented).toBe(true);
    expect(r.deliveries).toHaveLength(1);
    expect(r.deliveries[0]!.to).toEqual({ term: "pty:1" });
    expect(r.deliveries[0]!.items).toHaveLength(2);
    fire(r.textarea, "drop", "dataTransfer", transfer({ text: "one\ntwo\nthree" }));
    await settle();
    expect(r.s.questions).toEqual([MULTILINE_QUESTION(3)]);
    expect(r.s.pasted).toEqual(["one\ntwo\nthree"]);
    expect(r.deliveries).toHaveLength(1);
  });

  it("10. a FILE dragged anywhere else is refused (no navigation); the terminal's own drop is left alone", () => {
    r = rig();
    const over = fire(r.elsewhere, "dragover", "dataTransfer", transfer({ files: [file("a.jpg", 1)] }));
    expect(over.defaultPrevented).toBe(true);
    expect((over as unknown as { dataTransfer: DataTransfer }).dataTransfer.dropEffect).toBe("none");
    const drop = fire(r.elsewhere, "drop", "dataTransfer", transfer({ files: [file("a.jpg", 1)] }));
    expect(drop.defaultPrevented).toBe(true);
    // Text dragged elsewhere is the browser's (an input takes it).
    expect(fire(r.elsewhere, "dragover", "dataTransfer", transfer({ text: "hi" })).defaultPrevented).toBe(false);
    // The terminal took it first: its copy stands.
    const mine = fire(r.textarea, "dragover", "dataTransfer", transfer({ files: [file("a.jpg", 1)] }));
    expect((mine as unknown as { dataTransfer: DataTransfer }).dataTransfer.dropEffect).toBe("copy");
    // Gone with the session.
    r.ac.abort();
    expect(fire(r.elsewhere, "dragover", "dataTransfer", transfer({ files: [file("a.jpg", 1)] })).defaultPrevented).toBe(false);
  });

  // A LINK DROPPED WHERE NOTHING TAKES IT NAVIGATES THE PAGE — to the link, ending the session — for the same
  // reason a file does: the tab bar, a titlebar, the status bar. A browser's dragged link, and a dragged image
  // of the page's own (a palette thumbnail), carry `text/uri-list`.
  it("10. a LINK dragged anywhere else is refused too; the terminal's drop and an input's are left alone", async () => {
    r = rig({ bracketed: true });
    const over = fire(r.elsewhere, "dragover", "dataTransfer", transfer({ uri: "https://example.com/" }));
    expect(over.defaultPrevented).toBe(true);
    expect((over as unknown as { dataTransfer: DataTransfer }).dataTransfer.dropEffect).toBe("none");
    expect(fire(r.elsewhere, "drop", "dataTransfer", transfer({ uri: "https://example.com/" })).defaultPrevented).toBe(true);
    // The terminal takes a link as the text it is (its URL), and its own drop effect stands.
    const mine = fire(r.textarea, "dragover", "dataTransfer", transfer({ uri: "https://example.com/" }));
    expect((mine as unknown as { dataTransfer: DataTransfer }).dataTransfer.dropEffect).toBe("copy");
    const took = fire(r.textarea, "drop", "dataTransfer", transfer({ uri: "https://example.com/" }));
    await settle();
    expect(took.defaultPrevented).toBe(true);
    expect(r.s.pasted).toEqual(["https://example.com/"]);
    // A text field takes a dropped link as text, which navigates nothing: the browser's, as before.
    const input = document.createElement("input");
    document.body.append(input);
    expect(fire(input, "dragover", "dataTransfer", transfer({ uri: "https://example.com/" })).defaultPrevented).toBe(false);
    expect(fire(input, "drop", "dataTransfer", transfer({ uri: "https://example.com/" })).defaultPrevented).toBe(false);
  });

  // NOTHING SILENT (§2.6): with no terminal tab open a file, an image or text bound for the terminal has nowhere
  // to go, and the person is told — in a note that stays, like every failure.
  it("10. with no terminal tab open, a drop, a ⌘V image, a pick or a clipboard paste says so and sends nothing", async () => {
    r = rig({ visible: null, pick: async () => [file("a.jpg", 2)] });
    fire(r.textarea, "drop", "dataTransfer", transfer({ files: [file("a.jpg", 1)] }));
    const v = fire(r.textarea, "paste", "clipboardData", transfer({ files: [file("image.png", 3, "image/png")] }));
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("file");
    await settle();
    setClipboard(async () => [clipItem({ "image/png": png(4) })]);
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("paste");
    await settle();
    fire(r.textarea, "drop", "dataTransfer", transfer({ text: "ls" }));
    await settle();
    expect(v.defaultPrevented).toBe(true);
    expect([r.deliveries, r.s.pasted, r.s.notes]).toEqual([[], [], []]);
    expect(r.s.fails).toEqual(Array(5).fill("Not pasted: no terminal tab is open"));
  });

  it("11. passive() abandons what is in flight as not-driver and closes the menu", () => {
    r = rig();
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    expect(r.ui.menu.isOpen).toBe(true);
    r.ui.passive();
    expect(r.uploader.fail).toHaveBeenCalledWith("not-driver");
    expect(r.ui.menu.isOpen).toBe(false);
    const ch = new EventTarget() as never;
    r.ui.channelClosed(ch);
    expect(r.uploader.fail).toHaveBeenLastCalledWith("closed", ch);   // THAT channel's delivery only
    r.ui.onReply({ t: "paste-done", id: "p1", how: "paste" });
    expect(r.uploader.onReply).toHaveBeenCalledWith({ t: "paste-done", id: "p1", how: "paste" });
  });
  it("11. a held finger opens the menu at the finger — and a passive client's opens nothing", () => {
    vi.useFakeTimers();
    try {
      r = rig();
      r.textarea.dispatchEvent(touch("pointerdown", 40, 50));
      vi.advanceTimersByTime(HOLD_MS);
      expect(r.ui.menu.isOpen).toBe(true);
      window.dispatchEvent(touch("pointerup", 40, 50));
      r.ui.menu.close();
      r.s.enabled = false;
      r.textarea.dispatchEvent(touch("pointerdown", 40, 50));
      vi.advanceTimersByTime(HOLD_MS);
      expect(r.ui.menu.isOpen).toBe(false);
      // ...and its finger is still its own: the scroll under it moves (no held gesture swallows it).
      const tm = new Event("touchmove", { bubbles: true, cancelable: true });
      r.textarea.dispatchEvent(tm);
      expect(tm.defaultPrevented).toBe(false);
      window.dispatchEvent(touch("pointerup", 40, 50));
      r.ui.openTerminalMenu({ x: 1, y: 1 });
      expect(r.ui.menu.isOpen).toBe(false);
      // A passive client takes no drop and no ⌘V either: they are the browser's (and the refusal's).
      const e = fire(r.textarea, "paste", "clipboardData", transfer({ files: [file("a.png", 2, "image/png")] }));
      expect(e.defaultPrevented).toBe(false);
      expect(r.deliveries).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("PasteUI — what a delivery says (§2.6)", () => {
  let r: ReturnType<typeof rig>;
  afterEach(() => r?.ac.abort());

  // FAILURES STAY UNTIL THE NEXT NOTE (§2.6): a failure is written by `fail` — the note that stays — never the
  // flashing `note`, which would take it away six seconds later while the person may be looking elsewhere.
  it("a failure leaves its note, one that STAYS; a cancel says nothing; a success's word still flashes", async () => {
    r = rig({ outcome: { ok: false, reason: "disk" } });
    fire(r.textarea, "drop", "dataTransfer", transfer({ files: [file("a.jpg", 1)] }));
    await settle();
    expect(r.s.fails).toEqual(["Not pasted: the Mac could not save it"]);
    expect(r.s.notes).toEqual([]);
    r.uploader.outcome = { ok: false, reason: "cancelled" };
    fire(r.textarea, "drop", "dataTransfer", transfer({ files: [file("a.jpg", 1)] }));
    await settle();
    expect(r.s.fails).toEqual(["Not pasted: the Mac could not save it"]);
    r.uploader.outcome = { ok: true, how: "paste" };
    r.ui.windowDrop("win:7", { x: 0.5, y: 0.5 }, transfer({ text: "hi" }));
    await settle();
    expect(r.s.notes).toEqual(["Dropped as a paste"]);
    expect(r.s.fails).toEqual(["Not pasted: the Mac could not save it"]);
  });
  it("a Mac that never acknowledged the delivery: the note that STAYS says it may need updating", async () => {
    r = rig({ outcome: { ok: false, reason: "unanswered" } });
    fire(r.textarea, "drop", "dataTransfer", transfer({ files: [file("a.jpg", 1)] }));
    await settle();
    expect(r.s.fails).toEqual(["Not pasted: the Mac did not answer — Xpromptvs there may need updating"]);
    expect(r.s.notes).toEqual([]);
    expect(r.s.progress).toEqual([null]);         // the "Sending…" note goes as the failure's comes
  });
  it("progress names the delivery, at most ten notes a second, and always its last", () => {
    r = rig();
    const d: Delivery = { to: { term: "pty:1" }, items: [{ kind: "file", name: "IMG_0042.jpg", type: "image/jpeg", blob: sized(100) }] };
    vi.useFakeTimers();
    try {
      vi.setSystemTime(10_000);
      r.ui.progress(10, 100, d);
      r.ui.progress(20, 100, d);
      vi.setSystemTime(10_150);
      r.ui.progress(40, 100, d);
      r.ui.progress(100, 100, d);
    } finally {
      vi.useRealTimers();
    }
    expect(r.s.progress).toEqual(["Sending IMG_0042.jpg — 10%", "Sending IMG_0042.jpg — 40%", "Sending IMG_0042.jpg — waiting for the Mac…"]);
    r.ac.abort();
    r.ui.progress(100, 100, d);
    expect(r.s.progress).toHaveLength(3);         // the session is gone, and its note with it
  });
  it("a window drop carries its point, and a drop the Mac took as a paste says so", async () => {
    r = rig();
    r.ui.windowDrop("win:7", { x: 0.25, y: 0.5 }, transfer({ text: "hello" }));
    await settle();
    expect(r.deliveries).toEqual([{ to: { win: "win:7" }, at: { x: 0.25, y: 0.5 }, items: [{ kind: "text", text: "hello" }] }]);
    expect(r.s.notes).toEqual(["Dropped as a paste"]);
    r.uploader.outcome = { ok: true, how: "drop" };
    r.ui.windowDrop("win:7", { x: 0.1, y: 0.1 }, transfer({ files: [file("a.jpg", 3)] }));
    await settle();
    expect(r.deliveries[1]).toMatchObject({ to: { win: "win:7" }, at: { x: 0.1, y: 0.1 } });
    expect(r.s.notes).toEqual(["Dropped as a paste"]);
  });
  it("the window menu's Paste goes to THAT window", async () => {
    r = rig();
    setClipboard(async () => [clipItem({ "text/plain": textBlob("a\nb") })]);
    r.ui.openWindowMenu("win:9", { x: 1, y: 1 });
    pick("paste");
    await settle();
    expect(r.s.questions).toEqual([]);            // a window's paste is the Mac's ⌘V, not a terminal's
    expect(r.deliveries).toEqual([{ to: { win: "win:9" }, items: [{ kind: "text", text: "a\nb" }] }]);
  });
});

// A TAB'S MENU (2026-10-02, "I see no way to paste into windows on mobile"): on a phone a window's titlebar is
// all controls, so every tab's menu carries the paste items too — the SAME items, for the tab it was opened on.
describe("PasteUI — a tab's menu", () => {
  let r: ReturnType<typeof rig>;
  afterEach(() => { r?.ac.abort(); vi.useRealTimers(); });

  it("offers exactly the terminal menu's items: Paste only with a clipboard to read, Stop sending only while sending", () => {
    r = rig();
    setClipboard(async () => []);
    expect(r.ui.menuItems().map((i) => i.label)).toEqual(["Paste", "Paste Image/File…"]);
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    expect(r.ui.menuItems().map((i) => i.label)).toEqual(items());
    setClipboard(undefined);
    expect(r.ui.menuItems().map((i) => i.label)).toEqual(["Paste Image/File…"]);
    r.uploader.busy = true;
    expect(r.ui.menuItems().map((i) => i.label)).toEqual(["Paste Image/File…", "Stop sending"]);
    r.ui.pickForTab("win:9", "stop");
    expect(r.uploader.cancel).toHaveBeenCalledTimes(1);
  });

  it("a WINDOW tab's Paste goes to THAT window: text as text, an image as a file — and switches nothing", async () => {
    r = rig();
    setClipboard(async () => [clipItem({ "text/plain": textBlob("a\nb") })]);
    r.ui.pickForTab("win:9", "paste");
    await settle();
    expect(r.deliveries).toEqual([{ to: { win: "win:9" }, items: [{ kind: "text", text: "a\nb" }] }]);
    expect(r.s.questions).toEqual([]);            // a window's paste is the Mac's ⌘V, not a terminal's
    const img = png(5);
    setClipboard(async () => [clipItem({ "image/png": img })]);
    r.ui.pickForTab("dsp:2", "paste");
    await settle();
    expect(r.deliveries[1]).toEqual({ to: { win: "dsp:2" }, items: [{ kind: "file", name: "pasted.png", type: "image/png", blob: img }] });
    expect([r.s.shown, r.s.pasted]).toEqual([[], []]);
  });

  it("a WINDOW tab's Paste Image/File… is ONE delivery to that window", async () => {
    const a = file("IMG_1.jpg", 4), b = file("notes.pdf", 9, "application/pdf");
    r = rig({ pick: async () => [a, b] });
    r.ui.pickForTab("win:9", "file");
    await settle();
    expect(r.deliveries).toHaveLength(1);
    expect(r.deliveries[0]!.to).toEqual({ win: "win:9" });
    expect(r.deliveries[0]!.items.map((i) => (i.kind === "file" ? i.name : "?"))).toEqual(["IMG_1.jpg", "notes.pdf"]);
  });

  // The host types a delivery's paths into the tab it NAMES, shown or not (docs/terminal.md) — no switch.
  it("a TERMINAL tab's Paste Image/File…, and a clipboard image, go to THAT tab even when it is not the visible one", async () => {
    r = rig({ tabs: ["pty:1", "tmux:$2"], pick: async () => [file("a.jpg", 2)] });
    r.ui.pickForTab("tmux:$2", "file");
    await settle();
    const img = png(4);
    setClipboard(async () => [clipItem({ "image/png": img, "text/plain": textBlob("https://example.com/a.png") })]);
    r.ui.pickForTab("tmux:$2", "paste");
    await settle();
    expect(r.deliveries.map((d) => d.to)).toEqual([{ term: "tmux:$2" }, { term: "tmux:$2" }]);
    expect(r.deliveries[1]!.items).toEqual([{ kind: "file", name: "pasted.png", type: "image/png", blob: img }]);
    expect([r.s.shown, r.s.pasted]).toEqual([[], []]);
  });

  it("TEXT into the VISIBLE terminal tab is pasted at once, through xterm.js's paste — the tab shown as a tap shows it", async () => {
    r = rig({ tabs: ["pty:1", "pty:2"] });
    setClipboard(async () => [clipItem({ "text/plain": textBlob("ls -la") })]);
    r.ui.pickForTab("pty:1", "paste");
    await settle();
    expect(r.s.pasted).toEqual(["ls -la"]);
    expect(r.s.shown).toEqual(["pty:1"]);
    expect([r.deliveries, r.s.fails]).toEqual([[], []]);
  });

  // Typing goes through the VISIBLE tab's instance, and the host DROPS a keystroke naming a tab it does not
  // have active (docs/terminal.md): a hidden tab is switched to first, and the text waits for BOTH ends.
  it("TEXT into a HIDDEN terminal tab: the clipboard is read in the click, the tab switched to, and the text pasted only once the deck AND the host show it", async () => {
    vi.useFakeTimers();
    let give!: (v: unknown) => void;
    const read = vi.fn(() => new Promise((res) => { give = res; }));
    r = rig({ tabs: ["pty:1", "pty:2"] });
    setClipboard(read);
    r.ui.pickForTab("pty:2", "paste");
    expect(read).toHaveBeenCalledTimes(1);          // SYNCHRONOUSLY, inside the item's click
    expect(r.s.shown).toEqual([]);                  // ...and nothing switched before the clipboard answered
    give([clipItem({ "text/plain": textBlob("a\nb") })]);
    await vi.advanceTimersByTimeAsync(0);
    expect(r.s.shown).toEqual(["pty:2"]);
    r.s.visible = "pty:2";                          // the deck shows it at once...
    await vi.advanceTimersByTimeAsync(300);
    expect([r.s.pasted, r.s.questions]).toEqual([[], []]);   // ...but the host's active tab is still pty:1
    r.s.active = "pty:2";                           // its term-list lands
    await vi.advanceTimersByTimeAsync(100);
    expect(r.s.questions).toEqual([MULTILINE_QUESTION(2)]);  // asked about the tab now on screen
    expect(r.s.pasted).toEqual(["a\nb"]);
    expect([r.deliveries, r.s.fails]).toEqual([[], []]);
  });

  it("a switch that never lands within 2 s types nothing and SAYS so — in a note that stays", async () => {
    vi.useFakeTimers();
    r = rig({ tabs: ["pty:1", "pty:2"] });
    setClipboard(async () => [clipItem({ "text/plain": textBlob("make") })]);
    r.ui.pickForTab("pty:2", "paste");
    await vi.advanceTimersByTimeAsync(0);
    r.s.visible = "pty:2";                          // the host never confirms
    await vi.advanceTimersByTimeAsync(1900);
    expect(r.s.fails).toEqual([]);
    await vi.advanceTimersByTimeAsync(200);
    expect(r.s.pasted).toEqual([]);
    expect(r.s.fails).toEqual(["Not pasted: the Mac did not switch to that tab"]);
    expect(r.s.notes).toEqual([]);
    expect(vi.getTimerCount()).toBe(0);
  });

  // The person moving on is not a failure of the Mac's: blaming it would be false.
  it("a person who switches to ANOTHER tab during the wait gets nothing typed and no note", async () => {
    vi.useFakeTimers();
    r = rig({ tabs: ["pty:1", "pty:2", "pty:3"] });
    setClipboard(async () => [clipItem({ "text/plain": textBlob("make") })]);
    r.ui.pickForTab("pty:2", "paste");
    await vi.advanceTimersByTimeAsync(0);
    r.s.visible = "pty:2";
    await vi.advanceTimersByTimeAsync(500);
    r.s.visible = "pty:3";                          // a tap on another tab; the host follows it
    r.s.active = "pty:3";
    await vi.advanceTimersByTimeAsync(2000);
    expect([r.s.pasted, r.s.fails, r.s.notes]).toEqual([[], [], []]);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("a tab that closes — before the clipboard answers, or during the wait — is said to have closed, and nothing is typed", async () => {
    vi.useFakeTimers();
    r = rig({ tabs: ["pty:1", "pty:2"] });
    setClipboard(async () => { r.s.tabs = ["pty:1"]; return [clipItem({ "text/plain": textBlob("make") })]; });
    r.ui.pickForTab("pty:2", "paste");
    await vi.advanceTimersByTimeAsync(0);
    expect(r.s.shown).toEqual([]);                  // a switch to a tab that is gone would show nothing
    expect(r.s.fails).toEqual(["Not pasted: that tab or window has closed"]);
    r.s.tabs = ["pty:1", "pty:2"];
    setClipboard(async () => [clipItem({ "text/plain": textBlob("make") })]);
    r.ui.pickForTab("pty:2", "paste");
    await vi.advanceTimersByTimeAsync(0);
    r.s.tabs = ["pty:1"];                           // its shell exited mid-switch
    await vi.advanceTimersByTimeAsync(100);
    expect(r.s.fails).toEqual(["Not pasted: that tab or window has closed", "Not pasted: that tab or window has closed"]);
    expect(r.s.pasted).toEqual([]);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("control moving away during the wait types nothing and says why; the session ending leaves nothing behind", async () => {
    vi.useFakeTimers();
    r = rig({ tabs: ["pty:1", "pty:2"] });
    setClipboard(async () => [clipItem({ "text/plain": textBlob("make") })]);
    r.ui.pickForTab("pty:2", "paste");
    await vi.advanceTimersByTimeAsync(0);
    r.s.enabled = false;
    await vi.advanceTimersByTimeAsync(100);
    expect(r.s.fails).toEqual(["Not pasted: control moved to another device"]);
    r.s.enabled = true;
    r.ui.pickForTab("pty:2", "paste");
    await vi.advanceTimersByTimeAsync(0);
    r.ac.abort();
    await vi.advanceTimersByTimeAsync(3000);
    expect(r.s.pasted).toEqual([]);
    expect(r.s.fails).toHaveLength(1);
    expect(vi.getTimerCount()).toBe(0);
  });
});

// WHICH TABS OFFER THE PASTE ITEMS. The host resolves a window target only at the delivery's END
// (`SimManager.pasteTarget`) and refuses a MINIMIZED window — offered on its tab, a person would upload up to
// 1 GB to read that the window "has closed". A minimized window has no titlebar, so its tab is the only way
// there was to ask.
describe("tabTakesPaste — which tabs' menus offer the paste items", () => {
  const windows = [{ source: "win:7", minimized: false }, { source: "win:8", minimized: true }, { source: "dsp:1", minimized: false }];
  it("every terminal tab does", () => {
    expect(tabTakesPaste("pty:1", { windowless: false, windows })).toBe(true);
    expect(tabTakesPaste("tmux:$2", { windowless: true, windows: [] })).toBe(true);
  });
  it("a window tab does while its window is open, a display's too", () => {
    expect(tabTakesPaste("win:7", { windowless: false, windows })).toBe(true);
    expect(tabTakesPaste("dsp:1", { windowless: false, windows })).toBe(true);
  });
  it("a MINIMIZED window's tab does not, nor one the session does not list", () => {
    expect(tabTakesPaste("win:8", { windowless: false, windows })).toBe(false);
    expect(tabTakesPaste("win:9", { windowless: false, windows })).toBe(false);
  });
  it("a window-less session offers no window target; a key of no kind offers nothing", () => {
    expect(tabTakesPaste("win:7", { windowless: true, windows })).toBe(false);
    expect(tabTakesPaste("\u0000static", { windowless: false, windows })).toBe(false);
  });
});

// WHAT WAS COPIED IN FINDER, INSIDE THE APP (2026-10-02, "when pasting directories from the mac into the app, it
// says 'nothing to paste'"): a page is never told a path and a FOLDER reaches it as a 0-byte file, so the app
// says what was copied (`local`). On THIS Mac a path is a path there; to another Mac the person chooses.
describe("PasteUI — a folder copied in Finder (the app)", () => {
  let r: ReturnType<typeof rig>;
  afterEach(() => r?.ac.abort());
  const folder = (name: string, path = `/Users/me/${name}`): LocalFile => ({ path, name, dir: true });
  const plain = (name: string, path = `/Users/me/${name}`): LocalFile => ({ path, name, dir: false });
  /// Finder's copy as WebKit hands it to the page: a 0-byte, untyped File per item.
  const finder = (...names: string[]) => transfer({ files: names.map((n) => new File([], n)) });
  function app(copied: LocalFile[], prepared: PreparedFile[] = [], o: { refuse?: string; later?: boolean } = {}) {
    const calls = { prepare: [] as (readonly string[])[], discard: [] as (readonly string[])[], read: [] as string[], cancel: 0 };
    /// With `later`, the app's prepare answers only when the test says (`finish`), as a big zip does.
    let finish: (() => void) | null = null;
    const api: LocalPasteApi = {
      files: async () => copied,
      prepare: async (paths) => {
        calls.prepare.push(paths);
        if (o.later) await new Promise<void>((res) => { finish = res; });
        if (o.refuse) throw new Error(o.refuse);
        return prepared;
      },
      discard: (urls) => { calls.discard.push(urls); },
      read: async (url) => { calls.read.push(url); return new Blob([new Uint8Array(4)]); },
      cancel: () => { calls.cancel++; },
    };
    return { api, calls, finish: () => finish?.() };
  }
  const zip = (name: string, size: number): PreparedFile => ({ url: `app://client/__paste/t-${name}/${name}`, name, type: "application/zip", size });

  it("on THIS Mac, ⌘V of a folder types its path — quoted as the host types a file's, each path its own paste", async () => {
    const a = app([folder("My Projects")]);
    r = rig({ local: a.api, sameMac: true });
    const e = fire(r.textarea, "paste", "clipboardData", finder("My Projects"));
    await settle();
    expect(e.defaultPrevented).toBe(true);
    expect(r.s.pasted).toEqual(["'/Users/me/My Projects' "]);
    expect(r.deliveries).toEqual([]);
    expect([r.s.asked, r.s.notes, r.s.fails]).toEqual([[], [], []]);
  });
  it("on THIS Mac, a folder with files beside it types every path, in order", async () => {
    const a = app([folder("Proj"), plain("notes.txt")]);
    r = rig({ local: a.api, sameMac: true });
    fire(r.textarea, "paste", "clipboardData", finder("Proj", "notes.txt"));
    await settle();
    expect(r.s.pasted).toEqual(["/Users/me/Proj ", "/Users/me/notes.txt "]);
    expect(a.calls.prepare).toEqual([]);
  });
  it("⌘V of FILES alone is uploaded as before, in the app too; in a browser a folder is still nothing to paste", async () => {
    const a = app([plain("a.jpg")]);
    r = rig({ local: a.api, sameMac: true });
    fire(r.textarea, "paste", "clipboardData", transfer({ files: [file("a.jpg", 3)] }));
    await settle();
    expect(r.deliveries).toHaveLength(1);
    expect(r.s.pasted).toEqual([]);
    r.ac.abort();
    r = rig();
    fire(r.textarea, "paste", "clipboardData", finder("Proj"));
    await settle();
    expect(r.s.notes).toEqual(["Nothing to paste"]);
  });
  it("to ANOTHER Mac a folder asks; Paste the path types this Mac's path and sends nothing", async () => {
    const a = app([folder("Projects")]);
    r = rig({ local: a.api, choose: "path" });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    expect(r.s.asked).toEqual(["Paste “Projects”"]);
    expect(r.s.pasted).toEqual(["/Users/me/Projects "]);
    expect([r.deliveries, a.calls.prepare]).toEqual([[], []]);
  });
  it("Compress and send says it is compressing, then sends the zip to the visible tab — a small one without asking", async () => {
    const a = app([folder("Projects")], [zip("Projects.zip", 2048)]);
    r = rig({ local: a.api, choose: "send" });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    expect(a.calls.prepare).toEqual([["/Users/me/Projects"]]);
    expect(r.s.progress.slice(0, 2)).toEqual(["Compressing Projects…", null]);
    expect(a.calls.read).toEqual(["app://client/__paste/t-Projects.zip/Projects.zip"]);
    expect(r.deliveries).toHaveLength(1);
    expect(r.deliveries[0]).toMatchObject({ to: { term: "pty:1" }, items: [{ kind: "file", name: "Projects.zip", type: "application/zip" }] });
    expect(r.s.questions).toEqual([]);
  });
  it("over 50 MB it warns with the size first: no sends nothing and discards the zip; yes sends it, asking once", async () => {
    const a = app([folder("Projects")], [zip("Projects.zip", 73 * 1024 * 1024)]);
    r = rig({ local: a.api, choose: "send", answer: false });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    expect(r.s.questions).toEqual(["Send Projects.zip? It is 73 MB, so it may take a while."]);
    expect(r.s.yeses).toEqual(["Send"]);
    expect([a.calls.read, r.deliveries]).toEqual([[], []]);
    expect(a.calls.discard).toEqual([["app://client/__paste/t-Projects.zip/Projects.zip"]]);
    r.ac.abort();
    const b = app([folder("Projects")], [zip("Projects.zip", 73 * 1024 * 1024)]);
    r = rig({ local: b.api, choose: "send", answer: true });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    expect(r.s.questions).toHaveLength(1);
    expect(r.deliveries).toHaveLength(1);
  });
  it("the zip goes to the tab the paste was MADE in, though another is on screen when it is ready", async () => {
    const a = app([folder("Projects")], [zip("Projects.zip", 10)], { later: true });
    r = rig({ local: a.api, choose: "send", tabs: ["pty:1", "pty:2"] });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    r.s.visible = "pty:2"; r.s.active = "pty:2";              // the person moved on while it compressed
    a.finish();
    await settle();
    expect(r.deliveries).toHaveLength(1);
    expect(r.deliveries[0]!.to).toEqual({ term: "pty:1" });
  });
  it("Stop sending is offered while the app compresses, and stops it — saying nothing; the session ending stops it too", async () => {
    const a = app([folder("Projects")], [zip("Projects.zip", 10)], { later: true, refuse: "cancelled" });
    r = rig({ local: a.api, choose: "send" });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    expect(items()).toContain("Stop sending");
    pick("stop");
    expect(a.calls.cancel).toBe(1);
    a.finish();
    await settle();
    expect([r.s.fails, r.s.notes, r.deliveries]).toEqual([[], [], []]);
    expect(r.s.progress).toEqual(["Compressing Projects…", null]);
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    expect(items()).not.toContain("Stop sending");
    r.ac.abort();
    const b = app([folder("Projects")], [zip("Projects.zip", 10)], { later: true });
    r = rig({ local: b.api, choose: "send" });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    r.ac.abort();
    expect(b.calls.cancel).toBe(1);
  });
  it("a folder that compresses past 1 GB is stopped by the app and said so; more than 32 items are refused before it starts", async () => {
    const a = app([folder("Huge")], [], { refuse: "too-large" });
    r = rig({ local: a.api, choose: "send" });
    fire(r.textarea, "paste", "clipboardData", finder("Huge"));
    await settle();
    expect(r.s.fails).toEqual(["Not pasted: Huge is larger than 1 GB compressed"]);
    r.ac.abort();
    const many = Array.from({ length: 33 }, (_, i) => folder(`f${i}`));
    const b = app(many);
    r = rig({ local: b.api, choose: "send" });
    fire(r.textarea, "paste", "clipboardData", finder("f0"));
    await settle();
    expect(b.calls.prepare).toEqual([]);
    expect(r.s.fails).toEqual(["Not pasted: too much at once — 1 GB and 32 files at most"]);
  });
  it("the warning is for the whole paste: two zips of 30 MB ask, by their total", async () => {
    const a = app([folder("A"), folder("B")], [zip("A.zip", 30 * 1024 * 1024), zip("B.zip", 30 * 1024 * 1024)]);
    r = rig({ local: a.api, choose: "send", answer: true });
    fire(r.textarea, "paste", "clipboardData", finder("A", "B"));
    await settle();
    expect(r.s.questions).toEqual(["Send 2 files? They are 60 MB, so they may take a while."]);
    expect(r.deliveries).toHaveLength(1);
  });
  it("over 1 GB it is refused before a byte is read, and the zip discarded", async () => {
    const a = app([folder("Big")], [zip("Big.zip", 1024 * 1024 * 1024 + 1)]);
    r = rig({ local: a.api, choose: "send" });
    fire(r.textarea, "paste", "clipboardData", finder("Big"));
    await settle();
    expect(r.s.fails).toEqual(["Not pasted: Big.zip is larger than 1 GB"]);
    expect([a.calls.read, r.deliveries, r.s.questions]).toEqual([[], [], []]);
    expect(a.calls.discard).toHaveLength(1);
  });
  it("Cancel does nothing and says nothing; a folder the app could not compress says so", async () => {
    const a = app([folder("Projects")]);
    r = rig({ local: a.api, choose: null });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    expect([r.s.pasted, r.deliveries, r.s.notes, r.s.fails, a.calls.prepare]).toEqual([[], [], [], [], []]);
    r.ac.abort();
    const b = app([folder("Projects")], [], { refuse: "zip failed" });
    r = rig({ local: b.api, choose: "send" });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    expect(r.s.fails).toEqual(["Not pasted: Xpromptvs could not compress Projects"]);
    expect(r.s.progress).toEqual(["Compressing Projects…", null]);
  });
  it("control moving away while the question is up types and sends nothing, and says why", async () => {
    const a = app([folder("Projects")]);
    let answer!: (c: "path" | "send" | null) => void;
    r = rig({ local: a.api });
    (r.ui as unknown as { deps: PasteUIDeps }).deps.chooseFolder = () => new Promise((res) => { answer = res; });
    fire(r.textarea, "paste", "clipboardData", finder("Projects"));
    await settle();
    r.s.enabled = false;
    answer("path");
    await settle();
    expect([r.s.pasted, r.deliveries]).toEqual([[], []]);
    expect(r.s.fails).toEqual(["Not pasted: control moved to another device"]);
  });
  it("the menu's Paste asks the app first: a folder for a WINDOW is its path as text, or its zip — and Finder's icon never wins", async () => {
    const a = app([folder("Projects")], [zip("Projects.zip", 10)]);
    r = rig({ local: a.api, choose: "path" });
    setClipboard(async () => [clipItem({ "image/png": png(), "text/plain": textBlob("Projects") })]);
    r.ui.openWindowMenu("win:9", { x: 1, y: 1 });
    pick("paste");
    await settle();
    expect(r.deliveries).toEqual([{ to: { win: "win:9" }, items: [{ kind: "text", text: "/Users/me/Projects" }] }]);
    r.ac.abort();
    const b = app([folder("Projects")], [zip("Projects.zip", 10)]);
    r = rig({ local: b.api, choose: "send" });
    setClipboard(async () => [clipItem({ "image/png": png() })]);
    r.ui.openWindowMenu("win:9", { x: 1, y: 1 });
    pick("paste");
    await settle();
    expect(r.deliveries).toHaveLength(1);
    expect(r.deliveries[0]).toMatchObject({ to: { win: "win:9" }, items: [{ kind: "file", name: "Projects.zip" }] });
  });
  it("the menu's Paste of FILES copied in Finder sends the files themselves, not the icon Finder copies beside them", async () => {
    const a = app([plain("report.pdf")], [{ url: "app://client/__paste/t/report.pdf", name: "report.pdf", type: "application/pdf", size: 5 }]);
    r = rig({ local: a.api });
    setClipboard(async () => [clipItem({ "image/png": png() })]);
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("paste");
    await settle();
    expect(r.s.asked).toEqual([]);
    expect(r.s.progress).not.toContain("Compressing report.pdf…");
    expect(r.deliveries).toHaveLength(1);
    expect(r.deliveries[0]).toMatchObject({ to: { term: "pty:1" }, items: [{ kind: "file", name: "report.pdf", type: "application/pdf" }] });
  });
  it("the menu's Paste with nothing copied in Finder is the clipboard's, as before", async () => {
    const a = app([]);
    r = rig({ local: a.api });
    setClipboard(async () => [clipItem({ "text/plain": textBlob("echo hi") })]);
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("paste");
    await settle();
    expect(r.s.pasted).toEqual(["echo hi"]);
  });
  it("on THIS Mac a TAB's menu types a folder's path into THAT tab, switched to first as text is", async () => {
    const a = app([folder("Proj")]);
    r = rig({ local: a.api, sameMac: true, tabs: ["pty:1", "pty:2"] });
    setClipboard(async () => [clipItem({ "image/png": png() })]);
    r.ui.pickForTab("pty:2", "paste");
    await settle();
    expect(r.s.shown).toEqual(["pty:2"]);
    expect(r.s.pasted).toEqual([]);
    r.s.visible = "pty:2"; r.s.active = "pty:2";
    await new Promise((res) => setTimeout(res, 120));
    expect(r.s.pasted).toEqual(["/Users/me/Proj "]);
  });
});

// A BIG PASTE IS SENT AFTER A WARNING, NOT REFUSED (2026-10-02, asked for a compressed folder; every file follows
// the same rule, or zipping a file would be the way around a cap): over 50 MB the person is told its size first.
describe("PasteUI — a big paste", () => {
  let r: ReturnType<typeof rig>;
  afterEach(() => r?.ac.abort());
  /// A file that only says how big it is (`size` is a getter: defined, never assigned).
  const big = (name: string, size: number) => {
    const f = new File([], name, { type: "video/quicktime" });
    Object.defineProperty(f, "size", { value: size });
    return f;
  };
  it("a file over 50 MB — dropped, ⌘V'd or picked — asks with its size; no sends nothing, yes sends it", async () => {
    r = rig({ answer: false });
    fire(r.textarea, "drop", "dataTransfer", transfer({ files: [big("IMG.mov", 312 * 1024 * 1024)] }));
    await settle();
    expect(r.s.questions).toEqual(["Send IMG.mov? It is 312 MB, so it may take a while."]);
    expect(r.s.yeses).toEqual(["Send"]);
    expect(r.deliveries).toEqual([]);
    r.ac.abort();
    r = rig({ answer: true, pick: async () => [big("a.mov", 20 * 1024 * 1024), big("b.mov", 20 * 1024 * 1024)] });
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("file");
    await settle();
    expect(r.s.questions).toEqual([]);              // 40 MB in all: nothing to warn about
    expect(r.deliveries).toHaveLength(1);
  });
  it("files each under 50 MB that come to more ask too: the warning is the paste's, not a file's", async () => {
    r = rig({ answer: false, pick: async () => [big("a.mov", 30 * 1024 * 1024), big("b.mov", 30 * 1024 * 1024)] });
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("file");
    await settle();
    expect(r.s.questions).toEqual(["Send 2 files? They are 60 MB, so they may take a while."]);
    expect(r.deliveries).toEqual([]);
  });
  it("one of several over 50 MB asks for all of them, by their total", async () => {
    r = rig({ answer: true, pick: async () => [big("a.mov", 60 * 1024 * 1024), file("b.jpg", 3)] });
    r.ui.openTerminalMenu({ x: 1, y: 1 });
    pick("file");
    await settle();
    expect(r.s.questions).toEqual(["Send 2 files? They are 60 MB, so they may take a while."]);
    expect(r.deliveries).toHaveLength(1);
  });
});

// A FINGER'S SELECTION (touch-selection.ts): a hold on text selects its word, and the menu leads with Copy.
describe("the terminal hold with a touch selection", () => {
  let r: ReturnType<typeof rig> | null = null;
  afterEach(() => { r?.ac.abort(); r = null; document.body.innerHTML = ""; vi.useRealTimers(); });
  const fakeSelection = (selects: boolean) => {
    const sel = {
      active: false, busy: false, closed: 0,
      holdAt: vi.fn(() => { sel.active = selects; return selects; }),
      text: () => (sel.active ? "DESKTOP" : ""),
      anchor: () => (sel.active ? new DOMRect(40, 200, 70, 16) : null),
      owns: () => false,
      menuClosed: () => { sel.closed++; sel.active = false; },
    };
    return sel;
  };
  it("a hold on text: Copy first, then the paste items; Copy writes the selection and says so; the menu closing ends it", () => {
    vi.useFakeTimers();
    const sel = fakeSelection(true);
    const copied: string[] = [];
    r = rig({ selection: () => sel, copy: (t) => { copied.push(t); } });
    r.textarea.dispatchEvent(touch("pointerdown", 60, 208));
    vi.advanceTimersByTime(HOLD_MS);
    expect(sel.holdAt).toHaveBeenCalledWith({ x: 60, y: 208 });
    expect(items()[0]).toBe("Copy");
    expect(items().slice(1)).toEqual(r.ui.menuItems().map((i) => i.label));
    window.dispatchEvent(touch("pointerup", 60, 208));
    pick("copy");
    expect(copied).toEqual(["DESKTOP"]);
    expect(r.s.notes).toEqual(["Copied"]);
    expect(r.ui.menu.isOpen).toBe(false);
    // A browser fires `toggle` as a popover closes (this file's stub does not): the menu's `onClosed`.
    const ev = new Event("toggle");
    (ev as unknown as { newState: string }).newState = "closed";
    document.querySelector(".ctx-menu")!.dispatchEvent(ev);
    expect(sel.closed, "the menu closing took the selection").toBe(1);
  });
  it("a hold on the terminal's SCROLLBAR opens nothing — the rail drags itself (touch-scroll.ts onTerminalScrollbar)", () => {
    vi.useFakeTimers();
    const sel = fakeSelection(true);
    r = rig({ selection: () => sel, copy: () => {} });
    const rail = document.createElement("div");
    rail.className = "terminal-scrollbar";
    const thumb = document.createElement("div");
    thumb.className = "terminal-scrollbar-thumb";
    rail.append(thumb);
    r.term.append(rail);
    thumb.dispatchEvent(touch("pointerdown", 300, 120));
    vi.advanceTimersByTime(HOLD_MS * 2);
    expect(r.ui.menu.isOpen).toBe(false);
    expect(sel.holdAt).not.toHaveBeenCalled();
    window.dispatchEvent(touch("pointerup", 300, 120));
  });
  it("a hold on blank space: the paste menu alone, as before", () => {
    vi.useFakeTimers();
    const sel = fakeSelection(false);
    r = rig({ selection: () => sel, copy: () => {} });
    r.textarea.dispatchEvent(touch("pointerdown", 60, 208));
    vi.advanceTimersByTime(HOLD_MS);
    expect(r.ui.menu.isOpen).toBe(true);
    expect(items()).not.toContain("Copy");
  });
});
