import Foundation
import RdevCore
import RdevE2E

/// **ADD DEVICE BY CODE, FROM A MAC: this Mac holds the identity, and a new Mac showed its code.**
/// (2026-10-07, asked for: "We should add a dedicated Add device by code workflow" — after a person pasted a
/// new Mac's code into Connect, which starts a GUEST pairing where both ends speak first, and the new Mac
/// refused the handshake as `gate/noise`.)
///
/// The ISSUER's half of adopt-by-code — what `web/src/client/adopt.ts` does in a browser — in the app: the new
/// Mac (`AdoptByCode`) opened §9.1's window and initiates §11.1's `pair`; this side joins that room as a
/// CLIENT, ANSWERS (`E2ESignallingGate` with `PairIssuer.passkey`), asks the person to confirm the identity
/// the Mac will join, and has the ROOT's passkey sign a DIRECT capability-`2` grant for the descriptor the
/// handshake authenticated, bound to that exact transcript (§10.3's remote binding) — the grant a browser
/// issues, built the same way (`E2EPasskeyGrant.request(issuingTo:)`).
///
/// **The psk is the authorisation, and the confirmation is the NAMING** (adopt.ts's own words): only someone
/// standing at that Mac could read its code, so the person is told which identity it is about to join and
/// asked to say yes before anything is signed. Confirmation comes BEFORE the assertion.
///
/// The new Mac commits and publishes what it is given (`AdoptByCode`); nothing here writes this Mac's own
/// identity. `AddDeviceByCodeTests` runs a real `AdoptByCode` against this, with only the relay and the
/// passkey faked.
public actor AddDeviceByCode {

    /// What the dashboard's Add device dialog shows. **The psk never appears here.**
    public enum Phase: Equatable, Sendable {
        case idle
        /// In the code's room; the new Mac has not spoken yet.
        case waiting
        /// The new Mac is authenticated and owed a chain. Nothing is signed until the person says so.
        case confirm(identityCode: String)
        /// The passkey has been asked for.
        case issuing
        /// Its chain was sent; waiting for the new Mac's word that it committed it (`AdoptionAck`).
        case finishing
        /// The new Mac COMMITTED its chain — it said so. `publication` is what this Mac knows of its own listing (§12.2).
        case added(publication: E2EWire.PublicationStatus)
        case failed(reason: String)
    }

    /// One §11.3 envelope from the new Mac, a refusal from the relay, or the socket gone.
    public enum Event: Sendable {
        case e2e(ct: String, mode: E2EWire.Mode?)
        case error(String)
        case closed
    }

    /// The socket, as a CLIENT: one peer, so a send names none.
    public protocol Transport: Sendable {
        func send(ct: String)
        func close()
    }

    public typealias Connect = @Sendable (_ url: URL, _ token: String)
        -> (transport: Transport, events: AsyncStream<Event>)

    private let identity: E2EHostIdentity
    private let authenticator: PasskeyAuthenticator
    private let connect: Connect
    /// How long the new Mac has to speak once this side is in its room. It speaks the moment the relay says
    /// somebody joined, so silence means no Mac is showing that code (an expired or mistyped one whose room
    /// still exists, or a Mac that went away).
    private let answerSeconds: Double
    /// How long the new Mac has, once its chain is sent, to say it committed it (`AdoptionAck`). It commits and says
    /// so in milliseconds; silence means the chain never reached it (2026-10-07: the Mac mini's connection dropped
    /// as its chain was sent, and this side said "added").
    private let ackSeconds: Double

    private var current: Phase = .idle
    private var transport: Transport?
    private var gate: E2ESignallingGate?
    private var root: E2EIdentity.Root?
    /// What this Mac knows of its own listing, told to the new Mac in `session-start` and shown with `added`.
    private var publication: E2EWire.PublicationStatus = .unconfirmed
    private var heard = false

    public init(identity: E2EHostIdentity, authenticator: PasskeyAuthenticator,
                connect: @escaping Connect = AddDeviceByCode.liveConnect, answerSeconds: Double = 30,
                ackSeconds: Double = 20) {
        self.identity = identity
        self.authenticator = authenticator
        self.connect = connect
        self.answerSeconds = answerSeconds
        self.ackSeconds = ackSeconds
    }

    public var phase: Phase { current }

    /// Join the room `carrier` names and run one adoption to its end — `added` or `failed`. The person's
    /// answer to `confirm` arrives through `decide`; `cancel` ends it from outside.
    @discardableResult
    public func start(carrier: String, signalingBase: String) async -> Phase {
        guard let seed = PairingSeed.decode(carrier.trimmingCharacters(in: .whitespacesAndNewlines)),
              let material = PairingSeed.derive(seed: seed) else { return finish(.failed(reason: "not-a-code")) }
        guard case .success(let loaded) = identity.manager.load(),
              let config = E2ESignallingGate.Config(loaded: loaded, policy: identity.policy,
                                                    pairingPSK: material.psk, pairIssuer: .passkey),
              let rootBytes = loaded.record.root, let parsedRoot = E2EIdentity.parseRoot(rootBytes)
        else { return finish(.failed(reason: "no-identity")) }
        guard let url = Self.sessionURL(signalingBase, code: material.code) else {
            return finish(.failed(reason: "malformed"))
        }
        root = parsedRoot
        publication = config.publicationStatus
        gate = E2ESignallingGate(config: config, roomCode: material.code)
        let (socket, events) = connect(url, material.token)
        transport = socket
        current = .waiting

        let silence = Task { [weak self, answerSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(answerSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.noAnswer()
        }
        defer { silence.cancel() }

        for await event in events {
            if isFinished { break }
            switch event {
            case .error(let code):
                fail(isWaitingForWord ? "unconfirmed" : code)
            case .closed:
                // The new Mac's room closed — it gave up, or it is gone. After its chain was sent and before its
                // word, nobody knows whether it committed.
                fail(isWaitingForWord ? "unconfirmed" : "disconnected")
            case .e2e(let ct, let mode):
                heard = true
                guard let bytes = base64urlDecode(ct), let gate else { fail("malformed-envelope"); break }
                switch gate.receive(bytes, mode: mode) {
                case .failure(let f): fail("gate/\(f)")
                case .success(.reply(let out)): socket.send(ct: base64urlEncode(Data(out)))
                case .success(.nothing): break
                case .success(.signalling(let message)):
                    // Only the new Mac's word, and only once its chain is out: anything else is not for this flow.
                    guard isWaitingForWord, let ack = AdoptionAck.parse(message) else { break }
                    switch ack {
                    case .adopted:
                        current = .added(publication: publication)
                        socket.close()
                    case .refused(let reason):
                        fail("mac-refused/\(reason)")
                    }
                case .success(.awaitingIssuance):
                    current = .confirm(identityCode: E2EIdentity.code(rootID: parsedRoot.id))
                }
            }
        }
        socket.close()
        if !isFinished { current = .failed(reason: isWaitingForWord ? "unconfirmed" : "disconnected") }
        return current
    }

    /// The person's answer to `confirm`: add it — the passkey is asked for — or not.
    public func decide(_ add: Bool) async {
        guard case .confirm = current else { return }
        guard add else { return fail("cancelled") }
        guard let gate, let root, let pending = gate.pendingIssuance,
              let request = E2EPasskeyGrant.request(
                issuingTo: pending.device, rootID: root.id,
                binding: .remote(handshakeHash: pending.handshakeHash,
                                 responderDeviceID: pending.responderDeviceID))
        else { return fail("malformed") }
        current = .issuing
        // §4: the root descriptor rides the assertion that was going to happen anyway — the browser writes the
        // credential's large blob on its grant assertion too, so the authenticator can name the root itself.
        let answer: E2EPasskeyGrant.Answer
        switch await authenticator.assert(rpID: identity.relyingParty, challenge: request.challenge,
                                          allowedCredentials: [root.credentialID], largeBlob: .write(root.bytes)) {
        case .success(let a): answer = a
        case .failure(.dismissed): return fail("cancelled")
        case .failure(let f): return fail(E2EPasskeyFailure.passkey(f).reason)
        }
        // The socket may have gone, or a cancel come, while the person touched the sensor.
        guard case .issuing = current else { return }
        guard let bundle = E2EPasskeyGrant.bundle(root: root, answer: answer, request: request,
                                                  device: pending.device, policy: identity.policy)
        else { return fail("unverified") }
        switch gate.issue(bundle) {
        case .failure(let f): return fail("gate/\(f)")
        case .success(let ct):
            transport?.send(ct: base64urlEncode(Data(ct)))
            // NOT "added" yet: that is the new Mac's to say (`AdoptionAck`), and the event loop hears it.
            current = .finishing
            let wait = ackSeconds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                await self?.noWord()
            }
        }
    }

    /// Stop. Nothing has been signed unless the passkey already answered, and then the chain is already sent.
    public func cancel() {
        guard !isFinished else { return }
        fail("cancelled")
    }

    // MARK: -

    private var isFinished: Bool {
        switch current {
        case .added, .failed: return true
        case .idle, .waiting, .confirm, .issuing, .finishing: return false
        }
    }

    private var isWaitingForWord: Bool {
        if case .finishing = current { return true }
        return false
    }

    private func noWord() {
        guard isWaitingForWord else { return }
        fail("unconfirmed")
    }

    private func noAnswer() {
        guard !heard, case .waiting = current else { return }
        fail("no-answer")
    }

    private func fail(_ reason: String) {
        guard !isFinished else { return }
        current = .failed(reason: reason)
        gate?.close()
        transport?.close()
    }

    private func finish(_ phase: Phase) -> Phase {
        current = phase
        return phase
    }

    /// `wss://<base>/session/<code>` — the room the new Mac registered.
    static func sessionURL(_ base: String, code: String) -> URL? {
        guard var comps = URLComponents(string: base), comps.scheme != nil else { return nil }
        if comps.scheme == "http" { comps.scheme = "ws" }
        if comps.scheme == "https" { comps.scheme = "wss" }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/session/" + code
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }

    /// The real socket: the relay's CLIENT role.
    public static let liveConnect: Connect = { url, token in
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        // A RESUME ID FOR THIS RUN: a reconnect while the person decides comes back as the SAME client, which the new
        // Mac is handshaking with — without one the relay mints a new id and the new Mac ignores it.
        let socket = SignalingTransport(url: url, role: "client", token: token,
                                        resumeId: UUID().uuidString.lowercased()) { event in
            switch event {
            case .e2e(let ct, _, let mode): continuation.yield(.e2e(ct: ct, mode: mode))
            case .error(let code, _): continuation.yield(.error(code))
            // The new Mac's room closed (`hostLeft` — the relay's `peer-left` with `role: "host"`).
            case .hostLeft: continuation.yield(.closed)
            default: break
            }
        }
        return (LiveTransport(socket: socket, continuation: continuation), stream)
    }

    private struct LiveTransport: Transport {
        let socket: SignalingTransport
        let continuation: AsyncStream<Event>.Continuation
        func send(ct: String) { socket.sendE2E(ct) }
        func close() {
            socket.close()
            continuation.finish()
        }
    }
}
