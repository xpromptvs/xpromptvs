import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  CAP_ENROLL, E2E_IDENTITY_ID_LENGTH, IssuerKind, authorityIsWellFormed, capabilitiesAreAccepted,
  device, deviceId, encodeBinding, grant, grantCommitment, grantCommitmentPreimage, grantId,
  parseGrant, revocation, root, rootId, validateChainStructure,
  type Binding, type ChainFailure,
} from "../src/e2e-identity";
import { sha256 } from "@noble/hashes/sha2.js";

// The §10 identity encodings, against vectors a THIRD implementation produced
// (`scripts/gen_e2e_identity_fixture.py`) and which `E2EIdentityTests.swift` asserts too.
//
// These bytes are what signatures cover, so a layout disagreement is not a parse error — it is a
// signature that verifies against the wrong statement.
interface Case {
  name: string; kind: string; encoded: string; id?: string;
  rp_id?: string; credential_id?: string; root_public_key?: string;
  root_id?: string; signing_public_key?: string; noise_public_key?: string;
  operation_id?: string; issuer_kind?: number; issuer_id?: string;
  device?: string; capabilities?: number; binding?: string; target_device_id?: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-identity.json", import.meta.url)), "utf8")) as { cases: Case[] };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");

const bindingFrom = (encoded: Uint8Array): Binding => {
  if (encoded[0] === 0) return { kind: "local", randomness: encoded.slice(1) };
  return { kind: "remote", handshakeHash: encoded.slice(1, 33), responderDeviceId: encoded.slice(33) };
};

describe("cross-implementation vectors", () => {
  const kinds = new Set<string>();
  for (const c of fx.cases) {
    test(c.name, () => {
      kinds.add(c.kind);
      switch (c.kind) {
        case "root": {
          const out = root(c.rp_id!, hex(c.credential_id!), hex(c.root_public_key!))!;
          expect(toHex(out)).toBe(c.encoded);
          expect(toHex(rootId(out))).toBe(c.id);
          break;
        }
        case "device": {
          const out = device(hex(c.root_id!), hex(c.signing_public_key!), hex(c.noise_public_key!))!;
          expect(toHex(out)).toBe(c.encoded);
          expect(toHex(deviceId(out))).toBe(c.id);
          break;
        }
        case "grant": {
          const out = grant({
            rootId: hex(c.root_id!), operationId: hex(c.operation_id!),
            issuerKind: c.issuer_kind as IssuerKind, issuerId: hex(c.issuer_id!),
            device: hex(c.device!), capabilities: c.capabilities!,
            binding: bindingFrom(hex(c.binding!)),
          })!;
          expect(toHex(out)).toBe(c.encoded);
          expect(toHex(grantId(out))).toBe(c.id);
          break;
        }
        case "grant-commitment": {
          // §10.4's commitment. No `id` field and no root fields: these bytes deliberately name no
          // root, which is the whole reason one ceremony can both identify the credential and sign.
          const out = grantCommitmentPreimage({
            operationId: hex(c.operation_id!), issuerKind: c.issuer_kind as IssuerKind,
            signingPublicKey: hex(c.signing_public_key!),
            noisePublicKey: hex(c.noise_public_key!),
            capabilities: c.capabilities!, binding: bindingFrom(hex(c.binding!)),
          })!;
          expect(toHex(out)).toBe(c.encoded);
          break;
        }
        case "revocation":
          expect(toHex(revocation(hex(c.root_id!), hex(c.operation_id!), hex(c.target_device_id!))!))
            .toBe(c.encoded);
          break;
        default:
          throw new Error(`unknown fixture kind ${c.kind} — a new kind must be asserted, not skipped`);
      }
    });
  }
  test("every kind appears", () => {
    expect([...kinds].sort())
      .toEqual(["device", "grant", "grant-commitment", "revocation", "root"]);
  });
});

// §10.3: "Accept exactly {1, 3, 7}". The rejected values are all EXPRESSIBLE in the mask, which is
// why an explicit set is needed rather than a bit test: `5` and `6` are `connect|enroll` and
// `host|enroll`, and neither is a role.
//
// **`2` JOINED THE SET ON 2026-09-15**, when adopt-by-code gave it a holder — a Mac enrolled by
// scanning its own code, which shares a screen and may do nothing else. It was refused until then
// for a stated reason, "a device that may share a screen it can never reach", which is a semantic
// judgement rather than a security invariant and is the exact property that Mac wants.
test("only four capability values exist", () => {
  for (let raw = 0; raw <= 9; raw++) {
    expect(capabilitiesAreAccepted(raw), `${raw}`)
      .toBe(raw === 1 || raw === 2 || raw === 3 || raw === 7);
  }
});

describe("capability 2 — host, and nothing else", () => {
  const id = new Uint8Array(E2E_IDENTITY_ID_LENGTH).fill(1);
  const dev = device(id, id, id)!;
  const binding: Binding = { kind: "local", randomness: new Uint8Array(32).fill(2) };

  test("encodes and parses, root-issued", () => {
    const bytes = grant({ rootId: id, operationId: id, issuerKind: IssuerKind.Root, issuerId: id,
                          device: dev, capabilities: 2, binding });
    expect(bytes).not.toBeNull();
    expect(parseGrant(bytes!)?.capabilities).toBe(2);
  });

  // Only `enroll` is restricted by issuer kind (§10.3), so a device may issue `host` as it may
  // issue `connect`. Nothing about who may enroll changed when 2 became a role.
  test("a device may issue it too", () => {
    expect(grant({ rootId: id, operationId: id, issuerKind: IssuerKind.Device, issuerId: id,
                   device: dev, capabilities: 2, binding })).not.toBeNull();
  });

  test("carries host and neither connect nor enroll", () => {
    const parsed = parseGrant(grant({ rootId: id, operationId: id, issuerKind: IssuerKind.Root,
                                      issuerId: id, device: dev, capabilities: 2, binding })!)!;
    expect(parsed.capabilities & 2).toBe(2);
    expect(parsed.capabilities & 1).toBe(0);
    expect(parsed.capabilities & CAP_ENROLL).toBe(0);
  });

  // The set stayed CLOSED. `6` is `host|enroll` and is the one a widened bit test would let through.
  test("6 is still not a role", () => {
    expect(capabilitiesAreAccepted(6)).toBe(false);
    expect(grant({ rootId: id, operationId: id, issuerKind: IssuerKind.Root, issuerId: id,
                   device: dev, capabilities: 6, binding })).toBeNull();
  });
});

// §10.3: "only root-issued grants may carry enroll". A LEAF CANNOT EXTEND THE CHAIN, which bounds
// chain depth at two without counting anything — and the refusal is at CONSTRUCTION, so such a grant
// is never signed in the first place.
test("only a root may issue enroll", () => {
  const id = new Uint8Array(E2E_IDENTITY_ID_LENGTH).fill(1);
  const dev = device(id, id, id)!;
  const binding: Binding = { kind: "local", randomness: new Uint8Array(32).fill(2) };
  const make = (issuerKind: IssuerKind, capabilities: number) =>
    grant({ rootId: id, operationId: id, issuerKind, issuerId: id, device: dev, capabilities, binding });

  expect(make(IssuerKind.Root, 7), "a root may issue enroll").not.toBeNull();
  expect(make(IssuerKind.Device, 7), "a device may NOT issue enroll").toBeNull();
  expect(make(IssuerKind.Device, 3)).not.toBeNull();
  expect(make(IssuerKind.Device, 1)).not.toBeNull();
  expect(make(IssuerKind.Root, 2), "host-only is a role since 2026-09-15").not.toBeNull();
  expect(make(IssuerKind.Root, 6), "an unaccepted capability value").toBeNull();

  expect(authorityIsWellFormed(IssuerKind.Root, CAP_ENROLL | 3)).toBe(true);
  expect(authorityIsWellFormed(IssuerKind.Device, CAP_ENROLL | 3)).toBe(false);
});

test("wrong widths are refused at construction", () => {
  const ok = new Uint8Array(E2E_IDENTITY_ID_LENGTH);
  const short = new Uint8Array(E2E_IDENTITY_ID_LENGTH - 1);
  expect(root("x", new Uint8Array(0), ok), "a 32-byte root key is not a SEC1 point").toBeNull();
  expect(device(short, ok, ok)).toBeNull();
  expect(revocation(ok, ok, short)).toBeNull();
  expect(encodeBinding({ kind: "local", randomness: short })).toBeNull();
  expect(encodeBinding({ kind: "remote", handshakeHash: ok, responderDeviceId: short })).toBeNull();
});

// A SECOND LABEL over the same bytes is what stops a grant id being confusable with a hash taken for
// any other purpose.
test("the grant id is domain-separated from the grant's hash", () => {
  const id = new Uint8Array(32).fill(3);
  const dev = device(id, id, id)!;
  const g = grant({ rootId: id, operationId: id, issuerKind: IssuerKind.Root, issuerId: id,
                    device: dev, capabilities: 7, binding: { kind: "local", randomness: id } })!;
  expect(toHex(grantId(g))).not.toBe(toHex(sha256(g)));
});

// Every field is bound in: change one and the identity changes. A descriptor that ignored a key
// would let a device swap it silently.
test("every field changes the identity", () => {
  const a = new Uint8Array(32).fill(1);
  const b = new Uint8Array(32).fill(2);
  const base = toHex(deviceId(device(a, a, a)!));
  for (const changed of [device(b, a, a)!, device(a, b, a)!, device(a, a, b)!]) {
    expect(toHex(deviceId(changed))).not.toBe(base);
  }
});

// Grant parsing and the §10.3 chain rules — everything decidable without a signature, and the rules
// a reader can check against the specification line by line.
describe("chain structure", () => {
  const ROOT = new Uint8Array(32).fill(0x71);
  const id = (b: number) => new Uint8Array(32).fill(b);
  const dev = device(ROOT, id(0x10), id(0x11))!;
  const mk = (issuerKind: IssuerKind, issuerId: Uint8Array, capabilities: number,
              rootIdBytes = ROOT) =>
    grant({ rootId: rootIdBytes, operationId: id(0x99), issuerKind, issuerId, device: dev,
            capabilities, binding: { kind: "local", randomness: id(0xc0) } })!;

  const direct = mk(IssuerKind.Root, ROOT, 7);
  const parent = grantId(direct);

  // §7 forbids reserialising to verify, so the parser keeps the ORIGINAL bytes.
  test("parsing round-trips and keeps the exact bytes", () => {
    const g = parseGrant(direct)!;
    expect(g).not.toBeNull();
    expect(toHex(g.bytes)).toBe(toHex(direct));
    expect(g.issuerKind).toBe(IssuerKind.Root);
    expect(g.capabilities).toBe(7);
  });

  test("the parser refuses malformed grants", () => {
    expect(parseGrant(new Uint8Array([...direct, 0])), "extra trailing bytes").toBeNull();
    expect(parseGrant(direct.slice(0, -1)), "truncated").toBeNull();
    expect(parseGrant(new Uint8Array(0)), "empty").toBeNull();

    const badKind = new Uint8Array(direct);
    badKind[2 + "rdev-e2e/grant/v1".length + 64] = 9;
    expect(parseGrant(badKind), "an unknown issuer kind").toBeNull();

    expect(parseGrant(revocation(ROOT, id(1), id(2))!), "a revocation is not a grant").toBeNull();
  });

  test("a direct chain validates, and a two-grant chain returns the LEAF", () => {
    const one = validateChainStructure([direct], ROOT);
    expect(one.ok).toBe(true);
    if (one.ok) expect(one.grant.capabilities).toBe(7);

    const leaf = mk(IssuerKind.Device, parent, 3);
    const two = validateChainStructure([direct, leaf], ROOT);
    expect(two.ok).toBe(true);
    if (two.ok) {
      expect(toHex(two.grant.bytes), "the leaf is what is authorised").toBe(toHex(leaf));
      expect(two.grant.capabilities).toBe(3);
    }
  });

  test("every structural rule is enforced", () => {
    const fail = (chain: Uint8Array[], root = ROOT): ChainFailure | null => {
      const r = validateChainStructure(chain, root);
      return r.ok ? null : r.failure;
    };
    const leaf = mk(IssuerKind.Device, parent, 3);
    expect(fail([])).toBe("empty");
    expect(fail([direct, leaf, direct]), "no chain has more than two grants").toBe("too-long");
    expect(fail([new Uint8Array([0, 1, 2])])).toBe("malformed-grant");
    expect(fail([direct], id(0xee)), "a chain may never replace a trusted root").toBe("root-mismatch");
    expect(fail([mk(IssuerKind.Root, id(0xab), 7)])).toBe("first-not-root-issued");
    expect(fail([direct, mk(IssuerKind.Device, id(0xab), 3)])).toBe("second-not-chained-to-first");
    expect(fail([direct, direct]), "a root-issued grant cannot be a leaf").toBe("second-not-chained-to-first");
  });

  // A leaf carrying `enroll` CANNOT EVEN BE CONSTRUCTED, so the chain rule guarding it is only
  // reachable by hand-assembled bytes — which is exactly the case that matters, since an adversary
  // does not use our constructor.
  test("a forged leaf carrying enroll is refused", () => {
    const forged = new Uint8Array(mk(IssuerKind.Device, parent, 3));
    const capsAt = forged.length - 1 - 2 - 33;
    expect(forged[capsAt], "located the capability byte").toBe(3);
    forged[capsAt] = 7;
    expect(parseGrant(forged), "the parser refuses it outright").toBeNull();
    const r = validateChainStructure([direct, forged], ROOT);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.failure).toBe("malformed-grant");
  });
});

describe("§10.4 grant commitment", () => {
  const id = (v: number): Uint8Array => new Uint8Array(E2E_IDENTITY_ID_LENGTH).fill(v);
  const ROOT_ID = id(0x11), OP = id(0x22), SIGN = id(0x33), NOISE = id(0x44);
  const binding: Binding = { kind: "local", randomness: id(0x55) };
  const DEVICE = device(ROOT_ID, SIGN, NOISE)!;

  const parsedGrant = (over: {
    rootId?: Uint8Array; issuerId?: Uint8Array; device?: Uint8Array;
    issuerKind?: IssuerKind; capabilities?: number; operationId?: Uint8Array;
  } = {}) => parseGrant(grant({
    rootId: over.rootId ?? ROOT_ID,
    operationId: over.operationId ?? OP,
    issuerKind: over.issuerKind ?? IssuerKind.Root,
    issuerId: over.issuerId ?? ROOT_ID,
    device: over.device ?? DEVICE,
    capabilities: over.capabilities ?? 7,
    binding,
  })!)!;

  const signerCommitment = () => grantCommitmentPreimage({
    operationId: OP, issuerKind: IssuerKind.Root,
    signingPublicKey: SIGN, noisePublicKey: NOISE, capabilities: 7, binding,
  });

  const contains = (haystack: Uint8Array, needle: Uint8Array): boolean => {
    outer: for (let i = 0; i + needle.length <= haystack.length; i++) {
      for (let j = 0; j < needle.length; j++) if (haystack[i + j] !== needle[j]) continue outer;
      return true;
    }
    return false;
  };

  // **THE WHOLE POINT.** A browser signing in has not yet learned which credential will answer, so
  // it cannot know `root_id`. A challenge containing one could not exist until a FIRST ceremony had
  // produced it — which is exactly the second prompt this encoding removes.
  test("names no root", () => {
    const commit = signerCommitment()!;
    expect(contains(commit, ROOT_ID)).toBe(false);
  });

  test("the verifier's projection equals the signer's", () => {
    expect(grantCommitment(parsedGrant(), ROOT_ID)).toEqual(signerCommitment());
  });

  // **THE STRUCTURAL GUARANTEE, AND THE ONLY PLACE IT IS OBSERVABLE.** `verifyBundle` rejects all
  // of these earlier, in the chain rules, so no end-to-end fixture ever reaches this mechanism.
  // Without these tests the pin that replaces the signature's own binding is untested.
  test("refuses a grant whose root_id disagrees", () => {
    expect(grantCommitment(parsedGrant(), id(0x99))).toBeNull();
  });

  test("refuses a grant whose issuer_id disagrees", () => {
    expect(grantCommitment(parsedGrant({ issuerId: id(0x99) }), ROOT_ID)).toBeNull();
  });

  test("refuses a grant whose device names another root", () => {
    const other = device(id(0x99), SIGN, NOISE)!;
    expect(grantCommitment(parsedGrant({ device: other }), ROOT_ID)).toBeNull();
  });

  // A device-issued grant is evidenced by a raw Ed25519 signature over the WHOLE grant, never by an
  // assertion, so there is no case in which this should answer for one.
  test("refuses a device-issued grant", () => {
    const parent = grant({
      rootId: ROOT_ID, operationId: OP, issuerKind: IssuerKind.Root, issuerId: ROOT_ID,
      device: DEVICE, capabilities: 7, binding,
    })!;
    const leaf = parsedGrant({
      issuerKind: IssuerKind.Device, issuerId: grantId(parent),
      capabilities: 3, operationId: id(0x66),
    });
    expect(grantCommitment(leaf, ROOT_ID)).toBeNull();
  });

  test("refuses malformed field widths", () => {
    expect(grantCommitmentPreimage({
      operationId: new Uint8Array(31), issuerKind: IssuerKind.Root,
      signingPublicKey: SIGN, noisePublicKey: NOISE, capabilities: 7, binding,
    })).toBeNull();
    // §10.3 accepts exactly {1, 3, 7}; the commitment must not encode an authority a grant could not.
    expect(grantCommitmentPreimage({
      operationId: OP, issuerKind: IssuerKind.Root,
      signingPublicKey: SIGN, noisePublicKey: NOISE, capabilities: 5, binding,
    })).toBeNull();
    // §10.3: only root-issued grants may carry `enroll`.
    expect(grantCommitmentPreimage({
      operationId: OP, issuerKind: IssuerKind.Device,
      signingPublicKey: SIGN, noisePublicKey: NOISE, capabilities: 7, binding,
    })).toBeNull();
  });
});
