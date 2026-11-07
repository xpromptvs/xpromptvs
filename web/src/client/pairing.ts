import { decodePairingSeed, derivePairing } from "@rdev/protocol";

export interface Pairing {
  code: string;
  token: string;
  /// §9.1's pre-shared key, present exactly when the carrier was a SEED — which is the only input
  /// that can produce one. A `?code=&token=` link admits a client to the room and gives it nothing
  /// to handshake `pair` with, and that difference is the whole reason this field is optional.
  psk?: Uint8Array;
}

/**
 * Parse what a person carried: a v3 pairing code, or a pasted connect URL / query string.
 *
 * **THE SEED TRAVELS IN THE FRAGMENT, NEVER THE QUERY.** A query string is sent to the Control Plane
 * on the very first navigation, and §9.1 forbids the seed reaching it — so a link that carries one
 * puts it after `#`, which no browser transmits. Accepting a seed from a query would turn a correct
 * link into a leak the moment someone rewrote it by hand.
 *
 * Async because the derivation is HKDF through SubtleCrypto; the v2 carrier it replaces was a pure
 * byte-slice and needed none.
 */
export async function parsePairing(input: string): Promise<Pairing | null> {
  const s = input.trim();
  if (s === "") return null;

  // **URLS FIRST, BECAUSE SHAPE IS THE DISCRIMINATOR NOW.** The `ss3.` prefix is gone, so a bare
  // carrier is recognised by being exactly 22 base64url characters — and a URL can never be that,
  // since none of `:`, `/`, `?`, `#` or `=` is in the alphabet. Testing the URL shape first keeps
  // the two rules from ever having to disagree.
  //
  // A pasted link's FRAGMENT is checked before its query, because a link carrying a seed carries
  // everything and the query's code/token would be a strictly weaker reading of the same link.
  if (s.includes("://") || s.includes("?") || s.includes("#") || s.includes("code=")) {
    const hash = s.indexOf("#");
    if (hash >= 0) {
      const fragment = new URLSearchParams(s.slice(hash + 1));
      const pair = fragment.get("pair");
      if (pair) return fromSeed(pair);
    }
    const q = s.indexOf("?");
    const end = hash >= 0 ? hash : s.length;
    const p = new URLSearchParams(q >= 0 ? s.slice(q + 1, end) : s.slice(0, end));
    const code = p.get("code");
    const token = p.get("token");
    return code && token ? { code, token } : null;
  }

  // A bare carrier. `fromSeed` -> `decodePairingSeed` enforces the exact length and alphabet, so
  // nothing that is not one reaches a derivation.
  return fromSeed(s);
}

async function fromSeed(carrier: string): Promise<Pairing | null> {
  const seed = decodePairingSeed(carrier);
  if (!seed) return null;
  const material = await derivePairing(seed);
  return material ? { code: material.code, token: material.token, psk: material.psk } : null;
}
