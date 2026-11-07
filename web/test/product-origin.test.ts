import { expect, test } from "vitest";
import fixture from "../../protocol/fixtures/e2e-product-origins.json";
import { appOriginFor, policyFor, PRODUCT_APP_ORIGIN, PRODUCT_ORIGINS, PRODUCT_RP_ID } from "../src/lib/product-origin";

// §10.1's policy on the product's domain — ONE fixture for this and the Mac's `E2EOrigin`
// (protocol/fixtures/e2e-product-origins.json), because a browser and a Mac that disagreed about which
// origins a grant may carry would each refuse the other's chain for a reason naming neither.
const fx = fixture as {
  rp_id: string; origins: string[]; app_origin: string;
  cases: Array<{ origin: string; rp_id: string; allowed_origins: string[]; app_origin: string }>;
};

test("the constants are the fixture's", () => {
  expect(PRODUCT_RP_ID).toBe(fx.rp_id);
  expect([...PRODUCT_ORIGINS]).toEqual(fx.origins);
  expect(PRODUCT_APP_ORIGIN).toBe(fx.app_origin);
});

test.each(fx.cases)("$origin", (c) => {
  expect(policyFor(c.origin)).toEqual({ rpId: c.rp_id, allowedOrigins: c.allowed_origins });
  expect(policyFor(`${c.origin}/`)).toEqual({ rpId: c.rp_id, allowedOrigins: c.allowed_origins });
  expect(appOriginFor(c.origin)).toBe(c.app_origin);
});

// **A grant keeps the origin it was signed at, for good** — so the apex must stay accepted after the
// client moved, or every identity enrolled before the move stops verifying.
test("the apex stays accepted from the app's origin, and the reverse", () => {
  expect(policyFor("https://app.xpromptvs.ai").allowedOrigins).toContain("https://xpromptvs.ai");
  expect(policyFor("https://xpromptvs.ai").allowedOrigins).toContain("https://app.xpromptvs.ai");
});

test("an opaque origin names no relying party anything could match, and does not throw", () => {
  expect(policyFor("null")).toEqual({ rpId: "null", allowedOrigins: ["null"] });
});
