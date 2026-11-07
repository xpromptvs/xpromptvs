import "fake-indexeddb/auto";
import { beforeEach, describe, expect, test } from "vitest";
import {
  decodeInstallation, encodeInstallation, generateInstallation, loadOrCreateInstallation,
} from "@rdev/protocol";
import { IndexedDBInstallationBackend } from "../src/lib/installation-idb";

// §10.2's "browser keys use durable local storage appropriate to the runtime".
//
// The decisions live in `@rdev/protocol`; what is exercised here is the PLUMBING — and specifically
// the two places it must not confuse "nothing stored" with "something wrong", because the protocol
// layer turns the first into a brand-new device and the second into a refusal.
const toHex = (u: Uint8Array): string => [...u].map((b) => b.toString(16).padStart(2, "0")).join("");

async function wipe(): Promise<void> {
  await new Promise<void>((resolve) => {
    const r = indexedDB.deleteDatabase("rdev-e2e");
    r.onsuccess = () => { resolve(); };
    r.onerror = () => { resolve(); };
    r.onblocked = () => { resolve(); };
  });
}

describe("the IndexedDB backend", () => {
  beforeEach(wipe);

  test("an empty database reads as null, which is what makes a fresh identity", async () => {
    expect(await new IndexedDBInstallationBackend().read()).toBeNull();
  });

  test("a written record reads back byte for byte", async () => {
    const backend = new IndexedDBInstallationBackend();
    const installation = generateInstallation()!;
    const bytes = encodeInstallation(installation);
    expect(await backend.write(bytes)).toBe(true);

    // A SECOND backend object, which is what a page reload is.
    const read = await new IndexedDBInstallationBackend().read();
    expect(read).not.toBeNull();
    expect(toHex(read!)).toBe(toHex(bytes));
    expect(decodeInstallation(read!)).not.toBeNull();
  });

  test("delete removes it, and the next read is null rather than an error", async () => {
    const backend = new IndexedDBInstallationBackend();
    await backend.write(encodeInstallation(generateInstallation()!));
    expect(await backend.delete()).toBe(true);
    expect(await backend.read()).toBeNull();
  });

  test("deleting nothing succeeds", async () => {
    // Already absent is the outcome the caller asked for.
    expect(await new IndexedDBInstallationBackend().delete()).toBe(true);
  });

  // THE CONFUSION THIS BACKEND MUST NOT MAKE. Something is stored and it is not bytes — another
  // build's value, a partially migrated record. Handing back `null` would tell the protocol layer
  // the store is empty and it would overwrite it with a new device, abandoning every grant the old
  // one held. An empty array reaches `unreadable-record` instead, which stops and says so.
  test("a stored value that is not bytes never reads as an empty store", async () => {
    await new Promise<void>((resolve, reject) => {
      const open = indexedDB.open("rdev-e2e", 1);
      open.onupgradeneeded = () => { open.result.createObjectStore("installation"); };
      open.onsuccess = () => {
        const db = open.result;
        const tx = db.transaction("installation", "readwrite");
        tx.objectStore("installation").put({ something: "else" }, "v1");
        tx.oncomplete = () => { db.close(); resolve(); };
        tx.onerror = () => { db.close(); reject(tx.error); };
      };
      open.onerror = () => { reject(open.error); };
    });

    const read = await new IndexedDBInstallationBackend().read();
    expect(read).not.toBeNull();
    expect(read!.length).toBe(0);

    const outcome = await loadOrCreateInstallation(new IndexedDBInstallationBackend());
    expect(outcome.ok ? outcome.state : outcome.failure).toBe("unreadable-record");
  });

  test("an ArrayBuffer round trip is read as bytes", async () => {
    // Structured clone can hand back an ArrayBuffer where a Uint8Array went in, depending on the
    // engine; both are the record, and neither is "nothing stored".
    const bytes = encodeInstallation(generateInstallation()!);
    await new Promise<void>((resolve, reject) => {
      const open = indexedDB.open("rdev-e2e", 1);
      open.onupgradeneeded = () => { open.result.createObjectStore("installation"); };
      open.onsuccess = () => {
        const db = open.result;
        const tx = db.transaction("installation", "readwrite");
        tx.objectStore("installation").put(bytes.buffer.slice(0), "v1");
        tx.oncomplete = () => { db.close(); resolve(); };
        tx.onerror = () => { db.close(); reject(tx.error); };
      };
      open.onerror = () => { reject(open.error); };
    });
    const read = await new IndexedDBInstallationBackend().read();
    expect(toHex(read!)).toBe(toHex(bytes));
  });
});

describe("through the protocol layer, end to end", () => {
  beforeEach(wipe);

  test("first run creates, second run loads the same identity", async () => {
    const first = await loadOrCreateInstallation(new IndexedDBInstallationBackend());
    expect(first.ok && first.state).toBe("created");

    const second = await loadOrCreateInstallation(new IndexedDBInstallationBackend());
    expect(second.ok && second.state).toBe("loaded");
    if (!first.ok || !second.ok) return;
    expect(toHex(encodeInstallation(second.installation)))
      .toBe(toHex(encodeInstallation(first.installation)));
  });

  test("clearing site data is key loss, and what comes back is a different device", async () => {
    // §10.2 through a browser menu rather than a failed disk.
    const first = await loadOrCreateInstallation(new IndexedDBInstallationBackend());
    await wipe();
    const second = await loadOrCreateInstallation(new IndexedDBInstallationBackend());
    expect(second.ok && second.state).toBe("created");
    if (!first.ok || !second.ok) return;
    expect(toHex(second.installation.keys.signingPrivateKey))
      .not.toBe(toHex(first.installation.keys.signingPrivateKey));
  });
});

describe("first creation over the REAL backend is single-flight", () => {
  beforeEach(wipe);

  // What the page actually does: every caller builds its OWN `ClientE2EIdentity` with its OWN
  // `IndexedDBInstallationBackend` objects, so only the store's NAME can say "same store". Before
  // `storeName` + the per-store lock, these interleaved and each minted a key set.
  test("six identity objects loading at once over one empty database agree on ONE key set", async () => {
    const { ClientE2EIdentity } = await import("../src/client/e2e-identity");
    const config = { rpId: "localhost", rpName: "Xpromptvs" };
    const loads = await Promise.all(Array.from({ length: 6 }, () =>
      new ClientE2EIdentity(undefined, undefined, config, "http://localhost:8787").load()));
    const keys = new Set(loads.map((l) =>
      "kind" in l ? "blocked" : toHex(l.installation.keys.signingPrivateKey)));
    expect(keys.size).toBe(1);
    expect(keys.has("blocked")).toBe(false);
    const stored = decodeInstallation((await new IndexedDBInstallationBackend().read())!)!;
    expect(keys.has(toHex(stored.keys.signingPrivateKey))).toBe(true);
  });
});
