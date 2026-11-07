import Foundation

/// The §11 session state machine: who may say what, in what order, and what must be true before a
/// session carries any authority at all.
///
/// **THE WHOLE POINT IS THE GATE.** §11.2: "Before this gate, only bounded authentication,
/// enrollment, and resume messages may be processed. No SDP, ICE, media, shell, input, or
/// subscription authority exists yet." `isEstablished` is that sentence, and it is false until the
/// responder has verified a chain, a device proof and a registration state, and the initiator has
/// verified the answer names its own session and its own keys.
///
/// **PURE, AND CRYPTO-FREE APART FROM SIGNATURES.** It never touches Noise. The caller drives the
/// handshake — `RdevNoise` on the host, the vendored core in the browser — and hands this machine
/// PLAINTEXTS plus the two facts only the handshake knows: the peer's authenticated static key and
/// the final handshake hash `h`. That split is what lets the rules live in `RdevCore`, which must
/// not link a Rust archive, and what lets every rule below be tested without a handshake at all.
///
/// The two halves are in one file because they are two statements of ONE contract, and the failure
/// mode is them drifting apart.
public enum E2ESession {

    /// Every way a session can refuse to establish. Raw values so the shared fixture and both
    /// implementations name the same reason — "refused for the wrong reason" hides real defects.
    public enum Failure: String, Error, Equatable, Sendable {
        /// A payload that did not parse, or carried trailing bytes.
        case malformed = "malformed"
        /// §11.1: "Message 1 has an empty payload."
        case message1NotEmpty = "message1-not-empty"
        /// A message arrived in a state that does not accept it. §11.3: one connection carries one
        /// Noise session and at most one handshake.
        case outOfOrder = "out-of-order"
        /// The peer's chain did not verify. The `E2EVerify.Failure` is carried alongside.
        case peerChain = "peer-chain"
        /// §11.1's role table: the responder does not hold what this mode requires of it.
        case responderRole = "responder-role"
        /// §11.1: "A selected Host's `device_id` must also match the selection."
        case responderNotSelected = "responder-not-selected"
        /// §11.1: "The descriptor's DH key must match the initiator's Noise static."
        case descriptorKeyMismatch = "descriptor-key-mismatch"
        /// §11.1's bundle rules: required for `auth`, empty for `pair` and `enroll`.
        case bundlePresence = "bundle-presence"
        /// §11.1: "An ordinary `auth` uses an all-zero operation ID."
        case operationIDMismatch = "operation-id-mismatch"
        /// The `client-confirm` proof body is not the one this session's facts produce.
        case proofBodyMismatch = "proof-body-mismatch"
        /// The Ed25519 device proof did not verify against the certified signing key.
        case proofSignature = "proof-signature"
        /// `session-start` does not name this handshake.
        case handshakeHashMismatch = "handshake-hash-mismatch"
        /// The accepted chain does not certify this device's exact keys.
        case acceptedChainMismatch = "accepted-chain-mismatch"
        /// §10.1: an incoming chain may never replace a trusted root.
        case rootNotTrusted = "root-not-trusted"
        /// The session was terminated. §11.3: "Decryption failure terminates the signalling session;
        /// never skip a failed ciphertext."
        case terminated = "terminated"
    }

    // MARK: - role requirements

    /// §11.1's table of what the RESPONDER must hold, per mode. Written as one function because the
    /// table is four lines in the spec and four lines here; spreading it across the two state
    /// machines is how it becomes three-quarters right.
    ///
    /// - `pair`: "the responder must have a direct grant with `enroll`" — DIRECT is the operative
    ///   word. A leaf can never carry `enroll` (§10.3), so this additionally means root-issued.
    /// - `enroll`, `auth`: "it must have `host`".
    /// - `resume`: "must match the persisted responder ID and the original operation's role
    ///   requirements" — the identity half is `expectedResponderDeviceID`, and the role half is
    ///   whatever the original operation demanded, so it is the CALLER's to supply and this
    ///   function deliberately asks nothing.
    public static func responderSatisfiesRole(mode: E2EWire.Mode,
                                              chain: E2EVerify.VerifiedChain) -> Bool {
        switch mode {
        case .pair:
            return chain.leaf.issuerKind == .root && chain.leaf.capabilities.canEnroll
        case .enroll, .auth:
            return chain.leaf.capabilities.canHost
        case .resume:
            return true
        }
    }

    /// §11.1's bundle rules for Noise message 3: "The bundle is required for `auth`; it is empty for
    /// `pair` and `enroll`. In `resume`, include any persisted grant" — so `resume` accepts either.
    ///
    /// EMPTY IS ENFORCED, not merely unused. A `pair` initiator that shipped a bundle would be
    /// presenting a chain nobody reads, and a responder that tolerated it would differ from one that
    /// did read it — which is the kind of disagreement that turns into an authority bug later.
    public static func bundlePresenceIsCorrect(mode: E2EWire.Mode, bundleIsEmpty: Bool) -> Bool {
        switch mode {
        case .auth: return !bundleIsEmpty
        case .pair, .enroll: return bundleIsEmpty
        case .resume: return true
        }
    }

    // MARK: - the initiator

    public struct InitiatorConfig: Sendable {
        public let mode: E2EWire.Mode
        public let roomCode: String
        /// This device's §10.2 descriptor bytes.
        ///
        /// **EMPTY IS CORRECT IN `pair`, and required there.** A descriptor NAMES its root (§10.2),
        /// and a newcomer does not learn that root until message 2 — §12.3 orders it exactly so:
        /// "persist trusted root … ── message 3: own descriptor". So in `pair` this is built here,
        /// after the root is adopted, from `devicePublicKeys`; in every other mode the caller
        /// already has a root and supplies the descriptor.
        public let device: [UInt8]
        /// This device's PUBLIC signing and Noise keys. Required in `pair` — they are what the
        /// descriptor is assembled from once the root is known — and ignored elsewhere.
        public let devicePublicKeys: (signing: [UInt8], noise: [UInt8])?
        public let signingPrivateKey: [UInt8]
        /// §11.1's message-3 bundle. Empty for `pair` and `enroll`.
        public let bundle: [UInt8]
        /// All-zero for an ordinary `auth`; the persisted random one for enrollment and resume.
        public let operationID: [UInt8]
        /// **Nil is legal ONLY in `pair`**, where §11.1 says the mode "may bootstrap its root
        /// through the PSK". In every other mode the root must already be trusted, because §10.1
        /// forbids an incoming chain from replacing one: "Switching identity requires an explicit
        /// local reset/re-registration; possession of a new passkey cannot remotely replace a
        /// Host's existing root."
        public let trustedRootID: [UInt8]?
        public let policy: E2EVerify.Policy
        public let revokedDeviceIDs: Set<[UInt8]>
        /// §11.1: "A selected Host's `device_id` must also match the selection." Nil when the
        /// initiator reached this route without having chosen a particular device.
        public let expectedResponderDeviceID: [UInt8]?

        public init(mode: E2EWire.Mode, roomCode: String, device: [UInt8],
                    signingPrivateKey: [UInt8], bundle: [UInt8], operationID: [UInt8],
                    trustedRootID: [UInt8]?, policy: E2EVerify.Policy,
                    revokedDeviceIDs: Set<[UInt8]> = [], expectedResponderDeviceID: [UInt8]? = nil,
                    devicePublicKeys: (signing: [UInt8], noise: [UInt8])? = nil) {
            self.mode = mode
            self.devicePublicKeys = devicePublicKeys
            self.roomCode = roomCode
            self.device = device
            self.signingPrivateKey = signingPrivateKey
            self.bundle = bundle
            self.operationID = operationID
            self.trustedRootID = trustedRootID
            self.policy = policy
            self.revokedDeviceIDs = revokedDeviceIDs
            self.expectedResponderDeviceID = expectedResponderDeviceID
        }
    }

    public struct Initiator {
        public enum Stage: Equatable, Sendable {
            case awaitingMessage2, awaitingSplit, awaitingSessionStart, established, terminated
        }

        public private(set) var stage: Stage = .awaitingMessage2
        public private(set) var responderChain: E2EVerify.VerifiedChain?
        /// The route the responder published in message 2. §9.2: persisting it "permits resume after
        /// a lost acknowledgement", which is the only way a half-finished enrollment is recoverable.
        public private(set) var responderRoute: RendezvousRoute?
        public private(set) var acceptedBundle: [UInt8]?
        public private(set) var publicationStatus: E2EWire.PublicationStatus?

        private let config: InitiatorConfig
        private var adoptedRootID: [UInt8]?
        /// **The descriptor this device presents, which in `pair` is not known at construction.**
        /// Everything downstream — message 3, the proof body, and the check that the accepted chain
        /// is about THIS device — must use the same bytes, so there is one place they come from.
        private var ownDevice: [UInt8]

        /// Nil when the configuration is one this protocol has no mode for — today that is exactly
        /// "no trusted root outside `pair`". Refused at construction rather than at message 2,
        /// because a machine that cannot state its own trust anchor has nothing to check against.
        public init?(_ config: InitiatorConfig) {
            guard config.mode == .pair || config.trustedRootID != nil else { return nil }
            guard config.operationID.count == E2EWire.idLength else { return nil }
            // `pair` names itself after message 2 and needs the keys to do it; every other mode
            // must arrive with a descriptor already. Refused at construction rather than three
            // messages in, where the failure would name neither.
            if config.mode == .pair {
                guard config.devicePublicKeys != nil else { return nil }
            } else {
                guard !config.device.isEmpty else { return nil }
            }
            self.config = config
            self.ownDevice = config.device
        }

        public var prologue: [UInt8]? {
            E2EWire.prologue(mode: config.mode, roomCode: config.roomCode)
        }

        /// §11.1: message 1's payload is empty.
        public var message1Payload: [UInt8] { [] }

        public var isEstablished: Bool { stage == .established }

        /// §11.2's gate, stated where a caller will look for it. Until this is true, a peer's SDP,
        /// ICE, media, shell, input and subscriptions are all things it is not yet entitled to send.
        public var maySignal: Bool { stage == .established }

        /// Handle Noise message 2's payload. `responderNoiseStatic` is the static key the HANDSHAKE
        /// authenticated — never a key read out of the payload, which is the peer's own claim.
        public mutating func receiveMessage2(_ payload: [UInt8],
                                             responderNoiseStatic: [UInt8])
            -> Result<Void, Failure> {
            guard stage == .awaitingMessage2 else { return fail(.outOfOrder) }
            guard let hello = E2EWire.parseResponderHello(payload) else { return fail(.malformed) }

            // In `pair` the root is bootstrapped from the chain itself, authenticated by the PSK:
            // completing an `XXpsk3` handshake at all is the proof that the peer holds the pairing
            // secret. In every other mode the trusted root is supplied and a chain naming a
            // different one is refused, never adopted.
            let rootID: [UInt8]
            if let trusted = config.trustedRootID {
                rootID = trusted
            } else {
                guard case .success(let b) = E2ECertificate.parseBundle(hello.bundle),
                      let root = E2EIdentity.parseRoot(b.root) else { return fail(.malformed) }
                rootID = root.id
            }

            let verified: E2EVerify.VerifiedChain
            switch E2EVerify.verifyBundle(hello.bundle, trustedRootID: rootID,
                                          policy: config.policy,
                                          revokedDeviceIDs: config.revokedDeviceIDs,
                                          expectedNoiseStatic: responderNoiseStatic) {
            case .success(let c): verified = c
            case .failure: return fail(.peerChain)
            }

            if let expected = config.expectedResponderDeviceID,
               verified.leafDevice.id != expected { return fail(.responderNotSelected) }
            guard responderSatisfiesRole(mode: config.mode, chain: verified) else {
                return fail(.responderRole)
            }

            adoptedRootID = rootID
            // §12.3: the descriptor is built once the trusted root is persisted, and NOT before —
            // a newcomer that named a root it invented would be certifying nothing.
            if config.mode == .pair {
                guard let keys = config.devicePublicKeys,
                      let descriptor = E2EIdentity.device(rootID: rootID,
                                                          signingPublicKey: keys.signing,
                                                          noisePublicKey: keys.noise)
                else { return fail(.malformed) }
                ownDevice = descriptor
            }
            responderChain = verified
            responderRoute = RendezvousRoute(rcode: hello.rcode, rtoken: hello.rtoken)
            stage = .awaitingSplit
            return .success(())
        }

        /// Noise message 3's payload. Available only once message 2 has been accepted — sending a
        /// device descriptor and a chain to a peer whose own chain has not verified would publish
        /// this device's identity to anyone who answered the room.
        public mutating func message3Payload() -> Result<[UInt8], Failure> {
            guard stage == .awaitingSplit else { return .failure(.outOfOrder) }
            guard bundlePresenceIsCorrect(mode: config.mode, bundleIsEmpty: config.bundle.isEmpty)
            else { return fail(.bundlePresence) }
            guard let payload = E2EWire.initiatorHello(device: ownDevice,
                                                       operationID: config.operationID,
                                                       bundle: config.bundle)
            else { return fail(.malformed) }
            return .success(payload)
        }

        /// §11.2: "After Split, the initiator sends the first transport message unprompted."
        /// `appHello`: the application's first words (`E2EWire.ClientConfirm.appHello`), at most `appHelloMax` bytes.
        public mutating func clientConfirm(handshakeHash h: [UInt8], newBundle: [UInt8] = [],
                                           appHello: [UInt8] = []) -> Result<[UInt8], Failure> {
            guard stage == .awaitingSplit else { return .failure(.outOfOrder) }
            guard let responder = responderChain,
                  let device = E2EIdentity.parseDevice(ownDevice) else { return fail(.malformed) }
            guard let body = E2EWire.deviceProofBody(
                    mode: config.mode, handshakeHash: h, deviceID: device.id,
                    responderDeviceID: responder.leafDevice.id, operationID: config.operationID),
                  let proof = E2EVerify.signEd25519(message: body,
                                                    privateKey: config.signingPrivateKey),
                  let message = E2EWire.clientConfirm(proofBody: body, proof: proof,
                                                      newBundle: newBundle, appHello: appHello)
            else { return fail(.malformed) }
            stage = .awaitingSessionStart
            return .success(message)
        }

        /// §11.2: "The initiator verifies `h`, operation ID, exact local device keys, and the
        /// accepted grant chain, then persists its committed record together with
        /// `publication_status`. Only then may it negotiate WebRTC."
        public mutating func receiveSessionStart(_ plaintext: [UInt8],
                                                 handshakeHash h: [UInt8]) -> Result<Void, Failure> {
            guard stage == .awaitingSessionStart else { return fail(.outOfOrder) }
            guard let start = E2EWire.parseSessionStart(plaintext) else { return fail(.malformed) }
            // `h` first: everything after it is only meaningful about THIS session.
            guard start.handshakeHash == h else { return fail(.handshakeHashMismatch) }
            guard start.operationID == config.operationID else { return fail(.operationIDMismatch) }

            // An accepted chain is only an answer if it certifies THIS device's exact keys. A
            // responder that returned someone else's perfectly valid grant would otherwise be
            // accepted, and the device would persist a record it can never use.
            if !start.acceptedBundle.isEmpty {
                guard let rootID = adoptedRootID,
                      let device = E2EIdentity.parseDevice(ownDevice) else {
                    return fail(.malformed)
                }
                switch E2EVerify.verifyBundle(start.acceptedBundle, trustedRootID: rootID,
                                              policy: config.policy,
                                              revokedDeviceIDs: config.revokedDeviceIDs,
                                              expectedNoiseStatic: device.noisePublicKey) {
                case .success(let accepted):
                    guard accepted.leafDevice.bytes == device.bytes else {
                        return fail(.acceptedChainMismatch)
                    }
                case .failure:
                    return fail(.acceptedChainMismatch)
                }
            }

            acceptedBundle = start.acceptedBundle
            publicationStatus = start.publicationStatus
            stage = .established
            return .success(())
        }

        /// §11.3: "Decryption failure terminates the signalling session; never skip a failed
        /// ciphertext." Terminal and one-way — there is no path back to any other stage.
        public mutating func terminate() { stage = .terminated }

        private mutating func fail<T>(_ f: Failure) -> Result<T, Failure> {
            stage = .terminated
            return .failure(f)
        }
    }

    // MARK: - the responder

    public struct ResponderConfig: Sendable {
        public let mode: E2EWire.Mode
        public let roomCode: String
        public let device: [UInt8]
        public let bundle: [UInt8]
        public let route: RendezvousRoute
        public let trustedRootID: [UInt8]
        public let policy: E2EVerify.Policy
        public let revokedDeviceIDs: Set<[UInt8]>

        public init(mode: E2EWire.Mode, roomCode: String, device: [UInt8], bundle: [UInt8],
                    route: RendezvousRoute, trustedRootID: [UInt8], policy: E2EVerify.Policy,
                    revokedDeviceIDs: Set<[UInt8]> = []) {
            self.mode = mode
            self.roomCode = roomCode
            self.device = device
            self.bundle = bundle
            self.route = route
            self.trustedRootID = trustedRootID
            self.policy = policy
            self.revokedDeviceIDs = revokedDeviceIDs
        }
    }

    public struct Responder {
        public enum Stage: Equatable, Sendable {
            case awaitingMessage1, awaitingMessage3, awaitingConfirm, established, terminated
        }

        public private(set) var stage: Stage = .awaitingMessage1
        /// The initiator's descriptor, once its DH key has been matched against the Noise static.
        public private(set) var initiatorDevice: E2EIdentity.Device?
        public private(set) var initiatorChain: E2EVerify.VerifiedChain?
        public private(set) var operationID: [UInt8]?
        /// The `new_bundle` from `client-confirm` — an enrollment request, still UNVERIFIED here:
        /// §12 decides whether to issue against it, and this machine only guarantees it arrived
        /// inside an authenticated session from a proven device.
        public private(set) var requestedBundle: [UInt8]?
        /// The `app_hello` from `client-confirm` — the application's first words (the client's terminal grid),
        /// set only once the proof has verified: nothing acts on it before the gate opens (§11.2).
        public private(set) var appHello: [UInt8] = []

        private let config: ResponderConfig

        public init(_ config: ResponderConfig) { self.config = config }

        public var prologue: [UInt8]? {
            E2EWire.prologue(mode: config.mode, roomCode: config.roomCode)
        }

        public var isEstablished: Bool { stage == .established }
        public var maySignal: Bool { stage == .established }

        public mutating func receiveMessage1(_ payload: [UInt8]) -> Result<Void, Failure> {
            guard stage == .awaitingMessage1 else { return fail(.outOfOrder) }
            guard E2EWire.message1PayloadIsAcceptable(payload) else { return fail(.message1NotEmpty) }
            stage = .awaitingMessage3
            return .success(())
        }

        /// §9.2: the Issuer sends its durable address here, "before the newcomer can request an
        /// enrollment that might commit."
        public func message2Payload() -> Result<[UInt8], Failure> {
            guard stage == .awaitingMessage3 else { return .failure(.outOfOrder) }
            guard let payload = E2EWire.responderHello(bundle: config.bundle,
                                                       rcode: config.route.rcode,
                                                       rtoken: config.route.rtoken)
            else { return .failure(.malformed) }
            return .success(payload)
        }

        public mutating func receiveMessage3(_ payload: [UInt8],
                                             initiatorNoiseStatic: [UInt8]) -> Result<Void, Failure> {
            guard stage == .awaitingMessage3 else { return fail(.outOfOrder) }
            guard let hello = E2EWire.parseInitiatorHello(payload),
                  let device = E2EIdentity.parseDevice(hello.device) else { return fail(.malformed) }

            // §11.1: "The descriptor's DH key must match the initiator's Noise static." Compared
            // against the key NOISE authenticated, not against anything else in this message — a
            // descriptor is a claim, and only the handshake proves possession.
            guard device.noisePublicKey == initiatorNoiseStatic else {
                return fail(.descriptorKeyMismatch)
            }
            guard bundlePresenceIsCorrect(mode: config.mode, bundleIsEmpty: hello.bundle.isEmpty)
            else { return fail(.bundlePresence) }
            // §11.1: "An ordinary `auth` uses an all-zero operation ID."
            guard config.mode != .auth || hello.isOrdinaryAuth else {
                return fail(.operationIDMismatch)
            }

            if !hello.bundle.isEmpty {
                switch E2EVerify.verifyBundle(hello.bundle, trustedRootID: config.trustedRootID,
                                              policy: config.policy,
                                              revokedDeviceIDs: config.revokedDeviceIDs,
                                              expectedNoiseStatic: initiatorNoiseStatic) {
                case .success(let c):
                    // The chain must certify the very descriptor this message carried, not merely
                    // some device holding the same DH key.
                    guard c.leafDevice.bytes == device.bytes else { return fail(.peerChain) }
                    initiatorChain = c
                case .failure:
                    return fail(.peerChain)
                }
            }

            initiatorDevice = device
            operationID = hello.operationID
            stage = .awaitingConfirm
            return .success(())
        }

        /// §11.2's gate. "The responder validates the descriptor, proof, chain or enrollment
        /// request, and registration state."
        ///
        /// **THE PROOF BODY IS REBUILT HERE AND COMPARED BYTE FOR BYTE.** Verifying the signature
        /// over the body the message SUPPLIED would prove only that the device signed something —
        /// and the something it signed could name a different session, a different responder or a
        /// different mode. The body is a statement about facts this side already knows, so this side
        /// composes it and the wire only gets to agree.
        public mutating func receiveClientConfirm(_ plaintext: [UInt8],
                                                  handshakeHash h: [UInt8]) -> Result<Void, Failure> {
            guard stage == .awaitingConfirm else { return fail(.outOfOrder) }
            guard let confirm = E2EWire.parseClientConfirm(plaintext),
                  let device = initiatorDevice,
                  let operation = operationID,
                  let ownDevice = E2EIdentity.parseDevice(config.device) else {
                return fail(.malformed)
            }
            guard let expected = E2EWire.deviceProofBody(
                    mode: config.mode, handshakeHash: h, deviceID: device.id,
                    responderDeviceID: ownDevice.id, operationID: operation)
            else { return fail(.malformed) }
            guard confirm.proofBody == expected else { return fail(.proofBodyMismatch) }

            // The signing key comes from the DESCRIPTOR, which the handshake bound to this peer via
            // its DH key, and — in `auth` — which a verified chain additionally certifies.
            guard E2EVerify.verifyEd25519(signature: confirm.proof, message: confirm.proofBody,
                                          publicKey: device.signingPublicKey)
            else { return fail(.proofSignature) }

            requestedBundle = confirm.newBundle
            appHello = confirm.appHello
            stage = .established
            return .success(())
        }

        /// §11.2: "The responder replies only after authorization and the required durable writes."
        /// Reachable only once the gate above has passed, which is what makes that sentence true of
        /// the code rather than only of the specification.
        public func sessionStart(handshakeHash h: [UInt8], status: E2EWire.PublicationStatus,
                                 acceptedBundle: [UInt8]) -> Result<[UInt8], Failure> {
            guard stage == .established, let operation = operationID else {
                return .failure(.outOfOrder)
            }
            guard let payload = E2EWire.sessionStart(handshakeHash: h, operationID: operation,
                                                     status: status, acceptedBundle: acceptedBundle)
            else { return .failure(.malformed) }
            return .success(payload)
        }

        public mutating func terminate() { stage = .terminated }

        private mutating func fail<T>(_ f: Failure) -> Result<T, Failure> {
            stage = .terminated
            return .failure(f)
        }
    }
}
