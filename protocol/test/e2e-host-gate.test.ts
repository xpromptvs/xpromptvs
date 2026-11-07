import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { E2EClientGate, type Received } from "../src/e2e-signalling-gate";
import { E2EHostGate } from "../src/e2e-host-gate";
import { deviceId } from "../src/e2e-identity";
import { APP_HELLO_MAX } from "../src/e2e-wire";

// **The two browser gates against EACH OTHER** — the responder answering the initiator, both real,
// over real Noise. `e2e-signalling-gate.test.ts` drives the client against a hand-built host; this
// drives the two production objects together, which is the only way to see them agree.
//
// Their Swift counterpart is `E2ESignallingGateTests`. The three are ONE contract, and the failure
// mode is them drifting apart.
interface Device {
  signing_private_key: string; noise_private_key: string; descriptor: string; bundle: string;
  signing_public_key: string; noise_public_key: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-session.json", import.meta.url)), "utf8")) as {
    rp_id: string; allowed_origins: string[]; root_id: string;
    devices: Record<string, Device>;
    adoption: { bundle_for_N: string; capabilities: number };
    routes: Record<string, { rcode: string; rtoken: string }>;
  };
const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const dev = (n: string): Device => fx.devices[n]!;
const policy = { rpId: fx.rp_id, allowedOrigins: fx.allowed_origins };
const ROOM = "room-1";
const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);
const flip = (u: Uint8Array, i: number): Uint8Array => {
  const out = new Uint8Array(u);
  out[i] = (out[i] ?? 0) ^ 0x01;
  return out;
};

const host = (opts: { room?: string; pairingPsk?: Uint8Array } = {}): E2EHostGate =>
  new E2EHostGate({
    roomCode: opts.room ?? ROOM, device: hex(dev("H").descriptor), bundle: hex(dev("H").bundle),
    noisePrivateKey: hex(dev("H").noise_private_key), route: fx.routes.H!,
    trustedRootId: hex(fx.root_id), policy,
    ...(opts.pairingPsk ? { pairingPsk: opts.pairingPsk } : {}),
  });

/// §9.1's psk. Its VALUE is irrelevant — what matters is that both ends hold the same one.
const PSK = new Uint8Array(32).fill(0x5a);

/// **N, the newcomer: no chain, no trusted root, and a psk someone carried.** In adopt-by-code this
/// is the MAC — it showed the code and speaks first — while the responder above is the browser
/// holding the passkey. The carry direction is reversed from guest pairing; the protocol direction
/// is not, which is the whole reason no fourth mode exists.
const newcomer = (psk = PSK): E2EClientGate =>
  new E2EClientGate({
    roomCode: ROOM, device: new Uint8Array(0),
    signingPrivateKey: hex(dev("N").signing_private_key),
    noisePrivateKey: hex(dev("N").noise_private_key),
    bundle: new Uint8Array(0), trustedRootId: null, policy,
    mode: "pair", pairingPsk: psk,
    devicePublicKeys: {
      signing: hex(dev("N").signing_public_key), noise: hex(dev("N").noise_public_key),
    },
  });

const client = (opts: { expect?: Uint8Array; appHello?: () => Uint8Array } = {}): E2EClientGate =>
  new E2EClientGate({
    roomCode: ROOM, device: hex(dev("C").descriptor),
    signingPrivateKey: hex(dev("C").signing_private_key),
    noisePrivateKey: hex(dev("C").noise_private_key),
    bundle: hex(dev("C").bundle), trustedRootId: hex(fx.root_id), policy,
    ...(opts.expect ? { expectedResponderDeviceId: opts.expect } : {}),
    ...(opts.appHello ? { appHello: opts.appHello } : {}),
  });

const cts = (r: ReturnType<E2EHostGate["receive"]>): Uint8Array[] => {
  expect(r.ok, JSON.stringify(r)).toBe(true);
  if (!r.ok) throw new Error("refused");
  expect(r.value.kind).toBe("reply");
  return (r.value as { kind: "reply"; cts: Uint8Array[] }).cts;
};

/// Drive the two gates to an open session.
function connect (h = host(), c = client()): { h: E2EHostGate; c: E2EClientGate } {
  const started = c.start();
  expect(started.ok).toBe(true);
  if (!started.ok) throw new Error("start");

  const [m2] = cts(h.receive(started.value.ct, started.value.mode));
  const [m3, confirm] = cts(c.receive(m2!));
  expect(h.receive(m3!).ok).toBe(true);
  const [start] = cts(h.receive(confirm!));
  const done = c.receive(start!);
  expect(done.ok).toBe(true);
  return { h, c };
}

describe("the two gates against each other", () => {
  test("both open, and each knows who it opened for", () => {
    const { h, c } = connect();
    expect(h.maySignal).toBe(true);
    expect(c.maySignal).toBe(true);
    expect([...deviceId(h.peerChain!.leafDevice.bytes)]).toEqual([...deviceId(hex(dev("C").descriptor))]);
    expect([...deviceId(c.peerChain!.leafDevice.bytes)]).toEqual([...deviceId(hex(dev("H").descriptor))]);
  });

  // `client-confirm`'s app_hello (docs/sources-and-focus.md, "The offer carries the tab bar"): what the page said
  // for the application — its terminal grid — reaches the host once its gate is open, and not before.
  test("the client's app_hello reaches the host, only once the gate is open", () => {
    const said = new TextEncoder().encode('{"grid":{"cols":120,"rows":40}}');
    let asked = 0;
    const h = host(), c = client({ appHello: () => { asked++; return said; } });
    const started = c.start();
    if (!started.ok) throw new Error("start");
    const [m2] = cts(h.receive(started.value.ct, started.value.mode));
    expect(asked, "asked for when client-confirm is written, not before").toBe(0);
    const [m3, confirm] = cts(c.receive(m2!));
    expect(asked).toBe(1);
    expect(h.receive(m3!).ok).toBe(true);
    expect(h.appHello.length, "nothing before the gate").toBe(0);
    cts(h.receive(confirm!));
    expect(new TextDecoder().decode(h.appHello)).toBe('{"grid":{"cols":120,"rows":40}}');
  });

  test("an app_hello that throws or is over the cap is sent empty, and the session still opens", () => {
    for (const appHello of [() => { throw new Error("no grid"); }, () => new Uint8Array(APP_HELLO_MAX + 1)]) {
      const { h, c } = connect(host(), client({ appHello }));
      expect(h.maySignal && c.maySignal).toBe(true);
      expect(h.appHello.length).toBe(0);
    }
  });

  // §11.3: "Every subsequent signalling message … is carried inside Noise transport."
  test("signalling travels both ways", () => {
    const { h, c } = connect();
    const offer = utf8(JSON.stringify({ t: "offer", sdp: "v=0" }));
    const sealed = h.seal(offer);
    expect(sealed.ok).toBe(true);
    if (!sealed.ok) return;
    const inbound = c.receive(sealed.value);
    expect(inbound.ok).toBe(true);
    if (inbound.ok) expect([...(inbound.value as { inner: Uint8Array }).inner]).toEqual([...offer]);

    const answer = utf8(JSON.stringify({ t: "answer", sdp: "v=0" }));
    const back = c.seal(answer);
    expect(back.ok).toBe(true);
    if (!back.ok) return;
    const atHost = h.receive(back.value);
    expect(atHost.ok).toBe(true);
    if (atHost.ok) expect([...(atHost.value as { inner: Uint8Array }).inner]).toEqual([...answer]);
  });
});

describe("§11.2: nothing before the gate", () => {
  test("the host seals nothing until it has opened", () => {
    const h = host();
    const c = client();
    expect(h.seal(utf8("x")).ok).toBe(false);

    const started = c.start();
    if (!started.ok) throw new Error("start");
    const [m2] = cts(h.receive(started.value.ct, started.value.mode));
    // Message 2 is out; the host has said who IT is and knows nothing about the peer.
    expect(h.peerChain).toBeNull();
    expect(h.seal(utf8("x")).ok).toBe(false);

    const [m3] = cts(c.receive(m2!));
    expect(h.receive(m3!).ok).toBe(true);
    // The peer's chain has verified — and that is STILL not authority. `client-confirm` has not
    // arrived, so nothing has proved the peer holds the signing key that chain certifies.
    expect(h.peerChain).not.toBeNull();
    expect(h.maySignal).toBe(false);
    expect(h.seal(utf8("x")).ok).toBe(false);
  });
});

describe("§11.3: what is refused", () => {
  // "Mode is supplied with the initial handshake and bound into the prologue."
  test("an opening envelope with no mode is refused", () => {
    const h = host();
    const c = client();
    const started = c.start();
    if (!started.ok) throw new Error("start");
    expect(h.receive(started.value.ct).ok).toBe(false);
    expect(h.receive(started.value.ct, "auth").ok).toBe(false);
  });

  test("only auth is served here", () => {
    for (const mode of ["pair", "enroll", "resume"]) {
      const h = host();
      const c = client();
      const started = c.start();
      if (!started.ok) throw new Error("start");
      expect(h.receive(started.value.ct, mode).ok, mode).toBe(false);
    }
  });

  // "Decryption failure terminates the signalling session; never skip a failed ciphertext."
  test("a tampered message 3 terminates, and the gate never answers again", () => {
    const h = host();
    const c = client();
    const started = c.start();
    if (!started.ok) throw new Error("start");
    const [m2] = cts(h.receive(started.value.ct, started.value.mode));
    const [m3] = cts(c.receive(m2!));

    const refused = h.receive(flip(m3!, m3!.length - 1));
    expect(refused.ok).toBe(false);
    if (!refused.ok) expect(refused.failure.kind).toBe("noise");
    expect(h.receive(m3!).ok).toBe(false);
    expect(h.maySignal).toBe(false);
  });

  // A room disagreement changes the prologue, which Noise mixes in before anything else.
  test("a different room fails the handshake", () => {
    const h = host({ room: "somewhere-else" });
    const c = client();
    const started = c.start();
    if (!started.ok) throw new Error("start");
    // Message 1 carries no authentication, so it is READ — and message 2 then cannot be read by a
    // peer whose prologue differs, which is where the disagreement surfaces.
    const answer = h.receive(started.value.ct, started.value.mode);
    if (answer.ok) {
      const reply = (answer.value as { cts: Uint8Array[] }).cts[0]!;
      expect(c.receive(reply).ok).toBe(false);
    }
  });

  // §11.1: "A selected Host's `device_id` must also match the selection."
  test("a client that picked another host refuses this one", () => {
    const h = host();
    const c = client({ expect: deviceId(hex(dev("X").descriptor)) });
    const started = c.start();
    if (!started.ok) throw new Error("start");
    const [m2] = cts(h.receive(started.value.ct, started.value.mode));
    const refused = c.receive(m2!);
    expect(refused.ok).toBe(false);
    if (!refused.ok) {
      expect((refused.failure as { failure: string }).failure).toBe("responder-not-selected");
    }
  });

  test("closing shuts the gate", () => {
    const { h } = connect();
    expect(h.maySignal).toBe(true);
    h.close();
    expect(h.maySignal).toBe(false);
    expect(h.seal(utf8("x")).ok).toBe(false);
  });
});

// ---------------------------------------------------------------- `pair`, as the RESPONDER

/**
 * **A browser answering `pair` is adopt-by-code.** The Mac shows its own code and initiates; this
 * side holds the passkey and issues. What is asserted here is the shape that makes that possible:
 * the gate PARKS after message 3 rather than minting, because `receive` is synchronous and a
 * WebAuthn ceremony is not — and the grant cannot be prepared in advance, since it covers a
 * descriptor and an `h` that do not exist until message 3 has arrived.
 */
describe("pair, as the responder", () => {
  /// Drive both gates to the parked point: handshake complete, `client-confirm` verified, nothing
  /// issued and nothing sent.
  function parked (): { h: E2EHostGate; c: E2EClientGate; confirmed: Received } {
    const h = host({ pairingPsk: PSK });
    const c = newcomer();
    const started = c.start();
    expect(started.ok, JSON.stringify(started)).toBe(true);
    if (!started.ok) throw new Error("start");
    expect(started.value.mode).toBe("pair");

    const [m2] = cts(h.receive(started.value.ct, started.value.mode));
    const [m3, confirm] = cts(c.receive(m2!));
    expect(h.receive(m3!).ok).toBe(true);
    const confirmed = h.receive(confirm!);
    expect(confirmed.ok, JSON.stringify(confirmed)).toBe(true);
    if (!confirmed.ok) throw new Error("confirm");
    return { h, c, confirmed: confirmed.value };
  }

  // §9.1 in code: a responder with no open window holds no psk, so the handshake could not complete
  // anyway. Refusing at the door names the reason instead of failing somewhere inside Noise.
  test("pair is refused when no pairing window is open", () => {
    const h = host();
    const started = newcomer().start();
    if (!started.ok) throw new Error("start");
    expect(h.receive(started.value.ct, "pair").ok).toBe(false);
  });

  test("a psk disagreement cannot complete the handshake", () => {
    const h = host({ pairingPsk: PSK });
    const c = newcomer(new Uint8Array(32).fill(0x5b));
    const started = c.start();
    if (!started.ok) throw new Error("start");
    const [m2] = cts(h.receive(started.value.ct, started.value.mode));
    // **XXpsk3 mixes the psk in at message 3**, so the divergence is on the RESPONDER's read, not on
    // the initiator's write. Asserted in that order rather than behind an `if`: a conditional here
    // would pass just as happily if the client had failed earlier, which would prove nothing about
    // the psk.
    const [m3] = cts(c.receive(m2!));
    expect(h.receive(m3!).ok).toBe(false);
  });

  test("it parks instead of minting, and says so", () => {
    const { h, confirmed } = parked();
    expect(confirmed.kind).toBe("awaiting-issuance");

    const pending = h.pendingIssuance;
    expect(pending).not.toBeNull();
    expect(pending!.device).toEqual(hex(dev("N").descriptor));
    expect(pending!.handshakeHash).toHaveLength(32);
    // §10.3's remote binding names the RESPONDER, which on this path is this browser.
    expect(pending!.responderDeviceId).toEqual(deviceId(hex(dev("H").descriptor)));
  });

  // §11.2: nothing may be sent before the gate opens, and a parked session has not opened one.
  test("nothing may be sent while parked", () => {
    const { h } = parked();
    expect(h.maySignal).toBe(false);
    expect(h.seal(new Uint8Array([1, 2, 3])).ok).toBe(false);
  });

  test("issuing opens the gate and hands the newcomer its chain", () => {
    const { h, c } = parked();
    const issued = h.issue(hex(fx.adoption.bundle_for_N));
    expect(issued.ok, JSON.stringify(issued)).toBe(true);
    if (!issued.ok) throw new Error("issue");
    expect(h.maySignal).toBe(true);

    const done = c.receive(issued.value.ct);
    expect(done.ok, JSON.stringify(done)).toBe(true);
    expect(c.acceptedBundle).toEqual(hex(fx.adoption.bundle_for_N));
  });

  /**
   * **Y verifies perfectly and simply does not describe N.** A caller that minted for the wrong
   * device — in a session that holds two of them — is the confusable mistake here, and it is
   * refused where it is legible rather than by the far side a moment later.
   */
  test("a bundle that certifies someone else is refused, and the gate stays shut", () => {
    const { h } = parked();
    expect(h.issue(hex(dev("Y").bundle)).ok).toBe(false);
    expect(h.maySignal).toBe(false);
  });

  test("a bundle under no root this side trusts is refused", () => {
    const { h } = parked();
    expect(h.issue(new Uint8Array(32)).ok).toBe(false);
    expect(h.maySignal).toBe(false);
  });

  test("issuing twice is refused — one window, one chain", () => {
    const { h } = parked();
    expect(h.issue(hex(fx.adoption.bundle_for_N)).ok).toBe(true);
    expect(h.issue(hex(fx.adoption.bundle_for_N)).ok).toBe(false);
  });

  test("auth never parks", () => {
    const { h } = connect();
    expect(h.pendingIssuance).toBeNull();
    expect(h.maySignal).toBe(true);
  });
});
