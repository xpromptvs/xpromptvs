/// A Host's or pairing Issuer's DURABLE route: the address a peer returns to, derived once from a
/// 32-byte seed persisted beside the device keys. §9.2 of the E2E protocol specification.
///
/// Mirror of `RdevCore.RendezvousSeed` (Swift), held to `protocol/fixtures/rendezvous-v7.json`.
///
/// The same construction as §9.1's pairing derivation — HKDF over one seed, the same 64-character
/// alphabet, the same UUID formatting — with two differences that matter:
///
/// 1. **It is DURABLE, not one-time.** `rseed` is persisted with the device keys and the SAME route
///    is registered after every restart. §9.2: "A durable-route conflict fails visibly; do not
///    silently choose a new identity or address."
/// 2. **There is no `psk`.** A durable route is public by construction — "Addresses and room tokens
///    confer no E2E authority ... Room seizure is denial of service." All the authority is in the
///    chain, which is why an Issuer can safely send this address in Noise message 2.
///
/// **THE SALT IS `rdev/rendezvous/v7`, NOT `rdev-e2e/...`.** That is the spec's, and it is the one
/// label in this protocol without the `rdev-e2e` prefix. Do not "fix" it to match its neighbours:
/// the label IS the domain separation, and changing it changes every route ever derived.
import { PAIRING_ALPHABET } from "./pairing-seed";

export interface RendezvousRoute {
  rcode: string;
  rtoken: string;
}

export const RENDEZVOUS_SEED_BYTES = 32;

/// §9.2's salt, quoted exactly. See the module comment before changing it.
export const RENDEZVOUS_SALT = "rdev/rendezvous/v7";

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);

/// Derive the durable route, or null if the seed is not exactly 32 bytes.
///
/// THROWS rather than returning null when SubtleCrypto is unavailable, for the same reason
/// `derivePairing` does: an environment failure is not a malformed seed.
export async function deriveRendezvous (seed: Uint8Array): Promise<RendezvousRoute | null> {
  if (seed.length !== RENDEZVOUS_SEED_BYTES) return null;
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) throw new Error("rendezvous derivation needs SubtleCrypto (a secure context)");

  const key = await subtle.importKey("raw", seed as BufferSource, "HKDF", false, ["deriveBits"]);
  const expand = async (info: string, bytes: number): Promise<Uint8Array> =>
    new Uint8Array(await subtle.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt: utf8(RENDEZVOUS_SALT) as BufferSource,
        info: utf8(info) as BufferSource },
      key, bytes * 8));

  const [codeBytes, tokenBytes] = await Promise.all([expand("code", 8), expand("token", 16)]);
  let code = "";
  for (const b of codeBytes) code += PAIRING_ALPHABET[b % PAIRING_ALPHABET.length];
  return { rcode: code, rtoken: uuidV4(tokenBytes) };
}

/// 16 bytes -> a canonical lowercase UUID with the v4 version and RFC 4122 variant bits stamped in.
/// LOWERCASE, because the session Durable Object compares tokens as exact strings.
function uuidV4 (raw: Uint8Array): string {
  const b = Uint8Array.from(raw);
  b[6] = (b[6]! & 0x0f) | 0x40;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const hex = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-`
       + `${hex.slice(16, 20)}-${hex.slice(20)}`;
}
