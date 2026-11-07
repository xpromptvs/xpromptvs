import Foundation
import RdevCore
import RdevE2E

/// **SHARING — the door other devices come in by**, from Start to Stop Sharing (docs/sources-and-focus.md,
/// "The session's lifetime"). It holds:
/// - the relay socket;
/// - §11's gates, one per relay peer, and the pairing psk;
/// - the directory listing and the keep-awake hold.
///
/// It feeds relay peers into the SESSION's `PeerHub`. Stopping it lowers the curtain and makes every
/// relay client LEAVE; it leaves the tabs, the window state and every socket client alone. A quit is
/// what empties those (`HostSession.end`).
public final class SharingRoom {
    private let session: HostSession
    private let config: HostConfig
    private let code: String
    private let token: String
    private var transport: SignalingTransport?

    /// §11's gate, one per peer.
    ///
    /// **EVERY TOUCH GOES THROUGH `e2eQueue`, and only the Noise call happens inside it.**
    /// `SignalingTransport` delivers events serially, but `PeerHub` sends offers and candidates from
    /// its own thread, so the map and the sessions inside it are genuinely shared. `NoiseSession`
    /// requires ordering — every message advances a nonce counter, so two concurrent writes are a
    /// protocol error, not a data race to paper over.
    ///
    /// Delivery happens OUTSIDE the queue, the same rule `SimManager.lock` and `ChannelHub.lock`
    /// follow: `peerHub.answer` can call straight back into `sendIce`, and a callback made while
    /// holding this queue would deadlock on the next seal.
    private var e2eGates: [String: E2ESignallingGate] = [:]
    private let e2eQueue = DispatchQueue(label: "rdev.e2e.gates")
    /// Peers `PeerHub` has been told about, while §11.2 is enforced. **A peer that has not opened
    /// the gate is not a peer yet**, so `clientJoined` is DEFERRED until it has — and this is what
    /// keeps that call to exactly once, since the join and the handshake are separate events.
    private var e2eAdmitted: Set<String> = []
    private var fastIdentities: [String: Data] = [:]
    private let admissionLock = NSRecursiveLock()
    /// EVERY resume, held until the peer's fresh session opens. A resume always follows a new
    /// handshake — a client that re-hellos starts one, and a host that re-hellos has reset every
    /// session and told each client to (`resetAllE2E`) — so `PeerHub.resume` run on arrival would
    /// seal its offer into the session being replaced: withheld, or delivered to a socket that is
    /// mid-handshake, and either way never answered. `admit` runs it. Latest wins.
    private var e2eHeldResumes: [String: ResumeMode] = [:]
    /// Peers told `e2e-reset` since their last handshake began. ONCE per generation: a client's
    /// envelopes already in flight when the session died each fail in turn, and a reset per failure
    /// would reach the client's NEXT socket and kill the handshake it opened in answer to the first.
    private var e2eResetSent: Set<String> = []
    /// §9.1's psk for the pairing window this host is showing, or nil when it has none open.
    private let pairingPSK: [UInt8]?

    /// Set by `stop`, under `e2eQueue`. **A HANDSHAKE COMPLETING ACROSS STOP** runs `admit` on the transport
    /// thread after `stop`'s clear; without this it would register a relay client (claiming control, on a
    /// `connect` intent) into the SESSION, which outlives sharing, with no socket left to reach it.
    private var stopped = false
    /// `start()` has run (and `stop()` not): this room is SHARING. Main-thread state, as `start`/`stop` are.
    private var sharing = false

    private let e2eService: E2EIdentityService
    private let publisher: E2ESessionPublisher

    /// The session's `PeerHub`, OPTIONAL as the runtime's property was, so the §11 code moved below reads
    /// exactly as it did (`peerHub?.resume`, `guard let peerHub`).
    private var peerHub: PeerHub? { session.peerHub }

    /// THE OFFER'S SCREEN (docs/sources-and-focus.md, "The offer carries the tab bar"): the grid a NEW client said as
    /// it joined, kept for its first offer (taken by it); and each offer held for its screen, with the peer's
    /// candidates queued behind it. Guarded by `offerLock`, never taken while `e2eQueue` is held.
    private let offerLock = NSLock()
    private var joinGrids: [String: TermGridSize] = [:]
    private var heldOffers: [String: (token: UUID, ice: [[String: Any]])] = [:]
    /// How long an offer waits for its screen: the redraw's settle (150 ms at most) and a capture.
    static let offerScreenBudget: UInt64 = 300_000_000
    private var e2eIdentity: E2EHostIdentity? { e2eService.identity }
    private func e2eStatus() -> E2EHostStatus { e2eService.status() }

    /// `pairingPSK` is §9.1's third derived value for the window this host is showing. It NEVER leaves
    /// this process: not to the Control Plane, not to a log, not into captured output.
    public convenience init(session: HostSession, config: HostConfig, code: String, token: String,
                            pairingPSK: [UInt8]? = nil) {
        self.init(session: session, config: config, code: code, token: token, pairingPSK: pairingPSK,
                  e2e: E2EIdentityService.shared(signalingBase: config.signalingBase))
    }

    init(session: HostSession, config: HostConfig, code: String, token: String, pairingPSK: [UInt8]? = nil,
         e2e: E2EIdentityService, publisher: E2ESessionPublisher = E2ESessionPublisher()) {
        self.session = session
        self.config = config
        self.code = code
        self.token = token
        self.pairingPSK = pairingPSK
        self.e2eService = e2e
        self.publisher = publisher
    }

    /// What this Mac's listing is doing, for the app's row.
    public func publicationState() -> E2ESessionPublisher.State { publisher.state() }

    public func start() {
        session.hostUpdates.setAuthority { [weak self] peer in
            guard let self else { return nil }
            return self.e2eQueue.sync {
                guard !self.stopped, let gate = self.e2eGates[peer], gate.maySignal else { return nil }
                return HostUpdateRequester(chain: gate.peerChain)
            }
        }
        // One line, at the one moment every log has. `summary` carries no key material — a device
        // id is a public hash — and it is the fastest way to tell "this Mac is not enrolled" apart
        // from every other reason a client sees nothing.
        print("[e2e] \(e2eStatus().summary)")

        // LOAD-BEARING: held while SHARING, not while a client is connected. The state that cannot be
        // recovered remotely is "locked with nobody connected", and that is only ever entered during
        // the DISCONNECTED periods — so scoping this to connected clients would leave the failure
        // exactly as reachable while looking like a fix.
        if config.keepAwake { DisplayAwakeKeeper.shared.hold(.sharing) }

        // **AUTOMATIC, AND NOT AWAITED.** A Mac that is sharing is a Mac its owner's other devices
        // should be able to find. Nothing here can fail sharing — `E2ESessionPublisher` never throws
        // and the status is only ever read.
        //
        // **GUARDED ON `.ready`, not on "an identity object exists".** An unenrolled Mac has an
        // identity that can load and no chain to sign with, so it would sit reporting a listing
        // that was never attempted — the exact conflation the old boolean made. A Mac that enrols
        // mid-session starts publishing THEN (`publishIfReady`), not at its next Share.
        sharing = true
        publishIfReady()

        let wsBase = config.signalingBase.replacingOccurrences(of: "http", with: "ws")
        let wsURL = URL(string: "\(wsBase)/session/\(code)")!
        // `[weak self]` because the room OWNS this transport: capturing strongly would be a
        // cycle, and a host that never deallocates keeps its Noise sessions alive with it.
        let transport = SignalingTransport(url: wsURL, role: "host", token: token) { [weak self] event in
            self?.handle(event)
        }
        // **EVERY signalling message leaves inside an established Noise session** (§11.3), and a
        // peer without one gets nothing. There is no second path: a per-peer choice between the two
        // would be exactly the fallback §11.2 exists to forbid.
        // A FRESH offer — a new peer's, a rebuilt one's — carries the session's tab bar (`ChannelHub.offerState`), so
        // the client draws its real tabs while WebRTC connects; a restart's (the client has them) carries none. Sealed
        // with the offer, like everything here. A NEW client that said its grid as it joined (`joinGrids`) also gets
        // its active tab's SCREEN at that grid (`ChannelHub.offerScreen`): the offer waits for it, `offerScreenBudget`
        // at most, and goes without it after that.
        session.peerHub.onFastFailure = { [weak self] peer, generation in
            guard let self else { return }
            self.admissionLock.lock(); defer { self.admissionLock.unlock() }
            guard !self.e2eQueue.sync(execute: { self.stopped }),
                  self.session.peerHub.fastConnection(peer)?.generation == generation else { return }
            self.session.peerHub.clientLeft(peer)
            if let json = try? JSONSerialization.data(withJSONObject: ["t": "fast-error", "generation": base64urlEncode(generation)]) {
                self.sendSealed(json, to: peer)
            }
            self.closeE2E(peer: peer)
            self.resetE2E(peer, why: "fast-data delivery retired")
        }
        session.peerHub.sendOfferRestart = { [weak self] sdp, peer, restart in
            guard let self else { return }
            guard !restart else { self.sendSealed(offerJSON(sdp, peer: peer, restart: true), to: peer); return }
            let state = self.session.channelHub.offerState(forClient: peer)
            let token = UUID()
            let waits: Bool = self.offerLock.withLock {
                guard self.joinGrids.removeValue(forKey: peer) != nil else { return false }
                self.heldOffers[peer] = (token, [])
                return true
            }
            guard waits else { self.sendSealed(offerJSON(sdp, peer: peer, restart: false, state: state), to: peer); return }
            let asked = DispatchTime.now().uptimeNanoseconds
            self.session.channelHub.offerScreen(forClient: peer, within: Self.offerScreenBudget) { [weak self] screen in
                let ms = (DispatchTime.now().uptimeNanoseconds &- asked) / 1_000_000
                print("[offer] \(peer): \(screen.map { "the active tab's screen (\($0.count) bytes)" } ?? "no screen") after \(ms) ms")
                self?.releaseOffer(peer, token: token,
                                   offerJSON(sdp, peer: peer, restart: false, state: state + (screen.map { [$0] } ?? [])))
            }
        }
        // A peer's candidates follow its offer: while one is held (`releaseOffer`), they wait behind it, in order.
        session.peerHub.sendIce = { [weak self] cand, peer in
            guard let self else { return }
            let queued: Bool = self.offerLock.withLock {
                guard self.heldOffers[peer] != nil else { return false }
                self.heldOffers[peer]?.ice.append(cand)
                return true
            }
            if !queued { self.sendSealed(iceJSON(cand, peer: peer), to: peer) }
        }
        self.transport = transport
    }

    /// One relay event. Internal so the tests can deliver one without a relay.
    func handle(_ event: SignalingEvent) {
        // **A RELAY PEER NEVER SPEAKS FOR A SOCKET CLIENT** (`SocketClientID`). A relay id is any string the
        // relay accepts, so a `peer-left` for `sock:<id>` would reach `PeerHub.clientLeft` and unregister
        // the Mac's own local window; a `peer-joined` would admit a relay client under its id. Dropped
        // whole, before anything reads it.
        if let id = event.peerID, SocketClientID.isReserved(id) {
            print("[e2e] ignoring relay traffic for \(id): that id belongs to a socket client")
            return
        }
        let peerHub = session.peerHub
        switch event {
        case .welcome(let turn):
            peerHub.configure(turn: turn)
            // A welcome is this host's socket (re)connecting. Whatever either side sent while it
            // was down is gone, so every session is suspect; see `resetAllE2E`.
            resetAllE2E()
        // **§11.2: NO AUTHORITY EXISTS BEFORE THE GATE, INCLUDING A PEER CONNECTION.** Building
        // one on `peer-joined` sends an offer and candidates immediately, and while E2E is
        // required those are withheld — arriving before any session could exist, and never
        // resent. Measured: the handshake then completed against a peer whose negotiation had
        // already been thrown away, and the connection sat at "new" forever.
        case .peerJoined:
            // NOTHING. A peer that has joined the ROOM has joined nothing else: `admit` is what tells `PeerHub` a
            // peer exists, and it runs when the gate opens — reading what the client said there (`JoinHello`).
            break
        case .peerLeft(let id):
            // §11.3: "One signalling connection carries one Noise session and at most one
            // handshake. A reconnect starts a fresh handshake with fresh ephemerals." Keeping
            // the gate would offer the next occupant of that peer id someone else's session.
            closeE2E(peer: id)
            peerHub.clientLeft(id)
        case .peerSuspended(let id):
            peerHub.suspend(id)
            socketGone(id)
        case .peerResumed(let id, let mode): holdResume(id, mode: mode)
        // **PLAINTEXT SIGNALLING IS REFUSED OUTRIGHT.** The relay no longer carries these
        // shapes at all, so anything arriving in one is a peer trying to skip the handshake by
        // speaking a protocol this host retired — the same hole as a fallback, closed by
        // answering nothing.
        case .answer(_, let id):
            print("[e2e] refusing a plaintext answer from \(id)")
        case .ice:
            print("[e2e] refusing plaintext ICE")
        // §11.3's envelope, into §11's gate — the only way SDP and ICE travel now, in both
        // directions.
        case .e2e(let ct, let peer, let mode):
            receiveE2E(ct: ct, peer: peer, mode: mode)
        default: break
        }
    }

    // MARK: - §11.3 envelopes

    /// One incoming E2E envelope. Everything that decides anything is `E2ESignallingGate`; this
    /// routes, and drops what it cannot attribute.
    private func receiveE2E(ct: String, peer: String?, mode: E2EWire.Mode?) {
        // §11.3: "peer is routing only". An envelope with nowhere to belong cannot be attributed to
        // a session, and guessing "the only peer" would be the relay choosing the session for us.
        guard let peer, let ciphertext = base64urlDecode(ct) else { return }
        // Read PER NEW PEER rather than once at startup: a host that enrols while running must be
        // able to serve without a restart.
        guard let config = e2eService.gateConfig(pairingPSK: pairingPSK) else {
            print("[e2e] refusing a session from \(peer): this Mac is not enrolled")
            return
        }
        let outcome: (result: Result<E2ESignallingGate.Received, E2ESignallingGate.Failure>?,
                      established: Bool, reset: Bool) = e2eQueue.sync {
            // **A MODE MEANS A NEW HANDSHAKE, AND A NEW HANDSHAKE REPLACES THE SESSION.** §11.3: "A
            // reconnect starts a fresh handshake with fresh ephemerals", and the mode rides only an
            // initiator's first message. Fed to the OLD gate, that message is a decryption failure:
            // the gate drops itself, the message is gone, and the client waits for a reply that
            // never comes — measured, a client back from a long background sat on "reconnecting…"
            // for good. It gives the relay nothing new: one that forges this could drop the
            // session's traffic just as well.
            if mode != nil {
                if let old = e2eGates.removeValue(forKey: peer) { old.close() }
                e2eResetSent.remove(peer)
            }
            // **A SESSION ONLY EVER STARTS ON A MESSAGE CARRYING A MODE.** Anything else arriving
            // with no gate behind it is a STRAY — transport sealed into a session this host no
            // longer holds — and the client that sent it believes it is signalling.
            guard let gate = e2eGates[peer] ?? (mode != nil ? E2ESignallingGate(config: config, roomCode: code) : nil)
            else { return (nil, false, e2eResetSent.insert(peer).inserted) }
            e2eGates[peer] = gate
            let wasOpen = gate.maySignal
            let result = gate.receive(ciphertext, mode: mode)
            if case .success(.reply(let bytes)) = result { transport?.sendE2E(base64urlEncode(Data(bytes)), peer: peer) }
            var reset = false
            if case .failure = result {
                // §11.3 leaves no room for recovery: the gate has terminated itself, and keeping it
                // would let the same peer keep asking. Dropping it means a reconnect — a fresh
                // handshake with fresh ephemerals — which is what the specification calls for.
                e2eGates[peer] = nil
                // An OPEN session that fails is a desynchronised one: an envelope was lost on a
                // socket that read open while it died, or while this host's was down. Only the
                // client can start again, so it is TOLD. A failed HANDSHAKE is a refusal, and a
                // reset would only make the client ask the same question again.
                if wasOpen { reset = e2eResetSent.insert(peer).inserted }
            }
            return (result, gate.maySignal, reset)
        }
        if outcome.reset { resetE2E(peer, why: outcome.result == nil ? "a stray envelope" : "an open session failed") }
        guard let result = outcome.result else { return }

        switch result {
        case .success(.reply):
            if outcome.established {
                print("[e2e] session established with \(peer)")
                admit(peer)
            }
        case .success(.nothing):
            break
        // A sharing room's gate mints a guest's chain itself (`PairIssuer.subordinate`); only a passkey
        // issuer's gate parks, and none is built here.
        case .success(.awaitingIssuance):
            break
        case .success(.signalling(let inner)):
            deliverSignalling(inner, from: peer)
        case .failure(let failure):
            print("[e2e] session with \(peer) refused: \(failure)")
        }
    }

    /// One outgoing signalling message, inside the peer's session.
    ///
    /// **A peer with no established session gets NOTHING — never a plaintext copy.** §11.2 says no
    /// SDP or ICE authority exists before the gate, and a fallback here would be the whole protocol
    /// opted out of by a peer that simply declines to handshake.
    @discardableResult
    private func sendSealed(_ json: Data, to peer: String) -> Bool {
        let (sealed, reset): ([UInt8]?, Bool) = e2eQueue.sync {
            // An ADMITTED peer with no gate believes it has a session — the gate died under it — so
            // a withheld message is one it is waiting for. Tell it, once. A gate still handshaking
            // is a session on its way, and its held resume will send what matters.
            guard let gate = e2eGates[peer] else {
                return (nil, e2eAdmitted.contains(peer) && e2eResetSent.insert(peer).inserted)
            }
            guard gate.maySignal else { return (nil, false) }
            guard case .success(let ct) = gate.seal(json) else {
                e2eGates[peer] = nil
                return (nil, e2eResetSent.insert(peer).inserted)
            }
            transport?.sendE2E(base64urlEncode(Data(ct)), peer: peer)
            return (ct, false)
        }
        if reset { resetE2E(peer, why: "signalling was withheld") }
        guard let sealed else {
            print("[e2e] withholding signalling for \(peer): no established session")
            return false
        }
        return !sealed.isEmpty
    }

    /// One signalling message that arrived INSIDE an authenticated session. It is the same JSON the
    /// plaintext envelopes carry, so it goes through the same router — which is the point of
    /// choosing that encoding for §11.3's inner payload.
    var beforeFastMediaResumeForTests: (() -> Void)?
    func deliverSignallingForTests(_ inner: Data, from peer: String) { deliverSignalling(inner, from: peer) }

    private func deliverSignalling(_ inner: Data, from peer: String) {
        guard let peerHub else { return }
        if let obj = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
           let t = obj["t"] as? String, t.hasPrefix("fast-") {
            guard let fast = peerHub.fastConnection(peer) else { return }
            if t == "fast-record", let text = obj["data"] as? String, text.count <= 12000,
               let bytes = base64urlDecode(text), let record = FastData.decode(Data(bytes)) {
                fast.receive(record, from: .webSocket)
            } else if let text = obj["generation"] as? String, let generation = base64urlDecode(text), Data(generation) == fast.generation {
                if t == "fast-ready", let raw = obj["offsets"] as? [String], raw.count == 3 {
                    let offsets = raw.compactMap { $0.count <= 20 ? UInt64($0) : nil }
                    guard offsets.count == 3 else { return }
                    fast.markReady(); fast.resume(offsets: offsets)
                } else if t == "fast-media-rebuild" {
                    beforeFastMediaResumeForTests?()
                    admissionLock.lock(); defer { admissionLock.unlock() }
                    guard !e2eQueue.sync(execute: { stopped }), peerHub.fastConnection(peer) === fast else { return }
                    peerHub.resume(peer, mode: obj["mode"] as? String == "ice" ? .ice : .rebuild)
                }
            }
            return
        }
        switch SignalingRouter.route(inner) {
        case .answer(let sdp, _):       peerHub.answer(sdp, from: peer)
        case .ice(let cand, _):         if let cand { peerHub.ice(cand, from: peer) }
        default:
            // An authenticated peer sending something this host does not serve is a protocol error,
            // not an attack — but it is still not a reason to guess.
            print("[e2e] unhandled inner message from \(peer)")
        }
    }

    /// Tell `PeerHub` a peer exists, now that it has proved who it is. Exactly once per peer: the
    /// gate opens on one message, but a reconnect is a fresh handshake for the same peer id and
    /// `clientJoined` twice would build two peer connections for one client.
    ///
    /// A peer ALREADY admitted is one that reconnected and handshook again, and what it is owed is
    /// the resume its reconnect announced (`holdResume`) — run now, when its offer can be sealed
    /// into the session the client is actually holding.
    ///
    /// A peer whose join intent is `connect` TAKES CONTROL as it is admitted — a person connecting a
    /// client makes it the driver; a reconnect keeps its place (docs/sources-and-focus.md, "The join
    /// intent"). The client says it INSIDE the session it just proved (`JoinHello`, its `client-confirm`'s
    /// app_hello), so the relay — inside the adversary model (§4) — can neither read nor forge it.
    private func admit(_ peer: String) {
        admissionLock.lock(); defer { admissionLock.unlock() }
        let (isNew, held, closed, hello) = e2eQueue.sync {
            stopped ? (false, nil, true, [])
                    : (e2eAdmitted.insert(peer).inserted, e2eHeldResumes.removeValue(forKey: peer), false,
                       e2eGates[peer]?.appHello ?? [])
        }
        if closed { return }   // Stop Sharing ran first (see `stopped`)
        // What it said as it joined (`JoinHello`): its join intent and its terminal grid.
        let said = JoinHello.parse(hello)
        let claim = said.intent == .connect, grid = said.grid
        if said.fastData == 1 {
            let device = e2eQueue.sync { e2eGates[peer]?.peerChain.map { Data(E2EIdentity.deviceID($0.leaf.device)) } }
            guard let device else { return }
            let obj = (try? JSONSerialization.jsonObject(with: Data(hello))) as? [String: Any]
            let requested = (obj?["fastGeneration"] as? String).flatMap(base64urlDecode).map { Data($0) }
            let old = peerHub?.fastConnection(peer)
            let resumes = FastResume.accepts(retainedGeneration: old?.generation, offeredGeneration: requested, retainedDevice: e2eQueue.sync { fastIdentities[peer] }, authenticatedDevice: device)
            let generation: Data
            if resumes, let old { generation = old.generation }
            else { generation = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }) }
            e2eQueue.sync { fastIdentities[peer] = device }
            guard let fast = peerHub?.prepareFast(peer, generation: generation) else { return }
            fast.setWebSocketSender { [weak self] bytes in
                guard let self, let json = try? JSONSerialization.data(withJSONObject: ["t": "fast-record", "data": base64urlEncode(bytes)]) else { return false }
                return self.sendSealed(json, to: peer)
            }
            let start: [String: Any] = ["t": "fast-start", "version": 1, "generation": base64urlEncode(generation), "offsets": fast.receiveOffsets().map(String.init)]
            if let json = try? JSONSerialization.data(withJSONObject: start) { sendSealed(json, to: peer) }
        }
        if said.fastData != 1, peerHub?.fastConnection(peer) != nil {
            peerHub?.disableFast(peer)
            peerHub?.resume(peer, mode: .rebuild, claim: claim, grid: grid)
            return
        }
        // A held resume wins even for a peer this runtime never admitted: `PeerHub.resume` already
        // knows a peer it has never seen is a fresh join, and a retained one is not.
        if let held { peerHub?.resume(peer, mode: held, claim: claim, grid: grid) }
        else if isNew {
            if let grid, said.fastData != 1 { offerLock.withLock { joinGrids[peer] = grid } }
            peerHub?.clientJoined(peer, claim: claim, grid: grid)
        }
    }

    /// A held offer goes — with its screen, or without it at the budget — then the candidates that waited behind
    /// it, in order; one replaced by a newer offer for the peer (a rebuild) is dropped with its candidates. Sent
    /// UNDER `offerLock`, so a candidate arriving now cannot overtake the offer (nothing holding `e2eQueue` takes it).
    private func releaseOffer(_ peer: String, token: UUID, _ offer: Data) {
        offerLock.lock(); defer { offerLock.unlock() }
        guard let held = heldOffers[peer], held.token == token else { return }
        heldOffers[peer] = nil
        sendSealed(offer, to: peer)
        for cand in held.ice { sendSealed(iceJSON(cand, peer: peer), to: peer) }
    }

    private func holdResume(_ peer: String, mode: ResumeMode) {
        e2eQueue.sync { e2eHeldResumes[peer] = mode }
        socketGone(peer)
    }

    /// **The client's socket is gone, so its session is too** (§11.3: one connection, one session).
    /// Told by `peer-suspended` or `peer-resumed`, which the relay sends when the client's old socket
    /// closes and when its new one says hello. Kept, the gate goes on sealing into a session the
    /// client has discarded, and the relay delivers those to the client's NEW socket — where one
    /// arriving before message 2 kills the handshake (the client recovers on its `noise` retry).
    /// NARROWS A RACE NO GATE HITS: `gate-signalling-reconnect.sh` passes with this removed, so it is
    /// argued from §11.3, not measured. Withheld instead, and marked as reset because the client
    /// already knows: its own socket dropped. Its next message 1 starts the session again.
    private func socketGone(_ peer: String) {
        peerHub?.fastConnection(peer)?.setWebSocketSender(nil)
        e2eQueue.sync {
            e2eGates.removeValue(forKey: peer)?.close()
            e2eResetSent.insert(peer)
        }
    }

    /// Tell one client this host holds no session for it (`e2e-reset`). Called OUTSIDE `e2eQueue`.
    private func resetE2E(_ peer: String, why: String) {
        print("[e2e] told \(peer) to reconnect: \(why)")
        transport?.sendE2EReset(peer: peer)
    }

    /// **THIS HOST'S SOCKET RECONNECTED, SO EVERY SESSION IS SUSPECT.** The relay drops what a
    /// client sends while the host has no socket, and what the host sealed into its dying one never
    /// left — either desynchronises a Noise session in a way that surfaces only at the NEXT message,
    /// in whichever direction it happens to go. Keeping the sessions was luck; resetting them is a
    /// rule. Each client is told to reconnect, and the relay's `peer-resumed` for it is held until
    /// that client's fresh session opens. Unconditional on the reset set: an earlier reset may have
    /// gone down with the old socket. The first welcome finds nothing to reset.
    private func resetAllE2E() {
        let peers: [String] = e2eQueue.sync {
            for gate in e2eGates.values { gate.close() }
            let peers = Set(e2eGates.keys).union(e2eAdmitted)
            e2eGates.removeAll()
            e2eResetSent.formUnion(peers)
            return Array(peers)
        }
        for peer in peers { peerHub?.fastConnection(peer)?.setWebSocketSender(nil); resetE2E(peer, why: "this host's socket reconnected") }
    }

    private func closeE2E(peer: String) {
        e2eQueue.sync {
            e2eGates[peer]?.close()
            e2eGates[peer] = nil
            e2eAdmitted.remove(peer)
            fastIdentities.removeValue(forKey: peer)
            e2eHeldResumes[peer] = nil
            e2eResetSent.remove(peer)
        }
    }

    /// **STOP SHARING: THE DOOR CLOSES, THE SESSION STAYS.** In order:
    /// 1. The curtain comes down FIRST: never leave the shield up with nobody to lower it.
    /// 2. The listing is withdrawn and the keep-awake hold released.
    /// 3. §11's gates are dropped.
    /// 4. The relay socket CLOSES: before 2026-09-30 it was only dropped, and nothing cancelled its task.
    /// 5. Every relay client LEAVES (`PeerHub.allClientsLeft`).
    /// 6. The captures stop now, the state kept (`stopStreams`): those departures armed a grace for a
    ///    driver who can no longer return.
    /// 7. The curtain is lowered AGAIN, ASYNCHRONOUSLY on main, behind any raise a relay driver had
    ///    queued before its peer closed (see the comment at the call).
    ///
    /// The tabs, the window state and every socket client (the app's local window) are the SESSION's,
    /// and untouched: a quit is what empties them (`HostSession.end`).
    /// **A MAC THAT ENROLS WHILE SHARING IS LISTED THEN** (2026-10-07: the Mac mini, sharing since launch with no
    /// identity, was added by code — it reached the laptop, and the laptop's list never showed it, because this ran
    /// only at Start). The app calls it on every move of the e2e status to ready (`StatePublisher`); a no-op unless
    /// this room is sharing, the status is ready and the listing is not already being announced.
    public func publishIfReady() {
        guard sharing, !publisher.state().publishing, case .ready = e2eStatus(), let identity = e2eIdentity else { return }
        publisher.start(identity: identity, session: .init(code: code, token: token, label: Self.deviceLabel()))
    }

    /// Tests: what `start()` records about sharing, without its relay socket.
    func markSharingForTests() { sharing = true }

    public func stop() {
        admissionLock.lock(); defer { admissionLock.unlock() }
        sharing = false
        CurtainController.shared.lower()   // never tear down leaving the shield up
        // Withdraw the listing FIRST and without waiting: the 90 s TTL reaps it anyway, and quitting
        // must not block on a network round trip.
        publisher.stop(identity: e2eIdentity)
        DisplayAwakeKeeper.shared.release(.sharing)
        e2eQueue.sync {
            stopped = true
            for gate in e2eGates.values { gate.close() }
            e2eGates.removeAll()
            e2eAdmitted.removeAll()
            fastIdentities.removeAll()
            e2eHeldResumes.removeAll()
            e2eResetSent.removeAll()
        }
        transport?.close()
        transport = nil
        session.peerHub.allClientsLeft()
        // Those departures armed SimManager's 10 s grace for a driver who can no longer return: stop the
        // captures now (state kept), or the screen-recording indicator stays lit for nobody.
        session.stopStreams()
        // A relay driver's `curtain` raise arrives on a pion dispatcher thread and becomes
        // `DispatchQueue.main.async(_raise)`. In the app this method IS on main, so that raise cannot
        // run until we return, and a synchronous lower here would see it still down and the raise would
        // land AFTER Stop with nothing left to lower it (the dashboard's control is gated on sharing).
        // `allClientsLeft` closed every relay PionPeer and `pion_peer_close` drains its dispatcher
        // before returning, so every raise a relay driver sent is already queued on main AHEAD of this
        // block (FIFO): lowering ASYNC runs after it. Idempotent; off main (the harness) `lower()` hops
        // to main itself, so the async form is right there too.
        DispatchQueue.main.async { CurtainController.shared.lower() }
        // CLEARED LAST: live peers' dispatcher threads read these, unsynchronised. `PionPeer.close()` (in
        // `allClientsLeft`) drains each dispatcher before it returns, so no reader remains here, and a
        // callback fired while closing met the gates still up but the sockets gone, and was withheld.
        session.peerHub.sendOfferRestart = nil
        session.peerHub.sendIce = nil
        session.peerHub.onFastFailure = nil
    }

    public func setCurtain(_ on: Bool) {
        on ? CurtainController.shared.raise() : CurtainController.shared.lower()
    }

    public var curtainIsUp: Bool { CurtainController.shared.isUp }

    /// What a person reads in a listing. §10.4's SIGNED device labels are the trustworthy version of
    /// a name; this is not one, and `docs/e2e.md` records why a directory-supplied name is "one the
    /// same adversary chose". The computer's own name is what a person already recognises, and an
    /// empty string is the honest answer when macOS will not give one — never an invented default.
    static func deviceLabel() -> String {
        let name = Host.current().localizedName ?? ""
        return String(name.prefix(64))
    }
}
