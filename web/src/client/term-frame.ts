// The terminal channel's frames (docs/terminal.md, "The terminal channel"). Mirrors
// host/RdevCore/Sources/RdevCore/TermFrame.swift byte for byte:
//   [u8 kind][u8 tabIdLen][tabId utf8] + ([u16be cols][u16be rows] for kinds 1 and 2) + payload
// RZT1 compresses the entire record. Legacy kind 4 is reserved and rejected inside DATA.
export const TERM_OUTPUT = 0;
export const TERM_SNAPSHOT_CHUNK = 1;
export const TERM_SNAPSHOT_END = 2;
export const TERM_CLOSED = 3;
export const TERM_WIRE_START = 4;
/// THE LATE HISTORY (docs/terminal.md, "Scrollback comes after the screen"): the tab's FULL snapshot, taken at the same
/// moment as the screen-only snapshot that began its current generation, inside the shared wire compression context.
export const TERM_HISTORY_CHUNK = 5;
export const TERM_HISTORY_END = 6;
/// A snapshot of the SCREEN alone whose history follows: otherwise exactly a snapshot chunk/end.
export const TERM_SCREEN_CHUNK = 7;
export const TERM_SCREEN_END = 8;
export type TermFrameKind = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8;

export interface TermFrame { kind: TermFrameKind; tab: string; cols?: number; rows?: number; payload: Uint8Array }

const enc = new TextEncoder();
const dec = new TextDecoder();
const carriesSize = (k: number) => k !== TERM_OUTPUT && k !== TERM_CLOSED && k !== TERM_WIRE_START;

export function parseTermFrame(b: Uint8Array): TermFrame | null {
  if (b.length < 2 || b[0]! > TERM_SCREEN_END) return null;
  const kind = b[0] as TermFrameKind;
  const n = b[1]!;
  if (kind === TERM_WIRE_START) return n === 0 && b.length === 2 ? { kind, tab: "", payload: new Uint8Array() } : null;
  if (n === 0 || b.length < 2 + n) return null;
  const tab = dec.decode(b.subarray(2, 2 + n));
  let i = 2 + n;
  if (carriesSize(kind)) {
    if (b.length < i + 4) return null;
    const cols = (b[i]! << 8) | b[i + 1]!, rows = (b[i + 2]! << 8) | b[i + 3]!;
    return { kind, tab, cols, rows, payload: b.subarray(i + 4) };
  }
  return { kind, tab, payload: b.subarray(i) };
}

export function encodeTermFrame(f: TermFrame): Uint8Array {
  if (f.kind === TERM_WIRE_START) return new Uint8Array([TERM_WIRE_START, 0]);
  const id = enc.encode(f.tab);
  const size = carriesSize(f.kind) ? 4 : 0;
  const out = new Uint8Array(2 + id.length + size + f.payload.length);
  out[0] = f.kind; out[1] = id.length; out.set(id, 2);
  let i = 2 + id.length;
  if (size) {
    const c = f.cols ?? 0, r = f.rows ?? 0;
    out.set([(c >> 8) & 0xff, c & 0xff, (r >> 8) & 0xff, r & 0xff], i);
    i += 4;
  }
  out.set(f.payload, i);
  return out;
}
