import Foundation
import RdevCore

/// **What a host can say about its E2E identity, in one value.** A log line, a C ABI status code and
/// an app's own UI all need the same answer, and three of them deriving it separately from
/// `E2EIdentityManager.State` is how they come to disagree about whether a Mac is ready to share.
///
/// This is deliberately NOT `E2EIdentityManager.State` with a different name: that type answers
/// "what should this device do next" from storage alone, while this one also carries what is
/// happening right now (a ceremony in flight) and what a person would need to see (the device id).
public enum E2EHostStatus: Equatable, Sendable {
    /// No identity could be assembled. **Neither reason is fixed by trying again** — the configured
    /// origin cannot host a ceremony, or there is nowhere durable to write.
    case unavailable(E2EHostIdentity.Failure)
    /// Keys exist, no chain does. An enrollment is the next step and nothing is in the way.
    case unenrolled
    /// A passkey ceremony is in flight. Not a stored state — this process's own, and the reason a
    /// second one is refused rather than raising a second prompt.
    case enrolling
    /// §12.4 says `resume` to the responder that holds the half-finished operation. **This build's
    /// own ceremony is §12.1's local one**, which has no responder to resume to, so the state is
    /// reported and refused rather than quietly replaced with a fresh enrollment — starting one
    /// would reserve a second window for a device that already has one outstanding.
    case resumable
    /// Ready to serve and to connect. Carries this device's §10.2 id, which is what a directory
    /// listing and a signed label both name — and §12.2's publication status, because the issuing
    /// endpoint "MUST surface anything other than `confirmed`".
    case ready(deviceID: [UInt8], publication: E2EWire.PublicationStatus?)
    /// **A person has to decide.** Something is stored and cannot be read, and overwriting it would
    /// silently abandon an identity. Never resolved automatically.
    case blocked(E2EIdentityManager.Failure)

    /// Resolve a loaded identity into a status. The `deviceDescriptor` is derived from the trusted
    /// root, so `ready` without one is impossible by construction — but it is written as a fallback
    /// rather than a force-unwrap, because a future change to that derivation must not become a
    /// crash in a status line.
    public static func of(_ loaded: E2EIdentityManager.Loaded) -> E2EHostStatus {
        switch loaded.state {
        case .unenrolled: return .unenrolled
        case .resumable: return .resumable
        case .blocked(let failure): return .blocked(failure)
        case .ready:
            guard let descriptor = loaded.deviceDescriptor else { return .blocked(.noRoot) }
            return .ready(deviceID: E2EIdentity.deviceID(descriptor),
                          publication: loaded.record.publicationStatus)
        }
    }

    /// One short line for a log or a status menu. **No key material and no secret**: a device id is
    /// a public hash, and it is truncated only because a whole one is unreadable at a glance.
    public var summary: String {
        switch self {
        case .unavailable(.origin(let f)): return "unavailable (origin: \(f.rawValue))"
        case .unavailable(.storageUnavailable): return "unavailable (nowhere to write)"
        case .unenrolled: return "unenrolled"
        case .enrolling: return "enrolling"
        case .resumable: return "interrupted enrollment (resume is not implemented)"
        case .ready(let deviceID, let publication):
            let base = "ready device=\(Self.short(deviceID))"
            // §12.2: "the issuing endpoint knows the outcome directly and MUST surface anything
            // other than `confirmed`" — and the required wording for a rejection is quoted exactly,
            // because "not listed" asserts an absence no endpoint has established.
            switch publication {
            case .confirmed, nil: return base
            case .unconfirmed: return "\(base) · listing not confirmed"
            case .rejected: return "\(base) · \(E2EDirectory.rejectedWording)"
            }
        case .blocked(let failure): return "blocked (\(failure.rawValue))"
        }
    }

    static func short(_ id: [UInt8]) -> String {
        id.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
