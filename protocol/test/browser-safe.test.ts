import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";

// The browser bundles the main entry and everything it re-exports. None of these may
// import a node: builtin (the node-only compressors live in codecs-node.ts instead).
const BROWSER_SAFE = ["../src/index.ts", "../src/envelope.ts",
                      "../src/pairing-seed.ts", "../src/e2e-wire.ts", "../src/e2e-identity.ts",
                      // The vendored Noise core and our psk3 pattern. They reach the browser through
                      // index.ts, so the same rule binds them — and the vendor is from a library
                      // written for browsers, so a `node:` import here would mean a bad copy.
                      "../src/noise/protocol.ts", "../src/noise/xxpsk3.ts", "../src/noise/crypto.ts",
                      "../src/noise/crypto-js.ts", "../src/noise/nonce.ts", "../src/noise/errors.ts",
                      "../src/noise/types.ts", "../src/noise/transport.ts"];

test("browser-facing protocol modules import no node: builtins", () => {
  for (const rel of BROWSER_SAFE) {
    const src = readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8");
    expect(src, `${rel} must not import node:*`).not.toMatch(/from\s+["']node:/);
  }
});
