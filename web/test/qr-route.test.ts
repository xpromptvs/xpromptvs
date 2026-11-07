import { describe, expect, test } from "vitest";
import { PAIRING_SEED_BYTES, encodePairingSeed } from "@rdev/protocol";
import { routeScanned } from "../src/client/qr-route";

/**
 * **WHERE THE ORIGIN RULE LIVES.** A QR is untrusted input from the physical world: anyone who can
 * put a sticker on a Mac can put a URL in front of a person who is, at that moment, holding a
 * passkey and expecting to approve something. Everything this file asserts is about refusing that
 * without also refusing the ordinary cases.
 */

const ORIGIN = "https://rdev.example";
/// A REAL carrier, from the protocol's own encoder — a hand-typed one would not decode, and the
/// `code` route below would then pass for the wrong reason.
const CARRIER = encodePairingSeed(new Uint8Array(PAIRING_SEED_BYTES).fill(7))!;

describe("routeScanned", () => {
  test("an adopt URL on this origin is an adoption", async () => {
    expect(await routeScanned(`${ORIGIN}/#adopt=${CARRIER}`, ORIGIN))
      .toEqual({ kind: "adopt", carrier: CARRIER });
  });

  test("a connect URL on this origin is a connection", async () => {
    const r = await routeScanned(`${ORIGIN}/?code=abc12345&token=t-1`, ORIGIN);
    expect(r.kind).toBe("connect");
    if (r.kind === "connect") expect(r.search).toContain("code=abc12345");
  });

  /** **THE RULE THIS FILE EXISTS FOR.** */
  test("a URL on ANY other origin is refused, and named", async () => {
    expect(await routeScanned(`https://evil.example/#adopt=${CARRIER}`, ORIGIN))
      .toEqual({ kind: "foreign", origin: "https://evil.example" });
  });

  // Each of these differs from ORIGIN in one of the three ways an origin can: host, scheme, port.
  test("a look-alike origin is still foreign", async () => {
    for (const bad of ["https://rdev.example.evil.com", "http://rdev.example",
                       "https://rdev-example.com", "https://rdev.example:8443"]) {
      expect((await routeScanned(`${bad}/#adopt=${CARRIER}`, ORIGIN)).kind, bad).toBe("foreign");
    }
  });

  /**
   * **A BARE CARRIER NAMES NO DESTINATION**, so the origin rule has nothing to say about it — it is
   * a secret and nothing else, and refusing it would break photographing a code shown as text.
   */
  test("a bare carrier is accepted and left for the person to submit", async () => {
    expect(await routeScanned(CARRIER, ORIGIN)).toEqual({ kind: "code", text: CARRIER });
  });

  /**
   * **A BARE v2 CODE IS NOT ACCEPTED, and that is the product's behaviour rather than an oversight.**
   * `parsePairing` decodes a 22-character carrier and links; the 30-character v2 one is retired, and both
   * the app and the harness print the v3 one. Pinned so a future reader does not "restore" support
   * for a code nothing emits.
   */
  test("a retired 30-character v2 code is unknown", async () => {
    expect((await routeScanned("1alQfiLoSeeKnQRcgpYMI65ubJGlGQ", ORIGIN)).kind).toBe("unknown");
  });

  test("anything else is unknown or foreign, never guessed at", async () => {
    for (const junk of ["", "   ", "hello", "https://", "ftp://x/#adopt=y"]) {
      expect((await routeScanned(junk, ORIGIN)).kind, junk).toMatch(/unknown|foreign/);
    }
  });

  // The fragment carries the seed, which is strictly more than code+token — and `parsePairing`
  // already reads fragments first for exactly this reason.
  test("a link carrying both prefers the adoption", async () => {
    expect(await routeScanned(`${ORIGIN}/?code=abc12345&token=t-1#adopt=${CARRIER}`, ORIGIN))
      .toEqual({ kind: "adopt", carrier: CARRIER });
  });
});
