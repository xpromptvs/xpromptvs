/**
 * **The product's two origins, and §10.1's one relying party** (2026-10-06): the client moved to
 * `https://app.xpromptvs.ai` and the apex became the landing page.
 *
 * Passkeys stay registered to `xpromptvs.ai` — WebAuthn lets a page use its registrable parent as the
 * relying party, so every passkey made before the move still answers on `app.` — and **every verifier
 * accepts BOTH origins, for good**: a grant signed at the apex carries `https://xpromptvs.ai` in its
 * `clientDataJSON` forever, one signed on `app.` carries `https://app.xpromptvs.ai`, and the Mac's
 * native ceremony reports `https://xpromptvs.ai`. A page anywhere else (localhost, a LAN dev host, the
 * workers.dev name) keeps its own host and its own origin, as before.
 *
 * The same rule is `E2EOrigin` on the Mac, and both are held to `protocol/fixtures/e2e-product-origins.json`;
 * the Worker's `E2E_RP_ID`/`E2E_ORIGINS` state it a third time. `docs/e2e.md`, "Which relying party, and
 * which origin".
 */
export const PRODUCT_RP_ID = "xpromptvs.ai";
export const PRODUCT_ORIGINS: readonly string[] = ["https://xpromptvs.ai", "https://app.xpromptvs.ai"];
/** Where the client lives on the product's domain — what a link to "the app" points at. */
export const PRODUCT_APP_ORIGIN = "https://app.xpromptvs.ai";

const isProduct = (origin: string): boolean => PRODUCT_ORIGINS.includes(origin.replace(/\/+$/, ""));
/** An opaque origin (`null`, `about:`) has no host; it names no relying party anything could match. */
const hostOf = (origin: string): string => { try { return new URL(origin).hostname; } catch { return origin; } };

/** §10.1's policy for a ceremony run at — or a chain verified by a page at — `origin`. */
export function policyFor(origin: string): { rpId: string; allowedOrigins: string[] } {
  const o = origin.replace(/\/+$/, "");
  return isProduct(o)
    ? { rpId: PRODUCT_RP_ID, allowedOrigins: [...PRODUCT_ORIGINS] }
    : { rpId: hostOf(o), allowedOrigins: [o] };
}

/** Where "the app" is, seen from `origin`: the product's client origin, or the dev origin itself. */
export function appOriginFor(origin: string): string {
  const o = origin.replace(/\/+$/, "");
  return isProduct(o) ? PRODUCT_APP_ORIGIN : o;
}
