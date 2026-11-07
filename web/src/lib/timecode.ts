// web/src/lib/timecode.ts
// Mirror of RdevCore/LatencyTimecode.swift — keep the golden vector test in sync with the Swift one.
export const TIMECODE_BITS = 32;

/** MSB-first bits of the low 32 of `value` (unsigned). */
export function encodeTimecodeBits(value: number): boolean[] {
  const bits: boolean[] = [];
  for (let i = 0; i < TIMECODE_BITS; i++) {
    const shift = TIMECODE_BITS - 1 - i;
    bits.push(((value >>> shift) & 1) === 1);
  }
  return bits;
}

/** MSB-first bits → unsigned 32-bit value. */
export function decodeTimecodeBits(bits: boolean[]): number {
  let v = 0;
  for (let i = 0; i < TIMECODE_BITS; i++) {
    v = (v << 1) >>> 0;
    if (bits[i]) v = (v | 1) >>> 0;
  }
  return v >>> 0;
}
