import { openClientDialog, closeClientDialog } from "./instance/overlays";
// **THE CLIENT'S HALF OF AN IMAGE PATH OPENING** (2026-10-05, asked for: "add image preview functionality. when tapping
// a path (highlight it), it should open on the client if exists"; docs/terminal.md, "An image path opens on the
// client"). A tapped path (term-paths.ts) becomes a `file-get` to the host, which answers with the image in pieces
// (`file-begin`, `file-data`…, `file-end`) or one `file-error`. Nothing opens for a path that names no image: a note
// says why. Once the image has arrived and decoded, a modal shows it — over the session — until closed.

/// No `file-begin` within this: the Mac did not answer (an older one that does not know `file-get`, a dead link).
export const FILE_ANSWER_MS = 15_000;
/// No piece within this, once begun: the transfer stalled.
export const FILE_STALL_MS = 15_000;

export interface FileViewerDeps {
  /// Send a message to the host — on `bulk` (session.ts, `sendBulk`), where the file's pieces come back.
  send(msg: object): void;
  /// A note that stays until cleared (its mark), and one that goes by itself (status-note.ts).
  showNote(text: string): number;
  clearNote(mark: number): void;
  flashNote(text: string): void;
  /// Where the modal is mounted (the session's own markup, so it goes with the session).
  root: HTMLElement;
  timers?: { set(fn: () => void, ms: number): unknown; clear(t: unknown): void };
}

interface Pending {
  id: string; path: string; name: string; timer: unknown;
  begun?: { mime: string; size: number; resolved: string; parts: Uint8Array[]; got: number; next: number };
}

/// What a `file-error` says, in words.
export function fileErrorText(reason: string, path: string): string {
  switch (reason) {
    case "not-found": return `No such file: ${path}`;
    case "not-image": return `Not an image: ${path}`;
    case "too-large": return `Too large to preview (over 20 MB): ${path}`;
    case "unreadable": return `Could not read ${path}`;
    case "not-driver": return "Only the device in control can open files";
    default: return `Could not open ${path}`;
  }
}

const baseName = (p: string) => p.replace(/\/+$/, "").split("/").pop() || p;

export class FileViewer {
  private seq = 0;
  private pending: Pending | null = null;
  private dialog: HTMLDialogElement | null = null;
  private url: string | null = null;
  private readonly timers: NonNullable<FileViewerDeps["timers"]>;

  constructor(private readonly deps: FileViewerDeps) {
    this.timers = deps.timers ?? { set: (fn, ms) => setTimeout(fn, ms), clear: (t) => clearTimeout(t as ReturnType<typeof setTimeout>) };
  }

  /// Ask for the image `path` names, printed in tab `tab`. A request still on its way is dropped for this one.
  open(tab: string, path: string): void {
    this.close();
    const id = `f${++this.seq}`;
    const name = baseName(path);
    this.pending = { id, path, name, timer: this.arm(id, FILE_ANSWER_MS, "The Mac did not answer") };
    this.deps.send({ t: "file-get", id, term: tab, path });
  }

  /// A control message: TRUE when it was this viewer's (`file-*`), handled or stale.
  handle(msg: unknown): boolean {
    const m = msg as { t?: unknown; id?: unknown } | null;
    if (!m || typeof m.t !== "string" || !m.t.startsWith("file-")) return false;
    const p = this.pending;
    if (!p || m.id !== p.id) return true;                  // a request since dropped
    const any = m as Record<string, unknown>;
    switch (m.t) {
      case "file-error":
        this.fail(fileErrorText(String(any.reason), p.path));
        return true;
      case "file-begin": {
        if (p.begun) return true;
        const size = Number(any.size), mime = String(any.mime ?? "");
        if (!Number.isInteger(size) || size < 0 || !mime.startsWith("image/")) { this.fail(`Could not open ${p.path}`); return true; }
        p.begun = { mime, size, resolved: String(any.path ?? p.path), parts: [], got: 0, next: 0 };
        this.rearm(p, FILE_STALL_MS);
        if (typeof any.name === "string") p.name = any.name;
        return true;
      }
      case "file-data": {
        const b = p.begun;
        if (!b || any.seq !== b.next || typeof any.data !== "string") { if (b) this.fail(`Could not open ${p.path}`); return true; }
        let bytes: Uint8Array;
        try { bytes = Uint8Array.from(atob(any.data), (c) => c.charCodeAt(0)); } catch { this.fail(`Could not open ${p.path}`); return true; }
        b.parts.push(bytes); b.got += bytes.length; b.next++;
        if (b.got > b.size) { this.fail(`Could not open ${p.path}`); return true; }
        this.rearm(p, FILE_STALL_MS);
        return true;
      }
      case "file-end": {
        const b = p.begun;
        if (!b || b.got !== b.size) { this.fail(`Could not open ${p.path}`); return true; }
        this.timers.clear(p.timer);
        this.pending = null;
        this.picture(new Blob(b.parts as BlobPart[], { type: b.mime }),p.name,b.resolved);
        return true;
      }
      default:
        return true;
    }
  }

  /// The modal goes (and the image with it); a request on its way is dropped.
  close(): void {
    this.abandon();
    if (this.dialog?.open) closeClientDialog(this.dialog);
    this.release();
  }

  dispose(): void {
    this.close();
    this.dialog?.remove();
    this.dialog = null;
  }

  private abandon(): void {
    const p = this.pending;
    if (!p) return;
    this.timers.clear(p.timer);
    this.pending = null;
  }

  private arm(id: string, ms: number, why: string): unknown {
    return this.timers.set(() => { if (this.pending?.id === id) this.fail(why); }, ms);
  }
  private rearm(p: Pending, ms: number): void {
    this.timers.clear(p.timer);
    p.timer = this.arm(p.id, ms, `The Mac stopped sending ${p.name}`);
  }

  /// A failure: in the modal when it is up, else a note — nothing opens for a path that names no image.
  private fail(text: string): void {
    const p = this.pending;
    this.abandon();
    if (p?.begun && this.dialog?.open) this.status(text);
    else this.deps.flashNote(text);
  }

  private show(name: string, resolved: string): HTMLDialogElement {
    const d = this.ensureDialog();
    this.release();
    d.setAttribute("aria-label",name);
    d.querySelector<HTMLElement>(".file-viewer-name")!.textContent = name;
    d.querySelector<HTMLElement>(".file-viewer-name")!.title = resolved;
    d.querySelector<HTMLImageElement>(".file-viewer-image")!.hidden = true;
    return d;
  }

  private status(text: string): void {
    const el = this.dialog?.querySelector<HTMLElement>(".file-viewer-status");
    if (el) { el.textContent = text; el.hidden = false; }
  }

  private picture(blob: Blob, name: string, resolved: string): void {
    const d = this.show(name,resolved);
    this.url = URL.createObjectURL(blob);
    const url=this.url;
    const img = d.querySelector<HTMLImageElement>(".file-viewer-image")!;
    img.alt=name;
    img.onload = () => {
      if(this.url!==url)return;
      d.querySelector<HTMLElement>(".file-viewer-status")!.hidden = true;
      img.hidden = false;
      if(!d.open)openClientDialog(d);
    };
    img.onerror = () => {
      if(this.url!==url)return;
      this.release();this.deps.flashNote("This image cannot be shown here");
    };
    img.src = url;
  }

  private release(): void {
    if (this.url) { URL.revokeObjectURL(this.url); this.url = null; }
    const img = this.dialog?.querySelector<HTMLImageElement>(".file-viewer-image");
    if (img) { img.removeAttribute("src"); img.hidden = true; }
  }

  private ensureDialog(): HTMLDialogElement {
    if (this.dialog) return this.dialog;
    const d = document.createElement("dialog");
    d.className = "ss-dialog file-viewer";
    d.innerHTML = `<header class="file-viewer-bar"><span class="file-viewer-name"></span>`
      + `<button type="button" class="file-viewer-close" aria-label="Close">×</button></header>`
      + `<div class="file-viewer-body"><img class="file-viewer-image" alt="" hidden><p class="file-viewer-status"></p></div>`;
    d.querySelector(".file-viewer-close")!.addEventListener("click", () => this.close());
    // A press outside the picture's box — on the backdrop — closes it, as Esc does (the dialog's own `cancel`).
    d.addEventListener("click", (e) => { if (e.target === d) this.close(); });
    d.addEventListener("close", () => { this.abandon(); this.release(); });
    this.deps.root.append(d);
    this.dialog = d;
    return d;
  }
}
