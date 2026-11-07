import type { IBufferCell, IUnicodeVersionProvider, Terminal } from "@xterm/xterm";
import { UnicodeGraphemesAddon } from "@xterm/addon-unicode-graphemes";
import widths from "../../../protocol/fixtures/term-widths.json";
import tmuxGlyphs from "../../../protocol/fixtures/tmux-glyphs.json";

/// GLYPH WIDTHS — the client must count the columns the host's emulator counted (docs/terminal.md,
/// "Glyph widths"). A snapshot places every cell where SwiftTerm (a `pty:` tab) or tmux (a `tmux:` tab)
/// put it, and live output after it lands wherever the client's own count says; a glyph the two count
/// differently misplaces the rest of its row, the cursor with it.
///
/// xterm.js 6's default is a Unicode 6 table with no grapheme clusters (😀 one column, 👩‍💻 four). The
/// `@xterm/addon-unicode-graphemes` addon brings the grapheme rules — VS16, ZWJ sequences, skin tones,
/// flags, joined as UAX #29 joins them — but its width DATA is older than the host's (MEASURED
/// 2026-09-27: 🫠 and every other Unicode 14+ emoji one column, ☰ narrow) and it gives ZWSP, LRM and the
/// other invisible format characters a column. So rdev keeps the addon's JOIN decisions and takes every
/// WIDTH from the host:
/// - a scalar that does not join: the host's table (protocol/fixtures/term-widths.json, SwiftTerm's own
///   `columnWidth` as rdev patches it, written by //tools/TermSnapshotFixtures);
/// - a zero-width scalar that does not join (ZWSP after a letter): joined anyway, TRANSPARENTLY — width
///   and grapheme state stay the previous glyph's, as SwiftTerm and tmux drop it. xterm.js advances the
///   cursor past ANY cell it writes, zero-width included, so joining is the only zero it has;
/// - a zero-width scalar with NOTHING to join — xterm.js zeroes its join state on every control and
///   escape sequence, so a mark after `ESC[31m` is one — stands alone: one column, two for a skin-tone
///   modifier, as rdev's SwiftTerm patch writes it;
/// - a scalar that joins: the cluster keeps its base's width, except that VS16, a skin-tone modifier and
///   the second regional indicator of a pair widen it to two (the addon's own rule widened on ANY wider
///   joiner, so ❤‍🔥 without VS16 became two where SwiftTerm and tmux keep one).
export const RDEV_UNICODE_VERSION = "rdev-graphemes";

// xterm.js's packed character properties (UnicodeService.createPropertyValue): bit 0 "joins the
// previous cell", bits 1–2 the width, the rest the grapheme-break state. Not exported by xterm.js;
// term-unicode.test.ts reads widths back through a real Terminal, which is what keeps this honest.
const joins = (v: number) => (v & 1) !== 0;
const widthOf = (v: number) => (v >> 1) & 3;
const stateOf = (v: number) => v >> 3;
const pack = (state: number, width: number, join: boolean) => ((state & 0xffffff) << 3) | ((width & 3) << 1) | (join ? 1 : 0);

function within(r: number[][], c: number): boolean {
  let lo = 0, hi = r.length - 1;
  while (lo <= hi) {
    const m = (lo + hi) >> 1;
    const [a, b] = r[m]!;
    if (c < a!) hi = m - 1;
    else if (c > b!) lo = m + 1;
    else return true;
  }
  return false;
}
const tableWidth = (c: number): 0 | 1 | 2 => (within(widths.wide, c) ? 2 : within(widths.zero, c) ? 0 : 1);
// The BMP's widths as a 64 KB table, built once (the whole table is two binary searches per scalar
// otherwise — measured 2.4x xterm.js's default on CJK); the astral planes stay on the ranges.
const bmp = new Uint8Array(0x10000).fill(1);
for (const [w, ranges] of [[2, widths.wide], [0, widths.zero]] as const) {
  for (const [lo, hi] of ranges) if (lo! < 0x10000) bmp.fill(w, lo, Math.min(hi!, 0xffff) + 1);
}
/// The HOT scalars' tables are indexed by `hot(c)`: the BMP, then the emoji planes' block U+1F000–1FAFF
/// (every emoji most output carries), so neither pays the ranges' binary search. -1: elsewhere.
const HOT_EMOJI = 0x1f000, HOT_END = 0x1fb00, HOT_SIZE = 0x10000 + (HOT_END - HOT_EMOJI);
const hot = (c: number) => (c < 0x10000 ? c : c >= HOT_EMOJI && c < HOT_END ? 0x10000 + c - HOT_EMOJI : -1);
const hotWidth = new Uint8Array(HOT_SIZE);
hotWidth.set(bmp);
for (let c = HOT_EMOJI; c < HOT_END; c++) hotWidth[hot(c)] = tableWidth(c);
const hostWidth = (c: number): 0 | 1 | 2 => {
  const i = hot(c);
  return i >= 0 ? (hotWidth[i] as 0 | 1 | 2) : tableWidth(c);
};
/// Plain ASCII after a plain glyph: exactly what the addon answers itself (its `_plainNarrowProperties`),
/// without the call.
const PLAIN_NARROW = pack(0, 1, false);

/// Joiners that WIDEN a cluster to two columns: VS16, a skin-tone modifier, a regional indicator (only
/// ever joins as the second of a pair).
const widens = (c: number) => c === 0xfe0f || (c >= 0x1f3fb && c <= 0x1f3ff) || (c >= 0x1f1e6 && c <= 0x1f1ff);

// The addon's grapheme-break codes (its UnicodeProperties.GRAPHEME_BREAK_*; the state's low 4 bits).
const PREPEND = 1, EXTEND = 2, SPACING_MARK = 4, HANGUL_L = 5, HANGUL_LV = 8, HANGUL_LVT = 9, ZWJ = 10, EXT_PIC = 11;
/// rdev's own bit in the state, above the addon's code (which it masks with 0xF and never reads past):
/// the cluster so far is a PICTOGRAPH followed only by Extend/ZWJ — what UAX #29's GB11 asks of a ZWJ
/// before it lets an emoji join.
const PIC = 16;
const codeOf = (state: number) => state & 0xf;
/// The state rdev hands on (the addon's own is `code ± 16`, masked to 24 bits): the code, plus PIC.
const canonical = (code: number, pic: boolean) => code | (pic ? PIC : 0);

/// The grapheme-break code of every BMP scalar, learnt from the addon the first time it is seen (255:
/// not yet). Only for the fast path below, which needs it to know a scalar can never join.
const hotCode = new Uint8Array(HOT_SIZE).fill(255);

class RdevUnicodeProvider implements IUnicodeVersionProvider {
  readonly version = RDEV_UNICODE_VERSION;
  constructor(private readonly graphemes: IUnicodeVersionProvider) {}

  wcwidth(c: number): 0 | 1 | 2 {
    return c < 0xa0 ? this.graphemes.wcwidth(c) : hostWidth(c);
  }

  charProperties(c: number, preceding: number): number {
    // Kept SMALL so the engine inlines it into xterm.js's print loop: plain ASCII never leaves here.
    return c >= 32 && c < 127 && (preceding >> 3) === 0 ? PLAIN_NARROW : this.slow(c, preceding);
  }

  private slow(c: number, preceding: number): number {
    const before = codeOf(stateOf(preceding));
    const i = hot(c);
    if (i >= 0 && before !== PREPEND) {
      // FAST PATH, exact: a scalar of code Other (CJK, kana, most letters) or a Hangul syllable joins
      // nothing unless a Prepend precedes it (GB9a) — rdev keeps GB6's L + syllable apart (below) — and
      // a pictograph joins only after a ZWJ (GB11), so the addon's lookup can be skipped once its code
      // is known (learnt from the addon the first time the scalar is seen).
      let code = hotCode[i]!;
      if (code === 255) code = hotCode[i] = codeOf(stateOf(this.graphemes.charProperties(c, 0)));
      const w = hotWidth[i]!;
      if (w !== 0) {
        if (code === 0 || code === HANGUL_LV || code === HANGUL_LVT) return pack(code, w, false);
        if (code === EXT_PIC && before !== ZWJ) return pack(canonical(EXT_PIC, true), w, false);
      }
    }
    const v = this.graphemes.charProperties(c, preceding);
    const code = codeOf(stateOf(v));
    if (joins(v) && !this.keptApart(code, before, preceding)) {
      const pic = code === EXT_PIC || ((code === EXTEND || code === ZWJ) && (stateOf(preceding) & PIC) !== 0);
      const state = canonical(code, pic);
      return widens(c) ? pack(state, widthOf(v), true) : pack(state, widthOf(preceding), true);
    }
    const w = hostWidth(c);
    if (w === 0) {
      if (preceding !== 0) return pack(stateOf(preceding), widthOf(preceding), true);
      // An ORPHAN: a joiner with nothing to join — xterm.js zeroes the join state on every control and
      // escape sequence. It stands alone, one column (two for a skin-tone modifier, an emoji itself),
      // as rdev's SwiftTerm writes it; a width of 0 here would write a cell and still advance. Its
      // grapheme state is a plain base's (0, "Other"): the addon's for a lone ZWJ would join a following
      // emoji, where UAX #29's GB11 (and Swift) join one only after a pictograph.
      return pack(0, c >= 0x1f3fb && c <= 0x1f3ff ? 2 : 1, false);
    }
    return pack(canonical(code, code === EXT_PIC), w, false);
  }

  /// Joins the addon makes and SwiftTerm does not — the client follows SwiftTerm, which is also what
  /// wcwidth-counting shells and tmux assume (docs/terminal.md, "GLYPH WIDTHS"):
  /// - an emoji after a ZWJ when no pictograph began the cluster (the addon's GB11 skips that test:
  ///   `a` ZWJ 😀 was one column; UAX #29, Swift and Intl.Segmenter make it three);
  /// - Hangul L + L / LV / LVT (old Korean; GB6): two wide cells, never one;
  /// - a spacing glyph after a Prepend character (GB9a): SwiftTerm joins only a zero-width one.
  private keptApart(code: number, before: number, preceding: number): boolean {
    if (code === EXT_PIC && before === ZWJ) return (stateOf(preceding) & PIC) === 0;
    if (before === HANGUL_L) return code === HANGUL_L || code === HANGUL_LV || code === HANGUL_LVT;
    if (before === PREPEND) return code !== EXTEND && code !== ZWJ && code !== SPACING_MARK;
    return false;
  }
}

let shared: RdevUnicodeProvider | undefined;

/// The provider (stateless, so one serves every terminal). The addon exports only its addon class; its
/// provider is taken from the one call it makes, `terminal.unicode.register`, against a stand-in.
export function rdevUnicodeProvider(): IUnicodeVersionProvider {
  if (!shared) {
    let graphemes: IUnicodeVersionProvider | undefined;
    const standIn = { unicode: { register: (p: IUnicodeVersionProvider) => { if (p.version === "15-graphemes") graphemes = p; }, activeVersion: "6" } };
    new UnicodeGraphemesAddon().activate(standIn as unknown as Terminal);
    if (!graphemes) throw new Error("@xterm/addon-unicode-graphemes registered no 15-graphemes provider");
    shared = new RdevUnicodeProvider(graphemes);
  }
  return shared;
}

let fallbackLogged = false;

/// Every product terminal runs this before it is written to (xterm-view.ts's `mountXterm`). If the
/// provider cannot be built (an addon whose `activate` needs more than the stand-in offers — the pins in
/// web/package.json exist so that happens only on a deliberate bump), the terminal keeps xterm.js's
/// default provider and still WORKS, with widths that disagree with the host: said once, loudly.
/// `provide` is for the test of exactly that.
export function loadRdevUnicode(term: Terminal, provide: () => IUnicodeVersionProvider = rdevUnicodeProvider): boolean {
  let provider: IUnicodeVersionProvider;
  try {
    provider = provide();
  } catch (e) {
    if (!fallbackLogged) {
      fallbackLogged = true;
      console.error("[term] glyph widths: the rdev provider failed, falling back to xterm.js's default (Unicode 6) — "
        + "emoji and other wide glyphs will not line up with the host's snapshots", e);
    }
    return false;
  }
  term.unicode.register(provider);
  term.unicode.activeVersion = RDEV_UNICODE_VERSION;
  return true;
}

// ---------------------------------------------------------------------------------------------------
// A TMUX TAB COUNTS AS TMUX DOES (docs/terminal.md, "tmux tabs count as tmux does"). tmux decides where
// a tmux app's cursor goes, and its `%output` is what this instance draws, so a tmux tab follows tmux —
// MEASURED (scripts/measure_tmux_glyphs.py → protocol/fixtures/tmux-glyphs.json):
// - widths: the host's table with tmux's exceptions (☝ ✌ 🖐 … two columns, a lone skin tone two, the
//   Hangul filler none);
// - a scalar JOINS the cell before the cursor — whatever came between: an escape sequence, a control,
//   a cursor move — when it is zero-width (a mark, ZWJ, ZWSP, VS15, a conjoining vowel), VS16 (which
//   widens the cell to two), a skin tone after one of tmux's own list of bases, the second regional
//   indicator of a pair (two columns), or any non-ASCII scalar after a cell ending in a ZWJ;
// - a widening in the LAST column does not wrap: the cell stays where it is, one column, and the cursor
//   stays in pending wrap (tmux draws the glyph overhanging).
// xterm.js zeroes its join state at every sequence and control, so after one this provider reads the
// cell before the cursor from the buffer itself. What it cannot do (Known limits): tmux DROPS a
// zero-width scalar at column 0, xterm.js writes a cell and advances; and a WIDENING joiner after a
// sequence gets tmux's columns but a one-column cell plus an empty one (xterm.js widens by what the
// provider returns MINUS its own join state's width, which a sequence zeroed).
export const RDEV_TMUX_UNICODE_VERSION = "rdev-tmux";

const tmuxWide = new Set<number>(tmuxGlyphs.wide);
const tmuxZero = new Set<number>(tmuxGlyphs.zero);
const tmuxBases = new Set<number>(tmuxGlyphs.modifierBases);   // outside the hot block
const tmuxHot = hotWidth.slice();
/// Per hot scalar: 1 = one of tmux's skin-tone bases.
const tmuxHotBase = new Uint8Array(HOT_SIZE);
for (const c of tmuxGlyphs.wide) if (hot(c) >= 0) tmuxHot[hot(c)] = 2;
for (const c of tmuxGlyphs.zero) if (hot(c) >= 0) tmuxHot[hot(c)] = 0;
for (const c of tmuxGlyphs.modifierBases) if (hot(c) >= 0) tmuxHotBase[hot(c)] = 1;
const tmuxWidth = (c: number): 0 | 1 | 2 => {
  const i = hot(c);
  return i >= 0 ? (tmuxHot[i] as 0 | 1 | 2) : tmuxWide.has(c) ? 2 : tmuxZero.has(c) ? 0 : hostWidth(c);
};
const isTmuxBase = (c: number) => { const i = hot(c); return i >= 0 ? tmuxHotBase[i] === 1 : tmuxBases.has(c); };

/// The server's width options (docs/terminal.md, "TMUX TABS COUNT AS TMUX DOES"), stated IN BAND ahead
/// of each snapshot by the host (`TmuxGlyphOptions.osc`: `OSC 9910 ; vs16wide=on|off;widths=U+X=W,…`).
interface TmuxOptions { vs16Wide: boolean; widths: [number, number, number][] }
const TMUX_DEFAULTS: TmuxOptions = { vs16Wide: true, widths: [] };
export const TMUX_OPTIONS_OSC = 9910;
/// A statement is read up to this many characters and this many `widths` ranges; the rest is ignored
/// (final review I2): `width()` scans the list for every non-ASCII scalar on the page's main thread, and
/// xterm.js would hand a handler up to 10 MB.
export const TMUX_OPTIONS_MAX_CHARS = 4096;
export const TMUX_OPTIONS_MAX_RANGES = 256;
export function parseTmuxOptions(data: string): TmuxOptions {
  const o: TmuxOptions = { vs16Wide: true, widths: [] };
  for (const part of data.slice(0, TMUX_OPTIONS_MAX_CHARS).split(";")) {
    const eq = part.indexOf("=");
    const key = part.slice(0, eq), value = part.slice(eq + 1);
    if (key === "vs16wide") o.vs16Wide = value !== "off";
    if (key === "widths") {
      for (const entry of value.split(",")) {
        if (o.widths.length >= TMUX_OPTIONS_MAX_RANGES) break;
        const m = /^U\+([0-9A-Fa-f]+)(?:-U\+([0-9A-Fa-f]+))?=([012])$/.exec(entry.trim());
        if (m) o.widths.push([parseInt(m[1]!, 16), parseInt(m[2] ?? m[1]!, 16), Number(m[3])]);
      }
    }
  }
  return o;
}
const isModifier = (c: number) => c >= 0x1f3fb && c <= 0x1f3ff;
const isIndicator = (c: number) => c >= 0x1f1e6 && c <= 0x1f1ff;

// The state this provider hands on (xterm.js keeps it only until the next sequence): what tmux needs to
// know of the cell just written. STALE: the width field was a DELTA (a join after a sequence), not the
// cell's width, so the next scalar reads the cell from the buffer instead.
const ENDS_ZWJ = 1, LONE_RI = 2, MOD_BASE = 4, STALE = 8;

interface Cell { width: number; flags: number }

class TmuxUnicodeProvider implements IUnicodeVersionProvider {
  readonly version = RDEV_TMUX_UNICODE_VERSION;
  private opts: TmuxOptions = TMUX_DEFAULTS;
  /// One cell object for every buffer read (xterm.js fills it in place).
  private scratch: IBufferCell | undefined;
  /// This instance has been given a U+200D (sticky; every snapshot builds a fresh instance). Until then
  /// no cell of its buffer can END in one — every scalar xterm.js prints passes `charProperties` — so a
  /// scalar that is not itself a joiner cannot join anything, after a sequence included, and the buffer
  /// read is skipped: an SGR before every glyph (a coloured TUI border) read one cell per glyph.
  private sawZwj = false;
  constructor(private readonly term: Terminal) {}

  /// The server's options, from the latest in-band statement (a snapshot carries the whole set).
  setOptions(o: TmuxOptions): void { this.opts = o; }

  /// tmux's width of `c` under the server's `codepoint-widths` (the LAST entry covering it wins).
  private width(c: number): 0 | 1 | 2 {
    const ws = this.opts.widths;
    for (let k = ws.length - 1; k >= 0; k--) { const [lo, hi, w] = ws[k]!; if (c >= lo && c <= hi) return w as 0 | 1 | 2; }
    return tmuxWidth(c);
  }

  wcwidth(c: number): 0 | 1 | 2 {
    return c < 0xa0 ? (c >= 0x20 && c < 0x7f ? 1 : 0) : this.width(c);
  }

  charProperties(c: number, preceding: number): number {
    return c < 0x80 ? PLAIN_NARROW : this.slow(c, preceding);   // ASCII never joins in tmux
  }

  /// The cell before the cursor: from the state when the last thing xterm.js did was print it, from the
  /// buffer otherwise. null at column 0.
  private before(preceding: number): Cell | null {
    const st = stateOf(preceding);
    if (preceding !== 0 && (st & STALE) === 0) return { width: widthOf(preceding), flags: st };
    const b = this.term.buffer.active;
    const x = Math.min(b.cursorX, this.term.cols);
    if (x === 0) return null;
    const line = b.getLine(b.baseY + b.cursorY);
    let cell = line?.getCell(x - 1, this.scratch);
    if (cell && cell.getWidth() === 0 && x >= 2) cell = line?.getCell(x - 2, cell);
    if (cell) this.scratch = cell;
    if (!cell) return null;
    const chars = cell.getChars();
    const first = chars.codePointAt(0) ?? 0;
    let flags = 0;
    if (chars.endsWith("\u200D")) flags |= ENDS_ZWJ;
    if (isIndicator(first) && chars.length === 2) flags |= LONE_RI;
    if (isTmuxBase(first)) flags |= MOD_BASE;
    return { width: Math.max(1, cell.getWidth()), flags };
  }

  /// A cell of its own.
  private own(c: number, w: number): number {
    return pack((isIndicator(c) ? LONE_RI : 0) | (c >= 0x1f000 && isTmuxBase(c) ? MOD_BASE : 0), w, false);
  }

  private slow(c: number, preceding: number): number {
    const w = this.width(c);
    // Most scalars cannot join anything but a ZWJ-ending cell: decide without reading the buffer —
    // from the state after a print, and after a sequence (no state) whenever this instance has never
    // been given a ZWJ, because then no cell can end in one.
    // (Noted whatever its width: `codepoint-widths` can give U+200D a column, and its own cell still
    // ends in one.)
    if (c === 0x200d) this.sawZwj = true;
    const joiner = w === 0 || c === 0xfe0f || isModifier(c) || isIndicator(c);
    if (!joiner) {
      if (preceding !== 0 && (stateOf(preceding) & STALE) === 0) {
        if ((stateOf(preceding) & ENDS_ZWJ) === 0) return this.own(c, w);
      } else if (!this.sawZwj) return this.own(c, w);
    }
    const p = this.before(preceding);
    if (!p) return this.own(c, w);                            // column 0: nothing before (tmux drops a zero-width one)
    let joins = false, widen = false;
    if (c === 0xfe0f) { joins = true; widen = this.opts.vs16Wide; }
    else if (w === 0) joins = true;
    else if (isModifier(c)) joins = (p.flags & MOD_BASE) !== 0;
    else if (isIndicator(c)) { joins = (p.flags & LONE_RI) !== 0; widen = joins; }
    else joins = (p.flags & ENDS_ZWJ) !== 0;
    if (!joins) return this.own(c, w);
    let target = p.width;
    if (widen && p.width < 2) {
      // In the last column tmux keeps the cell where it is, overhanging; xterm.js would wrap it.
      const x = this.term.buffer.active.cursorX;
      if (x - p.width + 2 <= this.term.cols) target = 2;
    }
    const flags = (c === 0x200d ? ENDS_ZWJ : 0) | (p.flags & MOD_BASE);
    // xterm.js widens by (returned width − its own join state's width) and sets the cell's width to the
    // returned one: exact while that state is this cell's; after a sequence it is 0, so return the delta.
    if (preceding !== 0 && (stateOf(preceding) & STALE) === 0) return pack(flags, target, true);
    return pack(flags | STALE, target - p.width, true);
  }
}

/// A tmux tab's provider: per instance (it reads that terminal's buffer).
export function tmuxUnicodeProvider(term: Terminal): IUnicodeVersionProvider {
  return new TmuxUnicodeProvider(term);
}

/// What a tmux tab's instance runs instead of `loadRdevUnicode` (xterm-view.ts, `widths: "tmux"`).
export function loadTmuxUnicode(term: Terminal): void {
  const p = new TmuxUnicodeProvider(term);
  term.unicode.register(p);
  term.unicode.activeVersion = RDEV_TMUX_UNICODE_VERSION;
  // The host states the server's width options in band as the FIRST bytes of each snapshot, and every
  // snapshot builds a fresh instance (`TmuxSnapshot.emit`; xterm.js ignores an OSC nothing handles, so
  // a pty tab or an older client never sees it). A program in the pane can print the same OSC — tmux
  // forwards pane bytes raw — so it is accepted ONLY as the first thing this instance is given: the
  // instance's input is watched (its own `write`, whoever calls it) and a statement counts only if the
  // stream BEGAN with `ESC ] 9910 ;`, once. Anything else first — the host sent none (tmux's
  // defaults), a print, another sequence — closes it for good (final review I2, 2026-09-27).
  const opener = `\x1b]${TMUX_OPTIONS_OSC};`;
  let seen = "";                                  // the stream's first characters, until decided
  let state: "undecided" | "first" | "closed" = "undecided";
  const write = term.write.bind(term);
  (term as { write: Terminal["write"] }).write = (data: string | Uint8Array, cb?: () => void) => {
    if (state === "undecided" && data.length > 0) {
      const head = typeof data === "string" ? data.slice(0, opener.length)
        : String.fromCharCode(...data.subarray(0, opener.length));
      seen += head.slice(0, opener.length - seen.length);
      if (!opener.startsWith(seen)) state = "closed";
      else if (seen.length === opener.length) state = "first";
    }
    write(data, cb);
  };
  term.parser.registerOscHandler(TMUX_OPTIONS_OSC, (data) => {
    if (state === "first") p.setOptions(parseTmuxOptions(data));
    state = "closed";
    return true;
  });
}
