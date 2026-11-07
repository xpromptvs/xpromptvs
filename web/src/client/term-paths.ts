import type { IBufferLine, IBufferRange, IDisposable, ILink, ILinkProvider, Terminal } from "@xterm/xterm";
import { CLICK_SWALLOW_MS, HOLD_MS, TOUCH_SLOP_PX } from "./press-hold";
import { cellAt } from "./touch-selection";

// **AN IMAGE PATH IN THE TERMINAL OPENS ON THE CLIENT** (2026-10-05, asked for: "add image preview functionality.
// when tapping a path (highlight it), it should open on the client if exists"; docs/terminal.md, "An image path opens
// on the client"). A path to an image printed in a tab is a LINK: underlined under a mouse (xterm.js's own hover), and
// a click — or a finger's TAP, which has no hover — highlights it and asks the host for the file (`file-viewer.ts`).
// A relative path is the tab's: the host resolves it against what runs in that tab (`FileFetch.resolve`). A path an
// APP broke over several rows (Codex, Claude Code wrap their own output) is found whole (`continues`). A `file:` URL
// naming an image is a path too (2026-10-06, asked for: "recognize file:// urls the same way").

/// The extensions a path is an image by — the host's `FileFetch.shown` and `FileFetch.converted`.
export const IMAGE_EXTENSIONS = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "avif", "ico", "heic", "heif", "tif", "tiff"];

/// A path in a line of text: where it is (`index`, `length` — what is underlined) and the path it names, unquoted and
/// unescaped (`\ ` is a space).
export interface PathMatch { index: number; length: number; path: string }

const EXT = `(?:${IMAGE_EXTENSIONS.join("|")})`;
/// What may follow a path: the line's end, a space, a closing quote or bracket, punctuation — and a full stop or a
/// colon only at the end of a sentence (`see shot.png.`), never inside a longer name (`shot.png.bak`).
const END = "(?=$|[\\s'\"`<>|;,()\\[\\]{}!?]|[.:](?:$|\\s))";
/// A quoted path: everything between matching quotes, spaces included (`'Screenshot 2026-10-05 at 10.00.00.png'`).
const QUOTED = new RegExp(`(['"])([^'"\\n]*?\\.${EXT})\\1`, "gi");
/// A bare path: no space but an ESCAPED one (`Screenshot\ 1.png`), starting at the line's start or after a boundary —
/// `=` among them (`--out=render.png`), so a path with an `=` in it is not one.
const BARE = new RegExp(`(?<=^|[\\s'"\`(<\\[{=])((?:[^\\s'"\`<>|;,(){}\\[\\]=\\\\]|\\\\ )+?\\.${EXT})${END}`, "gi");
/// A URL is the web-links addon's (term-links.ts): an image URL is never also a path — except a `file:` one.
const URL_RE = /\b[a-z][a-z0-9+.-]*:\/\/\S+/gi;
/// A `file:` URL naming an image (`file:///Users/me/shot.png`, `file://<host>/…`), read from the start of a URL's run
/// of non-space: it ends as a bare path does, and may hold brackets (`Screenshot%20(1).png`) — a URL holds no space.
const FILE_URL = new RegExp(`^file://[^\\s'"\`<>]*?\\.${EXT}${END}`, "i");

/// The path a `file:` URL names, its escapes decoded (`%20` is a space) — whatever its host: the file is the host
/// Mac's either way, as a relative path is the tab's. Null for one that does not decode.
function fileUrlPath(url: string): string | null {
  try { return decodeURIComponent(new URL(url).pathname); } catch { return null; }
}

/// Every image path in `line`, in order.
export function findImagePaths(line: string): PathMatch[] {
  const taken: Array<[number, number]> = [];
  const free = (a: number, b: number) => !taken.some(([s, e]) => a < e && b > s);
  const out: PathMatch[] = [];
  for (const m of line.matchAll(URL_RE)) {
    taken.push([m.index, m.index + m[0].length]);
    const url = m[0].match(FILE_URL)?.[0];
    const path = url ? fileUrlPath(url) : null;
    if (url && path) out.push({ index: m.index, length: url.length, path });
  }
  for (const m of line.matchAll(QUOTED)) {
    const index = m.index + 1, text = m[2]!;
    if (!free(m.index, m.index + m[0].length)) continue;
    out.push({ index, length: text.length, path: text });
    taken.push([m.index, m.index + m[0].length]);
  }
  for (const m of line.matchAll(BARE)) {
    const text = m[1]!;
    if (!free(m.index, m.index + text.length)) continue;
    out.push({ index: m.index, length: text.length, path: text.replace(/\\ /g, " ") });
  }
  return out.sort((a, b) => a.index - b.index);
}

/// How far short of the width an app may wrap and still be taken to have broken a path because it did not fit:
/// Codex wraps a little inside the terminal's width.
const WRAP_MARGIN = 8;
/// Rows a chain joins, at most: a path longer than that is not a path a person taps.
const MAX_JOINS = 8;

/// A buffer line run the terminal soft-wrapped: rows `top`…`bottom`, their text as `IBufferLine.translateToString`
/// reads it (each row trimmed, as `mapIndex` walks it).
interface Group { top: number; bottom: number; text: string }
/// A group's text in a chain: from cell `col` of row `row` (a continuation's indent stripped), at `offset` in the
/// chain's joined text.
interface Segment { row: number; col: number; offset: number; text: string }

function groupAt(term: Terminal, row: number): Group | null {
  const buf = term.buffer.active;
  if (row < 0 || !buf.getLine(row)) return null;
  let top = row, bottom = row;
  while (top > 0 && buf.getLine(top)?.isWrapped && row - top < 64) top--;
  while (buf.getLine(bottom + 1)?.isWrapped && bottom - row < 64) bottom++;
  let text = "";
  for (let r = top; r <= bottom; r++) text += buf.getLine(r)!.translateToString(true);
  return { top, bottom, text };
}

/// The cells row `line` uses: up to its last non-blank cell.
function usedCells(line: IBufferLine, cell: ReturnType<Terminal["buffer"]["active"]["getNullCell"]>): number {
  let n = line.length;
  while (n > 0) {
    line.getCell(n - 1, cell);
    const ch = cell.getChars();
    if (cell.getWidth() === 0 || (ch !== "" && ch !== " ")) break;
    n--;
  }
  return n;
}

/// **Whether `b` carries on a path `a` ended with — an APP's line break, not the terminal's.** Codex and Claude Code
/// wrap their own output: a long path comes out on several rows, each broken after a `/` or a `-` and the rest
/// indented under it, as separate lines the terminal never joined (`isWrapped` false). Joined only when all of it
/// holds: `a` ends INSIDE a word — after a separator a wrapper breaks at (`/ - _ .`), or at the very last column —
/// because the rest did not fit (the row and `b`'s first word overflow the width, give or take `WRAP_MARGIN`); `b`'s
/// indent is no deeper than where that word started (a hanging indent); the word goes on with something that is not
/// a new path (`/`, `~`); and together they hold a `/`.
function continues(term: Terminal, a: Group, b: Group): boolean {
  if (!a.text || !b.text) return false;
  const indent = b.text.length - b.text.trimStart().length;
  const word = b.text.slice(indent).match(/^\S+/)?.[0];
  const tail = a.text.match(/\S+$/)?.[0];
  if (!word || !tail || /^[/~]/.test(word) || !(tail + word).includes("/")) return false;
  const buf = term.buffer.active;
  const used = usedCells(buf.getLine(a.bottom)!, buf.getNullCell());
  const full = used >= term.cols;
  if (!full && !"/-_.".includes(tail[tail.length - 1]!)) return false;
  if (!full && used + word.length <= term.cols - WRAP_MARGIN) return false;
  const [, tailCol] = mapIndex(term, a.top, 0, a.text.length - tail.length);
  return tailCol >= 0 && indent <= tailCol;
}

/// The rows a path through buffer row `row` may span: its soft-wrapped group, and the groups before and after it an
/// app's line breaks carry on (`continues`), joined with NO space — a path holds none.
function chainAt(term: Terminal, row: number): Segment[] {
  const first = groupAt(term, row);
  if (!first) return [];
  const groups = [first];
  for (let up = first, i = 0; i < MAX_JOINS; i++) {
    const prev = groupAt(term, up.top - 1);
    if (!prev || !continues(term, prev, up)) break;
    groups.unshift(prev); up = prev;
  }
  for (let down = first, i = 0; i < MAX_JOINS; i++) {
    const next = groupAt(term, down.bottom + 1);
    if (!next || !continues(term, down, next)) break;
    groups.push(next); down = next;
  }
  let offset = 0;
  return groups.map((g, i) => {
    const col = i === 0 ? 0 : g.text.length - g.text.trimStart().length;
    const seg = { row: g.top, col, offset, text: g.text.slice(col) };
    offset += seg.text.length;
    return seg;
  });
}

/// The links on buffer line `y` (1-based, as xterm.js asks): every image path in the chain through it (`chainAt`),
/// one link per ROW PIECE of it — a path an app broke over three rows is three links, each opening the whole path,
/// so no indent between them is underlined. A piece is mapped to cells as `@xterm/addon-web-links`' `LinkComputer`
/// maps a URL (MIT, xterm.js authors: its index→cell walk, which accounts for wide glyphs wrapped early).
export function pathLinksAt(term: Terminal, y: number, open: (path: string, ranges: IBufferRange[]) => void): ILink[] {
  const segs = chainAt(term, y - 1);
  const text = segs.map((s) => s.text).join("");
  const links: ILink[] = [];
  for (const m of findImagePaths(text)) {
    const ranges: IBufferRange[] = [];
    for (const s of segs) {
      const a = Math.max(m.index, s.offset), b = Math.min(m.index + m.length, s.offset + s.text.length);
      if (a >= b) continue;
      const [sy, sx] = mapIndex(term, s.row, s.col, a - s.offset);
      const [ey, ex] = mapIndex(term, sy, sx, b - a);
      if (sy < 0 || sx < 0 || ey < 0 || ex < 0) continue;
      // A piece ending at its row's last column ends there, not at column 0 of the next row (the walk's "one past").
      ranges.push({ start: { x: sx + 1, y: sy + 1 }, end: ex === 0 && ey > sy ? { x: term.cols, y: ey } : { x: ex, y: ey + 1 } });
    }
    for (const range of ranges) {
      if (range.start.y > y || range.end.y < y) continue;
      links.push({
        range, text: m.path,
        decorations: { pointerCursor: true, underline: true },
        activate: () => open(m.path, ranges),
      });
    }
  }
  return links;
}

function mapIndex(term: Terminal, lineIndex: number, col: number, stringIndex: number): [number, number] {
  const buf = term.buffer.active;
  const cell = buf.getNullCell();
  let start = col;
  while (stringIndex) {
    const line = buf.getLine(lineIndex);
    if (!line) return [-1, -1];
    for (let i = start; i < line.length; ++i) {
      line.getCell(i, cell);
      const chars = cell.getChars();
      if (cell.getWidth()) {
        stringIndex -= chars.length || 1;
        if (i === line.length - 1 && chars === "") {
          const next = buf.getLine(lineIndex + 1);
          if (next?.isWrapped) { next.getCell(0, cell); if (cell.getWidth() === 2) stringIndex += 1; }
        }
      }
      if (stringIndex < 0) return [lineIndex, i];
    }
    lineIndex++;
    start = 0;
  }
  return [lineIndex, start];
}

/// How long a tapped path stays highlighted: the request is on its way; the viewer (or a note) is the answer.
export const TAP_HIGHLIGHT_MS = 900;
/// The same path again within this is one activation's echo, never a second request.
const ECHO_MS = 600;

/// **IMAGE PATHS IN `term` ARE LINKS** that call `open` with the path. A MOUSE gets xterm.js's own link handling:
/// the hover's pointer and underline, and the click. A FINGER's tap is taken at its `touchend`, never from the
/// mouse events a phone synthesizes after it: those come later, through iOS's gesture system, and xterm.js FOCUSES
/// on their `mousedown` — the soft keyboard over the picture. So a tap — one finger, still (`TOUCH_SLOP_PX`), shorter
/// than a hold (`HOLD_MS`) and not the one that stops a glide (`gliding`, touch-scroll.ts's) — on a path PREVENTS its
/// `touchend` and swallows the `mousedown`, `mouseup` and `click` after it in `el`'s capture phase, ahead of xterm.js,
/// for `CLICK_SWALLOW_MS` or until the next touch, as the glide-stopping tap does. A press the session's own
/// handlers took — the paste menu's hold, a selection's ending tap, a menu's closing press — never reaches here or
/// is no tap. Every piece of the path is HIGHLIGHTED (a decoration per row) while the request is on its way.
export function attachPathLinks(term: Terminal, el: HTMLElement, open: (path: string) => void,
                                opts: { gliding?: () => boolean } = {}): IDisposable {
  let last: { path: string; at: number } | null = null;
  const activate = (path: string, ranges: IBufferRange[]) => {
    const now = performance.now();
    if (last && last.path === path && now - last.at < ECHO_MS) return;
    last = { path, at: now };
    highlight(term, ranges);
    open(path);
  };
  const provider: ILinkProvider = { provideLinks: (y, cb) => cb(pathLinksAt(term, y, activate)) };
  const registration = term.registerLinkProvider(provider);

  const ac = new AbortController();
  const linkAt = (x: number, y: number): ILink | null => {
    const screen = term.element?.querySelector<HTMLElement>(".xterm-screen")?.getBoundingClientRect();
    if (!screen || screen.width === 0 || screen.height === 0) return null;
    const c = cellAt(x, y, screen, term.cols, term.rows, term.buffer.active.viewportY);
    return pathLinksAt(term, c.row + 1, activate).find((l) => covers(l, c.col + 1, c.row + 1)) ?? null;
  };
  let tap: { id: number; x: number; y: number; at: number } | null = null;
  let swallowUntil = 0;
  el.addEventListener("touchstart", (e) => {
    swallowUntil = 0;                         // the next press ends the window: its own mouse events are its own
    const t = e.touches.length === 1 ? e.changedTouches[0] : undefined;
    tap = t && !opts.gliding?.() ? { id: t.identifier, x: t.clientX, y: t.clientY, at: performance.now() } : null;
  }, { capture: true, passive: true, signal: ac.signal });
  el.addEventListener("touchmove", (e) => {
    const t = tap && Array.from(e.changedTouches).find((c) => c.identifier === tap!.id);
    if (e.touches.length > 1 || (t && Math.hypot(t.clientX - tap!.x, t.clientY - tap!.y) > TOUCH_SLOP_PX)) tap = null;
  }, { capture: true, passive: true, signal: ac.signal });
  el.addEventListener("touchcancel", () => { tap = null; }, { capture: true, signal: ac.signal });
  el.addEventListener("touchend", (e) => {
    const t = tap;
    tap = null;
    if (!t || e.defaultPrevented || e.touches.length > 0 || performance.now() - t.at >= HOLD_MS) return;
    if (!Array.from(e.changedTouches).some((c) => c.identifier === t.id)) return;
    const link = linkAt(t.x, t.y);
    if (!link) return;
    if (e.cancelable) e.preventDefault();
    swallowUntil = Date.now() + CLICK_SWALLOW_MS;
    link.activate(e as unknown as MouseEvent, link.text);
  }, { capture: true, passive: false, signal: ac.signal });
  const swallow = (e: Event) => {
    if (Date.now() >= swallowUntil) return;
    if (e.type === "click") swallowUntil = 0;
    e.preventDefault();
    e.stopImmediatePropagation();
  };
  for (const type of ["mousedown", "mouseup", "click"] as const) el.addEventListener(type, swallow, { capture: true, signal: ac.signal });
  return { dispose: () => { registration.dispose(); ac.abort(); } };
}

function covers(link: ILink, x: number, y: number): boolean {
  const { start, end } = link.range;
  if (y < start.y || y > end.y) return false;
  if (y === start.y && x < start.x) return false;
  return !(y === end.y && x > end.x);
}

/// The path's cells, highlighted for `TAP_HIGHLIGHT_MS`: one decoration per row of every piece, drawn over the text
/// in the selection's tint (a DOM layer, whichever renderer draws the rows).
function highlight(term: Terminal, ranges: IBufferRange[]): void {
  const buf = term.buffer.active;
  const decorations: IDisposable[] = [];
  for (const range of ranges) {
    for (let y = range.start.y; y <= range.end.y; y++) {
      const x0 = y === range.start.y ? range.start.x - 1 : 0;
      const x1 = y === range.end.y ? range.end.x : term.cols;
      const marker = term.registerMarker(y - 1 - (buf.baseY + buf.cursorY));
      if (!marker) continue;
      const d = term.registerDecoration({ marker, x: x0, width: Math.max(1, x1 - x0), layer: "top" });
      if (!d) { marker.dispose(); continue; }
      d.onRender((box) => { box.classList.add("term-path-tapped"); });
      decorations.push(d, marker);
    }
  }
  setTimeout(() => { for (const d of decorations) d.dispose(); }, TAP_HIGHLIGHT_MS);
}
