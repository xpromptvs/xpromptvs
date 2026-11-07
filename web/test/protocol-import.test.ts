import { expect, test } from "vitest";
import { Codec, unwrap, wrap } from "@rdev/protocol";
import { deflateSync, inflateSync } from "fflate";

test("fflate raw-DEFLATE plugs into the protocol envelope", () => {
  const big = new Uint8Array(2000).fill(0x20);
  const wrapped = wrap(big, Codec.Deflate, (p) => deflateSync(p));
  expect(wrapped[0]).toBe(Codec.Deflate); // compressed
  const back = unwrap(wrapped, { [Codec.Deflate]: (p) => inflateSync(p) });
  expect(back).toEqual(big);
});
