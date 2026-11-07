import { expect, test } from "vitest";
import { Codec, unwrap, wrap } from "../src/envelope";
import { deflate, inflate } from "../src/codecs-node";

const decompressors = { [Codec.Deflate]: inflate };

test("wrap leaves codec=none when compression does not save space", () => {
  const tiny = new Uint8Array([1, 2, 3, 4]); // random-ish, won't shrink
  const out = wrap(tiny, Codec.Deflate, deflate);
  expect(out[0]).toBe(Codec.None);
  expect(unwrap(out, decompressors)).toEqual(tiny);
});

test("wrap compresses when it saves space", () => {
  const big = new Uint8Array(2000).fill(0x20); // highly compressible
  const out = wrap(big, Codec.Deflate, deflate);
  expect(out[0]).toBe(Codec.Deflate);
  expect(out.length).toBeLessThan(big.length + 1);
  expect(unwrap(out, decompressors)).toEqual(big);
});

test("wrap never emits a frame larger than raw+1", () => {
  const data = new Uint8Array(64).fill(0xab);
  const out = wrap(data, Codec.Deflate, deflate);
  expect(out.length).toBeLessThanOrEqual(data.length + 1);
});

test("codec=none with empty body round-trips", () => {
  const out = wrap(new Uint8Array(), Codec.None, deflate);
  expect(out[0]).toBe(Codec.None);
  expect(unwrap(out, decompressors)).toEqual(new Uint8Array());
});

test("unwrap throws on an unsupported codec", () => {
  expect(() => unwrap(new Uint8Array([0x02, 1, 2]), decompressors)).toThrow(/unsupported codec/);
});

test("unwrap throws on empty envelope", () => {
  expect(() => unwrap(new Uint8Array(), decompressors)).toThrow(/empty envelope/);
});
