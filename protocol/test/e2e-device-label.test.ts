import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  DEVICE_LABEL_MAX_NAME_BYTES, deviceLabelBody, nameIsSafe, parseDeviceLabel, verifyDeviceLabel,
} from "../src/e2e-device-label";

// The signed device label. `E2EDeviceLabelTests.swift` asserts the same rules against the same
// fixture, which a THIRD implementation produced.
//
// The attack it stops is narrow and real: the adversary of section 4 cannot invent a device - that
// needs the root passkey - but it CAN swap the names on two devices the user really owns, and a
// user then types into the wrong machine.
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
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");
const policy = { rpId: fx.rp_id, allowedOrigins: fx.allowed_origins };

/// Built from code points rather than written as literals, so this source file contains none of the
/// characters it is about - which is the same reason the rule exists.
const ch = (code: number): string => String.fromCodePoint(code);

function verify (caseName: string, over: {
  expectedDeviceId?: Uint8Array; signature?: Uint8Array; body?: Uint8Array;
  revokedDeviceIds?: Uint8Array[];
} = {}): string {
  const c = fx.labels[caseName]!;
  const r = verifyDeviceLabel({
    body: over.body ?? hex(c.body),
    signature: over.signature ?? hex(c.signature),
    signerBundle: hex(c.signer_bundle),
    expectedDeviceId: over.expectedDeviceId ?? hex(c.target_device_id),
    trustedRootId: hex(fx.root_id), policy,
    revokedDeviceIds: over.revokedDeviceIds ?? [],
  });
  return r.ok ? "ok" : r.failure;
}

describe("cross-implementation vectors", () => {
  // A DEVICE HOLDING `enroll` MAY NAME ITSELF, and that is the ordinary case - a device enrolled
  // with a passkey holds a direct grant with `enroll`, and the person is sitting at the machine they
  // are naming. Paired with "a leaf cannot name itself" below, which is the SAME SHAPE and refused.
  // Together they say the rule is about AUTHORITY, not about who.
  test("a device holding enroll may name itself", () => {
    const c = fx.labels.valid!;
    expect(c.signer).toBe("H");
    expect(c.target_device_id).toBe(fx.devices.H!.device_id);
    expect(verify("valid")).toBe("ok");
    const parsed = parseDeviceLabel(hex(fx.labels.valid!.body))!;
    expect(parsed.name).toBe("Isaac's MacBook");
    expect(toHex(parsed.deviceId)).toBe(fx.labels.valid!.target_device_id);
  });

  test("the encoding matches the third implementation's bytes", () => {
    const c = fx.labels.valid!;
    expect(toHex(deviceLabelBody(hex(fx.root_id), hex(c.target_device_id), c.name)!)).toBe(c.body);
  });
});

describe("the refusals", () => {
  // THE ATTACK THIS EXISTS FOR. The label is genuine, signed by an authorised device, naming a
  // device the user owns - and the directory offered it beside a DIFFERENT device.
  test("a label cannot be moved to another device", () => {
    expect(verify("valid", { expectedDeviceId: hex(fx.devices.C!.device_id) }))
      .toBe("device-mismatch");
  });

  // Section 6 accepts that "a directly enrolled device can issue access-only leaf grants", so a
  // compromised leaf is inside the model - and one that could name itself after the machine a user
  // trusts is the same attack in the one place a user actually looks.
  test("a leaf cannot name itself", () => {
    const c = fx.labels["signer-not-authorised"]!;
    expect(c.signer).toBe("C");
    expect(c.target_device_id).toBe(fx.devices.C!.device_id);   // self-signed, like the accepted case
    expect(verify("signer-not-authorised")).toBe("signer-not-authorised");
  });

  test("a label for another root is refused", () => {
    expect(verify("wrong-root")).toBe("root-mismatch");
  });

  test("a corrupt signature is refused", () => {
    const signature = hex(fx.labels.valid!.signature);
    signature[signature.length - 1]! ^= 0x01;
    expect(verify("valid", { signature })).toBe("signature");
  });

  test("a revoked signer cannot name", () => {
    expect(verify("valid", { revokedDeviceIds: [hex(fx.devices.H!.device_id)] }))
      .toBe("signer-chain");
  });

  test("malformed bytes are refused as malformed", () => {
    const body = hex(fx.labels.valid!.body);
    expect(verify("valid", { body: new Uint8Array([...body, 0]) })).toBe("malformed");
    expect(verify("valid", { body: body.slice(0, -1) })).toBe("malformed");
    expect(verify("valid", { body: new Uint8Array(0) })).toBe("malformed");
  });
});

describe("what may be shown to a person", () => {
  // NUL, newline, DEL, a C1 control, a right-to-left OVERRIDE, and an isolate pair. Both classes
  // let one string render as another, and this string's whole job is to say WHICH MACHINE.
  const unsafe = ["", "a" + ch(0x00) + "b", "a" + ch(0x0A) + "b", "a" + ch(0x7F) + "b",
                  "a" + ch(0x85) + "b", "Isaac" + ch(0x202E) + "koobcam",
                  "a" + ch(0x2066) + "b" + ch(0x2069) + "c"];

  test("control characters and bidi overrides are refused", () => {
    for (const bad of unsafe) {
      expect(nameIsSafe(bad), JSON.stringify(bad)).toBe(false);
      expect(deviceLabelBody(new Uint8Array(32), new Uint8Array(32), bad)).toBeNull();
    }
  });

  test("ordinary names are accepted", () => {
    for (const good of ["Isaac's MacBook", "Mac mini (office)", "Buero-Mac", "desk",
                        "a".repeat(DEVICE_LABEL_MAX_NAME_BYTES)]) {
      expect(nameIsSafe(good), good).toBe(true);
    }
    // The cap is in BYTES, because that is what the length prefix carries - so a name of multi-byte
    // characters runs out sooner, which is the honest limit rather than a character count that
    // would let one encoding overflow the other.
    const twoByte = ch(0xE9);
    expect(twoByte.repeat(DEVICE_LABEL_MAX_NAME_BYTES).length)
      .toBe(DEVICE_LABEL_MAX_NAME_BYTES);
    expect(nameIsSafe(twoByte.repeat(DEVICE_LABEL_MAX_NAME_BYTES))).toBe(false);
  });

  test("an unsafe name is refused at PARSE time too, and named as such", () => {
    // A label built elsewhere, carrying a name this endpoint must not show. Hand-assembled, because
    // deviceLabelBody refuses to produce one.
    const rootId = hex(fx.root_id);
    const deviceId = hex(fx.labels.valid!.target_device_id);
    const hostile = new TextEncoder().encode("Isaac" + ch(0x202E) + "koobcam");
    const label = new TextEncoder().encode("rdev-e2e/device-label/v1");
    const body = new Uint8Array([
      label.length >> 8, label.length & 0xff, ...label,
      ...rootId, ...deviceId,
      hostile.length >> 8, hostile.length & 0xff, ...hostile,
    ]);
    expect(parseDeviceLabel(body)).toBeNull();
    expect(verify("valid", { body })).toBe("unsafe-name");
  });
});
