/// WHAT WAS COPIED IN FINDER, AS THE APP SEES IT (docs/client-web.md, "A folder"; 2026-10-02 — "when pasting
/// directories from the mac into the app, it says 'nothing to paste'"). A web page is never told a file's path,
/// and WebKit hands it a FOLDER as a 0-byte `File` with no type, which a paste skipped as empty. Inside the app,
/// `__rdevShell` reads the pasteboard itself (`pasteboardFiles`) and, for a paste to ANOTHER Mac, makes what is
/// sent (`preparePaste`: a folder zipped as Finder's Compress makes it, a file as it is), served once to this
/// page at an `app://client/__paste/…` URL. A browser has none of this: there a folder is still nothing.

export interface LocalFile { path: string; name: string; dir: boolean }
export interface PreparedFile { url: string; name: string; type: string; size: number }

export interface LocalPasteApi {
  /// What Finder copied (file URLs on the pasteboard), in order; `[]` for anything else, and on any error.
  files(): Promise<LocalFile[]>;
  /// Each path made sendable — a folder zipped, a file as it is. Rejects with the app's reason: `too-large` (a
  /// zip the app stopped past 1 GiB), `cancelled` (`cancel`), or another.
  prepare(paths: readonly string[]): Promise<PreparedFile[]>;
  /// Stop what `prepare` is making for this page (the app kills its `ditto`); that `prepare` rejects `cancelled`.
  cancel(): void;
  /// The person will not send these after all: the app deletes the zips.
  discard(urls: readonly string[]): void;
  /// One prepared file's bytes.
  read(url: string): Promise<Blob>;
}

interface ShellPasteOps {
  pasteboardFiles?: () => Promise<unknown>;
  preparePaste?: (paths: string[]) => Promise<unknown>;
  discardPaste?: (urls: string[]) => Promise<unknown>;
  cancelPaste?: () => Promise<unknown>;
}

const isLocalFile = (v: unknown): v is LocalFile => {
  const o = v as Partial<LocalFile> | null;
  return !!o && typeof o.path === "string" && typeof o.name === "string" && typeof o.dir === "boolean";
};
const isPrepared = (v: unknown): v is PreparedFile => {
  const o = v as Partial<PreparedFile> | null;
  return !!o && typeof o.url === "string" && typeof o.name === "string" && typeof o.type === "string"
    && typeof o.size === "number" && Number.isFinite(o.size);
};

/// The app's half, from its shell — null in a browser, and in an app whose shell predates it.
export function localPasteApi(shell: ShellPasteOps | undefined): LocalPasteApi | null {
  if (!shell?.pasteboardFiles || !shell.preparePaste || !shell.discardPaste || !shell.cancelPaste) return null;
  const { pasteboardFiles, preparePaste, discardPaste, cancelPaste } = shell;
  return {
    files: () => pasteboardFiles().then((v) => (Array.isArray(v) ? v.filter(isLocalFile) : []), () => []),
    prepare: async (paths) => {
      const v = await preparePaste([...paths]);
      // The bridge's refusal is a `-`-prefixed reason (ClientBridge), never a throw.
      if (typeof v === "string") throw new Error(v.replace(/^-/, ""));
      if (!Array.isArray(v) || !v.every(isPrepared)) throw new Error("malformed");
      return v;
    },
    discard: (urls) => { void discardPaste([...urls]).catch(() => {}); },
    cancel: () => { void cancelPaste().catch(() => {}); },
    read: async (url) => {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`status ${res.status}`);
      return res.blob();
    },
  };
}

/// A path as it is TYPED into a terminal — exactly as the host types a pasted file's path (RdevCore
/// `PasteTyping`, protocol/fixtures/paste-typing.json): as-is when every character is in [A-Za-z0-9._/-],
/// single-quoted otherwise.
export function quotedPath(path: string): string {
  return /^[A-Za-z0-9._/-]*$/.test(path) ? path : `'${path.replaceAll("'", `'\\''`)}'`;
}

/// Each path its own piece, followed by a space, as Terminal.app types a drag: pasted ONE PIECE PER PASTE, the
/// only form Claude Code and Codex both attach (docs/terminal.md, "The host types a pasted file's path").
export function pathPieces(paths: readonly string[]): string[] {
  return paths.map((p) => `${quotedPath(p)} `);
}

export interface FolderQuestion { title: string; body: string; path: string; send: string }

/// What the person is asked when folders go to ANOTHER Mac: this Mac's path, or a zip.
export function folderQuestion(files: readonly LocalFile[]): FolderQuestion {
  const dirs = files.filter((f) => f.dir);
  const plain = files.length - dirs.length;
  const send = "Compress and send";
  if (!plain && dirs.length === 1) {
    return { title: `Paste “${dirs[0]!.name}”`, path: "Paste the path", send,
             body: "It is a folder on this Mac. Paste its path, or compress it and send it as a .zip." };
  }
  if (!plain) {
    return { title: `Paste ${dirs.length} folders`, path: "Paste the paths", send,
             body: "They are folders on this Mac. Paste their paths, or compress them and send them as .zip files." };
  }
  const which = dirs.length === 1 ? `“${dirs[0]!.name}” is a folder` : `${dirs.length} of them are folders`;
  const zipped = dirs.length === 1 ? "the folder and send it" : "the folders and send them";
  const rest = plain === 1 ? "the file as it is" : "the files as they are";
  return { title: `Paste ${files.length} items`, path: "Paste the paths", send,
           body: `${which} on this Mac. Paste the paths, or compress ${zipped} with ${rest}.` };
}

/// Whole megabytes (MiB, as the caps are written), at least 1.
export function megabytes(bytes: number): number {
  return Math.max(1, Math.round(bytes / (1024 * 1024)));
}

/// The warning before a big paste: what it is, its size, and that it may take a while. `label` is a delivery's
/// (`labelOf`): one file's name, or "N files".
export function sizeQuestion(label: string, bytes: number): string {
  const one = !/^\d+ files$/.test(label);
  return one
    ? `Send ${label}? It is ${megabytes(bytes)} MB, so it may take a while.`
    : `Send ${label}? They are ${megabytes(bytes)} MB, so they may take a while.`;
}
