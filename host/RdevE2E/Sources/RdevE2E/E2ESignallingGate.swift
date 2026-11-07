import Foundation
import RdevCore
import RdevNoise

/// **§11's gate, for one peer, on the host's side.** One Noise session, one `E2ESession.Responder`,
/// and the rule the whole protocol rests on: §11.2 — "Before this gate, only bounded
/// authentication, enrollment, and resume messages may be processed. No SDP, ICE, media, shell,
/// input, or subscription authority exists yet."
///
/// It exists because the two halves of §11 live in two modules that must not merge: `RdevCore`
/// decides policy and must never link a Rust archive, `RdevNoise` does the cryptography. The wiring
/// between them is where the handshake hash and the peer's authenticated static key cross over —
/// the two facts the gate rests on — and it belongs in exactly one place rather than at every call
/// site that wants a session.
///
/// **After the gate, this is also the TRANSPORT.** §11.3: "Every subsequent signalling message,
/// including SDP, ICE, renegotiation, and ICE restart, is carried inside Noise transport." So the
/// inner payload is the same signalling JSON the plaintext envelopes used to carry, and both ends
/// keep their existing parsers.
///
/// **NOT THREAD-SAFE, and it must not be made so here** — for `NoiseSession`'s reason, which is not
/// tidiness: every message advances a nonce counter, so two concurrent writes are a protocol error
/// rather than a data race to paper over. The caller serializes.
public final class E2ESignallingGate {

    public struct Config: Sendable {
        /// This host's §10.2 descriptor. Its DH key must be the Noise static below, and the peer
        /// checks exactly that.
        public let device: [UInt8]
        public let bundle: [UInt8]
        public let noisePrivateKey: [UInt8]
        /// §9.2's durable address, sent in message 2 "before the newcomer can request an enrollment
        /// that might commit". A host that has never enrolled through a rendezvous has none, and
        /// empty strings are what that looks like — the initiator RECORDS this and validates
        /// nothing, so an absent route costs a future `resume` and nothing in this session.
        public let route: RendezvousRoute
        public let trustedRootID: [UInt8]
        public let policy: E2EVerify.Policy
        public let revokedDeviceIDs: Set<[UInt8]>
        /// §12.2: the newcomer learns this from the endpoint that KNOWS, rather than inferring it
        /// from a directory listing that cannot answer the question.
        public let publicationStatus: E2EWire.PublicationStatus
        /// **§9.1's psk for the pairing window this Host is showing right now**, or nil when none is
        /// open. Nil REFUSES `pair`, and that is what "only a directly enrolled Issuer may open a
        /// pairing window" means in code: a Host with no window has no key, so the handshake cannot
        /// complete and there is nothing to prompt about.
        public let pairingPSK: [UInt8]?
        /// This device's signing key, for the grant a `pair` newcomer asks to be minted. Nil when
        /// this device cannot issue one — which is also a refusal rather than a prompt.
        public let signingPrivateKey: [UInt8]?
        /// WHO mints a `pair` newcomer's chain (`PairIssuer`).
        public let pairIssuer: PairIssuer

        public init(device: [UInt8], bundle: [UInt8], noisePrivateKey: [UInt8],
                    route: RendezvousRoute, trustedRootID: [UInt8], policy: E2EVerify.Policy,
                    revokedDeviceIDs: Set<[UInt8]> = [],
                    publicationStatus: E2EWire.PublicationStatus = .unconfirmed,
                    pairingPSK: [UInt8]? = nil, signingPrivateKey: [UInt8]? = nil,
                    pairIssuer: PairIssuer = .subordinate) {
            self.device = device
            self.bundle = bundle
            self.noisePrivateKey = noisePrivateKey
            self.route = route
            self.trustedRootID = trustedRootID
            self.policy = policy
            self.revokedDeviceIDs = revokedDeviceIDs
            self.publicationStatus = publicationStatus
            self.pairingPSK = pairingPSK
            self.signingPrivateKey = signingPrivateKey
            self.pairIssuer = pairIssuer
        }
    }

    /// **Who mints the chain a `pair` newcomer is owed.**
    ///
    /// - `subordinate`: THIS device, with its own signing key — §10.3's `root → A → B`, capability `1`.
    ///   A Host showing a pairing code to a guest: the newcomer is a client.
    /// - `passkey`: the ROOT, through a passkey ceremony the caller runs — adopt-by-code from a Mac
    ///   (2026-10-07, "a dedicated Add device by code workflow"). The NEWCOMER showed the code, this
    ///   device answers, and what it is owed is the direct, root-signed capability-`2` grant a browser
    ///   issues (`web/src/client/adopt.ts`). A ceremony is a person and seconds, so the gate PARKS after
    ///   `client-confirm` (`awaitingIssuance`) and `issue` supplies the chain — `E2EHostGate`'s shape in
    ///   TypeScript. Needs no signing key: the passkey signs.
    public enum PairIssuer: Equatable, Sendable { case subordinate, passkey }

    /// What a `passkey` issuer must mint over, once the newcomer is authenticated (`pendingIssuance`).
    public struct PendingIssuance: Equatable, Sendable {
        /// The newcomer's §10.2 descriptor, as message 3 delivered it and Noise authenticated it.
        public let device: [UInt8]
        /// §10.3's remote binding `h` — this exact transcript.
        public let handshakeHash: [UInt8]
        /// §10.3's remote binding `responder_device_id` — this device.
        public let responderDeviceID: [UInt8]
    }

    public enum Failure: Error, Equatable {
        /// §11.3: "Mode is supplied with the initial handshake." An envelope that opens a session
        /// without naming one cannot be given a default — the mode is bound into the prologue, and
        /// guessing it would let a peer choose the pattern by omission.
        case modeNotOffered
        /// The mode itself is fine; THIS gate cannot serve it right now. `pair` without an open
        /// pairing window has no psk, and a device that cannot issue a grant cannot answer either.
        /// Named rather than folded into `session` so the answer says "not here" instead of "you are
        /// wrong" — and a refusal is all a caller without the key can ever produce, because the
        /// handshake cannot complete without it.
        case modeNotSupported
        /// **§11.3: decryption failure TERMINATES the signalling session.** Never retried, never
        /// skipped: a peer who can produce this at will is the adversary, and a retry loop is what
        /// turns one forged frame into an oracle.
        case noise
        case session(E2ESession.Failure)
        /// A caller tried to send through a gate that has not opened, or has closed.
        case notEstablished
    }

    /// What one incoming envelope produced.
    public enum Received: Equatable {
        /// Handshake traffic to send back. **Never carries a mode** — only the initiator names one.
        case reply([UInt8])
        /// Received and absorbed; there is nothing to send yet.
        case nothing
        /// One signalling message from a peer this session has authenticated. The same JSON the
        /// plaintext envelopes carried, for `SignalingRouter.route`.
        case signalling(Data)
        /// A `pair` newcomer is authenticated and owed a chain the ROOT must sign (`PairIssuer.passkey`):
        /// nothing is sent until `issue` is given one. Only a `passkey` issuer's gate ever says this.
        case awaitingIssuance
    }

    private enum Stage {
        case fresh
        case running(NoiseSession)
        case terminated
    }

    private var stage: Stage = .fresh
    private var responder: E2ESession.Responder?
    /// The mode the opening envelope named. §11.3 binds it into the prologue, so it is fixed for the
    /// life of the session and what `session-start` owes depends on it.
    private var mode: E2EWire.Mode?
    private let config: Config
    private let roomCode: String
    private var pending: PendingIssuance?

    public init(config: Config, roomCode: String) {
        self.config = config
        self.roomCode = roomCode
    }

    /// §11.2's sentence, as a property. False until the peer has presented a chain that verifies
    /// under this host's trusted root AND a device proof bound to this exact handshake.
    ///
    /// **A PARKED SESSION HAS NOT OPENED** (`PairIssuer.passkey`): the responder's session is established
    /// once `client-confirm` verifies, but the newcomer is still owed its chain — §11.2's "the responder
    /// replies only after authorization and the required durable writes".
    public var maySignal: Bool { pending == nil && (responder?.maySignal ?? false) }

    /// What a `passkey` issuer must mint over, or nil when nothing is parked.
    public var pendingIssuance: PendingIssuance? { pending }

    /// The peer's verified chain, once there is one. Nil before the gate opens — which is the point:
    /// there is no authenticated identity to attribute anything to until then.
    public var peerChain: E2EVerify.VerifiedChain? { responder?.initiatorChain }
    /// What the client's `client-confirm` said for the APPLICATION (`E2EWire.ClientConfirm.appHello` — its terminal
    /// grid), and nothing until the gate is open: §11.2 grants no shell authority before it.
    public var appHello: [UInt8] { maySignal ? (responder?.appHello ?? []) : [] }

    /// Handle one §11.3 envelope's ciphertext.
    ///
    /// **Any failure terminates.** §11.3 leaves no room for recovery, and a gate that answered a
    /// second time after refusing once would be exactly the oracle that rule exists to prevent.
    public func receive(_ ciphertext: [UInt8], mode: E2EWire.Mode?) -> Result<Received, Failure> {
        switch stage {
        case .terminated:
            return .failure(.notEstablished)
        case .fresh:
            guard let mode else { return terminate(.modeNotOffered) }
            switch mode {
            case .auth:
                break
            case .pair:
                // No open window, or nothing to issue with: refused at the door rather than half
                // way through a handshake that could not have finished anyway. A passkey issuer needs
                // no signing key — the root signs.
                guard config.pairingPSK != nil,
                      config.pairIssuer == .passkey || config.signingPrivateKey != nil else {
                    return terminate(.modeNotSupported)
                }
            case .enroll:
                break
            case .resume:
                // §12.4's table is its own piece of work and this gate does not serve it yet.
                return terminate(.modeNotSupported)
            }
            return openHandshake(ciphertext, mode: mode)
        case .running(let noise):
            // A mode on anything but the first message is ignored rather than refused: §11.3 makes
            // the prologue the binding statement, and this one is routing metadata that changes
            // nothing. Refusing would let a relay kill established sessions by adding a field.
            return step(noise, ciphertext)
        }
    }

    /// Wrap one outgoing signalling message. §11.2: nothing may be sent before the gate opens, and
    /// this is where that stops being a convention.
    public func seal(_ message: Data) -> Result<[UInt8], Failure> {
        guard case .running(let noise) = stage, maySignal else { return .failure(.notEstablished) }
        guard let sealed = try? noise.write([UInt8](message)) else { return terminate(.noise) }
        return .success(sealed)
    }

    public func close() {
        responder?.terminate()
        stage = .terminated
    }

    // MARK: - the handshake

    private func openHandshake(_ ciphertext: [UInt8],
                               mode: E2EWire.Mode) -> Result<Received, Failure> {
        // §11.1's table: `pair` is `Noise_XXpsk3`, everything else is `Noise_XX`. The pattern is
        // chosen by the MODE, which the prologue binds — so a peer cannot pick one by omission.
        guard let prologue = E2EWire.prologue(mode: mode, roomCode: roomCode),
              let noise = NoiseSession(mode: mode == .pair ? .pair : .xx, initiator: false,
                                       prologue: prologue,
                                       staticPrivateKey: config.noisePrivateKey,
                                       psk: mode == .pair ? config.pairingPSK : nil)
        else { return terminate(.noise) }

        var session = E2ESession.Responder(.init(
            mode: mode, roomCode: roomCode, device: config.device, bundle: config.bundle,
            route: config.route, trustedRootID: config.trustedRootID, policy: config.policy,
            revokedDeviceIDs: config.revokedDeviceIDs))

        guard let message1 = try? noise.read(ciphertext) else { return terminate(.noise) }
        if case .failure(let f) = session.receiveMessage1(message1) {
            responder = session
            return terminate(.session(f))
        }
        let payload: [UInt8]
        switch session.message2Payload() {
        case .success(let p): payload = p
        case .failure(let f):
            responder = session
            return terminate(.session(f))
        }
        guard let reply = try? noise.write(payload) else { return terminate(.noise) }

        responder = session
        self.mode = mode
        stage = .running(noise)
        return .success(.reply(reply))
    }

    private func step(_ noise: NoiseSession, _ ciphertext: [UInt8]) -> Result<Received, Failure> {
        guard var session = responder else { return terminate(.notEstablished) }
        guard let plaintext = try? noise.read(ciphertext) else { return terminate(.noise) }

        // Established sessions carry signalling, and nothing else reaches this branch — the
        // handshake arms below all advance the stage before it can.
        if session.maySignal { return .success(.signalling(Data(plaintext))) }

        switch session.stage {
        case .awaitingMessage3:
            // The static key NOISE authenticated, not one the message asserted about itself. §11.1:
            // "The descriptor's DH key must match the initiator's Noise static."
            guard let staticKey = noise.remoteStaticKey else { return terminate(.noise) }
            let result = session.receiveMessage3(plaintext, initiatorNoiseStatic: staticKey)
            responder = session
            if case .failure(let f) = result { return terminate(.session(f)) }
            return .success(.nothing)

        case .awaitingConfirm:
            guard let h = noise.handshakeHash else { return terminate(.noise) }
            let result = session.receiveClientConfirm(plaintext, handshakeHash: h)
            responder = session
            if case .failure(let f) = result { return terminate(.session(f)) }

            // **A PASSKEY ISSUER STOPS HERE**: the newcomer is authenticated and owed a chain only the
            // root can sign, and a ceremony does not fit in a synchronous `receive`. Nothing is sent;
            // `issue` answers.
            if mode == .pair, config.pairIssuer == .passkey {
                guard let device = session.initiatorDevice else { return terminate(.session(.malformed)) }
                pending = PendingIssuance(device: device.bytes, handshakeHash: h,
                                          responderDeviceID: E2EIdentity.deviceID(config.device))
                return .success(.awaitingIssuance)
            }

            // §11.2: "The responder replies only after authorization and the required durable
            // writes."
            let accepted: [UInt8]
            switch acceptedBundle(for: session) {
            case .success(let bundle): accepted = bundle
            case .failure(let f): return terminate(f)
            }
            switch session.sessionStart(handshakeHash: h, status: config.publicationStatus,
                                        acceptedBundle: accepted) {
            case .success(let payload):
                guard let reply = try? noise.write(payload) else { return terminate(.noise) }
                return .success(.reply(reply))
            case .failure(let f):
                return terminate(.session(f))
            }

        case .awaitingMessage1, .established, .terminated:
            responder = session
            return terminate(.session(.outOfOrder))
        }
    }

    /// What `session-start` hands back, per mode.
    ///
    /// - `auth` issues nothing: the initiator already holds a chain and presented it in message 3.
    /// - `enroll` carries a chain the initiator issued ITSELF with the root passkey. This side
    ///   verifies it under the root it already trusts and echoes it as accepted. §10.1 is why it is
    ///   not adopted blindly: an incoming chain may never replace or extend the trust anchor.
    /// - `pair` carries nothing, and this side MINTS one — §10.3's `root → A → B`, capability `1`,
    ///   because a device that arrived through a pairing window is a client. **The psk is the
    ///   authorisation**: possession of it is what §9.1 buys, and nothing else is asked.
    private func acceptedBundle(for session: E2ESession.Responder) -> Result<[UInt8], Failure> {
        switch mode {
        case .auth, .resume, .none:
            return .success([])
        case .enroll:
            guard let requested = session.requestedBundle, !requested.isEmpty else {
                return .failure(.session(.bundlePresence))
            }
            guard case .success = E2EVerify.verifyBundle(requested,
                                                         trustedRootID: config.trustedRootID,
                                                         policy: config.policy,
                                                         revokedDeviceIDs: config.revokedDeviceIDs)
            else { return .failure(.session(.peerChain)) }
            return .success(requested)
        case .pair:
            guard let device = session.initiatorDevice, let signing = config.signingPrivateKey,
                  case .success(let parsed) = E2ECertificate.parseBundle(config.bundle)
            else { return .failure(.session(.malformed)) }
            switch E2ESubordinateGrant.issue(
                    to: device.bytes, ownRoot: parsed.root, ownBundle: config.bundle,
                    signingPrivateKey: signing,
                    operationID: DeviceIdentity.systemRandom(E2EIdentity.idLength),
                    randomness: DeviceIdentity.systemRandom(E2EIdentity.idLength),
                    policy: config.policy) {
            case .success(let bundle): return .success(bundle)
            case .failure: return .failure(.session(.malformed))
            }
        }
    }

    /// **Supply the chain a parked `pair` session is waiting for, and open the gate** — the ciphertext of
    /// its `session-start`, to send. `E2EHostGate.issue` in TypeScript, the same checks in the same order.
    ///
    /// The bundle is checked against this gate's OWN view first: it must verify under the root this device
    /// trusts and certify the exact descriptor message 3 delivered — a caller that minted for the wrong
    /// device is refused here, where the mistake is legible. **The BINDING is not checked here**: §10.4 has
    /// the far side check `h` and the responder's device id against its own view, which is where the check
    /// means something.
    ///
    /// A refusal TERMINATES: one window issues one chain, and a caller that may retry with another bundle
    /// is one that may shop for an accepted one.
    public func issue(_ bundle: [UInt8]) -> Result<[UInt8], Failure> {
        guard case .running(let noise) = stage, let parked = pending, let session = responder,
              let h = noise.handshakeHash else { return terminate(.notEstablished) }
        guard case .success(let chain) = E2EVerify.verifyBundle(bundle, trustedRootID: config.trustedRootID,
                                                                policy: config.policy,
                                                                revokedDeviceIDs: config.revokedDeviceIDs),
              chain.leafDevice.bytes == parked.device
        else { return terminate(.session(.peerChain)) }
        switch session.sessionStart(handshakeHash: h, status: config.publicationStatus, acceptedBundle: bundle) {
        case .success(let payload):
            guard let sealed = try? noise.write(payload) else { return terminate(.noise) }
            // Cleared LAST: `maySignal` reads it, so the gate opens at exactly this point.
            pending = nil
            return .success(sealed)
        case .failure(let f):
            return terminate(.session(f))
        }
    }

    private func terminate<T>(_ failure: Failure) -> Result<T, Failure> {
        responder?.terminate()
        stage = .terminated
        pending = nil
        return .failure(failure)
    }
}

public extension E2ESignallingGate.Config {
    /// Everything §11 needs to know about THIS host, from the one place that knows it.
    ///
    /// **Nil exactly when the host is not `ready`** — no root, no committed chain, or no keys — which
    /// is the right coupling: a device with no identity has nothing to present, and a gate built from
    /// placeholders would fail at the peer's chain check instead of at the door.
    /// `pairingPSK` is the window this Host is showing right now, if any — supplied by the caller
    /// rather than read from the installation, because a pairing window is a live thing with a
    /// lifetime and the identity is not.
    ///
    /// `pairIssuer`: `.passkey` when this device answers a newcomer that showed ITS OWN code — Add device
    /// by code — and the root signs what it is owed (`PairIssuer`).
    init?(loaded: E2EIdentityManager.Loaded, policy: E2EVerify.Policy,
          pairingPSK: [UInt8]? = nil, pairIssuer: E2ESignallingGate.PairIssuer = .subordinate) {
        guard let device = loaded.deviceDescriptor,
              let bundle = loaded.record.bundle,
              let rootID = loaded.trustedRootID,
              let route = loaded.installation.route else { return nil }
        self.init(device: device, bundle: bundle,
                  noisePrivateKey: loaded.installation.keys.noisePrivateKey,
                  route: route, trustedRootID: rootID, policy: policy,
                  revokedDeviceIDs: loaded.record.revokedDeviceIDs,
                  // §12.2: absent is not "confirmed". A host that has never heard back from a
                  // directory says so, and the newcomer decides what to do about it.
                  publicationStatus: loaded.record.publicationStatus ?? .unconfirmed,
                  pairingPSK: pairingPSK,
                  signingPrivateKey: loaded.installation.keys.signingPrivateKey,
                  pairIssuer: pairIssuer)
    }
}
