import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { RENDEZVOUS_SALT, deriveRendezvous } from "../src/rendezvous-seed";
import { PAIRING_ALPHABET, PAIRING_SALT, derivePairing } from "../src/pairing-seed";

// The §9.2 durable-route derivation, against vectors a THIRD implementation produced
// (`scripts/gen_rendezvous_fixture.py`) and which `RendezvousSeedTests.swift` asserts too.
interface Case {
  name: string; seed: string; rcode: string; rtoken: string;
  pairing_code?: string; pairing_seed?: string; pairing_token?: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/rendezvous-v7.json", import.meta.url)), "utf8")) as
  { salt: string; alphabet: string; cases: Case[] };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));

describe("cross-implementation vectors", () => {
  for (const c of fx.cases) {
    test(c.name, async () => {
      const route = await deriveRendezvous(hex(c.seed));
      expect(route).not.toBeNull();
      expect(route!.rcode).toBe(c.rcode);
      expect(route!.rtoken).toBe(c.rtoken);
    });
  }

  test("the fixture's salt and alphabet are the ones this module uses", () => {
    // The constants are the derivation. A fixture regenerated under a different salt would agree
    // with itself forever and with no shipped build.
    expect(fx.salt).toBe(RENDEZVOUS_SALT);
    expect(fx.alphabet).toBe(PAIRING_ALPHABET);
  });
});

// §9.1 and §9.2 are THE SAME CONSTRUCTION under different labels, which is exactly why this is worth
// a test: a build that derived a durable route under the pairing salt would produce a perfectly
// well-formed code and token, register them, and be unreachable at the address every peer persisted.
test("the label separates the two derivations completely", async () => {
  const c = fx.cases.find((x) => x.pairing_code !== undefined)!;
  const route = (await deriveRendezvous(hex(c.seed)))!;
  // §9.1's seed is 16 bytes and §9.2's is 32, so the fixture carries the pairing half explicitly:
  // the first 16 bytes of the same material, under the other label.
  const pairing = (await derivePairing(hex(c.pairing_seed!)))!;

  expect(RENDEZVOUS_SALT).not.toBe(PAIRING_SALT);
  expect(route.rcode).toBe(c.rcode);
  expect(pairing.code).toBe(c.pairing_code);
  expect(route.rcode).not.toBe(pairing.code);
  expect(route.rtoken).not.toBe(pairing.token);
});

test("a rendezvous route carries no psk to leak", async () => {
  // §9.2 has no psk by design: a durable route is public, and all the authority is in the chain.
  // Stated as a test because "add a psk here for symmetry with §9.1" is the tempting wrong move.
  const route = (await deriveRendezvous(new Uint8Array(32)))!;
  expect(Object.keys(route).sort()).toEqual(["rcode", "rtoken"]);
});

describe("seed length is enforced, never padded", () => {
  for (const n of [0, 16, 31, 33, 64]) {
    test(`${n} bytes`, async () => {
      expect(await deriveRendezvous(new Uint8Array(n))).toBeNull();
    });
  }
});

test("rcode is 8 characters, all from the alphabet", async () => {
  const route = (await deriveRendezvous(hex(fx.cases[0]!.seed)))!;
  expect(route.rcode).toHaveLength(8);
  for (const ch of route.rcode) expect(PAIRING_ALPHABET).toContain(ch);
  // Lowercase UUID: the session Durable Object compares tokens as exact strings.
  expect(route.rtoken).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
