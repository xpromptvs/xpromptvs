/// THE LANE'S WIRE FORMAT (docs/superpowers/specs/2026-10-12-terminal-lane-design.md §2), mirrored byte for byte by
/// host/streaming-engine/PionBridge/rdev_lane_codec.go and held to protocol/fixtures/lane-vectors.json
/// (scripts/gen_lane_vectors.py). Big-endian. Counters travel in 32 bits; `unwrapLane32` restores them.

/// One data-channel message, one SCTP packet on both stacks (Chrome's dcsctp MTU is the smaller): a message split
/// across packets is lost when any one is, and nothing re-sends it.
export const LANE_PACKET_MAX = 1100;
export const LANE_HEADER_BYTES = 9;
/// A symbol INCLUDING its 2-byte length prefix — a REPAIR over full symbols is 19 + 1080 bytes.
export const LANE_SYMBOL_MAX = 1080;
export const LANE_CHUNK_HEADER = 7;
export const LANE_RANGES_MAX = 16;
export const LANE_TYPE_SOURCE = 1;
export const LANE_TYPE_REPAIR = 2;
export const LANE_TYPE_FEEDBACK = 3;
/// terminal 0, input 1, control 2 — the host ABI's channel slots.
export const LANE_STREAMS = 3;

export interface LaneRange { start: number; length: number }
export interface LaneFeedback { cumEsi: number; ranges: LaneRange[]; lossPermille: number; echoTs: number; held: number }
export type LanePacket =
  | { kind: typeof LANE_TYPE_SOURCE; pkt: number; ts: number; esi: number; payload: Uint8Array }
  | { kind: typeof LANE_TYPE_REPAIR; pkt: number; ts: number; esi: number; count: number; seed: number; payload: Uint8Array }
  | { kind: typeof LANE_TYPE_FEEDBACK; pkt: number; ts: number; feedback: LaneFeedback };
export interface LaneChunk { stream: number; offset: number; bytes: Uint8Array }

function header(kind: number, pkt: number, ts: number, size: number): [Uint8Array<ArrayBuffer>, DataView] {
  const out = new Uint8Array(size);
  const view = new DataView(out.buffer);
  out[0] = kind;
  view.setUint32(1, pkt >>> 0);
  view.setUint32(5, ts >>> 0);
  return [out, view];
}

export function encodeLaneSource(pkt: number, ts: number, esi: number, symbol: Uint8Array): Uint8Array<ArrayBuffer> {
  const [out, view] = header(LANE_TYPE_SOURCE, pkt, ts, LANE_HEADER_BYTES + 4 + symbol.length);
  view.setUint32(9, esi >>> 0);
  out.set(symbol, 13);
  return out;
}

export function encodeLaneRepair(pkt: number, ts: number, firstEsi: number, count: number, seed: number,
                                 payload: Uint8Array): Uint8Array<ArrayBuffer> {
  const [out, view] = header(LANE_TYPE_REPAIR, pkt, ts, LANE_HEADER_BYTES + 10 + payload.length);
  view.setUint32(9, firstEsi >>> 0);
  view.setUint16(13, count);
  view.setUint32(15, seed >>> 0);
  out.set(payload, 19);
  return out;
}

export function encodeLaneFeedback(pkt: number, ts: number, f: LaneFeedback): Uint8Array<ArrayBuffer> {
  const [out, view] = header(LANE_TYPE_FEEDBACK, pkt, ts, LANE_HEADER_BYTES + 5 + 6 * f.ranges.length + 8);
  view.setUint32(9, f.cumEsi >>> 0);
  out[13] = f.ranges.length;
  let at = 14;
  for (const r of f.ranges) {
    view.setUint32(at, r.start >>> 0);
    view.setUint16(at + 4, r.length);
    at += 6;
  }
  view.setUint16(at, f.lossPermille);
  view.setUint32(at + 2, f.echoTs >>> 0);
  view.setUint16(at + 6, f.held);
  return out;
}

/// One lane packet, or null when it is not a well-formed one. Payloads are COPIES.
export function decodeLanePacket(b: Uint8Array): LanePacket | null {
  if (b.length < LANE_HEADER_BYTES || b.length > LANE_PACKET_MAX) return null;
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const pkt = view.getUint32(1), ts = view.getUint32(5);
  const body = b.length - LANE_HEADER_BYTES;
  switch (b[0]) {
    case LANE_TYPE_SOURCE:
      if (body < 6 || body - 4 > LANE_SYMBOL_MAX) return null;
      return { kind: LANE_TYPE_SOURCE, pkt, ts, esi: view.getUint32(9), payload: b.slice(13) };
    case LANE_TYPE_REPAIR: {
      if (body < 12 || body - 10 > LANE_SYMBOL_MAX) return null;
      const count = view.getUint16(13);
      if (count === 0) return null;
      return { kind: LANE_TYPE_REPAIR, pkt, ts, esi: view.getUint32(9), count, seed: view.getUint32(15), payload: b.slice(19) };
    }
    case LANE_TYPE_FEEDBACK: {
      if (body < 5) return null;
      const n = b[13]!;
      if (n > LANE_RANGES_MAX || body !== 5 + 6 * n + 8) return null;
      const ranges: LaneRange[] = [];
      let at = 14;
      for (let i = 0; i < n; i++) {
        ranges.push({ start: view.getUint32(at), length: view.getUint16(at + 4) });
        at += 6;
      }
      return {
        kind: LANE_TYPE_FEEDBACK, pkt, ts,
        feedback: { cumEsi: view.getUint32(9), ranges, lossPermille: view.getUint16(at), echoTs: view.getUint32(at + 2),
                    held: view.getUint16(at + 6) },
      };
    }
    default:
      return null;
  }
}

/// A symbol: `len u16` (the chunk bytes that follow), then each chunk `stream u8 · offset u32 · len u16 · bytes`.
export function buildLaneSymbol(chunks: readonly LaneChunk[]): Uint8Array {
  let size = 0;
  for (const c of chunks) size += LANE_CHUNK_HEADER + c.bytes.length;
  const out = new Uint8Array(2 + size);
  const view = new DataView(out.buffer);
  view.setUint16(0, size);
  let at = 2;
  for (const c of chunks) {
    out[at] = c.stream;
    view.setUint32(at + 1, c.offset >>> 0);
    view.setUint16(at + 5, c.bytes.length);
    out.set(c.bytes, at + LANE_CHUNK_HEADER);
    at += LANE_CHUNK_HEADER + c.bytes.length;
  }
  return out;
}

/// A symbol read back — from a SOURCE, or rebuilt from repair and so zero-padded past its length (harmless: the
/// prefix says where it ends). Null when malformed.
export function parseLaneSymbol(symbol: Uint8Array): LaneChunk[] | null {
  if (symbol.length < 2) return null;
  const view = new DataView(symbol.buffer, symbol.byteOffset, symbol.byteLength);
  const end = 2 + view.getUint16(0);
  if (end > symbol.length) return null;
  const chunks: LaneChunk[] = [];
  for (let at = 2; at < end;) {
    if (end - at < LANE_CHUNK_HEADER) return null;
    const stream = symbol[at]!, length = view.getUint16(at + 5);
    if (stream >= LANE_STREAMS || LANE_CHUNK_HEADER + length > end - at) return null;
    chunks.push({ stream, offset: view.getUint32(at + 1), bytes: symbol.slice(at + LANE_CHUNK_HEADER, at + LANE_CHUNK_HEADER + length) });
    at += LANE_CHUNK_HEADER + length;
  }
  return chunks;
}

const TWO_32 = 2 ** 32;

/// The counter nearest `reference` whose low 32 bits are `wire` (the live window is far below 2³¹). Exact for
/// counters below 2⁵³.
export function unwrapLane32(reference: number, wire: number): number {
  const candidate = Math.floor(reference / TWO_32) * TWO_32 + (wire >>> 0);
  if (candidate > reference && candidate - reference > 2 ** 31 && candidate >= TWO_32) return candidate - TWO_32;
  if (candidate < reference && reference - candidate > 2 ** 31) return candidate + TWO_32;
  return candidate;
}
