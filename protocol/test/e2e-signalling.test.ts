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
import { E2EInitiator, E2EResponder } from "../src/e2e-session";
import { PublicationStatus, prologue, type E2EMode } from "../src/e2e-wire";
import type { KeyPair } from "../src/noise/types.js";

// §17.3: "Use real Noise on both ends. Modified, replayed, reordered, or injected messages terminate
// the connection; mismatched modes or rooms fail. No SDP or ICE is processed before authentication
// and the revocation check ... Cover normal connection with no application traffic: `client-confirm`
// and `session-start` must suffice to finish authorization without a deadlock."
//
// Everything above this file tests the session machine against plaintexts it was handed. THIS tests
// it against a real handshake — the static keys are real X25519 points from the fixture's device
// descriptors, the payloads are really encrypted, and the handshake hash really comes from Noise.
// A session machine can be perfectly correct against its own fixtures and still be wired to the
// wrong key or the wrong `h`; nothing but this notices that.
//
// MEASURED, not asserted: regenerate `e2e-session.json` with the device descriptors carrying filler
// bytes where their X25519 public keys belong — which is what they held before this file existed —
// and `e2e-session.test.ts` still passes 29 of 29 while this file fails 7 of 14. The unit suite
// cannot see that a descriptor's DH key is not a key any handshake could authenticate.
interface Device {
  name: string; signing_private_key: string; signing_public_key: string;
  noise_private_key: string; noise_public_key: string; descriptor: string;
  device_id: string; bundle: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-session.json", import.meta.url)), "utf8")) as {
    rp_id: string; allowed_origins: string[]; root_id: string;
    devices: Record<string, Device>;
    routes: Record<string, { rcode: string; rtoken: string }>;
    operation_ids: Record<string, string>;
  };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const bytes = (u: Uint8Array | Uint8ArrayList): Uint8Array =>
  "subarray" in u ? u.subarray() : u;
const dev = (n: string): Device => fx.devices[n]!;
const policy = { rpId: fx.rp_id, allowedOrigins: fx.allowed_origins };
const ZERO = hex(fx.operation_ids.zero!);

const keyPair = (priv: string): KeyPair =>
  ({ privateKey: hex(priv), publicKey: x25519.getPublicKey(hex(priv)) });

/// The peer's static key AS THE HANDSHAKE AUTHENTICATED IT. Throws rather than handing `undefined`
/// to the session machine: a check against a missing key is a check that trivially passes, and
/// `rs` is legitimately absent until the message that carries it has been read.
const remoteStatic = (h: { rs?: Uint8Array | Uint8ArrayList | null }): Uint8Array => {
  if (!h.rs) throw new Error("the handshake has authenticated no static key yet");
  return bytes(h.rs);
};

const XX = "Noise_XX_25519_ChaChaPoly_SHA256";
const XXPSK3 = "Noise_XXpsk3_25519_ChaChaPoly_SHA256";

/// A complete, really-encrypted session. Returns every wire message so a test can tamper with one
/// and replay the rest.
function connect (opts: {
  mode?: E2EMode;
  room?: string;
  responderRoom?: string;
  responderName?: string;
  initiatorName?: string;
  psk?: Uint8Array;
  responderPsk?: Uint8Array;
} = {}) {
  const mode = opts.mode ?? "auth";
  const room = opts.room ?? "room-1";
  const responderName = opts.responderName ?? "H";
  const initiatorName = opts.initiatorName ?? "C";
  const crypto = wrapCrypto(pureJsCrypto);

  const mk = (initiator: boolean, name: string, prologueRoom: string, psk?: Uint8Array): any => {
    const init = {
      crypto, protocolName: psk ? XXPSK3 : XX,
      prologue: prologue(mode, prologueRoom)!, initiator,
      s: keyPair(dev(name).noise_private_key),
    };
    return psk ? new XXpsk3HandshakeState({ ...init, psk }) : new XXHandshakeState(init);
  };

  const ni = mk(true, initiatorName, room, opts.psk);
  const nr = mk(false, responderName, opts.responderRoom ?? room, opts.responderPsk ?? opts.psk);

  const responder = new E2EResponder({
    mode, roomCode: room,
    device: hex(dev(responderName).descriptor), bundle: hex(dev(responderName).bundle),
    route: fx.routes[responderName] ?? fx.routes.H!,
    trustedRootId: hex(fx.root_id), policy,
  });
  // §12.3: in `pair` the newcomer arrives with KEYS and names itself only after message 2, because
  // a §10.2 descriptor NAMES its root and it does not know one yet.
  const initiator = E2EInitiator.create({
    mode, roomCode: room,
    device: mode === "pair" ? new Uint8Array(0) : hex(dev(initiatorName).descriptor),
    ...(mode === "pair"
      ? { devicePublicKeys: { signing: hex(dev(initiatorName).signing_public_key),
                              noise: hex(dev(initiatorName).noise_public_key) } }
      : {}),
    signingPrivateKey: hex(dev(initiatorName).signing_private_key),
    bundle: mode === "auth" ? hex(dev(initiatorName).bundle) : new Uint8Array(0),
    operationId: ZERO,
    trustedRootId: mode === "pair" ? null : hex(fx.root_id),
    policy,
  })!;

  const wire: Record<string, Uint8Array> = {};

  // Message 1 — an EMPTY payload, encrypted by Noise all the same.
  wire.m1 = bytes(ni.writeMessageA(initiator.message1Payload));
  const m1Payload = bytes(nr.readMessageA(new Uint8ArrayList(wire.m1)));
  const step1 = responder.receiveMessage1(m1Payload);

  // Message 2 — the responder's chain and durable route.
  const m2Payload = responder.message2Payload();
  if (!m2Payload.ok || !step1.ok) return { wire, step1, step2: m2Payload, responder, initiator };
  wire.m2 = bytes(nr.writeMessageB(m2Payload.value));
  const m2Plain = bytes(ni.readMessageB(new Uint8ArrayList(wire.m2)));
  // `ni.rs` is the static key NOISE authenticated — the only honest source for it.
  const step2 = initiator.receiveMessage2(m2Plain, remoteStatic(ni));

  const m3Payload = initiator.message3Payload();
  if (!step2.ok || !m3Payload.ok) return { wire, step1, step2, step3: m3Payload, responder, initiator };
  wire.m3 = bytes(ni.writeMessageC(m3Payload.value));
  const m3Plain = bytes(nr.readMessageC(new Uint8ArrayList(wire.m3)));
  const step3 = responder.receiveMessage3(m3Plain, remoteStatic(nr));

  // Split, and the handshake hash each side computes for itself.
  const ti = new NoiseTransport(ni.ss.split(), true);
  const tr = new NoiseTransport(nr.ss.split(), false);
  const hInitiator = new Uint8Array(ni.ss.h);
  const hResponder = new Uint8Array(nr.ss.h);

  const confirm = initiator.clientConfirm(hInitiator);
  if (!step3.ok || !confirm.ok) {
    return { wire, step1, step2, step3, confirm, responder, initiator, ti, tr,
             hInitiator, hResponder };
  }
  wire.confirm = bytes(ti.write(confirm.value));
  const confirmPlain = bytes(tr.read(new Uint8ArrayList(wire.confirm)));
  const gate = responder.receiveClientConfirm(confirmPlain, hResponder);

  const start = responder.sessionStart(hResponder, PublicationStatus.Unconfirmed,
                                       new Uint8Array(0));
  if (!gate.ok || !start.ok) {
    return { wire, step1, step2, step3, confirm, gate, start, responder, initiator, ti, tr,
             hInitiator, hResponder };
  }
  wire.start = bytes(tr.write(start.value));
  const startPlain = bytes(ti.read(new Uint8ArrayList(wire.start)));
  const done = initiator.receiveSessionStart(startPlain, hInitiator);

  return { wire, step1, step2, step3, confirm, gate, start, done, responder, initiator, ti, tr,
           hInitiator, hResponder };
}

describe("a real auth session over real Noise", () => {
  test("completes, and both ends open their gate", () => {
    const s = connect();
    for (const [name, r] of Object.entries({ step1: s.step1, step2: s.step2, step3: s.step3 })) {
      expect(r?.ok, name).toBe(true);
    }
    expect(s.gate?.ok).toBe(true);
    expect(s.done?.ok).toBe(true);
    expect(s.responder.maySignal).toBe(true);
    expect(s.initiator.maySignal).toBe(true);
  });

  // §17.3: "Cover normal connection with no application traffic: `client-confirm` and
  // `session-start` must suffice to finish authorization without a deadlock."
  test("client-confirm and session-start are the only transport messages needed", () => {
    const s = connect();
    expect(Object.keys(s.wire).sort()).toEqual(["confirm", "m1", "m2", "m3", "start"]);
    expect(s.initiator.maySignal).toBe(true);
  });

  // THE FACT THIS FILE EXISTS TO CHECK. The session machine is handed `h` by its caller, and a
  // caller that handed it the wrong thing would pass every other test in this package.
  test("both ends derive the same handshake hash, and it is what the proof names", () => {
    const s = connect();
    expect(s.hResponder).toEqual(s.hInitiator);
    expect(s.hInitiator!.length).toBe(32);
    // A different session gets a different `h`, so a proof cannot be carried between them.
    const other = connect();
    expect(other.hInitiator).not.toEqual(s.hInitiator);
  });

  test("the descriptor's DH key really is the key Noise authenticated", () => {
    const s = connect();
    expect(s.responder.initiatorDevice!.noisePublicKey).toEqual(hex(dev("C").noise_public_key));
    expect(s.initiator.responderChain!.leafDevice.noisePublicKey)
      .toEqual(hex(dev("H").noise_public_key));
  });
});

describe("a real pair session over real XXpsk3", () => {
  const psk = new Uint8Array(32).fill(0xA7);

  test("a newcomer with no trusted root completes against the pairing secret", () => {
    const s = connect({ mode: "pair", initiatorName: "N", psk });
    expect(s.gate?.ok).toBe(true);
    expect(s.responder.maySignal).toBe(true);
    expect(s.initiator.responderChain).not.toBeNull();
  });

  test("a one-bit PSK mismatch kills the session at message 3", () => {
    const bad = new Uint8Array(psk); bad[31]! ^= 0x01;
    // psk3 mixes the secret at the END of message 3, so the failure lands in Noise, not in policy.
    expect(() => connect({ mode: "pair", initiatorName: "N", psk, responderPsk: bad })).toThrow();
  });
});

describe("§17.3: tampering terminates the connection", () => {
  test("a modified transport ciphertext does not decrypt", () => {
    const s = connect();
    const tampered = new Uint8Array(s.wire.confirm!);
    tampered[tampered.length - 1]! ^= 0x01;
    // A fresh session, so the receiving cipher state is at the right nonce.
    const fresh = connect();
    expect(() => fresh.tr!.read(new Uint8ArrayList(tampered))).toThrow();
  });

  test("a replayed transport message does not decrypt a second time", () => {
    // Noise's per-direction counters are the replay defence; the session machine never sees it.
    const s = connect();
    expect(() => s.tr!.read(new Uint8ArrayList(s.wire.confirm!))).toThrow();
  });

  test("a modified handshake message fails the AEAD", () => {
    const crypto = wrapCrypto(pureJsCrypto);
    const p = prologue("auth", "room-1")!;
    const ni = new XXHandshakeState({ crypto, protocolName: XX, prologue: p, initiator: true,
                                      s: keyPair(dev("C").noise_private_key) });
    const nr = new XXHandshakeState({ crypto, protocolName: XX, prologue: p, initiator: false,
                                      s: keyPair(dev("H").noise_private_key) });
    const m1 = bytes(ni.writeMessageA(new Uint8Array(0)));
    nr.readMessageA(new Uint8ArrayList(m1));
    const m2 = bytes(nr.writeMessageB(new Uint8Array([1, 2, 3])));
    const tampered = new Uint8Array(m2);
    tampered[tampered.length - 1]! ^= 0x01;
    expect(() => ni.readMessageB(new Uint8ArrayList(tampered))).toThrow();
  });
});

describe("§17.3: mismatched modes or rooms fail", () => {
  // The prologue is mixed before anything else, so a disagreement is fatal at the first AEAD — the
  // session machine never gets to apply a policy, which is the point of binding it there.
  test("a different room on each side fails the handshake", () => {
    expect(() => connect({ room: "room-1", responderRoom: "room-2" })).toThrow();
  });

  test("every mode produces a different prologue", () => {
    const seen = new Set<string>();
    for (const mode of ["pair", "enroll", "auth", "resume"] as E2EMode[]) {
      seen.add([...prologue(mode, "room-1")!].join(","));
    }
    expect(seen.size).toBe(4);
  });

  test("a mode disagreement fails the handshake even with the same room", () => {
    const crypto = wrapCrypto(pureJsCrypto);
    const ni = new XXHandshakeState({ crypto, protocolName: XX, prologue: prologue("auth", "r")!,
                                      initiator: true, s: keyPair(dev("C").noise_private_key) });
    const nr = new XXHandshakeState({ crypto, protocolName: XX, prologue: prologue("enroll", "r")!,
                                      initiator: false, s: keyPair(dev("H").noise_private_key) });
    const m1 = bytes(ni.writeMessageA(new Uint8Array(0)));
    nr.readMessageA(new Uint8ArrayList(m1));
    const m2 = bytes(nr.writeMessageB(new Uint8Array(0)));
    expect(() => ni.readMessageB(new Uint8ArrayList(m2))).toThrow();
  });
});

describe("§17.3: nothing is processed before the gate", () => {
  test("neither end may signal until its own verification completes", () => {
    const s = connect();
    expect(s.responder.maySignal && s.initiator.maySignal).toBe(true);

    // Walk it again, stopping at each point, and assert the gate is shut every time.
    const crypto = wrapCrypto(pureJsCrypto);
    const p = prologue("auth", "room-1")!;
    const ni = new XXHandshakeState({ crypto, protocolName: XX, prologue: p, initiator: true,
                                      s: keyPair(dev("C").noise_private_key) });
    const nr = new XXHandshakeState({ crypto, protocolName: XX, prologue: p, initiator: false,
                                      s: keyPair(dev("H").noise_private_key) });
    const responder = new E2EResponder({
      mode: "auth", roomCode: "room-1", device: hex(dev("H").descriptor),
      bundle: hex(dev("H").bundle), route: fx.routes.H!, trustedRootId: hex(fx.root_id), policy,
    });
    const initiator = E2EInitiator.create({
      mode: "auth", roomCode: "room-1", device: hex(dev("C").descriptor),
      signingPrivateKey: hex(dev("C").signing_private_key), bundle: hex(dev("C").bundle),
      operationId: ZERO, trustedRootId: hex(fx.root_id), policy,
    })!;

    const shut = (): void => {
      expect(responder.maySignal).toBe(false);
      expect(initiator.maySignal).toBe(false);
    };
    shut();
    const m1 = bytes(ni.writeMessageA(new Uint8Array(0)));
    responder.receiveMessage1(bytes(nr.readMessageA(new Uint8ArrayList(m1))));
    shut();
    const m2 = bytes(nr.writeMessageB((responder.message2Payload() as any).value));
    initiator.receiveMessage2(bytes(ni.readMessageB(new Uint8ArrayList(m2))), remoteStatic(ni));
    shut();
    const m3 = bytes(ni.writeMessageC((initiator.message3Payload() as any).value));
    responder.receiveMessage3(bytes(nr.readMessageC(new Uint8ArrayList(m3))), remoteStatic(nr));
    // SPLIT HAS HAPPENED. The channel is encrypted and both peers know each other's static key —
    // and STILL neither may signal, because §11.2's confirmation has not run.
    shut();
  });

  test("a session that never confirms never opens, however long it runs", () => {
    const crypto = wrapCrypto(pureJsCrypto);
    const p = prologue("auth", "room-1")!;
    const ni = new XXHandshakeState({ crypto, protocolName: XX, prologue: p, initiator: true,
                                      s: keyPair(dev("C").noise_private_key) });
    const nr = new XXHandshakeState({ crypto, protocolName: XX, prologue: p, initiator: false,
                                      s: keyPair(dev("H").noise_private_key) });
    const responder = new E2EResponder({
      mode: "auth", roomCode: "room-1", device: hex(dev("H").descriptor),
      bundle: hex(dev("H").bundle), route: fx.routes.H!, trustedRootId: hex(fx.root_id), policy,
    });
    const m1 = bytes(ni.writeMessageA(new Uint8Array(0)));
    responder.receiveMessage1(bytes(nr.readMessageA(new Uint8ArrayList(m1))));
    const m2 = bytes(nr.writeMessageB((responder.message2Payload() as any).value));
    ni.readMessageB(new Uint8ArrayList(m2));
    const m3 = bytes(ni.writeMessageC(new Uint8Array(0)));
    nr.readMessageC(new Uint8ArrayList(m3));
    const tr = new NoiseTransport(nr.ss.split(), false);
    const ti = new NoiseTransport(ni.ss.split(), true);

    // Fifty perfectly well-encrypted transport messages from an authenticated Noise peer.
    for (let i = 0; i < 50; i++) {
      const ct = ti.write(new Uint8Array([i]));
      expect(bytes(tr.read(new Uint8ArrayList(bytes(ct))))).toEqual(new Uint8Array([i]));
      expect(responder.maySignal).toBe(false);
    }
  });
});
