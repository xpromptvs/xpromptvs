import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { reviewHost, reviewHosts, rootCandidates, type ListedHost } from "../src/e2e-host-list";
import { parseRoot, root as encodeRoot } from "../src/e2e-identity";
import { bundle as encodeBundle, certificate as encodeCertificate, parseBundle } from "../src/e2e-certificate";

// Turning a Control Plane's list of live hosts into something a person may be shown.
//
// THE LIST IS EVIDENCE OF NOTHING. Every field arrives from the adversary of section 4, and section
// 9.2 says addresses and room tokens confer no E2E authority. These tests are about the one thing
// this layer decides: which names a user may be shown as if they meant something.
interface LabelCase {
  name: string; target_device_id: string; signer: string;
  body: string; signature: string; signer_bundle: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/e2e-session.json", import.meta.url)), "utf8")) as {
    rp_id: string; allowed_origins: string[]; root_id: string;
    devices: Record<string, { device_id: string }>;
    labels: Record<string, LabelCase>;
  };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const b64u = (u: Uint8Array): string => {
  let s = "";
  for (const b of u) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const opts = {
  trustedRootId: hex(fx.root_id),
  policy: { rpId: fx.rp_id, allowedOrigins: fx.allowed_origins },
};

const row = (over: Partial<ListedHost> = {}): ListedHost => {
  const c = fx.labels.valid!;
  return {
    name: "Isaac's MacBook", code: "c1", token: "t1",
    e2eDeviceId: b64u(hex(c.target_device_id)),
    label: b64u(hex(c.body)),
    labelSignature: b64u(hex(c.signature)),
    labelSignerBundle: b64u(hex(c.signer_bundle)),
    ...over,
  };
};

describe("a fully identified host", () => {
  test("its name is verified and it is connectable", () => {
    const r = reviewHost(row(), opts);
    expect(r.nameSource).toBe("verified");
    expect(r.displayName).toBe("Isaac's MacBook");
    expect(r.connectable).toBe(true);
    expect(r.labelFailure).toBeNull();
    expect(r.nameContested).toBe(false);
    expect(r.deviceId).toEqual(hex(fx.labels.valid!.target_device_id));
  });

  // The verified name WINS, and the disagreement is recorded: this is the directory caught saying
  // something a signature contradicts.
  test("a directory name that contradicts the label loses, and is flagged", () => {
    const r = reviewHost(row({ name: "Something Else" }), opts);
    expect(r.displayName).toBe("Isaac's MacBook");
    expect(r.nameSource).toBe("verified");
    expect(r.nameContested).toBe(true);
  });
});

describe("what makes a row unconnectable", () => {
  // Section 11.1 requires that "a selected Host's device_id must also match the selection", and a
  // selection with nothing to match is not one - so offering this row could never be made safe.
  test("no device id at all", () => {
    const r = reviewHost(row({ e2eDeviceId: undefined }), opts);
    expect(r.connectable).toBe(false);
    expect(r.deviceId).toBeNull();
    expect(r.nameSource).toBe("unverified");
  });

  test("a device id that is not 32 bytes, or not base64url", () => {
    for (const bad of ["", "AAAA", "not base64!", b64u(new Uint8Array(31))]) {
      expect(reviewHost(row({ e2eDeviceId: bad }), opts).connectable).toBe(false);
    }
  });

  test("an unconnectable row still carries its unverified name rather than nothing", () => {
    // A caller has to render SOMETHING, and a blank row tells a user less than a marked one.
    const r = reviewHost(row({ e2eDeviceId: undefined, name: "Old Mac" }), opts);
    expect(r.displayName).toBe("Old Mac");
    expect(r.nameSource).toBe("unverified");
  });
});

describe("what makes a name unverified", () => {
  test("no label", () => {
    const r = reviewHost(row({ label: undefined, labelSignature: undefined,
                               labelSignerBundle: undefined }), opts);
    expect(r.nameSource).toBe("unverified");
    expect(r.connectable).toBe(true);   // still selectable; only its NAME is unvouched for
    expect(r.labelFailure).toBeNull();
  });

  // Three fields that only mean anything together. A row carrying two of them is a row whose name is
  // unvouched-for, not one to half-believe.
  test("a partial label is no label", () => {
    for (const missing of ["label", "labelSignature", "labelSignerBundle"] as const) {
      const r = reviewHost(row({ [missing]: undefined }), opts);
      expect(r.nameSource, missing).toBe("unverified");
      expect(r.labelFailure, missing).toBeNull();
    }
  });

  test("a label for a different device is refused and says so", () => {
    const r = reviewHost(row({ e2eDeviceId: b64u(hex(fx.devices.C!.device_id)) }), opts);
    expect(r.nameSource).toBe("unverified");
    expect(r.labelFailure).toBe("device-mismatch");
    // Still connectable: the device id is well formed, and only the NAME failed to verify.
    expect(r.connectable).toBe(true);
  });

  test("a label signed by a device without enroll is refused", () => {
    const c = fx.labels["signer-not-authorised"]!;
    const r = reviewHost(row({
      e2eDeviceId: b64u(hex(c.target_device_id)),
      label: b64u(hex(c.body)), labelSignature: b64u(hex(c.signature)),
      labelSignerBundle: b64u(hex(c.signer_bundle)),
    }), opts);
    expect(r.labelFailure).toBe("signer-not-authorised");
    expect(r.nameSource).toBe("unverified");
  });

  test("a revoked signer cannot vouch for a name", () => {
    const r = reviewHost(row(), {
      ...opts, revokedDeviceIds: [hex(fx.devices.H!.device_id)],
    });
    expect(r.labelFailure).toBe("signer-chain");
    expect(r.nameSource).toBe("unverified");
  });

  test("garbage in the label fields is refused without throwing", () => {
    for (const bad of ["not base64!", "", "AAAA"]) {
      const r = reviewHost(row({ label: bad }), opts);
      expect(r.nameSource).toBe("unverified");
    }
  });
});

describe("the listing as a whole", () => {
  // NOTHING IS DROPPED. A row silently missing is indistinguishable from a device that is not
  // running, and section 12.2 is emphatic that absence must never be read as a verdict.
  test("order is preserved and unconnectable rows are marked, not removed", () => {
    const list = reviewHosts([
      row({ code: "a" }),
      row({ code: "b", e2eDeviceId: undefined }),
      row({ code: "c", label: undefined }),
    ], opts);
    expect(list.map((r) => r.code)).toEqual(["a", "b", "c"]);
    expect(list.map((r) => r.connectable)).toEqual([true, false, true]);
    expect(list.map((r) => r.nameSource)).toEqual(["verified", "unverified", "unverified"]);
  });

  test("an empty listing reviews to an empty listing", () => {
    expect(reviewHosts([], opts)).toEqual([]);
  });
});

// The identities a listing OFFERS to join, for a device that holds none yet — and the reason that
// ask is safe rather than merely honest: joining means asserting the root's passkey on this origin,
// so a substituted root either has no credential here (the ceremony fails) or is the person's own.
describe("root candidates", () => {
  const row = (bundle: string | undefined, code: string): ListedHost => ({
    name: "Mac", code, token: `t-${code}`,
    ...(bundle === undefined ? {} : { labelSignerBundle: bundle }),
  });
  const goodBundle = b64u(hex(fx.labels.valid!.signer_bundle));

  test("a listing with one identity offers it once, however many rows present it", () => {
    const candidates = rootCandidates([row(goodBundle, "a"), row(goodBundle, "b")]);
    expect(candidates).toHaveLength(1);
    expect([...candidates[0]!.rootId]).toEqual([...hex(fx.root_id)]);
    expect(candidates[0]!.presentedBy).toBe(2);
  });

  test("rows with no bundle contribute nothing, and are not an error", () => {
    expect(rootCandidates([row(undefined, "a")])).toHaveLength(0);
    expect(rootCandidates([])).toHaveLength(0);
  });

  // Parsed, not verified — but a bundle that does not decode names no identity at all, and naming
  // a person something unparseable is worse than offering them nothing.
  test("a bundle that does not parse is skipped", () => {
    expect(rootCandidates([row(b64u(new Uint8Array([1, 2, 3])), "a")])).toHaveLength(0);
    expect(rootCandidates([row("not base64url!!", "a")])).toHaveLength(0);
  });

  // **A WELL-FORMED BUNDLE CAN STILL CARRY A ROOT THAT IS NOT ONE.** `parseBundle` reads the root
  // as length-prefixed bytes and validates nothing about them, so the descriptor has to be parsed
  // separately — and a candidate whose root does not decode could never be used for a ceremony.
  test("a bundle whose ROOT does not parse is skipped", () => {
    const parsed = parseBundle(hex(fx.labels.valid!.signer_bundle));
    if (!parsed.ok) throw new Error("the fixture bundle must parse");
    const certs = parsed.bundle.certificates.map((c) => encodeCertificate(c.grant, c.evidence)!);
    const junkRoot = encodeBundle(new Uint8Array([9, 9, 9]), certs)!;
    expect(parseBundle(junkRoot).ok).toBe(true);
    expect(rootCandidates([row(b64u(junkRoot), "a")])).toHaveLength(0);
  });

  // The identity most of a person's Macs agree on is the one offered first. The fixture has ONE
  // root, so the second identity is built here — a different relying party over the same key, which
  // is what a second account on another deployment would look like.
  test("candidates are ordered by how many rows presented them", () => {
    const parsed = parseBundle(hex(fx.labels.valid!.signer_bundle));
    if (!parsed.ok) throw new Error("the fixture bundle must parse");
    const mine = parseRoot(parsed.bundle.root)!;
    const otherRoot = encodeRoot("other.example", mine.credentialId, mine.publicKey)!;
    const other = b64u(encodeBundle(otherRoot, parsed.bundle.certificates.map(
      (c) => encodeCertificate(c.grant, c.evidence)!))!);
    const candidates = rootCandidates([
      row(other, "a"), row(goodBundle, "b"), row(goodBundle, "c"),
    ]);
    expect(candidates).toHaveLength(2);
    expect([...candidates[0]!.rootId]).toEqual([...hex(fx.root_id)]);
    expect(candidates[0]!.presentedBy).toBe(2);
    expect(candidates[1]!.presentedBy).toBe(1);
  });

  test("the root comes back exactly as it appeared, for the ceremony to use", () => {
    const candidates = rootCandidates([row(goodBundle, "a")]);
    expect(parseRoot(candidates[0]!.root)).not.toBeNull();
  });
});
