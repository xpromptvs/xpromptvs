import { describe, expect, test } from "vitest";
import type { E2EClientGate, GateFailure, GateResult, Received } from "@rdev/protocol";
import { SecureSignalling, type SecureSignallingIO } from "../src/client/e2e-signalling";

// The client's §11 session over the signalling socket. `E2EClientGate` decides everything and has
// its own suite; what is tested here is the CARRIER — what goes on the wire, in what order, and the
// one rule that cannot live inside the gate because it is about the caller: §11.2, nothing is sent
// until the gate opens and what is sent afterwards goes inside it or not at all.

const b64u = (bytes: Uint8Array): string => {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

/// A gate that answers from a script, and records what it was handed.
class FakeGate {
  maySignal = false;
  readonly received: Uint8Array[] = [];
  readonly sealed: Uint8Array[] = [];
  closed = 0;
  startResult: GateResult<{ ct: Uint8Array; mode: "auth" }> =
    { ok: true, value: { ct: new Uint8Array([1]), mode: "auth" } };
  receiveResults: Array<GateResult<Received>> = [];
  sealResult: GateResult<Uint8Array> = { ok: true, value: new Uint8Array([9]) };

  start (): GateResult<{ ct: Uint8Array; mode: "auth" }> { return this.startResult; }
  receive (ct: Uint8Array): GateResult<Received> {
    this.received.push(ct);
    return this.receiveResults.shift() ?? { ok: true, value: { kind: "nothing" } };
  }
  seal (message: Uint8Array): GateResult<Uint8Array> {
    this.sealed.push(message);
    return this.sealResult;
  }
  close (): void { this.closed++; }
}

interface Harness {
  secure: SecureSignalling;
  gate: FakeGate;
  sent: Array<{ ct: string; mode?: string }>;
  delivered: unknown[];
  closures: string[];
  opens: number;
}

function harness (): Harness {
  const gate = new FakeGate();
  const sent: Array<{ ct: string; mode?: string }> = [];
  const delivered: unknown[] = [];
  const closures: string[] = [];
  const counter = { opens: 0 };
  const io: SecureSignallingIO = {
    sendE2E: (ct, mode) => { sent.push(mode === undefined ? { ct } : { ct, mode }); },
    deliver: (m) => { delivered.push(m); },
    onClosed: (reason) => { closures.push(reason); },
    onOpen: () => { counter.opens++; },
  };
  return {
    secure: new SecureSignalling(gate as unknown as E2EClientGate, io),
    gate, sent, delivered, closures,
    get opens () { return counter.opens; },
  } as Harness;
}

describe("opening the session", () => {
  // §11.3: "Mode is supplied with the initial handshake and bound into the prologue."
  test("the first envelope carries the mode, and nothing else does", () => {
    const h = harness();
    h.secure.start();
    expect(h.sent).toEqual([{ ct: b64u(new Uint8Array([1])), mode: "auth" }]);

    h.gate.receiveResults = [{ ok: true, value: { kind: "reply", cts: [new Uint8Array([2])] } }];
    h.secure.receive(b64u(new Uint8Array([3])));
    expect(h.sent[1]).toEqual({ ct: b64u(new Uint8Array([2])) });
  });

  // Message 3 and `client-confirm` are two Noise messages, so they are two envelopes — in order.
  test("a reply carrying two messages sends two envelopes, in order", () => {
    const h = harness();
    h.gate.receiveResults = [{
      ok: true,
      value: { kind: "reply", cts: [new Uint8Array([7]), new Uint8Array([8])] },
    }];
    h.secure.receive(b64u(new Uint8Array([1])));
    expect(h.sent.map((s) => s.ct)).toEqual([b64u(new Uint8Array([7])), b64u(new Uint8Array([8]))]);
    expect(h.sent.every((s) => s.mode === undefined)).toBe(true);
  });
});

describe("§11.2: nothing before the gate", () => {
  test("maySignal follows the gate, and a closed carrier signals nothing", () => {
    const h = harness();
    expect(h.secure.maySignal).toBe(false);
    h.gate.maySignal = true;
    expect(h.secure.maySignal).toBe(true);
    h.secure.close();
    expect(h.secure.maySignal).toBe(false);
  });

  // The gate is what refuses; what is tested here is that the carrier REPORTS the refusal rather
  // than sending something anyway — a caller that answered in plaintext when this returned false
  // would be the whole protocol opted out of by a peer that declined to handshake.
  test("a refused seal sends nothing and says so", () => {
    const h = harness();
    h.gate.sealResult = { ok: false, failure: { kind: "not-established" } };
    expect(h.secure.send({ t: "answer", sdp: "v=0" })).toBe(false);
    expect(h.sent).toHaveLength(0);
    expect(h.closures).toEqual(["not-established"]);
  });

  test("a sealed message is the JSON the plain arms carry", () => {
    const h = harness();
    expect(h.secure.send({ t: "answer", sdp: "v=0" })).toBe(true);
    expect(JSON.parse(new TextDecoder().decode(h.gate.sealed[0]!)))
      .toEqual({ t: "answer", sdp: "v=0" });
    expect(h.sent).toEqual([{ ct: b64u(new Uint8Array([9])) }]);
  });
});

describe("what arrives", () => {
  test("an inner message is delivered as the object it is", () => {
    const h = harness();
    const inner = new TextEncoder().encode(JSON.stringify({ t: "offer", sdp: "v=0" }));
    h.gate.receiveResults = [{ ok: true, value: { kind: "signalling", inner } }];
    h.secure.receive(b64u(new Uint8Array([1])));
    expect(h.delivered).toEqual([{ t: "offer", sdp: "v=0" }]);
  });

  test("an unreadable inner message closes the session rather than guessing", () => {
    const h = harness();
    h.gate.receiveResults = [{
      ok: true, value: { kind: "signalling", inner: new TextEncoder().encode("{oh no") },
    }];
    h.secure.receive(b64u(new Uint8Array([1])));
    expect(h.delivered).toHaveLength(0);
    expect(h.closures).toEqual(["unreadable-inner-message"]);
  });

  // **FRAMING IS NOT DECRYPTION.** §11.3's terminate-on-failure rule is about ciphertext; an
  // envelope that is not base64url never reached a Noise session, so it must not kill one.
  test("an envelope that is not base64url is dropped, not fatal", () => {
    const h = harness();
    h.secure.receive("not base64url!!");
    expect(h.gate.received).toHaveLength(0);
    expect(h.closures).toHaveLength(0);
    expect(h.secure.maySignal).toBe(false);
    // …and the session still works afterwards.
    h.gate.maySignal = true;
    expect(h.secure.send({ t: "answer" })).toBe(true);
  });

  // §11.3: "Decryption failure terminates the signalling session; never skip a failed ciphertext."
  test("a gate failure closes the carrier, and nothing reaches the gate afterwards", () => {
    const h = harness();
    const failure: GateFailure = { kind: "noise" };
    h.gate.receiveResults = [{ ok: false, failure }];
    h.secure.receive(b64u(new Uint8Array([1])));
    expect(h.closures).toEqual(["noise"]);

    h.secure.receive(b64u(new Uint8Array([2])));
    expect(h.gate.received).toHaveLength(1);
    expect(h.secure.send({ t: "answer" })).toBe(false);
    expect(h.gate.sealed).toHaveLength(0);
  });

  test("a session failure names the reason, so a refusal is not confused with a forged frame", () => {
    const h = harness();
    h.gate.receiveResults = [{ ok: false, failure: { kind: "session", failure: "peer-chain" } }];
    h.secure.receive(b64u(new Uint8Array([1])));
    expect(h.closures).toEqual(["session:peer-chain"]);
  });
});

test("closing is idempotent and closes the gate once", () => {
  const h = harness();
  h.secure.close();
  h.secure.close();
  expect(h.gate.closed).toBe(1);
});

// ----------------------------------------------------------------- §11.2's gate, as an EDGE

describe("onOpen", () => {
  // A `pair` session earns a chain, and the caller persists it exactly once. `maySignal` is a LEVEL
  // — true for the rest of the session — so a caller driven off it would rewrite the same bytes on
  // every envelope for as long as the connection lasted.
  test("fires once, on the transition, not on every envelope afterwards", () => {
    const h = harness();
    h.secure.start();

    h.gate.receiveResults = [{ ok: true, value: { kind: "nothing" } }];
    h.secure.receive(b64u(new Uint8Array([2])));
    expect(h.opens).toBe(0);                       // the gate has not opened yet

    h.gate.maySignal = true;
    h.gate.receiveResults = [{ ok: true, value: { kind: "nothing" } }];
    h.secure.receive(b64u(new Uint8Array([3])));   // session-start
    expect(h.opens).toBe(1);

    const inner = new TextEncoder().encode(JSON.stringify({ t: "offer", sdp: "v=0" }));
    h.gate.receiveResults = [{ ok: true, value: { kind: "signalling", inner } }];
    h.secure.receive(b64u(new Uint8Array([4])));
    expect(h.opens).toBe(1);
    expect(h.delivered).toHaveLength(1);
  });

  test("a session that never opens never announces one", () => {
    const h = harness();
    h.secure.start();
    h.gate.receiveResults = [{ ok: false, failure: { kind: "noise" } as GateFailure }];
    h.secure.receive(b64u(new Uint8Array([2])));
    expect(h.opens).toBe(0);
  });
});

// 2026-10-07: a new Mac's ADD-BY-CODE code pasted into Connect. That Mac initiates its own `pair` (it speaks first,
// naming a mode), so this initiator met a second opening — read as its reply, a decryption failure (`noise`) and a
// reconnect loop. Said as what it is, the gate never handed it, and nothing retries.
describe("a peer that opens a handshake of its own", () => {
  test("is `peer-initiated`, before the gate sees a byte", () => {
    const h = harness();
    h.secure.start();
    h.secure.receive(b64u(new Uint8Array([5])), "pair");
    expect(h.closures).toEqual(["peer-initiated"]);
    expect(h.gate.received).toHaveLength(0);
    expect(h.gate.closed).toBe(1);
  });

  test("a reply naming no mode is a reply, as ever", () => {
    const h = harness();
    h.secure.start();
    h.secure.receive(b64u(new Uint8Array([5])));
    expect(h.closures).toEqual([]);
    expect(h.gate.received).toHaveLength(1);
  });

  // A RESPONDER (no `start`) is handed the initiator's mode — that is how it learns the pattern.
  test("a responder takes the mode as the opening it is", () => {
    const h = harness();
    (h.gate as unknown as { start?: unknown }).start = undefined;
    h.secure.receive(b64u(new Uint8Array([5])), "auth");
    expect(h.closures).toEqual([]);
    expect(h.gate.received).toHaveLength(1);
  });
});
