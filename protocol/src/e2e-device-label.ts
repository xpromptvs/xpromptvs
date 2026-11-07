/// A device's human-readable name, **signed by someone entitled to assign it**.
///
/// ```
/// label = LP("rdev-e2e/device-label/v1") || root_id || device_id || LP(name)
/// ```
///
/// Mirror of `RdevCore.E2EDeviceLabel` (Swift).
///
/// **AN ADDITION TO THE SPECIFICATION, not one of its sections**, closing a gap it names without
/// closing. §10.1's residual says of a root: "that name MUST come from local state or from the
/// authenticator's own credential metadata, **never from a directory-supplied label, which the same
/// adversary chose**." The same argument applies to a Host in an account list, where the name is
/// host-supplied, Worker-stored and client-displayed — precisely a directory-supplied label.
///
/// §4's adversary cannot invent a device (that needs the root passkey) but **can swap the names on
/// two devices the user really owns**, so a user types into the wrong machine. This makes the name
/// as trustworthy as the device that assigned it.
///
/// **THE RULE IS ABOUT AUTHORITY, NOT ABOUT WHO.** The signer must hold `enroll` — and nothing stops
/// that being the device being named. A device that enrolled itself with a passkey holds a direct
/// grant with `enroll`, so it names itself, which is the ordinary case: the person is sitting at the
/// machine they are naming.
///
/// What the rule excludes is a device WITHOUT that authority naming anything, itself included. §6
/// accepts that "a directly enrolled device can issue access-only leaf grants", so a compromised
/// leaf is inside the model — and a leaf that could name itself "Isaac's MacBook" is the same attack
/// in the one place a user actually looks.
///
/// **ORDERING, not a circularity:** the label is signed AFTER the grant exists. A code-enrolled
/// device — capabilities 1 or 3 — can never name itself, and its Issuer names it.
import { IssuerKind, CAP_ENROLL } from "./e2e-identity";
import { verifyBundle, verifyEd25519, type E2EPolicy } from "./e2e-verify";
import { E2E_ID_LENGTH, E2EReader, bytesEqual, lengthPrefixed } from "./e2e-wire";

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);
const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

const LABEL = "rdev-e2e/device-label/v1";

/// Generous for a human name, small enough that a list stays a list. In BYTES, because that is what
/// the length prefix carries.
export const DEVICE_LABEL_MAX_NAME_BYTES = 128;

export interface DeviceLabel {
  bytes: Uint8Array;
  rootId: Uint8Array;
  deviceId: Uint8Array;
  name: string;
}

export type DeviceLabelFailure =
  | "malformed"
  /** The name is not something to put in front of a person. */
  | "unsafe-name"
  | "root-mismatch"
  /** The signer's own chain did not verify. */
  | "signer-chain"
  /** The signer's chain is valid and does not carry `enroll`. */
  | "signer-not-authorised"
  | "signature"
  /** The label names a device other than the one being displayed. */
  | "device-mismatch";

export type DeviceLabelResult =
  | { ok: true; label: DeviceLabel }
  | { ok: false; failure: DeviceLabelFailure };

/// What may be shown to a person in a list of machines they are about to control.
///
/// **Control characters and bidirectional overrides are refused**, and that is not general hygiene:
/// this string's whole job is to tell a user WHICH MACHINE they are connecting to, and both classes
/// let one string render as another. The signer is authorised, so this is not the main defence — it
/// stops an authorised-but-careless name from being a misleading one, and it costs nothing.
export function nameIsSafe (name: string): boolean {
  const bytes = utf8(name);
  if (bytes.length === 0 || bytes.length > DEVICE_LABEL_MAX_NAME_BYTES) return false;
  for (const ch of name) {
    const code = ch.codePointAt(0)!;
    if (code < 0x20 || (code >= 0x7f && code <= 0x9f)) return false;   // C0, DEL, C1
    if (code >= 0x202a && code <= 0x202e) return false;                // LRE RLE PDF LRO RLO
    if (code >= 0x2066 && code <= 0x2069) return false;                // LRI RLI FSI PDI
  }
  return true;
}

export function deviceLabelBody (rootId: Uint8Array, deviceId: Uint8Array,
                                 name: string): Uint8Array | null {
  if (rootId.length !== E2E_ID_LENGTH || deviceId.length !== E2E_ID_LENGTH) return null;
  if (!nameIsSafe(name)) return null;
  const encoded = lengthPrefixed(utf8(name));
  return encoded ? concat(lengthPrefixed(utf8(LABEL))!, rootId, deviceId, encoded) : null;
}

export function parseDeviceLabel (bytes: Uint8Array): DeviceLabel | null {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(LABEL)) return null;
  const rootId = r.take(E2E_ID_LENGTH);
  const deviceId = r.take(E2E_ID_LENGTH);
  const raw = r.lengthPrefixed();
  if (!rootId || !deviceId || !raw || !r.atEnd) return null;
  let name: string;
  try {
    name = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw);
  } catch {
    return null;
  }
  return nameIsSafe(name) ? { bytes, rootId, deviceId, name } : null;
}

/// Verify a label against the chain of whoever signed it.
///
/// `expectedDeviceId` is the device the caller is about to DISPLAY this name beside. Passing it is
/// what makes the label a statement about that row rather than a valid label for some other device
/// that the directory moved.
export function verifyDeviceLabel (opts: {
  body: Uint8Array;
  signature: Uint8Array;
  signerBundle: Uint8Array;
  expectedDeviceId: Uint8Array;
  trustedRootId: Uint8Array;
  policy: E2EPolicy;
  revokedDeviceIds?: readonly Uint8Array[];
}): DeviceLabelResult {
  const label = parseDeviceLabel(opts.body);
  if (!label) {
    // A name that fails `nameIsSafe` parses as nothing, so the caller hears one refusal for "not a
    // label" and another for "not a name a list may show".
    return { ok: false, failure: isLabelShaped(opts.body) ? "unsafe-name" : "malformed" };
  }
  if (!bytesEqual(label.rootId, opts.trustedRootId)) {
    return { ok: false, failure: "root-mismatch" };
  }
  if (!bytesEqual(label.deviceId, opts.expectedDeviceId)) {
    return { ok: false, failure: "device-mismatch" };
  }

  const signer = verifyBundle(opts.signerBundle, {
    trustedRootId: opts.trustedRootId, policy: opts.policy,
    revokedDeviceIds: opts.revokedDeviceIds ?? [],
  });
  if (!signer.ok) return { ok: false, failure: "signer-chain" };
  // The same authority §13 requires for code issuance, and for the same reason: this is an
  // administrative act over the identity, not a use of it.
  if ((signer.chain.leaf.capabilities & CAP_ENROLL) === 0
      || signer.chain.leaf.issuerKind !== IssuerKind.Root) {
    return { ok: false, failure: "signer-not-authorised" };
  }
  if (!verifyEd25519(opts.signature, label.bytes, signer.chain.leafDevice.signingPublicKey)) {
    return { ok: false, failure: "signature" };
  }
  return { ok: true, label };
}

/// Are these bytes a label whose only problem is its name? Used to tell "not a label" apart from
/// "a label carrying a name a list must not show".
function isLabelShaped (bytes: Uint8Array): boolean {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(LABEL)) return false;
  const rootId = r.take(E2E_ID_LENGTH);
  const deviceId = r.take(E2E_ID_LENGTH);
  const raw = r.lengthPrefixed();
  return rootId !== null && deviceId !== null && raw !== null && r.atEnd;
}
