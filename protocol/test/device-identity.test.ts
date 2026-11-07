import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  MemoryInstallationBackend, ReadOnlyInstallationBackend,
  clampX25519, decodeInstallation, descriptor, destroyInstallation, deviceIdFor, deviceKeys,
  encodeInstallation, generateInstallation, installationRoute, loadOrCreateInstallation,
  noisePublicKey, signingPublicKey,
} from "../src/device-identity";
import { deriveRendezvous } from "../src/rendezvous-seed";

// §10.2's local device keys, against vectors a THIRD implementation produced
// (`scripts/gen_device_identity_fixture.py`) and which `DeviceIdentityTests.swift` asserts too.
interface Case {
  name: string; signing_private_key: string; signing_public_key: string;
  noise_private_key_raw: string; noise_private_key: string; noise_public_key: string;
  rendezvous_seed: string; descriptor: string; device_id: string; record: string;
}
const fx = JSON.parse(readFileSync(
  fileURLToPath(new URL("../fixtures/device-identity.json", import.meta.url)), "utf8")) as
  { root_id: string; cases: Case[] };

const hex = (h: string): Uint8Array => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");
const rootId = hex(fx.root_id);

describe("cross-implementation vectors", () => {
  for (const c of fx.cases) {
    test(c.name, () => {
      const keys = deviceKeys(hex(c.signing_private_key), hex(c.noise_private_key))!;
      expect(keys).not.toBeNull();
      // THE POINT: two runtimes must agree about the public keys a private key implies.
      expect(toHex(signingPublicKey(keys))).toBe(c.signing_public_key);
      expect(toHex(noisePublicKey(keys))).toBe(c.noise_public_key);
      expect(toHex(descriptor(keys, rootId)!)).toBe(c.descriptor);
      expect(toHex(deviceIdFor(keys, rootId)!)).toBe(c.device_id);

      const installation = { keys, rendezvousSeed: hex(c.rendezvous_seed) };
      expect(toHex(encodeInstallation(installation))).toBe(c.record);
      const back = decodeInstallation(hex(c.record))!;
      expect(toHex(back.keys.signingPrivateKey)).toBe(c.signing_private_key);
      expect(toHex(back.keys.noisePrivateKey)).toBe(c.noise_private_key);
      expect(toHex(back.rendezvousSeed)).toBe(c.rendezvous_seed);
    });
  }

  test("clamping changes the stored bytes and not the public key", () => {
    // X25519 clamps its scalar internally, so an unclamped key yields the SAME public key. Clamping
    // before storing is therefore a decision about the RECORD, not about the cryptography — and a
    // runtime that skipped it would write a byte-different record that nevertheless works.
    for (const c of fx.cases) {
      const raw = hex(c.noise_private_key_raw);
      expect(toHex(clampX25519(raw))).toBe(c.noise_private_key);
      expect(toHex(noisePublicKey(deviceKeys(hex(c.signing_private_key), raw)!)))
        .toBe(c.noise_public_key);
    }
  });
});

describe("both keys are identity", () => {
  // §10.2: "Changing either key creates a new device identity." A build that regenerated one and
  // kept the other has not rotated anything — it has become a different device holding a grant that
  // no longer describes it.
  const base = fx.cases[2]!;
  const keys = deviceKeys(hex(base.signing_private_key), hex(base.noise_private_key))!;

  test("a different signing key is a different device", () => {
    const other = deviceKeys(hex(fx.cases[3]!.signing_private_key),
                             hex(base.noise_private_key))!;
    expect(toHex(deviceIdFor(other, rootId)!)).not.toBe(base.device_id);
  });

  test("a different noise key is a different device", () => {
    const other = deviceKeys(hex(base.signing_private_key),
                             hex(fx.cases[3]!.noise_private_key))!;
    expect(toHex(deviceIdFor(other, rootId)!)).not.toBe(base.device_id);
  });

  test("a different root is a different device", () => {
    // The descriptor names its root, so the same keys under another identity are another device.
    const elsewhere = deviceIdFor(keys, new Uint8Array(32).fill(9))!;
    expect(toHex(elsewhere)).not.toBe(base.device_id);
  });
});

describe("the stored record", () => {
  test("a record that is not one is refused, not read as key material", () => {
    const good = hex(fx.cases[0]!.record);
    expect(decodeInstallation(good)).not.toBeNull();
    expect(decodeInstallation(new Uint8Array([...good, 0]))).toBeNull();
    expect(decodeInstallation(good.slice(0, -1))).toBeNull();
    expect(decodeInstallation(new Uint8Array(96))).toBeNull();      // 96 bytes, no label
    expect(decodeInstallation(new Uint8Array(0))).toBeNull();
    // Another module's record, same shape, different label.
    const wrongLabel = Uint8Array.from(good);
    wrongLabel.set(new TextEncoder().encode("X"), 2);
    expect(decodeInstallation(wrongLabel)).toBeNull();
  });

  test("a wrong-width key is refused rather than padded", () => {
    expect(deviceKeys(new Uint8Array(31), new Uint8Array(32))).toBeNull();
    expect(deviceKeys(new Uint8Array(32), new Uint8Array(33))).toBeNull();
  });
});

describe("generation", () => {
  test("draws three independent values and clamps the stored noise key", () => {
    const draws: number[] = [];
    let n = 0;
    const fake = (count: number): Uint8Array => {
      draws.push(count);
      return new Uint8Array(count).fill(++n);
    };
    const i = generateInstallation(fake)!;
    expect(draws).toEqual([32, 32, 32]);
    // Three DIFFERENT draws, not one seed expanded three ways: these are a signing identity, a DH
    // identity and a public address that must not be linkable to each other by anyone who learns one.
    expect(toHex(i.keys.signingPrivateKey)).not.toBe(toHex(i.keys.noisePrivateKey));
    expect(toHex(i.keys.noisePrivateKey)).not.toBe(toHex(i.rendezvousSeed));
    expect(toHex(i.keys.noisePrivateKey)).toBe(toHex(clampX25519(new Uint8Array(32).fill(2))));
  });

  test("two generations share nothing", () => {
    const a = generateInstallation()!;
    const b = generateInstallation()!;
    expect(toHex(a.keys.signingPrivateKey)).not.toBe(toHex(b.keys.signingPrivateKey));
    expect(toHex(a.keys.noisePrivateKey)).not.toBe(toHex(b.keys.noisePrivateKey));
    expect(toHex(a.rendezvousSeed)).not.toBe(toHex(b.rendezvousSeed));
  });

  test("a round trip through the record preserves the identity exactly", () => {
    const i = generateInstallation()!;
    const back = decodeInstallation(encodeInstallation(i))!;
    expect(toHex(deviceIdFor(back.keys, rootId)!)).toBe(toHex(deviceIdFor(i.keys, rootId)!));
    expect(toHex(back.rendezvousSeed)).toBe(toHex(i.rendezvousSeed));
  });

  test("the installation's route is its seed's route", async () => {
    // §10.2 keeps them in ONE record because they share a lifetime: regenerating the keys while
    // keeping the seed would leave a new device answering at the old address.
    const i = generateInstallation()!;
    expect(await installationRoute(i)).toEqual(await deriveRendezvous(i.rendezvousSeed));
  });
});

describe("loading and creating, independent of storage", () => {
  const outcome = (r: Awaited<ReturnType<typeof loadOrCreateInstallation>>): string =>
    r.ok ? r.state : r.failure;

  test("an empty store creates and persists", async () => {
    const backend = new MemoryInstallationBackend();
    const first = await loadOrCreateInstallation(backend);
    expect(outcome(first)).toBe("created");
    expect(backend.writes).toBe(1);

    // PAIRED: a store that never wrote would satisfy the first assertion, and one that wrote every
    // time would satisfy neither this nor the identity comparison below.
    const second = await loadOrCreateInstallation(backend);
    expect(outcome(second)).toBe("loaded");
    expect(backend.writes).toBe(1);
    if (!first.ok || !second.ok) return;
    expect(toHex(encodeInstallation(second.installation)))
      .toBe(toHex(encodeInstallation(first.installation)));
  });

  // THE DECISION THIS EXISTS FOR. Something is stored and it is not a record; overwriting it
  // generates a new device and silently abandons every grant the old one held.
  test("an unreadable record is refused and left alone", async () => {
    const junk = new TextEncoder().encode("not an installation record at all, but as long");
    const backend = new MemoryInstallationBackend(junk);
    expect(outcome(await loadOrCreateInstallation(backend))).toBe("unreadable-record");
    expect(backend.stored).toBe(junk);
    expect(backend.writes).toBe(0);
  });

  test("an empty store is not an unreadable one", async () => {
    // Different outcomes that must not collapse: one is a device that has never run, the other is a
    // device whose identity is in trouble.
    expect(outcome(await loadOrCreateInstallation(new MemoryInstallationBackend()))).toBe("created");
    expect(outcome(await loadOrCreateInstallation(
      new MemoryInstallationBackend(new Uint8Array(0))))).toBe("unreadable-record");
  });

  test("a failed write is a failure, not an identity", async () => {
    expect(outcome(await loadOrCreateInstallation(new ReadOnlyInstallationBackend())))
      .toBe("write-failed");
  });

  test("a refusing CSPRNG is reported rather than papered over", async () => {
    const backend = new MemoryInstallationBackend();
    const outcomeString = outcome(await loadOrCreateInstallation(backend, () => {
      throw new Error("no CSPRNG available");
    }));
    expect(outcomeString).toBe("generation-failed");
    expect(backend.stored).toBeNull();
  });

  test("destroy is the only path that discards keys, and what returns is a new device", async () => {
    const backend = new MemoryInstallationBackend();
    const made = await loadOrCreateInstallation(backend);
    expect(await destroyInstallation(backend)).toBe(true);
    expect(backend.stored).toBeNull();

    const remade = await loadOrCreateInstallation(backend);
    expect(outcome(remade)).toBe("created");
    if (!made.ok || !remade.ok) return;
    // §10.2: "generating new keys and enrolling again, not reconstructing the old device" — and
    // §10.2 again: "reinstallation generates BOTH anew", address included.
    expect(toHex(remade.installation.keys.signingPrivateKey))
      .not.toBe(toHex(made.installation.keys.signingPrivateKey));
    expect(toHex(remade.installation.rendezvousSeed))
      .not.toBe(toHex(made.installation.rendezvousSeed));
  });

  test("a round trip survives a restart", async () => {
    const backend = new MemoryInstallationBackend();
    const made = await loadOrCreateInstallation(backend);
    // A "restart": a brand-new backend over the same bytes, which is all a restart is.
    const afterRestart = new MemoryInstallationBackend(backend.stored);
    const loaded = await loadOrCreateInstallation(afterRestart);
    expect(outcome(loaded)).toBe("loaded");
    if (!made.ok || !loaded.ok) return;
    expect(await installationRoute(loaded.installation))
      .toEqual(await installationRoute(made.installation));
  });
});
