import Foundation
import RdevCore
import RdevNoise

/// **§11's gate, on the INITIATOR's side, in Swift.** The mirror of `E2ESignallingGate`, and of
/// `protocol/src/e2e-signalling-gate.ts`'s `E2EClientGate` — the three are one contract and the
/// failure mode is them drifting apart, so this is deliberately the same shape as both.
///
/// **Why a Swift initiator exists at all.** `tools/RdevViewer` is a native client: it receives an
/// offer and answers it, over the same signalling the browser uses. Once signalling is E2E-only a
/// peer that cannot open a §11 session is a peer that cannot connect, and the viewer is the only
/// exercise of the decode path this repo has. An instrument that cannot reach the thing it measures
/// is not an instrument.
///
/// The one asymmetry that is real — **the initiator SPEAKS FIRST** — is the only difference in the
/// surface: `start()` exists here and has no counterpart on the responder.
///
/// **NOT THREAD-SAFE, for `NoiseSession`'s reason**: every message advances a nonce counter, so two
/// concurrent writes are a protocol error rather than a data race to paper over. The caller
/// serializes.
public final class E2EClientGate {

    public struct Config: Sendable {
        /// This device's §10.2 descriptor. Its DH key must be `noisePrivateKey`'s public key, and
        /// the responder checks exactly that.
        public let device: [UInt8]
        public let bundle: [UInt8]
        public let signingPrivateKey: [UInt8]
        public let noisePrivateKey: [UInt8]
        /// **Nil is legal ONLY in `pair`**, where §11.1 says the mode "may bootstrap its root
        /// through the PSK". In every other mode the root must already be trusted, because §10.1
        /// forbids an incoming chain from replacing one.
        public let trustedRootID: [UInt8]?
        public let policy: E2EVerify.Policy
        public let revokedDeviceIDs: Set<[UInt8]>
        /// §11.1: "A selected Host's `device_id` must also match the selection." Nil when this
        /// client reached the room without having chosen a particular device.
        public let expectedResponderDeviceID: [UInt8]?
        /// §11.1's mode. `auth` connects with a chain this device already holds; `enroll` presents
        /// one the ROOT just signed; `pair` presents nothing and asks to be issued one.
        public let mode: E2EWire.Mode
        /// §9.1's psk, required by `pair` and meaningless elsewhere. Derived from the seed a person
        /// carried, and **never transmitted** — it authenticates the handshake itself.
        public let pairingPSK: [UInt8]?
        /// The chain to present in `enroll`: one this device just had signed by the root passkey.
        /// Empty in every other mode.
        public let newBundle: [UInt8]
        /// The application's first words, carried by `client-confirm` (`E2EWire.ClientConfirm.appHello`) — a
        /// browser's terminal grid. Empty here: the native client renders no terminal. One longer than
        /// `E2EWire.appHelloMax` is sent EMPTY rather than killing the handshake.
        public let appHello: [UInt8]

        public init(device: [UInt8], bundle: [UInt8], signingPrivateKey: [UInt8],
                    noisePrivateKey: [UInt8], trustedRootID: [UInt8]?, policy: E2EVerify.Policy,
                    revokedDeviceIDs: Set<[UInt8]> = [], expectedResponderDeviceID: [UInt8]? = nil,
                    mode: E2EWire.Mode = .auth, pairingPSK: [UInt8]? = nil,
                    newBundle: [UInt8] = [], appHello: [UInt8] = []) {
            self.device = device
            self.bundle = bundle
            self.signingPrivateKey = signingPrivateKey
            self.noisePrivateKey = noisePrivateKey
            self.trustedRootID = trustedRootID
            self.policy = policy
            self.revokedDeviceIDs = revokedDeviceIDs
            self.expectedResponderDeviceID = expectedResponderDeviceID
            self.mode = mode
            self.pairingPSK = pairingPSK
            self.newBundle = newBundle
            self.appHello = appHello
        }
    }

    public enum Failure: Error, Equatable {
        /// §11.3: decryption failure TERMINATES the session. Never retried — a peer who can produce
        /// this at will is the adversary, and a retry loop turns one forged frame into an oracle.
        case noise
        case session(E2ESession.Failure)
        /// Something was asked of a gate that has not opened, or has closed.
        case notEstablished
    }

    /// What one incoming envelope produced. Mirrors the responder's, plus the list.
    public enum Received: Equatable {
        /// Handshake traffic to send back, IN ORDER, one envelope each.
        ///
        /// **A LIST, because message 3 and `client-confirm` are TWO Noise messages** produced
        /// together. Noise framing carries no length, so concatenating them hands the responder one
        /// message with the other's bytes as its payload — which decrypts, parses as garbage, and
        /// fails somewhere that names neither.
        case reply([[UInt8]])
        /// Received and absorbed; there is nothing to send yet.
        case nothing
        /// One signalling message from a peer this session has authenticated — the same JSON the
        /// plaintext envelopes carried.
        case signalling(Data)
    }


    private var noise: NoiseSession?
    private var initiator: E2ESession.Initiator?
    private var handshakeHash: [UInt8]?
    private var dead = false

    private let config: Config
    private let roomCode: String

    public init(config: Config, roomCode: String) {
        self.config = config
        self.roomCode = roomCode
    }

    /// §11.2's sentence, as a property. False until the host has presented a chain that verifies
    /// under this device's trusted root AND this device has proved, inside the handshake, that it
    /// holds its own signing key.
    public var maySignal: Bool { initiator?.maySignal ?? false }

    /// The host's verified chain, once there is one. Nil before the gate opens — which is the point:
    /// there is no authenticated identity to attribute anything to until then.
    public var peerChain: E2EVerify.VerifiedChain? { initiator?.responderChain }

    /// **The chain this device walked away with**, in `pair` (minted for it) and `enroll` (echoed
    /// back as accepted). Nil in `auth`, which issues nothing. The caller persists it — §12.3: "an
    /// unsuccessful durable write grants no authority", so that is deliberately not done here.
    public var acceptedBundle: [UInt8]? { initiator?.acceptedBundle }

    /// The root this session established, which in `pair` is the one it LEARNED. §11.1 allows that
    /// bootstrap only there, and only because the psk authenticated the chain it came from.
    public var responderChain: E2EVerify.VerifiedChain? { initiator?.responderChain }

    /// The two PUBLIC halves of this device's keys, which `pair` needs in order to name itself once
    /// it has adopted a root. `DeviceIdentity.Keys` derives both — Ed25519 and X25519 are different
    /// algorithms on different representations, and §7 forbids converting between them.
    private func publicKeys() -> (signing: [UInt8], noise: [UInt8])? {
        guard let keys = DeviceIdentity.Keys(signingPrivateKey: config.signingPrivateKey,
                                             noisePrivateKey: config.noisePrivateKey),
              let signing = keys.signingPublicKey, let noise = keys.noisePublicKey else { return nil }
        return (signing, noise)
    }

    /// Begin. **The initiator speaks first**, and this is the only envelope that carries a mode —
    /// §11.3: "Mode is supplied with the initial handshake and bound into the prologue."
    public func start() -> Result<(ciphertext: [UInt8], mode: E2EWire.Mode), Failure> {
        guard !dead, noise == nil else { return .failure(.notEstablished) }
        // A `pair` without its key could only ever fail inside Noise, and failing HERE names the
        // reason instead of producing an unexplained handshake error two messages later.
        if config.mode == .pair && config.pairingPSK == nil { return .failure(.notEstablished) }

        guard var session = E2ESession.Initiator(.init(
                mode: config.mode, roomCode: roomCode, device: config.device,
                signingPrivateKey: config.signingPrivateKey, bundle: config.bundle,
                // §11.1: "An ordinary `auth` uses an all-zero operation ID." Not a missing value —
                // and the enrolling modes carry a random one, because they are operations that can
                // be resumed and an all-zero id names none of them.
                operationID: config.mode == .auth
                    ? [UInt8](repeating: 0, count: E2EWire.idLength)
                    : DeviceIdentity.systemRandom(E2EWire.idLength),
                trustedRootID: config.trustedRootID, policy: config.policy,
                revokedDeviceIDs: config.revokedDeviceIDs,
                expectedResponderDeviceID: config.expectedResponderDeviceID,
                // §12.3: in `pair` the descriptor is assembled AFTER the root is adopted, so the
                // session gets the keys rather than a descriptor naming a root nobody knows yet.
                // Derived here because the gate is what holds the private halves.
                devicePublicKeys: config.mode == .pair ? publicKeys() : nil))
        else { return terminate(.session(.malformed)) }

        // §11.1's table: `pair` is `Noise_XXpsk3`, everything else `Noise_XX`. The prologue binds
        // the mode, so neither end can choose a pattern the other did not.
        guard let prologue = session.prologue,
              let handshake = NoiseSession(mode: config.mode == .pair ? .pair : .xx,
                                           initiator: true, prologue: prologue,
                                           staticPrivateKey: config.noisePrivateKey,
                                           psk: config.mode == .pair ? config.pairingPSK : nil),
              let message1 = try? handshake.write(session.message1Payload)
        else {
            session.terminate()
            return terminate(.noise)
        }
        noise = handshake
        initiator = session
        return .success((message1, config.mode))
    }

    /// Handle one §11.3 envelope's ciphertext.
    ///
    /// **Any failure terminates.** §11.3 leaves no room for recovery, and a gate that answered a
    /// second time after refusing once would be exactly the oracle that rule exists to prevent.
    public func receive(_ ciphertext: [UInt8]) -> Result<Received, Failure> {
        guard !dead, let noise, initiator != nil else { return terminate(.notEstablished) }

        // Established sessions carry signalling, and nothing else reaches this branch — the
        // handshake arms below all advance the stage before it can.
        if maySignal {
            guard let inner = try? noise.read(ciphertext) else { return terminate(.noise) }
            return .success(.signalling(Data(inner)))
        }
        if handshakeHash != nil { return receiveSessionStart(noise, ciphertext) }
        return receiveMessage2(noise, ciphertext)
    }

    /// Wrap one outgoing signalling message. §11.2: nothing may be sent before the gate opens, and
    /// this is where that stops being a convention.
    public func seal(_ message: Data) -> Result<[UInt8], Failure> {
        guard !dead, let noise, maySignal else { return .failure(.notEstablished) }
        guard let sealed = try? noise.write([UInt8](message)) else { return terminate(.noise) }
        return .success(sealed)
    }

    public func close() {
        initiator?.terminate()
        dead = true
        noise = nil
    }

    // MARK: - the handshake

    private func receiveMessage2(_ noise: NoiseSession,
                                 _ ciphertext: [UInt8]) -> Result<Received, Failure> {
        guard var session = initiator else { return terminate(.notEstablished) }
        guard let plaintext = try? noise.read(ciphertext) else { return terminate(.noise) }

        // The static key NOISE authenticated, never one read out of the payload — which would be
        // the peer's own claim about itself.
        guard let staticKey = noise.remoteStaticKey else { return terminate(.noise) }
        if case .failure(let f) = session.receiveMessage2(plaintext, responderNoiseStatic: staticKey) {
            initiator = session
            return terminate(.session(f))
        }

        let payload3: [UInt8]
        switch session.message3Payload() {
        case .success(let p): payload3 = p
        case .failure(let f):
            initiator = session
            return terminate(.session(f))
        }
        guard let message3 = try? noise.write(payload3) else {
            initiator = session
            return terminate(.noise)
        }

        // The split happened inside that write: message 3 is the last handshake message this side
        // sends, and `client-confirm` immediately after it is already transport. The handshake hash
        // is only available once it has, which is also what makes it the session's identity.
        guard let h = noise.handshakeHash else {
            initiator = session
            return terminate(.noise)
        }
        handshakeHash = h

        let confirm: [UInt8]
        let appHello = config.appHello.count <= E2EWire.appHelloMax ? config.appHello : []
        switch session.clientConfirm(handshakeHash: h, newBundle: config.newBundle, appHello: appHello) {
        case .success(let c): confirm = c
        case .failure(let f):
            initiator = session
            return terminate(.session(f))
        }
        guard let sealed = try? noise.write(confirm) else {
            initiator = session
            return terminate(.noise)
        }

        initiator = session
        return .success(.reply([message3, sealed]))
    }

    private func receiveSessionStart(_ noise: NoiseSession,
                                     _ ciphertext: [UInt8]) -> Result<Received, Failure> {
        guard var session = initiator, let h = handshakeHash else {
            return terminate(.notEstablished)
        }
        guard let plaintext = try? noise.read(ciphertext) else { return terminate(.noise) }
        let done = session.receiveSessionStart(plaintext, handshakeHash: h)
        initiator = session
        if case .failure(let f) = done { return terminate(.session(f)) }
        return .success(.nothing)
    }

    private func terminate<T>(_ failure: Failure) -> Result<T, Failure> {
        initiator?.terminate()
        dead = true
        noise = nil
        return .failure(failure)
    }
}

public extension E2EClientGate.Config {
    /// Everything §11 needs to know about THIS client, from the one place that knows it.
    ///
    /// **Nil exactly when the device is not `ready`** — no root, no committed chain, or no keys —
    /// which is the right coupling: a device with no identity has nothing to present, and a gate
    /// built from placeholders would fail at the peer's chain check instead of at the door. The
    /// responder's `E2ESignallingGate.Config(loaded:policy:)` is the same function.
    init?(loaded: E2EIdentityManager.Loaded, policy: E2EVerify.Policy,
          expectedResponderDeviceID: [UInt8]? = nil) {
        guard let device = loaded.deviceDescriptor,
              let bundle = loaded.record.bundle,
              let rootID = loaded.trustedRootID else { return nil }
        self.init(device: device, bundle: bundle,
                  signingPrivateKey: loaded.installation.keys.signingPrivateKey,
                  noisePrivateKey: loaded.installation.keys.noisePrivateKey,
                  trustedRootID: rootID, policy: policy,
                  revokedDeviceIDs: loaded.record.revokedDeviceIDs,
                  expectedResponderDeviceID: expectedResponderDeviceID)
    }
}

public extension E2EClientGate {

    /// Why a native client has no gate. One sentence, meant to be printed.
    struct Unavailable: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// **The gate a NATIVE CLIENT comes up with**, or a reason it has none.
    ///
    /// `tools/RdevViewer` is the caller. It is an instrument, not a product: it never enrols, so
    /// its identity comes from `RDEV_E2E_TEST_IDENTITY` — the same prepared identity every migrated
    /// gate installs, minted by `scripts/gen_e2e_test_identities.py` for the origin the run uses.
    /// The §11 handshake still runs for real against real chains; what is skipped is the ceremony,
    /// which §12.1's own checks cover.
    ///
    /// **§10.1's ORIGIN is `RDEV_E2E_ORIGIN` when set**, exactly as `E2EHostIdentity.live` reads it,
    /// because the policy is per ORIGIN and a run whose two ends disagree fails with nothing in
    /// either log naming one. That is measured, more than once.
    ///
    /// Carries a SENTENCE on failure rather than a code: every one of these is something a person
    /// running a gate has to read and act on, and there is no caller that branches on which.
    static func forNativeClient(
        signalingBase: String,
        roomCode: String,
        expectedResponderDeviceID: [UInt8]? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<E2EClientGate, Unavailable> {
        let originValue = processEnvironment["RDEV_E2E_ORIGIN"].flatMap { $0.isEmpty ? nil : $0 }
            ?? signalingBase
        let resolved: E2EOrigin.Resolved
        switch E2EOrigin.resolve(originValue) {
        case .success(let r): resolved = r
        case .failure(let f):
            return .failure(.init("§10.1's origin \(originValue) is unusable: \(f.rawValue)"))
        }

        guard let stores = E2ETestIdentity.stores(processEnvironment: processEnvironment) else {
            return .failure(.init("""
                this viewer has no E2E identity and signalling is E2E-only. Set \
                RDEV_E2E_TEST_IDENTITY (and RDEV_E2E_TEST_ROLE=client) to a file minted by \
                scripts/gen_e2e_test_identities.py for \(originValue) — `mint_e2e_identities` in \
                scripts/lib.sh does it for a gate
                """))
        }
        let manager = E2EIdentityManager(installations: stores.installations, trust: stores.trust)
        guard case .success(let loaded) = manager.load() else {
            return .failure(.init("the prepared identity could not be loaded"))
        }
        guard let config = Config(loaded: loaded, policy: resolved.policy,
                                  expectedResponderDeviceID: expectedResponderDeviceID) else {
            // Nil means not `ready` — no root, no committed chain, or no keys. A gate built from
            // placeholders would fail at the host's chain check instead of at the door.
            return .failure(.init("the prepared identity is not enrolled"))
        }
        return .success(E2EClientGate(config: config, roomCode: roomCode))
    }
}
