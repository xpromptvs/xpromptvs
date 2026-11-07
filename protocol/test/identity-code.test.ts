import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { identityCode } from "../src/identity-code";

// §10.1's identity as a person reads it. The vectors come from `scripts/gen_identity_code_fixture.py`
// — a THIRD implementation — because the Mac and the browser showing different strings would break
// the one comparison this code exists for.
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/identity-code.json", import.meta.url)), "utf8")) as {
    alphabet: string; bytes: number;
    vectors: Array<{ root_id: string; code: string }>;
  };

const hex = (h: string): Uint8Array =>
  Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));

describe("identityCode", () => {
  test("agrees with every vector", () => {
    for (const v of fx.vectors) {
      expect(identityCode(hex(v.root_id)), v.root_id).toBe(v.code);
    }
  });

  // A transposed alphabet passes on whichever rows happen to agree, so the set has to reach all 32.
  test("the vectors between them reach every character", () => {
    const seen = new Set(fx.vectors.flatMap((v) => [...v.code.replace(/-/g, "")]));
    expect([...seen].sort().join("")).toBe([...fx.alphabet].sort().join(""));
  });

  // No I, L, O or U — there is no pair of characters a person can confuse across two screens.
  test("the alphabet omits the glyphs that are read wrongly", () => {
    for (const c of "ILOU") expect(fx.alphabet).not.toContain(c);
    expect(fx.alphabet).toHaveLength(32);
  });

  test("sixteen characters in four groups, always", () => {
    for (const v of fx.vectors) {
      expect(v.code).toMatch(/^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/);
    }
  });

  // **Only the first ten bytes are read.** The fixture pads its tails with 0xAA so an implementation
  // that hashed or read all 32 would disagree; this states the rule directly too.
  test("only the first ten bytes matter", () => {
    const a = new Uint8Array(32).fill(0x11);
    const b = new Uint8Array(32).fill(0x11);
    b[10] = 0x99;
    expect(identityCode(a)).toBe(identityCode(b));
  });

  // An empty string rather than a half-length code: a caller showing "" has obviously nothing, while
  // a short code looks like an identity and is not one.
  test("too few bytes is nothing, not a shorter code", () => {
    expect(identityCode(new Uint8Array(9))).toBe("");
  });
});
