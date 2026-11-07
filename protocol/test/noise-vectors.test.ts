import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { Uint8ArrayList } from "uint8arraylist";
import { x25519 } from "@noble/curves/ed25519.js";
import { XXHandshakeState } from "../src/noise/protocol.js";
import { XXpsk3HandshakeState } from "../src/noise/xxpsk3.js";
import { pureJsCrypto } from "../src/noise/crypto-js.js";
import { wrapCrypto } from "../src/noise/crypto.js";
import { NoiseTransport } from "../src/noise/transport.js";
import type { ICrypto, KeyPair } from "../src/noise/types.js";

// The two protocols §11.1 names, against the published Cacophony vectors.
//
// THIS IS THE SAME FIXTURE THE RUST HOST ASSERTS (`//host/rdev-noise:rdev_noise_test`). Two
// implementations checked against one EXTERNAL answer is what makes two implementations acceptable
// at all; two implementations checked against each other could be wrong together, which is exactly
// what `XXpsk2` would have forced — it appears in no published corpus.
//
// Upstream ships no vector tests of its own — its suite is interop and compliance — so the vendored
// XX is checked here more than it is at home.
interface Vector {
  protocol_name: string; init_prologue: string; init_psks?: string[];
  init_static: string; init_ephemeral: string; resp_static: string; resp_ephemeral: string;
  messages: Array<{ payload: string; ciphertext: string }>;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/noise-vectors.json", import.meta.url)), "utf8")) as { vectors: Vector[] };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g)!.map((b) => parseInt(b, 16)));
const toHex = (u: Uint8Array | Uint8ArrayList): string =>
  [...("subarray" in u ? u.subarray() : u)].map((b) => b.toString(16).padStart(2, "0")).join("");
const kp = (priv: string): KeyPair => ({ privateKey: hex(priv), publicKey: x25519.getPublicKey(hex(priv)) });

/// THE SEAM A KNOWN-ANSWER TEST NEEDS. `writeE` asks `crypto.generateKeypair()` for the ephemeral, so
/// a shim that serves the vector's pinned one is enough — and it throws on a second request, so a
/// pattern that generated an extra ephemeral could not pass quietly.
function cryptoWithEphemeral (ephemeral: string): ICrypto {
  let served = false;
  return {
    ...wrapCrypto(pureJsCrypto),
    generateKeypair (): KeyPair {
      if (served) throw new Error("a second ephemeral was requested");
      served = true;
      return kp(ephemeral);
    },
  };
}

test("the fixture carries both protocols the specification names", () => {
  expect(fx.vectors.map((v) => v.protocol_name).sort()).toEqual([
    "Noise_XX_25519_ChaChaPoly_SHA256", "Noise_XXpsk3_25519_ChaChaPoly_SHA256",
  ]);
});

describe("published Cacophony vectors", () => {
  for (const v of fx.vectors) {
    test(v.protocol_name, () => {
      const psk = v.init_psks?.[0] !== undefined ? hex(v.init_psks[0]) : undefined;
      const isPsk = v.protocol_name.includes("psk");
      expect(isPsk, "a psk pattern must carry a psk and a plain one must not").toBe(psk !== undefined);

      const mk = (initiator: boolean, sPriv: string, ePriv: string): any => {
        const init = {
          crypto: cryptoWithEphemeral(ePriv), protocolName: v.protocol_name,
          prologue: hex(v.init_prologue), initiator, s: kp(sPriv),
        };
        return isPsk ? new XXpsk3HandshakeState({ ...init, psk: psk! }) : new XXHandshakeState(init);
      };
      const i = mk(true, v.init_static, v.init_ephemeral);
      const r = mk(false, v.resp_static, v.resp_ephemeral);

      const steps = [["writeMessageA", "readMessageA"], ["writeMessageB", "readMessageB"],
                     ["writeMessageC", "readMessageC"]] as const;
      for (let n = 0; n < 3; n++) {
        const [write, read] = steps[n]!;
        const [sender, receiver] = n % 2 === 0 ? [i, r] : [r, i];
        const out = sender[write](hex(v.messages[n]!.payload));
        expect(toHex(out), `message ${n + 1} ciphertext`).toBe(v.messages[n]!.ciphertext);
        const got = receiver[read](new Uint8ArrayList("subarray" in out ? out.subarray() : out));
        expect(toHex(got), `message ${n + 1} payload`).toBe(v.messages[n]!.payload);
      }

      // TRANSPORT. These three pin what the handshake three cannot: Split's key derivation, and the
      // PER-DIRECTION nonce counters — a session that shared one cipher state both ways would pass
      // every assertion above and fail here, on the second message, once the nonces collided.
      const ti = new NoiseTransport(i.ss.split(), true);
      const tr = new NoiseTransport(r.ss.split(), false);
      for (let n = 3; n < v.messages.length; n++) {
        const [sender, receiver] = n % 2 === 0 ? [ti, tr] : [tr, ti];
        const out = sender.write(hex(v.messages[n]!.payload));
        expect(toHex(out), `transport message ${n + 1} ciphertext`).toBe(v.messages[n]!.ciphertext);
        const got = receiver.read(new Uint8ArrayList("subarray" in out ? out.subarray() : out));
        expect(toHex(got), `transport message ${n + 1} payload`).toBe(v.messages[n]!.payload);
      }
    });
  }
});

// THE PROPERTY `pair` EXISTS FOR. Everything above would pass against a psk3 that ignored its psk
// entirely, because the vector fixes both sides' secret to the same value.
test("a one-bit PSK mismatch is rejected", () => {
  const v = fx.vectors.find((x) => x.protocol_name.includes("psk"))!;
  const good = hex(v.init_psks![0]!);
  const bad = new Uint8Array(good); bad[31]! ^= 0x01;
  const mk = (initiator: boolean, sPriv: string, ePriv: string, psk: Uint8Array) =>
    new XXpsk3HandshakeState({
      crypto: cryptoWithEphemeral(ePriv), protocolName: v.protocol_name,
      prologue: hex(v.init_prologue), initiator, s: kp(sPriv), psk,
    });
  const i = mk(true, v.init_static, v.init_ephemeral, good);
  const r = mk(false, v.resp_static, v.resp_ephemeral, bad);

  // psk3 mixes the secret at the END of message 3, so the first two still read — the pattern
  // behaving correctly, not a weak check.
  const m1 = i.writeMessageA(new Uint8Array(0));
  r.readMessageA(new Uint8ArrayList(m1.subarray()));
  const m2 = r.writeMessageB(new Uint8Array(0));
  i.readMessageB(new Uint8ArrayList(m2.subarray()));
  const m3 = i.writeMessageC(new Uint8Array(0));
  expect(() => r.readMessageC(new Uint8ArrayList(m3.subarray()))).toThrow();
});
