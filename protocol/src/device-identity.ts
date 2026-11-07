/// §10.2's local device keys, and the installation record they are stored in.
///
/// Mirror of `RdevCore.DeviceIdentity` (Swift).
///
/// **THE TWO KEYS ARE INDEPENDENT AND BOTH ARE IDENTITY.** §7 forbids deriving one from the other,
/// and §10.2 says "Changing either key creates a new device identity" — so a build that regenerated
/// one and kept the other has not rotated anything, it has become a different device with a grant
/// that no longer describes it. `deviceId` is over BOTH, which makes that automatic.
///
/// **THERE IS NO RECOVERY.** §10.2: "Private-key loss means generating new keys and enrolling again,
/// not reconstructing the old device." Nothing here takes a passphrase, a seed phrase or a backup,
/// and nothing should be added that does — §6 lists key recovery among the things this protocol
/// deliberately does not provide.
///
/// **A BROWSER DEVICE KEY IS EXTRACTABLE BY ANY SCRIPT ON ITS ORIGIN**, and it has to be: Noise
/// needs the raw X25519 scalar, so a non-extractable `CryptoKey` cannot serve. That is not a gap
/// this layer can close — §6 already assumes honest frontend code, and §2 says the same — but it is
/// the reason the browser's keys are worth exactly as much as the bundle that reads them.
import { ed25519, x25519 } from "@noble/curves/ed25519.js";
import { device as deviceDescriptor, deviceId as hashDevice } from "./e2e-identity";
import { E2EReader, lengthPrefixed } from "./e2e-wire";
import { RENDEZVOUS_SEED_BYTES, deriveRendezvous, type RendezvousRoute } from "./rendezvous-seed";

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);
const concat = (...parts: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

const RECORD_LABEL = "rdev-e2e/installation/v1";

export interface DeviceKeys {
  signingPrivateKey: Uint8Array;
  noisePrivateKey: Uint8Array;
}

export interface Installation {
  keys: DeviceKeys;
  rendezvousSeed: Uint8Array;
}

/// Nil if either key is the wrong width. Refused rather than padded: a short key is a bug at the
/// call site, and deriving from one silently produces a well-formed identity with less entropy than
/// any reader would assume.
export function deviceKeys (signingPrivateKey: Uint8Array,
                            noisePrivateKey: Uint8Array): DeviceKeys | null {
  if (signingPrivateKey.length !== 32 || noisePrivateKey.length !== 32) return null;
  return { signingPrivateKey, noisePrivateKey };
}

/// Ed25519 — §10.3's grant signatures and §11.2's device proof.
export const signingPublicKey = (keys: DeviceKeys): Uint8Array =>
  ed25519.getPublicKey(keys.signingPrivateKey);

/// X25519 — the Noise static (§11.1). A DIFFERENT ALGORITHM on a different curve representation,
/// not a reuse of the signing key; converting between them is exactly what §7 forbids.
export const noisePublicKey = (keys: DeviceKeys): Uint8Array =>
  x25519.getPublicKey(keys.noisePrivateKey);

export function descriptor (keys: DeviceKeys, rootId: Uint8Array): Uint8Array | null {
  return deviceDescriptor(rootId, signingPublicKey(keys), noisePublicKey(keys));
}

export function deviceIdFor (keys: DeviceKeys, rootId: Uint8Array): Uint8Array | null {
  const d = descriptor(keys, rootId);
  return d && hashDevice(d);
}

export const installationRoute = async (i: Installation): Promise<RendezvousRoute | null> =>
  deriveRendezvous(i.rendezvousSeed);

/// RFC 7748's scalar clamping, applied to the STORED bytes rather than at every use, so the two
/// implementations compare the same record.
export function clampX25519 (raw: Uint8Array): Uint8Array {
  if (raw.length !== 32) return raw;
  const k = Uint8Array.from(raw);
  k[0]! &= 248;
  k[31]! &= 127;
  k[31]! |= 64;
  return k;
}

/// Generate a fresh installation. `randomBytes` is injectable so the derivation is testable and so a
/// caller can supply a source it trusts.
///
/// **THE THREE VALUES ARE INDEPENDENT DRAWS.** Deriving them from one seed would be smaller and is
/// wrong here: §9.1's pairing seed does exactly that on purpose, because all three of its outputs
/// belong to one short-lived window, whereas these are a signing identity, a DH identity and a
/// public address that must not be linkable to each other by anyone who learns one.
export function generateInstallation (
  randomBytes: (n: number) => Uint8Array = systemRandom,
): Installation | null {
  const keys = deviceKeys(randomBytes(32), clampX25519(randomBytes(32)));
  if (!keys) return null;
  return { keys, rendezvousSeed: randomBytes(RENDEZVOUS_SEED_BYTES) };
}

export function systemRandom (count: number): Uint8Array {
  const out = new Uint8Array(count);
  // A missing CSPRNG is not a condition to carry on from with a zeroed key; §6 says RNG failure is
  // not repaired by any mechanism in this protocol, so the only honest response is to stop.
  if (!globalThis.crypto?.getRandomValues) throw new Error("no CSPRNG available");
  globalThis.crypto.getRandomValues(out);
  return out;
}

/// `LP("rdev-e2e/installation/v1") || signing_private || noise_private || rendezvous_seed`
///
/// **LOCAL ONLY — these bytes never touch a wire and no peer ever parses them.** The label is here
/// so a stored item that turns out to hold something else is REFUSED rather than read as 96 bytes of
/// key material, which is the failure that would silently produce a device nobody can authenticate.
export function encodeInstallation (i: Installation): Uint8Array {
  return concat(lengthPrefixed(utf8(RECORD_LABEL))!, i.keys.signingPrivateKey,
                i.keys.noisePrivateKey, i.rendezvousSeed);
}

export function decodeInstallation (bytes: Uint8Array): Installation | null {
  const r = new E2EReader(bytes);
  if (!r.expectLabel(RECORD_LABEL)) return null;
  const signing = r.take(32);
  const noise = r.take(32);
  const seed = r.take(RENDEZVOUS_SEED_BYTES);
  if (!signing || !noise || !seed || !r.atEnd) return null;
  const keys = deviceKeys(signing, noise);
  return keys ? { keys, rendezvousSeed: seed } : null;
}

// ------------------------------------------------- loading and creating, independent of storage

/// Somewhere durable to keep ~122 bytes. Deliberately tiny: every decision worth making is above it.
/// Async because the browser's durable stores are.
export interface InstallationBackend {
  read(): Promise<Uint8Array | null>;
  write(bytes: Uint8Array): Promise<boolean>;
  delete(): Promise<boolean>;
}

export type InstallationOutcome =
  /** An existing installation was read back intact. */
  | { ok: true; state: "loaded"; installation: Installation }
  /** Nothing was stored, so a new identity was generated and written. */
  | { ok: true; state: "created"; installation: Installation }
  | { ok: false; failure: InstallationFailure };

export type InstallationFailure =
  /**
   * Something is stored and it is not an installation record.
   *
   * **THE CALLER MUST NOT TREAT THIS AS "NO IDENTITY".** Overwriting it generates a new device,
   * which silently abandons every grant the old one held — §10.2 is explicit that key loss "means
   * generating new keys and enrolling again", and enrolling again is a decision with a person in it.
   * A transient read fault and a genuinely corrupt record are indistinguishable from here, and only
   * one of them is worth destroying an identity over.
   */
  | "unreadable-record"
  /** §12.3: "unsuccessful durable write grants no authority". */
  | "write-failed"
  | "generation-failed";

/// Read the installation, or create one if and only if the store is EMPTY.
///
/// The three outcomes are deliberately distinct. "Loaded" and "created" differ because a device that
/// has just created its identity has no grants and must enroll, while one that loaded its own may
/// already be authorized — and "unreadable" is neither, because it is the only one where the right
/// move is to stop and say so.
export async function loadOrCreateInstallation (
  backend: InstallationBackend,
  randomBytes: (n: number) => Uint8Array = systemRandom,
): Promise<InstallationOutcome> {
  const stored = await backend.read();
  if (stored !== null) {
    const installation = decodeInstallation(stored);
    return installation
      ? { ok: true, state: "loaded", installation }
      : { ok: false, failure: "unreadable-record" };
  }
  let fresh: Installation | null;
  try {
    fresh = generateInstallation(randomBytes);
  } catch {
    return { ok: false, failure: "generation-failed" };
  }
  if (!fresh) return { ok: false, failure: "generation-failed" };
  if (!await backend.write(encodeInstallation(fresh))) {
    return { ok: false, failure: "write-failed" };
  }
  return { ok: true, state: "created", installation: fresh };
}

/// Deliberately destroy this device's identity — the "enroll again" half of §10.2's rule.
///
/// **SEPARATE FROM `loadOrCreateInstallation` ON PURPOSE, and taking no shortcut through it.** This
/// is the only path that discards keys, so it is the only place a reader has to look to find out
/// what can.
export const destroyInstallation = async (backend: InstallationBackend): Promise<boolean> =>
  backend.delete();

/// An in-memory backend, for tests and for a runtime with nowhere durable to write.
export class MemoryInstallationBackend implements InstallationBackend {
  writes = 0;
  constructor (private contents: Uint8Array | null = null) {}
  get stored (): Uint8Array | null { return this.contents; }
  async read (): Promise<Uint8Array | null> { return this.contents; }
  async write (bytes: Uint8Array): Promise<boolean> {
    this.contents = bytes; this.writes += 1; return true;
  }
  async delete (): Promise<boolean> { this.contents = null; return true; }
}

/// A backend whose writes always fail, so "unsuccessful durable write" is reachable from a test
/// rather than only from a broken machine.
export class ReadOnlyInstallationBackend implements InstallationBackend {
  constructor (private readonly contents: Uint8Array | null = null) {}
  async read (): Promise<Uint8Array | null> { return this.contents; }
  async write (): Promise<boolean> { return false; }
  async delete (): Promise<boolean> { return false; }
}
