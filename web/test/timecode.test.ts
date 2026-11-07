// web/test/timecode.test.ts
import { expect, test } from "vitest";
import { TIMECODE_BITS, encodeTimecodeBits, decodeTimecodeBits } from "../src/lib/timecode";

test("bit count is 32", () => { expect(TIMECODE_BITS).toBe(32); });

test("round-trips values", () => {
  for (const v of [0, 1, 0x0a0b0c0d, 0xffffffff, 123456789]) {
    expect(decodeTimecodeBits(encodeTimecodeBits(v))).toBe(v >>> 0);
  }
});

test("golden vector matches the Swift contract (MSB-first)", () => {
  const bits = encodeTimecodeBits(0x0a0b0c0d).map((b) => (b ? "1" : "0")).join("");
  expect(bits).toBe("00001010000010110000110000001101");
});
