import type { InstallationBackend } from "@rdev/protocol";

/// IndexedDB behind `InstallationBackend` — §10.2's "browser keys use durable local storage
/// appropriate to the runtime".
///
/// Every decision worth making about the installation record is in `@rdev/protocol`'s
/// `loadOrCreateInstallation`; this is the thin part that actually talks to the database.
///
/// **IndexedDB rather than `localStorage`, for two reasons that both matter.** It stores a
/// `Uint8Array` as bytes instead of forcing a base64 round trip through a string, and — the real
/// one — `localStorage` in this client is documented as a per-viewer CONVENIENCE whose loss is
/// nothing: `pointer-mode.ts` and the playout-window memory both treat a missing value as "start
/// from the default". A device identity is the opposite; losing it costs every grant the device
/// holds. Keeping them in the same store invites the same casual clearing.
///
/// **IT IS STILL ORIGIN-SCOPED AND SCRIPT-READABLE**, and that is not a gap this file can close.
/// Noise needs the raw X25519 scalar, so a non-extractable `CryptoKey` cannot serve, and any script
/// on the origin can read what any other script wrote. §6 already assumes honest frontend code and
/// says what the protocol does and does not buy under that assumption: "it does not buy protection
/// against a hostile bundle served at the moment of connection." A browser device key is worth
/// exactly as much as the bundle that reads it.
///
/// **Clearing site data destroys the identity.** That is §10.2's "private-key loss means generating
/// new keys and enrolling again", arriving through a browser menu rather than a failed disk.
const DATABASE = "rdev-e2e";
const STORE = "installation";
/// §10.2 keeps the keys and the trust record APART on purpose — the keys are bound to the
/// rendezvous seed, the trust is learned later — so they are two entries, never one blob. One store
/// because they share a lifetime: clearing site data takes both, which is what §10.2 calls
/// "private-key loss", and a half-cleared identity would be worse than none.
export const INSTALLATION_KEY = "v1";
export const TRUST_KEY = "trust-v1";

/// §10.1 route 1: "Local passkey creation: **retain the registration public key and credential ID**".
///
/// **RETAINED CREATION MATERIAL, NOT A TRUSTED ROOT.** It is not in the trust record, no grant
/// references it and nothing verifies against it. It exists so that a passkey created but never
/// committed can be resumed instead of stranded: WebAuthn returns `root_public_key` only at
/// creation, so a descriptor dropped here cannot be rebuilt by anyone, ever — not by this browser,
/// not by the Worker, not by a later assertion.
///
/// A third entry rather than a field on the trust record, because the trust record is a versioned
/// encoding held to fixtures in two languages and this is one browser's private note to itself.
export const PENDING_KEY = "pending-v1";

function open (): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
    };
    request.onsuccess = () => { resolve(request.result); };
    request.onerror = () => { reject(request.error ?? new Error("indexedDB.open failed")); };
    // A private window with storage disabled, or a second tab holding an upgrade, both surface here
    // rather than as an error — so they must not hang the caller forever.
    request.onblocked = () => { reject(new Error("indexedDB.open blocked")); };
  });
}

async function transact<T> (mode: IDBTransactionMode,
                            body: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open();
  try {
    return await new Promise<T>((resolve, reject) => {
      const tx = db.transaction(STORE, mode);
      const request = body(tx.objectStore(STORE));
      request.onsuccess = () => { resolve(request.result); };
      request.onerror = () => { reject(request.error ?? new Error("indexedDB request failed")); };
      tx.onabort = () => { reject(tx.error ?? new Error("indexedDB transaction aborted")); };
    });
  } finally {
    db.close();
  }
}

export class IndexedDBInstallationBackend implements InstallationBackend {
  /// Which entry this backend owns. Defaulted so every existing caller keeps the installation, and
  /// named so the trust record cannot land on top of it by omission.
  constructor (private readonly key: string = INSTALLATION_KEY) {}

  /// **WHICH STORE THIS IS, as a name two backend OBJECTS agree on.** Every caller builds its own
  /// backend over the one database, so object identity cannot say "same store" — and
  /// `ClientE2EIdentity` single-flights first creation per store (`storeName` → its lock), which is
  /// what stops two read-then-writes each minting a key set (the web twin of 8a7f7fb1).
  get storeName (): string { return `${DATABASE}/${this.key}`; }

  /// Null for "nothing stored", which is what makes a fresh identity. **A FAILURE MUST NOT LOOK
  /// LIKE THAT**, so anything that throws is re-thrown: reading "no identity" out of a broken
  /// database would generate a new device and abandon the grants of the one already there.
  async read (): Promise<Uint8Array | null> {
    const value = await transact<unknown>("readonly", (s) => s.get(this.key) as IDBRequest<unknown>);
    if (value === undefined || value === null) return null;

    // **NOT `instanceof`** — a structural check, because `instanceof` compares constructors rather
    // than shapes and a structured clone may hand back an object from another realm.
    //
    // **HONEST ABOUT WHERE THAT BITES**, since an earlier version of this comment overstated it:
    // `fake-indexeddb` returns a cross-realm array (`constructor.name === "Uint8Array"`,
    // `instanceof` FALSE) and caught the first version of this method — but `e2e/installation-store
    // -check.mjs` measured real Chromium and real WebKit, and both return `instanceof === true`. So
    // this is not a browser hazard today; it is a correctness property that costs nothing, holds in
    // both, and covers the genuinely cross-realm cases (an iframe, a worker) as well as the shim.
    //
    // Getting it wrong is the one mistake this method must never make: the protocol layer above
    // turns "nothing stored" into a brand new device and abandons every grant the old one held.
    if (ArrayBuffer.isView(value)) {
      const view = value as ArrayBufferView;
      return new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
    }
    if (Object.prototype.toString.call(value) === "[object ArrayBuffer]") {
      return new Uint8Array(value as ArrayBuffer);
    }
    // Something is stored and it is genuinely not bytes. Handing back null would overwrite it; the
    // protocol layer's `unreadable-record` is the honest outcome, and an empty array reaches it.
    return new Uint8Array(0);
  }

  async write (bytes: Uint8Array): Promise<boolean> {
    try {
      await transact("readwrite", (s) => s.put(bytes, this.key) as IDBRequest<unknown>);
      return true;
    } catch {
      return false;
    }
  }

  async delete (): Promise<boolean> {
    try {
      await transact("readwrite", (s) => s.delete(this.key) as IDBRequest<unknown>);
      return true;
    } catch {
      return false;
    }
  }
}
