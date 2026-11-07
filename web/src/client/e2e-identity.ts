import {
  adoptRoot, commitOwnChain, decodeTrustRecord, deviceId as hashDevice, parseGrant,
  descriptor as descriptorFor, emptyTrustRecord, encodeTrustRecord, grantCommitmentPreimage,
  IssuerKind, loadOrCreateInstallation,
  nextActionForRecord, noisePublicKey, parseBundle, parseRoot, rootId as hashRoot,
  signingPublicKey, verifyBundle, verifyDiscoveredRoot,
  PublicationStatus,
  type Installation, type InstallationBackend, type TrustRecord,
} from "@rdev/protocol";
import { base64urlDecode, base64urlEncode } from "../lib/base64url";
import { IndexedDBInstallationBackend, INSTALLATION_KEY, PENDING_KEY, TRUST_KEY } from "../lib/installation-idb";
import { issueDirectGrant } from "../lib/e2e-grant";
import { registerDirectoryGrant, type DirectoryIdentity } from "../lib/directory-api";
import { ceremonyOrigin } from "../lib/signaling-base";
import { policyFor } from "../lib/product-origin";
import type { CredentialLookup } from "../lib/credential-lookup";
import { createRoot, discoverRoot, rootCheck, signalUnknownCredential }
  from "./webauthn-ceremony";
import type { CeremonyConfig } from "./webauthn-ceremony";
import type { ClientGateConfig, HostGateConfig } from "@rdev/protocol";

/**
 * **The browser's E2E identity** — the counterpart of `RdevHostKit.E2EHostIdentity`, and the same
 * four things travelling together: keys, a trust record, the origin that may run a ceremony, and
 * §10.1's policy derived from it.
 *
 * **THE BROWSER ENROLS ITSELF, IN PLACE**: the page IS the relying party's origin, so it runs the
 * passkey ceremony itself and writes the result to its own storage. (The Mac does the same since
 * 2026-10-06, through the platform's passkey API — `E2EPasskeyCeremony.swift`.)
 *
 * The ORIGIN is `location.origin` and is not configurable, which is the browser's version of the
 * rule `E2EOrigin` enforces on the Mac: the party that may run a ceremony is not something a server
 * gets to name.
 */

export type ClientIdentityStatus =
  /** Keys exist and no chain does. */
  | { kind: "unenrolled" }
  /** §10.1: a root is being adopted and a PERSON has to name it before the device commits. */
  | { kind: "awaiting-root-confirmation"; rootId: Uint8Array }
  | { kind: "ready"; deviceId: Uint8Array; rootId: Uint8Array }
  /** Something is stored and cannot be read. Overwriting it would abandon an identity. */
  | { kind: "blocked"; reason: string };

export type EnrollFailure =
  | { kind: "storage" }
  | { kind: "not-confirmed" }
  | { kind: "ceremony"; failure: string }
  | { kind: "malformed" }
  | { kind: "unverified"; failure: string }
  /** The shell refused to certify this renderer, and said why (`-not-enrolled`, `-library`, …). */
  | { kind: "shell"; reason: string }
  /** A passkey was asserted and no root descriptor is registered under it. */
  | { kind: "not-found" }
  /** Resume was asked for and this browser retained no descriptor to resume. */
  | { kind: "no-pending" };

/**
 * The shell's §10.3 issuer: base64url of `signing || noise` in, a base64url grant chain out — or a
 * `-`-prefixed reason. The native app's client bridge (`app/Sources/ClientBridge.swift`) exposes
 * exactly this as `__rdevShell.issueGrant`, and a test supplies its own.
 */
export type ShellGrantIssuer = (keysB64: string) => Promise<string>;

export type EnrollResult =
  | { ok: true; status: ClientIdentityStatus }
  | { ok: false; failure: EnrollFailure };

export interface LoadedIdentity {
  installation: Installation;
  record: TrustRecord;
  status: ClientIdentityStatus;
}

/// §10.1's relying party: `xpromptvs.ai` on the product's domain — the apex AND `app.`, so the passkeys
/// made before the client moved still answer — and the page's own host anywhere else (`product-origin.ts`).
const browserCeremony = (): CeremonyConfig => ({ rpId: policyFor(location.origin).rpId, rpName: "Xpromptvs" });

/**
 * The IO this module cannot do without and a test cannot do with: the passkey ceremony, the grant it
 * produces, and the randomness both depend on. Injected as ONE object rather than four parameters,
 * so a caller that fakes any of it has said so in one place.
 */
export interface IdentityEnvironment {
  createRoot: typeof createRoot;
  discoverRoot: typeof discoverRoot;
  rootCheck: typeof rootCheck;
  signalUnknown: typeof signalUnknownCredential;
  issue: typeof issueDirectGrant;
  random: (n: number) => Uint8Array;
}

const LIVE: IdentityEnvironment = {
  createRoot,
  discoverRoot,
  rootCheck,
  signalUnknown: signalUnknownCredential,
  issue: issueDirectGrant,
  random: (n) => crypto.getRandomValues(new Uint8Array(n)),
};

/**
 * **Which of §10.1's routes this enrollment is.**
 *
 * **NO ROUTE ASKS ANY MORE**, and the type is how that is kept true: there is nowhere to put a
 * confirmation, so one cannot be added to a single route by accident. It was once a required
 * parameter on every enrollment, then required on `adopt` alone; the amended §10.1 (see that route
 * below) is why it is now on none of them.
 *
 * - `create` — §10.1 route 1. The authenticator made this root HERE, seconds ago, answering this
 *   page's own ceremony. **No confirmation, and nowhere to put one.** §10.1's MUST is the Residual
 *   indented under route 2, and its hazard is named: a person "can be steered **by the directory**
 *   to one they *do* hold but did not intend to use here". There is no directory here and there was
 *   no choice.
 * - `adopt` — §10.1 route 2. The descriptor arrived from the directory, and **this route asks
 *   nothing either.** §10.1's Residual is about a candidate the DIRECTORY named; our discovery
 *   sends `allowCredentials: []`, the authenticator offers what it holds, the person picks from the
 *   operating system's own list, and the directory is consulted only afterwards about what they
 *   chose. It has no influence over which credential is used, so there is no steering to guard
 *   against — and the identity is stated on completion, with an immediate way to undo it, which is
 *   what the amended §10.1 requires in exchange.
 * - `resume` — §10.1 route 2's FIRST clause, "use a locally trusted descriptor": the retained
 *   creation material of a `create` that never committed. No confirmation, for `create`'s reason —
 *   the descriptor never left this browser.
 */
export type EnrollRoute =
  | { route: "create" }
  | { route: "resume" };

/**
 * **FIRST CREATION IS SINGLE-FLIGHT, PER STORE** — the web twin of 8a7f7fb1's Swift fix.
 *
 * `loadOrCreateInstallation` is a read-then-write, and IndexedDB yields between the two. A fresh app
 * window calls `load()` from five places at mount (`liveDevices`, the directory watch, the header,
 * the Settings panel, the on-open adoption), each through its OWN `ClientE2EIdentity` and its own
 * backend object over ONE store — so two of them could each read "empty", each generate a key set,
 * and the last write win. If the adoption had already sent the first set to the Mac, the trust
 * record certified keys the store no longer held: `ready` forever, and every signed request and
 * connect refused. Unit-tested RED first (`e2e-identity.test.ts`, "SINGLE-FLIGHT").
 *
 * Keyed by the backend's `storeName` when it has one (`IndexedDBInstallationBackend`: every object
 * over one entry agrees on it), else by the backend object itself. Within this realm a promise chain
 * serializes; ACROSS windows of one origin the Web Locks API does, where it exists — two app client
 * windows share one IndexedDB.
 */
const storeKey = (backend: InstallationBackend): unknown => {
  const name = (backend as { storeName?: unknown }).storeName;
  return typeof name === "string" ? name : backend;
};
const creationTails = new Map<unknown, Promise<void>>();
async function exclusive<T> (key: unknown, body: () => Promise<T>): Promise<T> {
  const previous = creationTails.get(key) ?? Promise.resolve();
  let release!: () => void;
  const mine = new Promise<void>((resolve) => { release = resolve; });
  const tail = previous.then(() => mine);
  creationTails.set(key, tail);
  try {
    await previous;
    const locks = (globalThis as { navigator?: { locks?: LockManager } }).navigator?.locks;
    return typeof key === "string" && locks && typeof locks.request === "function"
      ? await locks.request(`rdev-e2e/create:${key}`, body)
      : await body();
  } finally {
    release();
    if (creationTails.get(key) === tail) creationTails.delete(key);
  }
}
/**
 * **ONE ADOPTION IN FLIGHT PER STORE.** The on-open adoption (`welcome.ts`) and a connect's
 * (`main.ts`) run through different identity objects; without this a connect during the first would
 * ask the Mac for a SECOND grant over the same keys. A caller arriving mid-flight gets the same
 * answer; one arriving after finds `ready` and asks for nothing.
 */
const adoptionFlights = new Map<unknown, Promise<EnrollResult>>();

export class ClientE2EIdentity {
  constructor (
    private readonly installations: InstallationBackend = new IndexedDBInstallationBackend(INSTALLATION_KEY),
    private readonly trust: InstallationBackend = new IndexedDBInstallationBackend(TRUST_KEY),
    private readonly config: CeremonyConfig = browserCeremony(),
    private readonly origin: string = location.origin,
    private readonly env: IdentityEnvironment = LIVE,
    /// §10.1 route 1's retained creation material. Appended LAST so every existing positional
    /// construction keeps working. See `PENDING_KEY` for what it is and is not.
    private readonly pending: InstallationBackend = new IndexedDBInstallationBackend(PENDING_KEY),
  ) {}

  /** §10.1's policy, for verifying anything a ceremony or a peer presents — on the product's domain
   *  BOTH origins, since a grant keeps the origin it was signed at for good (`product-origin.ts`). */
  get policy (): { rpId: string; allowedOrigins: string[] } {
    return { rpId: this.config.rpId, allowedOrigins: policyFor(this.origin).allowedOrigins };
  }

  /**
   * Read both records, creating an installation if and only if none exists.
   *
   * **A trust record that EXISTS and cannot be read is `blocked`, never "no trust yet"** — the
   * difference is a browser that has never enrolled against one that has and cannot say so, and
   * only the first should quietly start a ceremony.
   */
  async load (): Promise<LoadedIdentity | { kind: "blocked"; reason: string }> {
    try {
      return await this.read();
    } catch {
      // **STORAGE THAT THROWS IS `blocked`, NOT A REJECTION.** `IndexedDBInstallationBackend.read`
      // re-throws deliberately — a failure must never look like "nothing stored", or the layer
      // above generates a new device and abandons the grants of the one already there — but nothing
      // turned that back into the state this method's own type declares. Every caller treats `load`
      // as value-returning, so a browser with IndexedDB blocked (Safari private mode, blocked site
      // data, a corrupt database) produced an unhandled rejection instead: the session silently
      // never started, and the Settings panel did the same. Measured in jsdom, where there is no
      // `indexedDB` at all.
      return { kind: "blocked", reason: "storage-unavailable" };
    }
  }

  private async read (): Promise<LoadedIdentity | { kind: "blocked"; reason: string }> {
    const outcome = await exclusive(storeKey(this.installations),
                                    () => loadOrCreateInstallation(this.installations, this.env.random));
    if (!outcome.ok) return { kind: "blocked", reason: outcome.failure };

    const installation = outcome.installation;
    let record = emptyTrustRecord();
    const stored = await this.trust.read();
    if (stored !== null) {
      const decoded = decodeTrustRecord(stored);
      if (!decoded) {
        return {
          installation, record,
          status: { kind: "blocked", reason: "unreadable-trust" },
        } as LoadedIdentity;
      }
      record = decoded;
    }
    return { installation, record, status: statusOf(installation, record) };
  }

  /**
   * **The root this browser trusts, or null — WITHOUT creating anything.**
   *
   * `load()` goes through `loadOrCreateInstallation`, which GENERATES this browser's device keys
   * when there are none. That is right for a caller about to use them and wrong for one that only
   * wants to know whether an identity is already here — a connection asking which root to expect
   * must not leave a device identity behind. It reads the trust record and nothing else.
   */
  async trustedRoot (): Promise<Uint8Array | null> {
    try {
      const stored = await this.trust.read();
      if (stored === null) return null;
      return decodeTrustRecord(stored)?.root ?? null;
    } catch {
      // Storage that throws is "no identity here" for this question — the page's other routes
      // still work, and a browser that cannot read its own record certainly cannot offer it.
      return null;
    }
  }

  async status (): Promise<ClientIdentityStatus> {
    const loaded = await this.load();
    return "kind" in loaded ? loaded : loaded.status;
  }

  /**
   * Enrol this browser.
   *
   * The ROUTE is the whole argument — see `EnrollRoute`. **None of them asks anybody anything**:
   * §10.1's Residual is about a candidate the directory named, and this browser's discovery names
   * none, so the identity is stated on completion with sign-out beside it. What the interface must
   * still do is NAME it, and `ClientIdentityStatus.ready` carries the root id for exactly that.
   */
  async enroll (options: EnrollRoute,
                /**
                 * Called once the root passkey EXISTS and before the grant ceremony that follows it.
                 * The create route costs two prompts — a registration returns no signature, so the
                 * grant needs an assertion of its own — and an interface that says nothing here
                 * shows the second prompt under words describing the first.
                 *
                 * Only the `create` route fires it; every other route has one ceremony.
                 *
                 * **AND IT IS AWAITED: the grant's prompt waits for the person to say go.** Safari
                 * refused a `get()` started straight after the `create()` — no prompt at all, the
                 * same `NotAllowedError` as a cancel (2026-10-03, xpromptvs.ai) — while the same
                 * assertion started from a click (Finish setting up) prompted. So the interface
                 * answers this once the person presses Continue, and the prompt starts from that
                 * click. Only `false` (or a promise of it) is "not now": the passkey stays
                 * retained, for Finish setting up.
                 */
                onRootCreated?: () => unknown): Promise<EnrollResult> {
    const loaded = await this.load();
    if ("kind" in loaded) return { ok: false, failure: { kind: "storage" } };
    if (loaded.status.kind === "blocked") return { ok: false, failure: { kind: "storage" } };

    // **An already-trusted root always wins, whatever the route asked for.** §10.1: "An incoming
    // chain is never allowed to replace an already trusted root."
    const adopting = loaded.record.root === null || loaded.record.root === undefined;
    let root = loaded.record.root ?? null;
    let credentialId: Uint8Array;
    /// Whether the retained entry is what is being committed, which decides whether a failure may
    /// discard it. Only a VERIFICATION failure may: "you cancelled" and "no such credential" are
    /// one `NotAllowedError` by design, so discarding on a ceremony failure would destroy the
    /// retention on every dismissal — and the descriptor cannot be rebuilt by anyone.
    let resuming = false;

    if (root !== null) {
      const parsed = parseRoot(root);
      if (!parsed) return { ok: false, failure: { kind: "malformed" } };
      credentialId = parsed.credentialId;
    } else if (options.route === "create") {
      const created = await this.env.createRoot(this.config, this.config.rpId,
                                                this.env.random(16));
      if (!created.ok) return { ok: false, failure: { kind: "ceremony", failure: created.failure } };
      root = created.value.root;
      credentialId = created.value.credentialId;
      // §10.1 route 1: RETAIN. Before the grant, before anything that can fail — WebAuthn returns
      // the public key only at creation, so a drop here is permanent and the passkey becomes one
      // the person has to delete by hand. Best-effort on purpose: this grants no authority, so a
      // failed write costs recoverability and nothing else.
      await this.pending.write(root);
      // AFTER the retention write, so a person is never told the passkey is safe before the thing
      // that makes it recoverable has happened.
      if ((await onRootCreated?.()) === false) {
        return { ok: false, failure: { kind: "ceremony", failure: "dismissed" } };
      }
    } else {
      // §10.1 route 2's FIRST clause — "use a locally trusted descriptor".
      //
      // **ONE CEREMONY, and no separate check.** This used to run `rootCheck` to prove the retained
      // descriptor and then a second ceremony to sign the grant. The grant assertion alone proves
      // it: `verifyBundle` pins the credential id against what the authenticator returned
      // (`verifyAssertion`'s `credential-mismatch`), pins the public key by the signature verifying
      // under it, and pins `hashRoot(root)` against the trusted root id. The one check it does not
      // make is `rp_id` against policy — and that check exists for DISCOVERY, where a Worker supplies
      // the descriptor. This descriptor came from this browser's own `createRoot`, whose `rp_id` is
      // `config.rpId`: there is no untrusted source to pin it against.
      const retained = await this.pending.read();
      const parsed = retained ? parseRoot(retained) : null;
      if (!parsed) return { ok: false, failure: { kind: "no-pending" } };
      root = parsed.bytes;
      credentialId = parsed.credentialId;
      resuming = true;
    }

    const rootIdBytes = hashRoot(root);

    const device = descriptorFor(loaded.installation.keys, rootIdBytes);
    if (!device) return { ok: false, failure: { kind: "malformed" } };

    const issued = await this.env.issue({
      config: this.config, origin: this.origin, root, credentialId, device,
      // §11.1: an ordinary enrollment that is not a resume carries its own random operation id.
      operationId: this.env.random(32),
    });
    if (!issued.ok) {
      // A retained descriptor that does not VERIFY is broken rather than merely unproven, and unlike
      // a dismissed prompt that is grounds to discard it. A ceremony failure never is.
      if (resuming && issued.failure.kind === "unverified") await this.pending.delete();
      return { ok: false, failure: issued.failure.kind === "ceremony"
        ? { kind: "ceremony", failure: issued.failure.failure }
        : issued.failure.kind === "unverified"
          ? { kind: "unverified", failure: issued.failure.failure }
          : { kind: "malformed" } };
    }

    return this.commit(loaded, root, device, issued.bundle, adopting);
  }

  /**
   * **The write, shared by every route that ends in one.**
   *
   * Extracted because `enroll` and `signIn` must not drift: two copies of the verify-adopt-commit
   * sequence is how a browser comes to hold a record one route would have refused. Everything here
   * happens AFTER the last ceremony, so it is the same work whichever prompt produced the bundle.
   */
  private async commit (loaded: LoadedIdentity, root: Uint8Array, device: Uint8Array,
                        bundle: Uint8Array, adopting: boolean): Promise<EnrollResult> {
    const rootIdBytes = hashRoot(root);

    // Verified AGAIN, against the descriptor this browser would actually present. `issueDirectGrant`
    // checks the bundle; this checks that the bundle is THIS DEVICE'S — a chain that verifies for
    // someone else is a perfectly valid grant this browser cannot use.
    const check = verifyBundle(bundle, {
      trustedRootId: rootIdBytes, policy: this.policy,
      revokedDeviceIds: loaded.record.revokedDeviceIds,
    });
    if (!check.ok) return { ok: false, failure: { kind: "unverified", failure: check.failure } };
    if (!sameBytes(check.chain.leafDevice.bytes, device)) {
      return { ok: false, failure: { kind: "unverified", failure: "chain/device-mismatch" } };
    }

    let record = loaded.record;
    if (adopting) {
      const adopted = adoptRoot(record, root);
      if (!adopted.ok) return { ok: false, failure: { kind: "malformed" } };
      record = adopted.record;
    }
    // §12.2: a newly issued grant carries its own status, and nothing here has been published yet.
    const committed = commitOwnChain(record, bundle, PublicationStatus.Unconfirmed, rootIdBytes);
    if (!committed.ok) return { ok: false, failure: { kind: "malformed" } };

    const encoded = encodeTrustRecord(committed.record);
    // §12.3: "an unsuccessful durable write grants no authority."
    if (!encoded || !(await this.trust.write(encoded))) {
      return { ok: false, failure: { kind: "storage" } };
    }
    // The trust record supersedes the retained entry. Unconditional — whichever root committed, a
    // resume route into any other one is now wrong (§10.1: an adopted root is never replaced), so
    // a stale entry from an earlier abandoned attempt dies here too.
    await this.pending.delete();
    return { ok: true, status: statusOf(loaded.installation, committed.record) };
  }

  /**
   * **Sign in with ONE passkey prompt.**
   *
   * This was two methods and two ceremonies until §10.4's commitment landed. The second's challenge
   * was `H(grant)`, and a grant names its root — which a browser signing in learns only from the
   * first — so the bytes the second prompt signed could not be assembled until the first had said
   * which credential answered. That is a data dependency, not an ordering choice, and it is why
   * reordering never helped. The commitment removed the root from the signed bytes, so the single
   * `get({ allowCredentials: [] })` that identifies the credential IS the grant's signature.
   *
   * §10.1's root is a discoverable credential, so the authenticator is asked which roots it holds
   * for this relying party with no username, no email and no account — the whole of what replaced
   * OAuth sign-in. The person picks one in the browser's own prompt.
   *
   * **An assertion returns no public key**, so the descriptor is fetched from the authenticator's
   * blob or the Control Plane, and `verifyDiscoveredRoot` pins every field of it — credential id,
   * public key and, the check `verifyBundle` does not need, the `rp_id` — against the assertion and
   * against local policy. A Worker that substitutes any of them is refused.
   *
   * §10.1's naming obligation is discharged afterwards, on the success screen: the Residual's hazard
   * is a candidate the DIRECTORY named, and `allowCredentials: []` means it named none.
   *
   * **`stranded` IS AN INVITATION TO ASK, NOT A VERDICT.** Merging discovery and grant issuance put
   * four different failures behind one call, and only one of them may raise the subject of deleting
   * a passkey: a definite `absent` from the credential index. A dismissed prompt proves nothing; a
   * descriptor that came back and would not verify is grounds to distrust the ANSWER, never evidence
   * the credential is unused; and a grant this browser could not assemble is about this browser. The
   * offer is destructive and permanent, so three of the four stay silent.
   */
  async signIn (lookup: (credentialId: Uint8Array) => Promise<CredentialLookup>):
    Promise<EnrollResult & { stranded: boolean; credentialId?: Uint8Array }> {
    const loaded = await this.load();
    if ("kind" in loaded || loaded.status.kind === "blocked") {
      return { ok: false, failure: { kind: "storage" }, stranded: false };
    }

    // Everything the commitment covers, fixed BEFORE the ceremony — §17.1's freezing requirement,
    // and here it is structural: these are the bytes about to be signed.
    const operationId = this.env.random(32);
    const binding = { kind: "local" as const, randomness: this.env.random(32) };
    const keys = loaded.installation.keys;
    const preimage = grantCommitmentPreimage({
      operationId, issuerKind: IssuerKind.Root,
      signingPublicKey: signingPublicKey(keys), noisePublicKey: noisePublicKey(keys),
      capabilities: 7, binding,
    });
    if (!preimage) return { ok: false, failure: { kind: "malformed" }, stranded: false };

    // **THE ONLY CEREMONY.** Its challenge is the commitment, so this one assertion answers "which
    // passkey?" and signs the grant.
    const asserted = await this.env.discoverRoot(this.config, preimage);
    if (!asserted.ok) {
      return { ok: false, failure: { kind: "ceremony", failure: asserted.failure },
               stranded: false };
    }

    // §4: the authenticator may be carrying the descriptor itself. **A SECOND SOURCE, NOT A SECOND
    // TRUST PATH** — whichever answers, the verification below pins the credential id, the public
    // key and the rp_id, so a blob is believed for exactly the reasons the Worker's answer is. What
    // it buys is that the Worker need not be reachable, or remember.
    const carried = asserted.value.blob;
    const usable = carried !== null && parseRoot(carried) !== null ? carried : null;
    const credentialId = asserted.value.credentialId;
    const answer = usable ? null : await lookup(credentialId);
    const root = usable ?? (answer?.kind === "found" ? answer.root : null);
    if (!root) {
      // The one outcome that may raise deletion: the Worker looked and holds nothing. Still not
      // evidence — the index is best-effort and a Mac enrolled during an outage answers identically
      // — so the PERSON decides, knowing things this code cannot.
      return { ok: false, failure: { kind: "not-found" }, credentialId,
               stranded: answer?.kind === "absent" };
    }

    const check = (candidate: Uint8Array) => verifyDiscoveredRoot({
      root: candidate, assertion: asserted.value.assertion, preimage, policy: this.policy,
    });
    let verified = check(root);
    // **A BLOB GETS NO LAST WORD.** It is bytes anyone holding the credential could have written, so
    // one that fails must not deny service to an identity the Worker could have named. Tried once,
    // and only in this direction: a Worker answer that fails has no second source to fall back to.
    if (!verified.ok && usable !== null) {
      const fetched = await lookup(credentialId);
      if (fetched.kind !== "found") {
        return { ok: false, failure: { kind: "unverified", failure: verified.failure },
                 credentialId, stranded: fetched.kind === "absent" };
      }
      verified = check(fetched.root);
    }
    if (!verified.ok) {
      return { ok: false, failure: { kind: "unverified", failure: verified.failure },
               credentialId, stranded: false };
    }

    // **§10.1: "An incoming chain is never allowed to replace an already trusted root."** A browser
    // holding one is not choosing here, whatever the authenticator offered — and unlike `enroll`,
    // which silently issues under the root it already has, refusing is the honest answer: the person
    // just picked a passkey, and quietly enrolling a different identity than the one they chose
    // would be the same surprise in the opposite direction.
    //
    // In practice the panel offers sign-in only to a browser that holds nothing, so this is the
    // invariant rather than a path. It is checked anyway: "offered only when" is a property of one
    // caller, and this is the function that must not be able to do it.
    const trusted = loaded.record.root ?? null;
    const adopting = trusted === null;
    if (trusted !== null && !sameBytes(trusted, verified.root.bytes)) {
      return { ok: false, failure: { kind: "unverified", failure: "root-replacement" },
               stranded: false };
    }

    const device = descriptorFor(keys, verified.rootId);
    if (!device) return { ok: false, failure: { kind: "malformed" }, stranded: false };

    // The SAME assembly every other route uses, handed the assertion that already exists. A second
    // ceremony here would be the prompt this method was written to remove.
    const issued = await this.env.issue({
      config: this.config, origin: this.origin, root: verified.root.bytes,
      credentialId, device, operationId,
      preAsserted: { binding, assertion: asserted.value.assertion },
    });
    if (!issued.ok) {
      // The identity WAS found; a failure here is about this browser's own grant. No offer.
      return { ok: false, stranded: false,
               failure: issued.failure.kind === "ceremony"
                 ? { kind: "ceremony", failure: issued.failure.failure }
                 : issued.failure.kind === "unverified"
                   ? { kind: "unverified", failure: issued.failure.failure }
                   : { kind: "malformed" } };
    }

    const committed = await this.commit(loaded, verified.root.bytes, device, issued.bundle,
                                        adopting);
    return { ...committed, stranded: false };
  }

  /**
   * **Adopt an identity this renderer cannot enrol itself for (§10.3, `root → A → B`).**
   *
   * The native app's client window runs at `app://client/`, an origin no passkey ceremony can run in
   * (§2, profile P-A). So it generates keys like any other device and asks the app — which holds a
   * direct grant, and therefore `enroll` — to certify them as a connect-only device.
   *
   * **Why this names nothing at all, where the browser's own routes at least state the identity.**
   * The person already named it — in the app's own enrollment row, on the Mac this renderer is part
   * of, which is §12.1's confirmation and still happens BEFORE that Mac commits. Stating it again
   * would be telling the same person about the same identity twice, for a device they cannot see
   * separately from the app.
   *
   * What is NOT skipped is verification: the returned chain is checked against the policy, and its
   * leaf must carry the two keys this renderer generated. A chain that certifies someone else is a
   * valid grant this window cannot use.
   *
   * Idempotent: a renderer that is already `ready` asks for nothing.
   */
  async adoptFromShell (issue: ShellGrantIssuer): Promise<EnrollResult> {
    const key = storeKey(this.installations);
    const inFlight = adoptionFlights.get(key);
    if (inFlight) return await inFlight;
    const flight = this.adoptFromShellOnce(issue);
    adoptionFlights.set(key, flight);
    try {
      return await flight;
    } finally {
      if (adoptionFlights.get(key) === flight) adoptionFlights.delete(key);
    }
  }

  private async adoptFromShellOnce (issue: ShellGrantIssuer): Promise<EnrollResult> {
    const loaded = await this.load();
    if ("kind" in loaded) return { ok: false, failure: { kind: "storage" } };
    if (loaded.status.kind === "blocked") return { ok: false, failure: { kind: "storage" } };
    if (loaded.status.kind === "ready") return { ok: true, status: loaded.status };

    const keys = loaded.installation.keys;
    const material = new Uint8Array(64);
    material.set(signingPublicKey(keys), 0);
    material.set(noisePublicKey(keys), 32);

    const answer = await issue(base64urlEncode(material));
    // A refusal is an ANSWER, not an exception: "this Mac is not enrolled" is a state a person can
    // fix, and it must not read the same as a broken bridge.
    if (answer.startsWith("-")) return { ok: false, failure: { kind: "shell", reason: answer } };
    const bundle = base64urlDecode(answer);
    if (!bundle) return { ok: false, failure: { kind: "malformed" } };

    // The root is whatever the chain carries. Taking it from the bundle rather than asking for it
    // separately is not a shortcut: a root that disagreed with the chain would fail the very next
    // check, so a second channel could only ever add a way for the two to disagree.
    const parsed = parseBundle(bundle);
    if (!parsed.ok) return { ok: false, failure: { kind: "malformed" } };
    const root = parsed.bundle.root;
    const rootIdBytes = hashRoot(root);

    const device = descriptorFor(keys, rootIdBytes);
    if (!device) return { ok: false, failure: { kind: "malformed" } };

    const check = verifyBundle(bundle, {
      trustedRootId: rootIdBytes, policy: this.policy,
      revokedDeviceIds: loaded.record.revokedDeviceIds,
    });
    if (!check.ok) return { ok: false, failure: { kind: "unverified", failure: check.failure } };
    if (!sameBytes(check.chain.leafDevice.bytes, device)) {
      return { ok: false, failure: { kind: "unverified", failure: "chain/device-mismatch" } };
    }
    // §10.3: a subordinate may not carry `enroll`, and `authorityIsWellFormed` refuses to encode
    // one — so a chain arriving here with it is malformed rather than over-privileged. Asserted
    // anyway, because this is the one place a renderer's authority is decided.
    if ((check.chain.leaf.capabilities & 4) !== 0) {
      return { ok: false, failure: { kind: "unverified", failure: "grant/capabilities" } };
    }

    let record = loaded.record;
    if (record.root === null || record.root === undefined) {
      const adopted = adoptRoot(record, root);
      if (!adopted.ok) return { ok: false, failure: { kind: "malformed" } };
      record = adopted.record;
    }
    const committed = commitOwnChain(record, bundle, PublicationStatus.Unconfirmed, rootIdBytes);
    if (!committed.ok) return { ok: false, failure: { kind: "malformed" } };

    const encoded = encodeTrustRecord(committed.record);
    // §12.3: "an unsuccessful durable write grants no authority."
    if (!encoded || !(await this.trust.write(encoded))) {
      return { ok: false, failure: { kind: "storage" } };
    }
    return { ok: true, status: statusOf(loaded.installation, committed.record) };
  }

  /** What §12.2's signed requests are made with — this device's chain and signing key — or null with no
   *  committed chain. The dashboard's listing and a connection following its Mac (`host-follow.ts`) both read
   *  it here, so the two can never ask under different identities. */
  async directoryIdentity (): Promise<DirectoryIdentity | null> {
    const loaded = await this.load();
    if ("kind" in loaded) return null;
    const { installation, record } = loaded;
    if (!record.root || !record.bundle) return null;
    return { root: record.root, bundle: record.bundle,
             signingPrivateKey: installation.keys.signingPrivateKey };
  }

  /**
   * **Make this browser's root discoverable, once.**
   *
   * §12.2's directory indexes `credential_id -> root descriptor` the first time a `DirectoryDO`
   * learns its root, which is the first SIGNED request of any kind — a `list` included. So a browser
   * that opens the dashboard is already discoverable, and what this covers is the one that enrols
   * MID-SESSION and never opens it, plus the general principle that a device should not rely on a
   * read to publish it.
   *
   * **Guarded by the stored publication status, which is exactly what it is for.** A record that is
   * already `confirmed` needs no traffic; one that is not tries again, and §12.2's idempotence on
   * `(root_id, operation_id)` — with the leaf grant's OWN operation id — makes the retry free. That
   * is what lets a browser enrolled before this existed heal itself on the next visit rather than
   * needing to be enrolled again.
   *
   * **NEVER FAILS ANYTHING.** §12.2: publication is best-effort and not a precondition for access.
   * A false here costs discovery from a second browser and costs this one nothing.
   */
  async registerWithDirectory (
    base: string,
    register: typeof registerDirectoryGrant = registerDirectoryGrant,
  ): Promise<boolean> {
    const loaded = await this.load();
    if ("kind" in loaded) return false;
    const { installation, record } = loaded;
    if (!record.root || !record.bundle) return false;
    if (record.publicationStatus === PublicationStatus.Confirmed) return true;

    const parsed = parseBundle(record.bundle);
    if (!parsed.ok) return false;
    const leaf = parsed.bundle.certificates[parsed.bundle.certificates.length - 1];
    const grant = leaf ? parseGrant(leaf.grant) : null;
    if (!grant) return false;

    const ok = await register(base, {
      root: record.root, bundle: record.bundle,
      signingPrivateKey: installation.keys.signingPrivateKey,
    }, grant.operationId);
    if (!ok) return false;

    // §12.2's status is monotonic toward `confirmed`, and this endpoint HOLDS the publication job —
    // which is the one case allowed to lower or raise it.
    const committed = commitOwnChain(record, record.bundle, PublicationStatus.Confirmed,
                                     hashRoot(record.root));
    if (!committed.ok) return true;        // registered; only the note about it failed
    const encoded = encodeTrustRecord(committed.record);
    if (encoded) await this.trust.write(encoded);
    return true;
  }

  /**
   * **Forget this browser's identity — the "sign out" a passkey-only product can actually offer.**
   *
   * BOTH records, and the keys are the reason. Deleting only the trust record would leave a browser
   * whose Noise static and signing key were certified under the old root and are about to be
   * certified under a new one — the same public key appearing in two identities, which is a stable
   * correlator any Host on either side can see. Signing out is meant to make this browser stop being
   * the one it was, and half of it would not.
   *
   * **IT REVOKES NOTHING, and that is not a shortcut.** §10.5's revocation is a root-signed act that
   * needs the passkey; this deletes the private keys the grant was issued FOR, which ends this
   * browser's use of it without asserting anything to anyone. The interface has to say so — a person
   * who reads "sign out" as "remove this browser from my identity" would be wrong about a copy of
   * the storage taken beforehand, and about what a directory still lists.
   *
   * Order is deliberate: the KEYS go first. If the second delete fails, what is left is a trust
   * record with no keys — §12.4's `keys-lost`, which answers "generate new keys and enrol again" —
   * rather than a usable identity a failed sign-out left behind.
   */
  /**
   * Is there retained creation material to resume (§10.1 route 1)?
   *
   * A boolean rather than the descriptor: the panel decides whether to OFFER a route, and handing
   * it the bytes would invite a second place that parses them — which is how two readers of one
   * record come to disagree about what it says.
   */
  async hasPendingRoot (): Promise<boolean> {
    try {
      const retained = await this.pending.read();
      return retained !== null && parseRoot(retained) !== null;
    } catch {
      // Storage that throws is "no offer", never a crash on the panel's first paint.
      return false;
    }
  }

  /**
   * **Delete a passkey this browser made and never finished with.**
   *
   * The destructive act, and the ONLY trigger for it that can be certain. `signalUnknownCredential`
   * deletes the credential silently and permanently on Apple platforms (measured; see the ceremony
   * module), so being wrong here destroys user property and every grant a root ever issued.
   *
   * **Why this case is knowledge rather than inference.** A retained descriptor means this browser
   * ran the creation ceremony itself; no grant was ever issued for it, because one would have
   * committed and cleared the entry; and the Worker was never told, because registration is
   * post-commit. Nothing anywhere can be holding it. Contrast the tempting trigger — a `404` from
   * `GET /credential/<id>` — which proves nothing at all: that index is best-effort, so a root in
   * daily use on a Mac produces the identical answer, and §12.2 is explicit that absence is never
   * revocation.
   *
   * **ORDER IS THE SAFETY PROPERTY.** Signal first, clear second. Clearing first and then failing to
   * signal manufactures exactly the unrecoverable orphan this feature exists to prevent — a passkey
   * in the keychain with the only record of it gone. The reverse failure is harmless: a resume offer
   * for a credential that is no longer there, which fails and self-heals at the next commit.
   */
  async discardPendingRoot (): Promise<{ ok: true } | { ok: false; reason: string }> {
    const loaded = await this.load();
    if ("kind" in loaded) return { ok: false, reason: "storage" };
    // A committed identity is not a stranded passkey, whatever is left lying in the pending entry —
    // and the entry CAN outlive a commit, if the clear that follows it failed.
    if (loaded.record.root) return { ok: false, reason: "holds-identity" };

    const retained = await this.pending.read();
    const parsed = retained ? parseRoot(retained) : null;
    if (!parsed) return { ok: false, reason: "no-pending" };

    const outcome = await this.env.signalUnknown(this.config.rpId, parsed.credentialId);
    if (outcome !== "signalled") return { ok: false, reason: outcome };

    // The passkey is gone; this is bookkeeping. A failed clear leaves a resume offer that cannot
    // work and dies at the next commit, which is not worth reporting as a failed deletion.
    await this.pending.delete();
    return { ok: true };
  }

  /**
   * **Delete a passkey no identity could be found for — the UNCERTAIN case.**
   *
   * Unlike `discardPendingRoot`, nothing here knows the credential is unused. The Worker looked and
   * holds nothing, and that is all: the credential index is best-effort, and a Mac whose
   * registration has not landed yet answers identically. **The person supplies the certainty this
   * code cannot**, because they know whether they ever set a Mac up, and `e2eSetupView`'s
   * `stranded-confirm` is where that question is put to them in those words.
   *
   * The one thing that IS checkable is that this is not the credential this browser's own identity
   * rests on. Holding a DIFFERENT identity says nothing about this passkey.
   */
  async discardCredential (credentialId: Uint8Array):
    Promise<{ ok: true } | { ok: false; reason: string }> {
    const loaded = await this.load();
    if ("kind" in loaded) return { ok: false, reason: "storage" };

    const mine = loaded.record.root ? parseRoot(loaded.record.root) : null;
    if (mine && sameBytes(mine.credentialId, credentialId)) {
      return { ok: false, reason: "holds-identity" };
    }

    const outcome = await this.env.signalUnknown(this.config.rpId, credentialId);
    return outcome === "signalled" ? { ok: true } : { ok: false, reason: outcome };
  }

  async forget (): Promise<{ ok: true } | { ok: false; failure: "storage" }> {
    // Under the creation lock, as the Swift `destroy` is: a sign-out racing a first creation
    // deletes AFTER that write, instead of emptying a store the write then refills.
    const keys = await exclusive(storeKey(this.installations), () => this.installations.delete());
    const trust = await this.trust.delete();
    // **NOT ABOUT SECRECY** — it is a public key, an rp_id and a credential id, and deleting it
    // protects nothing. Resume has no confirmation by design, so anything that can feed it must not
    // outlive a sign-out: a stale entry here is a one-tap silent re-adoption of the identity just
    // abandoned. The two rules are one unit.
    await this.pending.delete();
    return keys && trust ? { ok: true } : { ok: false, failure: "storage" };
  }

  /**
   * **§9.1's pairing, from the side with nothing.** The gate configuration for a browser that holds
   * no identity at all and is about to ask a Mac for one, authenticated by the psk from a scanned
   * code.
   *
   * NO TRUSTED ROOT, and that is legal only here: §11.1 says `pair` "may bootstrap its root through
   * the PSK", and the bootstrap is safe precisely because the psk authenticated the chain the root
   * arrives in. NO BUNDLE either — §11.1 requires message 3's to be empty in this mode, and a
   * newcomer has none to send anyway.
   *
   * Null only when keys could not be created, which is a storage failure rather than a state.
   */
  async pairGateConfig (roomCode: string, psk: Uint8Array): Promise<ClientGateConfig | null> {
    const loaded = await this.load();
    if ("kind" in loaded) return null;
    const keys = loaded.installation.keys;
    // **A §10.2 DESCRIPTOR NAMES ITS ROOT, AND IN `pair` THERE IS NOT ONE YET.** §12.3's sequence
    // is explicit about the order — "persist trusted root ... ── message 3: own descriptor" — so the
    // descriptor is built AFTER message 2, against the root this session just learned. The session
    // machine does not do that yet (`docs/open-threads.md`), so this passes an empty one and
    // `commitPaired` rebuilds it from the chain rather than trusting whatever was sent.
    return {
      roomCode,
      device: new Uint8Array(0),
      signingPrivateKey: keys.signingPrivateKey,
      noisePrivateKey: keys.noisePrivateKey,
      bundle: new Uint8Array(0),
      devicePublicKeys: { signing: signingPublicKey(keys), noise: noisePublicKey(keys) },
      trustedRootId: null,
      policy: this.policy,
      mode: "pair",
      pairingPsk: psk,
    };
  }

  /**
   * **Commit what a `pair` session earned.**
   *
   * The chain arrives from a peer the psk authenticated, so it is verified against the root it
   * CARRIES — the one bootstrap §11.1 allows — and then checked to be about THIS device. A chain
   * that verifies for somebody else is a perfectly valid grant this browser cannot use.
   *
   * §12.3: "an unsuccessful durable write grants no authority", so nothing is returned as ready
   * until the write succeeds.
   */
  async commitPaired (bundle: Uint8Array): Promise<EnrollResult> {
    const loaded = await this.load();
    if ("kind" in loaded) return { ok: false, failure: { kind: "storage" } };
    if (loaded.status.kind === "blocked") return { ok: false, failure: { kind: "storage" } };

    const parsed = parseBundle(bundle);
    if (!parsed.ok) return { ok: false, failure: { kind: "malformed" } };
    const root = parsed.bundle.root;
    const rootIdBytes = hashRoot(root);

    const device = descriptorFor(loaded.installation.keys, rootIdBytes);
    if (!device) return { ok: false, failure: { kind: "malformed" } };

    const check = verifyBundle(bundle, {
      trustedRootId: rootIdBytes, policy: this.policy,
      revokedDeviceIds: loaded.record.revokedDeviceIds,
    });
    if (!check.ok) return { ok: false, failure: { kind: "unverified", failure: check.failure } };
    if (!sameBytes(check.chain.leafDevice.bytes, device)) {
      return { ok: false, failure: { kind: "unverified", failure: "chain/device-mismatch" } };
    }
    // §10.3: a device that arrived through a pairing window is a client and must not carry
    // `enroll`. `authorityIsWellFormed` refuses to ENCODE such a grant, so one arriving here is
    // malformed rather than over-privileged — asserted anyway, because this is where a browser's
    // authority is decided.
    if ((check.chain.leaf.capabilities & 4) !== 0) {
      return { ok: false, failure: { kind: "unverified", failure: "grant/capabilities" } };
    }

    let record = loaded.record;
    if (record.root === null || record.root === undefined) {
      const adopted = adoptRoot(record, root);
      if (!adopted.ok) return { ok: false, failure: { kind: "malformed" } };
      record = adopted.record;
    }
    const committed = commitOwnChain(record, bundle, PublicationStatus.Unconfirmed, rootIdBytes);
    if (!committed.ok) return { ok: false, failure: { kind: "malformed" } };

    const encoded = encodeTrustRecord(committed.record);
    if (!encoded || !(await this.trust.write(encoded))) {
      return { ok: false, failure: { kind: "storage" } };
    }
    return { ok: true, status: statusOf(loaded.installation, committed.record) };
  }

  /**
   * Everything §11 needs to know about THIS browser, for one session.
   *
   * **Null exactly when the browser is not `ready`** — no root, no committed chain, or no keys —
   * which is the right coupling: a device with no identity has nothing to present, and a gate built
   * from placeholders would fail at the peer's chain check instead of at the door. The Mac's
   * `E2ESignallingGate.Config(loaded:policy:)` is the same function.
   */
  async gateConfig (roomCode: string, expectedResponderDeviceId?: Uint8Array):
    Promise<ClientGateConfig | null> {
    const loaded = await this.load();
    if ("kind" in loaded) return null;
    const root = loaded.record.root;
    const bundle = loaded.record.bundle;
    if (!root || !bundle) return null;
    const rootIdBytes = hashRoot(root);
    const device = descriptorFor(loaded.installation.keys, rootIdBytes);
    if (!device) return null;
    return {
      roomCode, device,
      signingPrivateKey: loaded.installation.keys.signingPrivateKey,
      noisePrivateKey: loaded.installation.keys.noisePrivateKey,
      bundle,
      trustedRootId: rootIdBytes,
      policy: this.policy,
      revokedDeviceIds: loaded.record.revokedDeviceIds,
      ...(expectedResponderDeviceId ? { expectedResponderDeviceId } : {}),
    };
  }

  /**
   * The same for a browser acting as the RESPONDER — `web/host.html` is one, and under E2E-only
   * signalling it cannot answer a client without §11's machine.
   *
   * **A responder on the same origin needs its OWN storage keys**, which is why this type takes its
   * backends: two peers sharing one installation would present one descriptor from both ends, and
   * §11.1's expected-peer check — and Noise itself — would be checking a device against itself.
   */
  async hostGateConfig (roomCode: string, pairingPsk?: Uint8Array): Promise<HostGateConfig | null> {
    const loaded = await this.load();
    if ("kind" in loaded) return null;
    const root = loaded.record.root;
    const bundle = loaded.record.bundle;
    if (!root || !bundle) return null;
    const device = descriptorFor(loaded.installation.keys, hashRoot(root));
    if (!device) return null;
    return {
      roomCode, device, bundle,
      noisePrivateKey: loaded.installation.keys.noisePrivateKey,
      // §9.2's durable address. A browser peer has no rendezvous route to offer, and the initiator
      // RECORDS this without validating it — so an absent route costs a future `resume` and nothing
      // in this session.
      route: { rcode: "", rtoken: "" },
      trustedRootId: hashRoot(root),
      policy: this.policy,
      revokedDeviceIds: loaded.record.revokedDeviceIds,
      // §9.1's psk for the window the PEER is showing — adopt-by-code, where a Mac shows its own
      // code and this browser answers. Absent everywhere else, and its absence is what refuses
      // `pair` at the door rather than somewhere inside Noise.
      ...(pairingPsk ? { pairingPsk } : {}),
      ...(loaded.record.publicationStatus !== null && loaded.record.publicationStatus !== undefined
        ? { publicationStatus: loaded.record.publicationStatus }
        : {}),
    };
  }

  /** §10.1's "explicit local reset". Discards the TRUST only — the keys survive a change of identity. */
  async resetTrust (): Promise<boolean> {
    const encoded = encodeTrustRecord(emptyTrustRecord());
    return encoded !== null && await this.trust.write(encoded);
  }
}

/**
 * **The identity scoped to §10.1's policy origin — `ceremonyOrigin()`, never `location.origin`.**
 *
 * `adoptFromShell`'s `verifyBundle` checks the chain's ROOT against `this.policy.rpId`, and inside
 * the app's client window `location.origin` is `app://client/` — no http(s) origin at all, and not
 * the one the Mac's root was ever enrolled against. A chain checked under the wrong policy is
 * refused for a reason naming neither (`docs/desktop-app.md`), which is exactly what `main.ts`'s
 * `clientIdentity()` already worked around for the connect-time call.
 *
 * **A strict generalisation of `new ClientE2EIdentity()`, safe everywhere that was used.** In a
 * browser there is no shell, so `ceremonyOrigin()` falls back to `location.origin` and this produces
 * the identical config — which is why `welcome.ts`'s identity factory can use it unconditionally
 * rather than branching on `__rdevShell`.
 */
export function shellScopedIdentity (): ClientE2EIdentity {
  const origin = ceremonyOrigin();
  return new ClientE2EIdentity(undefined, undefined,
                               { rpId: policyFor(origin).rpId, rpName: "Xpromptvs" }, origin);
}

function statusOf (installation: Installation, record: TrustRecord): ClientIdentityStatus {
  switch (nextActionForRecord(record, true).action) {
    case "auth": {
      const root = record.root;
      if (!root) return { kind: "blocked", reason: "no-root" };
      const device = descriptorFor(installation.keys, hashRoot(root));
      if (!device) return { kind: "blocked", reason: "no-root" };
      // The success screen NAMES the identity, because the create route no longer asks about it.
      return { kind: "ready", deviceId: hashDevice(device), rootId: hashRoot(root) };
    }
    // §12.4's `resume` is the rendezvous path's, and this browser has only the in-place ceremony —
    // which has nothing to resume TO. Reported as unenrolled would be a lie; it is not reachable
    // here because nothing writes a pending operation, and if it ever is, it is a person's problem.
    case "resume": return { kind: "blocked", reason: "interrupted" };
    default: return { kind: "unenrolled" };
  }
}

function sameBytes (a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}
