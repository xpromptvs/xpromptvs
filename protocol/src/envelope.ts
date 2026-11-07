export const Codec = {
  None: 0x00,
  Deflate: 0x01,
  Lzfse: 0x02,
  Zstd: 0x03,
} as const;

export type Compressor = (payload: Uint8Array) => Uint8Array;
export type Decompressor = (payload: Uint8Array) => Uint8Array;

/** Prefix a body with its 1-byte codec id. */
function prefix(codec: number, body: Uint8Array): Uint8Array {
  const out = new Uint8Array(body.length + 1);
  out[0] = codec;
  out.set(body, 1);
  return out;
}

/**
 * Wrap a payload with a 1-byte codec prefix, compressing only when it saves space.
 * Honors the "any savings" rule: compressed form is used iff strictly smaller than raw.
 */
export function wrap(payload: Uint8Array, codec: number, compress: Compressor): Uint8Array {
  if (codec !== Codec.None) {
    const compressed = compress(payload);
    if (compressed.length < payload.length) {
      return prefix(codec, compressed);
    }
  }
  return prefix(Codec.None, payload);
}

/** Read the codec byte and return the original payload, decompressing if needed. */
export function unwrap(bytes: Uint8Array, decompressors: Record<number, Decompressor>): Uint8Array {
  if (bytes.length === 0) throw new Error("empty envelope");
  const codec = bytes[0]!;
  const body = bytes.subarray(1);
  if (codec === Codec.None) return new Uint8Array(body);
  const d = decompressors[codec];
  if (!d) throw new Error(`unsupported codec 0x${codec.toString(16)}`);
  return d(body);
}
