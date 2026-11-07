import { Codec, unwrap, wrap, type Compressor, type Decompressor } from "@rdev/protocol";
import { deflateSync, inflateSync } from "fflate";

export const deflate: Compressor = (p) => deflateSync(p);
export const inflate: Decompressor = (p) => inflateSync(p);

const decompressors: Record<number, Decompressor> = { [Codec.Deflate]: inflate };

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

/** Wrap raw frame bytes (terminal channel). Attempts deflate, keeps raw if no savings. */
export function encodeBinary(payload: Uint8Array, codec: number = Codec.Deflate): Uint8Array {
  return wrap(payload, codec, deflate);
}
export function decodeBinary(bytes: Uint8Array): Uint8Array {
  return unwrap(bytes, decompressors);
}

/** Wrap a JSON message (input/control). Defaults to no compression (messages are tiny). */
export function encodeJson(obj: unknown, codec: number = Codec.None): Uint8Array {
  return wrap(textEncoder.encode(JSON.stringify(obj)), codec, deflate);
}
export function decodeJson<T>(bytes: Uint8Array): T {
  return JSON.parse(textDecoder.decode(decodeBinary(bytes))) as T;
}
