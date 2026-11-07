/** Versioned application records shared by encrypted WebSocket and WebRTC carriers. */
export type FastStream = 0 | 1 | 2;
export type FastKind = 1 | 2 | 3 | 4;
export interface FastRecord {
  kind: FastKind;
  generation: Uint8Array;
  stream: FastStream;
  /** Byte offset for data/ack, unpredictable challenge for probes. */
  value: bigint;
  bytes: Uint8Array;
}
export const FAST_RECORD_MAX = 8192;
export const FAST_U64_MAX = (1n << 64n) - 1n;
export function encodeFastRecord(r: FastRecord): Uint8Array {
  if (r.generation.length !== 16 || !Number.isInteger(r.stream) || r.stream < 0 || r.stream > 2 ||
      !Number.isInteger(r.kind) || r.kind < 1 || r.kind > 4 || r.value < 0n || r.value > FAST_U64_MAX ||
      (r.kind === 1 ? r.bytes.length < 1 || r.bytes.length > FAST_RECORD_MAX : r.bytes.length !== 0)) throw new Error('invalid fast record');
  const out = new Uint8Array(r.kind === 1 ? 29 + r.bytes.length : 27);
  const view = new DataView(out.buffer);
  out[0] = 1; out[1] = r.kind; out.set(r.generation, 2); out[18] = r.stream;
  view.setBigUint64(19, r.value);
  if (r.kind === 1) { view.setUint16(27, r.bytes.length); out.set(r.bytes, 29); }
  return out;
}
export function decodeFastRecord(bytes: Uint8Array): FastRecord | null {
  if (bytes.length < 27 || bytes[0] !== 1) return null;
  const kind = bytes[1]!, stream = bytes[18]!;
  if (kind < 1 || kind > 4 || stream > 2) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (kind === 1) {
    if (bytes.length < 30) return null;
    const n = view.getUint16(27);
    if (n < 1 || n > FAST_RECORD_MAX || bytes.length !== 29 + n) return null;
  } else if (bytes.length !== 27) return null;
  return {kind: kind as FastKind, generation: bytes.slice(2, 18), stream: stream as FastStream, value: view.getBigUint64(19), bytes: kind === 1 ? bytes.slice(29) : new Uint8Array()};
}
