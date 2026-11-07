import Foundation
import RdevCore
import RdevE2E

/// **ADOPT BY CODE: a Mac enrolled by showing its own QR.**
///
/// The Mac opens §9.1's pairing window, renders the carrier, waits for the relay to say a peer
/// arrived, and **initiates** §11.1's `pair`. The browser that scanned the code holds the passkey and
/// answers, minting a root-signed grant at capability `2` — host, and nothing else.
///
/// **THE CARRY DIRECTION IS REVERSED FROM GUEST PAIRING AND THE PROTOCOL DIRECTION IS NOT.** In guest
/// pairing the Issuer shows the code and a browser arrives to be granted access; here the newcomer
/// shows it and the Issuer arrives to grant. Either way the newcomer is the Noise INITIATOR receiving
/// a grant, so this reuses `E2EClientGate`'s `pair` arm unchanged rather than needing a fourth mode
/// whose responder is the party being adopted. §9.1 says only a directly enrolled Issuer may ISSUE
/// through a window for exactly this reason: opening one is a rendezvous, not an authority.
///
/// **What the psk buys, and it is the reason this path exists at all.** The seed is on the Mac's own
/// screen, so only someone standing at it can complete `XXpsk3` — the root that arrives is
/// authenticated as coming from a device that person was holding — the risk `a63ab8c7` accepted for
/// the browser-aided §12.1 (deleted 2026-10-06), and the reason this path stays beside the Mac's own
/// passkey sign-in: it needs the passkey on ANY device that can see this screen.
///
/// IO is injected — the window opener and the socket — because the decisions are testable and a
/// WebSocket is not. `AdoptByCodeTests` drives the whole thing against a REAL `E2ESignallingGate`
/// with only the socket faked, so the handshake under test is the production one.
public actor AdoptByCode {

    /// What the Devices row shows. **The psk never appears here**, or in a log, or in a crash report.
    public enum Phase: Equatable, Sendable {
        case idle
        /// The QR is up and nobody has scanned it. `carrier` is the 22 characters a person carries.
        case waiting(carrier: String, code: String)
        /// A peer arrived and the handshake is running.
        case handshaking
        case enrolled(deviceID: [UInt8])
        /// Why the last attempt ended. A row that says nothing is indistinguishable from a dead
        /// button, which is the defect `unenrolled`'s `detail` already exists to prevent.
        case failed(reason: String)
    }

    /// One §11.3 envelope in either direction, plus the two socket facts this flow reacts to.
    public enum Event: Sendable {
        case peerJoined(String)
        /// `mode`: present only on an INITIATOR's first message — never on a reply to this Mac's.
        case e2e(ct: String, peer: String?, mode: E2EWire.Mode? = nil)
        case closed
    }

    /// The socket, reduced to what this flow uses. `send` addresses a peer because the relay makes a
    /// host name one: "Host -> a specific client, named in `peer`. A host may hold several."
    public protocol Transport: Sendable {
        func send(ct: String, peer: String, mode: E2EWire.Mode?)
        func close()
    }

    public typealias Connect = @Sendable (_ url: URL, _ token: String)
        -> (transport: Transport, events: AsyncStream<Event>)
    public typealias OpenWindow = @Sendable (_ signalingBase: String)
        async -> Result<PairingWindowOpener.Opened, PairingWindowOpener.Failure>
    /// §12.2's registration for the grant just committed, keyed on its own operation id.
    public typealias Publish = @Sendable (_ operationID: [UInt8]) async -> Void

    private let manager: E2EIdentityManager
    private let policy: E2EVerify.Policy
    private let openWindow: OpenWindow
    private let connect: Connect
    /// §9.1: "A pairing window lasts 120 seconds by default."
    private let windowSeconds: Double
    /// **A HANDSHAKE THAT STOPS MOVING ENDS** (2026-10-07): once the issuer has answered, nothing bounded it — its
    /// last message lost (the Mac mini's connection dropped as its chain was sent) left "Adding this Mac…" up for
    /// good. Silence from the peer this long, mid-handshake, is `stalled`. Long enough for a person to read "Add
    /// this Mac?" on the other device and touch the sensor.
    private let stallSeconds: Double
    private var lastHeard = Date()
    private var stalled = false
    private var cancelled = false
    private let publish: Publish
    private var current: Phase = .idle
    /// The live socket, held so the window's own timer can end it. Without that, a QR nobody scans
    /// waits on an event stream that will never produce one — the expiry has to CLOSE something, not
    /// merely be checked the next time something arrives.
    private var active: Transport?
    private var expired = false

    public init(manager: E2EIdentityManager,
                policy: E2EVerify.Policy,
                openWindow: @escaping OpenWindow = { await PairingWindowOpener.open(signalingBase: $0) },
                connect: @escaping Connect = AdoptByCode.liveConnect,
                publish: @escaping Publish = { _ in },
                windowSeconds: Double = 120,
                stallSeconds: Double = 150) {
        self.stallSeconds = stallSeconds
        self.publish = publish
        self.manager = manager
        self.policy = policy
        self.openWindow = openWindow
        self.connect = connect
        self.windowSeconds = windowSeconds
    }

    public var phase: Phase { current }

    /// Open a window, show it, and run one adoption to a conclusion.
    ///
    /// Returns the terminal phase rather than throwing: every outcome here is something a row has to
    /// say, including the ones that are nobody's fault.
    @discardableResult
    public func start(signalingBase: String) async -> Phase {
        guard case .success(let loaded) = manager.load() else {
            return finish(.failed(reason: "identity-unreadable"))
        }
        // **Only an unenrolled Mac may be adopted.** A device holding a chain that ran this would be
        // asking a second root to certify it, and §10.1 forbids an incoming chain replacing a
        // trusted one. Upgrading an enrolled Mac is §12.1's ceremony, not this.
        guard loaded.record.bundle == nil else { return finish(.failed(reason: "already-enrolled")) }

        let opened: PairingWindowOpener.Opened
        switch await openWindow(signalingBase) {
        case .success(let o): opened = o
        case .failure(let f): return finish(.failed(reason: f.rawValue))
        }
        current = .waiting(carrier: opened.carrier, code: opened.material.code)

        guard let url = sessionURL(opened) else { return finish(.failed(reason: "malformed")) }
        let (transport, events) = connect(url, opened.material.token)
        active = transport
        expired = false
        defer { transport.close(); active = nil }

        // §11.1's `pair`: no descriptor and no chain — a §10.2 descriptor NAMES its root and this
        // device does not know one yet, so the gate assembles it after message 2 from these keys.
        let gate = E2EClientGate(
            config: .init(device: [], bundle: [],
                          signingPrivateKey: loaded.installation.keys.signingPrivateKey,
                          noisePrivateKey: loaded.installation.keys.noisePrivateKey,
                          trustedRootID: nil, policy: policy,
                          mode: .pair, pairingPSK: opened.material.psk),
            roomCode: opened.material.code)

        return await run(gate: gate, transport: transport, events: events, loaded: loaded)
    }

    // MARK: - the session

    private func run(gate: E2EClientGate, transport: Transport,
                     events: AsyncStream<Event>, loaded: E2EIdentityManager.Loaded) async -> Phase {
        var peer: String?

        // **The window is bounded whatever happens on the socket.** §9.1 destroys the secret on
        // expiry, and a QR left up forever is a secret left readable forever — so this does not
        // merely check a deadline when something arrives, which is exactly the case where nothing
        // does. It closes the socket, which ends the stream below.
        let expiry = Task { [weak self, windowSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(windowSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expire()
        }
        defer { expiry.cancel() }
        // The handshake's own bound (`stallSeconds`), checked once a second — the case it exists for is the one
        // where nothing arrives to check it on.
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.checkStall()
            }
        }
        defer { watchdog.cancel() }

        for await event in events {
            if cancelled || stalled || expired { return finish(.failed(reason: endReason)) }
            switch event {
            case .closed:
                return finish(.failed(reason: endReason))

            case .peerJoined(let id):
                // **THE MAC SPEAKS FIRST.** It owns the room because it registered the code, and the
                // relay is what tells it somebody is there to speak to.
                guard peer == nil else { continue }   // a second scanner is not a second session
                peer = id
                lastHeard = Date()
                current = .handshaking
                switch gate.start() {
                case .success(let first):
                    transport.send(ct: b64u(first.ciphertext), peer: id, mode: first.mode)
                case .failure(let f):
                    return finish(.failed(reason: "gate/\(f)"))
                }

            case .e2e(let ct, let from, let mode):
                guard let peer, from == nil || from == peer else { continue }
                lastHeard = Date()
                // **THE PEER OPENED A HANDSHAKE OF ITS OWN**: only an initiator names a mode, and here this
                // Mac is the initiator. A device that does that took the code for a connection code — it
                // was pasted into Connect, which starts a GUEST pairing. Said as that, rather than as the
                // `gate/noise` its first message would produce read as a reply (2026-10-07: exactly what a
                // person saw, adding the Mac mini by pasting its code into Connect).
                if mode != nil { return finish(.failed(reason: "entered-in-connect")) }
                guard let ciphertext = fromB64u(ct) else {
                    return finish(.failed(reason: "malformed-envelope"))
                }
                switch gate.receive(ciphertext) {
                case .failure(let f):
                    return finish(.failed(reason: "gate/\(f)"))
                case .success(let received):
                    if case .reply(let cts) = received {
                        for out in cts { transport.send(ct: b64u(out), peer: peer, mode: nil) }
                    }
                    if gate.maySignal, let bundle = gate.acceptedBundle, !bundle.isEmpty {
                        let outcome = commit(bundle: bundle, loaded: loaded)
                        // **THE ISSUER HEARS WHAT HAPPENED** (`AdoptionAck`), inside the session that just opened
                        // and BEFORE anything slower: it says "added" only on this. Until 2026-10-07 it said so as
                        // the chain left it, and a chain lost on the way read as a success there.
                        let ack: AdoptionAck
                        if case .failed(let reason) = outcome { ack = .refused(reason: reason) } else { ack = .adopted }
                        if case .success(let sealed) = gate.seal(ack.json) {
                            transport.send(ct: b64u(sealed), peer: peer, mode: nil)
                        }
                        // Said NOW, not after the registration below: the Devices row stops saying "Adding this
                        // Mac…" the moment the chain is committed.
                        current = outcome
                        // **§12.2's publication, and THIS side holds the job.** The same ordering
                        // §12.3 gives: durable local commit first, then the attempt — publication is
                        // best-effort and never a precondition for access, so a Worker that never
                        // answers costs this Mac its listing and not its identity. `retryRegistration`
                        // drains what this leaves behind.
                        if case .enrolled = outcome, let operationID = operationID(of: bundle) {
                            await publish(operationID)
                        }
                        return finish(outcome)
                    }
                }
            }
        }
        return finish(.failed(reason: endReason))
    }

    /// Why the socket ended, in order of who decided: the person, the handshake's bound, the window's, the network.
    private var endReason: String {
        cancelled ? "cancelled" : stalled ? "stalled" : expired ? "expired" : "disconnected"
    }

    /// **STOP, from the Devices row** (2026-10-07: "Adding this Mac…" offered no way out). Ends the attempt here; it
    /// cannot take back a chain the other device already signed — but nothing is committed on THIS Mac unless that
    /// chain arrived, and a chain for this Mac's keys is useless to anyone else.
    public func cancel() {
        switch current {
        case .enrolled, .failed: return
        case .idle, .waiting, .handshaking: break
        }
        cancelled = true
        active?.close()
    }

    private func checkStall() {
        guard case .handshaking = current, Date().timeIntervalSince(lastHeard) > stallSeconds else { return }
        stalled = true
        active?.close()
    }

    /// §9.1's 120 seconds, arriving as an action rather than a comparison.
    private func expire() {
        guard case .waiting = current else { return }   // a handshake in flight is not abandoned
        expired = true
        active?.close()
    }

    /// **The commit is what makes this real**; the socket closing afterwards changes nothing.
    ///
    /// `E2EIdentityManager` does the verification — the chain must verify under the root it names and
    /// must certify THIS device's descriptor — and it is not reimplemented here. A bundle for another
    /// device commits nothing, which is the one mistake a session holding two identities can make.
    private func commit(bundle: [UInt8], loaded: E2EIdentityManager.Loaded) -> Phase {
        guard case .success(let parsed) = E2ECertificate.parseBundle(bundle) else {
            return .failed(reason: "malformed-chain")
        }
        // §10.1: a root is ADOPTED before a chain under it can be committed, and this device had
        // none. The psk is what authorises it — see this type's own note.
        guard case .success(let adopted) = manager.adoptRoot(parsed.root, into: loaded.record) else {
            return .failed(reason: "root-not-adopted")
        }
        guard case .success(let reloaded) = manager.load() else {
            return .failed(reason: "identity-unreadable")
        }
        _ = adopted
        switch manager.commit(bundle: bundle, status: .unconfirmed, into: reloaded, policy: policy) {
        case .success:
            guard let descriptor = reloaded.deviceDescriptor else {
                return .failed(reason: "identity-unreadable")
            }
            return .enrolled(deviceID: E2EIdentity.deviceID(descriptor))
        case .failure(let f):
            return .failed(reason: f.rawValue)
        }
    }

    /// §12.2 keys idempotence on `(root_id, operation_id)`, so a retry must reuse the grant's OWN
    /// id rather than mint one — a fresh id would make every retry a second registration.
    private func operationID(of bundle: [UInt8]) -> [UInt8]? {
        guard case .success(let parsed) = E2ECertificate.parseBundle(bundle),
              let leaf = parsed.certificates.last,
              let grant = E2EIdentity.parseGrant(leaf.grant) else { return nil }
        return grant.operationID
    }

    private func finish(_ phase: Phase) -> Phase {
        current = phase
        return phase
    }

    private func sessionURL(_ opened: PairingWindowOpener.Opened) -> URL? {
        guard var comps = URLComponents(string: opened.sessionURL) else { return nil }
        if comps.scheme == "http" { comps.scheme = "ws" }
        if comps.scheme == "https" { comps.scheme = "wss" }
        return comps.url
    }

    // MARK: - base64url, which the envelope carries and nothing else here needs

    private func b64u(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func fromB64u(_ s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { [UInt8]($0) }
    }

    /// The real socket, behind the same `Transport` the tests fake.
    public static let liveConnect: Connect = { url, token in
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let socket = SignalingTransport(url: url, role: "host", token: token) { event in
            switch event {
            case .peerJoined(let id): continuation.yield(.peerJoined(id))
            case .e2e(let ct, let peer, let mode): continuation.yield(.e2e(ct: ct, peer: peer, mode: mode))
            case .peerLeft: continuation.yield(.closed)
            default: break
            }
        }
        return (LiveTransport(socket: socket, continuation: continuation), stream)
    }

    private struct LiveTransport: Transport {
        let socket: SignalingTransport
        let continuation: AsyncStream<Event>.Continuation
        func send(ct: String, peer: String, mode: E2EWire.Mode?) {
            socket.sendE2E(ct, peer: peer, mode: mode)
        }
        func close() {
            socket.close()
            continuation.finish()
        }
    }
}
