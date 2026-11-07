// **A device listing, without a Control Plane.**
//
// The welcome overlay's device list used to come from an OAuth account, and these checks mocked
// `/account/me` and `/account/sessions`. It comes from §12.2's directory now, signed by whatever
// chain the browser holds — so a check that wants rows on screen needs TWO things the account
// version did not: an identity in this origin's IndexedDB, and the directory's two endpoints.
//
// **The mock does not verify the signature, and that is the point of it being a mock.** What these
// checks are about is layout, motion and escaping; `protocol/test/e2e-directory.test.ts` and
// `E2EDirectoryClientTests` are where the request itself is held to anything.
import { mintIdentities, seedIdentity } from "./seed-identity.mjs";

/** 43 base64url characters — the width §12.2's 32-byte challenge decodes from. */
const CHALLENGE = "A".repeat(43);

/**
 * Route the directory and seed an identity, then land the page on `base` with both in place.
 *
 * `rows` are `{label, code, token, device_id}` as the Worker returns them. `status` other than 200
 * makes the listing fail, which is a DIFFERENT state from an empty one and worth checking on its own.
 */
export async function fakeDirectory(page, { base, rows = [], status = 200 }) {
  const url = new URL(base);
  const identities = mintIdentities({ rpId: url.hostname, origin: url.origin });

  await page.route("**/directory/*/challenge",
                   (r) => r.fulfill({ json: { challenge: CHALLENGE, expires_in: 120 } }));
  await page.route("**/directory/*/list", (r) => (status === 200
    ? r.fulfill({ json: { sessions: rows } })
    : r.fulfill({ status, body: "unavailable" })));

  // **The page must already be ON the origin before seeding**: IndexedDB written from `about:blank`
  // belongs to nothing.
  //
  // **AND THE APP MUST NOT BE RUNNING WHILE IT IS SEEDED.** This used to seed from the app itself and
  // then `reload()`: the dashboard noticed the identity arrive, started §12.2's `/challenge` fetch,
  // and the reload cancelled it mid-flight — which WebKit reports as "Fetch API cannot load …
  // /challenge due to access control checks", surfaced by Playwright as a `pageerror`. The harness
  // racing itself, in ~2 of 3 WebKit runs of `shellstorm-inline-check` (measured 2026-09-28; never
  // with WebKit alone, because the Chromium arm before it shifts the timing). So the seed is written
  // from an inert page ON the origin, and the app's first load is the one that finds it.
  const seedPage = new URL("/__rdev-seed-identity", url.origin).href;
  await page.route(seedPage, (r) => r.fulfill({ contentType: "text/html", body: "<!doctype html><title>seed</title>" }));
  await page.goto(seedPage);
  await seedIdentity(page, identities, "client");
  await page.unroute(seedPage);
  await page.goto(base);
  return identities;
}

/** One row, with the fields the directory actually returns. */
export const listedMac = (label, code, token = `${code}-token`) =>
  ({ label, code, token, device_id: `device-${code}` });
