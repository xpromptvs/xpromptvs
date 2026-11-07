import Foundation

/// Loading and creating the §10.2 installation record, independent of where it is kept.
///
/// The storage itself is a `Backend` — the Keychain on the host, IndexedDB in a browser — because
/// the decision this file exists to make is not about storage at all. It is about **what to do when
/// the record is there and cannot be read.**
public enum InstallationStore {

    /// Somewhere durable to keep ~122 bytes. Deliberately tiny: everything interesting is above it.
    public protocol Backend {
        func read() -> [UInt8]?
        func write(_ bytes: [UInt8]) -> Bool
        func delete() -> Bool
    }

    public enum Outcome: Equatable {
        /// An existing installation was read back intact.
        case loaded(DeviceIdentity.Installation)
        /// Nothing was stored, so a new identity was generated and written.
        case created(DeviceIdentity.Installation)
    }

    public enum Failure: String, Error, Equatable, Sendable {
        /// Something is stored and it is not an installation record.
        ///
        /// **THE CALLER MUST NOT TREAT THIS AS "NO IDENTITY".** Overwriting it generates a new
        /// device, which silently abandons every grant the old one held — §10.2 is explicit that
        /// key loss "means generating new keys and enrolling again", and enrolling again is a
        /// decision with a person in it. A transient read fault and a genuinely corrupt record are
        /// indistinguishable from here, and only one of them is worth destroying an identity over.
        case unreadableRecord = "unreadable-record"
        /// The record could not be written. §12.3: "unsuccessful durable write grants no authority",
        /// so a caller that ignores this and carries on is running an identity it cannot resume.
        case writeFailed = "write-failed"
        /// The CSPRNG, or key generation, refused.
        case generationFailed = "generation-failed"
    }

    /// Read the installation, or create one if and only if the store is EMPTY.
    ///
    /// The three outcomes are deliberately distinct. "Loaded" and "created" differ because a Host
    /// that has just created its identity has no grants and must enroll, while one that loaded its
    /// own may already be authorized — and "unreadable" is neither, because it is the only one where
    /// the right move is to stop and say so.
    ///
    /// **SINGLE-FLIGHT, PROCESS-WIDE.** Read-then-create is a check-then-act: two callers finding the
    /// store empty at once each generated keys and wrote them, the last write won, and a caller that
    /// had already acted on the losing set — §12.1's enrollment certifying the keys it loaded — left
    /// the device with a chain for keys it no longer held, so §12.2's registration was signed with
    /// the survivors and refused (`401 signature`, status 8). The native app hit it on every fresh
    /// launch: the first `status()` and the detached `retryRegistration` that
    /// `E2EIdentityService.shared` fires each created a set. The retired C ABI's koffi caller, one call
    /// at a time on the main thread, had only made the window narrower. ONE lock for every backend, not one per instance, because
    /// two managers over the same file are two instances.
    public static func loadOrCreate(
        _ backend: Backend,
        randomBytes: (Int) -> [UInt8] = DeviceIdentity.systemRandom
    ) -> Result<Outcome, Failure> {
        creation.lock()
        defer { creation.unlock() }
        if let stored = backend.read() {
            guard let installation = DeviceIdentity.decode(stored) else {
                return .failure(.unreadableRecord)
            }
            return .success(.loaded(installation))
        }
        guard let fresh = DeviceIdentity.generate(randomBytes: randomBytes) else {
            return .failure(.generationFailed)
        }
        guard backend.write(DeviceIdentity.encode(fresh)) else { return .failure(.writeFailed) }
        return .success(.created(fresh))
    }

    private static let creation = NSLock()

    /// Deliberately destroy this device's identity — the "enroll again" half of §10.2's rule.
    ///
    /// **SEPARATE FROM `loadOrCreate` ON PURPOSE, and it takes no shortcut through it.** This is the
    /// only path that discards keys, so it is the only place a reader has to look to find out what
    /// can. A caller reaching here has decided; nothing decides on its behalf.
    ///
    /// **Under the same `creation` lock**, so a destroy issued while a first creation is in flight
    /// waits for its write and then deletes it — rather than deleting an empty store the write then
    /// refills. The lock is NOT recursive and need not be: neither function calls the other, and no
    /// backend calls back into this type.
    public static func destroy(_ backend: Backend) -> Bool {
        creation.lock()
        defer { creation.unlock() }
        return backend.delete()
    }

    /// An in-memory backend, for tests and for a runtime with nowhere durable to write.
    ///
    /// **A CLASS, so it behaves like storage rather than like a value.** As a struct, `loadOrCreate`
    /// would write into a copy and every caller would appear to have a fresh identity forever — a
    /// test using one would pass while proving nothing about persistence.
    public final class Memory: Backend {
        public private(set) var stored: [UInt8]?
        public private(set) var writes = 0

        public init(_ initial: [UInt8]? = nil) { stored = initial }

        public func read() -> [UInt8]? { stored }
        public func write(_ bytes: [UInt8]) -> Bool { stored = bytes; writes += 1; return true }
        public func delete() -> Bool { stored = nil; return true }
    }

    /// A backend whose writes always fail, so the "unsuccessful durable write" path is reachable
    /// from a test rather than only from a broken machine.
    public final class ReadOnly: Backend {
        private let contents: [UInt8]?
        public init(_ contents: [UInt8]? = nil) { self.contents = contents }
        public func read() -> [UInt8]? { contents }
        public func write(_ bytes: [UInt8]) -> Bool { false }
        public func delete() -> Bool { false }
    }
}
