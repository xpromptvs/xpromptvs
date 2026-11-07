import { beforeEach, describe, expect, test } from "vitest";
import fixture from "../../protocol/fixtures/e2e-session.json";
import {
  deviceId as hashDevice, descriptor as descriptorFor, decodeTrustRecord, encodeInstallation,
  deviceKeys, rootId as hashRoot, signingPublicKey, noisePublicKey,
  type InstallationBackend,
} from "@rdev/protocol";
import {
  grantCommitment, parseBundle, parseGrant, root as rootDescriptor, parseRoot,
} from "@rdev/protocol";
import { ClientE2EIdentity, type IdentityEnvironment } from "../src/client/e2e-identity";
import type { CredentialLookup } from "../src/lib/credential-lookup";

// The browser's own identity, and the one property that matters about it: **the browser enrols
// itself, in place**, because the page IS the relying party's origin. What is faked here is exactly
// the authenticator — `webauthn-ceremony.test.ts` covers the ceremony's own request and response
// handling, and `e2e/webauthn-check.mjs` drives a REAL one — so what these tests see is the part
// that is this module's: which root is joined, what is written, and when a person is asked.
interface Device {
  signing_private_key: string; noise_private_key: string; descriptor: string; bundle: string;
}
const fx = fixture as unknown as {
  rp_id: string; allowed_origins: string[]; root: string; root_id: string;
  devices: Record<string, Device>;
};
const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const C = fx.devices.C!;
const ORIGIN = fx.allowed_origins[0]!;

/// An in-memory `InstallationBackend`, and a record of what it was asked to do.
class Memory implements InstallationBackend {
  value: Uint8Array | null = null;
  writes = 0;
  failWrites = false;
  failDeletes = false;
  constructor (initial: Uint8Array | null = null) { this.value = initial; }
  async read (): Promise<Uint8Array | null> { return this.value; }
  async write (bytes: Uint8Array): Promise<boolean> {
    this.writes++;
    if (this.failWrites) return false;
    this.value = bytes;
    return true;
  }
  async delete (): Promise<boolean> {
    if (this.failDeletes) return false;
    this.value = null;
    return true;
  }
}

/// Seeded to be the fixture's device C, which is what makes C's bundle a valid return for it.
const seededInstallation = (): Memory =>
  new Memory(encodeInstallation({
    keys: deviceKeys(hex(C.signing_private_key), hex(C.noise_private_key))!,
    rendezvousSeed: new Uint8Array(32).fill(0xE0),
  }));

interface Harness {
  identity: ClientE2EIdentity;
  installations: Memory;
  trust: Memory;
  asked: Uint8Array[];
  issued: Array<{ root: Uint8Array; device: Uint8Array }>;
  created: number;
  pending: Memory;
}

/// A REAL WebAuthn assertion for the fixture root, out of device H's root-issued certificate, with
/// that grant's §10.4 COMMITMENT as the pre-image. That is exactly the shape a discovery ceremony
/// produces — a pre-image the caller holds, hashed into the challenge — so `verifyDiscoveredRoot`
/// runs the same ECDSA path here that it will run in a browser, against a signature
/// `scripts/e2e_sigs.py` produced rather than one this suite made up for itself.
///
/// The commitment rather than the grant because that is what a root passkey signs now. It is also
/// why ONE ceremony can do both jobs: the assertion that identifies the credential is the same one
/// the grant is made of.
const DISCOVERY = (() => {
  const parsed = parseBundle(hex(fx.devices.H!.bundle));
  if (!parsed.ok) throw new Error("fixture bundle H does not parse");
  const certificate = parsed.bundle.certificates[0]!;
  const grant = parseGrant(certificate.grant);
  const preimage = grant && grantCommitment(grant, hashRoot(hex(fx.root)));
  if (!preimage) throw new Error("fixture grant H has no commitment");
  return {
    credentialId: parseRoot(hex(fx.root))!.credentialId,
    preimage,
    assertion: certificate.evidence,
  };
})();

function harness (opts: {
  confirm?: boolean;
  issue?: IdentityEnvironment["issue"];
  createRoot?: IdentityEnvironment["createRoot"];
  discoverRoot?: IdentityEnvironment["discoverRoot"];
  rootCheck?: IdentityEnvironment["rootCheck"];
  signalUnknown?: IdentityEnvironment["signalUnknown"];
  trust?: Memory;
  pending?: Memory;
  installations?: Memory;
  random?: IdentityEnvironment["random"];
  bundle?: Uint8Array;
} = {}): Harness {
  const installations = opts.installations ?? seededInstallation();
  const trust = opts.trust ?? new Memory();
  const asked: Uint8Array[] = [];
  const issued: Array<{ root: Uint8Array; device: Uint8Array }> = [];
  let created = 0;

  const env: IdentityEnvironment = {
    createRoot: opts.createRoot ?? (async () => {
      created++;
      return { ok: true, value: { root: hex(fx.root), credentialId: new Uint8Array(16) } } as any;
    }),
    discoverRoot: opts.discoverRoot ?? (async () => ({
      ok: true, value: { ...DISCOVERY, blob: null },
    })),
    // The same REAL assertion `DISCOVERY` carries, which is what makes the verification below run
    // the actual ECDSA path rather than agreeing with a stand-in.
    rootCheck: opts.rootCheck ?? (async () => ({
      ok: true,
      value: { challenge: new Uint8Array(32), preimage: DISCOVERY.preimage,
               assertion: DISCOVERY.assertion },
    })),
    signalUnknown: opts.signalUnknown ?? (async () => "signalled"),
    issue: opts.issue ?? (async (request) => {
      issued.push({ root: request.root, device: request.device });
      return { ok: true, bundle: opts.bundle ?? hex(C.bundle) };
    }),
    random: opts.random ?? ((n) => new Uint8Array(n).fill(7)),
  };
  const pending = opts.pending ?? new Memory();
  const identity = new ClientE2EIdentity(installations, trust,
                                         { rpId: fx.rp_id, rpName: "Xpromptvs" }, ORIGIN, env,
                                         pending);
  return {
    identity, installations, trust, pending, asked, issued,
    get created () { return created; },
  } as Harness;
}


const H = fx.devices.H!;

/// **A harness signing in as the device the fixture's root-issued certificate actually certifies.**
///
/// `signIn` computes §10.4's commitment ITSELF, from this browser's own signing and noise keys plus
/// the operation id and binding it just generated — and the fixture's assertion was signed over
/// exactly one set of bytes. So to exercise the REAL ECDSA path (rather than agreeing with a
/// stand-in this suite made up) the installation has to BE device H, and `random` has to replay H's
/// grant's operation id and binding randomness in the order `signIn` asks for them.
///
/// The seeded default is device C, whose bundle is a two-link chain (root → H → C) with no
/// root-issued grant of its own — which is why it cannot be the one signing in.
const H_OPERATION = new Uint8Array(32).fill(0xB0);
const H_BINDING_RANDOM = new Uint8Array(32).fill(0xC0);

const replaying = (...queued: Uint8Array[]): IdentityEnvironment["random"] => {
  let at = 0;
  return (n: number) => queued.length === 0
    ? new Uint8Array(n).fill(7)
    : queued[at++ % queued.length]!;
};

const signingIn = (opts: Parameters<typeof harness>[0] = {}): Harness => harness({
  installations: new Memory(encodeInstallation({
    keys: deviceKeys(hex(H.signing_private_key), hex(H.noise_private_key))!,
    rendezvousSeed: new Uint8Array(32).fill(0xE0),
  })),
  random: replaying(H_OPERATION, H_BINDING_RANDOM),
  bundle: hex(H.bundle),
  ...opts,
});

/// Joining an identity this browser did not create — ONE ceremony now, so the tests that used to
/// call `enroll({route:"adopt"})` after a separate `discover()` call `signIn` instead. The lookup is
/// what the Control Plane would answer.
const joins = (h: Harness, root: Uint8Array = hex(fx.root)) =>
  h.identity.signIn(async () => ({ kind: "found", root }));

describe("before enrollment", () => {
  test("a fresh browser is unenrolled, and loading created its keys", async () => {
    const h = harness();
    expect((await h.identity.status()).kind).toBe("unenrolled");
    expect(h.installations.value).not.toBeNull();
    expect(h.trust.value).toBeNull();
  });

  // The difference is a browser that has never enrolled against one that HAS and cannot say so.
  // Only the first should quietly start a ceremony.
  test("an unreadable trust record is blocked, never unenrolled", async () => {
    const h = harness({ trust: new Memory(new Uint8Array([0xff, 0xff, 0xff])) });
    const status = await h.identity.status();
    expect(status.kind).toBe("blocked");
    if (status.kind === "blocked") expect(status.reason).toBe("unreadable-trust");
  });
});

describe("enrolling", () => {
  test("joining an identity issues to THIS browser's descriptor, under the root it was given",
       async () => {
    const h = signingIn();
    const result = await joins(h);
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(h.issued).toHaveLength(1);
    expect([...h.issued[0]!.root]).toEqual([...hex(fx.root)]);
    expect([...h.issued[0]!.device]).toEqual([...hex(H.descriptor)]);
    // A supplied root is JOINED, never replaced by a new one.
    expect(h.created).toBe(0);

    const status = await h.identity.status();
    expect(status.kind).toBe("ready");
    if (status.kind === "ready") {
      expect([...status.deviceId]).toEqual([...hashDevice(hex(H.descriptor))]);
    }
  });

  // **THE SECOND PROMPT NEEDS ITS OWN WORDS, SO THE FLOW HAS TO SAY WHEN IT IS COMING.** Creating
  // costs two prompts and the panel showed one message across both, which reads as the same request
  // repeating. This callback is what lets the screen move on, and its ORDER is the point: it fires
  // after the passkey exists and before the grant ceremony, never at the end.
  test("creating reports the passkey BETWEEN the two ceremonies", async () => {
    const order: string[] = [];
    const h = harness({
      createRoot: async () => {
        order.push("created");
        return { ok: true, value: { root: hex(fx.root), credentialId: new Uint8Array(16) } } as never;
      },
      issue: async () => { order.push("granted"); return { ok: true, bundle: hex(C.bundle) }; },
    });
    const result = await h.identity.enroll({ route: "create" }, () => { order.push("announced"); });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(order).toEqual(["created", "announced", "granted"]);
  });

  // **THE GRANT'S PROMPT WAITS FOR THE PERSON.** Safari refused a `get()` started straight after the
  // `create()` (2026-10-03), so the panel answers the announcement only when Continue is pressed —
  // and the grant must not start before that answer.
  test("the grant waits for the announcement's answer", async () => {
    const order: string[] = [];
    let go!: (v: boolean) => void;
    const h = harness({
      issue: async () => { order.push("granted"); return { ok: true, bundle: hex(C.bundle) }; },
    });
    const running = h.identity.enroll({ route: "create" },
      () => { order.push("announced"); return new Promise<boolean>((r) => { go = r; }); });
    await new Promise((r) => setTimeout(r, 0));
    expect(order, "nothing granted before the person says go").toEqual(["announced"]);
    go(true);
    expect((await running).ok).toBe(true);
    expect(order).toEqual(["announced", "granted"]);
  });

  // "Not now": no grant, a dismissal (the form, not a failure screen), and the passkey still retained
  // for Finish setting up.
  test("an answer of no stops before the grant and keeps the passkey", async () => {
    let granted = 0;
    const h = harness({ issue: async () => { granted += 1; return { ok: true, bundle: hex(C.bundle) }; } });
    const result = await h.identity.enroll({ route: "create" }, async () => false);
    expect(result).toEqual({ ok: false, failure: { kind: "ceremony", failure: "dismissed" } });
    expect(granted).toBe(0);
    expect([...(h.pending.value as unknown as Uint8Array)]).toEqual([...hex(fx.root)]);
  });

  // A route with ONE ceremony must not announce a second prompt that never comes.
  test("no other route announces a second prompt", async () => {
    let announced = 0;
    const resumed = harness({ pending: new Memory(hex(fx.root)) });
    await resumed.identity.enroll({ route: "resume" }, () => { announced += 1; });
    expect(announced, "resume has one ceremony").toBe(0);
  });

  // **The retention write comes FIRST.** A person told the passkey is safe before the entry that
  // makes it recoverable exists has been told something that is not yet true.
  test("the passkey is retained before it is announced", async () => {
    const order: string[] = [];
    const pending = new Memory();
    const write = pending.write.bind(pending);
    pending.write = async (b: Uint8Array) => { order.push("retained"); return write(b); };
    const h = harness({ pending });
    await h.identity.enroll({ route: "create" }, () => { order.push("announced"); });
    expect(order.slice(0, 2)).toEqual(["retained", "announced"]);
  });

  test("with no root to join, one is created", async () => {
    const h = harness();
    const result = await h.identity.enroll({ route: "create" });
    expect(result.ok).toBe(true);
    expect(h.created).toBe(1);
  });

  // §10.1's Residual is about a candidate the DIRECTORY named, and our discovery is the reverse:
  // `allowCredentials: []`, the authenticator offers what it holds, the person picks from the OS
  // list, and the directory is consulted only afterwards about what they chose. So adopting asks
  // nothing — the identity is stated on the success screen, with sign-out beside it.
  // `docs/superpowers/specs/2026-09-14-identity-code-and-signin-flow-design.md` §1.
  test("ADOPTING ASKS NOTHING — there is no directory-named candidate to be steered to", async () => {
    const h = signingIn();
    const result = await joins(h);
    expect(result.ok).toBe(true);
    expect(h.issued).toHaveLength(1);
    expect([...h.issued[0]!.root]).toEqual([...hex(fx.root)]);
    expect(h.trust.value).not.toBeNull();
  });

  // A device that already trusts a root is deciding nothing. Asking anyway would train a person to
  // say yes — and §10.1 forbids replacing a root in any case.
  test("a second enrollment under the root already trusted asks nobody", async () => {
    const h = signingIn();
    await joins(h);
    let asked = 0;
    const again = await joins(h);
    expect(again.ok).toBe(true);
    expect(asked).toBe(0);
  });

  // §10.1: "possession of a new passkey cannot remotely replace a Host's existing root."
  //
  // **Signing in REFUSES rather than silently substituting.** `enroll` issues under the root it
  // already holds; sign-in cannot do that quietly, because the person just chose a passkey and
  // enrolling a different identity than the one they picked is the same surprise in reverse.
  test("a DIFFERENT root cannot replace the one already trusted", async () => {
    const h = signingIn();
    await joins(h);
    const before = h.trust.value;
    h.issued.length = 0;

    const other = new Uint8Array(hex(fx.root));
    other.set([(other.at(-1) ?? 0) ^ 0xff], other.length - 1);
    const second = await joins(h, other);

    expect(second.ok).toBe(false);
    expect(h.issued, "nothing is issued under a root that is not the trusted one").toHaveLength(0);
    expect([...h.trust.value!]).toEqual([...before!]);
  });

  // A chain that verifies for SOMEONE ELSE is a perfectly valid grant this browser cannot use, and
  // storing it would leave the client presenting keys it does not hold.
  test("a bundle certifying another device is refused", async () => {
    const h = signingIn({ issue: async () => ({ ok: true, bundle: hex(C.bundle) }) });
    const result = await joins(h);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failure.kind).toBe("unverified");
    expect(h.trust.value).toBeNull();
  });

  // §12.3: "an unsuccessful durable write grants no authority."
  test("a failed write is a failed enrollment", async () => {
    const h = signingIn();
    h.trust.failWrites = true;
    const result = await joins(h);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failure.kind).toBe("storage");
    expect((await h.identity.status()).kind).toBe("unenrolled");
  });

  test("a dismissed passkey prompt is a ceremony failure, and writes nothing", async () => {
    const h = signingIn({
      issue: async () => ({ ok: false, failure: { kind: "ceremony", failure: "dismissed" } }),
    });
    const result = await joins(h);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.failure.kind).toBe("ceremony");
      expect((result.failure as { failure: string }).failure).toBe("dismissed");
    }
    expect(h.trust.value).toBeNull();
  });
});

describe("what is stored", () => {
  test("the committed record names the root and carries this device's chain", async () => {
    const h = signingIn();
    await joins(h);
    const record = decodeTrustRecord(h.trust.value!)!;
    expect(record).not.toBeNull();
    expect([...hashRoot(record.root!)]).toEqual([...hex(fx.root_id)]);
    expect([...record.bundle!]).toEqual([...hex(H.bundle)]);
  });

  // §10.1's "explicit local reset/re-registration": a reset is a change of IDENTITY, not of device.
  test("resetting trust keeps the keys", async () => {
    const h = signingIn();
    await joins(h);
    const keysBefore = h.installations.value!;
    expect(await h.identity.resetTrust()).toBe(true);
    expect((await h.identity.status()).kind).toBe("unenrolled");
    expect([...h.installations.value!]).toEqual([...keysBefore]);
  });
});

beforeEach(() => { /* each harness builds its own storage */ });

describe("adopting from the shell (§10.3, root → A → B)", () => {
  // The native app's client window cannot enrol itself: `app://client/` is an origin no passkey
  // ceremony can run in (§2, profile P-A). It generates keys like any device and asks the app to
  // certify them. C's chain is device-issued by H with capability 3, which is exactly the shape a
  // subordinate's is — and the harness is already seeded to BE C.
  const shellReturns = (answer: string) => {
    const calls: string[] = [];
    return { calls, issue: async (keys: string) => { calls.push(keys); return answer; } };
  };
  const b64u = (bytes: Uint8Array): string =>
    btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  test("a certified renderer ends up ready, with the root and the chain stored", async () => {
    const h = harness();
    const shell = shellReturns(b64u(hex(C.bundle)));
    const result = await h.identity.adoptFromShell(shell.issue);
    expect(result.ok).toBe(true);
    expect((await h.identity.status()).kind).toBe("ready");
    const record = decodeTrustRecord(h.trust.value!)!;
    expect([...hashRoot(record.root!)]).toEqual([...hex(fx.root_id)]);
    expect([...record.bundle!]).toEqual([...hex(C.bundle)]);
  });

  test("what crosses is the two PUBLIC keys, and nothing else", async () => {
    const h = harness();
    const shell = shellReturns(b64u(hex(C.bundle)));
    await h.identity.adoptFromShell(shell.issue);
    expect(shell.calls).toHaveLength(1);
    const sent = Uint8Array.from(atob(shell.calls[0]!.replace(/-/g, "+").replace(/_/g, "/")),
                                 (c) => c.charCodeAt(0));
    expect(sent).toHaveLength(64);
    // The leaf of the chain it gets back must carry exactly these, which is the renderer's own
    // check — so the bytes it sends and the bytes it verifies are the same two keys.
    const descriptor = descriptorFor(deviceKeys(hex(C.signing_private_key),
                                                hex(C.noise_private_key))!, hex(fx.root_id))!;
    expect([...descriptor.slice(-64)]).toEqual([...sent]);
    // And no private key is anywhere in what crossed.
    expect(shell.calls[0]).not.toContain(b64u(hex(C.signing_private_key)));
  });

  test("a renderer that is already ready asks the shell for nothing", async () => {
    const h = harness();
    await h.identity.adoptFromShell(shellReturns(b64u(hex(C.bundle))).issue);
    const again = shellReturns(b64u(hex(C.bundle)));
    expect((await h.identity.adoptFromShell(again.issue)).ok).toBe(true);
    expect(again.calls).toHaveLength(0);
  });

  // A REFUSAL IS AN ANSWER. "This Mac is not enrolled" is a state a person can fix by enrolling;
  // a broken bridge is not. They must not read the same.
  test("a shell refusal is reported with its reason", async () => {
    const h = harness();
    const result = await h.identity.adoptFromShell(shellReturns("-not-enrolled").issue);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failure).toEqual({ kind: "shell", reason: "-not-enrolled" });
    expect(h.trust.value).toBeNull();
  });

  test("an answer that is not base64url is malformed, not a refusal", async () => {
    const result = await harness().identity.adoptFromShell(shellReturns("not base64!").issue);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failure.kind).toBe("malformed");
  });

  test("a chain certifying ANOTHER device is refused", async () => {
    // X's chain verifies perfectly. It is simply not this renderer's, and a grant for someone else
    // is not something to store.
    const h = harness();
    const result = await h.identity.adoptFromShell(shellReturns(b64u(hex(fx.devices.X!.bundle))).issue);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.failure.kind).toBe("unverified");
      expect((result.failure as { failure: string }).failure).toBe("chain/device-mismatch");
    }
    expect(h.trust.value).toBeNull();
  });

  test("a chain that would grant ENROLL is refused even though it verifies", async () => {
    // Seeded as H, handed H's OWN root-issued chain: it verifies, its leaf IS this device, and it
    // carries capability 7. A renderer is a client — §10.3's `1` exists so that is expressible —
    // and a window that could enrol other devices is authority nobody asked for.
    const H = fx.devices.H!;
    const installations = new Memory(encodeInstallation({
      keys: deviceKeys(hex(H.signing_private_key), hex(H.noise_private_key))!,
      rendezvousSeed: new Uint8Array(32).fill(0xE0),
    }));
    const trust = new Memory();
    const identity = new ClientE2EIdentity(installations, trust,
                                           { rpId: fx.rp_id, rpName: "Xpromptvs" }, ORIGIN);
    const result = await identity.adoptFromShell(shellReturns(b64u(hex(H.bundle))).issue);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.failure.kind).toBe("unverified");
      expect((result.failure as { failure: string }).failure).toBe("grant/capabilities");
    }
    expect(trust.value).toBeNull();
  });

  // §12.3: "an unsuccessful durable write grants no authority."
  test("a failed write leaves the renderer unenrolled", async () => {
    const trust = new Memory();
    trust.failWrites = true;
    const h = harness({ trust });
    const result = await h.identity.adoptFromShell(shellReturns(b64u(hex(C.bundle))).issue);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failure.kind).toBe("storage");
    expect((await h.identity.status()).kind).toBe("unenrolled");
  });
});

describe("the session configuration", () => {
  // Null exactly when the browser is not ready: a gate built from placeholders would fail at the
  // PEER's chain check, which is the wrong place to discover that this device has no identity.
  test("there is none before enrollment", async () => {
    expect(await harness().identity.gateConfig("room-1")).toBeNull();
  });

  test("it carries this device's own descriptor, keys and chain", async () => {
    const h = signingIn();
    await joins(h);
    const config = (await h.identity.gateConfig("room-1"))!;
    expect(config).not.toBeNull();
    expect(config.roomCode).toBe("room-1");
    expect([...config.device]).toEqual([...hex(H.descriptor)]);
    expect([...config.bundle]).toEqual([...hex(H.bundle)]);
    expect([...config.noisePrivateKey]).toEqual([...hex(H.noise_private_key)]);
    expect([...config.trustedRootId!]).toEqual([...hex(fx.root_id)]);
    expect(config.policy.allowedOrigins).toEqual([ORIGIN]);
    expect(config.expectedResponderDeviceId).toBeUndefined();
  });

  // §11.1: "A selected Host's `device_id` must also match the selection." A caller that picked a
  // Mac passes it; one that did not must not have a selection invented for it.
  test("a selection is carried only when there is one", async () => {
    const h = signingIn();
    await joins(h);
    const picked = hashDevice(hex(fx.devices.H!.descriptor));
    const config = (await h.identity.gateConfig("room-1", picked))!;
    expect([...config.expectedResponderDeviceId!]).toEqual([...picked]);
  });
});

test("the descriptor the status reports is the one the grant certified", async () => {
  const h = signingIn();
  await joins(h);
  const expected = descriptorFor(
    deviceKeys(hex(H.signing_private_key), hex(H.noise_private_key))!, hex(fx.root_id))!;
  const status = await h.identity.status();
  if (status.kind !== "ready") throw new Error("expected ready");
  expect([...status.deviceId]).toEqual([...hashDevice(expected)]);
});

// §10.1's usernameless discovery, now ONE ceremony: a browser that holds nothing, asked its
// authenticator which roots it has — with §10.4's grant commitment as the challenge, so the same
// assertion identifies the credential AND signs the grant. What is faked is the ceremony and the
// Control Plane's answer; the verification between them is the real one, which is the only part
// that makes the answer safe to use.
describe("signing in with a passkey", () => {
  const found = async (): Promise<CredentialLookup> => ({ kind: "found", root: hex(fx.root) });

  // **THE WHOLE POINT OF THE CHANGE.** Two prompts became one because the bytes the grant assertion
  // signs no longer name a root, so they can be assembled before the ceremony that finds it.
  test("ONE ceremony, and it both finds the identity and signs the grant", async () => {
    let ceremonies = 0;
    const h = signingIn({
      discoverRoot: async (_config, preimage) => {
        ceremonies += 1;
        // The challenge is the caller's commitment, not a pre-image this ceremony invented.
        expect([...preimage]).toEqual([...DISCOVERY.preimage]);
        return { ok: true, value: { ...DISCOVERY, blob: null } };
      },
      rootCheck: async () => { ceremonies += 1; return { ok: false, failure: "unsupported" }; },
      createRoot: async () => { ceremonies += 1; return { ok: false, failure: "unsupported" }; },
    });
    const r = await h.identity.signIn(found);
    expect(r.ok, JSON.stringify(r)).toBe(true);
    expect(ceremonies).toBe(1);
  });

  test("it commits, under exactly the root the credential pins", async () => {
    const h = signingIn();
    const r = await h.identity.signIn(found);
    expect(r.ok).toBe(true);
    expect(h.trust.value).not.toBeNull();
    const record = decodeTrustRecord(h.trust.value!)!;
    expect([...record.root!]).toEqual([...hex(fx.root)]);
    // And it is the fixture's root id, which is what a person is then shown.
    if (r.ok && r.status.kind === "ready") {
      expect([...r.status.rootId]).toEqual([...hex(fx.root_id)]);
    }
  });

  // **The check that has no counterpart in `verifyBundle`.** Every other field of the descriptor is
  // pinned by the assertion; the relying party is pinned only against local policy. A Worker that
  // returns the real credential and the real key under a different rp_id would otherwise hand this
  // browser a root id no Mac in the identity shares.
  test("refuses a descriptor carrying someone else's relying party", async () => {
    const h = signingIn();
    const real = parseRoot(hex(fx.root))!;
    const substituted = rootDescriptor("evil.example", real.credentialId, real.publicKey)!;
    const r = await h.identity.signIn(async () => ({ kind: "found", root: substituted }));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.failure).toEqual({ kind: "unverified", failure: "root-rpid" });
    expect(h.trust.value, "a refused descriptor commits nothing").toBeNull();
  });

  test("refuses a substituted public key", async () => {
    const h = signingIn();
    const real = parseRoot(hex(fx.root))!;
    const key = new Uint8Array(real.publicKey);
    key[1] = key[1]! ^ 0x01;
    const r = await h.identity.signIn(async () =>
      ({ kind: "found", root: rootDescriptor(fx.rp_id, real.credentialId, key)! }));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.failure).toEqual({ kind: "unverified", failure: "signature" });
    expect(h.trust.value).toBeNull();
  });

  // A Worker holding no mapping is an ordinary outcome — the identity may simply never have been
  // registered — and it is not evidence about the identity. §12.2: absence is not revocation.
  test("a Worker that knows nothing is not-found, not an error about the passkey", async () => {
    const h = signingIn();
    const r = await h.identity.signIn(async () => ({ kind: "unknown" }));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.failure).toEqual({ kind: "not-found" });
  });

  test("a dismissed prompt asks the Control Plane nothing at all", async () => {
    let asked = 0;
    const h = signingIn({ discoverRoot: async () => ({ ok: false, failure: "dismissed" }) });
    const r = await h.identity.signIn(async () => {
      asked++; return { kind: "found", root: hex(fx.root) };
    });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.failure).toEqual({ kind: "ceremony", failure: "dismissed" });
    // A credential id is the one thing the ceremony would have produced; a lookup without one would
    // be a request this browser had no business making.
    expect(asked).toBe(0);
  });

  // **Merging two calls put four failures behind one, and only ONE may raise deletion.**
  // `signalUnknownCredential` removes an Apple passkey permanently in 250 ms with no platform
  // prompt, so the panel's confirmation is the entire safety net and this flag is what shows it.
  test("deletion is offered only for a definite absence", async () => {
    const dismissed = await signingIn({
      discoverRoot: async () => ({ ok: false, failure: "dismissed" }),
    }).identity.signIn(async () => ({ kind: "absent" }));
    expect(dismissed.stranded, "a dismissal proves nothing about any credential").toBe(false);

    const absent = await signingIn().identity.signIn(async () => ({ kind: "absent" }));
    expect(absent.stranded, "the Worker looked and holds nothing").toBe(true);
    expect(absent.credentialId).toBeDefined();

    const silent = await signingIn().identity.signIn(async () => ({ kind: "unknown" }));
    expect(silent.stranded, "a Worker that never answered has told us nothing").toBe(false);

    const real = parseRoot(hex(fx.root))!;
    const wrongRp = rootDescriptor("evil.example", real.credentialId, real.publicKey)!;
    const unverified = await signingIn().identity.signIn(async () =>
      ({ kind: "found", root: wrongRp }));
    expect(unverified.stranded,
           "a descriptor that came back and failed discredits the ANSWER, not the credential")
      .toBe(false);
  });
});

// **Signing out: forgetting this browser's identity.** The analogue of the account Log out this
// replaced, and it means something different — which is exactly why the scope is asserted here.
describe("forgetting", () => {
  const enrolled = async () => {
    const h = signingIn();
    const result = await joins(h);
    expect(result.ok).toBe(true);
    return h;
  };

  // **BOTH RECORDS, and the keys are the reason.** Deleting only the trust record would leave a
  // browser whose Noise static and signing key were certified under the old root and are about to
  // be certified under a new one — the same public key in two identities, which is a stable
  // correlator any Host on either side can see.
  test("it deletes the KEYS as well as the trust record", async () => {
    const h = await enrolled();
    expect(h.installations.value).not.toBeNull();
    expect(h.trust.value).not.toBeNull();

    expect(await h.identity.forget()).toEqual({ ok: true });
    expect(h.installations.value).toBeNull();
    expect(h.trust.value).toBeNull();
  });

  test("and the browser comes back as one that has never enrolled", async () => {
    const h = await enrolled();
    const before = await h.identity.status();
    expect(before.kind).toBe("ready");

    await h.identity.forget();
    const after = await h.identity.status();
    expect(after.kind).toBe("unenrolled");
  });

  // A fresh installation is a DIFFERENT device, which is the property that makes signing out mean
  // something: the keys the old grant certified are gone, so the grant is unusable by this browser.
  test("the keys it comes back with are not the ones it had", async () => {
    const h = await enrolled();
    const old = h.installations.value!.slice();
    await h.identity.forget();
    await h.identity.load();          // creates a new installation
    expect([...h.installations.value!]).not.toEqual([...old]);
  });

  // **KEYS FIRST.** If the second delete fails, what is left is a trust record with no keys —
  // §12.4's `keys-lost`, which answers "generate new keys and enrol again" — rather than a usable
  // identity a failed sign-out left behind.
  test("a failed trust delete still leaves the keys gone", async () => {
    const h = await enrolled();
    h.trust.failDeletes = true;
    expect(await h.identity.forget()).toEqual({ ok: false, failure: "storage" });
    expect(h.installations.value).toBeNull();
  });
});

// **STORAGE THAT THROWS IS A STATE, NOT A REJECTION.** `IndexedDBInstallationBackend.read`
// re-throws on purpose — a failure must never look like "nothing stored" — and `load` is what has
// to turn that back into the `blocked` its own type declares. Without it a browser with IndexedDB
// blocked produces an unhandled rejection, and the session simply never starts.
describe("when storage itself is unavailable", () => {
  class Hostile extends Memory {
    override async read (): Promise<Uint8Array | null> { throw new Error("indexedDB is not defined"); }
  }

  test("a throwing installation store is reported, not thrown", async () => {
    const identity = new ClientE2EIdentity(new Hostile(), new Memory(),
                                           { rpId: fx.rp_id, rpName: "Xpromptvs" }, ORIGIN);
    const loaded = await identity.load();
    expect("kind" in loaded && loaded.kind).toBe("blocked");
    expect((await identity.status()).kind).toBe("blocked");
  });

  test("a throwing TRUST store is reported too — it is read separately", async () => {
    const identity = new ClientE2EIdentity(seededInstallation(), new Hostile(),
                                           { rpId: fx.rp_id, rpName: "Xpromptvs" }, ORIGIN);
    expect((await identity.status()).kind).toBe("blocked");
  });
});

// **MAKING A BROWSER-CREATED ROOT DISCOVERABLE.** §12.2's directory indexes `credential_id -> root`
// when a `DirectoryDO` first learns its root, and it learns it from a registration. Only the Mac
// ever registered — so a browser that created an identity was invisible to discovery from any OTHER
// browser, offered its own passkey and told "no identity is registered for that passkey yet".
describe("registering with the directory", () => {
  const enrolled = async () => {
    const h = signingIn();
    expect((await joins(h)).ok)
      .toBe(true);
    return h;
  };

  test("it registers the grant, with the LEAF'S OWN operation id", async () => {
    const h = await enrolled();
    const seen: Array<{ root: Uint8Array; operationId: Uint8Array }> = [];
    const ok = await h.identity.registerWithDirectory("https://cp.test", async (_b, id, op) => {
      seen.push({ root: id.root, operationId: op });
      return true;
    });
    expect(ok).toBe(true);
    expect(seen).toHaveLength(1);
    expect([...seen[0]!.root]).toEqual([...hex(fx.root)]);
    // §12.2 is idempotent on `(root_id, operation_id)`, and the leaf's own id is what makes a
    // retry free rather than a conflict — which is what lets an older browser heal itself.
    const leaf = parseBundle(hex(H.bundle));
    const grant = leaf.ok ? parseGrant(leaf.bundle.certificates.at(-1)!.grant) : null;
    expect([...seen[0]!.operationId]).toEqual([...grant!.operationId]);
  });

  test("a confirmed record costs no traffic at all", async () => {
    const h = await enrolled();
    let calls = 0;
    const register = async () => { calls++; return true; };
    await h.identity.registerWithDirectory("https://cp.test", register);
    await h.identity.registerWithDirectory("https://cp.test", register);
    await h.identity.registerWithDirectory("https://cp.test", register);
    expect(calls).toBe(1);
  });

  // §12.2: publication is best-effort and never a precondition. A Worker that refuses costs
  // discovery from a second browser and costs THIS one nothing — so the record stays unconfirmed
  // and the next visit tries again.
  test("a refusal is not remembered as success", async () => {
    const h = await enrolled();
    expect(await h.identity.registerWithDirectory("https://cp.test", async () => false))
      .toBe(false);
    let retried = 0;
    await h.identity.registerWithDirectory("https://cp.test", async () => { retried++; return true; });
    expect(retried).toBe(1);
  });

  test("a browser with no identity registers nothing", async () => {
    const h = harness();
    let calls = 0;
    expect(await h.identity.registerWithDirectory("https://cp.test",
                                                  async () => { calls++; return true; })).toBe(false);
    expect(calls).toBe(0);
  });
});

describe("retaining a created root", () => {
  // §10.1 route 1's "retain the registration public key and credential ID". WebAuthn hands the key
  // back ONLY at creation, so a descriptor dropped here is unrecoverable by anyone — which is what
  // turned an abandoned enrollment into a passkey the person had to delete by hand.
  test("a created root is retained BEFORE the grant ceremony runs", async () => {
    const pending = new Memory();
    let retainedWhenIssued: Uint8Array | null = null;
    const h = harness({
      pending,
      issue: async () => {
        retainedWhenIssued = pending.value;
        return { ok: true, bundle: hex(C.bundle) };
      },
    });
    await h.identity.enroll({ route: "create" });
    expect(retainedWhenIssued).not.toBeNull();
    expect([...(retainedWhenIssued as unknown as Uint8Array)]).toEqual([...hex(fx.root)]);
  });

  test("a joined root is NOT retained — nothing was created here", async () => {
    const h = signingIn();
    await joins(h);
    expect(h.pending.value).toBeNull();
  });

  // The trust record supersedes it. Unconditionally: a browser that abandoned root A and later
  // adopted root B must not keep a resume route into A (§10.1 forbids replacing an adopted root).
  test("commit clears the retained entry", async () => {
    const h = harness();
    const result = await h.identity.enroll({ route: "create" });
    expect(result.ok).toBe(true);
    expect(h.pending.value).toBeNull();
  });

  // Not about secrecy — it is a public key, an rp_id and a credential id. Resume has NO
  // confirmation, so a stale entry surviving a sign-out is a one-tap silent re-adoption of the
  // identity just left.
  test("forget clears it too", async () => {
    const h = harness({ pending: new Memory(hex(fx.root)) });
    await h.identity.forget();
    expect(h.pending.value).toBeNull();
  });

  // Retention grants no authority, so §12.3's "an unsuccessful durable write grants no authority"
  // does not reach it. It costs recoverability and nothing else.
  test("a failed retention write does not fail the ceremony", async () => {
    const pending = new Memory();
    pending.failWrites = true;
    const h = harness({ pending });
    const result = await h.identity.enroll({ route: "create" });
    expect(result.ok).toBe(true);
  });
});

describe("which route asked, and who gets asked back", () => {
  // §10.1's confirmation obligation is the *Residual* indented under route 2 — "a user holding
  // several credentials for this RP can be steered BY THE DIRECTORY to one they do hold but did not
  // intend to use here". On the create route there is no directory and no choice: the credential
  // did not exist a second ago. The route carries this STRUCTURALLY — `{ route: "create" }` has
  // nowhere to put a confirmation — so it cannot regress by someone passing the wrong flag.
  test("CREATING NEVER ASKS — there is no directory and no choice", async () => {
    const h = harness();
    const result = await h.identity.enroll({ route: "create" });
    expect(result.ok).toBe(true);
    expect(h.trust.value).not.toBeNull();
    expect(h.issued).toHaveLength(1);
  });

  // §10.1: "An incoming chain is never allowed to replace an already trusted root."
  test("a browser that already holds a root creates nothing, whatever the route says", async () => {
    const h = harness();
    await h.identity.enroll({ route: "create" });
    const before = h.created;
    const again = await h.identity.enroll({ route: "create" });
    expect(again.ok).toBe(true);
    expect(h.created).toBe(before);
  });
});

describe("resuming an abandoned creation", () => {
  // **The whole point.** A passkey created but never committed is otherwise unrecoverable, because
  // WebAuthn returns the public key ONLY at creation — so the alternative is deleting it by hand in
  // System Settings and making another.
  // **THE CEREMONIES ARE COUNTED, not inferred.** This assertion used to say "ONE ceremony" in its
  // name while checking only that no credential was CREATED — which the two-ceremony version passed
  // perfectly well, because its extra prompt was a `rootCheck`, not a creation. Resume now proves
  // the retained descriptor with the grant's own assertion: `verifyBundle` pins the credential id,
  // the public key and the root id, which is exactly what the separate check established.
  test("a retained root is resumed with ONE ceremony and no confirmation", async () => {
    let checks = 0;
    const h = harness({
      pending: new Memory(hex(fx.root)),
      rootCheck: async () => { checks += 1; return { ok: false, failure: "unsupported" }; },
    });
    const result = await h.identity.enroll({ route: "resume" });
    expect(result.ok, JSON.stringify(result)).toBe(true);
    expect(checks, "the separate root check is gone; the grant assertion proves it").toBe(0);
    // It went nowhere near the authenticator for a NEW credential either.
    expect(h.created).toBe(0);
    expect(h.issued).toHaveLength(1);
    expect([...h.issued[0]!.root]).toEqual([...hex(fx.root)]);
    // And the retained entry is gone, superseded by the trust record.
    expect(h.pending.value).toBeNull();
  });

  test("with nothing retained, resume refuses rather than creating", async () => {
    const h = harness();
    const result = await h.identity.enroll({ route: "resume" });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failure.kind).toBe("no-pending");
    expect(h.created).toBe(0);
  });

  // **A CANCELLED PROMPT MUST NOT DESTROY THE RETENTION.** WebAuthn reports "you cancelled" and
  // "this authenticator holds no such credential" as ONE `NotAllowedError`, on purpose, so that a
  // page cannot learn whether a credential exists. Clearing here would throw the descriptor away
  // every time somebody pressed Escape — and it is unrebuildable.
  // **"YOU CANCELLED" AND "NO SUCH CREDENTIAL" ARE ONE `NotAllowedError`**, by design, so a ceremony
  // failure may never discard the retention — the descriptor cannot be rebuilt by anyone, and the
  // passkey would become one the person has to delete by hand. Resume runs ONE ceremony now, the
  // grant's own, so this is a dismissal of that.
  test("a dismissed grant ceremony KEEPS the retained entry", async () => {
    const h = harness({
      pending: new Memory(hex(fx.root)),
      issue: async () => ({ ok: false, failure: { kind: "ceremony", failure: "dismissed" } }),
    });
    const result = await h.identity.enroll({ route: "resume" });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failure.kind).toBe("ceremony");
    expect(h.pending.value).not.toBeNull();
  });

  // A descriptor the assertion contradicts is broken and unusable, and unlike a cancelled prompt
  // that IS grounds to discard it. With one ceremony the verdict comes from `verifyBundle` inside
  // the grant — which pins the credential id, the public key and the root id just as the separate
  // check used to.
  test("a retained entry the grant cannot verify against is discarded", async () => {
    const other = rootDescriptor(fx.rp_id, new Uint8Array(20).fill(9), new Uint8Array(65).fill(4))!;
    const h = harness({
      pending: new Memory(other),
      issue: async () => ({ ok: false, failure: { kind: "unverified", failure: "root-mismatch" } }),
    });
    const result = await h.identity.enroll({ route: "resume" });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failure.kind).toBe("unverified");
    expect(h.pending.value).toBeNull();
  });
});

describe("discovery reads the authenticator before the Worker", () => {
  // §4: a second SOURCE, not a second trust path — it goes through the same `verifyDiscoveredRoot`
  // and the same three pins. What it buys is that the Worker need not answer, or even exist.
  test("a blob-carried descriptor is used, and the Worker is never asked", async () => {
    let asked = 0;
    const h = signingIn({
      discoverRoot: async () => ({ ok: true, value: { ...DISCOVERY, blob: hex(fx.root) } }),
    });
    const found = await h.identity.signIn(async () => { asked++; return { kind: "unknown" }; });
    expect(found.ok, JSON.stringify(found)).toBe(true);
    expect([...decodeTrustRecord(h.trust.value!)!.root!]).toEqual([...hex(fx.root)]);
    expect(asked).toBe(0);
  });

  test("no blob falls back to the Worker", async () => {
    let asked = 0;
    const h = signingIn({
      discoverRoot: async () => ({ ok: true, value: { ...DISCOVERY, blob: null } }),
    });
    const found = await h.identity.signIn(async () => {
      asked++; return { kind: "found", root: hex(fx.root) };
    });
    expect(found.ok).toBe(true);
    expect(asked).toBe(1);
  });

  // **A BLOB EARNS NO SHORTCUT AND NO LAST WORD.** It is bytes anyone holding the credential could
  // have written, so garbage there must not deny service — the Worker still gets its turn.
  test("a blob that does not parse falls back rather than failing", async () => {
    let asked = 0;
    const h = signingIn({
      discoverRoot: async () => ({
        ok: true, value: { ...DISCOVERY, blob: new Uint8Array([1, 2, 3]) },
      }),
    });
    const found = await h.identity.signIn(async () => {
      asked++; return { kind: "found", root: hex(fx.root) };
    });
    expect(found.ok).toBe(true);
    expect(asked).toBe(1);
  });

  // A blob that PARSES but names another identity is the interesting one: it survives the cheap
  // check and has to be caught by the same verification a Worker answer is.
  test("a well-formed blob for a different credential falls back too", async () => {
    let asked = 0;
    const other = rootDescriptor(fx.rp_id, new Uint8Array(20).fill(9), new Uint8Array(65).fill(4))!;
    const h = signingIn({
      discoverRoot: async () => ({ ok: true, value: { ...DISCOVERY, blob: other } }),
    });
    const found = await h.identity.signIn(async () => {
      asked++; return { kind: "found", root: hex(fx.root) };
    });
    expect(found.ok, JSON.stringify(found)).toBe(true);
    expect([...decodeTrustRecord(h.trust.value!)!.root!]).toEqual([...hex(fx.root)]);
    expect(asked).toBe(1);
  });
});

describe("discarding a passkey nothing is holding", () => {
  // **THE ONLY PLACE CERTAINTY EXISTS.** This browser created the credential, no grant was ever
  // issued (one would have committed), and the Worker was never told (registration is
  // post-commit) — so nothing anywhere can be holding it. A 404 from the credential index would
  // NOT do: that index is best-effort, so a root in daily use on a Mac produces the same answer.
  test("signals the retained credential, under this deployment's relying party", async () => {
    const calls: Array<{ rpId: string; credentialId: Uint8Array }> = [];
    const h = harness({
      pending: new Memory(hex(fx.root)),
      signalUnknown: async (rpId, credentialId) => { calls.push({ rpId, credentialId }); return "signalled"; },
    });
    const result = await h.identity.discardPendingRoot();
    expect(result.ok).toBe(true);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.rpId).toBe(fx.rp_id);
    expect([...calls[0]!.credentialId]).toEqual([...parseRoot(hex(fx.root))!.credentialId]);
    expect(h.pending.value).toBeNull();
  });

  // **THE ORDER IS THE SAFETY PROPERTY.** Clearing first and then failing to signal manufactures
  // exactly the unrecoverable orphan this whole feature exists to prevent: a passkey in the
  // keychain with the only record of it gone.
  test("A FAILED SIGNAL CHANGES NOTHING — the descriptor is kept", async () => {
    const h = harness({
      pending: new Memory(hex(fx.root)),
      signalUnknown: async () => "failed/NotAllowedError",
    });
    const result = await h.identity.discardPendingRoot();
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toBe("failed/NotAllowedError");
    expect(h.pending.value).not.toBeNull();
  });

  test("a browser without the API keeps the descriptor and says so", async () => {
    const h = harness({
      pending: new Memory(hex(fx.root)),
      signalUnknown: async () => "unsupported",
    });
    const result = await h.identity.discardPendingRoot();
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toBe("unsupported");
    expect(h.pending.value).not.toBeNull();
  });

  // Nothing retained is nothing to be certain ABOUT, so nothing is signalled. This is the guard
  // that keeps the destructive call away from every credential except the one we made.
  test("with nothing retained it signals nobody", async () => {
    let called = 0;
    const h = harness({ signalUnknown: async () => { called++; return "signalled"; } });
    const result = await h.identity.discardPendingRoot();
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toBe("no-pending");
    expect(called).toBe(0);
  });

  // A committed identity is not a stranded passkey, whatever is left lying in the pending entry.
  test("a browser that already holds an identity signals nobody", async () => {
    let called = 0;
    const h = signingIn({
      pending: new Memory(hex(fx.root)),
      signalUnknown: async () => { called++; return "signalled"; },
    });
    await joins(h);
    h.pending.value = hex(fx.root);        // as a failed clear at commit would leave it
    const result = await h.identity.discardPendingRoot();
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toBe("holds-identity");
    expect(called).toBe(0);
  });
});

describe("a credential the Worker has never heard of", () => {
  const STRANGER = rootDescriptor(fx.rp_id, new Uint8Array(20).fill(3), new Uint8Array(65).fill(4))!;

  // The offer is drawn from a DEFINITE answer, never from silence. A Worker that did not reply has
  // told us nothing, and raising "shall I delete this?" on the strength of a timeout raises it on
  // the strength of the person's Wi-Fi.
  test("a definite ABSENT marks the credential as strandable", async () => {
    const h = harness();
    const found = await h.identity.signIn(async () => ({ kind: "absent" }));
    expect(found.ok).toBe(false);
    if (!found.ok) {
      expect(found.failure.kind).toBe("not-found");
      expect(found.stranded).toBe(true);
      expect([...(found.credentialId ?? [])]).toEqual([...DISCOVERY.credentialId]);
    }
  });

  test("an UNKNOWN answer marks nothing — silence is not an answer", async () => {
    const h = harness();
    const found = await h.identity.signIn(async () => ({ kind: "unknown" }));
    expect(found.ok).toBe(false);
    if (!found.ok) expect(found.stranded).toBe(false);
  });

  // A blob-carried descriptor that fails verification is a Worker-independent reason to distrust
  // what came back. It is not evidence the credential is unused.
  test("a descriptor that came back but would not verify marks nothing", async () => {
    const h = harness({
      discoverRoot: async () => ({ ok: true, value: { ...DISCOVERY, blob: null } }),
    });
    const found = await h.identity.signIn(async () => ({ kind: "found", root: STRANGER }));
    expect(found.ok).toBe(false);
    if (!found.ok) {
      expect(found.failure.kind).toBe("unverified");
      expect(found.stranded).toBe(false);
    }
  });

  test("deleting a stranded credential signals exactly it", async () => {
    const calls: Array<{ rpId: string; credentialId: Uint8Array }> = [];
    const h = harness({
      signalUnknown: async (rpId, credentialId) => { calls.push({ rpId, credentialId }); return "signalled"; },
    });
    const result = await h.identity.discardCredential(DISCOVERY.credentialId);
    expect(result.ok).toBe(true);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.rpId).toBe(fx.rp_id);
    expect([...calls[0]!.credentialId]).toEqual([...DISCOVERY.credentialId]);
  });

  // **THE GUARD THAT MATTERS.** This operation has no retained descriptor behind it, so the one
  // thing it can check is that it is not about to delete the credential its OWN identity rests on.
  test("IT REFUSES TO DELETE THE CREDENTIAL THIS BROWSER'S OWN IDENTITY RESTS ON", async () => {
    let called = 0;
    const h = signingIn({ signalUnknown: async () => { called++; return "signalled"; } });
    await joins(h);
    const mine = parseRoot(hex(fx.root))!.credentialId;
    const result = await h.identity.discardCredential(mine);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toBe("holds-identity");
    expect(called).toBe(0);
  });

  // A different credential is still fair game — holding one identity says nothing about a passkey
  // that is not part of it.
  test("but will still delete a credential that is not its own", async () => {
    let called = 0;
    const h = harness({ signalUnknown: async () => { called++; return "signalled"; } });
    await joins(h);
    const result = await h.identity.discardCredential(new Uint8Array(20).fill(0xAB));
    expect(result.ok).toBe(true);
    expect(called).toBe(1);
  });
});

describe("first creation and shell adoption are SINGLE-FLIGHT", () => {
  // The web twin of 8a7f7fb1 (the Swift `InstallationStore.loadOrCreate` race). A fresh app window
  // calls `load()` from five places at mount — `liveDevices`, the directory watch, the header, the
  // Settings panel and the on-open adoption — each through its OWN `ClientE2EIdentity` and its own
  // backend object over ONE store. `loadOrCreateInstallation` is read-then-write, so two callers
  // that both read "empty" each generate a key set and the last write wins: if the adoption sent K1
  // to the Mac and K2 landed after, the trust record certifies keys the store no longer holds, the
  // status reads `ready` forever, and every signed request and connect fails.

  /// Every read and write yields to the event loop first, the way IndexedDB does — which is what
  /// lets two read-then-writes interleave.
  class Slow extends Memory {
    override async read (): Promise<Uint8Array | null> {
      await new Promise((r) => setTimeout(r, 1));
      return this.value;
    }
    override async write (bytes: Uint8Array): Promise<boolean> {
      await new Promise((r) => setTimeout(r, 1));
      return super.write(bytes);
    }
  }
  const config = { rpId: fx.rp_id, rpName: "Xpromptvs" };
  const pub = (loaded: Awaited<ReturnType<ClientE2EIdentity["load"]>>): string =>
    "kind" in loaded ? "blocked" : [...loaded.installation.keys.signingPrivateKey].join(",");

  test("N concurrent load()s over one empty store make exactly ONE write and ONE key set", async () => {
    const installations = new Slow();
    const trust = new Slow();
    // Separate identity objects, as the page's callers are; the store is what they share.
    const loads = await Promise.all(Array.from({ length: 6 }, () =>
      new ClientE2EIdentity(installations, trust, config, ORIGIN).load()));
    expect(installations.writes).toBe(1);
    const sets = new Set(loads.map(pub));
    expect(sets.size).toBe(1);
    expect(sets.has("blocked")).toBe(false);
  });

  test("concurrent adoptions from the shell ask the Mac ONCE, and certify the stored keys", async () => {
    const installations = new Slow();
    const trust = new Slow();
    const b64 = (bytes: Uint8Array): string =>
      btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const calls: string[] = [];
    // Seeded as C, so C's chain is a valid answer — the question is only how many times it is asked.
    installations.value = seededInstallation().value;
    const issue = async (keys: string): Promise<string> => {
      calls.push(keys);
      await new Promise((r) => setTimeout(r, 5));
      return b64(hex(C.bundle));
    };
    // The on-open adoption and a connect racing it — two identity objects, one device.
    const results = await Promise.all([
      new ClientE2EIdentity(installations, trust, config, ORIGIN).adoptFromShell(issue),
      new ClientE2EIdentity(installations, trust, config, ORIGIN).adoptFromShell(issue),
      new ClientE2EIdentity(installations, trust, config, ORIGIN).adoptFromShell(issue),
    ]);
    expect(results.every((r) => r.ok)).toBe(true);
    expect(calls).toHaveLength(1);
    expect(trust.writes).toBe(1);
  });

  test("a FRESH store: the keys the Mac certified are the keys the store holds", async () => {
    // The actual hazard end to end: creation and adoption racing on an EMPTY store. Whatever key set
    // wins, the one sent to `issue` must be the one stored. The shell echoes back a marker for what
    // it was sent, and the check is against the store afterwards.
    const installations = new Slow();
    const trust = new Slow();
    const sent: string[] = [];
    const issue = async (keys: string): Promise<string> => { sent.push(keys); return "-not-enrolled"; };
    await Promise.all([
      new ClientE2EIdentity(installations, trust, config, ORIGIN).load(),
      new ClientE2EIdentity(installations, trust, config, ORIGIN).adoptFromShell(issue),
      new ClientE2EIdentity(installations, trust, config, ORIGIN).load(),
    ]);
    expect(installations.writes).toBe(1);
    const stored = await new ClientE2EIdentity(installations, trust, config, ORIGIN).load();
    if ("kind" in stored) throw new Error("blocked");
    const material = new Uint8Array(64);
    material.set(signingPublicKey(stored.installation.keys), 0);
    material.set(noisePublicKey(stored.installation.keys), 32);
    expect(sent).toHaveLength(1);
    const b64 = btoa(String.fromCharCode(...material)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    expect(sent[0]).toBe(b64);
  });
});
