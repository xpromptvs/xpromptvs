import Foundation

/// §12.2's directory contract — the bytes a device signs to mutate the directory, what a publication
/// attempt's outcome means, and the rules that stop one peer's ignorance overwriting another's
/// knowledge.
///
/// **PUBLICATION IS BEST-EFFORT WITH A BOUNDED WAIT; IT IS NOT A PRECONDITION FOR ACCESS.** §12.2
/// flags that as "a deliberate policy change from an earlier revision ... and it should be recognised
/// as such rather than read as a cleanup". Cryptographically the old rule added nothing — M can claim
/// any grant is registered or that none is — but it did give the account list the property of being a
/// COMPLETE view of who had access. That completeness is what was traded away, for availability.
///
/// PURE. No HTTP, no storage, no clock: a caller supplies the outcome it observed and this decides
/// what it means, which is the part two implementations must agree on.
public enum E2EDirectory {

    /// §12.2: "a fresh, one-use 32-byte Worker challenge, valid for at most 120 seconds."
    public static let challengeLength = 32
    public static let challengeMaxAgeSeconds = 120

    /// §12.2's bounded wait on publication, and §12.2's bounded wait on the revocation fetch.
    ///
    /// **BOUNDED IS THE WHOLE POINT, not "failure does not block".** A request that is neither
    /// answered nor refused has not failed, and without a deadline it stalls activation for as long
    /// as M cares to stay silent — which is precisely the denial of service that not blocking on
    /// failure was meant to avoid.
    public static let publishDeadlineSeconds = 5.0
    public static let revokeDeadlineSeconds = 5.0

    static let requestLabel = "rdev-e2e/directory/v1"

    /// §12.2 names one. Root revocation is NOT here: "the WebAuthn-signed revocation itself
    /// authorizes an idempotent submission and needs no device authority", so it is not signed with
    /// a device key and does not use this body at all.
    ///
    /// **The other three are rdev's, and they are what replaces OAuth accounts.** Session discovery
    /// used to hang off a Google identity and a bearer token; it hangs off the root a device already
    /// belongs to, authorised exactly the way `register` is — a one-use Worker challenge and a body
    /// signed by a device key whose chain verifies under that root. There is no bearer token to
    /// steal and the Worker learns a root id rather than a person.
    /// `docs/superpowers/specs/2026-09-13-passkey-only-identity.md`.
    ///
    /// **`list` is signed too, and that is not symmetry for its own sake.** A published session
    /// carries the room `code` and `token`, which is what a peer needs to reach the signalling room
    /// at all — so an unauthenticated listing would hand every live room to anyone who learned a
    /// root id. §11 would still refuse them, but "the gate holds" is not a reason to publish the
    /// door.
    public enum Action: String, Sendable, CaseIterable {
        case register
        case publish
        case unpublish
        case list
        /// `list`'s authorisation for a STREAM (`/watch`). Distinct so a `list` signature is never a
        /// subscription.
        case subscribe
    }

    /// **A live Host, as the directory carries it.** The `code` and `token` are the existing pairing
    /// pair, so everything after selection is the pairing-code path that already exists — which is
    /// what keeps `SessionDO` and the signalling wire format out of this entirely.
    ///
    /// `label` is what a person reads. §10.4's SIGNED device labels are the trustworthy version of a
    /// name and this is not one: it is a convenience the publishing device asserts about itself, and
    /// a directory-supplied name is one "the same adversary chose". Present it as a hint, never as
    /// proof.
    public struct Session: Equatable, Sendable {
        public let code: String
        public let token: String
        public let label: String
        /// The publishing device. **EMPTY in everything a device signs**: the Worker derives it from
        /// the verified chain rather than reading it from the request, so filling it in here would
        /// be signing over a field nobody consults — and the two would then be free to disagree.
        public let deviceID: String

        public init(code: String, token: String, label: String, deviceID: String = "") {
            self.code = code
            self.token = token
            self.label = label
            self.deviceID = deviceID
        }
    }

    static let sessionLabel = "rdev-e2e/directory-session/v1"

    /// The bytes `publish` signs over: `LP("rdev-e2e/directory-session/v1") || LP(code) ||
    /// LP(token) || LP(label) || LP(device_id)`.
    ///
    /// Canonical and minimal, because a JSON encoder's key order is not a contract and two
    /// implementations that disagree about it produce a signature neither can check.
    public static func sessionPayload(_ s: Session) -> [UInt8]? {
        guard let code = E2EWire.lengthPrefixed(Array(s.code.utf8)),
              let token = E2EWire.lengthPrefixed(Array(s.token.utf8)),
              let label = E2EWire.lengthPrefixed(Array(s.label.utf8)),
              let deviceID = E2EWire.lengthPrefixed(Array(s.deviceID.utf8))
        else { return nil }
        return E2EWire.lp(sessionLabel) + code + token + label + deviceID
    }

    /// `LP("rdev-e2e/directory/v1") || LP(action) || challenge || root_id || operation_id
    ///  || H(payload)`
    ///
    /// The payload is HASHED, not carried: the body is a fixed size whatever the bundle's size (161
    /// bytes for `register`), and the Worker compares the hash against the bundle it actually
    /// received. Signing the bundle inline would make the signed statement grow with its subject for
    /// no gain.
    public static func requestBody(action: Action, challenge: [UInt8], rootID: [UInt8],
                                   operationID: [UInt8], payload: [UInt8]) -> [UInt8]? {
        guard challenge.count == challengeLength, rootID.count == E2EWire.idLength,
              operationID.count == E2EWire.idLength else { return nil }
        return E2EWire.lp(requestLabel) + E2EWire.lp(action.rawValue)
             + challenge + rootID + operationID + E2EIdentity.sha256(payload)
    }

    public struct Request: Equatable, Sendable {
        public let action: Action
        public let challenge: [UInt8]
        public let rootID: [UInt8]
        public let operationID: [UInt8]
        public let payloadHash: [UInt8]
    }

    public static func parseRequestBody(_ bytes: [UInt8]) -> Request? {
        var r = E2EWire.Reader(bytes)
        guard r.expectLabel(requestLabel),
              let actionBytes = r.lengthPrefixed(),
              let actionName = String(bytes: actionBytes, encoding: .utf8),
              let action = Action(rawValue: actionName),
              let challenge = r.take(challengeLength),
              let rootID = r.take(E2EWire.idLength),
              let operationID = r.take(E2EWire.idLength),
              let payloadHash = r.take(E2EWire.idLength),
              r.atEnd
        else { return nil }
        return Request(action: action, challenge: challenge, rootID: rootID,
                       operationID: operationID, payloadHash: payloadHash)
    }

    // MARK: - what a publication attempt meant

    /// What the endpoint observed when it tried to publish. Modelled as cases rather than a bare
    /// status code because **a 409 means opposite things depending on its content**, and an API that
    /// took only a number would make that distinction impossible to state.
    public enum Response: Equatable, Sendable {
        /// The Worker acknowledged the registration.
        case acknowledged
        /// Nothing came back: timeout, connection refused, DNS or TLS failure, or the deadline
        /// expired. §12.2 counts "any reply that did not arrive" as transient.
        case noReply
        /// A `409` under the same operation ID carrying the SAME content. §12.2: "the idempotent
        /// success path, not a rejection." Registration is idempotent on `(root_id, operation_id)`.
        case conflictSameContent
        /// A `409` under the same operation ID carrying DIFFERENT content — terminal.
        case conflictDifferentContent
        /// Any other HTTP status.
        case httpStatus(Int)
    }

    /// §12.2's transient/terminal table. The two categories differ in RETRY POLICY, not in what they
    /// prove about the directory — see `rejectedIsNotAVerdict`.
    public static func classify(_ response: Response) -> E2EWire.PublicationStatus {
        switch response {
        case .acknowledged, .conflictSameContent:
            return .confirmed
        case .noReply:
            return .unconfirmed
        case .conflictDifferentContent:
            return .rejected
        case .httpStatus(let code):
            if (200 ... 299).contains(code) { return .confirmed }
            // **404 IS TRANSIENT**, which looks wrong and is not: §12.2 lists it explicitly because
            // "a deployment may be in progress". A 404 from a Worker mid-deploy is an outage, not a
            // refusal, and treating it as terminal would pause a job that a retry would complete.
            if code == 404 || code == 429 || (500 ... 599).contains(code) { return .unconfirmed }
            // Everything else is terminal, and the transient set above is EXHAUSTIVE by design. A
            // bare 409 lands here on purpose: its content was not compared, so it is not known to be
            // the idempotent path, and guessing "transient" would retry forever against a Worker
            // that will keep answering 409.
            return .rejected
        }
    }

    /// §12.2's REQUIRED WORDING, quoted exactly.
    ///
    /// Two rules live behind this string and neither is expressible as code, so they are stated
    /// here where the string is:
    ///
    /// - **`rejected` is not a verdict on the device.** M can refuse arbitrarily, and the endpoint's
    ///   own verification is what authorized the session.
    /// - **Absence from the directory is not revocation.** "A failed request, a rejected retry, or
    ///   an omitted record never establishes absence" — and the tempting call site, "the list came
    ///   back and my grant is not in it, so I have been removed", is one line of plausible code. An interface that says "not listed" asserts an
    /// absence no endpoint has established: `rejected` describes the latest ATTEMPT, and a perfectly
    /// ordinary history is publication succeeding, its acknowledgement being lost, and a later retry
    /// being refused. The record exists; only the retry failed.
    public static let rejectedWording = "Publication rejected; listing not confirmed. Action required."

    /// Does this status need surfacing to the user? §12.2 obliges both the issuing endpoint and the
    /// newcomer to "surface anything other than `confirmed`".
    public static func mustSurface(_ status: E2EWire.PublicationStatus) -> Bool {
        status != .confirmed
    }

    /// Whether a job in this state retries on its own. Transient retries "automatic, idempotent,
    /// across restarts"; terminal is "paused, pending corrective action".
    public static func retriesAutomatically(_ status: E2EWire.PublicationStatus) -> Bool {
        status == .unconfirmed
    }

    // MARK: - §12.2's monotonic status

    /// Merge a reported status into the stored one. **Status is stored per `grant_id` and is
    /// monotonic toward `confirmed`.**
    ///
    /// `reporterHoldsPublicationJob` is the rule that makes this non-trivial. `publication_status`
    /// rides in EVERY `session-start`, including an ordinary `auth` to a Host that never
    /// participated in the publication and holds no record of it — and §12.2 says such a Host
    /// "reports `unconfirmed`, which is the truth: it does not know". **Without this parameter every
    /// connection to an unrelated Host would erase what the issuing endpoint reported.**
    public static func merge(stored: E2EWire.PublicationStatus?,
                             reported: E2EWire.PublicationStatus,
                             reporterHoldsPublicationJob: Bool) -> E2EWire.PublicationStatus? {
        // `confirmed` is terminal. "A later `unconfirmed` from any peer MUST NOT reset it."
        if stored == .confirmed { return .confirmed }
        guard reporterHoldsPublicationJob else { return stored }
        return reported
    }

    /// §12.2's clearing rule: "A newcomer clears its own flag when it observes its own `grant_id` in
    /// the directory; a `confirmed` status is never revisited."
    ///
    /// **AND IT NEVER COMES BACK.** The flag is a user-visibility hint, not a security control — M
    /// can claim a grant is listed when it is not — so re-raising the warning because M later omits
    /// the record would hand it a nuisance channel and protect nothing.
    public static func observedOwnGrantInDirectory() -> E2EWire.PublicationStatus { .confirmed }

    // MARK: - §12.4 resume

    /// The durable state a newcomer can wake up in.
    public enum DurableState: String, Sendable, CaseIterable {
        /// Keys only; no request that could commit was ever sent.
        case keysOnly = "keys-only"
        /// A pending operation and a responder route, but no committed chain.
        case pendingOperation = "pending-operation"
        /// A committed chain, with cleanup still outstanding.
        case committedWithCleanupPending = "committed-cleanup-pending"
        case committedClean = "committed-clean"
        /// Device private keys lost. §10.2: "Private-key loss means generating new keys and enrolling
        /// again, not reconstructing the old device."
        case keysLost = "keys-lost"
    }

    public enum NextAction: Equatable, Sendable {
        case freshEnrollment
        case resume
        /// `repeatCleanup` carries §12.4's second column for the interrupted row: the session is an
        /// ordinary `auth`, and the cleanup that did not finish is run again.
        case auth(repeatCleanup: Bool)
        case generateNewKeysAndEnroll
    }

    /// §12.4's table, whole. A device that guesses here either strands a committed chain or restarts
    /// a ceremony that already reserved a window.
    public static func nextAction(_ state: DurableState) -> NextAction {
        switch state {
        case .keysOnly: return .freshEnrollment
        case .pendingOperation: return .resume
        case .committedWithCleanupPending: return .auth(repeatCleanup: true)
        case .committedClean: return .auth(repeatCleanup: false)
        case .keysLost: return .generateNewKeysAndEnroll
        }
    }
}
