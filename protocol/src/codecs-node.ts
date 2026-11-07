import { deflateRawSync, inflateRawSync } from "node:zlib";
import type { Compressor, Decompressor } from "./envelope";

// Node reference compressors (raw DEFLATE, zlib-compatible / no header — matches Apple
// COMPRESSION_ZLIB and fflate's deflateSync/inflateSync). Node-only; not browser-safe.
export const deflate: Compressor = (p) => new Uint8Array(deflateRawSync(p));
export const inflate: Decompressor = (p) => new Uint8Array(inflateRawSync(p));
