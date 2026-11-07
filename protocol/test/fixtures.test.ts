import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";
import { Codec, wrap } from "../src/envelope";
import { deflate } from "../src/codecs-node";

const UPDATE = process.env.UPDATE_FIXTURES === "1";

function fixturePath(name: string): string {
  return fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url));
}

// A 10-byte payload does not compress, so the envelope carries it as codec None — byte-portable across
// implementations (the Swift envelope test reads the same file). The bytes were a cursor frame of the
// retired cell-frame terminal; to the envelope they are opaque.
const payload = new Uint8Array([0x03, 0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x01]);
const envelopeNone = wrap(payload, Codec.Deflate, deflate);

test("golden fixture envelope-none.bin is stable", () => {
  const path = fixturePath("envelope-none.bin");
  if (UPDATE) writeFileSync(path, envelopeNone);
  expect(new Uint8Array(readFileSync(path))).toEqual(envelopeNone);
  expect(envelopeNone[0]).toBe(Codec.None);
});
