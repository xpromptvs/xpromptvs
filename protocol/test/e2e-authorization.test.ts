import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  SessionAuthority, authorize, type AuthDenial, type AuthEffect,
} from "../src/e2e-authorization";
import { verifyBundle, type VerifiedChain } from "../src/e2e-verify";
import { IssuerKind, authorityIsWellFormed } from "../src/e2e-identity";

// §13's authorization rules, against the same world the session machine uses
// (`scripts/gen_e2e_session_fixture.py`) and which `E2EAuthorizationTests.swift` asserts too.
//
// H holds capabilities 7 root-issued; C holds 3 and is device-issued; X holds 1 root-issued. Those
// three cover every cell of the table below with real, signed chains rather than hand-built values.
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-session.json", import.meta.url)), "utf8")) as {
    rp_id: string; allowed_origins: string[]; root_id: string;
    devices: Record<string, { bundle: string }>;
  };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const policy = { rpId: fx.rp_id, allowedOrigins: fx.allowed_origins };

function chain (name: string): VerifiedChain {
  const v = verifyBundle(hex(fx.devices[name]!.bundle),
                         { trustedRootId: hex(fx.root_id), policy });
  if (!v.ok) throw new Error(`${name}: ${v.failure}`);
  return v.chain;
}

const outcome = (effect: AuthEffect, name: string,
                 over: { gatePassed?: boolean; revocationChecked?: boolean } = {}): string => {
  const r = authorize(effect, {
    chain: chain(name),
    gatePassed: over.gatePassed ?? true,
    revocationChecked: over.revocationChecked ?? true,
  });
  return r.ok ? "ok" : r.denial;
};

describe("§13's capability table", () => {
  // capabilities: H = 7 (root), C = 3 (device-issued), X = 1 (root)
  const table: Array<[AuthEffect, string, string]> = [
    ["connect", "H", "ok"], ["connect", "C", "ok"], ["connect", "X", "ok"],
    ["host", "H", "ok"], ["host", "C", "ok"], ["host", "X", "missing-capability"],
    ["issue-code", "H", "ok"],
    ["issue-code", "C", "not-direct-enroll"], ["issue-code", "X", "not-direct-enroll"],
  ];
  for (const [effect, name, want] of table) {
    test(`${effect} for ${name} → ${want}`, () => {
      expect(outcome(effect, name)).toBe(want);
    });
  }

  test("connect is not read-only", () => {
    // §10.3: "a Client-only device still receives full remote control of the Host it connects to,
    // including a shell". X holds capabilities 1 and this is a full session, not a viewer.
    expect(outcome("connect", "X")).toBe("ok");
  });
});

// §13: "Only a direct `enroll` grant authorizes code issuance."
//
// THIS BRANCH IS UNREACHABLE THROUGH THE PARSER, AND THAT IS WHY IT IS TESTED HERE. `parseGrant`
// already refuses any device-issued grant carrying `enroll` (§10.3), so no bundle can produce such a
// chain and no fixture can contain one — a mutation deleting the issuer-kind conjunct passed the
// entire suite. The check is defence in depth across two files, so it is exercised by building the
// chain the parser will not.
test("code issuance requires a root-issued grant even if the parser would refuse one", () => {
  const leafWith = (issuerKind: IssuerKind): VerifiedChain => {
    const grant = {
      bytes: new Uint8Array(0), rootId: new Uint8Array(0), operationId: new Uint8Array(0),
      issuerKind, issuerId: new Uint8Array(0), device: new Uint8Array(0),
      capabilities: 7, binding: { kind: "local", randomness: new Uint8Array(0) },
    } as VerifiedChain["leaf"];
    const device = {
      bytes: new Uint8Array(0), rootId: new Uint8Array(0),
      signingPublicKey: new Uint8Array(0), noisePublicKey: new Uint8Array(0),
    };
    return {
      root: { bytes: new Uint8Array(0), rpId: "", credentialId: new Uint8Array(0),
              publicKey: new Uint8Array(0) },
      grants: [grant], leaf: grant, leafDevice: device,
    };
  };
  const decide = (chain: VerifiedChain): string => {
    const r = authorize("issue-code", { chain, gatePassed: true, revocationChecked: true });
    return r.ok ? "ok" : r.denial;
  };
  expect(decide(leafWith(IssuerKind.Root))).toBe("ok");
  expect(decide(leafWith(IssuerKind.Device))).toBe("not-direct-enroll");

  // And the reason it cannot arrive that way in practice, asserted so the two rules stay tied.
  expect(authorityIsWellFormed(IssuerKind.Device, 7)).toBe(false);
});

describe("both preconditions are required, and separately", () => {
  // Folding them into one "ready" flag would let a caller that did one satisfy a check meant for
  // both. They are made at different times by different code.
  test("the gate alone is not enough", () => {
    expect(outcome("connect", "H", { revocationChecked: false })).toBe("revocation-not-checked");
  });

  test("the revocation check alone is not enough", () => {
    expect(outcome("connect", "H", { gatePassed: false })).toBe("not-authenticated");
  });

  test("neither, and the gate is reported first", () => {
    expect(outcome("connect", "H", { gatePassed: false, revocationChecked: false }))
      .toBe("not-authenticated");
  });

  test("no effect is reachable without both, for any device", () => {
    for (const effect of ["connect", "host", "issue-code"] as AuthEffect[]) {
      for (const name of ["H", "C", "X"]) {
        expect(outcome(effect, name, { gatePassed: false })).not.toBe("ok");
        expect(outcome(effect, name, { revocationChecked: false })).not.toBe("ok");
      }
    }
  });
});

describe("§13: a replaced or revoked session withdraws its authority", () => {
  test("a stamp from the previous session never runs again", () => {
    const authority = new SessionAuthority();
    const first = authority.current;
    expect(authority.permits(first)).toBe(true);

    const second = authority.replace();
    expect(authority.permits(second)).toBe(true);
    // The late callback: captured under `first`, firing after the handover.
    expect(authority.permits(first)).toBe(false);
    expect((authority.check(first) as { denial: AuthDenial }).denial).toBe("authority-withdrawn");
  });

  test("withdrawal refuses the CURRENT stamp too", () => {
    // §10.5 on revocation: "withdraw active control, release held input, and prevent further effects
    // from those sessions." The session being current is exactly what is being taken away.
    const authority = new SessionAuthority();
    const stamp = authority.current;
    authority.withdraw();
    expect(authority.permits(stamp)).toBe(false);
    expect(authority.withdrawn).toBe(true);
  });

  test("the way back from withdrawal is a NEW session, never a resumption", () => {
    const authority = new SessionAuthority();
    const withdrawn = authority.current;
    authority.withdraw();
    const fresh = authority.replace();
    expect(authority.permits(fresh)).toBe(true);
    expect(authority.permits(withdrawn)).toBe(false);
    expect(fresh.epoch).toBeGreaterThan(withdrawn.epoch);
  });

  test("epochs only move forward, so an old stamp can never become valid again", () => {
    const authority = new SessionAuthority();
    const stamps = [authority.current];
    for (let i = 0; i < 5; i++) stamps.push(authority.replace());
    for (const s of stamps.slice(0, -1)) expect(authority.permits(s)).toBe(false);
    expect(authority.permits(stamps[stamps.length - 1]!)).toBe(true);
    expect(new Set(stamps.map((s) => s.epoch)).size).toBe(stamps.length);
  });
});
