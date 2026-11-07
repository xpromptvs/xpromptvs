import Foundation
import RdevCore

/// One per host. Fans terminal output out to every connected client's terminal
/// channel and funnels every client's input into the one shared PTY + injector.
/// Clients register/unregister their ClientConnection (a WebRTC peer, or a socket) as they join/leave.
/// @unchecked Sendable: all shared mutable state (the terminal model + the open-
/// peer map) is guarded by `lock`; channel sends happen outside the lock.
/// PionPeerDelegate methods are called from pion's goroutine threads — do NOT
/// add @MainActor anywhere on the delegate path.
public final class ChannelHub: NSObject, @unchecked Sendable {
    public let hostUpdates = HostUpdates()
    var agents: AgentManager?
    private let agentSender = AgentSender()
    private var agentViewers: [ObjectIdentifier: UInt64] = [:] // guarded by lock, explicit hello only

    private let terminals: TerminalManager
    /// AN IMAGE PATH IN THE TERMINAL OPENS ON THE CLIENT (`FileFetch`): reads and sends off the message path.
    let fileFetcher: FileFetcher
    private var sourceInputCapabilities: [String: ObjectIdentifier] = [:]
    private var sourceInputRoute = SourceInputRoute()
    private var sourceFocusRequest: SourceFocusRequest?
    private var injector: InputInjector?          // swappable (guarded by `lock`); nil when unbound
    public weak var simDelegate: SimControlDelegate?  // set by main.swift (not on the test-pattern path)

    /// Route one adaptive-FlexFEC controller decision to SimManager.
    ///
    /// NO SimManager IS SUCCESS, NOT FAILURE, and the first version of this returned `false` on the
    /// stated grounds that "nothing applied the update" — which conflated two different things.
    /// The status answers "did your decision take effect?", and where there are no per-source
    /// encoders at all nothing contradicts it, so it did. A genuine failure is an INVALID update
    /// (which the coordinator rejects before reaching here) or a host that has gone away. This is
    /// the same rule `SimManager.applyRecoveryPolicy` already states for a source with no encoder
    /// yet or an empty subscription set.
    ///
    /// IT IS NOT HYPOTHETICAL: the adaptive controller acknowledges an initial off-tier update from
    /// inside `pion_peer_create`, so returning false here killed every session on the headless
    /// test-pattern path at creation — measured, with `create adaptive FlexFEC controller:
    /// acknowledge adaptive FlexFEC initial off tier`. That path has no client prefs and no
    /// per-source bitrate model, so there is genuinely nothing for a ratio to apply to.
    @discardableResult
    public func applyRecoveryPolicy(mediaBitrateBps: UInt32, budgetBps: UInt32) -> Bool {
        guard let simDelegate else { return true }
        return simDelegate.applyRecoveryPolicy(mediaBitrateBps: mediaBitrateBps, budgetBps: budgetBps)
    }
    /// Whether the (global, host-owned) view set currently has a subscription — wired in main.swift to
    /// SimManager.hasSubscription. Video delivery follows the SUBSCRIPTION, not active-status: the active
    /// client gets a delivery track only when something is subscribed, so a client that CLAIMS an
    /// intentionally-hidden session does not resurrect the stream. `nil` on the headless smoke path (no
    /// SimManager) ⇒ the single active client always gets one "test" track.
    public var isVideoSubscribed: (() -> Bool)?
    /// The headless "test" path's shared encoder. A `var` because that path now REBUILDS it when the
    /// answer settles on a codec it is not producing (see `codecResolved`). Guarded by `lock`.
    private var encoder: VideoEncoding

    /// Build a replacement shared encoder in `codec` and re-point the headless test pattern at it.
    /// Supplied by `RdevHostRuntime` on the TestPattern path ONLY; nil everywhere else, because the
    /// real path owns per-source encoders in `SimManager`.
    public var rebuildSharedEncoder: ((NegotiatedCodec) -> VideoEncoding?)?

    /// The driver's pastes and drops (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md). SET ONCE,
    /// by `HostSession`, before any client can connect, and read without `lock` after that; nil only in
    /// tests that build a bare hub. Called OUTSIDE `lock` — it queues everything onto its own serial queue
    /// and its replies come back through `sendControl`, which takes `lock`.
    var paste: PasteReceiver?

    private let lock = NSLock()
    private var ownershipEpoch: UInt64 = 0 // under lock; admission AND every ownership transition
    private let reconcileLock = NSLock() // never held while acquiring SimManager.lock indirectly from hub.lock
    private let active = ActiveClientTracker()           // who controls (single active client)
    private var peers: [String: ClientConnection] = [:]         // clientId -> registered connection
    private var openPeers: [String: ClientConnection] = [:]     // clientId -> OPEN terminal connection
    private var controlPeers: [String: ClientConnection] = [:]  // clientId -> OPEN control connection
    /// Clients that declared `term-mode raw` on this connection: they decode the terminal WIRE, and a
    /// driver among them gets one bound (`rebindTermWire`). It is the ONLY terminal mode — the legacy
    /// cell-frame renderer is gone — but it is still DECLARED, not assumed: the declaration comes after
    /// the client has attached its listener and reset its router, and it doubles as "build me a fresh
    /// wire" after a decode failure.
    private var wirePeers: Set<String> = []
    // clientId -> sourceID -> its track slot + delivery sink. The sink is NIL between addVideo (track added,
    // codec offered) and codecResolved (encoder built in the negotiated codec, sink attached); guarded by `lock`.
    /// Per client, per source: BOTH slots plus their sinks. The audio half rides here rather than in
    /// a second map because a source's two tracks have exactly ONE lifetime — added together by
    /// `addSourceTracks`, removed together by `removeSourceTracks` — and two maps would let them
    /// disagree about it. `slot` keeps its name so every existing read of the video slot is unchanged.
    private var videoSlots: [String: [String: (slot: Int32, audioSlot: Int32,
                                               sink: TrackSink?, audioSink: AudioSink?)]] = [:]
    /// The delivery used when the client expressed NO preference.
    ///
    /// EXISTS FOR THE EAGER TRACK. On the headless test-pattern path there is no SimManager, so a
    /// `subscribe` never reaches `addVideo` at all and the client has no way to ask for anything —
    /// which left the DataChannel path untestable without a GUI. `RDEV_DC_DELIVERY=1` makes the host
    /// route by default; a client that DOES express a preference always wins, so this can never
    /// override an explicit `delivery: "rtp"`.
    static let defaultVideoDelivery: VideoDelivery =
        ProcessInfo.processInfo.environment["RDEV_DC_DELIVERY"] == "1" ? .dc : .rtp

    /// What the client ASKED for, per source. Kept separately from what was applied so a track
    /// re-added by a codec change keeps the request rather than reverting to RTP.
    private var videoDeliveryRequest: [String: VideoDelivery] = [:]
    /// What the bridge APPLIED, per source. This is what `view-set` reports; the request never is.
    private var videoDeliveryApplied: [String: (delivery: VideoDelivery, dcIndex: Int?)] = [:]
    // Clients whose media we released because their peer connection reached a terminal state. Read
    // by PeerHub.resume to downgrade an ICE-restart resume to a rebuild (a retained peer whose media
    // is gone re-establishes nothing). Cleared whenever a client gets a fresh peer.
    private var releasedMedia = Set<String>()
    /// A minimum interval between forced IDRs, per source. Guarded by `lock`.
    private var keyframeDebounce = KeyframeDebounce()
    private var lastKeyframeSuppressionLog: TimeInterval = 0
    /// One deferred IDR per source, so a burst of requests inside the window costs one keyframe at
    /// the end of it rather than none. Guarded by `lock`.
    /// Deferred IDRs, per source: the scheduled work AND the deadline it was scheduled for.
    ///
    /// THE DEADLINE IS THE POINT. Keyed only by presence, a pending entry that never fires silences
    /// every later request for that source forever — the deadlock this pairing exists to close.
    private final class ReferenceRoute {
        let peer: PionPeer, slot: Int32, encoder: LLVEncoderAdapter, controller: AV1ReferenceRecovery
        let timer: DispatchSourceTimer
        let connectionID: String
        let id: UUID
        init(id: UUID, peer: PionPeer, slot: Int32, encoder: LLVEncoderAdapter, controller: AV1ReferenceRecovery,
             timer: DispatchSourceTimer, connectionID: String) {
            self.id = id; self.peer = peer; self.slot = slot; self.encoder = encoder; self.controller = controller
            self.timer = timer; self.connectionID = connectionID
        }
        deinit { timer.cancel() }
        func retire() { timer.cancel(); controller.invalidate(); encoder.disableReferencePlanner() }
    }
    private var referenceRoutes: [String: ReferenceRoute] = [:]
    private var referenceCapabilities: [String: Int] = [:]
    private var pendingRecoveryIntents: [String: RecoveryIntent] = [:]

    private func referenceRoute(peer: PionPeer, slot: Int32) -> (String, ReferenceRoute)? {
        lock.withLock {
            guard active.isActive(peer.clientId), peers[peer.clientId]?.mediaPeer === peer else { return nil }
            return referenceRoutes.first { source, route in
                route.peer === peer && route.slot == slot && videoSlots[peer.clientId]?[source]?.slot == slot
            }.map { ($0.key, $0.value) }
        }
    }
    private func configureReferenceRecovery(source: String, peer: PionPeer, slot: Int32,
                                            encoder: any VideoEncoding, consumers: Int) -> Bool {
        // Both refresh/encoderReady and slot retirement run on mediaQueue. Reject a snapshot
        // whose peer/slot was replaced before this configuration reached the queue.
        guard lock.withLock({
            peers[peer.clientId]?.mediaPeer === peer &&
            videoSlots[peer.clientId]?[source]?.slot == slot &&
            videoSlots[peer.clientId]?[source]?.sink != nil
        }) else { return false }
        let previous = lock.withLock { referenceRoutes[source] }
        let context = lock.withLock {
            (referenceCapabilities[peer.clientId], active.isActive(peer.clientId) && peers[peer.clientId]?.mediaPeer === peer,
             videoDeliveryApplied[source]?.delivery == .rtp,
             clientPrefs[peer.clientId]?.av1ReferenceRecovery == true)
        }
        let descriptor = peer.nextReferenceFrame(slot: slot) != nil
        let trackID = peer.referenceTrackID(slot: slot)
        if ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1" {
            print("[av1-ref] eligibility source=\(source) capability=\(context.0 ?? 0) remote=\(context.1) rtp=\(context.2) consumers=\(consumers) descriptor=\(descriptor) track=\(trackID ?? "-")")
        }
        guard context.3,
              let adapter = encoder as? LLVEncoderAdapter,
              AV1ReferenceRecovery.canEnable(capability: context.0, codec: encoder.codec, remote: context.1,
                  rtp: context.2, consumers: consumers, descriptor: descriptor),
              let trackID else {
            lock.withLock { referenceRoutes[source] = nil }; previous?.retire()
            return false
        }
        if let previous, previous.peer === peer, previous.slot == slot, previous.encoder === encoder {
            return previous.controller.isEligible
        }
        lock.withLock { referenceRoutes[source] = nil }; previous?.retire()
        let connectionID = "\(peer.clientId):\(ObjectIdentifier(peer))"
        let routeID = UUID()
        let controller = AV1ReferenceRecovery(source: source, send: { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.keyframeQueue.async { [weak self, weak peer] in
                guard let self, let peer, let (_, route) = self.referenceRoute(peer: peer, slot: slot),
                      route.id == routeID, route.controller.currentEpoch == message["epoch"] as? String,
                      let data = try? JSONSerialization.data(withJSONObject: message) else { return }
                let target = self.lock.withLock { self.controlPeers[peer.clientId] }
                guard target?.mediaPeer === peer else { return }
                target?.send(.control, wrapMessage(data))
            }
        }, requestIndependent: { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.keyframeQueue.async { [weak self, weak peer] in
                guard let self, let peer, self.referenceRoute(peer: peer, slot: slot)?.1.id == routeID else { return }
                self.requestKeyframe(sources: [source])
            }
        }, outcome: { [weak self, weak peer] outcome in
            self?.keyframeQueue.async { [weak peer] in
                if ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1",
                   let data = try? JSONSerialization.data(withJSONObject: ["source": source, "epoch": outcome.epoch,
                       "recoveryId": outcome.recoveryID, "kind": outcome.kind.rawValue]),
                   let json = String(data: data, encoding: .utf8) { print("[av1-ref-event] \(json)") }
                peer?.referenceRecoveryOutcome(slot: slot, outcome: outcome)
            }
        }, requestRepair: { [weak self, weak peer] in
            self?.keyframeQueue.async { [weak self, weak peer] in
                guard let self, let peer, self.referenceRoute(peer: peer, slot: slot)?.1.id == routeID else { return }
                self.requestKeyframe(sources: [source], intent: .repairEstablishedStream)
            }
        }, unsupported: { [weak self, weak peer] in
            self?.mediaQueue.async { [weak self, weak peer] in
                guard let self, let peer, let (_, route) = self.referenceRoute(peer: peer, slot: slot), route.id == routeID else { return }
                // Keep the disabled route until receiver replacement: repeated encoder-ready calls
                // must not re-enable a receiver that cannot report presentation timestamps.
                route.encoder.disableReferencePlanner()
                route.encoder.requestKeyframe()
            }
        })
        controller.setConsumer(connectionID: connectionID, trackID: trackID, eligible: true)
        let timer = DispatchSource.makeTimerSource(queue: keyframeQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak controller] in controller?.tick() }
        let route = ReferenceRoute(id: routeID, peer: peer, slot: slot, encoder: adapter, controller: controller,
                                   timer: timer, connectionID: connectionID)
        lock.withLock { referenceRoutes[source] = route }
        adapter.setReferencePlanner({ [weak peer, weak controller] epoch, frameID, force in
            controller?.prepare(epoch: epoch, frameID: frameID, force: force,
                nextWireFrameNumber: peer?.nextReferenceFrame(slot: slot)) ?? ReferenceFramePlan(forceIndependent: true)
        }, onRequest: { [weak controller] in controller?.request($0) },
           onFailure: { [weak controller] in controller?.continuityLost() })
        timer.resume()
        return true
    }
    func requestReferenceRecovery(peer: PionPeer, slot: Int32, intent: RecoveryIntent) {
        guard lock.withLock({ peers[peer.clientId]?.mediaPeer === peer && active.isActive(peer.clientId) }) else { return }
        if let (source, _) = referenceRoute(peer: peer, slot: slot) {
            requestKeyframe(sources: [source], intent: intent)
        } else { requestKeyframe(clientId: peer.clientId, slot: slot) }
    }
    func referenceSent(peer: PionPeer, slot: Int32, message: [String: Any]) {
        guard let (source, route) = referenceRoute(peer: peer, slot: slot),
              let metadata = message["metadata"] as? [String: Any],
              let token = metadata["token"] as? [String: Any],
              let result = message["result"] as? [String: Any],
              let wireText = result["wireFrameNumber"] as? String,
              let wire = UInt64(wireText), String(wire) == wireText,
              let complete = result["complete"] as? Bool else { return }
        var receipt = token
        receipt["t"] = "av1-ref-ack"; receipt["source"] = source
        receipt["rtpTimestamp"] = result["rtpTimestamp"]
        receipt["purpose"] = metadata["recoveryId"] == nil ? "candidate" : "recovery"
        receipt["recoveryId"] = metadata["recoveryId"]
        guard let parsed = AV1ReferenceMessage.decode(receipt), let identity = parsed.token,
              let timestamp = parsed.rtpTimestamp else { return }
        let rtt = (message["rttNs"] as? String).flatMap(UInt64.init)
        route.controller.didSend(token: identity, recoveryID: parsed.recoveryID,
            result: ReferenceSendResult(rtpTimestamp: timestamp, wireFrameNumber: wire, complete: complete), rttNs: rtt)
    }
    func referenceWriteFailed(peer: PionPeer, slot: Int32, metadata: AV1ReferenceFrameMetadata) {
        guard let (_, route) = referenceRoute(peer: peer, slot: slot),
              route.controller.currentEpoch == metadata.epoch else { return }
        route.controller.deliveryFailed()
    }
    private func handleReferenceReceipt(_ message: AV1ReferenceMessage, peer: ClientConnection) {
        let route = lock.withLock { () -> ReferenceRoute? in
            guard peers[peer.clientId] === peer, active.isActive(peer.clientId),
                  let route = referenceRoutes[message.source], route.peer === peer.mediaPeer else { return nil }
            return route
        }
        if let route { route.controller.handleReceipt(message, connectionID: route.connectionID) }
    }
    private func deliverRecovery(_ source: String, encoder: any VideoEncoding) {
        let intent = lock.withLock { pendingRecoveryIntents.removeValue(forKey: source) ?? .independentKeyframe }
        encoder.requestRecovery(intent)
    }

    private var pendingKeyframes: [String: (work: DispatchWorkItem, deadline: TimeInterval)] = [:]
    private let keyframeQueue = DispatchQueue(label: "dev.rdev.keyframe-debounce")
    /// Pending debounced pause, if a client reported hidden and has not yet come back. Guarded by `lock`.
    private var hiddenPause: DispatchWorkItem?
    /// Whether a pause was actually APPLIED, as opposed to merely scheduled. Guarded by `lock`.
    private var mediaPaused = false
    /// The client whose hidden report applied the pause — its peer carries `setVideoHidden(true)`.
    /// Guarded by `lock`.
    private var mediaPausedBy: String?
    /// Bumped by every visibility report and every void, so a hold that already started running when
    /// it was superseded applies nothing (`DispatchWorkItem.cancel` cannot stop one mid-flight).
    /// Guarded by `lock`.
    private var mediaPauseGeneration = 0
    /// ONE WRITER AT A TIME FOR THE MEDIA PAUSE'S EFFECTS (review A, finding 1). A hold applying and a
    /// void undoing used to interleave: the void restored the rate between the hold's check and its
    /// `setHidden(true)`, SimManager keeps the LAST call, and the session sat at 1 fps with
    /// `mediaPaused` false — which no later visible report could undo. Every transition (hold, void,
    /// resume) and every sink attach (`encoderReady`) now runs its state change AND its effects here,
    /// so the last writer is always the current state. Entered through `onMediaQueue`, which runs
    /// inline when already on it. Nothing here waits on another queue; the bodies take `lock` only
    /// around state and call SimManager (its own lock), encoders and one atomic bridge store.
    private let mediaQueue = DispatchQueue(label: "dev.rdev.media-pause")
    private let mediaQueueKey = DispatchSpecificKey<Void>()
    /// How long a hidden report is held before the pause applies. Immutable; the product's is 1 s.
    private let mediaPauseHold: DispatchTimeInterval
    /// Whether `clientId` is receiving media — false while ITS hidden-tab pause is applied. The audio
    /// election reads it so a subscribe or toggle while the page is hidden attaches no audio sink.
    /// A READ AND AN ACT ON IT ARE ONLY ORDERED WITH THE PAUSE INSIDE `orderedWithMediaPause`; read
    /// outside it, a pause can apply between the answer and the attach.
    public func deliversMedia(to clientId: String) -> Bool {
        lock.withLock { !(mediaPaused && mediaPausedBy == clientId) }
    }

    /// Run `body` on the media queue, so a decision it makes from `deliversMedia` and the sinks it
    /// attaches on that decision land entirely before or entirely after a pause's transition — never
    /// across it. The audio election (`SimManager.reconcileAudio`) runs its attach step here: read
    /// off the queue, a hold applying between its "delivering" and its `addSink` dropped a sink not
    /// yet attached, and the attach then landed on the paused client until the resume.
    ///
    /// Inline when already on the queue (the resume runs the election from there). NEVER CALL WITH A
    /// LOCK HELD — neither `lock` nor SimManager's: the queue's bodies take `lock` and call
    /// `SimManager.setHidden`, which takes SimManager's.
    public func orderedWithMediaPause<T>(_ body: () -> T) -> T { onMediaQueue(body) }
    /// Test hook: whether the media pause is APPLIED.
    var isMediaPaused: Bool { lock.withLock { mediaPaused } }
    /// The driver as `apply` last saw it — how it notices a CHANGE of driver (the palette hand-off, the
    /// pause resets, the departing driver's wire). It used to be `tmuxOwner`, when tmux tabs were the
    /// driver's and a change dropped them; they are the session's now. Guarded by `lock`.
    private var lastDriver: String?
    /// Each client's xterm.js palette (`term-palette`), for the host's answers to a tmux tab's colour
    /// queries that reach no client — the DRIVER's is the one in use. Guarded by `lock`.
    private var termPalettes: [String: TermPalette] = [:]
    /// Each client's client-wide preferences (`client-hello`, `set-prefs`): fps, resolution, bitrate,
    /// codec, pointer mode. The DRIVER's are what every stream resolves against (`reconcileDriver`); a
    /// passive client's are kept for when it becomes the driver. Guarded by `lock`.
    private var clientPrefs: [String: ClientPrefs] = [:]
    /// Each client's last-stated SESSION-SCOPED connection settings — its forced FEC overhead
    /// (`set-recovery`; a present nil is Auto) and its playout request (`set-playout-delay`) — kept
    /// whether or not it drives, like `clientPrefs`. A passive client's are refused as it sends them,
    /// so without this a CLAIMED or PROMOTED driver started with no playout window on its peer and
    /// `view-set` echoed the previous driver's values (final review, 2026-09-29). Applied at
    /// activation, before the reconcile adds a track (`applyConnectionSettings`). Guarded by `lock`.
    private var recoveryRequests: [String: Int?] = [:]
    private var playoutRequests: [String: (minMs: Int?, maxMs: Int?)] = [:]
    /// Each client's transport from its `client-hello` (amendment 1): how the windows reconciled for it
    /// as the driver — and a window it restores — are delivered. Guarded by `lock`.
    private var clientDelivery: [String: VideoDelivery] = [:]
    /// Clients whose CURRENT connection has sent its `client-hello` — the last message of its
    /// control-open batch, so its playout window, visibility, palette and recovery override are
    /// already applied to the peer by then. A driver is reconciled only after it
    /// (docs/superpowers/specs/2026-09-29-host-session-state-design.md): its first video must start
    /// under its own playout window (docs/engine.md). Cleared by a rebuild — the new connection says
    /// hello again. Guarded by `lock`.
    private var helloed: Set<String> = []
    /// Stamps each palette hand-off, decided under `lock` and delivered after it: the manager keeps only
    /// the newest, so a claim racing a palette message cannot leave the old driver's in use. Guarded by `lock`.
    private var paletteSeq: UInt64 = 0
    private func nextPaletteSeqLocked() -> UInt64 { paletteSeq += 1; return paletteSeq }
    /// The DRIVER's shared zstd terminal wire. nil with no raw driver whose terminal
    /// channel is open. Guarded by `lock`; its own `emit` is called outside `lock`.
    private var termWire: TermWire?
    /// Each connection's terminal-channel budget (`TermPath`), shared by every wire bound to it: a new wire's frames
    /// follow what the old one already handed to pion. Keyed by identity, held beside a weak reference so an address
    /// reused by a later connection never inherits a stale budget. Guarded by `lock`.
    private var termPaths: [ObjectIdentifier: (peer: Weak, path: TermPath)] = [:]
    private struct Weak { weak var peer: AnyObject? }
    /// The client `termWire` delivers to. Guarded by `lock`; read by tests (`termWireClientId`).
    private var termWireOwner: String?
    /// Bumped under `lock` at every change of the bound wire; each write of the manager's
    /// `driverDecodesWire` carries the value it was computed at, and the manager keeps only the NEWEST.
    /// The write happens after `lock` is released (TerminalManager's lock is never taken inside the
    /// hub's), so without it a delayed write from an older change could land last — a rebuild's
    /// "false" undoing a racing claim's "true", with the host then answering device queries the new
    /// driver's xterm.js answers too.
    private var wireGeneration: UInt64 = 0
    /// The hidden page's 1 s terminal hold (TermWire.swift). Built in `init`.
    private var terminalPause: TerminalPauseGate!

    public convenience init(terminals: TerminalManager, injector: InputInjector?, encoder: VideoEncoding) {
        self.init(terminals: terminals, injector: injector, encoder: encoder, terminalPauseHold: .milliseconds(1000))
    }

    /// `terminalPauseHold`: the hidden page's terminal hold; `mediaPauseHold`: its media hold
    /// (`setVisibility`). Tests shorten them; the product uses 1 s for both.
    init(terminals: TerminalManager, injector: InputInjector?, encoder: VideoEncoding,
         terminalPauseHold: DispatchTimeInterval, mediaPauseHold: DispatchTimeInterval = .milliseconds(1000)) {
        self.terminals = terminals
        self.fileFetcher = FileFetcher(directory: { [weak terminals] id in terminals?.directory(of: id) }, home: terminals.home)
        self.mediaPauseHold = mediaPauseHold
        mediaQueue.setSpecific(key: mediaQueueKey, value: ())
        self.injector = injector
        self.encoder = encoder
        super.init()
        // Tab set / active tab / title / name / order changed → the bar's terminal half follows the pool
        // (a `view-set` when its SET changed), THEN the tab list to all control peers.
        terminals.onTabsChanged = { [weak self] in self?.terminalTabsChanged() }
        // tmux: a session the driver had open ended; the set of sessions changed. (A tmux tab that must
        // be repainted re-snapshots itself onto the wire.)
        terminals.onTmuxClosed = { [weak self] s, reason in self?.sendToDriver(tmuxClosedJSON(session: s, reason: reason)) }
        terminals.onTmuxSessionsChanged = { [weak self] in self?.sendTmuxListToDriver() }
        // A tmux tab the host could not read was closed (the session lives): say why.
        terminals.onTmuxError = { [weak self] s, reason in self?.sendToDriver(tmuxErrorJSON(session: s, reason: reason)) }
        // Every tab's stream → the driver's wire (TermWire). Called on the tab's serial path.
        terminals.onEmit = { [weak self] e in self?.currentTermWire()?.emit(e) ?? false }
        // A bell in output that reached no client (a hidden driver's pause, a resume's gap): the DRIVER
        // hears it as a `term-bell` (docs/terminal.md, "The bell"); with no driver, nobody does.
        terminals.onBell = { [weak self] id in self?.sendToDriver(termBellJSON(term: id)) }
        terminals.onClipboard = { [weak self] id, epoch, bytes in self?.sendTerminalClipboard(id, epoch: epoch, bytes: bytes) }
        terminalPause = TerminalPauseGate(
            delay: terminalPauseHold,
            owner: { [weak self] in self?.driverConnection() },
            apply: { [weak self] in self?.terminals.pauseForwarding() },
            lift: { [weak self] in self?.terminals.resumeForwarding() },
            clear: { [weak self] in self?.terminals.clearPause() })
    }

    /// `claim`: the client is CONNECTING (its join intent, docs/sources-and-focus.md "The join intent") and
    /// takes control from whoever drives — decided here, on the host. A reconnect joins without it.
    public func register(clientId: String, peer: ClientConnection, claim: Bool = false) {
        lock.lock()
        let replacesDriver = active.isActive(clientId) && peers[clientId] !== peer
        if peers[clientId] !== peer { sourceInputCapabilities[clientId] = nil }
        peers[clientId] = peer; releasedMedia.remove(clientId)
        let before = active.activeId
        let fx = active.join(clientId, claim: claim)
        if before != active.activeId || replacesDriver { ownershipEpoch &+= 1 }
        lock.unlock()
        apply(fx)
    }

    /// A client CONNECTING over a connection the host still held (a resume of its id) takes control on
    /// it — exactly what "Move here" (`claim-control`) does.
    public func claim(clientId: String) { handleClaim(clientId: clientId) }

    public func unregister(clientId: String) {
        lock.lock()
        let wasDriver = active.isActive(clientId)
        peers[clientId] = nil; openPeers[clientId] = nil; controlPeers[clientId] = nil
        wirePeers.remove(clientId)
        sourceInputCapabilities[clientId] = nil
        termPalettes[clientId] = nil
        clientPrefs[clientId] = nil
        recoveryRequests[clientId] = nil; playoutRequests[clientId] = nil
        clientDelivery[clientId] = nil
        helloed.remove(clientId)
        referenceCapabilities[clientId] = nil
        let fx = active.leave(clientId)
        if wasDriver { ownershipEpoch &+= 1 }
        let driverless = active.activeId == nil
        lock.unlock()
        // ITS PASTE GOES WITH IT, files and all — in silence: there is nobody left to tell.
        paste?.abandon(clientId: clientId, reply: nil)
        removeVideo(clientId: clientId)   // drop the departing client's delivery sink (its peer is closing)
        apply(fx)
        // ONLY THE DRIVER'S DEPARTURE ENDS THE STREAMS, and only when nobody took over. The teardown is
        // GLOBAL — it stops every stream — and until 2026-09-29 `PeerHub.clientLeft` armed it for EVERY
        // departing peer: a passive tab closing, or the old driver reaped after a claim, ended the
        // CURRENT driver's windows ~10 s later without a view-set to say so. A driver promoted in
        // `apply` above is reconciled there; its streams go on.
        if wasDriver && driverless { simDelegate?.onClientGone() }
        // A departing client cannot send the keyups for whatever it was holding — ⌘W kills the tab
        // mid-chord, so the ⌘-down was forwarded and the ⌘-up never will be. Unconditional:
        // releaseKeys is idempotent, and a client that held nothing costs one no-op.
        releaseInjectorKeys(protectReadyScopedRoute: true)
    }

    /// Swap in a freshly-built PionPeer for a client that is RESUMING via rebuild (its old PC is dead, a new
    /// one is about to be negotiated). Unlike unregister→register, this preserves the ActiveClientTracker
    /// state so the resuming client keeps its active-control status. Channel maps are cleared; they refill
    /// when the new peer's data channels open. The delivery track is re-established later, once the rebuilt
    /// connection reaches `connected` (stateDidChange → establishVideoIfActive) — NOT here: rebindPeer runs
    /// BEFORE the new peer's startOffer, and addVideoTrack renegotiates, so adding a track now would emit a
    /// premature offer that races the first one.
    public func rebindPeer(clientId: String, peer: ClientConnection) {
        lock.lock()
        if active.isActive(clientId) { ownershipEpoch &+= 1 }
        sourceInputCapabilities[clientId] = nil
        peers[clientId] = peer
        releasedMedia.remove(clientId)   // a stale flag would downgrade a later healthy ICE resume
        openPeers[clientId] = nil; controlPeers[clientId] = nil
        wirePeers.remove(clientId)
        // The rebuilt connection says hello again with its control-open batch; until it does, nothing
        // is reconciled for it (its `connected` re-establishes nothing either).
        helloed.remove(clientId)
        referenceCapabilities[clientId] = nil
        // The wire delivers to the OLD peer: drop it. The new peer binds its own when its terminal
        // channel opens and declares raw (terminalOpened / term-mode), with a snapshot of every tab.
        let dropped = termWireOwner == clientId
        if dropped { termWire?.retire(); termWire = nil; termWireOwner = nil; wireGeneration += 1 }
        let generation = wireGeneration
        let hook = _afterWireDroppedForRebuild
        lock.unlock()
        if dropped { hook?() }
        if dropped { terminals.setDriverDecodesWire(false, generation: generation) }
        // A REBUILT DRIVER IS A NEW PAGE LIFETIME for the terminal (final review C1). Its page may have
        // been hidden past the hold — the pause APPLIED — and its `terminal-resume` sent into the dead
        // connection; the rebuilt one's first wire must still snapshot every tab, which a pause in force
        // withholds. So the pause goes, exactly as on a change of driver, and the client re-states its
        // visibility on the new control channel (a hidden page pauses again). Only for the DRIVER — read
        // now, after the hook: a claim may have moved control meanwhile, and its own reset stands.
        lock.lock(); let isDriver = active.activeId == clientId && peers[clientId] === peer; lock.unlock()
        if isDriver { terminalPause.reset() }
        // A DELIVERY RIDES ONE CONNECTION, and this one is gone: the client's uploader failed with the old
        // channel, and its next paste on the new one must not be refused `busy` behind a delivery nothing
        // will ever finish. Abandoned HERE, where the host learns of the rebuild — before the new control
        // channel can carry a `paste-begin` — and the replaced connection's stragglers are refused at the
        // dispatch (`pasteSender`). No reply: the client already counts it failed.
        paste?.abandon(clientId: clientId, reply: nil)
        // THE SAME SHAPE FOR MEDIA. A `set-visibility` visible sent into the dead connection left the
        // host believing the page hidden: sinks dropped and the sources at 1 fps for a page the user is
        // looking at. The pause goes (a pending hold too — it was scheduled for the OLD connection), and
        // the client re-states its visibility on the new control channel (`controlOpenMessages`).
        if isDriver { voidMediaPause() }
        // `peers[clientId]` was already repointed to the NEW peer above, so removeVideo's `peer?.removeVideoTrack(slot:)`
        // targets the NEW peer (a harmless no-op — it has no track in that slot yet), not the old/closed one. The
        // load-bearing half is `encoder.removeSink(v.sink)`, which drops the sink by the OLD peer's identity
        // (captured when the sink was created) regardless — the old peer's track dies anyway with its closed PC.
        removeVideo(clientId: clientId)
    }

    func replaceMedia(clientId: String) {
        lock.withLock { releasedMedia.remove(clientId) }
        removeVideo(clientId: clientId)
        paste?.abandon(clientId: clientId, reply: nil)
    }

    /// Perform an ActiveClientTracker effect: add/remove the delivery track, release what the outgoing
    /// driver was holding, snapshot the new active client, and (re)broadcast control-state. Sends
    /// happen outside `lock`.
    ///
    /// INTERNAL rather than private so `InjectorReleaseTests` can drive it with a real
    /// `ActiveClientEffects` — the alternative was asserting a restatement of the rule instead of the
    /// method that carries it, which is the distinction this repo has been burned by repeatedly. Not
    /// a public entry point: the only callers are `register`, `unregister` and `handleClaim`.
    /// `incomingGrid`: the terminal grid the activated client said with its claim — applied before its wire's
    /// snapshots (`rebindTermWire(grid:)`).
    func apply(_ fx: ActiveClientEffects, incomingGrid: TermGridSize? = nil) {
        // A CHANGE OF DRIVER hands over what is per-driver — the palette the host answers colour
        // queries from, the terminal and media pauses (the outgoing driver's page, not the incoming
        // one's). The TABS are not per-driver: shells and tmux tabs alike are the SESSION's and stay
        // open, attached (docs/superpowers/specs/2026-09-29-host-session-state-design.md); the
        // incoming driver's wire gets a snapshot of each.
        lock.lock()
        let driver = active.activeId
        let driverChanged = driver != lastDriver
        lastDriver = driver
        // The host answers as the DRIVER's xterm.js would: its palette, or xterm.js's own until it sends one.
        let palette = driver.flatMap { termPalettes[$0] } ?? .xtermDefault
        let paletteSeq = driverChanged ? nextPaletteSeqLocked() : 0
        lock.unlock()
        if driverChanged {
            terminals.setTermPalette(palette, seq: paletteSeq)
            terminalPause.reset()
            // The media pause is the OUTGOING driver's page, not the incoming one's, which states its own
            // visibility when it becomes the driver. Restored BEFORE the new driver's sinks attach below
            // (the rate first, then the re-attach — `setVisibility`'s order). With NO driver it stays:
            // nobody is watching, and the next driver's arrival voids it.
            if driver != nil { voidMediaPause() }
            // A DEPARTING driver produces no effect below (see `deactivate`'s comment), and its wire
            // must not outlive it: the old driver stops receiving.
            if fx.activate == nil && fx.deactivate == nil { rebindTermWire() }
        }
        if let id = fx.deactivate {
            removeVideo(clientId: id)                          // stop feeding the old driver's delivery track
            // CONTROL CHANGED HANDS WHILE THE OLD DRIVER WAS STILL CONNECTED, and nothing else will
            // release what it was holding: it is not the driver any more, so `handleWinKey` refuses
            // the keyups it does send, and it never sends the ones ⌘ swallowed anyway. The injector
            // is SHARED — one per focused source, not one per client — so a ⌘ left down turns every
            // keystroke of the INCOMING driver into a chord, and a glide the outgoing one launched
            // keeps posting scroll into the new driver's session.
            //
            // `unregister`'s own unconditional call does NOT make this redundant, and neither makes
            // the other so: a DEPARTING driver produces no `deactivate` effect at all
            // (`ActiveClientTracker.leave` returns `activate:` alone when it auto-promotes, and all
            // nils when it does not), so the two sites cover different transitions.
            releaseInjectorKeys(protectReadyScopedRoute: true)
            // ITS PASTE IS ABANDONED, and it is TOLD (`not-driver`): it is still connected, and its uploader
            // is waiting on an answer. The abandon is QUEUED — the paste queue may be mid-step (a raise can take
            // a second) — and once the receiver has taken it, a delivery past its `paste-end` posts no ⌘V and no
            // fallback paste, and its drop posts no press (`HostDrop`). What can still land in the new driver's
            // session: a drop already PRESSED when the abandon was taken — a drag under way cannot be refused
            // (measured, `HostDrop`'s guard 1) — whose files the receiver keeps for the app reading them.
            // Nothing calls a drop back.
            paste?.abandon(clientId: id, reply: .notDriver)
        }
        if let id = fx.activate {
            // A NEW VIDEO CONSUMER INHERITS NO CROP AND NO AUTO CEILING — see `SimManager.resetViewerDerived`.
            simDelegate?.resetViewerDerived()
            // A DRIVER EXISTS: whatever teardown the last one's departure armed is off, before anything
            // could reach it. (Every join and resume used to cancel it — a passive one too, which kept
            // streams running for nobody.)
            // A WINDOW-LESS DRIVER WATCHES NO WINDOW: what it takes over stops streaming exactly as when a
            // driver leaves (SimManager's grace, the state kept), and a windowed client taking control
            // later is reconciled back to it.
            let windowless = isWindowless(id)
            if windowless { simDelegate?.onClientGone() } else { simDelegate?.onClientBack() }
            let (tabs, activeId) = terminals.descriptors()
            sendControl(termListJSON(tabs: tabs, activeId: activeId), to: id)
            simDelegate?.sendViewSet(toClient: id)        // the session's state, as every client gets it
            simDelegate?.sendSourceStatus(toClient: id)   // a new driver inherits current window liveness
            // ITS OWN connection settings, before the reconcile below adds a track: a claimer's were
            // refused while it was passive.
            if presentation(for: id) == .streamedSources { applyConnectionSettings(id) }
            // The new driver's wire, and a snapshot of every tab into it (else deferred to terminalOpened) — at
            // the grid it claimed with, when it said one.
            rebindTermWire(grid: incomingGrid)
            // THE SESSION, RECONCILED FOR THIS DRIVER: its preferences, the streams the state wants, a
            // track for each — only once its hello has arrived. A CLAIM's has (it came with the
            // claimer's control open); a FRESH join reaches here before `startOffer`, and its own hello
            // reconciles — adding a track now would emit an offer racing the first one.
            reconcileDriver(id)
        } else if fx.deactivate != nil {
            rebindTermWire()                                  // driver left with no replacement
        }
        if fx.broadcastState { broadcastControlState() }
    }

    // MARK: - Slot-addressed video delivery
    //
    // The active client's video rides a DYNAMIC per-peer track (a slot), not the bridge's primary track.
    // `addVideo` adds the track + registers a `TrackSink` on the encoder; `removeVideo` reverses it.
    // LOCK DISCIPLINE: `peer.addVideoTrack` / `removeVideoTrack` renegotiate through the bridge — they run
    // OUTSIDE `lock`; only the `videoSlots` map mutation is guarded by `lock`. `lock` is never held across
    // a bridge call, and never simultaneously with SimManager.lock (activeVideoSourceIDs is read outside
    // `lock`). `addVideoTrack` renegotiates, so callers MUST ensure the peer is past its first offer.

    /// The source ids the active client should be fed a track for. Sim path: the subscribed sources (0/1
    /// at cap 1). Smoke path (no SimManager ⇒ isVideoSubscribed == nil): the single synthetic "test"
    /// source so the TestPattern client still gets one track. Read outside `lock` (hits SimManager.lock).
    private func activeVideoSourceIDs() -> [String] {
        guard isVideoSubscribed != nil else { return ["test"] }   // headless smoke: always one track
        return simDelegate?.subscribedSourceIDs() ?? []
    }

    /// The encoder that feeds `sourceID`'s track (cap-N: one encoder per subscribed source). The shared
    /// `encoder` is used ONLY on the headless "test" path (no SimManager ⇒ `isVideoSubscribed == nil`); the
    /// real-sim path looks up the source's own encoder via SimManager. Returns nil if the per-source lookup
    /// misses (the stream was torn down between the source-id snapshot and this call).
    ///
    /// The shared-`encoder` read is LOCKED because that field is now mutable — `codecResolved` swaps it
    /// when the headless path has to rebuild in the negotiated codec. Every caller releases `lock`
    /// before calling this (NSLock is not reentrant), which is what makes taking it here safe.
    private func encoderFor(_ sourceID: String) -> VideoEncoding? {
        isVideoSubscribed == nil ? lock.withLock { encoder } : simDelegate?.encoderForSource(sourceID)
    }

    /// This source's AUDIO encoder, or nil when it has none.
    ///
    /// NO HEADLESS FALLBACK, unlike `encoderFor` above: there is no shared audio encoder to fall back
    /// to, and the headless test-pattern path has no audio at all until the tone source lands. nil
    /// means "no audio for this source", which every caller already treats as ordinary.
    private func audioEncoderFor(_ sourceID: String) -> AudioEncoding? {
        // The headless test-pattern path has no SimManager, so it carries ONE shared audio encoder
        // exactly as it carries one shared video encoder — the `encoderFor` shape above.
        //
        // THE STORED FIELD IS READ DIRECTLY UNDER `lock`, NEVER THROUGH THE PUBLIC GETTER. The getter
        // takes `lock` itself, and `lock.withLock { sharedAudioEncoder }` therefore takes a
        // NON-REENTRANT NSLock twice and deadlocks the calling thread outright. That is not a
        // theoretical hazard: it shipped for one build and hung the peer's ordered dispatcher inside
        // `encoderReady`, AFTER the video sink had already attached — so `[encode]` reported
        // `1 attach · 1 sinks` and streamed perfectly at 60 fps while audio never started and the
        // very log line meant to explain why could not print.
        isVideoSubscribed == nil ? lock.withLock { _sharedAudioEncoder }
                                 : simDelegate?.audioEncoderForSource(sourceID)
    }

    /// The headless path's single audio encoder, set by RdevHostRuntime under RDEV_TEST_PATTERN=1.
    /// nil on the product path, where SimManager owns one encoder per source.
    ///
    /// EVERY INTERNAL READ MUST USE `_sharedAudioEncoder` UNDER `lock`, not this — see above.
    public var sharedAudioEncoder: AudioEncoding? {
        get { lock.withLock { _sharedAudioEncoder } }
        set { lock.lock(); _sharedAudioEncoder = newValue; lock.unlock() }
    }
    private var _sharedAudioEncoder: AudioEncoding?

    /// Tests: a stand-in for the bridge's track negotiation. When set, `addVideo` takes its slots from
    /// here instead of `pion_peer_add_source_tracks` (and records the delivery it asked for as applied),
    /// and `removeVideo` skips the bridge's removal — so a hub test adds, re-routes and removes REAL
    /// `videoSlots` entries through the product's own paths on a never-connected peer. nil in the
    /// product. Guarded by `lock`.
    var fakeTrackSlotsForTests: ((_ clientId: String, _ sourceID: String) -> (video: Int32, audio: Int32))? {
        get { lock.withLock { _fakeTrackSlots } }
        set { lock.withLock { _fakeTrackSlots = newValue } }
    }
    private var _fakeTrackSlots: ((String, String) -> (video: Int32, audio: Int32))?

    /// Tests: `"add"` just before a NEW track is negotiated (never for an idempotent or re-routing
    /// `addVideo`), `"remove"` when an EXISTING track is removed. Guarded by `lock`.
    var trackEventHookForTests: ((_ event: String, _ clientId: String, _ sourceID: String) -> Void)? {
        get { lock.withLock { _trackEventHook } }
        set { lock.withLock { _trackEventHook = newValue } }
    }
    private var _trackEventHook: ((String, String, String) -> Void)?

    /// Tests: the delivery a source's next track is added with.
    func videoDeliveryRequestForTests(_ sourceID: String) -> VideoDelivery? {
        lock.withLock { videoDeliveryRequest[sourceID] }
    }

    /// Add a delivery track for `sourceID` to `peer`, OFFERING BOTH codecs, and record its slot with a NIL sink.
    /// The encoder can't be built until the answer resolves the codec, so the sink is attached later in
    /// `codecResolved` → `encoderReady`. Idempotent per (client, source): a no-op once this client already has a
    /// track for that source. OUTSIDE `lock` for the bridge call; only the `videoSlots` mutation is guarded.
    private func addVideo(peer: PionPeer, sourceID: String) {
        guard lock.withLock({ peers[peer.clientId]?.mediaReady ?? true }) else { return }
        lock.lock()
        let existing = videoSlots[peer.clientId]?[sourceID]
        let wanted = videoDeliveryRequest[sourceID] ?? ChannelHub.defaultVideoDelivery
        let appliedNow = videoDeliveryApplied[sourceID]
        let fake = _fakeTrackSlots, hook = _trackEventHook
        lock.unlock()
        // ADDING IS IDEMPOTENT; ROUTING IS NOT. A track already exists for this (client, source), so
        // there is nothing to negotiate — but the DELIVERY may have moved since it was added, and
        // returning here unconditionally is what made a peer rebuild permanent: the host re-added the
        // track itself BEFORE the client's `subscribe{delivery:"dc"}` arrived, which was then dropped on
        // this line while the client waited for DataChannel frames that were being packetised as RTP.
        //
        // Re-routing is cheap and safe: the track stays negotiated, so this is neither a
        // renegotiation nor a new SSRC, and `setDelivery` is idempotent on the bridge side.
        if let existing {
            guard appliedNow?.delivery != wanted else { return }
            let applied = fake != nil ? (delivery: wanted, dcIndex: nil as Int?)
                : peer.setVideoDelivery(slot: Int(existing.slot), sourceID: sourceID, delivery: wanted)
            lock.lock(); videoDeliveryApplied[sourceID] = applied; lock.unlock()
            encoderReady(sourceID: sourceID)
            print("[channel] \(sourceID) delivery re-routed to \(applied.delivery.rawValue)"
                  + (applied.dcIndex.map { " index=\($0)" } ?? ""))
            return
        }
        hook?("add", peer.clientId, sourceID)          // a NEW track is about to be negotiated
        // Offer this SOURCE's preference from the start, so a pinned codec does not have to be switched
        // a round trip after the track already resolved to something else.
        let pref = simDelegate?.codecPrefForSource(sourceID) ?? .auto
        // ONE renegotiation for both tracks — see pion_peer_add_source_tracks. OUTSIDE lock.
        let slots = fake?(peer.clientId, sourceID)
            ?? peer.addSourceTracks(sourceID: sourceID, codecPref: pref.bridgeValue)
        let slot = slots.video
        guard slot >= 0 else { return }
        // ROUTED ONCE THE SLOT EXISTS, and the RESULT is recorded rather than the request. The request is
        // re-read from `videoDeliveryRequest`, so a track re-added by a codec change keeps the delivery
        // the client asked for instead of silently reverting to RTP.
        let applied = fake != nil ? (delivery: wanted, dcIndex: nil as Int?)
            : peer.setVideoDelivery(slot: Int(slot), sourceID: sourceID, delivery: wanted)   // OUTSIDE lock
        lock.lock()
        videoSlots[peer.clientId, default: [:]][sourceID] = (slot, slots.audio, nil, nil)
        videoDeliveryApplied[sourceID] = applied
        lock.unlock()
        // PRINTED WHATEVER IT SAYS — zeroes are printed, not omitted: silence has been mistaken for an
        // answer on this very line.
        print("[channel] \(sourceID) delivery asked=\(wanted.rawValue) applied=\(applied.delivery.rawValue)"
              + (applied.dcIndex.map { " index=\($0)" } ?? ""))
        // The sink is attached in codecResolved(), once the encoder exists in the negotiated codec. IT
        // STAYS ATTACHED ON THE DataChannel PATH TOO: the bridge routes the access units, so a detached
        // sink would starve both paths rather than just the RTP one.
    }

    /// What the bridge actually applied for `sourceID`, for `view-set`'s `activeDelivery`/`dcIndex`.
    /// Nil means not yet resolved — which the client must be able to tell from "resolved, and rtp".
    func videoDelivery(forSource sourceID: String) -> (delivery: VideoDelivery, dcIndex: Int?)? {
        lock.lock(); defer { lock.unlock() }
        return videoDeliveryApplied[sourceID]
    }

    /// Both `view-set` maps in ONE lock acquisition. A per-source call would take the lock N times
    /// while building a single message, and the two maps must describe the same instant — a source
    /// whose delivery changed between two reads would report a `dc` delivery with no index, or an
    /// index for a source that had just fallen back.
    public func videoDeliveryMaps() -> (delivery: [String: VideoDelivery], indices: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        var delivery: [String: VideoDelivery] = [:]
        var indices: [String: Int] = [:]
        for (source, applied) in videoDeliveryApplied {
            delivery[source] = applied.delivery
            if let index = applied.dcIndex { indices[source] = index }
        }
        return (delivery, indices)
    }

    /// Record what a client asked for, before the track exists. Read by `addVideo`.
    func setVideoDeliveryRequest(_ delivery: VideoDelivery, forSource sourceID: String) {
        lock.lock(); videoDeliveryRequest[sourceID] = delivery; lock.unlock()
    }

    /// Apply a codec-preference change by REMOVING and RE-ADDING each client's track for `sourceID`.
    ///
    /// Why not swap the codec on the live track: `ReplaceTrack` gives the new TrackLocalStaticSample a
    /// fresh random sequencer and RTP timestamp base on the SAME SSRC, and the receiver discards the
    /// stream (measured — seq jumped back ~2700 and the timestamp by ~2.5e9, and Chrome's
    /// packetsReceived froze while every host-side state read healthy). A new track means a new SSRC,
    /// so there is no continuity to preserve and the problem does not arise.
    ///
    /// The cost is one renegotiation and a fresh IDR, and a codec change already forces an encoder
    /// rebuild and an IDR — so the marginal cost is the renegotiation. `addVideo` reads the source's
    /// (already-updated) preference, so the new track is offered the new order.
    ///
    /// LOCK DISCIPLINE: snapshot under `lock`, then call removeVideo/addVideo OUTSIDE it — both
    /// renegotiate through the bridge, exactly like the subscribe path.
    func setCodec(sourceID: String, pref: CodecPref) {
        lock.lock()
        let clients = videoSlots.compactMap { $0.value[sourceID] != nil ? $0.key : nil }
        lock.unlock()
        for clientId in clients {
            removeVideo(clientId: clientId, sourceID: sourceID)
            lock.lock(); let peer = peers[clientId]?.mediaPeer; lock.unlock()
            if let peer { addVideo(peer: peer, sourceID: sourceID) }
        }
    }

    /// The bridge resolved this track's codec from the answer. Map slot -> source, then build the encoder in that
    /// codec and attach the delivery sink. Real-sim path: `simDelegate.ensureEncoder` builds/rebuilds the per-source
    /// encoder and calls back into `encoderReady(source)`. Headless "test" path (no SimManager ⇒ no simDelegate): the
    /// shared `encoder` already exists, so attach the sink directly via `encoderReady`. Runs on the peer's ordered
    /// dispatcher (post-answer). OUTSIDE `lock` for the simDelegate/encoder calls.
    func codecResolved(clientId: String, slot: Int32, codec: NegotiatedCodec) {
        lock.lock()
        let source = videoSlots[clientId]?.first(where: { $0.value.slot == slot })?.key
        lock.unlock()
        guard let source else { return }
        if let simDelegate {
            simDelegate.ensureEncoder(sourceID: source, codec: codec)   // builds/rebuilds encoder → encoderReady — hits SimManager.lock
        } else {
            // Headless "test" path: rebuild the shared encoder when the answer settled on a codec it is
            // not already producing. Without this the host ships H.264 bytes on a track the browser
            // negotiated as something else — RTP flows, every state reads healthy, and nothing decodes.
            //
            // LOAD-BEARING ordering, mirroring SimManager.ensureEncoder: drop the old encoder's sinks
            // first, install and RETAIN the replacement before retargeting (the pattern's sink is weak),
            // and invalidate the old one last. VTEncoder's VideoToolbox callback holds an UNRETAINED
            // refcon, so an in-flight frame landing on a freed encoder is a SIGSEGV, not a dropped frame.
            let current = lock.withLock { encoder }
            if current.codec != codec, let fresh = rebuildSharedEncoder?(codec) {
                current.removeAllSinks()
                lock.withLock { encoder = fresh }
                current.invalidate()
            }
            encoderReady(sourceID: source)
        }
    }

    /// The source's encoder now exists (negotiated codec). Attach the delivery sink for whichever client holds a
    /// slot for this source. Idempotent: replaces a prior sink (codec rebuild) so a stale sink can't linger. All
    /// encoder/bridge calls run OUTSIDE `lock`; only the `videoSlots` reads/writes are guarded.
    /// Drop a hidden client's delivery sinks WITHOUT removing its tracks.
    ///
    /// NOT `removeVideo`: that also calls `peer.removeVideoTrack`, which renegotiates and gives the
    /// replacement a new SSRC with a fresh sequencer and RTP timestamp base — a discontinuity a live
    /// receiver discards, and a renegotiation per tab switch besides. Keeping `(slot, nil)` means the
    /// track stays negotiated and resume is a re-attach.
    private func pauseVideo(clientId: String) {
        lock.lock()
        var dropped: [(String, TrackSink)] = []
        var droppedAudio: [(String, AudioSink)] = []
        for (source, v) in videoSlots[clientId] ?? [:] {
            if let sink = v.sink { dropped.append((source, sink)) }
            if let audio = v.audioSink { droppedAudio.append((source, audio)) }
            videoSlots[clientId]?[source] = (v.slot, v.audioSlot, nil, nil)
        }
        lock.unlock()
        for (source, sink) in dropped { encoderFor(source)?.removeSink(sink) }
        // AUDIO PAUSES WITH VIDEO. A hidden tab should stop paying for sound too, and the track
        // stays negotiated exactly as the video one does, so resuming is a re-attach.
        for (source, sink) in droppedAudio { audioEncoderFor(source)?.removeSink(sink) }
    }

    /// Re-attach a returning client's sinks. `encoderReady` already does exactly this — drop any
    /// stale sink, build a fresh TrackSink, record it, addSink (which forces an IDR, which is what a
    /// returning tab needs). Reusing it avoids a second copy of the codec-rebuild path.
    private func resumeVideo(clientId: String) {
        let sources = lock.withLock { videoSlots[clientId].map { Array($0.keys) } ?? [] }
        for s in sources { encoderReady(sourceID: s) }
    }

    /// THE DEBOUNCE IS HERE, ON THE HOST, AND THE PLATFORM FORCES IT. The obvious design debounces
    /// client-side so a two-second glance at another tab costs nothing — but on iOS the page is often
    /// SUSPENDED moments after `visibilitychange`, so a client-side timer may never fire, on exactly
    /// the platform where the win is biggest. The client reports immediately; the host absorbs churn.
    ///
    /// VISIBLE IS APPLIED IMMEDIATELY, with no delay. Hiding a second late wastes a second of encode;
    /// showing a second late leaves the user looking at a frozen window.
    ///
    /// A REPORT CAN BE LOST — a phone's control channel is often dead by the time the page returns —
    /// so the pause belongs to one PAGE LIFETIME on one connection: a rebuild of the driver and a change
    /// of driver void it (`voidMediaPause`), and the client states its visibility on every control open.
    public func setVisibility(clientId: String, hidden: Bool) {
        if !hidden {
            onMediaQueue {
                guard voidMediaPause() else { return }   // a cancelled pause never applied; nothing to undo
                resumeVideo(clientId: clientId)          // the rate was restored FIRST; now re-attach
                // AND THE AUDIO. `pauseVideo` dropped the audio sinks too, and `encoderReady` re-attaches
                // audio only on the headless path — on the product path the ownership election owns it
                // (a yielded sibling or a muted source must stay silent), so it runs again here.
                simDelegate?.reconcileAudio()
                print("[channel] \(clientId) visible — media resumed")
            }
            return
        }
        lock.lock()
        hiddenPause?.cancel(); hiddenPause = nil
        mediaPauseGeneration += 1
        let generation = mediaPauseGeneration
        lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.mediaHoldHookForTests?(.willApply)
            self.onMediaQueue {
                self.lock.lock()
                let current = self.mediaPauseGeneration == generation
                if current { self.hiddenPause = nil; self.mediaPaused = true; self.mediaPausedBy = clientId }
                self.lock.unlock()
                guard current else { return }            // superseded while it was starting to run
                self.mediaHoldHookForTests?(.applying)
                // The DataChannel path pauses too, and by the same rule: repair for a source nobody
                // is watching is pure waste. Routing survives, so coming back is not a renegotiation.
                self.peerFor(clientId)?.setVideoHidden(true)
                // ORDER IS LOAD-BEARING: drop the sinks BEFORE the rate change. On libaom fps is the
                // timebase denominator, so setFps recreates the encoder and emits an IDR — with the
                // sink already gone that IDR costs nothing on the wire. Reversed, every tab switch
                // would push a keyframe to a client that is not looking at it.
                self.pauseVideo(clientId: clientId)
                self.simDelegate?.setHidden(true)
                // A backgrounded tab stops delivering keyups too — same reasoning as client leave.
                self.releaseInjectorKeys()
                print("[channel] \(clientId) hidden — media paused")
            }
        }
        lock.lock(); hiddenPause = work; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + mediaPauseHold, execute: work)
    }

    /// Cancel a pending hold and undo an applied pause's RATE and DataChannel halves. Returns whether
    /// a pause had applied. The SINKS are the caller's: a visible report re-attaches them
    /// (`resumeVideo`), a rebuild re-establishes them on `connected`, a change of driver attaches the
    /// incoming driver's. Runs on `mediaQueue` (inline when already there).
    ///
    /// CALLED OUTSIDE `lock` — NSLock is not re-entrant, so a caller holding it deadlocks here rather
    /// than failing loudly. No cheap guard exists for that (NSLock has no owner query, and a
    /// `try()` cannot tell "held by me" from "held by another thread"), so this comment is the guard.
    @discardableResult
    private func voidMediaPause() -> Bool { onMediaQueue { voidMediaPauseOnQueue() } }

    private func voidMediaPauseOnQueue() -> Bool {
        lock.lock()
        hiddenPause?.cancel(); hiddenPause = nil
        mediaPauseGeneration += 1
        let wasPaused = mediaPaused, by = mediaPausedBy
        mediaPaused = false; mediaPausedBy = nil
        lock.unlock()
        guard wasPaused else { return false }
        by.flatMap { peerFor($0) }?.setVideoHidden(false)
        simDelegate?.setHidden(false)
        return true
    }

    /// Run `body` on `mediaQueue`: inline when already on it (a resume re-attaching through
    /// `encoderReady`), else synchronously. Never call with `lock` held.
    private func onMediaQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: mediaQueueKey) != nil ? body() : mediaQueue.sync(execute: body)
    }

    /// Attach each client's sink to `sourceID`'s (possibly new) encoder — EXCEPT the paused client's
    /// (review A, finding 2): a codec rebuild or a late `codec-resolved` while the pause is in force
    /// attached a sink and forced an IDR at a page nobody is looking at. Its stale sink is still
    /// dropped and its slot kept, so the resume (`resumeVideo`) attaches it. On `mediaQueue`, so a
    /// hold cannot drop sinks between this reading "not paused" and attaching.
    func encoderReady(sourceID: String) { onMediaQueue { encoderReadyOnQueue(sourceID: sourceID) } }

    private func encoderReadyOnQueue(sourceID: String) {
        guard let enc = encoderFor(sourceID) else { return }
        lock.lock()
        var updates: [(clientId: String, slot: Int32, audioSlot: Int32, old: TrackSink?)] = []
        for (clientId, byId) in videoSlots {
            if let v = byId[sourceID] { updates.append((clientId, v.slot, v.audioSlot, v.sink)) }
        }
        lock.unlock()
        for u in updates {
            u.old.map { enc.removeSink($0) }                       // drop a stale sink from a prior (rebuilt) encoder
            let paused = lock.withLock { mediaPaused && mediaPausedBy == u.clientId }
            if paused {
                lock.lock()
                if let v = videoSlots[u.clientId]?[sourceID] { videoSlots[u.clientId]?[sourceID] = (v.slot, v.audioSlot, nil, v.audioSink) }
                lock.unlock()
                continue
            }
            let peer = lock.withLock { peers[u.clientId]?.mediaPeer }
            guard let peer else { continue }
            let sink = TrackSink(peer: peer, slot: u.slot)
            let existingAudio = lock.withLock { videoSlots[u.clientId]?[sourceID]?.audioSink }
            lock.lock()
            videoSlots[u.clientId]?[sourceID] = (u.slot, u.audioSlot, sink, existingAudio)
            lock.unlock()
            let referenceEnabled = configureReferenceRecovery(source: sourceID, peer: peer, slot: u.slot,
                                                               encoder: enc, consumers: updates.count)
            enc.addSink(sink)                                      // forces an IDR
            if referenceEnabled { enc.requestRecovery(.independentKeyframe) }
            // AUDIO, HEADLESS PATH ONLY. On the product path SimManager's `reconcileAudio` owns this,
            // because attaching here unconditionally would give a YIELDED source a sink and defeat
            // the ownership election. The headless path has no election and no SimManager, so this is
            // the only place its sink can come from.
            if isVideoSubscribed == nil, let audioEnc = audioEncoderFor(sourceID),
               let audioSink = audioSink(forClient: u.clientId, sourceID: sourceID) {
                audioEnc.addSink(audioSink)
            }
        }
    }

    /// The audio sink for one (client, source), created on first use and remembered so a later call
    /// returns the SAME object — an encoder keys sinks by (peer, slot), so a fresh object each time
    /// would replace rather than accumulate, but `removeSink` from a caller holding a different
    /// instance would still work. Remembering it keeps the map honest about what is attached.
    ///
    /// nil when that (client, source) has no audio slot, which is not an error: a track added before
    /// audio existed, or a peer that has gone away.
    ///
    /// LOCK DISCIPLINE: `lock` is taken and released around the map reads; the `AudioSink` is
    /// constructed outside it. No bridge call happens here at all.
    func audioSink(forClient clientId: String, sourceID: String) -> AudioSink? {
        lock.lock()
        guard let slots = videoSlots[clientId]?[sourceID], slots.audioSlot >= 0 else {
            lock.unlock(); return nil
        }
        if let existing = slots.audioSink { lock.unlock(); return existing }
        let peer = peers[clientId]?.mediaPeer
        lock.unlock()
        guard let peer else { return nil }
        let sink = AudioSink(peer: peer, slot: slots.audioSlot)
        lock.lock()
        if var entry = videoSlots[clientId]?[sourceID] {
            entry.audioSink = sink
            videoSlots[clientId]?[sourceID] = entry
        }
        lock.unlock()
        return sink
    }

    /// Drop ONE (client, source) track: detach its sink from that source's encoder + remove the track from the
    /// peer. Tolerates an absent/closed peer.
    private func removeVideo(clientId: String, sourceID: String) {
        // Retire the route and its slot on the same lane that installs a reference planner.
        // Bridge operations below remain outside the lane and outside the hub lock.
        let (v, peer, fake, hook) = onMediaQueue {
            lock.lock()
            let v = videoSlots[clientId]?[sourceID]
            let retiredReference = referenceRoutes[sourceID].flatMap { $0.peer.clientId == clientId ? $0 : nil }
            if retiredReference != nil { referenceRoutes[sourceID] = nil }
            pendingRecoveryIntents[sourceID] = nil
            videoSlots[clientId]?[sourceID] = nil
            if videoSlots[clientId]?.isEmpty ?? false { videoSlots[clientId] = nil }
            // A re-subscribe builds a FRESH encoder and needs its IDR at once; inheriting this source's
            // old clock would leave the new window black for up to the debounce interval.
            keyframeDebounce.forget(source: sourceID)
            pendingKeyframes.removeValue(forKey: sourceID)?.work.cancel()
            let peer = peers[clientId]?.mediaPeer
            let fake = _fakeTrackSlots != nil, hook = _trackEventHook
            lock.unlock()
            retiredReference?.retire()
            return (v, peer, fake, hook)
        }
        guard let v else { return }
        hook?("remove", clientId, sourceID)            // an EXISTING track is removed
        if let sink = v.sink { encoderFor(sourceID)?.removeSink(sink) }   // sink is nil until codecResolved attached it
        // RELEASED BEFORE THE TRACK GOES. The bridge retires the source's index rather than freeing
        // it, so a later subscribe cannot inherit an index whose old symbols may still be in flight.
        if !fake { peer?.releaseVideoDelivery(slot: Int(v.slot)) }
        // THE APPLIED VALUE GOES; THE REQUEST STAYS. `videoDeliveryRequest` is the client's standing
        // intent for this source, and a track being removed is not the client changing its mind —
        // `setCodec` removes and re-adds, and so does every peer rebuild.
        lock.lock(); videoDeliveryApplied[sourceID] = nil; lock.unlock()
        if !fake { peer?.removeSourceTracks(videoSlot: v.slot, audioSlot: v.audioSlot) }   // OUTSIDE lock
    }

    /// Mark a discontinuity on this source for every client delivering it over the DataChannel.
    ///
    /// A codec change or encoder rebuild starts a new stream, and without the epoch the client's
    /// decoder would carry a window across the boundary and solve against symbols that no longer
    /// exist. Broadcast rather than per-client because the encoder is per SOURCE, not per viewer.
    func bumpVideoDelivery(sourceID: String) {
        lock.lock()
        let targets = videoSlots.compactMap { entry -> (PionPeer, Int32)? in
            guard let slot = entry.value[sourceID]?.slot, let peer = peers[entry.key]?.mediaPeer else { return nil }
            return (peer, slot)
        }
        lock.unlock()
        for (peer, slot) in targets { peer.bumpVideoDelivery(slot: Int(slot)) }   // OUTSIDE lock
    }

    /// This client's MEDIA peer (nil for a window-less client), for calls that must happen OUTSIDE `lock` — every bridge call
    /// here follows that rule, since the bridge can re-enter through a delegate callback.
    private func peerFor(_ clientId: String) -> PionPeer? {
        lock.lock(); defer { lock.unlock() }
        return peers[clientId]?.mediaPeer
    }

    /// Whether this client currently holds any delivery track. GUARD 1 + idempotency; see
    /// `shouldReleaseMedia`.
    private func hasVideoSlots(clientId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(videoSlots[clientId]?.isEmpty ?? true)
    }

    /// Whether this client's media was released by `releaseMedia`. Consumed by `PeerHub.resume`.
    public func mediaWasReleased(clientId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return releasedMedia.contains(clientId)
    }

    /// Drop a dead peer's delivery sinks and retire capture/encode.
    ///
    /// NOT teardown: the client stays registered, keeps its active-control status, and keeps its
    /// terminal. Only media is released.
    ///
    /// LOCK DISCIPLINE: `ChannelHub.lock` is NOT held across `removeVideo` (which takes it itself)
    /// or `clientGone` (which reaches `SimManager.lock`). SimManager.lock and ChannelHub.lock are
    /// never held simultaneously anywhere in this project.
    private func releaseMedia(clientId: String, state: Int32) {
        lock.lock()
        let dropped = videoSlots[clientId]?.count ?? 0
        releasedMedia.insert(clientId)
        lock.unlock()
        removeVideo(clientId: clientId)   // drops each TrackSink from its encoder; the track removal
                                          // no-ops on a closed peer, so no renegotiation churn
        simDelegate?.onClientGone()       // the driver's connection is gone: SimManager's grace, then its streams stop (the session is kept)
        print("[channel] \(clientId) released media on state=\(state) (\(dropped) slot(s) dropped)")
        // THE CURTAIN STAYS UP (2026-09-30, docs/curtain.md "Nothing lowers it on its own"). It used to
        // lower here, so a curtain could not outlive its driver — and a phone in a pocket for 30 s (ICE
        // failing), a reload, or the client rebuilding its own connection lit the Mac's screen for the
        // room. Only a REQUEST lowers it now — the driver's toggle, ⌃⌥⌘U on the Mac's own keyboard, Stop
        // Sharing or quitting — or the host process dying, which restores gamma by itself.
    }

    /// Drop ALL of a client's delivery tracks (deactivate / disconnect / rebuild).
    private func removeVideo(clientId: String) {
        lock.lock(); let sources = videoSlots[clientId].map { Array($0.keys) } ?? []; lock.unlock()
        for s in sources { removeVideo(clientId: clientId, sourceID: s) }
    }

    /// Route a keyframe request to the owning source's encoder. A per-track PLI carries that track's `slot`; the
    /// on-connect / connection-level request uses `slot == -1` (force IDR on ALL of this client's sources).
    /// The recovery stack the ACTIVE client's connection actually runs, or nil before its answer
    /// settles it.
    ///
    /// THE ACTIVE CLIENT'S, because only that client is fed video — `apply` removes the outgoing
    /// driver's track and adds the incoming one — so it is the only connection whose recovery stack
    /// describes anything being sent. This follows `activeCodecs`, which is per-source but likewise
    /// only ever populated for the client that has tracks.
    func activeRecovery() -> String? {
        lock.lock()
        let clientId = active.activeId
        let peer = clientId.flatMap { peers[$0]?.mediaPeer }
        lock.unlock()
        return peer?.activeRecovery
    }

    /// DEBOUNCED PER SOURCE. rdev used to answer every PLI with a full IDR, so a request storm became
    /// a bitrate storm: measured on a real iPad, 60 requests in fifteen seconds became 60 keyframes,
    /// 99% of the wire, and 9.2 fps — leaving no capacity for the video those keyframes were meant to
    /// restore. The loop sustains itself, because starving the encoder gives the receiver more to
    /// complain about. See KeyframeDebounce for why a suppressed request is dropped, not deferred.
    func requestKeyframe(clientId: String, slot: Int32) {
        lock.lock()
        let entries = videoSlots[clientId] ?? [:]
        let wanted = slot < 0 ? Array(entries.keys) : entries.filter { $0.value.slot == slot }.map(\.key)
        lock.unlock()
        requestKeyframe(sources: wanted)
    }

    /// Control-channel `request-keyframe`: the client's OWN decoder needs an IDR for one source.
    ///
    /// WHY A CLIENT WOULD ASK. A client that consumes the encoded frames itself — `?render=webcodecs`
    /// pipes `RTCRtpScriptTransform`'s readable into its own `VideoDecoder` — starves the browser's
    /// decoder, so the browser never sends a PLI again. Decoder-driven recovery becomes the client's
    /// job, and this is how it asks. A `<video>` client never sends it; its browser PLIs for it.
    ///
    /// NOT SEPARATELY ACTIVE-GATED, because `videoSlots[clientId]` already is: a passive client holds
    /// no video slots, so the guard below refuses it. Naming a source this client is not receiving is
    /// likewise a no-op rather than a way to keyframe someone else's window.
    func requestKeyframe(clientId: String, sourceID: String) {
        lock.lock()
        let subscribed = (videoSlots[clientId] ?? [:])[sourceID] != nil
        lock.unlock()
        guard subscribed else { return }
        requestKeyframe(sources: [sourceID])
    }

    /// The shared debounce-and-defer core. Split out so the PLI path and the control-channel path
    /// cannot drift — a second copy of this would be a second place to get "deferred, never dropped"
    /// wrong, and that distinction is the difference between 21 frames and 1131 under 1% loss.
    private func requestKeyframe(sources: [String], intent: RecoveryIntent = .independentKeyframe) {
        let now = Date().timeIntervalSinceReferenceDate
        let wanted = sources
        lock.lock()
        var allowed: [String] = []
        var deferred: [(source: String, wait: TimeInterval)] = []
        // Requests a pending IDR will satisfy. COUNTED because the previous version discarded them
        // silently, which is how a stuck pending entry hid for 40 seconds at a time.
        var coveredByPendingKeyframe = 0
        for source in wanted {
            if pendingRecoveryIntents[source] != .independentKeyframe { pendingRecoveryIntents[source] = intent }
            let wait = keyframeDebounce.waitBeforeKeyframe(source: source, now: now)
            if wait <= 0 {
                allowed.append(source)
                pendingKeyframes.removeValue(forKey: source)?.work.cancel()
            } else {
                switch deferredKeyframeAction(wait: wait,
                                              pendingDeadline: pendingKeyframes[source]?.deadline,
                                              now: now) {
                case .arm(let w):
                    deferred.append((source, w))
                case .rearmStale(let w):
                    // The scheduled IDR missed its deadline and is presumed lost. Replace it rather
                    // than drop this request: a deferred IDR that never arrives stops the engine
                    // forwarding the receiver's retries, and the stream never recovers.
                    print("[channel] keyframe for \(source) was armed and never fired — re-arming")
                    pendingKeyframes.removeValue(forKey: source)?.work.cancel()
                    deferred.append((source, w))
                case .alreadyArmed:
                    coveredByPendingKeyframe += 1
                }
            }
        }
        let suppressed = deferred.count
        // Rate-limited to one line a second: a storm produces several suppressions per second and the
        // report must not become the noise it describes. Silence would be worse — a request rdev
        // refused is exactly the kind of thing that hides.
        let report = suppressed > 0 && now - lastKeyframeSuppressionLog >= 1
        if report { lastKeyframeSuppressionLog = now }
        let interval = keyframeDebounce.minimumInterval
        lock.unlock()
        // OUTSIDE THE LOCK: encoderFor takes it, and NSLock is not reentrant.
        for source in allowed { if let encoder = encoderFor(source) { deliverRecovery(source, encoder: encoder) } else { rearmDeferredKeyframe(source: source) } }
        // EVERY DEFERRED REQUEST IS OWED AN IDR. Dropping one deadlocks the stream: the engine's NACK
        // responder marks a keyframe response outstanding when it forwards a request and reopens only
        // when one is actually sent, so a dropped request stops it forwarding the receiver's retries.
        // Measured with the drop version under 1% loss — 204 client PLIs became ONE keyframe and the
        // stream died after a second, against a steady 60 fps with the debounce off.
        for (source, wait) in deferred {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.pendingKeyframes.removeValue(forKey: source)
                self.lock.unlock()
                // NO ENCODER MEANS THE REQUEST IS STILL OWED. A scale or codec change REBUILDS the
                // encoder, so a deferred IDR can fire into a gap where there is nothing to ask —
                // and dropping it there is the deadlock: the engine reopens only when a keyframe is
                // actually sent. Re-arm instead, and do NOT consume the debounce slot for a request
                // that was never delivered.
                guard let encoder = self.encoderFor(source) else {
                    self.rearmDeferredKeyframe(source: source)
                    return
                }
                self.lock.lock()
                _ = self.keyframeDebounce.waitBeforeKeyframe(source: source, now: Date().timeIntervalSinceReferenceDate)
                self.lock.unlock()
                self.deliverRecovery(source, encoder: encoder)
            }
            lock.lock()
            pendingKeyframes[source] = (work, Date().timeIntervalSinceReferenceDate + wait)
            lock.unlock()
            keyframeQueue.asyncAfter(deadline: .now() + wait, execute: work)
        }
        if report {
            print("[channel] keyframe request suppressed — one IDR per \(Int(interval * 1000))ms per source"
                + (coveredByPendingKeyframe > 0 ? " (\(coveredByPendingKeyframe) covered by a pending IDR)" : ""))
        }
    }

    /// Re-schedule a deferred IDR that could not be delivered, one debounce interval out.
    ///
    /// Separate from the request path because it must NOT consult the debounce: this request has
    /// already waited its turn and was lost through no fault of the receiver's. Consulting it again
    /// would let a source whose encoder is slow to rebuild starve indefinitely.
    private func rearmDeferredKeyframe(source: String) {
        let wait = keyframeDebounce.minimumInterval
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pendingKeyframes.removeValue(forKey: source); self.lock.unlock()
            guard let encoder = self.encoderFor(source) else {
                self.rearmDeferredKeyframe(source: source)      // still nothing to ask; keep owing it
                return
            }
            self.lock.lock()
            _ = self.keyframeDebounce.waitBeforeKeyframe(source: source, now: Date().timeIntervalSinceReferenceDate)
            self.lock.unlock()
            self.deliverRecovery(source, encoder: encoder)
        }
        lock.lock()
        pendingKeyframes[source] = (work, Date().timeIntervalSinceReferenceDate + wait)
        lock.unlock()
        keyframeQueue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// A track for every streamed window, for `clientId` IF it is the driver AND its current
    /// connection has said hello. Safe only when the peer is past its first offer — which the hello
    /// guarantees: it arrived on a DataChannel. Idempotent via addVideo.
    /// Async workspace placement changes the source set after its original control message returned.
    func reconcileWorkspaceMedia() {
        let wanted=Set(activeVideoSourceIDs())
        let stale:[(String,String)]=lock.withLock {videoSlots.flatMap {client,slots in slots.keys.compactMap {source in
            guard case .workspace?=parseSourceID(source),!wanted.contains(source) else{return nil}
            return (client,source)
        }}}
        for (client,source) in stale {removeVideo(clientId:client,sourceID:source)}
        if let driver=currentDriver() {establishVideoIfActive(clientId:driver.clientId)}
    }

    private func establishVideoIfActive(clientId: String) {
        lock.lock()
        let peer = peers[clientId]?.mediaPeer
        let ready = active.isActive(clientId) && helloed.contains(clientId) && (peers[clientId]?.mediaReady ?? false)
        lock.unlock()
        guard let peer, ready else { return }
        for src in activeVideoSourceIDs() { addVideo(peer: peer, sourceID: src) }
    }

    /// The session, reconciled for `clientId`, the DRIVER: its preferences resolve every stream, the
    /// streams the state wants exist, each is routed over the driver's transport, and it holds a track
    /// for each — once its `client-hello` has arrived. A claim's came with its control open long before;
    /// a fresh join's arrives later and reconciles then.
    private func reconcileDriver(_ clientId: String) {
        guard lock.withLock({ active.isActive(clientId) && helloed.contains(clientId) }) else { return }
        // Claims may arrive on different transports. Recheck AFTER joining the reconciliation lane:
        // a prior owner's slow reconciliation can never finish after the new owner's reconciliation.
        reconcileLock.lock(); defer { reconcileLock.unlock() }
        lock.lock()
        // A window-less driver has no windows to reconcile: its streams stay stopped (`apply`).
        let ready = active.isActive(clientId) && helloed.contains(clientId)
        let epoch = ownershipEpoch
        let mode = peers[clientId]?.presentation ?? .terminalOnly
        let prefs = clientPrefs[clientId] ?? .default
        lock.unlock()
        guard ready, mode != .terminalOnly else { return }
        if mode == .streamedSources && !lock.withLock({ peers[clientId]?.mediaReady ?? false }) { return }
        defer {
            // A successor without hello (or terminal-only) has no pending reconcile to repair this
            // work. Retire this stale presentation; a waiting ready successor restarts it afterward.
            if currentDriverEpoch() != epoch { simDelegate?.onClientGone() }
        }
        if mode == .nativeSimulators { simDelegate?.reconcileNative(); return }
        simDelegate?.reconcile(driverPrefs: prefs)       // SimManager's lock only — never both
        // THE DRIVER'S TRANSPORT, for every window reconciled for it — recorded BEFORE the tracks, which
        // is when `addVideo` reads it (and an existing track is re-routed by the same call).
        if let delivery = helloDelivery(clientId) {
            for src in activeVideoSourceIDs() { setVideoDeliveryRequest(delivery, forSource: src) }
        }
        establishVideoIfActive(clientId: clientId)
    }

    /// A NEW DRIVER's own session-scoped connection settings, applied to its peer and echoed — what it
    /// last stated (`recoveryRequests`, `playoutRequests`), or none: a driver that never forced FEC runs
    /// adaptive, and one with no playout request starts at 20 ms, so the echo stops carrying the
    /// previous driver's. Called at activation, BEFORE the reconcile adds a track. Outside `lock` for
    /// the bridge and the delegate.
    private func applyConnectionSettings(_ clientId: String) {
        lock.lock()
        let peer = peers[clientId]?.mediaPeer
        let recovery = recoveryRequests[clientId]
        let playout = playoutRequests[clientId] ?? (minMs: defaultPlayoutDelayMinMs, maxMs: nil)
        lock.unlock()
        if let recovery { peer?.setRecoveryOverride(recovery) }
        simDelegate?.setRecoveryOverride(bp: recovery ?? nil)
        peer?.setPlayoutDelay(minMs: playout.minMs, maxMs: playout.maxMs)
        simDelegate?.setPlayoutDelay(minMs: playout.minMs, maxMs: playout.maxMs)
    }

    /// The transport `clientId`'s hello asked for, or nil for "no preference". RULING: on the HEADLESS
    /// path (no SimManager) an `rtp` hello expresses none, so `RDEV_DC_DELIVERY=1` still routes the eager
    /// "test" track by default — the wire cannot tell an absent `delivery` from an explicit `rtp`, and
    /// the env default would otherwise never apply again.
    private func helloDelivery(_ clientId: String) -> VideoDelivery? {
        let d = lock.withLock { clientDelivery[clientId] } ?? .rtp
        return (d == .rtp && isVideoSubscribed == nil) ? nil : d
    }

    /// `client-hello`: this connection's preferences and transport, and "my connection settings are
    /// stated — start". UNGATED (a passive client's is kept for its claim), but only from the client's
    /// CURRENT peer: a hello still draining from a connection a rebuild retired says nothing about the
    /// new one.
    private func handleClientHello(_ prefs: ClientPrefs, delivery: VideoDelivery, capability: Int?, peer p: ClientConnection) {
        lock.lock()
        guard peers[p.clientId] === p else { lock.unlock(); return }
        referenceCapabilities[p.clientId] = capability
        clientPrefs[p.clientId] = prefs
        clientDelivery[p.clientId] = delivery
        helloed.insert(p.clientId)
        lock.unlock()
        reconcileDriver(p.clientId)                      // a no-op unless it is the driver
    }

    /// `reattach-source`: re-add THIS driver's track for a streamed window — the WebCodecs stall recovery
    /// (amendment 2). It used to unsubscribe and resubscribe, which under the session state would close
    /// the window and open it again. No state changes; the track is removed and added again, which is
    /// what gives the client a fresh decoder's worth of stream.
    private func handleReattachSource(_ source: String, peer p: ClientConnection) {
        guard isActiveClient(p.clientId),
              simDelegate?.subscribedSourceIDs().contains(source) ?? (source == "test") else { return }
        removeVideo(clientId: p.clientId, sourceID: source)
        if let media = p.mediaPeer { addVideo(peer: media, sourceID: source) }
    }

    /// `set-prefs`: the client changed a preference. The WHOLE set, so this replaces what it had. A
    /// passive client's is kept; the driver's re-reconciles every stream (a codec change renegotiates).
    private func handleSetPrefs(_ prefs: ClientPrefs, clientId: String) {
        let referenceChanged = lock.withLock {
            let changed = (clientPrefs[clientId] ?? .default).av1ReferenceRecovery != prefs.av1ReferenceRecovery
            clientPrefs[clientId] = prefs
            return changed
        }
        reconcileDriver(clientId)
        if referenceChanged { refreshReferenceRecovery(clientId: clientId) }
    }

    /// A live opt-in/out keeps tracks and sinks. Paused streams configure on resume; new tracks
    /// configure on encoderReady. Serialized with those paths so retiring cannot disable a new route.
    private func refreshReferenceRecovery(clientId: String) {
        onMediaQueue {
            let streams = lock.withLock { () -> [(String, PionPeer, Int32, Int)] in
                guard active.isActive(clientId), let peer = peers[clientId]?.mediaPeer else { return [] }
                return (videoSlots[clientId] ?? [:]).compactMap { source, slots in
                    guard slots.sink != nil else { return nil }
                    let consumers = videoSlots.values.filter { $0[source] != nil }.count
                    return (source, peer, slots.slot, consumers)
                }
            }
            for (source, peer, slot, consumers) in streams {
                guard let encoder = encoderFor(source) else { continue }
                if configureReferenceRecovery(source: source, peer: peer, slot: slot, encoder: encoder, consumers: consumers) {
                    encoder.requestRecovery(.independentKeyframe) // also starts the epoch when capture is idle
                }
            }
        }
    }

    private func controlStateJSON(active: Bool, clients: Int) -> Data {
        Data(#"{"t":"control-state","active":\#(active ? "true" : "false"),"clients":\#(clients)}"#.utf8)
    }

    /// **THE LAST `control-state` A CLIENT GETS IS THE TRUTH** (docs/sources-and-focus.md): who drives is READ and
    /// SENT under `controlStateLock`, so the sends go out in the order of the reads and the last one carries the newest
    /// driver. Read under `lock` and sent outside it, two claims at once — the phone's on pion's thread, "This Mac"'s
    /// on the socket queue — could send in the opposite order: the page that read first, sent last, believed it drove
    /// while the wire, the keys and the snapshots went to the other — a frozen terminal with no "Move here" to tap.
    /// Held across sends, which never block and never call back (`MessageSocket.send`, `PionPeer.send`); taken
    /// before `lock`, never inside it.
    private func broadcastControlState() {
        controlStateLock.lock(); defer { controlStateLock.unlock() }
        lock.lock()
        let activeId = active.activeId; let count = active.clientCount
        let targets = controlPeers.map { ($0.key, $0.value) }
        let hook = _afterControlStateRead
        lock.unlock()
        hook?()
        for (id, peer) in targets {
            peer.send(.control, wrapMessage(controlStateJSON(active: id == activeId, clients: count)))
        }
    }
    private let controlStateLock = NSLock()

    /// Tests: runs between a `control-state`'s READ of who drives and its SENDS — where another claim can
    /// change the driver and send its own. Guarded by `lock`.
    var afterControlStateReadForTests: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _afterControlStateRead }
        set { lock.lock(); _afterControlStateRead = newValue; lock.unlock() }
    }
    private var _afterControlStateRead: (() -> Void)?

    /// Repoint the active injector (called by SimManager on a hot-swap). Guarded by `lock` — read on
    /// pion delegate threads in handleTouch, written here.
    ///
    /// THE OUTGOING INJECTOR IS RELEASED. Focus moving to another window and a source being
    /// unsubscribed both arrive here, and a key held at that moment would otherwise stay held on a
    /// window nobody is driving — on macOS a stuck ⌘ turns every later keystroke into a chord.
    /// Released OUTSIDE the lock, like every other injector call. Re-setting the SAME injector is
    /// not a routing change (a codec rebuild re-commits it) and must not drop a live window's keys.
    /// Remove only the retired instance: a concurrent focus/attach may already have routed a successor.
    func clearInjector(ifMatching retired: InputInjector?) {
        guard let retired else { return }
        lock.lock()
        guard injector === retired else { lock.unlock(); return }
        injector = nil
        lock.unlock()
        retired.releaseKeys()
    }

    /// The serialized focus lane drains this outgoing instance before raising its successor.
    /// A same-injector re-commit preserves held keys (e.g. codec negotiation finishing).
    func beginInjectorSwitch(to target: InputInjector?, forceDrain: Bool = false) -> InputInjector? {
        lock.withLock {
            guard forceDrain || injector !== target else { return nil }
            let outgoing = injector; injector = nil
            return outgoing
        }
    }

    public func setInjector(_ inj: InputInjector?) {
        lock.lock(); let outgoing = injector; injector = inj; lock.unlock()
        if outgoing !== inj { outgoing?.releaseKeys() }
    }

    /// Send a raw control-channel JSON payload to one client (wraps in the codec envelope).
    public func sendControl(_ payload: Data, to clientId: String) {
        lock.lock(); let peer = controlPeers[clientId]; lock.unlock()
        peer?.send(.control, wrapMessage(payload))
    }

    /// Send a raw JSON payload to one client on `bulk` (wraps in the codec envelope): the paste/drop protocol's
    /// replies and the image viewer's files — the transfers that left `control` when it joined the lane.
    public func sendBulk(_ payload: Data, to clientId: String) {
        lock.lock(); let peer = controlPeers[clientId]; lock.unlock()
        peer?.send(.bulk, wrapMessage(payload))
    }

    /// Every client with an open control channel, for a caller that must build a DIFFERENT payload
    /// per client. `broadcastControl` sends one payload to all, which is wrong for anything carrying
    /// per-client state — a mute set, for instance.
    public func controlClientIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(controlPeers.keys)
    }

    /// The clients holding a track for `sourceID`. Used to attach or detach that source's audio sink
    /// per client without reaching into `videoSlots` from outside.
    public func subscribedClientIDs(forSource sourceID: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return videoSlots.compactMap { $0.value[sourceID] != nil ? $0.key : nil }
    }

    /// Broadcast a raw control-channel JSON payload to every open control peer.
    public func broadcastControl(_ payload: Data) {
        lock.lock(); let targets = controlPeers.map { $0.value }; lock.unlock()
        for p in targets { p.send(.control, wrapMessage(payload)) }
    }

    // A client's terminal channel reached open: record the peer, and — if this is the driver — repaint
    // it with the active tab, if one exists.
    //
    // OPENING A CHANNEL CREATES NO SHELL, AND THAT IS A SECURITY BOUNDARY. This used to call
    // `ensureFirstTab()` unconditionally, so ANY client reaching this point spawned a shell — a
    // passive one that has not claimed control included. A channel open is a TRANSPORT EVENT: it says
    // a peer's SCTP stream came up, not that an authorized party asked for anything. Privilege must
    // rest on an authenticated request — and since 2026-09-25 a shell starts ONLY on an explicit one
    // (`open-terminal`, the tmux requests); nothing creates one implicitly.
    //
    // This matters more once the media transport is isolated, because a compromised one can fabricate
    // transport events at will — but it is already wrong without that: it lets a viewer spawn a
    // process on the host.
    private func terminalOpened(clientId: String, peer: ClientConnection) {
        lock.lock(); openPeers[clientId] = peer; let isActive = active.isActive(clientId); lock.unlock()
        if isActive { rebindTermWire() }
    }

    // A client's control channel reached open: record it and tell it whether it is the active client.
    private func controlOpened(clientId: String, peer: ClientConnection) {
        // Under `controlStateLock`, as every control-state is (`broadcastControlState`): a claim this page sends the
        // moment its channel opens (`SessionControl.reclaim`) must not have its "you drive" overtaken by this
        // "passive", read before it.
        controlStateLock.lock()
        lock.lock()
        controlPeers[clientId] = peer
        let isActive = active.isActive(clientId); let count = active.clientCount
        let hook = _afterControlStateRead
        lock.unlock()
        hook?()
        peer.send(.control, wrapMessage(controlStateJSON(active: isActive, clients: count)))
        controlStateLock.unlock()
        peer.send(.control, wrapMessage(hostUpdates.info(for: clientId)))
        hostUpdates.onRefresh { [weak self] in
            guard let self else { return }
            for id in self.controlClientIDs() { self.sendControl(self.hostUpdates.info(for: id), to: id) }
        }
        let (tabs, activeId) = terminals.descriptors()
        peer.send(.control, wrapMessage(termListJSON(tabs: tabs, activeId: activeId)))
        simDelegate?.sendViewSet(toClient: clientId)
        simDelegate?.sendSourceStatus(toClient: clientId)
    }

    /// **THE TAB BAR, BEFORE ANY CHANNEL OPENS** (2026-10-05, asked for; docs/sources-and-focus.md, "The offer carries
    /// the tab bar"): what a peer's FIRST offer carries (`offerJSON`'s `state`) — the messages `controlOpened` starts
    /// with: `control-state` (whether it drives — a passive client is drawn no terminal tab), the `term-list`, and the
    /// session state's windows (`SimControlDelegate.offerStatePayloads`). The client draws the session's real tabs from
    /// it while WebRTC still connects; the control channel's own copies replace them. Called on pion's dispatcher (the
    /// offer's callback), as `codecResolved` is: it takes this hub's lock, the pool's and SimManager's, one at a
    /// time, and never reaches the bridge.
    public func offerState(forClient id: String) -> [Data] {
        lock.lock(); let isActive = active.isActive(id); let count = active.clientCount; lock.unlock()
        let (tabs, activeId) = terminals.descriptors()
        return [controlStateJSON(active: isActive, clients: count), termListJSON(tabs: tabs, activeId: activeId)]
            + (simDelegate?.offerStatePayloads() ?? [])
    }

    /// **THE GRID A CLIENT SAID AS IT JOINED** (`JoinHello`, its `client-confirm`'s app_hello), applied at admission
    /// exactly as its own `resize` will be once `control` opens: the driver's alone, within the same bounds — so a
    /// connecting client (the driver from admission) has every tab at its grid before the offer is built, and the
    /// offer's screen (`offerScreen`) is what its terminal will show. A passive client's grid changes nothing.
    public func applyJoinGrid(_ grid: TermGridSize, clientId: String) {
        handleResize(cols: grid.cols, rows: grid.rows, clientId: clientId)
    }

    /// **THE SCREEN A FRESH OFFER CARRIES** (`term-screen`; docs/sources-and-focus.md, "The offer carries the tab
    /// bar"): the active tab's, once the redraw its join resize brought has settled (`TerminalManager.screenPreview`),
    /// for the DRIVER only — a passive client is drawn no terminal. `completion` runs once: the message, or nil
    /// (no driver, no tab, nothing within `within` nanoseconds).
    public func offerScreen(forClient id: String, within: UInt64, completion: @escaping @Sendable (Data?) -> Void) {
        guard isActiveClient(id), let active = terminals.descriptors().activeId else { return completion(nil) }
        terminals.screenPreview(active, within: within) { screen in
            completion(screen.map { termScreenJSON(id: active, size: $0.size, bytes: $0.bytes) })
        }
    }

    /// Only the DRIVER may touch the terminal. It creates NOTHING: since 2026-09-25 a shell starts only
    /// on an explicit request (`open-terminal`, and the tmux requests), so a transport event, a
    /// keystroke or an attach can never spawn a process. It holds no reference to `terminals` at all,
    /// which is what keeps the lazy first shell from coming back here unnoticed.
    @discardableResult
    private func ensureTerminalForDriver(_ clientId: String) -> Bool { isActiveClient(clientId) }

    /// Terminal bytes from the driver, delivered only if the client and the host agree about which tab
    /// the user was typing into.
    ///
    /// `switch-terminal` rides `control`; these bytes ride `input`. The two streams — the lane's, or the SCTP
    /// baseline's two channels — are ordered only against themselves, so the host has no arrival order to
    /// reason from and used to write whatever arrived into whatever was active — the keys typed around a tab
    /// switch landing in a shell the user was not looking at. `term` is the client's claim about what it was
    /// displaying, and `write(_:toTerminal:)` refuses the write when that disagrees.
    private func handleKey(_ s: String, term: TermTabID, clientId: String) {
        guard ensureTerminalForDriver(clientId) else { return }
        terminals.write(Data(s.utf8), toTerminal: term)
    }

    /// A device-query REPLY from the driver's xterm.js instance for `term` — the tab whose bytes asked.
    /// Not a keystroke: it goes to the tab it names while the host owes that tab a reply, and is held to
    /// the keystroke rule otherwise (`TerminalManager.writeReply`, `TerminalInput.shouldDeliverReply`).
    private func handleTermReply(_ s: String, term: TermTabID, clientId: String) {
        guard ensureTerminalForDriver(clientId) else { return }
        terminals.writeReply(Data(s.utf8), toTerminal: term)
    }

    /// A client's xterm.js palette (`term-palette`). Kept per client — a passive one's is the one the host
    /// answers from once it becomes the driver (`apply`) — and handed to the terminal at once if it is
    /// the driver's.
    private func handleTermPalette(_ palette: TermPalette, clientId: String) {
        lock.lock()
        termPalettes[clientId] = palette
        let isDriver = active.isActive(clientId)
        let seq = isDriver ? nextPaletteSeqLocked() : 0
        lock.unlock()
        if isDriver { terminals.setTermPalette(palette, seq: seq) }
    }

    /// The driver's current connection — the only one whose `terminal-pause`/`-resume` the gate acts on.
    private func driverConnection() -> AnyHashable? {
        lock.lock(); defer { lock.unlock() }
        return active.activeId.flatMap { peers[$0] }.map { AnyHashable(ObjectIdentifier($0)) }
    }

    /// Internal for `PeerHub.allClientsLeft`, which makes the driver leave LAST.
    func isActiveClient(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active.isActive(id)
    }

    private enum PasteSender: Equatable { case driver, passive, replaced }

    /// Who sent a paste message. A connection a REBUILD replaced speaks for nobody — as `SocketClients`
    /// drops a replaced socket's frames: its client's delivery was abandoned with it (`rebindPeer`), a
    /// straggling `paste-begin` from it would open a delivery nothing finishes (`busy` for 30 s), and a
    /// reply could reach only the NEW connection, which never heard of that id.
    private func pasteSender(_ p: ClientConnection) -> PasteSender {
        lock.lock(); defer { lock.unlock() }
        guard peers[p.clientId] === p else { return .replaced }
        return active.isActive(p.clientId) ? .driver : .passive
    }

    private func handleClaim(clientId: String, grid: TermGridSize? = nil) {
        lock.lock()
        let before = active.activeId
        let fx = active.claim(clientId)
        if before != active.activeId { ownershipEpoch &+= 1 }
        lock.unlock()
        apply(fx, incomingGrid: fx.activate == clientId ? grid : nil)
    }

    private func handleTouch(x: Double, y: Double, phase: String, button: MouseButton,
                             ts: Int?, clientId: String, peer: ClientConnection) {
        guard isActiveClient(clientId) else { return }
        // NOT given the button: the red/green press overlay reports that a press is DOWN, which is
        // equally true of either one.
        CursorOverlayState.shared.touch(phase: phase, x: x, y: y)
        lock.lock(); let inj = injector; lock.unlock()
        inj?.inject(touchNormalizedX: x, y: y, phase: phase, button: button)
        guard let ts else { return }
        let injectedAt = Int(Date().timeIntervalSince1970 * 1000)
        let json = #"{"t":"inputAck","ts":\#(ts),"injectedAtEpochMs":\#(injectedAt)}"#
        peer.send(.control, wrapMessage(Data(json.utf8)))
    }
    private func handleSimTouch(phase: String, points: [SimPoint], clientId: String) {
        guard isActiveClient(clientId) else { return }
        lock.lock(); let inj = injector; lock.unlock()
        inj?.simTouch(phase: phase, points: points)
    }

    private func handleSimText(_ text: String, clientId: String) {
        guard isActiveClient(clientId) else { return }
        lock.lock(); let inj = injector; lock.unlock()
        inj?.simText(text)
    }

    // A scroll event from the driver over the video surface → the focused source's injector (a window
    // injector acts on it; a sim injector no-ops via the protocol default). Active-gated like touch.
    /// Cursor passthrough: pushes the host app's cursor shape to the ACTIVE client whenever it changes.
    /// The callback runs on the MAIN thread (AppKit affinity), so it takes `lock` only to read the active id
    /// and never holds it across `sendControl`.
    var cursorPollingForTests: Bool { cursorWatcher.isPollingForTests }
    private lazy var cursorWatcher = CursorWatcher { [weak self] png, png3x, w, h, hx, hy in
        guard let self else { return }
        self.lock.lock(); let target = self.active.activeId; self.lock.unlock()
        guard let target else { return }   // only the driver has a pointer to dress
        self.sendControl(cursorJSON(pngBase64: png.base64EncodedString(), w: w, h: h,
                                    hotspotX: hx, hotspotY: hy, png3xBase64: png3x.base64EncodedString()), to: target)
    }

    /// Hover from the driver: move the host pointer over the focused source so the app updates its cursor
    /// shape. Same lock discipline as handleScroll — snapshot the injector under `lock`, call it OUTSIDE.
    private func handleHover(x: Double, y: Double, clientId: String) {
        guard isActiveClient(clientId) else { return }
        // Feeds the debug cursor rectangle. Unconditional: the state is three doubles behind an
        // already-taken lock, on a path that is active-gated and rate-limited to one message per
        // animation frame, and FrameOverlaySink — the only reader — is not installed at all unless
        // the overlay is on. A second enablement flag here would just be one more thing that can
        // disagree with the first.
        CursorOverlayState.shared.hover(x: x, y: y)
        lock.lock(); let inj = injector; lock.unlock()
        inj?.move(normalizedX: x, normalizedY: y)
        cursorWatcher.noteHover()   // arm the shape poll (self-disarms when hovering stops)
    }

    private func handleScroll(x: Double, y: Double, dx: Double, dy: Double,
                              unit: ScrollUnit, mods: InputModifiers, clientId: String) {
        guard isActiveClient(clientId) else { return }
        lock.lock(); let inj = injector; lock.unlock()
        inj?.scroll(normalizedX: x, normalizedY: y, deltaX: dx, deltaY: dy, unit: unit, mods: mods)
    }

    /// A touch client's flick ended: hand the velocity to the injector, which runs the glide on the
    /// HOST's clock. Active-gated with the same lock discipline as handleScroll.
    private func handleScrollFling(x: Double, y: Double, vx: Double, vy: Double,
                                   mods: InputModifiers, clientId: String) {
        guard isActiveClient(clientId) else { return }
        lock.lock(); let inj = injector; lock.unlock()
        inj?.scrollFling(normalizedX: x, normalizedY: y, velocityX: vx, velocityY: vy, mods: mods)
    }

    /// A key transition from the driver over the focused source. Active-gated, same lock discipline
    /// as handleScroll — snapshot the injector under `lock`, call it OUTSIDE.
    private func handleWinKey(down: Bool, code: String, key: String, repeat isRepeat: Bool,
                              mods: InputModifiers, clientId: String) {
        guard isActiveClient(clientId) else { return }
        lock.lock(); let inj = injector; lock.unlock()
        inj?.key(down: down, code: code, key: key, repeat: isRepeat, mods: mods)
    }

    /// The client lost keyboard focus (blur, window blur, tab hidden, pagehide) and will stop
    /// delivering keyups.
    private func handleWinKeysRelease(clientId: String) {
        guard isActiveClient(clientId) else { return }
        releaseInjectorKeys()
    }

    /// Release whatever the routed injector is holding. Called from every exit the client cannot
    /// report itself — ⌘W kills the browser tab mid-chord, so the ⌘-down was forwarded and the ⌘-up
    /// never will be. `releaseKeys` is idempotent, so calling it unconditionally is safe.
    private func readyScopedRouteLocked() -> Bool {
        guard let ticket = sourceInputRoute.current else { return false }
        return ticket.request != nil && sourceInputRoute.lease != nil && sourceOwnerLocked() == ticket.owner
    }

    private func releaseInjectorKeys(protectReadyScopedRoute: Bool = false) {
        let inj: InputInjector? = lock.withLock {
            // A fresh native lease proves its predecessor was drained BEFORE readiness. A late
            // outgoing claim/departure effect must not drain keys accepted under that new lease.
            if protectReadyScopedRoute && readyScopedRouteLocked() { return nil }
            return injector
        }
        guard let inj else { return }
        if protectReadyScopedRoute {
            inj.releaseAfterOwnershipChange(postFence: { [weak self, weak inj] post in
                guard let self, let inj else { return false }
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.injector === inj, !self.readyScopedRouteLocked() else { return false }
                post(); return true
            })
        } else { inj.releaseKeys() }
    }
    /// The DRIVER's terminal stream: a fresh `TermWire` (fresh per-tab contexts) whenever the driver,
    /// its terminal channel or its `term-mode raw` declaration changes, then a snapshot of every open tab
    /// into it. A driver that has not declared (or no driver) gets no wire — and the terminal channel
    /// carries NOTHING but a wire.
    ///
    /// The OLD wire is retired INSIDE `lock`, before the new one is installed: an emitter can reach the
    /// new wire only through `currentTermWire()` (under `lock`), so by the time any emitter can send the
    /// new wire's start — lazily, from its first `emit` — the old wire has already delivered its last
    /// frame (`retire` waits out an emission in flight) and drops every later one. No frame of the old
    /// wire can follow the new wire's start, whatever the emitters holding the old reference do. Rebinds
    /// racing each other are serialised by the same section: each retires its predecessor before its
    /// own wire is reachable, and a `begin()` on a wire already retired by a later rebind sends nothing.
    /// Deadlock-free: `TermWire.emit` holds only the wire's lock and never takes the hub's.
    ///
    /// `grid`: the NEW driver's terminal grid, when it said one (`claim-control`). Every tab takes it AFTER the old
    /// wire is retired — the outgoing driver gets none of it — and BEFORE the snapshots, which are then at it. Without
    /// it they were at the PREVIOUS driver's grid: the claimer committed that layout reflowed to its own size and
    /// showed it for a frame or more, until its `resize` brought a second set (2026-10-06, measured: 2–6 frames —
    /// "a one-frame blink of something that looks like the other device's size"). docs/terminal.md, "A claim says
    /// its grid".
    private func rebindTermWire(grid: TermGridSize? = nil) {
        lock.lock()
        termWire?.retire()
        wireGeneration += 1
        let epoch = wireGeneration
        let id = active.activeId
        let peer = id.flatMap { openPeers[$0] }
        let declared = id.map { wirePeers.contains($0) } ?? false
        if let peer, declared {
            let tap = _termWireTap          // `lock` is held
            // THE PACER (docs/terminal.md, "A slow link gets the terminal paced"): frames go to pion while the channel is
            // within its budget, the rest wait where they can be reordered — the tab on screen first — and are dropped
            // with the wire. A socket client reports nothing buffered, so its frames go straight through.
            let key = ObjectIdentifier(peer)
            // Fast framing and ACKs add lane traffic. Pair its 8 KiB floor with 2 KiB terminal
            // units so a slow link has frequent scheduling boundaries (docs/terminal.md).
            if termPaths[key]?.peer.peer !== peer { termPaths[key] = (Weak(peer: peer), TermPath(minimumBytes: peer is FastClientConnection ? 8192 : TermPath.floorBytes)) }
            termPaths = termPaths.filter { $0.value.peer.peer != nil }
            let path = termPaths[key]!.path
            let terminals = self.terminals
            let pacer = SharedTermPacer(path: path, deps: .init(
                send: { [weak peer] d in tap?(d); peer?.send(.terminal, d) },
                buffered: { [weak peer] in peer?.bufferedAmount(.terminal) },
                now: { DispatchTime.now().uptimeNanoseconds },
                // The product's STRICT timer: a plain `asyncAfter` ran 17–34 ms late while the app was not visible
                // (App Nap) — the usual state of a Mac driven from elsewhere (docs/terminal.md, "THE SEND BUFFER").
                schedule: TerminalManager.strictTimer,
                activeTab: { [weak terminals] in terminals?.descriptors().activeId?.wire }),
                epoch: epoch, messageCeiling: peer is FastClientConnection ? 2048 : TermWire.frameBytes,
                capacity: peer is FastClientConnection ? 2 * 1024 * 1024 : TermPath.ceilingBytes,
                failed: { [weak self, weak peer] reason in
                    guard let peer else { return }
                    self?.terminalStreamFailed(peer, epoch: epoch, reason: reason)
                })
            termWire = TermWire(epoch: epoch, messageCeiling: peer is FastClientConnection ? 2048 : TermWire.frameBytes, pacer: pacer)
            termWireOwner = peer.clientId
        } else {
            termWire = nil
            termWireOwner = nil
        }
        let wire = termWire
        let generation = wireGeneration
        let pause = _afterTermWireInstalled
        lock.unlock()
        pause?()
        terminals.setDriverDecodesWire(wire != nil, generation: generation)
        // Resized with NO re-send of its own: the snapshots below are every tab's, at this grid.
        if let grid { terminals.resizeAll(cols: grid.cols, rows: grid.rows, resend: false) }
        // The start (unless an emitter already sent it), then a snapshot of every tab — INTO THIS WIRE and
        // only while this rebind is the newest (`SnapshotTarget`): a racing newer rebind snapshots its own. A tab
        // just resized (the grid above, a join's) is snapshotted once its program's redraw is in, not before it.
        if let wire {
            wire.begin()
            terminals.snapshotAllSettled(into: .init(generation: generation, emit: { wire.emit($0) }))
        }
    }

    /// Failure arrives asynchronously, outside wire/pacer critical sections. A
    /// retired wire's late notification cannot invalidate its replacement.
    func terminalStreamFailed(_ peer: ClientConnection, epoch: UInt64, reason: SharedTermPacer.Failure) {
        lock.lock()
        guard openPeers[peer.clientId] === peer, termWire?.epoch == epoch else { lock.unlock(); return }
        termWire?.retire(); termWire = nil; termWireOwner = nil
        wireGeneration += 1
        let generation = wireGeneration
        lock.unlock()
        terminals.setDriverDecodesWire(false, generation: generation)
        let name: String
        switch reason {
        case .overloaded: name = "overloaded"
        case .codec: name = "codec"
        case .transport: return // the carrier's normal failure path handles reconnection
        }
        let payload = try! JSONSerialization.data(withJSONObject: ["t": "term-stream-error", "reason": name, "epoch": String(epoch)])
        peer.send(.control, wrapMessage(payload))
    }

    private func currentTermWire() -> TermWire? {
        lock.lock(); defer { lock.unlock() }; return termWire
    }

    /// Tests: runs inside `rebindTermWire` right after the new wire is REACHABLE (the hub lock released)
    /// — the point where a concurrent emitter can pick the new wire up, before the manager hears of it.
    /// Guarded by `lock`.
    var afterTermWireInstalledForTests: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _afterTermWireInstalled }
        set { lock.lock(); _afterTermWireInstalled = newValue; lock.unlock() }
    }
    private var _afterTermWireInstalled: (() -> Void)?

    /// Tests: runs inside `rebindPeer` right after it dropped the rebuilt driver's wire and released
    /// the hub lock — where a claim can bind another driver's wire before this path finishes.
    var afterWireDroppedForRebuildForTests: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _afterWireDroppedForRebuild }
        set { lock.lock(); _afterWireDroppedForRebuild = newValue; lock.unlock() }
    }
    private var _afterWireDroppedForRebuild: (() -> Void)?

    /// Where a media hold is when `mediaHoldHookForTests` runs: `.willApply` before it checks its
    /// generation, `.applying` after it recorded the pause and before any of its effects.
    enum MediaHoldPhase { case willApply, applying }
    /// Tests: runs inside the media hold at each `MediaHoldPhase`, on the hold's thread. Guarded by `lock`.
    var mediaHoldHookForTests: ((MediaHoldPhase) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _mediaHoldHook }
        set { lock.lock(); _mediaHoldHook = newValue; lock.unlock() }
    }
    private var _mediaHoldHook: ((MediaHoldPhase) -> Void)?

    /// Tests: a negotiated (client, source) track slot with no sink, as `addVideo` records one — a
    /// never-connected PionPeer cannot negotiate a real one.
    func installVideoSlotForTests(clientId: String, sourceID: String, slot: Int32, audioSlot: Int32 = -1) {
        lock.lock(); videoSlots[clientId, default: [:]][sourceID] = (slot, audioSlot, nil, nil); lock.unlock()
    }

    /// Tests: the wire currently bound, nil with none.
    var termWireForTests: TermWire? { currentTermWire() }

    /// Tests: sees every message a terminal wire bound after it is set delivers. Guarded by `lock`.
    var termWireTap: ((Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _termWireTap }
        set { lock.lock(); _termWireTap = newValue; lock.unlock() }
    }
    private var _termWireTap: ((Data) -> Void)?

    /// Tests: the client the terminal wire is bound to, nil with none.
    var termWireClientId: String? { lock.lock(); defer { lock.unlock() }; return termWireOwner }
    /// Tests: wait for every terminal pause/resume queued so far.
    func syncTerminalPause() { terminalPause.sync() }

    // A client declared that it decodes the terminal wire. A driver gets a fresh wire (a snapshot of
    // every tab); a repeated declaration is the client asking for exactly that after a decode failure.
    private func handleTermWire(clientId: String) {
        lock.lock(); wirePeers.insert(clientId); lock.unlock()
        if isActiveClient(clientId) { rebindTermWire() }
    }

    // The driver's pane changed size: every tab reflows (emulator + PTY). The client repaints from the
    // live stream and the SIGWINCH-driven redraw. Ignored from non-drivers and for out-of-range sizes.
    private func handleResize(cols: Int, rows: Int, clientId: String) {
        guard cols >= 1, cols <= 500, rows >= 1, rows <= 500 else { return }
        guard isActiveClient(clientId) else { return }
        terminals.resizeAll(cols: cols, rows: rows)
    }

    /// The terminal pool changed. The SESSION's bar keeps its terminal half current FIRST
    /// (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §3) — a tab that opened enters the
    /// order beside its siblings, one that closed leaves it, and a `view-set` says so — THEN the tab list,
    /// so a client rarely holds a `term-list` tab its `view-set` has not placed yet (it places one by the
    /// host's rule if it does). Outside every lock: `TerminalManager` calls this outside its own, and
    /// `SimManager` takes and releases its own (the two are never held together).
    private func terminalTabsChanged() {
        // ONE STEP, read to broadcast (review M9, 2026-10-01): this runs on several threads — the message
        // path, the title debounce, tmux's callbacks, a shell's exit — and a read that lost the race to a
        // fresher one, synced AFTER it, put a closed tab back into the bar's order (and the last
        // `term-list`) as a ghost. Its own lock, never `lock`: the sync takes `SimManager`'s, and the two
        // are never held together. Nothing inside takes this lock again, and nothing holding another
        // takes it.
        tabsChangedLock.lock()
        defer { tabsChangedLock.unlock() }
        let (tabs, activeId) = terminals.descriptors()
        terminalTabsReadForTests?()
        simDelegate?.syncTerminalTabs(tabs.map(\.id.wire))
        broadcastControl(termListJSON(tabs: tabs, activeId: activeId))
    }
    private let tabsChangedLock = NSLock()

    /// Tests: runs in `terminalTabsChanged` between its read of the pool and the sync, no hub lock held.
    var terminalTabsReadForTests: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _terminalTabsRead }
        set { lock.lock(); _terminalTabsRead = newValue; lock.unlock() }
    }
    private var _terminalTabsRead: (() -> Void)?

    /// The driver moved a tab of the bar. With a session state (`SimManager`), the bar's order is the
    /// state's: the move happens there, and when the moved tab is a TERMINAL the pool takes the order's
    /// terminal half (`arrange` → `term-list`), so `TabPool.close`'s "previous neighbour" is the one the
    /// person sees. WITHOUT one (the test-pattern harness) only terminals exist: the tab moves within the
    /// pool, `before` a terminal or the end — a window key names nothing there and is refused.
    private func handleMoveTab(_ tab: String, before: String?) {
        if let simDelegate {
            guard let order = simDelegate.moveTab(tab, before: before), TabKey.isTerminal(tab) else { return }
            terminals.arrange(order.compactMap(TermTabID.init(wire:)))
            return
        }
        guard let id = TermTabID(wire: tab) else { return }
        var target: TermTabID? = nil
        if let before {
            guard let b = TermTabID(wire: before) else { return }
            target = b
        }
        terminals.move(id, before: target)
    }

    /// The driver named a tab. A `pty:` tab's name is the pool's (→ `term-list`); a `tmux:` tab's is its
    /// SESSION's, renamed through tmux off this path (a refusal comes back as `tmux-error rename-failed`);
    /// a window's is the session state's (→ `view-set`).
    private func handleRenameTab(_ tab: String, name: String, clientId: String) {
        if TabKey.isAgent(tab) {
            simDelegate?.agentTab(action: "rename-tab", thread: String(tab.dropFirst(6)), title: name, cwd: "")
            return
        }
        guard let id = TermTabID(wire: tab) else {
            simDelegate?.renameWindow(sourceID: tab, name: name, requestedBy: clientId)
            return
        }
        switch id {
        case .pty: terminals.rename(id, name)
        case .tmux(let session): terminals.renameTmux(session, name)
        }
    }

    // Any client may ASK for the tab list (only the driver renders it).
    private func handleListTerminals(clientId: String) {
        let (tabs, activeId) = terminals.descriptors()
        sendControl(termListJSON(tabs: tabs, activeId: activeId), to: clientId)
    }

    // Open a new shell at the driver's reported grid and make it active. Its snapshot and output
    // reach the driver on the wire (TerminalManager emits them); the tab list follows onTabsChanged.
    private func handleOpenTerminal(clientId: String) {
        guard isActiveClient(clientId) else { return }
        // Refused at the cap: SAY so, or the client keeps waiting to focus a tab that is not coming.
        if !terminals.open() { sendControl(termErrorJSON(reason: "too-many-tabs"), to: clientId) }
    }

    // ⌘⇧T: the tab the driver closed last comes back (`TerminalManager.reopenClosed`). Nothing to bring back,
    // or the cap, is SAID, or the client keeps waiting for a tab that is not coming.
    private func handleReopenTerminal(clientId: String) {
        guard isActiveClient(clientId) else { return }
        switch terminals.reopenClosed() {
        case .reopened: break
        case .nothingClosed: sendControl(termErrorJSON(reason: "nothing-to-reopen"), to: clientId)
        case .full: sendControl(termErrorJSON(reason: "too-many-tabs"), to: clientId)
        }
    }

    // Close a shell; the wire carries its `closed`. Remembered for ⌘⇧T.
    private func handleCloseTerminal(id: TermTabID, clientId: String) {
        guard isActiveClient(clientId) else { return }
        _ = terminals.closeRemembering(id)
    }

    // Switch the ACTIVE tab (which one keystrokes and device-query replies belong to). Every tab is
    // already live on the client, so nothing is sent on the terminal channel.
    private func handleSwitchTerminal(id: TermTabID, clientId: String) {
        guard isActiveClient(clientId) else { return }
        _ = terminals.switchTo(id)
    }

    /// THE PERSON LANDED ON A TERMINAL TAB (`SessionState.landing`): the window they were at is going and
    /// the tab to its left is a terminal, so it becomes the active one. NO DRIVER GATE — what caused it was
    /// the driver's intent (`×`, `−` carrying `land`), already gated where it arrived. `SimManager` calls this
    /// BEFORE it commits the change, so the `term-list` naming the tab reaches a client ahead of any `view-set`
    /// showing the surface. Outside every lock, like every `SimManager` → hub call.
    func landOnTerminal(_ key: String) {
        guard let id = TermTabID(wire: key), terminals.descriptors().activeId != id else { return }
        _ = terminals.switchTo(id)
    }

    // MARK: tmux

    /// UNGATED like `list-terminals`: it reads, it mutates nothing.
    private func sendTmuxList(to clientId: String) {
        let (available, sessions) = terminals.listTmux()
        sendControl(tmuxListJSON(available: available, sessions: sessions), to: clientId)
    }

    private func sendTmuxListToDriver() {
        lock.lock(); let driver = active.activeId; lock.unlock()
        if let driver { sendTmuxList(to: driver) }
    }

    /// A WINDOW TAB'S BELL (docs/window-capture-and-input.md, "A window's bell"): the application owning
    /// `sources` raised its Dock badge. The DRIVER's alone — a passive client marks nothing.
    func sendWindowBell(sources: [String]) { sendToDriver(windowBellJSON(sources: sources)) }

    private func sendToDriver(_ payload: Data) {
        lock.lock(); let driver = active.activeId; lock.unlock()
        if let driver { sendControl(payload, to: driver) }
    }

    private func sendTerminalClipboard(_ term: TermTabID, epoch: UInt64, bytes: Data) {
        let messages = termClipboardJSON(term: term, epoch: epoch, copy: UUID().uuidString, bytes: bytes)
        lock.lock()
        guard termWire?.epoch == epoch, let id = termWireOwner, active.activeId == id, let peer = controlPeers[id] else { lock.unlock(); return }
        lock.unlock()
        for message in messages {
            lock.lock()
            let current = termWire?.epoch == epoch && termWireOwner == id && active.activeId == id && controlPeers[id] === peer
            lock.unlock()
            guard current else { return }
            // Send to the captured connection, never resolve an ID again after a reconnect/handoff.
            peer.send(.control, wrapMessage(message))
        }
    }

    private static func tmuxErrorReason(_ e: TerminalManager.TmuxOpenError) -> String {
        switch e {
        case .unavailable: return "unavailable"
        case .gone: return "session-gone"
        case .full: return "too-many-tabs"
        case .failed: return "failed"
        }
    }

    private func handleOpenTmux(_ session: String, clientId: String) {
        guard isActiveClient(clientId) else { return }
        switch terminals.openTmux(session) {
        case .success: break
        case .failure(let e): sendControl(tmuxErrorJSON(session: session, reason: Self.tmuxErrorReason(e)), to: clientId)
        }
    }

    private func handleNewTmux(clientId: String) {
        guard isActiveClient(clientId) else { return }
        switch terminals.newTmux() {
        case .success: sendTmuxList(to: clientId)
        case .failure(let e): sendControl(tmuxErrorJSON(session: nil, reason: Self.tmuxErrorReason(e)), to: clientId)
        }
    }

}

extension ChannelHub {
    /// A logical channel of `c` OPENED — a WebRTC client's data channel, or every channel of a socket
    /// client when its hello is admitted (`SocketClients`). A transport event, never an authorization.
    public func connection(_ c: ClientConnection, didOpen ch: PionChannel) {
        guard lock.withLock({ peers[c.clientId] === c }) else { return }
        if ch == .terminal { terminalOpened(clientId: c.clientId, peer: c) }
        if ch == .control { controlOpened(clientId: c.clientId, peer: c) }
    }

    /// A message's case name for a log line — never its payload, which can be a keystroke.
    private static func caseName(_ m: InboundMessage) -> String {
        Mirror(reflecting: m).children.first?.label ?? String(describing: m)
    }

    /// Whether `clientId`'s connection carries no media. Unknown clients read as windowed (false): the
    /// callers act only on registered ones.
    func presentation(for clientId: String) -> ClientPresentation {
        lock.withLock { peers[clientId]?.presentation ?? .terminalOnly }
    }

    private func isWindowless(_ clientId: String) -> Bool {
        lock.withLock { peers[clientId].map { $0.presentation == .terminalOnly } ?? false }
    }

    /// One message from `c` on `ch`. Dispatched by CONTENT (`parseInbound`), as it always was.
    public func connection(_ c: ClientConnection, didReceive data: Data, on ch: PionChannel) {
        guard lock.withLock({ peers[c.clientId] === c }) else { return }
        let p = c
        guard let payload = unwrapMessage(data) else {
            print("[channel] \(p.clientId) dropped message with unsupported codec byte=\(data.first.map { String($0) } ?? "?")")
            return
        }
        if ch == .control, hostUpdates.receive(payload, client: c.clientId, reply: { [weak self, weak c] data in
            guard let self, let c, self.lock.withLock({ self.peers[c.clientId] === c }) else { return }
            self.sendControl(data, to: c.clientId)
        }) { return }
        guard let msg = parseInbound(payload) else { return }
        receive(msg, from: c)
    }

    func currentDriverEpoch() -> UInt64? { lock.withLock { active.activeId == nil ? nil : ownershipEpoch } }
    /// The final native post is nonblocking; hold the ownership lock only across that post,
    /// never across AX/capture queries. A claim cannot overtake an admitted old-generation event.
    func performInput(ifCurrentEpoch epoch: UInt64?, _ post: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let epoch, active.activeId != nil, ownershipEpoch == epoch else { return false }
        post(); return true
    }
    func isCurrentDriver(_ c: ClientConnection, epoch: UInt64) -> Bool {
        lock.withLock { ownershipEpoch == epoch && peers[c.clientId] === c && active.isActive(c.clientId) }
    }

    func currentDriver() -> ClientConnection? { lock.withLock { active.activeId.flatMap { peers[$0] } } }

    func installAgents(_ manager: AgentManager) {
        agents = manager
        manager.onStatus = { [weak self] thread, status, flags in self?.simDelegate?.agentStatus(thread: thread, status: status, activeFlags: flags) }
        manager.onEvent = { [weak self] event in
            guard let self else { return }
            let target: (ClientConnection,UInt64)? = self.lock.withLock {
                guard let id = self.active.activeId, let peer = self.peers[id],
                      self.agentViewers[ObjectIdentifier(peer)] == self.ownershipEpoch else { return nil }
                return (peer,self.ownershipEpoch)
            }
            if let (peer,epoch) = target { self.deliverAgent(["t":"agent-event","v":1,"epoch":String(epoch),"event":event],to:peer,epoch:epoch) }
        }
    }
    private func handleAgent(_ command: AgentCommand, from peer: ClientConnection) {
        let epoch: UInt64? = lock.withLock {
            guard peers[peer.clientId] === peer, active.isActive(peer.clientId) else { return nil }
            if command.op == "hello" { agentViewers = [ObjectIdentifier(peer):ownershipEpoch] }
            else if command.epoch != String(ownershipEpoch) || agentViewers[ObjectIdentifier(peer)] != ownershipEpoch { return nil }
            return ownershipEpoch
        }
        guard let epoch else { return }
        guard ProductFeatures.graphicalAgents, let agents else {
            deliverAgent(["t":"agent-response", "v":1, "id":command.id, "epoch":String(epoch),
                          "error":"Graphical agents are unavailable in this edition."], to:peer, epoch:epoch)
            return
        }
        if command.op == "select-tab" || command.op == "close-tab" {
            guard isCurrentDriver(peer, epoch: epoch), let thread = command.thread else { return }
            simDelegate?.agentTab(action: command.op, thread: thread, title: "", cwd: "")
            deliverAgent(["t":"agent-response", "v":1, "id":command.id, "epoch":String(epoch), "result":[:]], to:peer, epoch:epoch)
            return
        }
        agents.handle(command,authorized:{ [weak self, weak peer] in
            guard let self, let peer else { return false }; return self.isCurrentDriver(peer,epoch:epoch)
        }) { [weak self, weak peer] result in
            guard let self, let peer else { return }
            if command.op == "open-tab", self.isCurrentDriver(peer, epoch: epoch),
               case .success(let value) = result, let thread = value["thread"] as? [String:Any],
               let id = thread["id"] as? String, id == command.thread {
                self.simDelegate?.agentTab(action: "open-tab", thread: id,
                    title: (thread["name"] as? String) ?? (thread["preview"] as? String) ?? "Codex session",
                    cwd: (thread["cwd"] as? String) ?? "")
                let status = thread["status"] as? [String:Any]
                self.simDelegate?.agentStatus(thread: id, status: status?["type"] as? String, activeFlags: status?["activeFlags"] as? [String] ?? [])
            }
            var response: [String:Any] = ["t":"agent-response","v":1,"id":command.id,"epoch":String(epoch)]
            switch result { case .success(let value): response["result"] = value; case .failure(let error): response["error"] = error.localizedDescription }
            self.deliverAgent(response,to:peer,epoch:epoch)
        }
    }
    private func deliverAgent(_ object: [String:Any], to peer: ClientConnection, epoch: UInt64) {
        agentSender.send(object,authorized:{ [weak self, weak peer] in
            guard let self, let peer else { return false }; return self.isCurrentDriver(peer,epoch:epoch)
        },buffered:{ [weak peer] in peer?.bufferedAmount(.bulk) },deliver:{ [weak self, weak peer] bulk,data in
            guard let self, let peer, self.isCurrentDriver(peer,epoch:epoch) else { return }
            peer.send(bulk ? .bulk:.control,wrapMessage(data))
        })
    }

    /// Resolve a capability sender against the currently registered connection. Called outside
    /// SimManager.lock; a retired connection's late announcement cannot replace its successor.
    func currentConnection(clientID: String, expectedOID: ObjectIdentifier) -> ClientConnection? {
        lock.withLock {
            guard let peer = peers[clientID], ObjectIdentifier(peer) == expectedOID else { return nil }
            return peer
        }
    }

    func isCurrentDriver(_ c: ClientConnection) -> Bool {
        lock.withLock { peers[c.clientId] === c && active.isActive(c.clientId) }
    }

    private func sourceOwnerLocked() -> String? {
        guard let id = active.activeId, let peer = peers[id] else { return nil }
        return "\(ObjectIdentifier(peer)):\(ownershipEpoch)"
    }

    func prepareSourceFocus(source: String?, revision: UInt64, activation: String?) -> SourceFocusRoutePlan? {
        lock.withLock {
            let owner = sourceOwnerLocked()
            if let activation {
                guard let request = sourceFocusRequest, request.request == activation, request.source == source,
                      request.epoch == ownershipEpoch,
                      active.activeId.flatMap({ peers[$0] }).map(ObjectIdentifier.init) == request.connection else { return nil }
            }
            sourceInputRoute.setOwner(owner)
            guard owner != nil else { return activation == nil ? SourceFocusRoutePlan(epoch: nil, ticket: nil) : nil }
            let request = sourceFocusRequest.flatMap { pending -> String? in
                guard pending.source == source, pending.epoch == ownershipEpoch,
                      active.activeId.flatMap({ peers[$0] }).map(ObjectIdentifier.init) == pending.connection else { return nil }
                return pending.request
            }
            guard let ticket = sourceInputRoute.intend(source: source, revision: revision, request: request) else { return nil }
            return SourceFocusRoutePlan(epoch: ownershipEpoch, ticket: ticket)
        }
    }

    private func sourceFocusCurrentLocked(_ plan: SourceFocusRoutePlan) -> Bool {
        let epoch = active.activeId == nil ? nil : ownershipEpoch
        guard epoch == plan.epoch else { return false }
        guard let ticket = plan.ticket else { return epoch == nil }
        return sourceOwnerLocked() == ticket.owner && sourceInputRoute.current == ticket
    }
    func sourceFocusIsCurrent(_ plan: SourceFocusRoutePlan) -> Bool { lock.withLock { sourceFocusCurrentLocked(plan) } }

    @discardableResult func commitSourceFocus(_ plan: SourceFocusRoutePlan, injector target: InputInjector?) -> Bool {
        // Preparation/readback may join the HID queue. NEVER do that while holding the hub lock: a final post
        // on that queue may itself need this lock to validate its captured lease.
        let simulatorScroll = (target as? SimulatorInputInjector)?.nativeScrollGestureSupported
        lock.lock()
        guard sourceFocusCurrentLocked(plan) else { lock.unlock(); return false }
        injector = target
        var response: (ClientConnection, [String: Any])?
        if let ticket = plan.ticket {
            var lease: String?
            if ticket.source != nil, target != nil {
                let proposed = sourceInputRoute.lease ?? UUID().uuidString
                guard sourceInputRoute.commit(ticket, lease: proposed) else { lock.unlock(); return false }
                lease = proposed
            }
            if let request = ticket.request, let id = active.activeId, let peer = peers[id],
               sourceInputCapabilities[id] == ObjectIdentifier(peer), (ticket.source == nil || lease != nil) {
                var object: [String: Any] = ["t": "source-focus", "request": request,
                    "source": ticket.source.map { $0 as Any } ?? NSNull()]
                if let lease { object["lease"] = lease }
                if let simulatorScroll { object["scrollGestures"] = simulatorScroll ? ["simulator"] : [String]() }
                response = (peer, object)
            }
        }
        lock.unlock()
        if let (peer, object) = response { sendSourceInputReply(object, to: peer) }
        return true
    }

    func failSourceFocus(_ plan: SourceFocusRoutePlan, error: String) {
        lock.lock()
        guard sourceFocusCurrentLocked(plan) else { lock.unlock(); return }
        injector = nil
        let ticket = plan.ticket
        sourceInputRoute.setOwner(nil)
        let peer = active.activeId.flatMap { peers[$0] }
        lock.unlock()
        if let ticket, let request = ticket.request, let peer {
            sendSourceInputReply(["t": "source-focus", "request": request,
                "source": ticket.source.map { $0 as Any } ?? NSNull(), "error": error], to: peer)
        }
    }

    private func sendSourceInputReply(_ object: [String: Any], to peer: ClientConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        peer.send(.control, wrapMessage(data))
    }

    private func releaseUnavailableSourceInput(source: String?, request: String, from peer: ClientConnection) {
        let captured: (InputInjector, UInt64)? = lock.withLock {
            guard peers[peer.clientId] === peer, active.isActive(peer.clientId),
                  let pending = sourceFocusRequest, pending.request == request, pending.source == source,
                  pending.connection == ObjectIdentifier(peer), pending.epoch == ownershipEpoch,
                  let injector else { return nil }
            return (injector, ownershipEpoch)
        }
        guard let (target, epoch) = captured else { return }
        // Neutral-only authority for this failed activation. A later activation/owner invalidates
        // it at post, so a delayed failed-focus cleanup cannot release somebody else's new chord.
        target.submitScoped(.winKeysRelease, postFence: { [weak self, weak peer, weak target] post in
            guard let self, let peer, let target else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.ownershipEpoch == epoch, self.peers[peer.clientId] === peer,
                  self.active.isActive(peer.clientId), self.injector === target,
                  self.sourceInputRoute.lease == nil, let pending = self.sourceFocusRequest,
                  pending.connection == ObjectIdentifier(peer), pending.epoch == epoch,
                  pending.request == request, pending.source == source else { return false }
            post(); return true
        })
    }

    private func handleSourceInput(_ command: SourceInputCommand, from peer: ClientConnection) {
        switch command {
        case .capabilities:
            let accepted = lock.withLock { () -> Bool in
                guard peers[peer.clientId] === peer else { return false }
                sourceInputCapabilities[peer.clientId] = ObjectIdentifier(peer)
                return true
            }
            if accepted { sendSourceInputReply(["t": "source-input-capabilities", "v": 1, "scrollGestures": ["window", "display"]], to: peer) }
        case .focus(let source, let request):
            let accepted = lock.withLock { () -> Bool in
                guard peers[peer.clientId] === peer, active.isActive(peer.clientId),
                      sourceInputCapabilities[peer.clientId] == ObjectIdentifier(peer) else { return false }
                // Invalidate synchronously, BEFORE delegate work or AX can block. Even an invalid
                // destination cannot leave the old presentation's queued input admitted.
                sourceInputRoute.setOwner(nil)
                sourceFocusRequest = SourceFocusRequest(connection: ObjectIdentifier(peer), epoch: ownershipEpoch,
                    source: source, request: request)
                return true
            }
            guard accepted else { return }
            if simDelegate?.sourceInputFocus(source: source, request: request, requestedBy: peer.clientId) != true {
                releaseUnavailableSourceInput(source: source, request: request, from: peer)
                sendSourceInputReply(["t": "source-focus", "request": request,
                    "source": source.map { $0 as Any } ?? NSNull(), "error": "source-unavailable"], to: peer)
            }
        case .input(let source, let lease, let event):
            let captured: (InputInjector, UInt64)? = lock.withLock {
                guard peers[peer.clientId] === peer, active.isActive(peer.clientId),
                      sourceInputCapabilities[peer.clientId] == ObjectIdentifier(peer),
                      let owner = sourceOwnerLocked(), sourceInputRoute.permits(owner: owner, source: source, lease: lease),
                      let injector else { return nil }
                return (injector, ownershipEpoch)
            }
            guard let (target, epoch) = captured else { return }
            // Preserve the ordinary pointer's cursor/latency observations after scoped admission.
            // Native posting itself still validates the captured lease below, on the injector queue.
            switch event {
            case .hover(let x, let y):
                CursorOverlayState.shared.hover(x: x, y: y)
                cursorWatcher.noteHover()
            case .touch(let x, let y, let phase, _, let ts):
                CursorOverlayState.shared.touch(phase: phase, x: x, y: y)
                if let ts {
                    let at = Int(Date().timeIntervalSince1970 * 1000)
                    if let data = try? JSONSerialization.data(withJSONObject: ["t": "inputAck", "ts": ts, "injectedAtEpochMs": at]) {
                        peer.send(.control, wrapMessage(data))
                    }
                }
            default: break
            }
            target.submitScoped(event, postFence: { [weak self, weak peer, weak target] post in
                guard let self, let peer, let target else { return false }
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.ownershipEpoch == epoch, self.peers[peer.clientId] === peer,
                      self.active.isActive(peer.clientId), self.injector === target,
                      let owner = self.sourceOwnerLocked(),
                      self.sourceInputRoute.permits(owner: owner, source: source, lease: lease) else { return false }
                post(); return true
            })
        }
    }

    func receive(_ msg: InboundMessage, from p: ClientConnection) {
        // A WINDOW-LESS CLIENT'S window, picture and machine intents are refused HERE, before any
        // handler (`WindowlessPolicy`): it has no picture to act on, and a passive-style refusal per
        // handler would be one more place for a new message to forget.
        let permitted: Bool
        switch p.presentation {
        case .terminalOnly: permitted = WindowlessPolicy.permits(msg)
        case .nativeSimulators:
            permitted = NativeSimulatorPolicy.permits(msg, focusedSource: simDelegate?.focusedSourceID)
        case .streamedSources: permitted = true
        }
        guard permitted else {
            print("[channel] \(p.clientId) presentation refused \(Self.caseName(msg))")
            return
        }
        // Once a presentation opts into scoped input it cannot fall back to the shared injector.
        if SourceInputEvent(msg) != nil {
            let legacyInput = lock.withLock {
                peers[p.clientId] === p && sourceInputCapabilities[p.clientId] != ObjectIdentifier(p)
            }
            guard legacyInput else { return }
        }
        switch msg {
        case .agent(let command): handleAgent(command, from:p)
        case .sourceInput(let command): handleSourceInput(command, from: p)

        case .key(let s, let term): handleKey(s, term: term, clientId: p.clientId)
        case .termReply(let s, let term): handleTermReply(s, term: term, clientId: p.clientId)
        case .touch(let x, let y, let phase, let button, let ts):
            handleTouch(x: x, y: y, phase: phase, button: button, ts: ts, clientId: p.clientId, peer: p)
        case .scroll(let x, let y, let dx, let dy, let unit, let mods):
            handleScroll(x: x, y: y, dx: dx, dy: dy, unit: unit, mods: mods, clientId: p.clientId)
        case .scrollFling(let x, let y, let vx, let vy, let mods):
            handleScrollFling(x: x, y: y, vx: vx, vy: vy, mods: mods, clientId: p.clientId)
        case .scrollGesture(let x, let y, let phase, let vx, let vy, let mods):
            guard isActiveClient(p.clientId) else { return }
            lock.lock(); let target = injector; lock.unlock()
            target?.scrollGesture(normalizedX: x, normalizedY: y, phase: phase, velocityX: vx, velocityY: vy, mods: mods)
        case .winKey(let down, let code, let key, let isRepeat, let mods):
            handleWinKey(down: down, code: code, key: key, repeat: isRepeat, mods: mods, clientId: p.clientId)
        case .winKeysRelease:
            handleWinKeysRelease(clientId: p.clientId)
        case .hover(let x, let y): handleHover(x: x, y: y, clientId: p.clientId)
        case .simTouch(let phase, let points): handleSimTouch(phase: phase, points: points, clientId: p.clientId)
        case .simText(let text): handleSimText(text, clientId: p.clientId)
        case .simAction(let source, let action):
            if isActiveClient(p.clientId) {
                simDelegate?.simAction(sourceID: source, action: action, requestedBy: p.clientId)
            }
        case .claimControl(let grid): handleClaim(clientId: p.clientId, grid: grid)
        case .resize(let c, let r): handleResize(cols: c, rows: r, clientId: p.clientId)   // implemented in Task 6
        case .termWire: handleTermWire(clientId: p.clientId)
        // Tagged with the SENDING connection: the gate drops it unless that is still the driver's when
        // it is queued (a claim, or a rebuild, may land in between — TerminalPauseGate).
        case .terminalPause: if isActiveClient(p.clientId) { terminalPause.pause(from: ObjectIdentifier(p)) }
        case .terminalResume: if isActiveClient(p.clientId) { terminalPause.resume(from: ObjectIdentifier(p)) }
        case .termPalette(let palette): handleTermPalette(palette, clientId: p.clientId)
        case .listTerminals: handleListTerminals(clientId: p.clientId)
        case .openTerminal: handleOpenTerminal(clientId: p.clientId)
        case .reopenTerminal: handleReopenTerminal(clientId: p.clientId)
        case .closeTerminal(let id): handleCloseTerminal(id: id, clientId: p.clientId)
        case .switchTerminal(let id): handleSwitchTerminal(id: id, clientId: p.clientId)
        case .listTmux: sendTmuxList(to: p.clientId)
        case .openTmux(let s): handleOpenTmux(s, clientId: p.clientId)
        case .newTmux: handleNewTmux(clientId: p.clientId)
        case .killTmux(let s): if isActiveClient(p.clientId) { terminals.killTmux(s) }
        case .appsCapabilities(let enabled): simDelegate?.workspaceConnectionCapability(enabled,clientID:p.clientId,connectionID:ObjectIdentifier(p))
        case .appsList: simDelegate?.workspaceRequest(action:"list",app:nil,clientID:p.clientId)
        case .appsAdd(let app): if isActiveClient(p.clientId) {simDelegate?.workspaceRequest(action:"add",app:app,clientID:p.clientId)}
        case .appsRemove(let app): if isActiveClient(p.clientId) {simDelegate?.workspaceRequest(action:"remove",app:app,clientID:p.clientId)}
        case .appsRestoreAll: if isActiveClient(p.clientId) {simDelegate?.workspaceRequest(action:"restore-all",app:nil,clientID:p.clientId)}
        case .listSources: simDelegate?.listSources(forClient: p.clientId)
        case .requestThumbs: simDelegate?.requestThumbs(forClient: p.clientId)
        // THE CLIENT MEASURED THIS, NOT US — printed under the client id so it cannot be mistaken
        // for something the host observed. It is the only view of the RECEIVER's decode path, and it
        // rides the data channel because attaching a debugger by cable moves the media off the
        // network being measured.
        case let .receiverReport(line): print("[rx] \(p.clientId) \(line)")
        case .subscribe(let source, let delivery):
            // WHAT ARRIVED ON THE WIRE, before any host logic touches it — the one line that is neither
            // side's opinion about delivery.
            print("[channel] subscribe \(source) delivery=\(delivery.rawValue) from \(p.clientId)")
            // Recorded BEFORE the open, so `addVideo` sees it when it creates the track.
            setVideoDeliveryRequest(delivery, forSource: source)
            // OPENS A WINDOW IN THE SESSION (or un-minimizes it). The driver's track only if the window
            // now streams — a refused id must not leave a track that carries nothing. The peer is
            // negotiated (this arrived over its control channel), so the renegotiation is clean.
            if isActiveClient(p.clientId),
               simDelegate?.openWindow(sourceID: source, requestedBy: p.clientId) ?? false, let media = p.mediaPeer {
                addVideo(peer: media, sourceID: source)      // both codecs offered; the sink attaches on codec-resolved
            }
        case .unsubscribe(let source, let land):
            // CLOSES THE WINDOW: it leaves the session — landing the person on the bar's previous tab when
            // the client says they were at it.
            if isActiveClient(p.clientId) {
                if case .workspace?=parseSourceID(source) {} else {removeVideo(clientId:p.clientId,sourceID:source)}
                simDelegate?.closeWindow(sourceID: source, land: land, requestedBy: p.clientId)
            }
        case .setSourcePrefs(let source, let scale, let crop):
            // Only what the page DERIVES per window — its Auto ceiling and its crop. fps, bitrate and
            // codec are the driver's client-wide preferences (`client-hello`, `set-prefs`).
            if isActiveClient(p.clientId) {
                simDelegate?.setSourceView(sourceID: source, scale: scale, crop: crop, requestedBy: p.clientId)
            }
        case .clientHello(let prefs, let delivery, let capability): handleClientHello(prefs, delivery: delivery, capability: capability, peer: p)
        case .av1Reference(let message): handleReferenceReceipt(message, peer: p)
        case .setPrefs(let prefs): handleSetPrefs(prefs, clientId: p.clientId)
        case .reattachSource(let source): handleReattachSource(source, peer: p)
        case .minimizeWindow(let source, let land):
            // THE WINDOW STAYS IN THE SESSION, parked; its track and its stream go.
            if isActiveClient(p.clientId) {
                removeVideo(clientId: p.clientId, sourceID: source)
                simDelegate?.minimizeWindow(sourceID: source, land: land, requestedBy: p.clientId)
            }
        case .restoreWindow(let source):
            if isActiveClient(p.clientId),
               simDelegate?.restoreWindow(sourceID: source, requestedBy: p.clientId) ?? false, let media = p.mediaPeer {
                // Back over the DRIVER's transport (its hello), not whatever this window last used.
                if let delivery = helloDelivery(p.clientId) { setVideoDeliveryRequest(delivery, forSource: source) }
                addVideo(peer: media, sourceID: source)
            }
        case .setWindowPosition(let source, let x, let y):
            if isActiveClient(p.clientId) {
                simDelegate?.setWindowPosition(sourceID: source, x: x, y: y, requestedBy: p.clientId)
            }
        case .setView(let surface, let fullscreen):
            if isActiveClient(p.clientId) {
                simDelegate?.setView(surface: surface, fullscreen: fullscreen, requestedBy: p.clientId)
            }
        // THE BAR: driver-gated, and permitted to a window-less client (`WindowlessPolicy`).
        case .moveTab(let tab, let before):
            if isActiveClient(p.clientId) { handleMoveTab(tab, before: before) }
        case .renameTab(let tab, let name):
            if isActiveClient(p.clientId) { handleRenameTab(tab, name: name, clientId: p.clientId) }
        // A PASTE OR A DROP (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §7) — the driver's,
        // on its CURRENT connection; a window-less client's window paste was refused above. A passive
        // client's begin and end are answered `not-driver` (it is waiting on one); its data is dropped.
        case .pasteBegin(let b):
            switch pasteSender(p) {
            case .driver: paste?.begin(b, clientId: p.clientId)
            case .passive: sendBulk(pasteErrorJSON(id: b.id, reason: .notDriver), to: p.clientId)
            case .replaced: break
            }
        case .pasteData(let id, let item, let seq, let bytes):
            if pasteSender(p) == .driver { paste?.piece(id: id, item: item, seq: seq, bytes: bytes, clientId: p.clientId) }
        case .pasteEnd(let id):
            switch pasteSender(p) {
            case .driver: paste?.end(id: id, clientId: p.clientId)
            case .passive: sendBulk(pasteErrorJSON(id: id, reason: .notDriver), to: p.clientId)
            case .replaced: break
            }
        case .pasteCancel(let id):
            // Not gated on control: a cancel only ever ends the sender's OWN delivery, and one it lost with
            // control was already abandoned.
            if pasteSender(p) != .replaced { paste?.cancel(id: id, clientId: p.clientId) }
        // AN IMAGE PATH THE TERMINAL PRINTED (`FileFetch`): the DRIVER's, as the terminal is; a passive client is
        // told why it gets nothing. The answer goes to the connection that asked, in order.
        case .fileGet(let request):
            guard isActiveClient(p.clientId) else {
                p.send(.bulk, wrapMessage(FileFetch.errorJSON(id: request.id, reason: .notDriver)))
                return
            }
            fileFetcher.fetch(request, client: p.clientId,
                              send: { [weak p] data in p?.send(.bulk, wrapMessage(data)) },
                              buffered: { [weak p] in p?.bufferedAmount(.bulk) })
        case .setSourceAudio(let source, let enabled):
            // DRIVER-GATED like every other mutation, and the reply is the view-set
            // `setSourceAudio` broadcasts — every request gets one, including a refusal.
            if isActiveClient(p.clientId) {
                simDelegate?.setSourceAudio(sourceID: source, enabled: enabled, requestedBy: p.clientId)
            }
        case .setVisibility(let hidden):
            // The driver's CURRENT connection only: a report still draining from a connection a rebuild
            // retired would pause (or resume) the page's new lifetime, which states its own.
            if isActiveClient(p.clientId) && peerFor(p.clientId) === p { setVisibility(clientId: p.clientId, hidden: hidden) }
        case .curtain(let on):
            // DRIVER-GATED like every other mutation. `CurtainController.shared` is thread-safe and hops
            // to main itself, so there is no lock discipline to observe here — and it must NOT be called
            // under any hub lock, since it can block on the main queue.
            if isActiveClient(p.clientId) {
                print("[curtain] \(on ? "raise" : "lower") requested by \(p.clientId)")
                on ? CurtainController.shared.raise() : CurtainController.shared.lower()
                // ANNOUNCE FROM THE MAIN QUEUE, ORDERED AFTER THE TOGGLE ITSELF. `raise`/`lower` hop to
                // main asynchronously, so announcing inline reads `isUp` BEFORE the change applies and
                // every client's toggle ends up exactly one update behind — observed as a button still
                // reading "Raise" after the screen had gone black, catching up only on the NEXT toggle.
                // Same "accepted, not applied" trap as pion_peer_set_recovery_override.
                //
                // Main-queue FIFO is what makes this correct: this block is enqueued after the
                // controller's own, so `isUp` is settled by the time the view-set is built.
                DispatchQueue.main.async { [weak self] in self?.simDelegate?.announceCurtainChange() }
            }
        case .setRecovery(let bp):
            // KEPT FOR ITS CLAIM, from the client's current connection only (`applyConnectionSettings`).
            lock.withLock { if peers[p.clientId] === p { recoveryRequests[p.clientId] = .some(bp) } }
            if isActiveClient(p.clientId) {
                // SESSION-SCOPED, so it names no source and goes straight to the SENDER's media peer
                // (`p.mediaPeer`), like every other arm here that answers its sender (handleTouch) — a
                // window-less client has none, so this is silent for it (and `WindowlessPolicy` refused
                // the message before this switch anyway). An earlier version looked the peer up in
                // `peers[p.clientId]` instead and got nil, which the optional chain then swallowed: the
                // message arrived, the active check passed, and nothing happened, with no log line
                // anywhere to say so.
                p.mediaPeer?.setRecoveryOverride(bp)
                // SimManager records it so every later view-set echoes it. Absent on the headless
                // test-pattern path, which has no SimManager and no view-set to echo into.
                simDelegate?.setRecoveryOverride(bp: bp)
            }
        case .setPlayoutDelay(let minMs, let maxMs):
            lock.withLock { if peers[p.clientId] === p { playoutRequests[p.clientId] = (minMs, maxMs) } }
            if isActiveClient(p.clientId) {
                // SESSION-SCOPED, straight to the SENDER's media peer (`p.mediaPeer`), for the same
                // reason as .setRecovery directly above — silent for a window-less client, which has
                // none (and was refused earlier anyway) — and with the same trap avoided: looking `p`
                // up in `peers` returns nil and the optional chain swallows it silently.
                p.mediaPeer?.setPlayoutDelay(minMs: minMs, maxMs: maxMs)
                simDelegate?.setPlayoutDelay(minMs: minMs, maxMs: maxMs)
            }
        case .focusSource(let source):
            if isActiveClient(p.clientId) {
                simDelegate?.focusSource(sourceID: source, requestedBy: p.clientId)
            }
        case .setSourceSize(let source, let w, let h):
            if isActiveClient(p.clientId) {
                simDelegate?.setSourceSize(sourceID: source, w: w, h: h, requestedBy: p.clientId)
            }
        case .requestKeyframe(let source):
            // Straight to this peer's own tracks; the guard inside scopes it to what this client is
            // actually receiving, which is also what makes it harmless from a passive client.
            requestKeyframe(clientId: p.clientId, sourceID: source)
        }
    }
}

extension ChannelHub: PionPeerDelegate {
    public func pionPeer(_ p: PionPeer, didOpen ch: PionChannel) { connection(p, didOpen: ch) }
    public func pionPeer(_ p: PionPeer, didReceive data: Data, on ch: PionChannel) { connection(p, didReceive: data, on: ch) }
    public func pionPeer(_ p: PionPeer, stateDidChange state: Int32) {
        // Client teardown is signaling-driven (the `peerLeft` event → PeerHub.clientLeft → close),
        // not connection-state-driven — this logs the pion PeerConnection state for diagnostics.
        print("[channel] \(p.clientId) state=\(state)")
        if state == 3 {   // 3 == PeerConnectionStateConnected
            // On (re)connect — including after an ICE restart (Task 15) — force an IDR so the
            // decoder recovers cleanly. pion also fires an on-connect IDR internally (peer.go:116),
            // but that path may not re-fire on a pure ICE restart if the peer-connection-state never
            // left Connected; this explicit request is idempotent and covers it.
            if isActiveClient(p.clientId) {
                // An ICE restart back to Connected (a rebuilt or fresh driver is reconciled by its own
                // hello instead): re-establish the tracks, gated on this connection's hello like every
                // other path. Idempotent — a no-op once a track exists.
                if lock.withLock({ peers[p.clientId] is FastClientConnection }) { reconcileDriver(p.clientId) }
                establishVideoIfActive(clientId: p.clientId)              // (re)adds tracks — addSink already forces an IDR
                requestKeyframe(clientId: p.clientId, slot: -1)           // belt-and-suspenders for an ICE-restart reconnect
                                                                          // where tracks already exist (addVideo no-ops)
            }
        }
        // MEDIA release IS connection-state-driven, while TEARDOWN remains signalling-driven — the
        // two answer different questions, so this is not a reversal of the rule at the top of this
        // method.
        //
        // Suspension is the wrong signal for media: a suspended client's peer connection is often
        // perfectly alive (that is exactly what PeerHub.resume's `.restartICE` path relies on), so
        // releasing on suspend would break a working stream whose signalling merely blipped. What
        // matters here is whether the connection is actually gone.
        //
        // The client is NOT torn down: it stays registered, keeps its active-control status, and
        // keeps its terminal. Only its media is released.
        // See docs/superpowers/specs/2026-08-21-suspended-client-media-release-design.md
        if shouldReleaseMedia(state: state, hasVideoSlots: hasVideoSlots(clientId: p.clientId)) {
            releaseMedia(clientId: p.clientId, state: state)
        }
    }
}
