// **Opening the client, with an identity.**
//
// Once signalling is E2E-only a client cannot connect without one, and a spec that navigated
// straight to `?code=…&token=…` would sit on "sign in with a passkey to continue" forever
// with nothing pointing at why. This is the one place that knows both halves of that.
//
// **The identity is minted for the CEREMONY origin**, which is the page's own origin here: the
// smokes serve the client from vite and proxy `/session` to the Worker, so a browser's
// `location.origin` is vite's. The host is told the same origin through `RDEV_E2E_ORIGIN`, because
// §10.1's policy is about where the ceremony ran and both ends must agree.
import { readFileSync } from "node:fs";
import { seedClientIdentity } from "./seed-identity.mjs";

/**
 * Navigate `page` to a connected client.
 *
 * `RDEV_E2E_TEST_IDENTITY` names the minted file. **Without it this REFUSES** rather than navigating
 * anyway: signalling is E2E-only, so a client with no identity connects to nothing, and a spec that
 * sat waiting for a host would say nothing about why. There is no `?e2e=1` any more — §11 is not a
 * mode the URL selects.
 */
export async function openClient(page, { base, code, token, extra = "", options }) {
  const path = process.env.RDEV_E2E_TEST_IDENTITY;
  if (!path) {
    throw new Error(
      "RDEV_E2E_TEST_IDENTITY is unset, so this client would have no identity and signalling is "
      + "E2E-only. Mint one for the origin this page runs on: `mint_e2e_identities <base>` in "
      + "scripts/lib.sh, or scripts/gen_e2e_test_identities.py directly.");
  }
  // The page must ALREADY be on the origin: an IndexedDB written from `about:blank` belongs to
  // nothing, and the client would come up unenrolled with nothing to say why.
  await page.goto(base, { waitUntil: "domcontentloaded" });
  await seedClientIdentity(page, JSON.parse(readFileSync(path, "utf8")));
  await page.goto(`${base}/?code=${code}&token=${token}${extra}`, options);
}
