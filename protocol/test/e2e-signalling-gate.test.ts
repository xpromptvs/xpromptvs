import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import type { ClientGateConfig } from "../src/e2e-signalling-gate";
import { Uint8ArrayList } from "uint8arraylist";
import { x25519 } from "@noble/curves/ed25519.js";
import { XXHandshakeState } from "../src/noise/protocol.js";
import { pureJsCrypto } from "../src/noise/crypto-js.js";
import { wrapCrypto } from "../src/noise/crypto.js";
import { NoiseTransport } from "../src/noise/transport.js";
import { E2EResponder } from "../src/e2e-session";
import { E2EClientGate, type Received } from "../src/e2e-signalling-gate";
import { PublicationStatus, prologue } from "../src/e2e-wire";
import { deviceId } from "../src/e2e-identity";

// The client half of §11, as the browser will actually run it. `e2e-signalling.test.ts` proves the
// session machine and real Noise agree; this proves the OBJECT that wires them does — including the
// part that suite has no reason to cover, that the gate is also the transport once it opens.
//
// Its Swift counterpart is `E2ESignallingGateTests`, asserting the same properties of the host's
// side. The two gates are ONE contract and the failure mode is them drifting apart.
interface Device {
  signing_private_key: string; noise_private_key: string;
  signing_public_key: string; noise_public_key: string;
  descriptor: string; bundle: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-session.json", import.meta.url)), "utf8")) as {
    rp_id: string; allowed_origins: string[]; root_id: string;
    devices: Record<string, Device>;
    routes: Record<string, { rcode: string; rtoken: string }>;
  };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const bytes = (u: Uint8Array | Uint8ArrayList): Uint8Array => ("subarray" in u ? u.subarray() : u);
const dev = (n: string): Device => fx.devices[n]!;
const policy = { rpId: fx.rp_id, allowedOrigins: fx.allowed_origins };
const ROOM = "room-1";
const XX = "Noise_XX_25519_ChaChaPoly_SHA256";
const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);
/// One flipped bit, as a copy. `?? 0` because `noUncheckedIndexedAccess` is on and an index into a
/// typed array is genuinely `number | undefined` to the compiler.
const flip = (u: Uint8Array, i: number): Uint8Array => {
  const out = new Uint8Array(u);
  out[i] = (out[i] ?? 0) ^ 0x01;
  return out;
};

const gate = (opts: { trustedRootId?: Uint8Array; expect?: Uint8Array } = {}): E2EClientGate =>
  new E2EClientGate({
    roomCode: ROOM, device: hex(dev("C").descriptor),
    signingPrivateKey: hex(dev("C").signing_private_key),
    noisePrivateKey: hex(dev("C").noise_private_key),
    bundle: hex(dev("C").bundle),
    trustedRootId: opts.trustedRootId ?? hex(fx.root_id),
    policy,
    ...(opts.expect ? { expectedResponderDeviceId: opts.expect } : {}),
  });

/// The host half, driven by hand — a real `E2EResponder` over a real Noise session. Deliberately NOT
/// a second copy of the host's gate: what is under test is the CLIENT's, and a hand-driven peer is
/// the only way to hand it something a correct host would never send.
class Host {
  readonly noise: XXHandshakeState;
  readonly session: E2EResponder;
  transport: NoiseTransport | null = null;
  h: Uint8Array | null = null;

  constructor (name = "H", room = ROOM) {
    this.noise = new XXHandshakeState({
      crypto: wrapCrypto(pureJsCrypto), protocolName: XX,
      prologue: prologue("auth", room)!, initiator: false,
      s: {
        privateKey: hex(dev(name).noise_private_key),
        publicKey: x25519.getPublicKey(hex(dev(name).noise_private_key)),
      },
    });
    this.session = new E2EResponder({
      mode: "auth", roomCode: room, device: hex(dev(name).descriptor),
      bundle: hex(dev(name).bundle), route: fx.routes[name] ?? fx.routes.H!,
      trustedRootId: hex(fx.root_id), policy,
    });
  }

  /** m1 in, m2 out. */
  message2 (m1: Uint8Array): Uint8Array {
    const plain = bytes(this.noise.readMessageA(new Uint8ArrayList(m1)));
    expect(this.session.receiveMessage1(plain).ok).toBe(true);
    const payload = this.session.message2Payload();
    expect(payload.ok).toBe(true);
    if (!payload.ok) throw new Error("message 2");
    return bytes(this.noise.writeMessageB(payload.value));
  }

  /** m3 in; splits. */
  receiveMessage3 (m3: Uint8Array): void {
    const plain = bytes(this.noise.readMessageC(new Uint8ArrayList(m3)));
    if (!this.noise.rs) throw new Error("no static key");
    expect(this.session.receiveMessage3(plain, bytes(this.noise.rs)).ok).toBe(true);
    this.transport = new NoiseTransport(this.noise.ss.split(), false);
    this.h = new Uint8Array(this.noise.ss.h);
  }

  /** client-confirm in, session-start out. */
  sessionStart (confirm: Uint8Array): Uint8Array {
    const plain = bytes(this.transport!.read(new Uint8ArrayList(confirm)));
    expect(this.session.receiveClientConfirm(plain, this.h!).ok).toBe(true);
    const start = this.session.sessionStart(this.h!, PublicationStatus.Confirmed, new Uint8Array(0));
    if (!start.ok) throw new Error("session start");
    return bytes(this.transport!.write(start.value));
  }
}

const reply = (r: { ok: boolean } & Record<string, any>): Uint8Array[] => {
  expect(r.ok, JSON.stringify(r)).toBe(true);
  const value = r.value as Received;
  expect(value.kind).toBe("reply");
  return (value as { kind: "reply"; cts: Uint8Array[] }).cts;
};

/// Drive a whole `auth` session. Returns both ends, established.
function connect (g = gate(), host = new Host()): { g: E2EClientGate; host: Host } {
  const started = g.start();
  expect(started.ok).toBe(true);
  if (!started.ok) throw new Error("start");
  expect(started.value.mode).toBe("auth");

  const m2 = host.message2(started.value.ct);
  const [m3, confirm] = reply(g.receive(m2));
  host.receiveMessage3(m3!);
  const start = host.sessionStart(confirm!);
  const done = g.receive(start);
  expect(done.ok).toBe(true);
  return { g, host };
}

describe("a complete auth session", () => {
  test("opens the gate on both ends", () => {
    const { g, host } = connect();
    expect(g.maySignal).toBe(true);
    expect(host.session.maySignal).toBe(true);
  });

  test("the gate knows WHO it opened for", () => {
    const { g } = connect();
    expect(g.peerChain).not.toBeNull();
    expect([...g.peerChain!.leafDevice.bytes]).toEqual([...hex(dev("H").descriptor)]);
  });

  // §11: message 3 and `client-confirm` are two Noise messages, and Noise framing carries no length.
  // Concatenating them would hand the host one message with the other's bytes as its payload — which
  // is how the first version of this gate was wrong.
  test("message 3 and client-confirm are TWO envelopes", () => {
    const g = gate();
    const host = new Host();
    const started = g.start();
    if (!started.ok) throw new Error("start");
    const cts = reply(g.receive(host.message2(started.value.ct)));
    expect(cts).toHaveLength(2);
    expect(cts[0]).not.toEqual(cts[1]);
  });

  // §11.3: "Every subsequent signalling message, including SDP, ICE, renegotiation, and ICE restart,
  // is carried inside Noise transport."
  test("signalling travels inside the session, both ways", () => {
    const { g, host } = connect();
    const answer = utf8(JSON.stringify({ t: "answer", sdp: "v=0\r\n" }));
    const sealed = g.seal(answer);
    expect(sealed.ok).toBe(true);
    if (!sealed.ok) return;
    expect([...sealed.value]).not.toEqual([...answer]);
    expect([...bytes(host.transport!.read(new Uint8ArrayList(sealed.value)))]).toEqual([...answer]);

    const offer = utf8(JSON.stringify({ t: "offer", sdp: "v=0\r\n", peer: "p1" }));
    const inbound = g.receive(bytes(host.transport!.write(offer)));
    expect(inbound.ok).toBe(true);
    if (!inbound.ok) return;
    expect(inbound.value.kind).toBe("signalling");
    expect([...(inbound.value as { inner: Uint8Array }).inner]).toEqual([...offer]);
  });
});

describe("§11.2: nothing before the gate", () => {
  test("seal refuses at every stage before establishment", () => {
    const g = gate();
    const host = new Host();
    expect(g.seal(utf8("x")).ok).toBe(false);

    const started = g.start();
    if (!started.ok) throw new Error("start");
    expect(g.seal(utf8("x")).ok).toBe(false);
    expect(g.maySignal).toBe(false);

    reply(g.receive(host.message2(started.value.ct)));
    // The host's chain has verified and its descriptor is known…
    expect(g.peerChain).not.toBeNull();
    // …and that is STILL not authority: `session-start` has not arrived.
    expect(g.maySignal).toBe(false);
    expect(g.seal(utf8("x")).ok).toBe(false);
  });
});

describe("§11.3: what terminates", () => {
  // "Decryption failure terminates the signalling session; never skip a failed ciphertext." The gate
  // must not answer a second time after refusing once — a peer who can make it try again has an
  // oracle.
  test("a tampered message 2 terminates, and the gate stays shut", () => {
    const g = gate();
    const host = new Host();
    const started = g.start();
    if (!started.ok) throw new Error("start");
    const m2 = host.message2(started.value.ct);
    const refused = g.receive(flip(m2, m2.length - 1));
    expect(refused.ok).toBe(false);
    if (!refused.ok) expect(refused.failure.kind).toBe("noise");

    expect(g.receive(m2).ok).toBe(false);
    expect(g.maySignal).toBe(false);
  });

  test("tampering mid-session terminates too", () => {
    const { g, host } = connect();
    const sealed = bytes(host.transport!.write(utf8("{}")));
    const refused = g.receive(flip(sealed, 4));
    expect(refused.ok).toBe(false);
    if (!refused.ok) expect(refused.failure.kind).toBe("noise");
    expect(g.maySignal).toBe(false);
    expect(g.seal(utf8("x")).ok).toBe(false);
  });

  // §10.1: an incoming chain may never replace a trusted root. A host under another root is refused
  // by the CHAIN, and the failure says so rather than blaming the transport.
  test("a host under another root is refused, by name", () => {
    const g = gate({ trustedRootId: new Uint8Array(32).fill(0xEE) });
    const host = new Host();
    const started = g.start();
    if (!started.ok) throw new Error("start");
    const refused = g.receive(host.message2(started.value.ct));
    expect(refused.ok).toBe(false);
    if (!refused.ok) {
      expect(refused.failure.kind).toBe("session");
      expect((refused.failure as { failure: string }).failure).toBe("peer-chain");
    }
    expect(g.maySignal).toBe(false);
  });

  // §11.1: "A selected Host's `device_id` must also match the selection." Connecting to the Mac you
  // picked is not the same as connecting to a Mac in the same account.
  test("a host that is not the one selected is refused", () => {
    const g = gate({ expect: deviceId(hex(dev("X").descriptor)) });
    const host = new Host();
    const started = g.start();
    if (!started.ok) throw new Error("start");
    const refused = g.receive(host.message2(started.value.ct));
    expect(refused.ok).toBe(false);
    if (!refused.ok) {
      expect((refused.failure as { failure: string }).failure).toBe("responder-not-selected");
    }
  });

  test("start cannot be called twice", () => {
    const g = gate();
    expect(g.start().ok).toBe(true);
    expect(g.start().ok).toBe(false);
    expect(g.maySignal).toBe(false);
  });

  test("closing shuts the gate", () => {
    const { g } = connect();
    expect(g.maySignal).toBe(true);
    g.close();
    expect(g.maySignal).toBe(false);
    expect(g.seal(utf8("x")).ok).toBe(false);
  });
});

// ------------------------------------------------------------- `pair`, through the GATE

/// **The gate is where a `pair` configuration is assembled, and assembling it wrong is silent.**
/// Dropping `devicePublicKeys` here made `E2EInitiator.create` return null, so `start()` refused
/// and NOTHING went on the wire — which end to end looked like a host that never answered. The
/// session suite could not see it: it builds its own config.
describe("a pair configuration reaches the session", () => {
  const pairGate = (over: Partial<ClientGateConfig> = {}): E2EClientGate =>
    new E2EClientGate({
      roomCode: ROOM,
      // Empty, because §10.2's descriptor names a root this newcomer does not know yet.
      device: new Uint8Array(0),
      devicePublicKeys: { signing: hex(dev("N").signing_public_key),
                          noise: hex(dev("N").noise_public_key) },
      signingPrivateKey: hex(dev("N").signing_private_key),
      noisePrivateKey: hex(dev("N").noise_private_key),
      bundle: new Uint8Array(0),
      trustedRootId: null,
      policy,
      mode: "pair",
      pairingPsk: new Uint8Array(32).fill(0x5c),
      ...over,
    });

  test("a pair gate opens, and its first envelope says so", () => {
    const started = pairGate().start();
    expect(started.ok).toBe(true);
    if (!started.ok) return;
    expect(started.value.mode).toBe("pair");
    expect(started.value.ct.length).toBeGreaterThan(0);
  });

  test("WITHOUT the public keys it refuses, rather than sending nothing quietly", () => {
    const started = pairGate({ devicePublicKeys: undefined }).start();
    expect(started.ok).toBe(false);
  });

  test("without the psk it refuses too", () => {
    const started = pairGate({ pairingPsk: undefined }).start();
    expect(started.ok).toBe(false);
  });
});
