import { parsePairing } from "./pairing";

/**
 * What a scanned QR turns out to be.
 *
 * **`foreign` is a refusal that NAMES the origin**, because a person who scanned the wrong sticker
 * deserves to know which one they got — and because a refusal with no subject reads as a bug.
 */
export type Scanned =
  | { kind: "adopt"; carrier: string }
  | { kind: "connect"; search: string }
  | { kind: "code"; text: string }
  | { kind: "foreign"; origin: string }
  | { kind: "unknown" };

/**
 * **A QR IS UNTRUSTED INPUT FROM THE PHYSICAL WORLD**, and navigating wherever one points is a
 * phishing primitive: anyone who can put a sticker on a Mac can put a URL in front of a person who
 * is, at that moment, holding a passkey and expecting to approve something.
 *
 * So a URL is accepted only on THIS origin — compared against `location.origin` as the caller passes
 * it, and never against anything the QR supplies.
 *
 * **A bare carrier is exempt, and that is not an oversight.** The origin rule is about URLs because
 * a URL names a DESTINATION; a bare carrier names none — it is a secret and nothing else, so
 * accepting it does exactly what typing it would have done, and refusing it would break
 * photographing a code that is shown as text.
 *
 * PURE, and async only because §9.1's derivation is HKDF through SubtleCrypto.
 */
export async function routeScanned (text: string, origin: string): Promise<Scanned> {
  const s = text.trim();
  if (s === "") return { kind: "unknown" };

  let url: URL | null = null;
  try { url = new URL(s); } catch { url = null; }

  if (url) {
    // A QR may encode any scheme at all. Only the two that name a web origin can be compared, and
    // anything else — `javascript:`, `data:`, `ftp:` — is refused rather than reasoned about.
    if (url.protocol !== "http:" && url.protocol !== "https:") return { kind: "unknown" };
    if (url.origin !== origin) return { kind: "foreign", origin: url.origin };

    // The fragment first: a link carrying a seed carries strictly more than one carrying
    // code+token, which is the same order `parsePairing` reads them in.
    const adopt = new URLSearchParams(url.hash.slice(1)).get("adopt");
    if (adopt) return { kind: "adopt", carrier: adopt };

    return await parsePairing(s) ? { kind: "connect", search: url.search + url.hash }
                                 : { kind: "unknown" };
  }

  // Not a URL, so it names nowhere. `parsePairing` decides whether it is a carrier at all; the
  // retired 30-character v2 code is not one, and nothing in the product emits it any more.
  return await parsePairing(s) ? { kind: "code", text: s } : { kind: "unknown" };
}
