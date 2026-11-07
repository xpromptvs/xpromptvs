/// The v3 one-time pairing derivation — §9.1 of
/// `docs/superpowers/specs/2026-09-10-e2e-protocol-specification.md`.
///
/// Mirror of `RdevCore.PairingSeed` (Swift), and the two are held together by
/// `protocol/fixtures/pairing-v3.json`, whose vectors a THIRD implementation produced (stdlib Python
/// hmac/hashlib). Two implementations that agree only with each other can be wrong together.
///
/// ONE SEED CARRIES ALL THREE VALUES, AND ONLY THE SEED LEAVES THE DEVICE. `code` is the Issuer's
/// temporary routing ID and `token` is room admission material — both public to the Control Plane,
/// which registers them. `psk` is the 256-bit pre-shared key for
/// `Noise_XXpsk3_25519_ChaChaPoly_SHA256` and is **never transmitted**: not to the Control Plane, not
/// in a registration request, not in a URL query, not to analytics, not to a log. HKDF is a
/// pseudorandom function, so the two public outputs reveal nothing about the seed or about `psk`.
///
/// **THE SEED IS THE SECRET.** Anyone who obtains these 32 bytes can derive `psk` and complete a
/// `pair` handshake with keys of their own. It is rendered only on the local pairing surface, which
/// the capture boundary protects (§16).
///
/// BROWSER-SAFE BY CONSTRUCTION: WebCrypto only, no `node:` builtins — `browser-safe.test.ts`
/// enforces that, because this module is bundled into the web client.

export interface PairingMaterial {
  /** The Issuer's temporary registered routing ID. Public. */
  code: string;
  /** Room admission material, canonical lowercase UUID. Public. */
  token: string;
  /** 32 bytes for Noise XXpsk3. NEVER transmitted. */
  psk: Uint8Array;
}

/**
 * **SIXTEEN BYTES, AND NO PREFIX** (2026-09-15) — 47 characters became 22.
 *
 * The seed's only job is the psk's resistance to an OFFLINE attack: the `XXpsk3` transcript is on
 * the wire, so a recorder can test guesses at leisure, and 128 bits is comfortably infeasible for
 * that. 256 bits was matched to Noise's PSK slot rather than to a threat, and cost 25 characters of
 * the one thing in this protocol a person has to carry by hand.
 *
 * **The `ss3.` discriminator went with it.** It existed so a v3 carrier could not be read as a v2
 * one; v2 is retired, nothing else in the product is a bare base64url string, and a 22-character
 * payload cannot be read as a URL because none of `:`, `/`, `?`, `#` or `=` is in the alphabet.
 * Shape is the discriminator now, and `parsePairing` checks it on both sides.
 */
export const PAIRING_SEED_BYTES = 16;
/// `b64u(16 bytes)` — 128 bits in 22 characters, with no padding and no prefix.
export const PAIRING_ENCODED_LENGTH = 22;

/// §9.2's alphabet, byte-for-byte the Control Plane's existing `CODE_ALPHABET`, so a derived routing
/// ID occupies the same character space as a minted one.
///
/// EXACTLY 64 CHARACTERS, which is why `% 64` introduces no modulo bias: 256 is a whole multiple of
/// 64, so every character is reachable from exactly four byte values. An alphabet of any other length
/// would skew the distribution invisibly to any test that only checks length and character set.
export const PAIRING_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// §8's `rdev-e2e/pair/v3` label. Domain separation: the same seed under a different label is a
/// different, unrelated key schedule.
export const PAIRING_SALT = "rdev-e2e/pair/v3";

const utf8 = (s: string) => new TextEncoder().encode(s);

/// Derive the pairing window's three values, or null if the seed is not exactly 32 bytes.
///
/// THROWS rather than returning null when SubtleCrypto is unavailable (an insecure context, say).
/// That is an environment failure, not a malformed seed, and conflating the two would let a client
/// silently treat "this browser will not do HKDF" as "the user typed a bad code".
export async function derivePairing(seed: Uint8Array): Promise<PairingMaterial | null> {
  if (seed.length !== PAIRING_SEED_BYTES) return null;
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) throw new Error("pairing derivation needs SubtleCrypto (a secure context)");

  // WebCrypto's HKDF performs Extract-then-Expand in one call with the given salt and info, which is
  // exactly HKDF-Expand(HKDF-Extract(salt, seed), info, L) — the spec's formula, not an approximation
  // of it. The three calls share a salt and differ only in `info`, so they share one PRK.
  const key = await subtle.importKey("raw", seed as BufferSource, "HKDF", false, ["deriveBits"]);
  const expand = async (info: string, bytes: number) =>
    new Uint8Array(await subtle.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt: utf8(PAIRING_SALT) as BufferSource, info: utf8(info) as BufferSource },
      key, bytes * 8));

  const [codeBytes, tokenBytes, psk] = await Promise.all([
    expand("code", 8), expand("token", 16), expand("psk", 32),
  ]);

  let code = "";
  for (const b of codeBytes) code += PAIRING_ALPHABET[b % PAIRING_ALPHABET.length];
  return { code, token: uuidV4(tokenBytes), psk };
}

/// The out-of-band carrier: `b64u(seed)`, bare. Null unless the seed is exactly 16 bytes.
export function encodePairingSeed(seed: Uint8Array): string | null {
  if (seed.length !== PAIRING_SEED_BYTES) return null;
  return base64urlEncode(seed);
}

/// The inverse, and STRICT: the text must be exactly `PAIRING_ENCODED_LENGTH` characters and decode
/// to exactly `PAIRING_SEED_BYTES`. **The length check is the discriminator now that the prefix is
/// gone** — without it a short base64url fragment of something else would decode to a seed-shaped
/// value. Whitespace is trimmed because a person types and pastes this, and a trailing newline from
/// a copy is not a different secret.
export function decodePairingSeed(text: string): Uint8Array | null {
  const s = text.trim();
  if (s.length !== PAIRING_ENCODED_LENGTH) return null;
  const bytes = base64urlDecode(s);
  return bytes && bytes.length === PAIRING_SEED_BYTES ? bytes : null;
}

/// 16 bytes -> canonical LOWERCASE UUID with the v4 version and RFC 4122 variant bits stamped in, as
/// §9.2's "UUID-format" specifies. Lowercase is load-bearing: the session Durable Object compares the
/// token as an exact string against what `crypto.randomUUID()` mints.
function uuidV4(raw: Uint8Array): string {
  const b = new Uint8Array(raw);
  b[6] = (b[6]! & 0x0f) | 0x40;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}

function base64urlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlDecode(s: string): Uint8Array | null {
  if (s === "" || !/^[A-Za-z0-9\-_]+$/.test(s)) return null;
  let b = s.replace(/-/g, "+").replace(/_/g, "/");
  while (b.length % 4 !== 0) b += "=";
  let bin: string;
  try { bin = atob(b); } catch { return null; }
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// -------------------------------------------------------------------- opening a pairing window

/// A pairing window, as the Issuer holds it.
///
/// **`seed` and `psk` never leave the device.** The carrier is rendered on the local pairing surface
/// — that display IS the out-of-band channel — and `code`/`token` are what the Control Plane is told.
export interface OpenedPairing {
  seed: Uint8Array;
  /// `b64u(seed)`, the 22 characters a person carries — bare, since 2026-09-15.
  carrier: string;
  material: PairingMaterial;
  sessionUrl: string;
}

/// §9.2's retry budget: "A temporary pairing-route conflict can be retried with fresh material, at
/// most four times." Four, not unbounded — a Control Plane that answered `conflict` forever would
/// otherwise hold an Issuer in a loop, which is the denial of service the bound exists to cap.
export const PAIRING_CONFLICT_ATTEMPTS = 4;

export type OpenPairingFailure = "conflict" | "unreachable" | "refused";

/**
 * **Open a pairing window: generate, derive, register.**
 *
 * §9.1 puts generation on the Issuer. This derives all three values from one seed and registers only
 * the two public ones, so the Control Plane learns a routing ID and a room token and nothing that
 * would let it complete a `pair` handshake.
 *
 * `random` and `post` are injected because a test that cannot pin the seed cannot assert the code,
 * and a test that needs a network is not a test of this.
 */
export async function openPairingWindow(base: string, deps: {
  random?: (n: number) => Uint8Array;
  post?: (url: string, body: string) => Promise<{ status: number; text: string }>;
} = {}): Promise<{ ok: true; value: OpenedPairing } | { ok: false; failure: OpenPairingFailure }> {
  const random = deps.random ?? ((n) => crypto.getRandomValues(new Uint8Array(n)));
  const post = deps.post ?? (async (url, body) => {
    const res = await fetch(url, { method: "POST", body });
    return { status: res.status, text: await res.text() };
  });

  for (let attempt = 0; attempt < PAIRING_CONFLICT_ATTEMPTS; attempt++) {
    const seed = random(PAIRING_SEED_BYTES);
    const material = await derivePairing(seed);
    const carrier = encodePairingSeed(seed);
    if (!material || !carrier) return { ok: false, failure: "refused" };

    let res: { status: number; text: string };
    try {
      // **ONLY THE TWO PUBLIC VALUES.** Sending the seed here — or logging this body — would hand
      // the Control Plane the ability to derive `psk` and complete the handshake itself.
      res = await post(`${base}/pair`,
                       JSON.stringify({ code: material.code, token: material.token }));
    } catch {
      return { ok: false, failure: "unreachable" };
    }
    if (res.status === 409) continue;                 // seized; §9.2 says try fresh material
    if (res.status !== 200) return { ok: false, failure: "refused" };

    let sessionUrl = `${base}/session/${material.code}`;
    try {
      const body = JSON.parse(res.text) as { sessionUrl?: unknown };
      if (typeof body.sessionUrl === "string") sessionUrl = body.sessionUrl;
    } catch { /* the derived URL is the answer either way */ }
    return { ok: true, value: { seed, carrier, material, sessionUrl } };
  }
  return { ok: false, failure: "conflict" };
}
