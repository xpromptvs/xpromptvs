import { Codec } from "@rdev/protocol";
import { expect, test } from "vitest";
import { decodeBinary, decodeJson, encodeBinary, encodeJson } from "../src/lib/codec";

test("binary round-trips and compresses large payloads", () => {
  const big = new Uint8Array(2000).fill(7);
  const enc = encodeBinary(big);
  expect(enc[0]).toBe(Codec.Deflate);
  expect(decodeBinary(enc)).toEqual(big);
});

test("binary leaves tiny payloads uncompressed (any-savings gate)", () => {
  const tiny = new Uint8Array([1, 2, 3, 4]);
  const enc = encodeBinary(tiny);
  expect(enc[0]).toBe(Codec.None);
  expect(decodeBinary(enc)).toEqual(tiny);
});

test("json round-trips", () => {
  const enc = encodeJson({ t: "touch", phase: "down", id: 0, x: 0.5, y: 0.5, ts: 1 });
  const obj = decodeJson<{ t: string; x: number }>(enc);
  expect(obj.t).toBe("touch");
  expect(obj.x).toBe(0.5);
});
