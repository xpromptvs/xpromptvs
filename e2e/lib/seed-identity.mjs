// **Installing a prepared E2E identity, for gates.**
//
// Once signalling is E2E-only every gate needs both ends enrolled. Driving a real passkey ceremony
// per gate would put a person, an authenticator and a Worker in front of checks that are about
// codecs, audio or input — so this installs an identity instead, minted by
// `scripts/gen_e2e_test_identities.py` for the origin the gate actually uses.
//
// **It removes no security property from what is under test:** the §11 handshake still runs for
// real, against real chains, with real signatures. What is skipped is the ceremony that produced
// them, which §12.1's own checks cover.
//
// The host half is a file the harness reads (`RDEV_E2E_TEST_IDENTITY`); the client half goes into
// the page's own IndexedDB, through the SAME module the product uses — a seeder that wrote the
// bytes itself would be testing its own encoder.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = new URL("../..", import.meta.url).pathname;

/**
 * Mint a root and two devices for `origin`. Deterministic in `seed`, so a host that restarts comes
 * back as the SAME device rather than a new one.
 */
export function mintIdentities({ rpId, origin, seed }) {
  const out = join(mkdtempSync(join(tmpdir(), "rdev-e2e-")), "identities.json");
  const args = ["scripts/gen_e2e_test_identities.py", "--rp-id", rpId, "--origin", origin,
                "--out", out];
  if (seed) args.push("--seed", seed);
  const result = spawnSync("python3", args, { cwd: ROOT, stdio: ["ignore", "ignore", "inherit"] });
  if (result.status !== 0) throw new Error("gen_e2e_test_identities.py failed");
  return { path: out, ...JSON.parse(readFileSync(out, "utf8")) };
}

let bundled = null;

/** The product's own storage and encoders, bundled so a page can call them. */
function seeder() {
  if (bundled) return bundled;
  const esbuild = createRequire(ROOT + "web/")("esbuild");
  const source = `
    import { encodeInstallation, deviceKeys, encodeTrustRecord, emptyTrustRecord,
             PublicationStatus } from "@rdev/protocol";
    import { IndexedDBInstallationBackend, INSTALLATION_KEY, TRUST_KEY }
      from ${JSON.stringify(ROOT + "web/src/lib/installation-idb.ts")};
    const hex = (h) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
    export async function seed(half, rootHex, storageKeys) {
      const deviceKeyPair = deviceKeys(hex(half.signing_private_key), hex(half.noise_private_key));
      if (!deviceKeyPair) throw new Error("bad keys");
      const installation = encodeInstallation({
        keys: deviceKeyPair, rendezvousSeed: hex(half.rendezvous_seed),
      });
      const record = emptyTrustRecord();
      record.root = hex(rootHex);
      record.bundle = hex(half.bundle);
      // §12.2: nothing has been published. Claiming otherwise would hide a real failure.
      record.publicationStatus = PublicationStatus.Unconfirmed;
      const encoded = encodeTrustRecord(record);
      if (!encoded) throw new Error("bad record");
      // **A RESPONDER ON THE SAME ORIGIN NEEDS ITS OWN KEYS.** The harness peer page and the client
      // share an origin and therefore an IndexedDB; two peers sharing one installation would
      // present one descriptor from both ends, and Noise would be checking a device against itself.
      const [installKey, trustKey] = storageKeys ?? [INSTALLATION_KEY, TRUST_KEY];
      if (!await new IndexedDBInstallationBackend(installKey).write(installation)) {
        throw new Error("installation write failed");
      }
      if (!await new IndexedDBInstallationBackend(trustKey).write(encoded)) {
        throw new Error("trust write failed");
      }
      return true;
    }
  `;
  const built = esbuild.buildSync({
    stdin: { contents: source, resolveDir: ROOT + "web", loader: "ts" },
    bundle: true, format: "iife", globalName: "RdevSeed", write: false, platform: "browser",
  });
  bundled = built.outputFiles[0].text;
  return bundled;
}

/**
 * The seeder as a script that defines `RdevSeed`, for a page no Playwright drives — the native
 * app's windows, reached through its automation port's `eval` (`e2e/app-worker-request-check.mjs`).
 */
export function seederScript() { return seeder(); }

/**
 * Put the client half into this page's origin. **The page must already be ON that origin** — an
 * IndexedDB written from `about:blank` belongs to nothing.
 */
export async function seedClientIdentity(page, identities) {
  await seedIdentity(page, identities, "client");
}

/**
 * Put one half into this page's origin. **The page must already be ON that origin** — an IndexedDB
 * written from `about:blank` belongs to nothing.
 *
 * `role` picks the half AND the storage keys: the browser-to-browser smoke runs both peers on one
 * origin, so the responder's identity has to live somewhere the client's does not.
 */
export async function seedIdentity(page, identities, role) {
  await page.addScriptTag({ content: seeder() });
  const keys = role === "host" ? ["host-v1", "host-trust-v1"] : null;
  const ok = await page.evaluate(
    ({ half, root, storageKeys }) => RdevSeed.seed(half, root, storageKeys),
    { half: identities[role], root: identities.root, storageKeys: keys });
  if (ok !== true) throw new Error(`seeding the ${role} identity failed`);
}

/** The environment a harness needs to come up already enrolled. */
export function hostEnvironment(identities) {
  return {
    RDEV_E2E_TEST_IDENTITY: identities.path,
    RDEV_E2E_TEST_ROLE: "host",
  };
}
