import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, test } from "vitest";
import { parseInitiatorHello } from "../src/e2e-wire";
import {
  E2EInitiator, E2EResponder, bundlePresenceIsCorrect, responderSatisfiesRole,
  type InitiatorConfig, type ResponderConfig, type SessionResult,
} from "../src/e2e-session";
import { PublicationStatus, type E2EMode } from "../src/e2e-wire";
import { verifyBundle } from "../src/e2e-verify";

// The §11 session state machine, driven through complete handshakes against the world a THIRD
// implementation produced (`scripts/gen_e2e_session_fixture.py`) and which `E2ESessionTests.swift`
// drives too.
//
// THE GATE IS THE SUBJECT. §11.2: "Before this gate ... No SDP, ICE, media, shell, input, or
// subscription authority exists yet." Every test below either walks a session to that point or
// proves something stops it.
interface Device {
  name: string; signing_private_key: string; signing_public_key: string;
  noise_public_key: string; descriptor: string; device_id: string; bundle: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-session.json", import.meta.url)), "utf8")) as {
    rp_id: string; allowed_origins: string[]; root: string; root_id: string;
    devices: Record<string, Device>;
    routes: Record<string, { rcode: string; rtoken: string }>;
    operation_ids: Record<string, string>;
    handshake_hashes: Record<string, string>;
  };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const dev = (n: string): Device => fx.devices[n]!;
const policy = { rpId: fx.rp_id, allowedOrigins: fx.allowed_origins };
const H_A = hex(fx.handshake_hashes.a!);
const H_B = hex(fx.handshake_hashes.b!);
const ZERO = hex(fx.operation_ids.zero!);
const ENROLLMENT = hex(fx.operation_ids.enrollment!);

const unwrap = <T>(r: SessionResult<T>): T => {
  if (!r.ok) throw new Error(`expected ok, got ${r.failure}`);
  return r.value;
};
const failure = <T>(r: SessionResult<T>): string => (r.ok ? "ok" : r.failure);

function responderConfig (name: string, mode: E2EMode,
                          over: Partial<ResponderConfig> = {}): ResponderConfig {
  return {
    mode, roomCode: "room-1",
    device: hex(dev(name).descriptor), bundle: hex(dev(name).bundle),
    route: fx.routes[name] ?? fx.routes.H!,
    trustedRootId: hex(fx.root_id), policy, ...over,
  };
}

function initiatorConfig (name: string, mode: E2EMode,
                          over: Partial<InitiatorConfig> = {}): InitiatorConfig {
  // **In `pair` a newcomer has KEYS and no descriptor**, because §10.2's descriptor names its root
  // and §12.3 puts learning that root AFTER message 2. Everywhere else it has a root already.
  return {
    mode, roomCode: "room-1",
    device: mode === "pair" ? new Uint8Array(0) : hex(dev(name).descriptor),
    ...(mode === "pair"
      ? { devicePublicKeys: { signing: hex(dev(name).signing_public_key),
                              noise: hex(dev(name).noise_public_key) } }
      : {}),
    signingPrivateKey: hex(dev(name).signing_private_key),
    bundle: mode === "auth" ? hex(dev(name).bundle) : new Uint8Array(0),
    operationId: mode === "auth" ? ZERO : ENROLLMENT,
    trustedRootId: hex(fx.root_id), policy, ...over,
  };
}

/// One complete `auth`: C (code-enrolled, capabilities 3) connecting to H (the Host).
function runAuth (opts: {
  initiatorOver?: Partial<InitiatorConfig>;
  responderOver?: Partial<ResponderConfig>;
  confirmHash?: Uint8Array;
  startHash?: Uint8Array;
  acceptedBundle?: Uint8Array;
} = {}) {
  const responder = new E2EResponder(responderConfig("H", "auth", opts.responderOver ?? {}));
  const initiator = E2EInitiator.create(initiatorConfig("C", "auth", opts.initiatorOver ?? {}))!;
  const steps: Record<string, string> = {};

  steps.message1 = failure(responder.receiveMessage1(initiator.message1Payload));
  const m2 = responder.message2Payload();
  steps.message2 = failure(m2);
  if (!m2.ok) return { responder, initiator, steps };

  steps.receiveMessage2 = failure(
    initiator.receiveMessage2(m2.value, hex(dev("H").noise_public_key)));
  const m3 = initiator.message3Payload();
  steps.message3 = failure(m3);
  if (!m3.ok) return { responder, initiator, steps };

  steps.receiveMessage3 = failure(
    responder.receiveMessage3(m3.value, hex(dev("C").noise_public_key)));

  const confirm = initiator.clientConfirm(opts.confirmHash ?? H_A);
  steps.clientConfirm = failure(confirm);
  if (!confirm.ok) return { responder, initiator, steps };

  steps.receiveConfirm = failure(responder.receiveClientConfirm(confirm.value, H_A));
  const start = responder.sessionStart(opts.startHash ?? H_A, PublicationStatus.Confirmed,
                                       opts.acceptedBundle ?? new Uint8Array(0));
  steps.sessionStart = failure(start);
  if (!start.ok) return { responder, initiator, steps };

  steps.receiveSessionStart = failure(initiator.receiveSessionStart(start.value, H_A));
  return { responder, initiator, steps };
}

describe("a complete auth session", () => {
  test("every step succeeds and both ends establish", () => {
    const { responder, initiator, steps } = runAuth();
    expect(steps).toEqual({
      message1: "ok", message2: "ok", receiveMessage2: "ok", message3: "ok",
      receiveMessage3: "ok", clientConfirm: "ok", receiveConfirm: "ok",
      sessionStart: "ok", receiveSessionStart: "ok",
    });
    expect(responder.isEstablished).toBe(true);
    expect(initiator.isEstablished).toBe(true);
  });

  test("the responder learns exactly who it is talking to", () => {
    const { responder } = runAuth();
    expect(responder.initiatorChain).not.toBeNull();
    expect(responder.initiatorChain!.leaf.capabilities).toBe(3);
    expect(responder.initiatorDevice).not.toBeNull();
  });

  test("the initiator persists the responder's durable route", () => {
    // §9.2: persisting it "permits resume after a lost acknowledgement".
    const { initiator } = runAuth();
    expect(initiator.responderRoute).toEqual(fx.routes.H);
  });
});

// §11.2's gate, asserted as a property of every intermediate state rather than only of the end.
// A machine that set `maySignal` one step early would still pass the happy path above.
describe("nothing may signal before the gate", () => {
  test("neither end signals until session-start is verified", () => {
    const responder = new E2EResponder(responderConfig("H", "auth"));
    const initiator = E2EInitiator.create(initiatorConfig("C", "auth"))!;
    const seen: boolean[] = [];
    const watch = (): void => { seen.push(responder.maySignal, initiator.maySignal); };

    watch();
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    watch();
    const m2 = unwrap(responder.message2Payload());
    unwrap(initiator.receiveMessage2(m2, hex(dev("H").noise_public_key)));
    watch();
    const m3 = unwrap(initiator.message3Payload());
    unwrap(responder.receiveMessage3(m3, hex(dev("C").noise_public_key)));
    watch();
    const confirm = unwrap(initiator.clientConfirm(H_A));
    watch();                                   // the initiator has SENT its proof and still may not
    unwrap(responder.receiveClientConfirm(confirm, H_A));
    // The responder is through its gate here; the initiator is not, and that asymmetry is the
    // protocol's — §11.2 gives the initiator its own verification of `session-start`.
    expect(responder.maySignal).toBe(true);
    expect(initiator.maySignal).toBe(false);

    expect(seen).toEqual(new Array(10).fill(false));

    const start = unwrap(responder.sessionStart(H_A, PublicationStatus.Confirmed,
                                                new Uint8Array(0)));
    unwrap(initiator.receiveSessionStart(start, H_A));
    expect(initiator.maySignal).toBe(true);
  });
});

describe("§11.1's role table", () => {
  test("a connect-only responder may not host an auth", () => {
    // X holds capabilities 1. Its chain is perfectly valid and it is the right root — the only
    // thing wrong is that it has no business being the Host.
    const responder = new E2EResponder(responderConfig("X", "auth"));
    const initiator = E2EInitiator.create(initiatorConfig("C", "auth"))!;
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    expect(failure(initiator.receiveMessage2(m2, hex(dev("X").noise_public_key))))
      .toBe("responder-role");
  });

  test("a pair responder must hold a DIRECT grant with enroll", () => {
    // C carries capabilities 3 and is device-issued: it can never carry `enroll` (§10.3), so it can
    // never be a pairing Issuer however the UI presents it.
    const responder = new E2EResponder(responderConfig("C", "pair", { route: fx.routes.H! }));
    const initiator = E2EInitiator.create(
      initiatorConfig("N", "pair", { trustedRootId: null }))!;
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    expect(failure(initiator.receiveMessage2(m2, hex(dev("C").noise_public_key))))
      .toBe("responder-role");
  });

  test("H satisfies both pair and auth; X satisfies neither", () => {
    const chainOf = (name: string) => {
      const v = verifyBundle(hex(dev(name).bundle),
                             { trustedRootId: hex(fx.root_id), policy });
      if (!v.ok) throw new Error(v.failure);
      return v.chain;
    };
    for (const mode of ["pair", "enroll", "auth"] as E2EMode[]) {
      expect(responderSatisfiesRole(mode, chainOf("H"))).toBe(true);
      expect(responderSatisfiesRole(mode, chainOf("X"))).toBe(false);
    }
    // `resume` asks nothing of the role here: §11.1 defers it to the original operation.
    expect(responderSatisfiesRole("resume", chainOf("X"))).toBe(true);
  });
});

describe("§11.1's bundle rules", () => {
  test("required for auth, empty for pair and enroll, either for resume", () => {
    expect(bundlePresenceIsCorrect("auth", true)).toBe(false);
    expect(bundlePresenceIsCorrect("auth", false)).toBe(true);
    for (const mode of ["pair", "enroll"] as E2EMode[]) {
      expect(bundlePresenceIsCorrect(mode, true)).toBe(true);
      expect(bundlePresenceIsCorrect(mode, false)).toBe(false);
    }
    expect(bundlePresenceIsCorrect("resume", true)).toBe(true);
    expect(bundlePresenceIsCorrect("resume", false)).toBe(true);
  });

  test("a pair initiator that ships a bundle is refused before it sends one", () => {
    const initiator = E2EInitiator.create(initiatorConfig("C", "pair", {
      trustedRootId: null, bundle: hex(dev("C").bundle),
    }))!;
    const responder = new E2EResponder(responderConfig("H", "pair"));
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    unwrap(initiator.receiveMessage2(m2, hex(dev("H").noise_public_key)));
    expect(failure(initiator.message3Payload())).toBe("bundle-presence");
  });

  test("an auth with no bundle is refused by the responder", () => {
    const { steps } = runAuth({ initiatorOver: { bundle: new Uint8Array(0) } });
    expect(steps.message3).toBe("bundle-presence");
  });
});

describe("the descriptor must be the peer the handshake authenticated", () => {
  test("a descriptor whose DH key is not the Noise static is refused", () => {
    const responder = new E2EResponder(responderConfig("H", "auth"));
    const initiator = E2EInitiator.create(initiatorConfig("C", "auth"))!;
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    unwrap(initiator.receiveMessage2(m2, hex(dev("H").noise_public_key)));
    const m3 = unwrap(initiator.message3Payload());
    // C's own descriptor, presented over a handshake that authenticated X's key.
    expect(failure(responder.receiveMessage3(m3, hex(dev("X").noise_public_key))))
      .toBe("descriptor-key-mismatch");
  });

  test("a responder chain bound to another device's key is refused", () => {
    const initiator = E2EInitiator.create(initiatorConfig("C", "auth"))!;
    const responder = new E2EResponder(responderConfig("H", "auth"));
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    expect(failure(initiator.receiveMessage2(m2, hex(dev("C").noise_public_key))))
      .toBe("peer-chain");
  });

  test("a selected Host that answers with a different device is refused", () => {
    const initiator = E2EInitiator.create(initiatorConfig("C", "auth", {
      expectedResponderDeviceId: hex(dev("X").device_id),
    }))!;
    const responder = new E2EResponder(responderConfig("H", "auth"));
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    expect(failure(initiator.receiveMessage2(m2, hex(dev("H").noise_public_key))))
      .toBe("responder-not-selected");
  });
});

describe("the device proof is about THIS session", () => {
  test("a proof body naming a different handshake is refused", () => {
    // The initiator signs over H_B; the responder composes the body from H_A. The SIGNATURE is
    // perfectly valid — what fails is that it is a statement about a different session.
    const { steps } = runAuth({ confirmHash: H_B });
    expect(steps.receiveConfirm).toBe("proof-body-mismatch");
  });

  test("the responder rebuilds the body rather than trusting the one it was sent", () => {
    // Proof: swap the signing key so the SIGNATURE is wrong while the body is right, and confirm a
    // different failure. If the responder verified the supplied body, both cases would look alike.
    const responder = new E2EResponder(responderConfig("H", "auth"));
    const initiator = E2EInitiator.create(initiatorConfig("C", "auth", {
      signingPrivateKey: hex(dev("X").signing_private_key),
    }))!;
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    unwrap(initiator.receiveMessage2(m2, hex(dev("H").noise_public_key)));
    const m3 = unwrap(initiator.message3Payload());
    unwrap(responder.receiveMessage3(m3, hex(dev("C").noise_public_key)));
    const confirm = unwrap(initiator.clientConfirm(H_A));
    expect(failure(responder.receiveClientConfirm(confirm, H_A))).toBe("proof-signature");
  });
});

describe("session-start must answer THIS session", () => {
  test("a different handshake hash is refused", () => {
    const { steps } = runAuth({ startHash: H_B });
    expect(steps.receiveSessionStart).toBe("handshake-hash-mismatch");
  });

  test("an accepted chain for another device is refused", () => {
    // H's own perfectly valid bundle, returned to C. Every signature verifies; it just is not C's.
    const { steps } = runAuth({ acceptedBundle: hex(dev("H").bundle) });
    expect(steps.receiveSessionStart).toBe("accepted-chain-mismatch");
  });

  // THE CASE THAT MADE THE DEVICE-EQUALITY CHECK NON-REDUNDANT. Y holds C's NOISE key with a
  // different signing key, so its chain satisfies "the leaf's DH key is the static this session
  // authenticated" — and carries capabilities 7 against C's 3. Nothing but comparing the descriptor
  // itself separates them, and a mutation removing that comparison passed the whole suite until
  // this device existed.
  test("an accepted chain that merely shares this device's DH key is refused", () => {
    expect(dev("Y").noise_public_key).toBe(dev("C").noise_public_key);
    expect(dev("Y").signing_public_key).not.toBe(dev("C").signing_public_key);
    const { steps } = runAuth({ acceptedBundle: hex(dev("Y").bundle) });
    expect(steps.receiveSessionStart).toBe("accepted-chain-mismatch");
  });

  test("a responder refuses a message-3 chain that merely shares the peer's DH key", () => {
    // The same confusion in the other direction: C's descriptor presented with Y's bundle.
    const responder = new E2EResponder(responderConfig("H", "auth"));
    const initiator = E2EInitiator.create(initiatorConfig("C", "auth", {
      bundle: hex(dev("Y").bundle),
    }))!;
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    unwrap(initiator.receiveMessage2(m2, hex(dev("H").noise_public_key)));
    const m3 = unwrap(initiator.message3Payload());
    expect(failure(responder.receiveMessage3(m3, hex(dev("C").noise_public_key))))
      .toBe("peer-chain");
  });

  test("an ordinary auth carries an all-zero operation id", () => {
    const { steps } = runAuth({ initiatorOver: { operationId: ENROLLMENT } });
    expect(steps.receiveMessage3).toBe("operation-id-mismatch");
  });
});

describe("pair bootstraps its root; nothing else may", () => {
  test("a newcomer with no trusted root completes a pair", () => {
    const responder = new E2EResponder(responderConfig("H", "pair"));
    const initiator = E2EInitiator.create(initiatorConfig("N", "pair", {
      trustedRootId: null, bundle: new Uint8Array(0),
    }))!;
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    unwrap(initiator.receiveMessage2(m2, hex(dev("H").noise_public_key)));
    const m3 = unwrap(initiator.message3Payload());
    unwrap(responder.receiveMessage3(m3, hex(dev("N").noise_public_key)));
    const confirm = unwrap(initiator.clientConfirm(H_A));
    unwrap(responder.receiveClientConfirm(confirm, H_A));
    expect(responder.maySignal).toBe(true);
    // §10.1: the root the newcomer adopted is the Issuer's, learned through the PSK-authenticated
    // exchange and nowhere else.
    expect(initiator.responderChain!.root.bytes).toEqual(hex(fx.root));
  });

  test("auth, enroll and resume refuse to be built without a trusted root", () => {
    for (const mode of ["auth", "enroll", "resume"] as E2EMode[]) {
      expect(E2EInitiator.create(initiatorConfig("C", mode, { trustedRootId: null }))).toBeNull();
    }
    expect(E2EInitiator.create(initiatorConfig("N", "pair", { trustedRootId: null })))
      .not.toBeNull();
  });

  /// **A `pair` newcomer needs its keys at CONSTRUCTION, and everything else needs a descriptor.**
  /// Refused there rather than three messages in, where the failure would be a `malformed` payload
  /// naming neither the missing input nor the mode that wanted it. The Swift mirror is
  /// `testTheDescriptorAndTheKeysAreRequiredByOppositeModes`.
  test("the descriptor and the keys are required by opposite modes", () => {
    // `pair` with no keys: it could never name itself after adopting the root.
    expect(E2EInitiator.create(initiatorConfig("N", "pair", {
      trustedRootId: null, devicePublicKeys: undefined,
    }))).toBeNull();
    // `auth` with no descriptor: there is a root already, so there is nothing to wait for.
    expect(E2EInitiator.create(initiatorConfig("C", "auth", {
      device: new Uint8Array(0),
    }))).toBeNull();
  });

  /// The descriptor a `pair` newcomer presents is built from the root it just ADOPTED — the ordering
  /// §12.3 spells out, and the thing a fixture descriptor cannot demonstrate because it already
  /// names the right root.
  test("a pair newcomer names itself after adopting the root", () => {
    const responder = new E2EResponder(responderConfig("H", "pair"));
    const initiator = E2EInitiator.create(initiatorConfig("N", "pair", {
      trustedRootId: null, bundle: new Uint8Array(0),
    }))!;
    unwrap(responder.receiveMessage1(initiator.message1Payload));
    const m2 = unwrap(responder.message2Payload());
    unwrap(initiator.receiveMessage2(m2, hex(dev("H").noise_public_key)));
    const hello = parseInitiatorHello(unwrap(initiator.message3Payload()))!;
    expect([...hello.device]).toEqual([...hex(dev("N").descriptor)]);
  });
});

describe("§11.3: one handshake, and a failure is terminal", () => {
  let responder: E2EResponder;
  let initiator: E2EInitiator;
  beforeEach(() => {
    responder = new E2EResponder(responderConfig("H", "auth"));
    initiator = E2EInitiator.create(initiatorConfig("C", "auth"))!;
  });

  test("message 1 may not carry a payload", () => {
    expect(failure(responder.receiveMessage1(new Uint8Array([0])))).toBe("message1-not-empty");
    expect(responder.stage).toBe("terminated");
  });

  test("a second message 1 is out of order", () => {
    unwrap(responder.receiveMessage1(new Uint8Array(0)));
    expect(failure(responder.receiveMessage1(new Uint8Array(0)))).toBe("out-of-order");
  });

  test("every refusal terminates, and a terminated session accepts nothing", () => {
    expect(failure(responder.receiveMessage1(new Uint8Array([1])))).toBe("message1-not-empty");
    expect(failure(responder.message2Payload())).toBe("out-of-order");
    expect(failure(responder.receiveMessage3(new Uint8Array(0), new Uint8Array(32))))
      .toBe("out-of-order");
    expect(failure(responder.receiveClientConfirm(new Uint8Array(0), H_A))).toBe("out-of-order");
    expect(responder.maySignal).toBe(false);
  });

  test("terminate is one-way", () => {
    unwrap(responder.receiveMessage1(new Uint8Array(0)));
    responder.terminate();
    expect(failure(responder.message2Payload())).toBe("out-of-order");
    expect(responder.maySignal).toBe(false);
  });

  test("the initiator cannot confirm before its peer's chain has verified", () => {
    expect(failure(initiator.clientConfirm(H_A))).toBe("out-of-order");
    expect(failure(initiator.message3Payload())).toBe("out-of-order");
  });

  test("session-start is unreachable until the responder is through its gate", () => {
    unwrap(responder.receiveMessage1(new Uint8Array(0)));
    expect(failure(responder.sessionStart(H_A, PublicationStatus.Confirmed, new Uint8Array(0))))
      .toBe("out-of-order");
  });
});

test("a revoked peer cannot complete a session", () => {
  // §10.5: "Reject any chain containing a tombstoned device, including an Issuer." H is C's Issuer,
  // so revoking H kills C's chain as well as H's own.
  const { steps } = runAuth({ responderOver: { revokedDeviceIds: [hex(dev("C").device_id)] } });
  expect(steps.receiveMessage3).toBe("peer-chain");

  const asIssuer = runAuth({ initiatorOver: { revokedDeviceIds: [hex(dev("H").device_id)] } });
  expect(asIssuer.steps.receiveMessage2).toBe("peer-chain");
});
