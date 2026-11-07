import Foundation
import RdevCore
import RdevHostKit

// MARK: - the Mac's own passkey ceremony, and the state its dashboard reads
//
// The STATE is polled: the app's `StatePublisher` reads this class on one 250 ms main-queue tick and
// pushes changes to the dashboard (2026-09-26). The CEREMONIES are not: since 2026-10-06 the app runs
// the passkey prompt itself (`signIn`, `createPasskey`, `authorise` — the platform's passkey API, no
// browser, no courier, no question to poll for), so each is one awaited call that ends with its
// outcome, and the dashboard's panel shows it as the browser's does. `docs/e2e.md`, "The Mac's own
// passkey ceremony".
//
// The identity is NOT the runtime's. A runtime exists only between `start()` and `stop()`, while
// "is this Mac enrolled?" is what the app asks before any session exists — it is what decides
// whether Share is offered at all.

/// Ordered by how far along the device is, but nothing may depend on that: the caller switches on
/// the value.
public enum E2EStatusCode: Int32, Sendable {
    case unavailable = 0
    case unenrolled = 1
    case enrolling = 2
    // 3 was `awaitingRootConfirmation`, §12.1's polled question — gone with the courier (2026-10-06).
    case interrupted = 4
    case ready = 5
    case blocked = 6
    /// **§12.2: the issuing endpoint "MUST surface anything other than `confirmed`".** Ready and
    /// serving either way — publication is best-effort and never a precondition for access — but the
    /// two unpublished outcomes are SEPARATE CODES rather than a marker inside `detail`, because
    /// they differ in required wording and in retry policy, and a caller that had to parse a string
    /// to tell them apart would eventually get it wrong.
    case readyListingNotConfirmed = 7
    case readyPublicationRejected = 8
    case badArguments = -1
}

public final class E2EHost: @unchecked Sendable {
    public static let shared = E2EHost()
    private let lock = NSLock()
    /// The last base a caller named, so `detail` and the ceremonies act on the same service without
    /// every call having to repeat it. `E2EIdentityService.shared` dedupes by base, so naming the
    /// same one twice is free and naming a different one is a deliberate change of Control Plane.
    private var base: String?
    /// Why the last ceremony ended, as a short code for the UI. Empty when none has.
    private var lastFailure = ""

    /// §10.3's capability on this device's own leaf grant, or 0 when there is no chain to read one
    /// from. **0 is "unknown", not a role** — the accepted set is `{1, 2, 3, 7}` and a caller that
    /// treated 0 as a restriction would disable a working button on a Mac whose library will not
    /// load.
    public func capabilities() -> UInt8 {
        // **One reader, shared with the upgrade rule.** A second copy of "verify the chain and take
        // the leaf's capability" is a second chance for the two to disagree about the same device.
        currentService()?.identity?.leafCapabilities()?.raw ?? 0
    }

    public func service(base: String) -> E2EIdentityService {
        lock.lock()
        self.base = base
        lock.unlock()
        return E2EIdentityService.shared(signalingBase: base)
    }

    private func currentService() -> E2EIdentityService? {
        lock.lock()
        let remembered = base
        lock.unlock()
        return remembered.map { E2EIdentityService.shared(signalingBase: $0) }
    }

    /// Where this device stands with §12.1, as one value. Safe to call before, during and after
    /// sharing — it reads no runtime.
    public func status(base: String) -> E2EStatusCode {
        switch service(base: base).status() {
        case .unavailable: return .unavailable
        case .unenrolled: return .unenrolled
        case .enrolling: return .enrolling
        case .resumable: return .interrupted
        case .ready(_, let publication):
            switch publication {
            case .confirmed, nil: return .ready
            case .unconfirmed: return .readyListingNotConfirmed
            case .rejected: return .readyPublicationRejected
            }
        case .blocked: return .blocked
        }
    }

    /// The one string the status code cannot carry, and WHICH string depends only on the status:
    ///
    /// - ready — this device's §10.2 id, which is what a directory listing names. **NOT an identity,
    ///   and it stays hexadecimal**: nobody holds two screens up to compare a device handle, and
    ///   giving it the identity's shape would invite exactly that;
    /// - unavailable or blocked — why, which is the whole content of those two states;
    /// - anything else — why the last ceremony ended, or empty.
    public func detail() -> String {
        switch currentService()?.status() {
        case .ready(let deviceID, _):
            return hex(deviceID)
        case .unavailable(.origin(let failure)):
            return "origin-\(failure.rawValue)"
        case .unavailable(.storageUnavailable):
            return "no-storage"
        case .blocked(let failure):
            return failure.rawValue
        case .unenrolled, .enrolling, .resumable, nil:
            lock.lock()
            defer { lock.unlock() }
            return lastFailure
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// §10.1's identity AS A PERSON READS IT, or "" when this Mac belongs to none.
    ///
    /// **Its own function, not a second meaning for `detail()`.** That one returns the §10.2 DEVICE id
    /// while a Mac is ready, and an identity and a device handle are two formats that exist precisely
    /// so a person cannot mistake one for the other.
    public func identityCode() -> String {
        guard let rootID = currentService()?.trustedRootID() else { return "" }
        return E2EIdentity.code(rootID: rootID)
    }

    public func forget() -> Bool {
        forgetListing()
        return currentService()?.forget() ?? false
    }

    /// What a ceremony ended with, for the dashboard's panel (`web/src/shared/e2e-setup.ts`'s `enroll`):
    /// the identity as a person reads it and this device's id, or the reason code the panel words.
    public struct CeremonyOutcome: Sendable, Equatable {
        public let ok: Bool
        public let reason: String
        public let rootCode: String
        public let deviceID: String
        public var json: [String: Any] {
            ok ? ["ok": true, "rootId": rootCode, "deviceId": deviceID]
               : ["ok": false, "reason": reason, "stranded": false]
        }
    }

    /// **Sign in with a passkey: ONE prompt** (`E2EHostIdentity.signIn`), then §12.2's publication.
    /// Also §10.3's upgrade for a Mac adopted by code.
    public func signIn(base: String, authenticator: PasskeyAuthenticator) async -> CeremonyOutcome {
        settle(await service(base: base).signIn(authenticator: authenticator).map { _ in () })
    }

    /// **Create a passkey** — prompt one of two; the passkey is retained (`E2EHostIdentity.createPasskey`).
    public func createPasskey(base: String, authenticator: PasskeyAuthenticator) async -> CeremonyOutcome {
        settle(await service(base: base).createPasskey(authenticator: authenticator), granted: false)
    }

    /// **Let the retained passkey authorise this Mac** — create's prompt two, and "Finish setting up".
    public func authorise(base: String, authenticator: PasskeyAuthenticator) async -> CeremonyOutcome {
        settle(await service(base: base).authorise(authenticator: authenticator).map { _ in () })
    }

    /// A passkey this Mac created and never finished: the panel offers "Finish setting up".
    public func hasPendingRoot() -> Bool { currentService()?.hasPendingRoot ?? false }

    private func settle(_ result: Result<Void, E2EIdentityService.CeremonyFailure>,
                        granted: Bool = true) -> CeremonyOutcome {
        switch result {
        case .success:
            lock.lock(); lastFailure = ""; lock.unlock()
            // A new identity is a new listing: what the old one streamed is not this one's.
            if granted { forgetListing() }
            let device: String
            if case .ready(let id, _)? = currentService()?.status() { device = hex(id) } else { device = "" }
            return CeremonyOutcome(ok: true, reason: "", rootCode: granted ? identityCode() : "",
                                   deviceID: device)
        case .failure(let failure):
            let code: String
            switch failure {
            case .unavailable(.origin(let f)): code = "origin-\(f.rawValue)"
            case .unavailable(.storageUnavailable): code = "no-storage"
            case .alreadyEnrolling: code = "already-enrolling"
            case .notApplicable: code = "not-applicable"
            case .ceremony(let f): code = f.reason
            }
            // A dismissal is a decision, not a fault: nothing to remember for the row.
            if code != "dismissed" { lock.lock(); lastFailure = code; lock.unlock() }
            return CeremonyOutcome(ok: false, reason: code, rootCode: "", deviceID: "")
        }
    }

    // MARK: - §12.2's listing, over the same one-directional surface

    /// The last answer, and whether one is on its way. **Cached, because the caller POLLS**: the
    /// app's `StatePublisher` ticks every 250 ms, and a listing is a signed round trip — one per
    /// tick would be four requests a second for a value that changes on a 30 s heartbeat.
    ///
    /// §12.2's listing as a pure state machine (`ListingStore`); this class adds the lock and owns
    /// the watcher object.
    private var store = ListingStore()

    /// The app's own hook for "the listing MAY HAVE CHANGED" — a fetch landed, a stream snapshot
    /// landed, or the listing was forgotten. **It is not "the identity changed"**: `forget()` below
    /// calls `forgetListing()` (which fires this) BEFORE it asks `currentService()?.forget()`
    /// whether the identity itself was actually forgotten, so a caller that read this hook as
    /// identity news would learn of a sign-out that had not yet — and might never — happen.
    /// `docs/superpowers/specs/2026-09-26-app-push-state-design.md`: the app pushes state to its dashboard
    /// instead of the dashboard polling this class, and this is the one seam that tells it when to
    /// push. **Called OUTSIDE `lock`, always** (AGENTS.md: never call out while holding a lock) — the
    /// get/set below are the only places that touch `listingObserver` itself, and `notifyListing`
    /// reads it through the getter, which takes and releases the lock before returning, rather than
    /// calling it while still holding one.
    private var listingObserver: (@Sendable () -> Void)?
    public var onListingChange: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return listingObserver }
        set { lock.lock(); listingObserver = newValue; lock.unlock() }
    }
    private func notifyListing() { onListingChange?() }

    /// §12.2's listing as a STREAM (`/watch`, `E2EDirectoryWatcher`): each snapshot lands in `store`
    /// exactly as a fetch does, and fires `onListingChange`, so the app's publisher pushes it to the
    /// dashboard at once with no change above this line. `docs/superpowers/specs/2026-09-24-live-device-list-design.md`.
    private var watcher: E2EDirectoryWatcher?
    private var watchStarting = false
    /// A refusal or a `/watch` that never opens stops the stream until the next identity change.
    private var watchStopped = false
    /// `RDEV_DIRECTORY_WATCH=0` turns the stream off and leaves polling alone — an operational
    /// fallback, and the negative control in `gate-directory-listing.sh`.
    private let watchAllowed = ProcessInfo.processInfo.environment["RDEV_DIRECTORY_WATCH"] != "0"

    /// `internal`, not `private`: `RdevAppHostTests` calls this directly rather than through the
    /// public `forget()`, so a listing test never risks reaching `forget()`'s second half
    /// (`currentService()?.forget()`, which deletes this MACHINE's real installation the moment
    /// anything has named a signalling base). This method touches only `store` and `watcher`.
    func forgetListing() {
        lock.lock()
        store.forget()
        let w = watcher
        watcher = nil
        watchStarting = false
        watchStopped = false
        lock.unlock()
        w?.stop()
        notifyListing()
    }

    /// Return what is known and, when asked or when nothing is known yet, go and find out.
    ///
    /// **The surface is polled** and the bridge calls in on the AppKit main thread, so a signed HTTP
    /// round trip is not awaited here. The
    /// answer is a state the caller polls. `refresh` is the Refresh button; without it a first call
    /// starts the fetch and returns `loading`, and the caller's next tick has the rows.
    public func listSessions(base: String, refresh: Bool) -> Listing {
        let service = service(base: base)
        lock.lock()
        let shouldFetch = store.read(refresh: refresh)
        let startWatch = watchAllowed && watcher == nil && !watchStarting && !watchStopped
        if startWatch { watchStarting = true }
        let epoch = store.epoch
        lock.unlock()

        if startWatch {
            if let watch = service.identity?.directoryWatch() {
                let w = E2EDirectoryWatcher(
                    url: watch.url, credentials: watch.credentials,
                    onSessions: { [weak self] rows in self?.streamed(rows, epoch: epoch) },
                    onDown: { [weak self] in self?.setWatchLive(false) },
                    onStopped: { [weak self] _ in self?.watchEnded() })
                lock.lock()
                let current = epoch == store.epoch
                if current { watcher = w }
                watchStarting = false
                lock.unlock()
                if current { w.start() }
            } else {
                // No committed chain yet: try again on a later read, once there is one.
                lock.lock(); watchStarting = false; lock.unlock()
            }
        }

        if shouldFetch {
            Task.detached {
                let rows = await service.identity?.listSessions(
                    operationID: E2EOperation.newID())
                self.landed(rows, epoch: epoch)
            }
        }

        lock.lock(); defer { lock.unlock() }
        return store.snapshot
    }

    private func row(_ s: E2EDirectory.Session) -> ListingRow {
        ListingRow(label: s.label, code: s.code, token: s.token, deviceID: s.deviceID)
    }

    /// A SYNCHRONOUS method, called from the detached task. `NSLock.lock()` is unavailable from an
    /// asynchronous context — an error under the Swift 6 language mode — and taking it inside a
    /// plain function is the fix rather than a workaround: nothing here suspends while it is held.
    private func landed(_ rows: [E2EDirectory.Session]?, epoch: Int) {
        lock.lock(); store.store(rows.map { $0.map(row) }, epoch: epoch); lock.unlock()
        notifyListing()
    }

    /// A snapshot from the stream. Same destination as a fetch, minus the in-flight flag — a fetch
    /// may still be out, and it lands on the same store. Already filtered of this Mac's own row
    /// (`E2EDirectoryWatch` does it). An old identity's snapshot lands on a stale epoch and is dropped.
    private func streamed(_ rows: [E2EDirectory.Session], epoch: Int) {
        lock.lock(); store.streamed(rows.map(row), epoch: epoch); lock.unlock()
        notifyListing()
    }

    private func setWatchLive(_ live: Bool) { lock.lock(); store.setWatchLive(live); lock.unlock() }

    private func watchEnded() {
        lock.lock(); store.setWatchLive(false); watchStopped = true; lock.unlock()
    }

    /// §10.3's `root → A → B`. `keysB64` is base64url of `signing_public_key || noise_public_key`,
    /// 64 bytes; the root is this device's, so the descriptor is assembled on this side. Returns the
    /// subordinate's bundle as base64url, or a `-`-prefixed failure code — the same shape `detail()`
    /// uses, so one buffer contract serves both.
    public func issueSubordinateGrant(keysB64: String) -> String {
        guard let keys = base64urlDecode(keysB64),
              keys.count == 2 * E2EIdentity.idLength else { return "-malformed-device" }
        guard let identity = currentService()?.identity else { return "-not-enrolled" }
        let split = E2EIdentity.idLength
        switch identity.issueSubordinateGrant(signingPublicKey: Array(keys[..<split]),
                                              noisePublicKey: Array(keys[split...])) {
        case .success(let bundle): return base64urlEncode(Data(bundle))
        case .failure(let failure): return "-" + failure.rawValue
        }
    }
}
