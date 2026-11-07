import Foundation

/// §13: what an authenticated session is actually allowed to do, and when that permission stops.
///
/// §10 and §11 establish WHO a peer is. This is the layer that turns that into WHETHER — and §13 is
/// blunt about the order: "A Host grants remote access only after the §11.2 confirmation gate and
/// §12.2's revocation check". Both are parameters here rather than assumptions, so a call site that
/// has not done them cannot accidentally read as one that has.
///
/// **"Authentication cannot be performed in or after the component whose privileged side effect it
/// is supposed to guard."** That sentence is why this type exists separately from the effects it
/// guards: a decision made inside `SimManager` or `TerminalManager` is a decision made after the
/// object that owns the side effect already exists.
public enum E2EAuthorization {

    /// The privileged effects §13 names. Deliberately COARSE: these are the three things a grant
    /// says, not a catalogue of every control message. Per-message policy (who is the active
    /// controller, what the lifecycle allows) stays where it already lives — §13: "Terminal control,
    /// input, subscriptions, and curtain actions retain the application's active-controller and
    /// lifecycle rules."
    public enum Effect: String, Sendable, CaseIterable {
        /// Establish a controlled session at all — which, per §10.3, includes full remote control
        /// and a shell. `connect` is NOT a read-only capability.
        case connect
        /// Serve as the Host of a session.
        case host
        /// Issue a pairing code, and enroll another device against it.
        case issueCode = "issue-code"
    }

    public enum Denial: String, Error, Equatable, Sendable {
        /// §11.2's gate has not passed. §13: "A routing ID, open connection, account token, or
        /// certificate without possession proof is insufficient."
        case notAuthenticated = "not-authenticated"
        /// §12.2's revocation check has not been made for this activation. §10.5 requires Hosts to
        /// "fetch revocations when connecting to the Control Plane and before activating a newly
        /// authenticated session" — so "we did not ask" is a denial, not a pass.
        case revocationNotChecked = "revocation-not-checked"
        /// The chain does not carry the capability this effect requires.
        case missingCapability = "missing-capability"
        /// §13: "Only a direct `enroll` grant authorizes code issuance." A leaf can never carry
        /// `enroll` at all (§10.3), so this fires for a root-issued grant that simply lacks it.
        case notDirectEnroll = "not-direct-enroll"
        /// The session that authorized this has been replaced or revoked. §13: "Late callbacks must
        /// never execute through a replacement session's authority."
        case authorityWithdrawn = "authority-withdrawn"
    }

    /// The whole of §13's capability test, in one place so the three rules can be read together.
    ///
    /// `gatePassed` and `revocationChecked` are separate parameters ON PURPOSE. Folding them into
    /// one "ready" flag would let a caller that did one of them satisfy a check meant for both, and
    /// they are made at different times by different code.
    public static func authorize(_ effect: Effect, chain: E2EVerify.VerifiedChain,
                              gatePassed: Bool, revocationChecked: Bool) -> Result<Void, Denial> {
        guard gatePassed else { return .failure(.notAuthenticated) }
        guard revocationChecked else { return .failure(.revocationNotChecked) }

        switch effect {
        case .connect:
            return chain.leaf.capabilities.canConnect ? .success(()) : .failure(.missingCapability)
        case .host:
            return chain.leaf.capabilities.canHost ? .success(()) : .failure(.missingCapability)
        case .issueCode:
            // DIRECT is the operative word, and it is already implied: §10.3 forbids `enroll` on any
            // device-issued grant, so a chain reaching here with `enroll` is necessarily root-issued.
            // Stated anyway, because the implication lives in a different file and a future
            // relaxation there must not silently widen this.
            guard chain.leaf.capabilities.canEnroll, chain.leaf.issuerKind == .root else {
                return .failure(.notDirectEnroll)
            }
            return .success(())
        }
    }

    /// A stamp identifying WHICH session authorized something.
    ///
    /// §13: "Replacing a session or receiving revocation withdraws the old session's authority. Late
    /// callbacks must never execute through a replacement session's authority."
    ///
    /// **THIS IS A KNOWN-RECURRING SHAPE IN THIS CODEBASE, not a hypothetical.** The same bug has
    /// been paid for before wherever a deferred effect outlived the state that authorized it — a
    /// held modifier carried into an incoming driver's session on a CLAIM, an injector reused across
    /// a handover. A callback that captured a session and fires after the handover is indeed a
    /// callback holding authority nobody granted.
    public struct Stamp: Equatable, Hashable, Sendable {
        public let epoch: UInt64
        public init(epoch: UInt64) { self.epoch = epoch }
    }

    /// Tracks which session is current, so a deferred effect can be asked whether its own authority
    /// still exists. A value type: copying it copies a snapshot, and a snapshot cannot silently
    /// become current again.
    public struct Authority: Equatable, Sendable {
        public private(set) var current: Stamp
        public private(set) var withdrawn: Bool

        public init(epoch: UInt64 = 1) {
            current = Stamp(epoch: epoch)
            withdrawn = false
        }

        /// A new authenticated session supersedes the old one. Returns the new stamp; the previous
        /// one never becomes valid again, because the epoch only moves forward.
        @discardableResult
        public mutating func replace() -> Stamp {
            current = Stamp(epoch: current.epoch + 1)
            withdrawn = false
            return current
        }

        /// §10.5 on receiving a revocation: "terminate affected sessions, withdraw active control,
        /// release held input, and prevent further effects from those sessions." Withdrawal is
        /// TERMINAL for the current epoch — the way back is `replace()`, which is a new session,
        /// never a resumption of this one.
        public mutating func withdraw() { withdrawn = true }

        /// May an effect stamped at `stamp` still run?
        public func permits(_ stamp: Stamp) -> Bool { !withdrawn && stamp == current }

        public func check(_ stamp: Stamp) -> Result<Void, Denial> {
            permits(stamp) ? .success(()) : .failure(.authorityWithdrawn)
        }
    }
}
