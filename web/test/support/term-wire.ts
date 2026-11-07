import { encodeTermFrame, TERM_CLOSED, TERM_OUTPUT, TERM_SNAPSHOT_CHUNK, TERM_SNAPSHOT_END, type TermFrame, type TermFrameKind } from "../../src/client/term-frame";

// Standalone early-offer previews still use DEFLATE.
const MAX_STORED = 0xffff;
const enc = new TextEncoder();

/** `bytes` as non-final stored DEFLATE blocks (an empty input is one empty block — a bare sync flush). */
export function storedDeflate(bytes: Uint8Array): Uint8Array {
  const blocks = Math.max(1, Math.ceil(bytes.length / MAX_STORED));
  const out = new Uint8Array(bytes.length + blocks * 5);
  let o = 0;
  for (let i = 0; i < blocks; i++) {
    const chunk = bytes.subarray(i * MAX_STORED, Math.min(bytes.length, (i + 1) * MAX_STORED));
    const n = chunk.length;
    out[o++] = 0x00;                                   // BFINAL 0, BTYPE 00, then padding to the byte
    out[o++] = n & 0xff; out[o++] = n >> 8;
    out[o++] = ~n & 0xff; out[o++] = (~n >> 8) & 0xff;
    out.set(chunk, o); o += n;
  }
  return out;
}

/** DEV/TEST ONLY: valid zstd stored blocks, decoded by the real client codec.
 * Product compression lives on the native host; this writer models the mock Mac. */
export class MockTermWire {
  private sequence = 0n;
  constructor(readonly epoch: bigint) {}
  start(): Uint8Array {
    this.sequence = 0n;
    const raw = this.block(Uint8Array.from({ length: 32 }, (_, i) => i));
    const compressed = new Uint8Array(6 + raw.length);
    compressed.set([0x28,0xb5,0x2f,0xfd,0,56]); compressed.set(raw, 6);
    return this.envelope(0, compressed);
  }
  record(frame: TermFrame): Uint8Array {
    const raw = encodeTermFrame(frame);
    if (raw.length > 60 * 1024 - 128) throw new Error('mock terminal record too large');
    return this.envelope(1, this.block(raw), raw.length);
  }
  snapshot(tab: string, cols: number, rows: number, text: string): Uint8Array[] {
    return this.chunks(tab, enc.encode(text), TERM_SNAPSHOT_CHUNK, TERM_SNAPSHOT_END, cols, rows);
  }
  output(tab: string, text: string): Uint8Array[] { return this.chunks(tab, enc.encode(text), TERM_OUTPUT, TERM_OUTPUT); }
  closed(tab: string): Uint8Array { return this.record({ kind: TERM_CLOSED, tab, payload: new Uint8Array() }); }
  private chunks(tab: string, payload: Uint8Array, chunk: TermFrameKind, end: TermFrameKind, cols?: number, rows?: number): Uint8Array[] {
    const room = 8192 - 128 - 2 - enc.encode(tab).length - (cols === undefined ? 0 : 4);
    const out: Uint8Array[] = [];
    for (let i = 0; i < Math.max(1, payload.length); i += room) {
      out.push(this.record({ tab, kind: i + room >= payload.length ? end : chunk, cols, rows, payload: payload.subarray(i, i + room) }));
    }
    return out;
  }
  private block(raw: Uint8Array): Uint8Array {
    const out = new Uint8Array(3 + raw.length), header = raw.length << 3;
    out.set([header & 255, (header >> 8) & 255, (header >> 16) & 255]); out.set(raw, 3); return out;
  }
  private envelope(type: 0 | 1, compressed: Uint8Array, length = 0): Uint8Array {
    const header = type === 0 ? 13 : 25, out = new Uint8Array(header + compressed.length);
    out.set([82,90,84,49,type]); const view = new DataView(out.buffer); view.setBigUint64(5, this.epoch);
    if (type === 1) { view.setBigUint64(13, this.sequence++); view.setUint32(21, length); }
    out.set(compressed, header); return out;
  }
}
