// Everything about an xterm.js 6 instance that a restore must reproduce, as plain data: every cell of
// both buffers (chars, width, attributes), wrap flags, cursor (including the pending-wrap x === cols),
// regions, tab stops, saved cursors, modes, mouse protocol/encoding, charsets and the current pen.
// Internal fields are read through `_core` (the npm build keeps these names — measured on 6.0.0). A
// renamed OBJECT in an upgrade makes this throw; a renamed LEAF reads `undefined` on both sides, which
// the fidelity test's "no captured field reads undefined" catches instead.
import type { IBuffer, Terminal } from "@xterm/xterm";

type Attr = {
  isFgDefault(): boolean; isFgRGB(): boolean; getFgColor(): number;
  isBgDefault(): boolean; isBgRGB(): boolean; getBgColor(): number;
  isBold(): number; isDim(): number; isItalic(): number; isUnderline(): number; isBlink(): number;
  isInverse(): number; isInvisible(): number; isStrikethrough(): number;
  getUnderlineStyle(): number; isUnderlineColorDefault(): boolean; isUnderlineColorRGB(): boolean; getUnderlineColor(): number;
};
type InternalBuffer = {
  x: number; y: number; ybase: number; scrollTop: number; scrollBottom: number;
  tabs: Record<number, boolean | undefined>;
  savedX: number; savedY: number; savedCurAttrData: Attr; savedCharset: unknown;
};
type Core = {
  buffers: { normal: InternalBuffer; alt: InternalBuffer };
  buffer: InternalBuffer;
  coreService: { isCursorHidden: boolean; decPrivateModes: { cursorStyle?: string; cursorBlink?: boolean } };
  coreMouseService: { activeProtocol: string; activeEncoding: string };
  _charsetService: { glevel: number; _charsets: unknown[] };
  optionsService: { rawOptions: { cursorStyle: string; cursorBlink: boolean } };
  _inputHandler: { _curAttrData: Attr };
};

/// Palette colours compare by INDEX: SwiftTerm does not keep P16 vs P256 (docs/terminal.md, Known limits).
const color = (isDefault: boolean, isRGB: boolean, v: number) => (isDefault ? "d" : isRGB ? `rgb${v.toString(16)}` : `p${v}`);

export function attrKey(a: Attr): string {
  const flags = [a.isBold() && "b", a.isDim() && "d", a.isItalic() && "i", a.isBlink() && "k", a.isInverse() && "r",
    a.isInvisible() && "h", a.isStrikethrough() && "s"].filter(Boolean).join("");
  const ul = a.isUnderline() ? a.getUnderlineStyle() || 1 : 0;
  const ulc = a.isUnderline() && !a.isUnderlineColorDefault() ? color(false, a.isUnderlineColorRGB(), a.getUnderlineColor()) : "d";
  return `${color(a.isFgDefault(), a.isFgRGB(), a.getFgColor())}/${color(a.isBgDefault(), a.isBgRGB(), a.getBgColor())}/${flags}/u${ul}/${ulc}`;
}

function lines(t: Terminal, b: IBuffer) {
  return Array.from({ length: b.length }, (_, i) => {
    const l = b.getLine(i)!;
    const cells: string[] = [];
    for (let x = 0; x < t.cols; x++) {
      const c = l.getCell(x)! as unknown as Attr & { getChars(): string; getWidth(): number };
      cells.push(`${JSON.stringify(c.getChars())}:${c.getWidth()}:${attrKey(c)}`);
    }
    return { wrapped: l.isWrapped, cells };
  });
}

function internal(b: InternalBuffer) {
  return {
    scrollTop: b.scrollTop, scrollBottom: b.scrollBottom,
    // Stops at or past cols (kept by xterm.js after a shrink) are not in a snapshot: docs/terminal.md, Known limits.
    tabs: Object.keys(b.tabs).map(Number).filter((k) => b.tabs[k]).sort((p, q) => p - q),
    // xterm.js stores savedY ABSOLUTE (ybase + y) and DECRC restores max(savedY - ybase, 0); SwiftTerm's
    // is screen-relative, so the snapshot can only state the row DECRC lands on NOW. Compare that.
    // (After further scrolling the two differ: docs/terminal.md, Known limits.)
    saved: { x: b.savedX, y: Math.max(b.savedY - b.ybase, 0), attr: attrKey(b.savedCurAttrData), charset: JSON.stringify(b.savedCharset ?? null) },
  };
}

export function captureState(t: Terminal) {
  const core = (t as unknown as { _core: Core })._core;
  const activeIsAlt = t.buffer.active.type === "alternate";
  const dec = core.coreService.decPrivateModes, opts = core.optionsService.rawOptions;
  return {
    cols: t.cols, rows: t.rows, activeIsAlt,
    normal: { lines: lines(t, t.buffer.normal), ...internal(core.buffers.normal) },
    alt: activeIsAlt ? { lines: lines(t, t.buffer.alternate), ...internal(core.buffers.alt) } : null,
    cursor: {
      x: core.buffer.x, y: core.buffer.y, hidden: core.coreService.isCursorHidden,
      // DECSCUSR 0/1 and "never set" render identically: normalise to the effective style.
      style: dec.cursorStyle ?? opts.cursorStyle, blink: dec.cursorBlink ?? opts.cursorBlink,
    },
    modes: { ...t.modes },
    mouse: { protocol: core.coreMouseService.activeProtocol, encoding: core.coreMouseService.activeEncoding },
    // The pen the next printed character gets, and the erase attribute's background.
    pen: attrKey(core._inputHandler._curAttrData),
    charsets: { glevel: core._charsetService.glevel, g: [0, 1, 2, 3].map((i) => JSON.stringify(core._charsetService._charsets[i] ?? null)) },
  };
}
export type XtermState = ReturnType<typeof captureState>;

/// Paths where `b` differs from `a`, first `limit` of them — a readable failure instead of a 10 MB dump.
export function diffStates(a: unknown, b: unknown, path = "$", out: string[] = [], limit = 20): string[] {
  if (out.length >= limit) return out;
  if (typeof a !== "object" || a === null || typeof b !== "object" || b === null) {
    if (a !== b) out.push(`${path}: ${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`);
    return out;
  }
  if (Array.isArray(a) !== Array.isArray(b)) { out.push(`${path}: array vs object`); return out; }
  if (Array.isArray(a) && Array.isArray(b) && a.length !== b.length) out.push(`${path}.length: ${a.length} ≠ ${b.length}`);
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const k of keys) diffStates((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k], `${path}.${k}`, out, limit);
  return out;
}
