import Foundation
import ApplicationServices
import CoreGraphics
import RdevCore

/// What the host can actually capture. Deliberately NOT the same type as `RdevCore.ParsedSourceID`:
/// this is the HOST's, and a simulator here is captured from its own framebuffer and driven through its
/// own HID (docs/superpowers/specs/2026-10-13-simulator-sources-design.md).
///
/// THE SAME ENUM DRIVES CAPTURE AND INPUT (`ScreenCaptureSource`, `WindowInputInjector`), so there is
/// one spelling of "which subject" inside the host and exactly one mapping from the wire — the place a
/// win:/dsp: mix-up would otherwise hide.
public enum SourceTarget: Equatable, Sendable {
    case window(Int)         // CGWindowID as Int
    case display(Int)        // CGDirectDisplayID as Int
    case workspace(Int)      // session-owned virtual display; wire identity remains apps:<uuid>
    case simulator(String)   // CoreSimulator udid (uppercase UUID)
}

/// Inbound control-channel hooks the ChannelHub forwards to (set as `channelHub.simDelegate`).
public protocol SimControlDelegate: AnyObject {
    var focusedSourceID: String? { get }
    func workspaceCapability(_ enabled:Bool,clientID:String)
    func workspaceConnectionCapability(_ enabled:Bool,clientID:String,connectionID:ObjectIdentifier)
    func workspaceRequest(action:String,app:String?,clientID:String)
    func reconcileNative()
    // Unified source-subscription protocol (Phase 3b → Milestone B cap-N). `sourceID` is "sim:<udid>" / "win:<cgWindowID>".
    func listSources(forClient clientId: String)
    /// Capture a one-shot snapshot per source (windows + booted sims) and stream a `source-thumb` per source
    /// to `clientId` as each completes. Ungated read-only info, like `listSources`.
    func requestThumbs(forClient clientId: String)
    // THE SESSION (docs/superpowers/specs/2026-09-29-host-session-state-design.md). Every one of these
    // is a DRIVER's intent — ChannelHub gates them — and changes the host's session state, which
    // outlives every client for as long as the host runs; the streams are reconciled against it.

    /// Open a window in the session (or un-minimize and focus one already in it) and stream it.
    /// Returns whether it is now streamed — false for an unparseable id, the removed `sim:` form, or
    /// one of the host's OWN windows — so the caller adds the driver's track only on success.
    func openWindow(sourceID: String, requestedBy clientId: String) -> Bool
    /// The window leaves the session; its stream stops. `land`: the client says the person was AT it, so
    /// they land on the bar's previous tab (`SessionState.landing`) — a terminal tab too.
    func closeWindow(sourceID: String, land: Bool, requestedBy clientId: String)
    /// The window STAYS in the session, minimized; its stream stops (focus falls back). `land` as above.
    func minimizeWindow(sourceID: String, land: Bool, requestedBy clientId: String)
    /// Un-minimize and focus; true iff it is now streamed (the caller then adds the driver's track).
    func restoreWindow(sourceID: String, requestedBy clientId: String) -> Bool
    /// Where the window sits on the desktop layout — client stage px, carried for whoever connects next.
    func setWindowPosition(sourceID: String, x: Double, y: Double, requestedBy clientId: String)
    /// Which surface a pinned layout shows, and which window (if any) is full screen. `.some(nil)` clears.
    func setView(surface: SessionSurface?, fullscreen: String??, requestedBy clientId: String)
    /// Move a tab of the session's BAR — terminal or window, by key — to just before `before`, or to the
    /// end when nil (`SessionState.moveTab`). Returns the NEW ORDER when it changed, nil otherwise: the
    /// caller arranges the terminal pool from it when the moved tab is a terminal.
    func moveTab(_ tab: String, before: String?) -> [String]?
    func agentTab(action: String, thread: String, title: String, cwd: String)
    func agentStatus(thread: String, status: String?, activeFlags: [String])
    /// A window's user name; `""` clears it (`SessionState.setName`).
    func renameWindow(sourceID: String, name: String, requestedBy clientId: String)
    /// The terminal pool's tabs, in pool order, by wire id: the bar's terminal half follows them
    /// (`SessionState.syncTerminals`). NOT a driver's intent — the hub calls it on every tab-set change,
    /// a title's included, and only a change of the SET broadcasts a `view-set`.
    func syncTerminalTabs(_ ids: [String])
    /// A driver was established (its `client-hello` arrived) or changed its preferences: resolve every
    /// stream against `driverPrefs`, build the streams the state wants and lacks, and cancel a pending
    /// teardown. The caller then adds a track for each of `subscribedSourceIDs()`.
    func reconcile(driverPrefs: ClientPrefs)
    /// The per-window values the driver's page DERIVES: its Auto resolution ceiling and its crop.
    func setSourceView(sourceID: String, scale: Double?, crop: CropRect?, requestedBy clientId: String)
    /// The session ENDS (a quit): every stream stops now and the session is forgotten. Stop Sharing does
    /// not end it (`stopStreamsKeepingSession`).
    func endSession()
    /// Apply one adaptive-FlexFEC controller decision across every subscribed source, returning
    /// whether it was applied. See `SimManager.applyRecoveryPolicy`.
    @discardableResult
    func applyRecoveryPolicy(mediaBitrateBps: UInt32, budgetBps: UInt32) -> Bool
    /// The bridge resolved this source's track codec from the answer: build (or rebuild) the source's encoder in
    /// that codec and wire capture->encoder if the source has booted. Called from `ChannelHub.codecResolved`.
    func ensureEncoder(sourceID: String, codec: NegotiatedCodec)
    /// Forget every window's crop AND Auto resolution ceiling: both are what the VIEWER's page derived
    /// from its own boxes, so a change of video consumer drops them and the incoming one re-derives them.
    func resetViewerDerived()
    /// The codec the client asked for on `sourceID` (`.auto` when unknown). ChannelHub reads this when it
    /// creates a delivery track, so a pinned window is offered its preference from the start.
    func codecPrefForSource(_ sourceID: String) -> CodecPref
    /// Record the session's forced FEC overhead (basis points, nil = adaptive) and re-broadcast the
    /// view set. SESSION-SCOPED, so it names no source.
    func setRecoveryOverride(bp: Int?)
    func setPlayoutDelay(minMs: Int?, maxMs: Int?)
    func focusSource(sourceID: String, requestedBy clientId: String)
    /// A scoped native activation, including returning to the terminal without removing a source.
    func sourceInputFocus(source: String?, request: String, requestedBy clientId: String) -> Bool
    /// The window a paste or drop goes to (§4.2): FOCUSED first, as `focus-source` would, and its stream's
    /// injector returned; nil unless it is open (not minimized) and has an injector.
    func pasteTarget(sourceID: String) -> InputInjector?

    /// Start or stop sending one source's audio to ONE client. Drops or attaches that client's audio
    /// sink; the track stays negotiated, so this costs no renegotiation, no SSRC change and no IDR.
    func setSourceAudio(sourceID: String, enabled: Bool, requestedBy clientId: String)
    /// Resize the real window behind `sourceID` (POINTS), best-effort. No reply — the size poll's
    /// `source-status` push is the answer, so a clamped or refused resize simply snaps back.
    func setSourceSize(sourceID: String, w: Int, h: Int, requestedBy clientId: String)
    /// A driver's intent on a simulator (`sim-action`): a button, shake, a rotation, boot or shutdown.
    func simAction(sourceID: String, action: SimAction, requestedBy clientId: String)
    /// Re-broadcast the view set after the host curtain changed, so every client's toggle reflects it
    /// at once. Raising/lowering is ChannelHub's, which owns the CurtainController call.
    func announceCurtainChange()
    func sendViewSet(toClient clientId: String)
    /// What an OFFER carries of the session's windows (`ChannelHub.offerState`): the state's `view-set` with no live
    /// echo, and the names the last listing gave its windows. Called on pion's dispatcher — it reads nothing but this
    /// manager's own state.
    func offerStatePayloads() -> [Data]
    /// Push per-window liveness to one client (control-open / claim), mirroring `sendViewSet`.
    func sendSourceStatus(toClient clientId: String)
    /// The currently-subscribed source ids (cap-N ⇒ 0..N). ChannelHub reads this to know which
    /// source(s) to bind a delivery track to for the active client.
    func subscribedSourceIDs() -> [String]
    /// The per-source encoder feeding `sourceID`'s track (cap-N: one encoder per subscribed source). ChannelHub
    /// attaches/removes each `TrackSink` on it and routes that source's keyframe requests to it. nil if unknown.
    func encoderForSource(_ id: String) -> VideoEncoding?

    /// This source's Opus encoder, or nil when it has none. Built at SUBSCRIBE rather than lazily:
    /// Opus is the only audio codec, so there is no codec-resolved round trip to wait for.
    func audioEncoderForSource(_ id: String) -> AudioEncoding?
    /// The client's tab was backgrounded (or came back). Re-rates every subscribed source; see
    /// `SimManager.setHidden`.
    func setHidden(_ hidden: Bool)
    /// Re-run the audio ownership election and attach/detach each client's audio sinks (sink-level,
    /// never a renegotiation). The hidden-tab resume calls it: the pause dropped the audio sinks.
    func reconcileAudio()
    /// Nobody is driving any more — the driver left with nobody taking over, or its connection
    /// failed. Keep every stream for the grace window (a cheap return reuses them), then stop them.
    /// THE SESSION STATE IS KEPT either way. See `onClientBack`.
    func onClientGone()
    /// A driver exists again: cancel the pending teardown. Safe with no timer armed (a no-op).
    func onClientBack()
}

extension SimControlDelegate {
    public func agentStatus(thread: String, status: String?, activeFlags: [String]) {}
    public func agentTab(action: String, thread: String, title: String, cwd: String) {
        guard ProductFeatures.graphicalAgents else { return }}
    public var focusedSourceID: String? { nil }
    public func reconcileNative() {}
    public func sourceInputFocus(source: String?, request: String, requestedBy clientId: String) -> Bool { false }
}

/// Owns the live source streams (cap-N: one `SourceStream` per subscribed source, each with its OWN encoder +
/// capture + optional injector) and orchestrates their lifecycle. Concurrency model:
///  - `list-sources` is answered immediately on its own Task — never blocked by a boot.
///  - `subscribe` creates the `SourceStream` (with a fresh encoder from the factory) SYNCHRONOUSLY under `lock`
///    so ChannelHub's `addVideo` finds the encoder immediately; the capture source + injector are filled in
///    AFTER the sim boots by `buildAndAttach`/`attach`, on a per-request Task (boots run concurrently, off the
///    critical section). Per-source serialization is an IDENTITY check (`streams[id] === stream`) at boot-commit:
///    an unsubscribe-then-resubscribe of the same source replaces the stream object, so a superseded boot commits
///    into nothing and tears down what it built (latest-wins per source; replaces Milestone A's global swap barrier).
///  - `focus-source` governs input routing (the focused source's injector receives input) AND video rate (focused
///    → full prefs; unfocused → the throttle profile).
/// @unchecked Sendable: `streams` + `session` + `driverPrefs` + `autoScales` + `crops` + every `SourceStream` mutable field are guarded by `lock`; encoder/
/// source/injector/channelHub calls happen OUTSIDE `lock` on snapshotted refs (`lock` is never held across one).
public final class SimManager: SimControlDelegate, @unchecked Sendable {

    /// AX can block. All source raises/commits, including late capture attachment, use ONE lane.
    private let focusQueue = DispatchQueue(label: "rdev.sources.focus", qos: .userInteractive)
    private var focusRoutingGeneration: UInt64 = 0 // under lock; invalidates already queued raises
    private var hasFocusRoutingPlan = false
    private var routedSource: String?
    private var routedInjector: ObjectIdentifier?
    private var scopedTerminalInput = false
    private var hasInputOwnerEpoch = false
    private var inputOwnerEpoch: UInt64?
    private let makeEncoder: (String, Int, Int, NegotiatedCodec) -> VideoEncoding
    private weak var channelHub: ChannelHub?
    private let workspace=AppWorkspaceCoordinator()
    private var workspaceCapabilities:[String:WorkspaceConnectionCapability]=[:]
    private var streamReconcileGeneration: UInt64 = 0
    private let defaultPrefs: VideoPrefs    // base for a NEW subscription's prefs (immutable)
    /// Slope of the resolution-derived starting bitrate. Read ONCE — it is a process-wide default,
    /// not a per-source pref, and re-reading the environment per subscribe would let it drift
    /// mid-session. Refuses an out-of-range value rather than clamping, like the RDEV_LIBAOM_* five.
    private static let bitsPerPixel: Double = {
        guard let raw = ProcessInfo.processInfo.environment["RDEV_VIDEO_BITS_PER_PIXEL"],
              let value = Double(raw) else { return defaultBitsPerPixel }
        guard value > 0, value <= 1 else {
            print("[sources] RDEV_VIDEO_BITS_PER_PIXEL=\(raw) is not in (0, 1] — using \(defaultBitsPerPixel)")
            return defaultBitsPerPixel
        }
        return value
    }()
    /// The session's STATE — every window open in it (minimized or not, with its position), the focus
    /// and the view (docs/superpowers/specs/2026-09-29-host-session-state-design.md). Changed only by
    /// the DRIVER's intents, and it outlives every client for as long as this host runs. `streams` are
    /// the MACHINERY reconciled against it: one for every streamed window while a driver is reconciled
    /// (`driving`), none once the grace teardown has run. Guarded by `lock`.
    private var session = SessionState()
    private var nativeEpoch: UInt64?
    private var presentation: ClientPresentation = .streamedSources
    private var nativeFrames: [String: [UUID: (SimulatorSurfaceFrame?) -> Void]] = [:]
    var localSimulatorState: (SessionState, [SimInfo]) { lock.withLock { (session, Array(simInfos.values)) } }

    func observeNativeFrames(source: String, receive: @escaping (SimulatorSurfaceFrame?) -> Void) -> LocalSimulatorObservation {
        let token = UUID()
        let capture: SimulatorCaptureSource? = lock.withLock {
            nativeFrames[source, default: [:]][token] = receive
            return streams[source]?.source as? SimulatorCaptureSource
        }
        // A late observer gets the current static frame too.
        if let capture { startNative(capture, source: source) }
        return LocalSimulatorObservation { [weak self] in self?.lock.withLock { self?.nativeFrames[source]?[token] = nil } }
    }

    private func startNative(_ capture: SimulatorCaptureSource, source: String) {
        guard lock.withLock({ presentation == .nativeSimulators && streams[source]?.source === capture }) else { return }
        capture.framebuffer.start { [weak self, weak capture] frame in
            guard let self, let capture else { return }
            let callbacks: [(SimulatorSurfaceFrame?) -> Void] = self.lock.withLock {
                guard self.presentation == .nativeSimulators, self.streams[source]?.source === capture else { return [] }
                return Array(self.nativeFrames[source]?.values ?? [:].values)
            }
            for callback in callbacks { callback(frame) }
        }
    }

    private func switchPresentation(_ value: ClientPresentation) {
        let epoch = value == .nativeSimulators ? channelHub?.currentDriverEpoch() : nil
        let dead: [SourceStream] = lock.withLock {
            guard presentation != value || nativeEpoch != epoch else { return [] }
            presentation = value; nativeEpoch = epoch
            let all = Array(streams.values); streams.removeAll()
            return all
        }
        for stream in dead { stream.injector?.releaseKeys(); stream.stop(); stream.encoder?.invalidate() }
    }

    public func reconcileNative() {
        switchPresentation(.nativeSimulators)
        lock.withLock { graceTimer?.cancel(); graceTimer = nil; driving = true }
        syncStreams()
        refreshInputOwner()
        broadcastViewSet()
    }

    public func restoreWorkspace(forQuit:Bool=false,completion:@escaping @Sendable(String?)->Void) {
        let previous=workspace.snapshot().source
        workspace.request(forQuit ? "quit" : "restore-all",app:nil) { [weak self] snapshot in
            guard let self else{completion("Host session ended");return}
            self.channelHub?.broadcastControl(snapshot.wire())
            if snapshot.members.isEmpty,let previous {self.closeWindow(sourceID:previous,requestedBy:"")}
            completion(snapshot.error)
        }
    }
    public func workspaceCapability(_ enabled:Bool,clientID:String) {
        if let driver=channelHub?.currentDriver(), driver.clientId==clientID {
            workspaceConnectionCapability(enabled,clientID:clientID,connectionID:ObjectIdentifier(driver))
        } else if !enabled {
            lock.withLock {workspaceCapabilities.removeValue(forKey:clientID)}
            syncStreams();channelHub?.reconcileWorkspaceMedia();broadcastViewSet()
        }
    }
    public func workspaceConnectionCapability(_ enabled:Bool,clientID:String,connectionID:ObjectIdentifier) {
        guard let peer=channelHub?.currentConnection(clientID:clientID,expectedOID:connectionID) else{return}
        lock.withLock {
            if enabled {workspaceCapabilities[clientID]=WorkspaceConnectionCapability(peer)}
            else if workspaceCapabilities[clientID]?.matches(peer)==true {workspaceCapabilities.removeValue(forKey:clientID)}
        }
        syncStreams();channelHub?.reconcileWorkspaceMedia();broadcastViewSet()
    }
    public func workspaceRequest(action:String,app:String?,clientID:String) {
        let requestDriver=channelHub?.currentDriver()
        let requestCapable=lock.withLock {requestDriver.map {$0.clientId==clientID && workspaceCapabilities[clientID]?.matches($0)==true} ?? false}
        if action=="add",!requestCapable {var s=workspace.snapshot();s.error="Apps requires experimental desktop Chromium support";channelHub?.sendControl(s.wire(),to:clientID);return}
        let previous=workspace.snapshot().source
        workspace.request(action,app:app) { [weak self] snapshot in
            guard let self else{return}
            self.channelHub?.broadcastControl(snapshot.wire())
            if let source=snapshot.source {
                self.lock.withLock {self.listedSources[source]=Source(id:source,kind:"application-workspace",name:"Apps",inputCapable:true,running:true,w:1280,h:800)}
                let named=self.lock.withLock {Array(self.listedSources.values)}
                self.channelHub?.broadcastControl(sourceListJSON(sources:named))
                if action=="add",snapshot.error==nil {_=self.openWindow(sourceID:source,requestedBy:clientID);self.channelHub?.reconcileWorkspaceMedia()}
            } else if let previous {self.closeWindow(sourceID:previous,requestedBy:clientID)}
        }
    }

    public var focusedSourceID: String? { lock.withLock { session.focused } }
    /// Every source the LAST listing named (`listSources`), by id: what an offer labels the session's window tabs
    /// with (`offerStatePayloads`) before the client's own listing lands — the host enumerates only when asked, and a
    /// window in the session was picked from a listing this run, so its entry is here. Guarded by `lock`.
    private var listedSources: [String: Source] = [:]
    /// A driver has been reconciled (or asked for a window) and the grace teardown has not run since —
    /// the only condition under which a stream may be BUILT. A layout intent or a listing arriving with
    /// nobody driving must not resurrect capture. Guarded by `lock`.
    private var driving = false
    /// The DRIVER's client-wide preferences — fps, resolution, bitrate, codec — from its `client-hello`
    /// or `set-prefs`, via `reconcile`. Every stream's prefs resolve against these (`resolvedPrefsLocked`);
    /// another driver's take over when it does. Guarded by `lock`.
    private var driverPrefs = ClientPrefs.default
    /// Per window, the Auto resolution ceiling the driver's page derived for it (`set-source-prefs`
    /// `scale`) — used while the driver's resolution preference is `auto`. Kept while ONE driver drives
    /// (across a minimize, a reconcile, a stream's teardown); a change of driver forgets it
    /// (`resetViewerDerived`), and so does the window leaving the state. Guarded by `lock`.
    private var autoScales: [String: Double] = [:]
    /// Per window, the driver's crop (`set-source-prefs` `crop`) — a MASK chosen by whoever is
    /// watching, forgotten with the Auto ceiling (`resetViewerDerived`). Guarded by `lock`.
    private var crops: [String: CropRect] = [:]
    private let bitrateCap: Int
    private let throttleFps: Int
    private let throttleBitrateBps: Int

    private let lock = NSLock()
    private var streams: [String: SourceStream] = [:]   // sourceID -> live stream; guarded by `lock`

    /// The adaptive FlexFEC controller's latest media fraction; guarded by `lock`.
    ///
    /// 1.0 UNTIL THE CONTROLLER SAYS OTHERWISE, so every bitrate path below is byte-identical to
    /// what shipped until an update actually arrives — and it never arrives at all while recovery
    /// is `nack-rtx`, which is still the default.
    ///
    /// KNOWN LIMITATION, N>1: the controller is per SESSION and the encoder is per SOURCE, shared
    /// by every client watching that source. Two clients on different networks would each push a
    /// ratio and the last writer would win, so the two would fight over one encoder. Increment 2
    /// scoped the browser path to N=1 deliberately; this is the same shape as the documented
    /// "one encoder per source ⇒ one codec per source, for every viewer" limitation that
    /// `ensureEncoder` already has, and it wants the same fix (a per-client encoder, or a
    /// host-side reconciliation across sessions) rather than a local patch here.
    private var fecMediaRatio: Double = 1.0
    /// The operator-forced FEC overhead in basis points, or nil for adaptive control. SESSION-SCOPED:
    /// one value for the whole connection, echoed once in every `view-set` so every window's titlebar
    /// renders the same number and they all change together. It is recorded here rather than in
    /// ChannelHub only because this is where the view-set is built; ChannelHub owns applying it to the
    /// peer, which is where the peers are.
    private var recoveryOverrideBp: Int?
    /// The session's playout-delay floor in milliseconds; nil is Auto. Guarded by `lock`, like the
    /// recovery override beside it, and echoed into every `view-set`.
    private var playoutDelayMinMs: Int? = defaultPlayoutDelayMinMs
    /// The explicit ceiling the session's client asked for, or nil for the configured one.
    private var playoutDelayMaxMs: Int?

    // Grace-pool (Task 8): when the (single) client leaves for real, sources persist for a short window
    // (cheap reconnect reuses the live capturer+encoder) instead of leaking forever or tearing down
    // immediately. `graceTimer` is guarded by `lock`, same as `streams`/`session`.
    private var graceTimer: DispatchSourceTimer?
    /// `RDEV_SOURCE_GRACE_S`, 10 s by default; tests pass their own.
    private let graceSeconds: Int
    /// Whether the (single) client's tab is backgrounded. Guarded by `lock`.
    ///
    /// PER CLIENT, while prefs and encoders are PER SOURCE — so with two clients on one source the
    /// last writer wins. Same shape as the recorded "one encoder per source ⇒ one codec per source"
    /// limit, and moot at N=1, which is what the browser path is scoped to.
    private var hidden = false

    // Window liveness (spec 1 of the yabai-metadata arc): polls each subscribed window's on-screen state and
    // broadcasts `source-status` on change. Owns its own queue; started/stopped by `refreshLivenessWatch`.
    private let liveness = WindowLivenessMonitor()
    /// A WINDOW TAB'S BELL (docs/window-capture-and-input.md, "A window's bell"): the Dock's badges, read
    /// while a driver is reconciled and the session holds a `win:` window (minimized ones too — a parked tab
    /// carries the mark), and a rise sent to the driver as a `window-bell`. Started/stopped by
    /// `refreshBellWatch`. Tests replace it BEFORE use (a long interval, a fake Dock).
    var dockBadges = DockBadgeWatch() { didSet { wireDockBadges() } }
    /// Where the watch's targets are worked out — OFF the broadcasting thread (review F5: `announceCurtainChange`
    /// broadcasts on the app's MAIN thread) and in order, so the watch is always given the LAST state's windows.
    private let bellQueue = DispatchQueue(label: "rdev.dock.badges.targets")
    /// The windows the watch was last given, as a SET (nil: never) — a tab drag reorders `windows` and changes
    /// nothing here. Confined to `bellQueue`.
    private var bellKey: Set<String>?
    /// Owner pids for many windows in ONE window-server copy (`WindowAX.ownerPIDs`), for the bell watch's
    /// windows that have no stream to ask (`SourceStream.ownerPID`). Tests supply their own. Set before use.
    var windowOwnerPIDs: (Set<CGWindowID>) -> [CGWindowID: pid_t] = { WindowAX.ownerPIDs($0) }
    /// Tests: build no capture for a new stream (`buildAndAttach` needs ScreenCaptureKit and a real
    /// window). Everything else about a stream — its prefs, its place in `streams` — is the product's.
    /// Set before use; not guarded.
    var attachesCaptureForTests = true
    var workspaceDisplayForTests: ((String) -> UInt32?)?
    var beforeStreamInstallForTests: (() -> Void)?
    /// The pid owning a window, for the own-window refusal and the audio election. `WindowAX.ownerPID`
    /// uses `.optionAll`, the documented invariant; tests supply their own, because a made-up window id
    /// has no owner and an unknown owner FAILS CLOSED. Set before use; not guarded.
    var windowOwnerPID: (CGWindowID) -> Int32? = { WindowAX.ownerPID($0) }
    /// Every window id the window server still has — what `retainListed` asks before dropping a window
    /// a listing lacks. Tests supply their own: a made-up id exists only where a test says so. Set
    /// before use; not guarded.
    var existingWindowIDs: () -> Set<CGWindowID> = { WindowAX.allWindowIDs() }
    /// The simulators (docs/superpowers/specs/2026-10-13-simulator-sources-design.md); nil where there is nothing to
    /// see — the headless harness and the tests that do not ask.
    private let simulators: SimulatorDevices?
    /// `devicectl` — rotate, shake, display info, the pasteboard. Tests replace its runner. Set before use.
    var simulatorControl = SimulatorControl.live
    /// How long after a listing that lacks a simulator the absence is confirmed by another. Tests shorten it.
    var deletionConfirmDelay: TimeInterval = 2
    /// The last listing's simulators, by udid: a new stream's native size, and what `source-status` says of a
    /// simulator's state. Guarded by `lock`.
    private var simInfos: [String: SimInfo] = [:]
    /// Whether a STREAMED simulator's framebuffer is up (its capture's `onLiveChange`), by source id. A booted device
    /// shows nothing for ~20 s after its state reads booted, so `live` waits for the picture. Guarded by `lock`.
    private var simLive: [String: Bool] = [:]
    /// Whether the catalog is being watched. Guarded by `lock`.
    private var watchingSimulators = false

    public init(makeEncoder: @escaping (String, Int, Int, NegotiatedCodec) -> VideoEncoding, channelHub: ChannelHub,
                defaultPrefs: VideoPrefs, bitrateCap: Int, throttleFps: Int, throttleBitrateBps: Int,
                graceSeconds: Int? = nil, simulators: SimulatorDevices? = nil) {
        self.makeEncoder = makeEncoder; self.channelHub = channelHub
        self.simulators = simulators
        self.defaultPrefs = defaultPrefs; self.bitrateCap = bitrateCap
        self.throttleFps = throttleFps; self.throttleBitrateBps = throttleBitrateBps
        self.graceSeconds = graceSeconds
            ?? Int(ProcessInfo.processInfo.environment["RDEV_SOURCE_GRACE_S"] ?? "") ?? 10
        // Map the monitor's snapshot to source-status and broadcast to all control peers on change. The two
        // kinds are read from SEPARATE maps and given their own id builders — the numeric spaces overlap.
        workspace.onStateChanged = { [weak self] snapshot in self?.channelHub?.broadcastControl(snapshot.wire()) }
        wireDockBadges()
        liveness.onChange = { [weak self] live in
            guard let self else { return }
            // On the MONITOR's queue: the cached simulator half, never `lock` (see `simStatusCache`).
            let sims = self.simStatusLock.withLock { self.simStatusCache }
            self.broadcastStatuses(Self.windowStatuses(live) + sims)
        }
        observeSimulators()
    }

    // MARK: - SimControlDelegate: unified source subscriptions (Milestone B, cap-N)

    /// Enumerate windows into the unified source list. Immediate + concurrent: a pure read + send, never
    /// queued behind a boot.
    ///
    /// SIMULATORS ARE LISTED BESIDE WINDOWS through `listSimulators`, which holds its own deadline so a wedged
    /// CoreSimulatorService never holds the windows up (docs/superpowers/specs/2026-10-13-simulator-sources-design.md).
    public func listSources(forClient clientId: String) {
        Task { [weak self] in
            guard let self else { return }
            // TIMED AND COUNTED, deliberately. A client that never receives `source-list` and one that
            // receives a list with too few windows are the SAME symptom from the outside ("the host
            // lists no windows") and have completely different causes — a wedged AX sweep, a slow first
            // SCShareableContent call, or genuinely nothing to list. Without this line the only way to
            // tell them apart is a bisect; with it, one failing run says which.
            let t0 = DispatchTime.now().uptimeNanoseconds
            if self.channelHub?.presentation(for: clientId) == .nativeSimulators {
                let sims = await self.listSimulators() ?? []
                self.rememberSimulators(sims)
                let sources = makeSources(sims: sims, windows: [])
                self.lock.withLock { for source in sources { self.listedSources[source.id] = source } }
                self.channelHub?.sendControl(sourceListJSON(sources: sources), to: clientId)
                return
            }
            async let simsTask = self.listSimulators()
            let (wins, authorized) = await ScreenCaptureSource.listWindows()
            let displays = await ScreenCaptureSource.listDisplays()
            let sims = await simsTask ?? []
            self.rememberSimulators(sims)
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000.0
            // `display=` is the whole diagnosis on one line. A host with a sleeping display lists its
            // windows perfectly and returns NO displays and NO thumbnails — indistinguishable from a
            // client-side fault without this, and that once cost twelve hours on a deployed host.
            let display = ScreenCaptureSource.displayStatus()
            print(String(format: "[sources] listed %d windows (%d running), %d simulators in %.0fms authorized=%@ display=%@%@",
                         wins.count, wins.filter { !$0.minimized }.count, sims.count, ms,
                         authorized ? "yes" : "NO",
                         display.availability.rawValue,
                         display.locked == true ? " LOCKED" : ""))
            var sources = makeSources(sims: sims, displays: displays, windows: wins)
            if let id=self.workspace.snapshot().source {sources.append(Source(id:id,kind:"application-workspace",name:"Apps",inputCapable:true,running:true,w:1280,h:800))}
            self.rememberListing(sources)
            // THE LISTING IS ALSO HOW THE SESSION LEARNS A WINDOW IS GONE — its app quit or it was
            // closed, minimized or not. Nothing else enumerates: the liveness poll watches only
            // streamed windows. Only an AUTHORIZED listing, which is the only one that means anything.
            self.applyListing(sourceIDs: Set(sources.map(\.id)), authorized: authorized)
            self.channelHub?.sendControl(sourceListJSON(sources: sources, display: display), to: clientId)
            if !authorized {
                self.channelHub?.sendControl(
                    simStatusJSON(udid: "", phase: "error", message: "Screen Recording permission needed"),
                    to: clientId)
            }
        }
    }

    /// Enumerate the same sources as `listSources` (windows, displays and simulators), then capture +
    /// stream one `source-thumb` per source.
    /// LOAD-BEARING: enumeration + capture run on this detached Task (never under `lock`); the only host call
    /// is `channelHub?.sendBulk(_:to:)` from the thumbnailer's `send` closure.
    /// ON `bulk`, NOT `control`: a thumbnail is a 20–35 KB JPEG in base64, up to ~1 MB a palette open, and on the
    /// lane control packs before the terminal — each one held ~30 symbols ahead of every terminal byte, ~2.5 s at
    /// 100 kbit/s (docs/superpowers/specs/2026-10-12-terminal-lane-design.md, Decision 2). The page reads it by
    /// content on either channel and keys it by source id, so it needs no order against `source-list`.
    public func requestThumbs(forClient clientId: String) {
        Task { [weak self] in
            guard let self else { return }
            if self.channelHub?.presentation(for: clientId) == .nativeSimulators {
                let sims = await self.listSimulators() ?? []
                self.rememberSimulators(sims)
                await SourceThumbnailer.run(sources: makeSources(sims: sims, windows: [])) { [weak self] payload in
                    self?.channelHub?.sendBulk(payload, to: clientId)
                }
                return
            }
            async let simsTask = self.listSimulators()
            let (wins, _) = await ScreenCaptureSource.listWindows()
            let displays = await ScreenCaptureSource.listDisplays()
            let sims = await simsTask ?? []
            self.rememberSimulators(sims)
            let sources = makeSources(sims: sims, displays: displays, windows: wins)
            await SourceThumbnailer.run(sources: sources) { [weak self] payload in
                self?.channelHub?.sendBulk(payload, to: clientId)
            }
        }
    }

    /// The simulators for a listing — nil when CoreSimulator did not answer in time. HOLDS ITS OWN 2.5 s DEADLINE over
    /// the catalog's 2 s one, so nothing a catalog does can hold the WINDOWS of a listing up.
    func listSimulators() async -> [SimInfo]? {
        guard let simulators else { return [] }
        return await withCheckedContinuation { (cont: CheckedContinuation<[SimInfo]?, Never>) in
            let once = OnceFlag()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = simulators.list(deadline: 2)
                if once.claim() { cont.resume(returning: r) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    private func rememberSimulators(_ sims: [SimInfo]) {
        lock.withLock { for s in sims { simInfos[s.udid] = s } }
    }

    // MARK: - the session's intents (driver-gated by ChannelHub)

    /// Open `id` in the session — or un-minimize and focus it when it is already there — and stream it.
    /// Focus follows the newest open, as it always has.
    @discardableResult
    public func openWindow(sourceID id: String, requestedBy clientId: String) -> Bool {
        guard let target = captureTarget(forSourceID: id) else { return false }
        // PICKING A SHUT-DOWN SIMULATOR BOOTS IT — a driver's open is the one intent that may (spec, "The client").
        if case .simulator(let udid) = target, lock.withLock({ simInfos[udid]?.state }) == .shutdown {
            bootSimulator(udid)
        }
        lock.lock()
        let prev = session.focused
        session.open(id)
        driving = true                       // a DRIVER asked for a window: one exists
        lock.unlock()
        syncStreams()
        if prev != id { applyFocus(demote: prev, promote: id) }
        broadcastViewSet()
        updateSimulatorWatch()
        broadcastFullStatus()
        return true
    }

    private func bootSimulator(_ udid: String) {
        let name = lock.withLock { simInfos[udid]?.name } ?? "the simulator"
        simulators?.boot(udid) { [weak self] err in
            guard let err else { return }
            self?.channelHub?.broadcastControl(simStatusJSON(udid: udid, phase: "error", message: "Couldn't boot \(name): \(err)"))
        }
    }

    /// `id` leaves the session and its stream stops. If it was focused, focus falls to the streamed
    /// window before it in tab order (else after it, `SessionState.focused`), which is re-rated to full
    /// and given input — and when the client says the person was AT it (`land`), they land on the bar's
    /// previous tab, a terminal tab too (`landing`).
    public func closeWindow(sourceID id: String, land wanted: Bool = false, requestedBy clientId: String) {
        if case .workspace?=parseSourceID(id),workspace.snapshot().source==id {workspaceRequest(action:"restore-all",app:nil,clientID:clientId);return}
        let landing = landing(leaving: id, wanted: wanted)
        lock.lock()
        let wasFocused = session.focused == id
        let closed = session.close(id, landing: landing)
        if closed { autoScales[id] = nil; crops[id] = nil }
        let now = session.focused
        lock.unlock()
        guard closed else { return }
        syncStreams()
        if case .workspace?=parseSourceID(id) {
            let named=lock.withLock {listedSources.removeValue(forKey:id);return Array(listedSources.values)}
            channelHub?.broadcastControl(sourceListJSON(sources:named));channelHub?.reconcileWorkspaceMedia()
        }
        if wasFocused { applyFocus(demote: nil, promote: now) }
        broadcastViewSet()
        updateSimulatorWatch()
        broadcastFullStatus()
    }

    /// Where the person lands when `id` goes — asked only when the client says they were AT it — and, for a
    /// TERMINAL tab, the pool switched to it NOW. A pure read of the state, then the pool, and only THEN does
    /// the caller commit the change that shows the terminal surface: so the `term-list` naming the tab goes
    /// out before any `view-set` that could carry that surface, from this thread or another (review,
    /// 2026-10-02 — committing first and switching after left a gap a concurrent `view-set` could fill). The
    /// caller hands the SAME landing to the state, so the pool and the surface cannot disagree. Outside
    /// `lock`: the pool's change comes back through `syncTerminalTabs`.
    private func landing(leaving id: String, wanted: Bool) -> SessionLanding? {
        guard wanted else { return nil }
        let landing = lock.withLock { session.landing(leaving: id) }
        if case .terminal(let key)? = landing { channelHub?.landOnTerminal(key) }
        return landing
    }

    /// `id` STAYS in the session, minimized — the `−` that parks a window as its tab — and its stream
    /// stops: a parked window costs nothing. Before 2026-09-29 the host forgot a minimized window the
    /// moment it was minimized (it was an unsubscribe), so only the page that parked it knew it existed.
    public func minimizeWindow(sourceID id: String, land wanted: Bool = false, requestedBy clientId: String) {
        let landing = landing(leaving: id, wanted: wanted)
        lock.lock()
        let prev = session.focused
        let changed = session.minimize(id, landing: landing)
        let now = session.focused
        lock.unlock()
        guard changed else { return }
        syncStreams()
        if prev != now { applyFocus(demote: nil, promote: now) }
        broadcastViewSet()
    }

    /// Un-minimize `id` and focus it; it streams again. True iff it is now streamed — a window that was
    /// already open counts (the reducer reports no change for it, and the caller's track is idempotent).
    @discardableResult
    public func restoreWindow(sourceID id: String, requestedBy clientId: String) -> Bool {
        lock.lock()
        let prev = session.focused
        let changed = session.restore(id)
        let streamed = session.streamed.contains(id)
        if streamed { driving = true }
        lock.unlock()
        guard streamed else { return false }
        if changed {
            syncStreams()
            if prev != id { applyFocus(demote: prev, promote: id) }
            broadcastViewSet()
        }
        return true
    }

    /// Where `id` sits on the desktop layout, for whoever connects next. Pure state: nothing streams
    /// differently. The reducer refuses a non-finite or absurd value.
    public func setWindowPosition(sourceID id: String, x: Double, y: Double, requestedBy clientId: String) {
        let changed = lock.withLock { session.setPosition(id, x: x, y: y) }
        if changed { broadcastViewSet() }
    }

    /// Which surface a pinned layout shows, and which window is full screen (the in-page mode). Pure state.
    public func setView(surface: SessionSurface?, fullscreen: String??, requestedBy clientId: String) {
        let changed = lock.withLock { session.setView(surface: surface, fullscreen: fullscreen) }
        if changed { broadcastViewSet() }
    }

    // MARK: - the bar (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md)

    /// Move a tab of the bar. Pure state as far as capture goes: a moved window reorders `windows` (and so
    /// `streamed` and `subscribedSourceIDs`) but no stream starts or stops, and focus stays. The new order
    /// when it changed — the hub arranges the terminal pool from it — else nil.
    public func agentTab(action: String, thread: String, title: String, cwd: String) {
        guard ProductFeatures.graphicalAgents else { return }
        if action == "close-tab" {
            let landing = lock.withLock { session.landing(leaving: "agent:" + thread) }
            if case .terminal(let key)? = landing { channelHub?.landOnTerminal(key) }
        }
        let (changed, previous, current) = lock.withLock { () -> (Bool, String?, String?) in
            let previous = session.focused
            let changed: Bool
            switch action {
            case "open-tab": changed = session.openAgent(thread, title: title, cwd: cwd)
            case "select-tab": changed = session.selectAgent(thread)
            case "close-tab": changed = session.closeAgent(thread)
            case "rename-tab": changed = session.setAgentName(thread, title)
            default: changed = false
            }
            return (changed, previous, session.focused)
        }
        if previous != current { applyFocus(demote: previous, promote: current) }
        if changed { broadcastViewSet() }
    }

    func savedAgentTabs(terminalIDs:[String]) -> SavedAgentTabs {
        lock.withLock { SavedAgentTabs(state:session,terminalIDs:terminalIDs) }
    }

    func restoreAgentTabs(_ saved:SavedAgentTabs,terminalIDs:[Int:String]) {
        guard ProductFeatures.graphicalAgents else { return }
        let changed=lock.withLock { session.restoreAgents(saved,terminalIDs:terminalIDs) }
        if changed {broadcastViewSet()}
    }

    public func agentStatus(thread: String, status: String?, activeFlags: [String]) {
        let changed = lock.withLock { session.setAgentStatus(thread, status, activeFlags: activeFlags) }
        if changed { broadcastViewSet() }
    }

    public func moveTab(_ tab: String, before: String?) -> [String]? {
        let order: [String]? = lock.withLock { session.moveTab(tab, before: before) ? session.tabOrder : nil }
        if order != nil { broadcastViewSet() }
        return order
    }

    /// A window's user name, `""` clearing it. Pure state; refused (silently, nothing broadcast) for a
    /// window not in the session or a name `TabName` refuses.
    public func renameWindow(sourceID id: String, name: String, requestedBy clientId: String) {
        let changed = lock.withLock { session.setName(id, name) }
        if changed { broadcastViewSet() }
    }

    /// The bar's terminal half follows the pool. Called on EVERY tab-set change, a title's included —
    /// the same set again is no change, so a title broadcasts no `view-set`.
    public func syncTerminalTabs(_ ids: [String]) {
        let changed = lock.withLock { session.syncTerminals(ids) }
        if changed { broadcastViewSet() }
    }

    /// A driver was established, or changed its preferences: every stream resolves against `prefs`, the
    /// streams the state wants and lacks are built, and a pending teardown is cancelled. Idempotent — a
    /// hello repeated by a rebuilt connection changes nothing that is already right.
    public func reconcile(driverPrefs prefs: ClientPrefs) {
        switchPresentation(.streamedSources)
        lock.lock()
        graceTimer?.cancel(); graceTimer = nil   // a driver exists: nothing is torn down
        driverPrefs = prefs
        driving = true
        lock.unlock()
        syncStreams()
        refreshInputOwner()
        broadcastViewSet()
    }

    /// A terminal-only native activation is presentation-local. A new driver restores the
    /// session's focused source, even when its capture survived the handoff and never reattached.
    private func refreshInputOwner() {
        let epoch = channelHub?.currentDriverEpoch()
        let state: (Bool, String?) = lock.withLock {
            guard !hasInputOwnerEpoch || inputOwnerEpoch != epoch else { return (false, nil) }
            hasInputOwnerEpoch = true; inputOwnerEpoch = epoch; scopedTerminalInput = false
            return (true, session.focused)
        }
        if state.0 { routeFocusedSource(state.1) }
    }

    /// The session is OVER (a quit, or the harness stopping) — every stream stops now and the state is
    /// forgotten. Stop Sharing is NOT this: it keeps the state (`stopStreamsKeepingSession`).
    public func endSession() {
        let dead: [SourceStream] = lock.withLock {
            graceTimer?.cancel(); graceTimer = nil
            let all = Array(streams.values)
            streams.removeAll()
            session = SessionState()
            driving = false
            driverPrefs = .default
            autoScales.removeAll(); crops.removeAll()
            return all
        }
        for s in dead {
            s.stop()
            s.encoder?.invalidate()
        }
        refreshLivenessWatch()
        broadcastViewSet()
    }

    /// Drop from the state every `win:` window that is GONE — its app quit or it was closed — minimized
    /// or not. A DISPLAY is never dropped here: a sleeping display is ONLINE but lists no `dsp:` source
    /// (AGENTS.md), and forgetting it at every sleep would lose it for good. Called only with an
    /// AUTHORIZED listing: without Screen Recording the list is empty and would wipe the session.
    /// INTERNAL for the tests; `listSources` is the product's caller.
    ///
    /// NOT LISTED IS NOT GONE (final review, 2026-09-29). The listing carries on-screen windows plus
    /// minimized ones, so a HIDDEN app's window (⌘H), one on another Space or behind a full-screen app,
    /// one under 64 pt or with an empty title is missing from it while its app runs — and every
    /// client's control open lists, passive ones included. A window the listing lacks leaves only when
    /// the window server no longer has it, asked NOW (`existingWindowIDs`): which also keeps a listing
    /// that started before a window was opened from pruning it.
    func retainListed(sourceIDs listed: Set<String>) {
        lock.lock()
        let unlisted = session.windows.map(\.source).filter { $0.hasPrefix("win:") && !listed.contains($0) }
        lock.unlock()
        guard !unlisted.isEmpty else { return }
        let existing = existingWindowIDs()               // OUTSIDE `lock`: a window-server call
        let gone = Set(unlisted.filter { id in
            guard case .window(let w)? = parseSourceID(id) else { return false }
            guard let wid = CGWindowID(exactly: w) else { return true }   // no window can have that number
            return !existing.contains(wid)
        })
        guard !gone.isEmpty else { return }
        lock.lock()
        let prevFocus = session.focused
        let keep = Set(session.windows.map(\.source).filter { !gone.contains($0) })
        let dropped = session.retain(onlyIn: keep)                 // never lands: nobody was at a quit
        for id in dropped { autoScales[id] = nil; crops[id] = nil }
        let focus = session.focused
        lock.unlock()
        guard !dropped.isEmpty else { return }
        print("[sources] gone from the host, left the session: \(dropped.joined(separator: " "))")
        syncStreams()
        if focus != prevFocus { applyFocus(demote: nil, promote: focus) }
        broadcastViewSet()
    }

    /// What a listing means for the session. An AUTHORIZED one drops the windows it no longer has
    /// (`retainListed`). An UNAUTHORIZED one is EMPTY — Screen Recording missing, not every window gone —
    /// and prunes NOTHING: a revoked grant or a first-run prompt would otherwise wipe the session.
    /// INTERNAL for the tests; `listSources` is the product's caller.
    func applyListing(sourceIDs listed: Set<String>, authorized: Bool) {
        guard authorized else { return }
        retainListed(sourceIDs: listed)
    }

    /// What `id` captures, or nil for a source the host refuses: an unparseable id, a `sim:` on a host with no
    /// simulator support, or one of the host's OWN windows. OUTSIDE `lock` — the owner lookup is an AX/CG call.
    private func captureTarget(forSourceID id: String) -> SourceTarget? {
        guard let parsed = parseSourceID(id) else { return nil }
        switch parsed {
        case .sim(let udid):
            guard simulators != nil else {
                print("[source] no simulator support on this host — refusing \(id)")
                return nil
            }
            return .simulator(udid)
        case .window(let w):
            // OUR OWN WINDOW IS REFUSED AT THE REQUEST, not later at the capture boundary, and the
            // reason is a CRASH rather than a disclosure. `buildAndAttach` raises the opened window
            // through Accessibility, and a process performing an AX raise on ITSELF traps inside
            // AppKit — `accessibilityPerformRaise` -> `makeKeyAndOrderFront` -> EXC_BREAKPOINT,
            // measured by `scripts/gate-capture-boundary.sh` and confirmed in the crash report. Any
            // connected client could therefore kill the host with one control message naming a window
            // id belonging to the host process, and those ids are adjacent to the ones it does list.
            //
            // Refusing here also removes two lesser wrongs the late refusal left behind: the client
            // got a negotiated video track that carried nothing, and the host built an Opus encoder
            // for its own process.
            //
            // `ScreenCaptureSource.resolveSubject` KEEPS ITS OWN REFUSAL. That one is the capture
            // boundary and this is authorization; §16 enumerates every path separately.
            if SelfCapture.isOwnWindow(ownerPID: windowOwnerPID(CGWindowID(w)),
                                       selfPID: ProcessInfo.processInfo.processIdentifier) {
                print("[source] refusing to open our own window \(w) — it carries the pairing secret")
                return nil
            }
            return .window(w)
        case .workspace:
            if let display = workspaceDisplayForTests?(id) { return .workspace(Int(display)) }
            guard ApplicationCaptureFeature.enabled else { return nil }
            return workspace.displayID(for:id).map { .workspace(Int($0)) }
        case .display(let d):
            return .display(d)
        }
    }

    /// A new stream for `id`, with everything that needs AX or CoreGraphics filled in — OUTSIDE `lock`.
    /// Its `fullPrefs` are its base defaults until `syncStreams` resolves them against the driver's.
    private func makeStream(_ id: String, target: SourceTarget, workspaceEpoch: UInt64?) -> SourceStream {
        var base = defaultPrefs
        var native: (w: Int, h: Int)? = nil
        // A DISPLAY'S DEFAULTS FOLLOW ITS PANEL. A display captured at scale 1.0 can exceed libaom's
        // 3840x2160 ceiling, and EncodeDimensions.fit then throws the excess away after a large vImage
        // downscale — measured firing on the very first frame of a 3456x2234 panel. AND THE BITRATE
        // FOLLOWS THE PIXELS: the flat default is ~0.0002 bits per pixel on a panel that size, and a
        // starved encoder answers a scene change with one enormous frame. Both are STARTING defaults —
        // a driver's own resolution or bitrate preference still wins (`resolvedPrefsLocked`).
        if case .display(let d) = target, let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(d)) {
            base.scale = displayDefaultScale(pixelW: mode.pixelWidth, pixelH: mode.pixelHeight)
            base.bitrateBps = derivedBitrate(nativeW: mode.pixelWidth, nativeH: mode.pixelHeight, prefs: base)
            native = (mode.pixelWidth, mode.pixelHeight)
        }
        if case .simulator(let udid) = target, let s = lock.withLock({ simInfos[udid] }) {
            base.scale = displayDefaultScale(pixelW: s.pxW, pixelH: s.pxH)
            base.bitrateBps = derivedBitrate(nativeW: s.pxW, nativeH: s.pxH, prefs: base)
            native = (s.pxW, s.pxH)
        }
        if case .workspace = target {
            // The fixed frame includes RGB, alpha and hit panels. Without this size Auto falls
            // back to 2 Mbps for 3840×800, starving text even while the transport is healthy.
            let format = WorkspaceFormat.v1
            base.scale = 1
            native = (format.codedWidth, format.codedHeight)
            base.bitrateBps = derivedBitrate(nativeW: format.codedWidth, nativeH: format.codedHeight, prefs: base)
        }
        let stream = SourceStream(sourceID: id, target: target, fullPrefs: base)
        stream.nativeEpoch = lock.withLock { nativeEpoch }
        if case .workspace = target { stream.workspaceEpoch = workspaceEpoch }
        stream.baseDefaults = base
        stream.nativePixels = native
        // THE OWNING APPLICATION, for the audio-ownership election. A display source owns EVERY
        // application's audio (SCK gives it the system mix), which `nil` denotes.
        if case .window(let w) = target { stream.ownerPID = windowOwnerPID(CGWindowID(w)) }
        // BUILT HERE, not lazily like the video encoder: Opus is the only audio codec rdev registers,
        // so there is no codec-resolved callback to wait for and nothing to rebuild when it settles.
        if stream.nativeEpoch == nil {
            stream.audioEncoder = OpusEncoderAdapter(sourceID: id)
        }
        return stream
    }

    /// Under `lock`: the prefs `stream` runs at for the current driver — its base defaults, overridden
    /// by the driver's preferences, its window's Auto ceiling and crop (`resolvedVideoPrefs`).
    ///
    /// THE DERIVED BUDGET FOLLOWS THE PIXELS while the driver names no bitrate: Auto resolution lands
    /// about a second after a window opens and can cut the pixel count several-fold, and a budget sized
    /// for the full panel would then be spent on a seventh of the pixels. A bitrate the driver DOES
    /// name is never overwritten.
    private func resolvedPrefsLocked(_ stream: SourceStream) -> VideoPrefs {
        var p = resolvedVideoPrefs(defaults: stream.baseDefaults, client: driverPrefs,
                                   autoScale: autoScales[stream.sourceID],
                                   crop: crops[stream.sourceID] ?? .full, bitrateCap: bitrateCap)
        // Fix the workspace's actual encoding scale BEFORE deriving its rate. A device-wide
        // quarter-resolution preference never changes these panels and must not quarter their budget.
        if case .workspace=stream.target {p.scale=1;p.crop = .full;p.codec = .av1}
        if driverPrefs.bitrateBps == nil, let native = stream.nativePixels {
            p.bitrateBps = derivedBitrate(nativeW: native.w, nativeH: native.h, prefs: p)
        }
        return p
    }

    /// Make `streams` match the state — build a stream for every streamed window that has none (only
    /// while `driving`), stop every stream whose window is no longer streamed (minimized, closed, gone)
    /// — and re-resolve every stream's prefs against the driver's, pushing a change to a live encoder.
    ///
    /// THREE PHASES, for the standing rule that nothing slow runs under `lock`: decide under it; do
    /// the AX/CoreGraphics work of a new stream outside it; install under it again, re-checking that
    /// the window is still wanted and still streamless (an intent may have landed in between). Every
    /// capture, encoder and hub call happens after the last release. The caller broadcasts.
    private func syncStreams() {
        let driver=channelHub?.currentDriver()
        let driverEpoch=channelHub?.currentDriverEpoch()
        let mediaReady = driver?.mediaReady ?? true
        lock.lock()
        streamReconcileGeneration &+= 1
        let reconcileGeneration=streamReconcileGeneration
        let capable=driver.map {workspaceCapabilities[$0.clientId]?.matches($0)==true} ?? false
        let want = session.streamed.filter { id in
            if case .workspace?=parseSourceID(id) {return capable && presentation != .nativeSimulators}
            return presentation != .nativeSimulators || NativeSimulatorPolicy.isSimulator(id)
        }
        var stopped: [SourceStream] = []
        for (id, s) in streams {
            var staleWorkspace = false
            if case .workspace = s.target { staleWorkspace = s.workspaceEpoch != driverEpoch }
            if !want.contains(id) || staleWorkspace { stopped.append(s); streams[id] = nil }
        }
        let missing = driving && mediaReady ? want.filter { streams[$0] == nil } : []
        lock.unlock()

        let prepared: [(SourceStream, SourceTarget)] = missing.compactMap { id in
            captureTarget(forSourceID: id).map { (makeStream(id, target: $0, workspaceEpoch: driverEpoch), $0) }
        }

        var builds: [(SourceStream, SourceTarget)] = []
        var live: [(enc: VideoEncoding?, src: StreamVideoSource?, prefs: VideoPrefs)] = []
        var codecChanges: [(String, CodecPref)] = []
        beforeStreamInstallForTests?()
        // Snapshot the CURRENT connection outside our lock; capability belongs to this instance,
        // not the reused client ID. A newer reconciliation also invalidates old prepared work.
        let installDriver=channelHub?.currentDriver()
        let installEpoch=channelHub?.currentDriverEpoch()
        let installReady=installDriver?.mediaReady ?? true
        lock.lock()
        let stillCapable=installDriver.map {workspaceCapabilities[$0.clientId]?.matches($0)==true} ?? false
        let wantNow = Set(session.streamed.filter { id in
            if case .workspace?=parseSourceID(id) {
                return stillCapable && installReady && presentation == .streamedSources &&
                    driver === installDriver && driverEpoch == installEpoch && reconcileGeneration == streamReconcileGeneration
            }
            return presentation != .nativeSimulators || NativeSimulatorPolicy.isSimulator(id)
        })
        for (s, target) in prepared where driving && wantNow.contains(s.sourceID) && streams[s.sourceID] == nil && s.nativeEpoch == nativeEpoch {
            streams[s.sourceID] = s
            builds.append((s, target))
        }
        let focusedID = session.focused
        for (id, s) in streams {
            let before = s.fullPrefs
            s.fullPrefs = resolvedPrefsLocked(s)
            // A stream built just now has no encoder or capture yet: `commitStart` applies its prefs.
            guard s.fullPrefs != before, !builds.contains(where: { $0.0 === s }) else { continue }
            if s.fullPrefs.codec != before.codec { codecChanges.append((id, s.fullPrefs.codec)) }
            live.append((s.encoder, s.source,
                         effectiveVideoPrefs(full: s.fullPrefs, focused: id == focusedID, hidden: hidden,
                                             throttleFps: throttleFps, throttleBitrateBps: throttleBitrateBps)))
        }
        let ratio = fecMediaRatio
        lock.unlock()

        // Capture teardown alone leaves a focused injector routed. Invalidate its post lease
        // synchronously before stopping media, then drain/unroute it while retaining the session tab.
        for s in stopped {
            if case .workspace=s.target { (s.injector as? WindowInputInjector)?.invalidateWorkspace() }
            channelHub?.clearInjector(ifMatching:s.injector)
        }
        for s in stopped { s.stop() }         // stop capture/encode for a window no longer streamed
        // THE RATIO IS APPLIED TO THE REQUEST and `fullPrefs` keeps the request — see fecAppliedBitrate.
        // NO CROP HERE: `setSourceView` is THE ONLY PLACE a crop is pushed (and `resetViewerDerived` its reset).
        for w in live {
            w.enc?.setFps(w.prefs.fps)
            w.enc?.setBitrate(fecAppliedBitrate(requested: w.prefs.bitrateBps, ratio: ratio))
            w.src?.setScale(w.prefs.scale); w.src?.setFpsCap(w.prefs.fps)
        }
        // A codec change renegotiates every client's track for the source (remove + add, never
        // ReplaceTrack — ChannelHub.setCodec); `codec-resolved` then rebuilds the encoder.
        for (id, codec) in codecChanges { channelHub?.setCodec(sourceID: id, pref: codec) }
        if attachesCaptureForTests {
            for (s, target) in builds { Task { [weak self] in await self?.buildAndAttach(stream: s, target: target) } }
        }
        // LOSING A CARRIER PROMOTES A SIBLING of the same application, so the audio election re-runs
        // whenever a stream stops (it ends with a view-set broadcast).
        if !stopped.isEmpty { reconcileAudio() }
        refreshLivenessWatch()
    }

    /// Apply one adaptive-FlexFEC controller decision to every subscribed source.
    ///
    /// Returns `false` only when the update could not be applied at all, which the ABI reports back
    /// to the engine as a rejection. A SOURCE WITH NO ENCODER YET, OR AN EMPTY SUBSCRIPTION SET, IS
    /// A NO-OP RETURNING SUCCESS — not an error: the controller's own rejections are for invalid
    /// sequences and bitrates, and failing because nothing is subscribed yet would kill a session
    /// for a condition that is normal at startup. The ratio is stored either way, so a source that
    /// subscribes later starts at the right fraction (see `commitStart`).
    ///
    /// THE CONTROLLER'S FIGURE IS ABSOLUTE AGAINST THE SESSION BUDGET and is converted to a ratio
    /// here. The budget is the bitrate CAP, which no client request can exceed by definition —
    /// which is what makes the ratio meaningful for a source requesting far less than the cap.
    ///
    /// LOCK DISCIPLINE, unchanged from every other method here: state is mutated and refs are
    /// snapshotted under `lock`; every encoder call happens after releasing it, and `ChannelHub`'s
    /// lock is never taken while holding this one.
    @discardableResult
    public func applyRecoveryPolicy(mediaBitrateBps: UInt32, budgetBps: UInt32) -> Bool {
        // A zero budget cannot produce a ratio, and reporting success for an update that reached no
        // encoder is the one lie the callback's status exists to prevent.
        guard budgetBps > 0, mediaBitrateBps > 0 else { return false }
        let ratio = Double(mediaBitrateBps) / Double(budgetBps)

        lock.lock()
        fecMediaRatio = ratio
        let plans: [(VideoEncoding, VideoPrefs)] = streams.compactMap { id, stream in
            guard let encoder = stream.encoder else { return nil }
            let focused = session.focused == id
            // `fullPrefs` is the REQUEST and is never written here.
            let applied = focused ? stream.fullPrefs
                : throttledPrefs(stream.fullPrefs, throttleFps: throttleFps,
                                 throttleBitrateBps: throttleBitrateBps)
            return (encoder, applied)
        }
        lock.unlock()

        for (encoder, applied) in plans {
            encoder.setBitrate(fecAppliedBitrate(requested: applied.bitrateBps, ratio: ratio))
        }
        return true
    }

    /// Change a subscribed source's FULL prefs in place (clamped) and reconfigure its encoder + source live at the
    /// focused-or-throttled runtime rate. Ignored for a source that isn't currently subscribed.
    /// The resolution-derived starting bitrate for a source, from its NATIVE size and the scale the
    /// capture will actually run at. ONE function, so the subscribe path and the prefs path cannot
    /// drift — the bug that shape produces is a budget that is right until the first resize.
    private func derivedBitrate(nativeW: Int, nativeH: Int, prefs: VideoPrefs) -> Int {
        let px = Double(nativeW) * prefs.scale
        let py = Double(nativeH) * prefs.scale
        return resolutionBitrateBps(pixelW: Int(px.rounded()), pixelH: Int(py.rounded()), fps: prefs.fps,
                                    floorBps: defaultPrefs.bitrateBps, capBps: bitrateCap,
                                    bitsPerPixel: Self.bitsPerPixel)
    }

    /// The per-window values the driver's page DERIVES: `scale` is its Auto resolution ceiling for this
    /// window (used while the driver's resolution preference is `auto`), `crop` the region it can see.
    /// fps, bitrate and codec are not here: they are the driver's CLIENT-WIDE preferences (`reconcile`).
    public func setSourceView(sourceID id: String, scale: Double?, crop: CropRect?, requestedBy clientId: String) {
        if case .workspace?=parseSourceID(id) {return} // v1 is fixed-format; crops must never split its planes.
        lock.lock()
        guard session.contains(id) else { lock.unlock(); return }
        if let scale { autoScales[id] = min(max(scale, 0.05), 1.0) }
        if let crop { crops[id] = crop }
        guard let stream = streams[id] else { lock.unlock(); return }   // minimized: kept for its restore
        let effective = resolvedPrefsLocked(stream)
        stream.fullPrefs = effective
        let applied = effectiveVideoPrefs(full: effective, focused: session.focused == id, hidden: hidden,
                                          throttleFps: throttleFps, throttleBitrateBps: throttleBitrateBps)
        let enc = stream.encoder; let src = stream.source
        let ratio = fecMediaRatio
        lock.unlock()
        // The encoder may not exist yet (codec unresolved): the prefs are stored above and applied by
        // `commitStart`. THE RATIO IS APPLIED TO THE REQUEST — see fecAppliedBitrate.
        enc?.setFps(applied.fps)
        enc?.setBitrate(fecAppliedBitrate(requested: applied.bitrateBps, ratio: ratio))
        // THE ONLY PLACE THE CROP IS PUSHED. Every other site that re-pushes fps/bitrate/scale — focus
        // flips, the hidden-tab throttle, a reconcile, a rebuild — leaves the crop alone, and the
        // adapter holding it across a recreate is what keeps that true.
        enc?.setCrop(applied.crop)
        src?.setScale(applied.scale); src?.setFpsCap(applied.fps)
        broadcastViewSet()   // `subs` carries the stream's resolved prefs
    }

    /// Set the input-focus source: repoint input + rate the two affected streams (new focus → full prefs + input;
    /// the previously-focused → throttle). Ignored for a source that isn't subscribed, or a no-op re-focus.
    /// Resize the real window behind `sourceID`, best-effort (see `WindowAX.setSize`). Runs OUTSIDE any lock
    /// — it touches only the wid and a fresh AX tree, exactly like the `unminimize` call in `buildAndAttach`.
    ///
    /// EVERY REQUEST GETS A REPLY, and that is the load-bearing part rather than the resize itself: the client
    /// holds its window blurred and provisional until a `source-status` lands, so any path that returns
    /// silently strands it there forever. Identical, clamped, refused by the app, and "this source cannot be
    /// resized at all" are all the same path. Sims are the one exception — they have no window and no bounds
    /// to answer with.
    /// Forget every window's crop AND Auto resolution ceiling.
    ///
    /// WHY IT EXISTS. Both are chosen by whichever client is the video consumer, from ITS boxes. Client A
    /// zooms into a corner and disconnects; client B connects and inherits a window that is nine tenths
    /// checkerboard, with nothing on its end explaining why — and a window sized for A's phone. There is
    /// exactly one consumer at a time — `ActiveClientEffects` names the client to add or remove as one —
    /// so a change of consumer is the right moment to forget (contract amendment 3). The incoming
    /// driver's reconcile (right after, in `ChannelHub.apply`) re-resolves the scale; the crop is reset
    /// on the encoders here, because nothing else pushes one.
    public func resetViewerDerived() {
        lock.lock()
        crops.removeAll()
        autoScales.removeAll()
        var encoders: [(any VideoEncoding)?] = []
        for stream in streams.values where stream.fullPrefs.crop != .full {
            stream.fullPrefs.crop = .full
            encoders.append(stream.encoder)
        }
        lock.unlock()
        // OUTSIDE `lock`, the standing rule: build under the lock, call out beyond it.
        for enc in encoders { enc?.setCrop(.full) }
    }

    /// A driver's intent on a simulator. Buttons go through the STREAMED simulator's own injector (a simulator not
    /// streamed has no HID connection to press with); rotation and shake through `devicectl`, off every lock and every
    /// queue that matters; boot and shutdown through the catalog. A failure is said as a `sim-status` error — the
    /// toast the client already shows.
    public func simAction(sourceID id: String, action: SimAction, requestedBy clientId: String) {
        guard case .sim(let udid)? = parseSourceID(id) else { return }
        let (inj, name) = lock.withLock {
            (streams[id]?.injector as? SimulatorInputInjector, simInfos[udid]?.name ?? "the simulator")
        }
        let hub = channelHub
        let report: (String) -> @Sendable (String?) -> Void = { what in
            { err in
                guard let err else { return }
                hub?.broadcastControl(simStatusJSON(udid: udid, phase: "error", message: "Couldn't \(what) \(name): \(err)"))
            }
        }
        switch action {
        case .home: inj?.press(.home)
        case .keyboard: inj?.press(.keyboard)
        case .appSwitcher: inj?.appSwitcher()
        case .lock: inj?.press(.lock)
        case .siri: inj?.press(.siri)
        case .volumeUp: inj?.press(.volumeUp)
        case .volumeDown: inj?.press(.volumeDown)
        case .boot: simulators?.boot(udid, completion: report("boot"))
        case .shutdown: simulators?.shutdown(udid, completion: report("shut down"))
        case .shake, .rotateLeft, .rotateRight:
            let control = simulatorControl
            let done = report(action == .shake ? "shake" : "rotate")
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let ok: Bool
                switch action {
                case .shake: ok = control.shake(udid: udid)
                case .rotateLeft: ok = control.rotate(udid: udid, left: true)
                default: ok = control.rotate(udid: udid, left: false)
                }
                print("[sim] \(action.rawValue) \(udid): \(ok ? "done" : "devicectl failed") "
                      + "(\((DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000) ms)")
                done(ok ? nil : "devicectl failed")
            }
        }
    }

    public func setSourceSize(sourceID: String, w: Int, h: Int, requestedBy clientId: String) {
        let size: CGSize
        switch parseSourceID(sourceID) {
        case .workspace:
            size=CGSize(width:1280,height:800)
        case .display(let d):
            // A DISPLAY CANNOT BE RESIZED, BUT THE REQUEST STILL GETS AN ANSWER. Replying with the size it
            // already is un-blurs the client's window immediately and snaps it back — the drag does nothing,
            // which is correct, and it does it VISIBLY.
            let b = CGDisplayBounds(CGDirectDisplayID(d))
            guard b.width > 0, b.height > 0 else { return }
            size = b.size
        case .window(let wid):
            let actual = WindowAX.setSize(windowID: CGWindowID(wid), w: w, h: h)
            if actual == nil && !AXIsProcessTrusted() {
                print("[window] resize skipped for wid \(wid): Accessibility permission absent")
            }
            // Falls back to the on-screen bounds when AX can't be resolved.
            guard let s = actual ?? WindowLivenessMonitor.onScreenSize(CGWindowID(wid)) else { return }
            size = s
        case .sim:
            // A SIMULATOR CANNOT BE RESIZED, AND ANSWERS LIKE A DISPLAY: the size it is, so the window snaps back.
            if let s = simulatorSizeStatus(sourceID: sourceID) {
                refreshSimulatorStatusCache()
                pushStatuses(merging: s)
            }
            return
        case nil:
            return
        }
        let status = SourceStatus(id: sourceID, live: true,
                                  w: Int(size.width.rounded()), h: Int(size.height.rounded()))
        pushStatuses(merging: status)
    }

    /// Every `sim:` window of the session, as `source-status` says it: `live` only once its picture is up (a booted
    /// device shows nothing for ~20 s), `simState` from the last listing. INTERNAL for the tests.
    func simulatorStatuses() -> [SourceStatus] {
        lock.withLock {
            session.windows.compactMap { w -> SourceStatus? in
                guard case .sim(let udid)? = parseSourceID(w.source) else { return nil }
                let state = simInfos[udid]?.state
                let live = state == .booted && (simLive[w.source] ?? false)
                return SourceStatus(id: w.source, live: live, simState: state)
            }
        }
    }

    /// A simulator's answer to `set-source-size`: the size it IS, so the client snaps back (as a display's). nil when
    /// nothing is known of it. INTERNAL for the tests.
    func simulatorSizeStatus(sourceID id: String) -> SourceStatus? {
        guard case .sim(let udid)? = parseSourceID(id) else { return nil }
        return lock.withLock { () -> SourceStatus? in
            let state = simInfos[udid]?.state
            let live = state == .booted && (simLive[id] ?? false)
            if let pt = (streams[id]?.source as? SimulatorCaptureSource)?.shownPoints {
                return SourceStatus(id: id, live: live, w: Int(pt.width.rounded()), h: Int(pt.height.rounded()), simState: state)
            }
            guard let s = simInfos[udid] else { return nil }
            return SourceStatus(id: id, live: live, w: s.w, h: s.h, simState: state)
        }
    }

    private func simulatorLive(_ id: String, _ live: Bool) {
        lock.withLock { simLive[id] = live }
        broadcastFullStatus()
    }

    /// The simulator half of every `source-status` push, CACHED for the window monitor's callback: that runs on the
    /// monitor's own queue and must never take `lock`, because the simulator paths call `liveness.snapshot()` — a
    /// `queue.sync` onto that same queue. A LEAF lock: nothing is acquired while it is held.
    private let simStatusLock = NSLock()
    private var simStatusCache: [SourceStatus] = []

    private static func windowStatuses(_ live: LivenessSnapshot) -> [SourceStatus] {
        live.windows.map { SourceStatus(id: sourceID(windowID: Int($0.key)), live: $0.value) }
            + live.displays.map { SourceStatus(id: sourceID(displayID: Int($0.key)), live: $0.value) }
    }

    /// TESTS: every `source-status` this manager broadcasts, before it is sent. Set before use.
    var statusBroadcastForTests: (([SourceStatus]) -> Void)?

    private func broadcastStatuses(_ statuses: [SourceStatus]) {
        statusBroadcastForTests?(statuses)
        channelHub?.broadcastControl(sourceStatusJSON(statuses: statuses))
    }

    /// A capture's size changed (its first frame, a resize, a rotation): its size, to every client. On the capture's
    /// own queue (`ScreenCaptureSource`'s `sizeQueue`), so it never takes `lock`. INTERNAL for the tests.
    func sourceSizeChanged(_ id: String, size: CGSize, scale: CGFloat) {
        let status = SourceStatus(id: id, live: true,
                                  w: Int(size.width.rounded()), h: Int(size.height.rounded()),
                                  pxW: Int((size.width * scale).rounded()),
                                  pxH: Int((size.height * scale).rounded()))
        pushStatuses(merging: status)
    }

    /// THE FULL SNAPSHOT FROM WHAT IS ALREADY KNOWN — the monitor's windows and the CACHED simulators — with `one`'s
    /// size merged onto its entry (final review I1: a push about one source wiped every other's liveness and every
    /// simulator's state on the client). Never takes `lock`, so a capture's size queue may call it.
    private func pushStatuses(merging one: SourceStatus?) {
        var statuses = Self.windowStatuses(liveness.snapshot()) + simStatusLock.withLock { simStatusCache }
        if let one { statuses = Self.merging(statuses, one) }
        broadcastStatuses(statuses)
    }

    /// `one`'s sizes onto its entry in `full` (its liveness and state kept), or `one` appended when it has none.
    static func merging(_ full: [SourceStatus], _ one: SourceStatus) -> [SourceStatus] {
        guard let i = full.firstIndex(where: { $0.id == one.id }) else { return full + [one] }
        var out = full
        let e = full[i]
        out[i] = SourceStatus(id: e.id, live: e.live, w: one.w ?? e.w, h: one.h ?? e.h, pxW: one.pxW ?? e.pxW,
                              pxH: one.pxH ?? e.pxH, simState: e.simState ?? one.simState)
        return out
    }

    /// EVERY LIVENESS PUSH IS A FULL SNAPSHOT — the client REPLACES its liveness map with each one (`session.ts`) — so
    /// a simulator's `live:false` sent alone would be wiped by the next window push, and a window's by the next
    /// simulator push. Windows and simulators therefore always travel together. OUTSIDE `lock`.
    private func broadcastFullStatus() {
        refreshSimulatorStatusCache()
        pushStatuses(merging: nil)
    }

    /// Recompute the simulator half (takes `lock`) and THEN store it — the cache's lock stays a leaf (final review M1).
    private func refreshSimulatorStatusCache() {
        let sims = simulatorStatuses()
        simStatusLock.withLock { simStatusCache = sims }
    }

    private func observeSimulators() {
        // REGISTERED, NOT STARTED (final review I6): the catalog is watched only while the session holds a simulator
        // tab (`updateSimulatorWatch`), so nothing of CoreSimulator runs at launch.
        simulators?.observe { [weak self] list in self?.simulatorsChanged(list) }
    }

    /// The catalog's poll saw a change. A device that is GONE from the set (deleted) leaves the session — the one way
    /// a simulator's tab goes without a person closing it; every other state keeps it (spec, "One lifecycle rule").
    private func simulatorsChanged(_ list: [SimInfo]) {
        let present = Set(list.map(\.udid))
        lock.lock()
        for s in list { simInfos[s.udid] = s }
        let missing = Set(session.windows.map(\.source).filter {
            guard case .sim(let u)? = parseSourceID($0) else { return false }
            return !present.contains(u)
        })
        lock.unlock()
        // ONE LISTING'S WORD IS NOT A DELETION (final review M2): CoreSimulatorService restarting — the standard cure
        // for a wedge — can list nothing for a moment, and that closed every simulator tab. A device missing here is
        // listed again after `deletionConfirmDelay`, and leaves only if it is STILL missing; a listing that fails
        // (nil) confirms nothing.
        if !missing.isEmpty {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deletionConfirmDelay) { [weak self] in
                guard let self, let again = self.simulators?.list(deadline: 2) else { return }
                let still = Set(again.map(\.udid))
                self.dropDeletedSimulators(missing.filter { id in
                    guard case .sim(let u)? = parseSourceID(id) else { return false }
                    return !still.contains(u)
                })
            }
        }
        broadcastFullStatus()
    }

    /// Watch the catalog while — and only while — the session holds a simulator tab (final review I6).
    private func updateSimulatorWatch() {
        guard let simulators else { return }
        let change: Bool? = lock.withLock {
            let want = session.windows.contains { $0.source.hasPrefix("sim:") }
            guard want != watchingSimulators else { return nil }
            watchingSimulators = want
            return want
        }
        if let change { simulators.setObserving(change) }
    }

    /// The simulator tabs whose devices are CONFIRMED gone leave the session.
    private func dropDeletedSimulators(_ gone: Set<String>) {
        guard !gone.isEmpty else { return }
        lock.lock()
        let prevFocus = session.focused
        var dropped: [String] = []
        if !gone.isEmpty {
            let keep = Set(session.windows.map(\.source).filter { !gone.contains($0) })
            dropped = session.retain(onlyIn: keep)
            for id in dropped { autoScales[id] = nil; crops[id] = nil; simLive[id] = nil }
        }
        let focus = session.focused
        lock.unlock()
        if !dropped.isEmpty {
            print("[sources] simulator deleted, left the session: \(dropped.joined(separator: " "))")
            syncStreams()
            if focus != prevFocus { applyFocus(demote: nil, promote: focus) }
            broadcastViewSet()
        }
        updateSimulatorWatch()
        broadcastFullStatus()
    }

    public func focusSource(sourceID id: String, requestedBy clientId: String) {
        lock.lock()
        let prev = session.focused
        let focused = session.focus(id)       // only an open, non-minimized window
        lock.unlock()
        guard focused, prev != id else { return }
        applyFocus(demote: prev, promote: id)
        broadcastViewSet()
    }

    public func sourceInputFocus(source: String?, request: String, requestedBy clientId: String) -> Bool {
        let epoch = channelHub?.currentDriverEpoch()
        lock.withLock { hasInputOwnerEpoch = true; inputOwnerEpoch = epoch }
        guard let source else {
            routeFocusedSource(nil, activation: request, terminal: true)
            return true
        }
        let state: (String?, Bool)? = lock.withLock {
            guard session.streamed.contains(source), let stream = streams[source], stream.injector != nil else { return nil }
            switch stream.target {
            case .workspace: return nil
            case .window, .display, .simulator: break
            }
            let previous = session.focused
            _ = session.focus(source)
            return (previous, previous != source)
        }
        guard let (previous, changed) = state else {
            // A late capture attachment must not resurrect the old route after a failed activation.
            lock.withLock { scopedTerminalInput = true }
            return false
        }
        if changed { applyFocus(demote: previous, promote: source, routeInput: false); broadcastViewSet() }
        routeFocusedSource(source, activation: request)
        return true
    }

    /// The window a paste or drop goes to (§4.2): FOCUSED first, as `focus-source` would — so ⌘V lands on
    /// it, and every device's bar shows it — and its stream's injector returned. nil unless it is OPEN in
    /// the session (not minimized) and has an injector (a window still booting has none). An
    /// already-focused window is a target too: only the re-announcing is skipped.
    public func pasteTarget(sourceID id: String) -> InputInjector? {
        lock.lock()
        let prev = session.focused
        // `focus` answers false for a window that is ALREADY focused (nothing changed), so that case is named.
        let focused = session.focused == id || session.focus(id)
        let inj = streams[id]?.injector
        lock.unlock()
        guard focused, let inj else { return nil }
        if prev != id {
            applyFocus(demote: prev, promote: id)
            broadcastViewSet()
        }
        return inj
    }

    /// Tests: whether `id` is in the session at all, streamed or minimized.
    func sessionContainsForTests(_ id: String) -> Bool { lock.withLock { session.contains(id) } }
    /// Tests: the starting scale a stream was built with (`makeStream`'s defaults).
    func streamScaleForTests(_ id: String) -> Double? { lock.withLock { streams[id]?.baseDefaults.scale } }

    func nativeInputTarget(_ id: String) -> InputInjector? { lock.withLock { streams[id]?.injector } }

    func injectorForTests(_ id: String) -> InputInjector? { lock.withLock { streams[id]?.injector } }

    /// Tests: give a stream an injector (`attachesCaptureForTests = false` never builds one).
    func setInjectorForTests(_ id: String, _ injector: InputInjector?) { lock.withLock { streams[id]?.injector = injector } }

    /// Whether the session streams anything. ChannelHub only asks whether this closure EXISTS (the
    /// headless path has none); kept meaningful anyway.
    public var hasSubscription: Bool { lock.withLock { !session.streamed.isEmpty } }

    /// The streamed windows that HAVE a stream, in tab order — what the driver gets a track for.
    public func subscribedSourceIDs() -> [String] { lock.withLock { session.streamed.filter { streams[$0] != nil } } }

    /// Tests: a stream's resolved prefs, nil with no stream.
    func fullPrefsForTests(_ id: String) -> VideoPrefs? { lock.withLock { streams[id]?.fullPrefs } }

    /// The per-source encoder feeding `id`'s track (cap-N: one encoder per subscribed source). nil if unknown.
    /// Per client, the sources that client asked to SILENCE. Absent means audible — the default is
    /// ON, so a client that has never spoken hears everything it is entitled to. Guarded by `lock`.
    ///
    /// PER CLIENT AND NOT PER SOURCE, because sinks already are: one encoder fans out to a sink per
    /// (client, source), so muting is dropping one sink and costs nothing that is not already there.
    private var audioMuted: [String: Set<String>] = [:]

    public func encoderForSource(_ id: String) -> VideoEncoding? { lock.withLock { streams[id]?.encoder } }
    public func audioEncoderForSource(_ id: String) -> AudioEncoding? {
        lock.withLock { streams[id]?.audioEncoder }
    }

    /// Record the session's forced FEC overhead so every later `view-set` echoes it, and re-broadcast
    /// so the change lands in every open titlebar at once. Applying it to the peer is ChannelHub's,
    /// which is where the peers are.
    public func setRecoveryOverride(bp: Int?) {
        lock.withLock { recoveryOverrideBp = bp }
        broadcastViewSet()
    }

    /// Record the session's playout-delay floor so every later `view-set` echoes it, and re-broadcast
    /// so every open titlebar shows the change at once. Applying it to the peer is ChannelHub's.
    public func setPlayoutDelay(minMs: Int?, maxMs: Int?) {
        lock.withLock { playoutDelayMinMs = minMs; playoutDelayMaxMs = maxMs }
        broadcastViewSet()
    }

    /// The host curtain changed: re-broadcast so every client's toggle reflects it at once. The curtain
    /// is HOST state that the host reports, which is why it is read live from CurtainController in
    /// `viewSetJSON` rather than mirrored into a field here — a mirror could disagree with the screen.
    public func announceCurtainChange() { broadcastViewSet() }

    /// Push the view set to one client (on control-open, on claim, and on every change).
    public func sendViewSet(toClient clientId: String) {
        channelHub?.sendControl(viewSetPayload(forClient: clientId), to: clientId)
    }

    /// The listing just sent, remembered for the next offer's window names (`listedSources`). INTERNAL for the tests.
    func rememberListing(_ sources: [Source]) {
        lock.withLock {
            let apps=listedSources.filter {if case .workspace?=parseSourceID($0.key){return true};return false}
            listedSources=Dictionary(sources.map {($0.id,$0)},uniquingKeysWith:{a,_ in a});listedSources.merge(apps,uniquingKeysWith:{a,_ in a})
        }
    }

    /// **WHAT AN OFFER CARRIES OF THE WINDOWS** (`ChannelHub.offerState`; docs/sources-and-focus.md, "The offer
    /// carries the tab bar"): the session's STATE as a `view-set` — windows, focus, view, the bar's order, version —
    /// with NO live echo (no `subs`, codecs, delivery, audio, recovery, playout or curtain: those read the bridge,
    /// and this runs on pion's dispatcher), then a `source-list` of the session's windows as the last listing named
    /// them, so a window tab reads its title rather than its id. Nothing when the session holds no window.
    public func offerStatePayloads() -> [Data] {
        let (state, named) = lock.withLock { (session, session.windows.compactMap { listedSources[$0.source] }) }
        var out = [viewSetJSON(subs: [], focused: state.focused, state: state)]
        if !named.isEmpty { out.append(sourceListJSON(sources: named)) }
        return out
    }

    /// The `view-set` for one client: the session's STATE (`windows`, `focused`, `view`, `version`),
    /// each STREAMED window's live echo (`subs` — its RESOLVED prefs, never the throttled rate an
    /// unfocused window runs at; what its answer settled on; its delivery and audio) and the
    /// session-wide echoes. INTERNAL for the tests.
    func viewSetPayload(forClient clientId: String) -> Data {
        let (state, subs, active, rec, delayMin, delayMax) = lock.withLock {
            (session,
             session.streamed.compactMap { id in streams[id].map { Subscription(source: id, prefs: $0.fullPrefs) } },
             activeCodecsLocked(), recoveryOverrideBp, playoutDelayMinMs, playoutDelayMaxMs)
        }
        // READ OUTSIDE `lock`, like every other channelHub call here: it queries the bridge.
        let recovery = channelHub?.activeRecovery()
        // ONE snapshot: the two maps must describe the same instant, or a source could report `dc`
        // with no index.
        let delivery = channelHub?.videoDeliveryMaps() ?? (delivery: [:], indices: [:])
        return viewSetJSON(subs: subs, focused: state.focused, state: state, activeCodecs: active,
                           activeDelivery: delivery.delivery, dcIndices: delivery.indices,
                           audioState: audioStateFor(clientId: clientId),
                           recoveryOverrideBp: rec, activeRecovery: recovery,
                           playoutDelayMinMs: delayMin, playoutDelayMaxMs: delayMax,
                           curtainUp: CurtainController.shared.isUp)
    }

    /// Under `lock`: source id -> the codec its track's answer settled on. A source absent from the map
    /// has not resolved yet, and `viewSetJSON` then omits `activeCodec` entirely rather than guessing.
    private func activeCodecsLocked() -> [String: NegotiatedCodec] {
        streams.compactMapValues { $0.activeCodec }
    }

    /// The codec the client asked for on `id` (`.auto` when unknown). ChannelHub reads this when it
    /// creates a delivery track, so a track is offered the source's preference from the start rather
    /// than being switched a round trip later.
    public func codecPrefForSource(_ id: String) -> CodecPref {
        lock.withLock { streams[id]?.fullPrefs.codec ?? .auto }
    }

    /// Re-run the ownership election and attach or detach each source's audio sink accordingly.
    ///
    /// NO RENEGOTIATION HAPPENS HERE, which is what makes it cheap enough to run on every subscribe
    /// and unsubscribe: every subscribed source already holds an audio track, so ownership and mute
    /// are both SINK-level — the hidden-tab pause's mechanism, not the codec-change one.
    ///
    /// LOCK DISCIPLINE: the election runs under `lock`; every `channelHub` and encoder call is made
    /// OUTSIDE it. `SimManager.lock` and `ChannelHub.lock` are never held simultaneously.
    ///
    /// THE WHOLE ELECTION — ITS SNAPSHOT AND ITS ATTACH — RUNS ON THE HUB'S MEDIA QUEUE, entered with
    /// NO lock held (the queue's one precondition; its bodies take the hub's lock and this one).
    /// Ordered with the hidden-tab pause: the "delivering" read and the `addSink` it decides must not
    /// straddle a pause applying, or the pause drops a sink not yet attached and the attach lands on a
    /// paused client. And ordered with EACH OTHER: a snapshot taken before the queue let an election
    /// overtaken by a later one (a mute, then an unmute) apply its stale inputs last. Lock order is
    /// queue → `lock`, the order `setHidden` already takes from the pause. `broadcastViewSet` stays
    /// outside the queue.
    public func reconcileAudio() {
        guard let hub = channelHub else { broadcastViewSet(); return }
        electionWillEnterMediaQueueForTests?()
        hub.orderedWithMediaPause {
            lock.lock()
            // IN OPENING ORDER, which is what makes "first subscriber wins" mean anything — the state
            // keeps it (`streamedByOpening`) and `streams` (a dictionary) does not. Never the BAR's order:
            // dragging a tab must not move an application's sound (review I1, 2026-10-01).
            let ordered = session.streamedByOpening.compactMap { id -> AudioSource? in
                guard let stream = streams[id] else { return nil }
                return AudioSource(id: id,
                                   owner: stream.audioOwner)
            }
            let carriers = AudioOwnership.carriers(ordered)
            let encoders = streams.compactMapValues { $0.audioEncoder }
            let muted = audioMuted
            lock.unlock()
            for (sourceID, encoder) in encoders {
                let carries = carriers.contains(sourceID)
                for clientId in hub.subscribedClientIDs(forSource: sourceID) {
                    guard let sink = hub.audioSink(forClient: clientId, sourceID: sourceID) else { continue }
                    // A client whose hidden-tab pause is in force gets NO audio: the resume re-runs this.
                    let delivering = hub.deliversMedia(to: clientId)
                    if carries && delivering && !(muted[clientId]?.contains(sourceID) ?? false) {
                        encoder.addSink(sink)
                    } else {
                        encoder.removeSink(sink)
                    }
                }
            }
        }
        broadcastViewSet()
    }

    /// Start or stop sending one source's audio to ONE client.
    ///
    /// EVERY REQUEST GETS A REPLY, including one that changes nothing — the `set-source-size` rule.
    /// A source that refused to unmute otherwise looks broken forever, and the reply is the
    /// `view-set` that `reconcileAudio` ends with.
    public func setSourceAudio(sourceID id: String, enabled: Bool, requestedBy clientId: String) {
        lock.lock()
        if enabled {
            audioMuted[clientId]?.remove(id)
        } else {
            audioMuted[clientId, default: []].insert(id)
        }
        lock.unlock()
        reconcileAudio()
    }

    /// Tests: runs in `reconcileAudio` just before it enters the hub's media queue, with no lock held.
    /// Guarded by `lock`.
    var electionWillEnterMediaQueueForTests: (() -> Void)? {
        get { lock.withLock { _electionWillEnterMediaQueue } }
        set { lock.withLock { _electionWillEnterMediaQueue = newValue } }
    }
    private var _electionWillEnterMediaQueue: (() -> Void)?

    /// Tests: a subscribed source with an audio encoder and an owner, and no capture — what
    /// `subscribe` + `buildAndAttach` leave behind, without ScreenCaptureKit. Then the election runs.
    func installStreamForTests(sourceID id: String, target: SourceTarget, ownerPID: Int32?,
                               audioEncoder: any AudioEncoding) {
        let workspaceEpoch = channelHub?.currentDriverEpoch()
        lock.lock()
        session.open(id)
        driving = true
        let stream = SourceStream(sourceID: id, target: target, fullPrefs: defaultPrefs)
        if case .workspace = target { stream.workspaceEpoch = workspaceEpoch }
        stream.audioEncoder = audioEncoder
        stream.ownerPID = ownerPID
        streams[id] = stream
        lock.unlock()
        reconcileAudio()
    }

    /// Forget a departed client's mute set, so a later client reusing the id does not inherit it.
    private func forgetAudioMutes(clientId: String) {
        lock.lock(); audioMuted[clientId] = nil; lock.unlock()
    }

    /// What this client should be told about each subscribed source's audio.
    ///
    /// TWO FALSE STATES, AND THEY MUST NOT BE CONFLATED: muted is `sending: false` with NO owner,
    /// yielded is `sending: false` WITH one. They sound identical and the client renders them
    /// differently — one is a setting the user chose, the other a fact about the host they did not.
    private func audioStateFor(clientId: String) -> [String: AudioSubState] {
        lock.lock()
        // The election's order, as `reconcileAudio` reads it — the two must never disagree.
        let ordered = session.streamedByOpening.compactMap { id -> AudioSource? in
            guard let stream = streams[id] else { return nil }
            return AudioSource(id: id,
                               owner: stream.audioOwner)
        }
        let muted = audioMuted[clientId] ?? []
        lock.unlock()
        let owners = AudioOwnership.elect(ordered)
        var out: [String: AudioSubState] = [:]
        for (source, owner) in owners {
            let carries = owner == source
            out[source] = AudioSubState(sending: carries && !muted.contains(source),
                                        owner: carries ? nil : owner)
        }
        return out
    }

    /// Broadcast the current view set to all control peers (on any change).
    ///
    /// ONE PAYLOAD PER CLIENT, NOT ONE FOR ALL, since audio landed: the mute set is per client, so a
    /// single broadcast would tell every viewer about one viewer's muting. Everything else in the
    /// message is session-wide and identical across the loop.
    private func broadcastViewSet() {
        for clientId in channelHub?.controlClientIDs() ?? [] {
            sendViewSet(toClient: clientId)
        }
        // Every change of the state, `driving` included, ends in a broadcast: the bell watch follows it here.
        refreshBellWatch()
    }

    private func wireDockBadges() {
        dockBadges.onRing = { [weak self] sources in self?.channelHub?.sendWindowBell(sources: sources) }
        bellQueue.sync { bellKey = nil }
    }

    /// Give the Dock-badge watch the session's `win:` windows and their owners while SimManager is `driving` —
    /// nothing otherwise, which stops it. Queued, never done on the caller's thread.
    private func refreshBellWatch() {
        bellQueue.async { [weak self] in self?.refreshBellTargets() }
    }

    /// On `bellQueue`. Only when the SET of windows changed — a position, a rename or a tab drag changes none —
    /// and then ONE window-server copy at most: a streamed window's owner is its stream's (`ownerPID`, read when
    /// it was built), only the rest (minimized ones) are looked up, all together (review F5).
    private func refreshBellTargets() {
        let (order, known): ([String], [String: pid_t]) = lock.withLock {
            guard driving else { return ([], [:]) }
            let ids = session.windows.map(\.source).filter { $0.hasPrefix("win:") }
            var known: [String: pid_t] = [:]
            for id in ids { if let pid = streams[id]?.ownerPID { known[id] = pid } }
            return (ids, known)
        }
        let key = Set(order)
        guard key != bellKey else { return }
        bellKey = key
        var wids: [String: CGWindowID] = [:]
        for id in order where known[id] == nil {
            if case .window(let n)? = parseSourceID(id), let wid = CGWindowID(exactly: n) { wids[id] = wid }
        }
        let looked = wids.isEmpty ? [:] : windowOwnerPIDs(Set(wids.values))
        let targets = order.compactMap { id -> DockBadgeWatch.Target? in
            guard let pid = known[id] ?? wids[id].flatMap({ looked[$0] }) else { return nil }
            return DockBadgeWatch.Target(source: id, pid: pid)
        }
        dockBadges.setTargets(targets)
    }

    /// TEST-ONLY: wait for every queued `refreshBellWatch` to have handed the watch its targets.
    func flushBellRefreshForTests() { bellQueue.sync {} }

    /// Recompute what the liveness monitor watches, PARTITIONED BY KIND. A simulator is never polled here: its
    /// liveness is its capture's and its catalog state's (`simulatorStatuses`). Called
    /// after any change to the subscribed SET. `setTargets` starts/stops the poll timer as the set crosses
    /// empty. The partition is load-bearing: CGWindowID and CGDirectDisplayID are both UInt32, so one
    /// combined list would make a window and a display with the same number indistinguishable.
    private func refreshLivenessWatch() {
        let (wins, disps): ([CGWindowID], [CGDirectDisplayID]) = lock.withLock {
            var w: [CGWindowID] = []
            var d: [CGDirectDisplayID] = []
            for id in session.streamed where streams[id] != nil {
                switch parseSourceID(id) {
                case .window(let n): w.append(CGWindowID(n))
                case .display(let n): d.append(CGDirectDisplayID(n))
                case .workspace, .sim, nil: continue
                }
            }
            return (w, d)
        }
        liveness.setTargets(windows: wins, displays: disps)
    }

    /// Push the current per-window liveness snapshot to one client (control-open / claim). Empty when no window
    /// is subscribed — the client then treats every source as live. Runs OUTSIDE `lock`.
    ///
    /// Carries the source's NATIVE PIXEL size whenever its capture source knows one. LOAD-BEARING for Auto
    /// resolution: `pxW`/`pxH` are otherwise published only by `ScreenCaptureSource.onSizeChange`, which
    /// fires when capture STARTS and on a poll-detected size change — so a client that reconnects within
    /// the grace window (or a second client, or anyone subscribing to a source already being captured)
    /// never learned it, `autoScale` returned nil, and Auto silently never sent. Measured: on a pooled
    /// host, picking Auto after a manual 25% left the host at 25% and produced no `[encode]` line, while
    /// the identical sequence on a freshly started host worked.
    public func sendSourceStatus(toClient clientId: String) {
        // Snapshot the sources under `lock`, then build + send OUTSIDE it (SimManager.lock and
        // ChannelHub.lock are never held simultaneously).
        let sources: [String: StreamVideoSource] = lock.withLock {
            var out: [String: StreamVideoSource] = [:]
            for (id, stream) in streams { if let src = stream.source { out[id] = src } }
            return out
        }
        // Carries pxW/pxH whenever the capture source knows one. LOAD-BEARING for Auto resolution: those
        // are otherwise published only by ScreenCaptureSource.onSizeChange, which fires at capture start
        // and on a size change — so a client joining a LIVE capture would never learn the native size and
        // Auto would silently never send. Applies to displays exactly as it does to windows.
        let snap = liveness.snapshot()
        let withPixels = { (id: String, live: Bool) -> SourceStatus in
            guard let px = sources[id]?.nativePixelSize else { return SourceStatus(id: id, live: live) }
            return SourceStatus(id: id, live: live,
                                pxW: Int(px.width.rounded()), pxH: Int(px.height.rounded()))
        }
        let sims = simulatorStatuses().map { s -> SourceStatus in
            guard let px = sources[s.id]?.nativePixelSize else { return s }
            return SourceStatus(id: s.id, live: s.live, pxW: Int(px.width.rounded()), pxH: Int(px.height.rounded()),
                                simState: s.simState)
        }
        refreshSimulatorStatusCache()
        let statuses = snap.windows.map { withPixels(sourceID(windowID: Int($0.key)), $0.value) }
                     + snap.displays.map { withPixels(sourceID(displayID: Int($0.key)), $0.value) }
                     + sims
        channelHub?.sendControl(sourceStatusJSON(statuses: statuses), to: clientId)
    }

    // MARK: - negotiation-driven encoder

    /// Build (or rebuild) the source's encoder in the negotiated codec, then wire capture->encoder if BOTH are
    /// ready. Called from `ChannelHub.codecResolved` after the answer settles. Reuses a live encoder iff its codec
    /// matches (a returning client with the same browser); on a codec CHANGE it swaps in a fresh encoder and
    /// re-points the RUNNING capture source at it (`start(into:)` is idempotent on the stream and only swaps the
    /// sink). The injector is untouched — input focus survives. `commitStart` (the single capture-start) fires here
    /// only when the source already booted — otherwise `attach` fires it later; whichever completes second wins the
    /// start (both gate on `wirePlanLocked`). Finally tells ChannelHub the encoder exists so it (re)attaches the
    /// delivery sink.
    ///
    /// THE CAPTURE IS KEPT ACROSS A CODEC CHANGE, since 2026-09-04. It used to be replaced by a FRESH source with
    /// the old one stopped, and that stop killed the new stream: two SCStreams on one window share the captured
    /// application's connection (audio capture, 2026-09-03), and stopping one interrupts the other with `-3805`.
    /// Every codec switch in the latency campaign died that way — `frames=0/0` at the receiver while the bind, the
    /// subscription and the encoder all read healthy. See `ScreenCaptureSource.start(into:)`.
    ///
    /// LOAD-BEARING (Finding 1): `makeEncoder`/`removeAllSinks`/`commitStart` all run OUTSIDE `lock`. The lock is
    /// taken in TWO short holds: (#1) decide if a (re)build is needed + snapshot the stream/prefs; (#2) after building
    /// the new encoder outside the lock, re-fetch + re-check identity & codec-need, install + flip `started` false +
    /// return the wire plan. Teardown/start/notify happen after the lock is released. The single-start invariant is
    /// preserved: `wirePlanLocked` (called only inside hold #2) is the sole writer of `started` and flips it true in
    /// the same hold that returns a non-nil plan.
    public func ensureEncoder(sourceID id: String, codec: NegotiatedCodec) {
        if case .workspace?=parseSourceID(id),codec != .av1 {
            if let driver=channelHub?.currentDriver() {workspaceCapability(false,clientID:driver.clientId)}
            workspace.captureStatus("Apps experimental mode requires AV1; reconnect with a supported browser")
            return
        }
        typealias StartPlan = (source: StreamVideoSource, enc: VideoEncoding, prefs: VideoPrefs, focused: Bool)

        // Record what the answer SETTLED ON, in its own short hold — true the moment we are told, and
        // independent of whether a rebuild turns out to be needed. `view-set` reports it as `activeCodec`
        // so the client can see a pin that this browser refused.
        let codecChanged: Bool = lock.withLock {
            guard let s = streams[id], s.activeCodec != codec else { return false }
            s.activeCodec = codec
            return true
        }

        // Lock hold #1: decide whether a (re)build is needed and snapshot what we need to build the new encoder
        // OUTSIDE the lock. NOTHING is created here (no makeEncoder/removeAllSinks).
        let build: (stream: SourceStream, prefs: VideoPrefs)? = lock.withLock {
            guard let s = streams[id] else { return nil }
            guard s.encoder == nil || s.encoder!.codec != codec else { return nil }   // already the right codec → no build
            return (s, s.fullPrefs)
        }

        // OUTSIDE the lock: build the new encoder. The capture source is KEPT whether or not it has started —
        // `start(into:)` on a running source only swaps its sink (see the doc comment above).
        let newEnc: VideoEncoding? = build.map { makeEncoder(id, $0.prefs.fps, $0.prefs.bitrateBps, codec) }

        // Lock hold #2: re-fetch + re-check identity & codec-need, then install (or abandon) the build. Returns the
        // wire plan + the encoder to tear down OUTSIDE the lock. Guards an interleaved unsubscribe/re-subscribe (a
        // different stream object at `id`) or a racing ensureEncoder that already installed the right codec.
        let result: (plan: StartPlan?, oldEnc: VideoEncoding?, abandoned: Bool) = lock.withLock {
            guard let s = streams[id] else { return (nil, nil, newEnc != nil) }   // stream gone → abandon any build
            if let newEnc {
                guard s === build?.stream, s.encoder == nil || s.encoder!.codec != codec else {
                    // Different stream (unsub+resub) or codec already satisfied by a racing ensureEncoder → abandon OUR
                    // build. Still (re)wire only when it's the SAME stream (a fresh stream owns its own codec-resolve).
                    let plan: StartPlan? = (s === build?.stream) ? wirePlanLocked(s) : nil
                    return (plan, nil, true)
                }
                let oldEnc = s.encoder                    // the encoder we replace (removeAllSinks OUTSIDE the lock)
                s.encoder = newEnc
                wireIdleTicks(encoder: newEnc, source: s.source)
                s.started = false                         // a fresh encoder must be (re)started into
                return (wirePlanLocked(s), oldEnc, false)
            }
            // No build was needed: still (re)wire (the source may have just arrived) + let the delivery sink attach.
            return (wirePlanLocked(s), nil, false)
        }

        // OUTSIDE the lock: tear down the replaced (or abandoned) encoder, start the wire plan, notify ChannelHub.
        result.oldEnc?.removeAllSinks()                   // detach the old encoder's sinks before it deallocs
        if result.abandoned { newEnc?.removeAllSinks() }  // never installed → tear down what we built
        if let p = result.plan { commitStart(streamID: id, plan: p) }
        channelHub?.encoderReady(sourceID: id)            // let ChannelHub (re)attach the delivery sink
        if codecChanged {
            // A NEW ENCODER IS A NEW STREAM. On the DataChannel path the client must discard its
            // decoder state and the code's window for this source, or it would try to solve
            // equations against symbols from a stream that no longer exists — and mixing two ESI
            // spaces produces plausible garbage rather than an error.
            channelHub?.bumpVideoDelivery(sourceID: id)
            broadcastViewSet()                            // publish the new activeCodec — OUTSIDE the lock
        }
    }

    /// Under `lock`: return the single-start plan iff the source can now feed its encoder (both present, not yet
    /// started). Flips `started` so the SAME source can't be started twice from the two racing paths (attach + the
    /// codec-resolved `ensureEncoder`). Snapshots the refs so the caller can `commitStart` OUTSIDE the lock.
    private func wirePlanLocked(_ stream: SourceStream) -> (source: StreamVideoSource, enc: VideoEncoding, prefs: VideoPrefs, focused: Bool)? {
        guard let src = stream.source, let enc = stream.encoder, !stream.started else { return nil }
        stream.started = true
        return (src, enc, stream.fullPrefs, session.focused == stream.sourceID)
    }

    /// Start the capture source feeding its encoder at the focused-or-throttled rate + force an IDR. Runs OUTSIDE
    /// `lock` on the snapshotted refs from `wirePlanLocked` (the `started` flag guarantees this runs at most once
    /// per (source, encoder) generation).
    private func commitStart(streamID id: String, plan: (source: StreamVideoSource, enc: VideoEncoding, prefs: VideoPrefs, focused: Bool)) {
        let eff = plan.focused ? plan.prefs : throttledPrefs(plan.prefs, throttleFps: throttleFps, throttleBitrateBps: throttleBitrateBps)
        plan.source.setScale(eff.scale); plan.source.setFpsCap(eff.fps)
        // A source subscribed AFTER a policy update has to start at the CURRENT ratio, or it runs at
        // 100% while every sibling runs at the current fraction and the session exceeds its budget.
        let ratio = lock.withLock { fecMediaRatio }
        plan.enc.setFps(eff.fps)
        plan.enc.setBitrate(fecAppliedBitrate(requested: eff.bitrateBps, ratio: ratio))
        // Debug overlays (off by default) composite into a buffer they own just before encode.
        // `install` returns `plan.enc` itself when nothing is enabled, so the production path is
        // unchanged. ScreenCaptureSource holds its sink strongly, so no extra retain is needed here.
        // THE AUDIO SINK IS WIRED BEFORE start(into:), for the reason the video sink is: SCK begins
        // delivering as soon as capture starts, and a handler installed afterwards drops whatever
        // arrived in between. Captured WEAKLY — the capture source outlives an encoder across a
        // codec rebuild, and a strong capture here would pin a dead encoder for the source's life.
        let audioEncoder = lock.withLock { streams[id]?.audioEncoder }
        plan.source.onAudioFrame = { [weak audioEncoder] frame in audioEncoder?.encode(frame) }
        plan.source.start(into: FrameOverlaySink.install(on: plan.enc, sourceID: id))
        plan.enc.requestKeyframe()                        // IDR on attach (infinite GOP)
        // The election has to run once this source can actually produce audio; before `start` there
        // is nothing to attach a sink to.
        reconcileAudio()
    }

    /// Construct (but do NOT start) a capture source for `target` at `prefs`. Used by `buildAndAttach`; a codec
    /// rebuild no longer makes one (see `ensureEncoder`). Constructed with the FULL prefs; `commitStart` applies
    /// the runtime rate.

    /// Lets `[capture]` distinguish "the window did not change" from "the machine was too slow".
    /// WEAK on the source: the adapter outlives a capture source across a codec rebuild, and a strong
    /// capture here would pin a stopped source's SCStream for the life of the encoder.
    /// DROPPED IN THE main MERGE, deliberately and with the rest of its feature.
    ///
    /// This wired `[capture]`'s idle-tick and grid counters, which lived on the canvas branch's
    /// `WindowCaptureSource`. `main` replaced that type with `ScreenCaptureSource` (one class for
    /// windows and displays), and porting ~380 lines of pacing-investigation instrumentation into the
    /// renamed, diverged file was not worth the risk to the capture path every gate depends on.
    ///
    /// What went with it: `RDEV_CAPTURE_GRID`, `RDEV_CAPTURE_TIME_PROBE`, `RDEV_CAPTURE_PTS`,
    /// `RDEV_CAPTURE_QUEUE_DEPTH`, the SCK pool-buffer fix and the frame-arrival watchdog. The
    /// watchdog is the one worth rebuilding — AGENTS.md still lists per-source frame-flow liveness as
    /// a KNOWN GAP, and it addressed exactly that.
    private func wireIdleTicks(encoder: VideoEncoding?, source: StreamVideoSource?) {
        guard let adapter = encoder as? LLVEncoderAdapter else { return }
        adapter.nonCompleteTicks = nil
    }

    private func makeSource(target: SourceTarget, prefs: VideoPrefs) -> StreamVideoSource {
        switch target {
        case .workspace(let display): return WorkspaceCaptureSource(displayID:UInt32(display))
        case .window(let wid): return ScreenCaptureSource(windowID: CGWindowID(wid), scaleFactor: prefs.scale, fps: prefs.fps)
        case .display(let did): return ScreenCaptureSource(displayID: CGDirectDisplayID(did), scaleFactor: prefs.scale, fps: prefs.fps)
        case .simulator:
            // `buildAndAttach` builds a simulator's capture TOGETHER with its injector (one SimDisplayState).
            preconditionFailure("makeSource: a simulator's capture is built in buildAndAttach")
        }
    }

    // MARK: - grace-pool (Task 8)

    /// The (single) client left for real (`PeerHub.clientLeft`). Defer teardown: (re)arm a one-shot timer that
    /// tears every source down on expiry. Replacing any existing timer (rather than requiring `onClientBack`
    /// first) makes this idempotent under a double-fire. Safe to call with zero live streams — the eventual
    /// `teardownAllSources` is then just a no-op sweep.
    /// The client's tab went to the background (or came back): re-rate every subscribed source.
    ///
    /// LOCK DISCIPLINE, and it is the rule this whole type is built on: snapshot the streams and
    /// their prefs UNDER `lock`, then touch encoders and capture sources OUTSIDE it. `SimManager.lock`
    /// is never held across an encoder or source call.
    public func setHidden(_ h: Bool) {
        lock.lock()
        hidden = h
        let ratio = fecMediaRatio
        let focusedID = session.focused
        let work: [(enc: VideoEncoding?, src: StreamVideoSource?, prefs: VideoPrefs)] = streams.map { (id, stream) in
            (stream.encoder, stream.source,
             effectiveVideoPrefs(full: stream.fullPrefs, focused: id == focusedID, hidden: h,
                                 throttleFps: throttleFps, throttleBitrateBps: throttleBitrateBps))
        }
        lock.unlock()
        // Derived from `fullPrefs` every time and NEVER written back — see fecAppliedBitrate for why
        // that direction matters: writing the reduced value back would make the next view-set echo it
        // and the next reduction compound, ratcheting the bitrate down a step at a time while every
        // individual step looked correct.
        for w in work {
            w.enc?.setFps(w.prefs.fps)
            w.enc?.setBitrate(fecAppliedBitrate(requested: w.prefs.bitrateBps, ratio: ratio))
            w.src?.setScale(w.prefs.scale)
            w.src?.setFpsCap(w.prefs.fps)
        }
        print("[sources] visibility \(h ? "hidden" : "visible") — re-rated \(work.count) source(s)")
    }

    public func onClientGone() {
        if lock.withLock({ presentation == .nativeSimulators }) {
            stopStreamsKeepingSession()
            return
        }
        lock.lock()
        graceTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + .seconds(graceSeconds))
        t.setEventHandler { [weak self, weak t] in
            guard let self, let timer = t else { return }
            self.teardownAllSources(firedBy: timer)
        }
        graceTimer = t
        lock.unlock()
        t.resume()
    }

    /// The client returned before grace expired: cancel the pending teardown. The live capturers/encoders are
    /// untouched — a fresh negotiation re-resolves the codec and `ensureEncoder` reuses (matching codec) or
    /// rebuilds (codec change) per source; capturers are reused as-is either way. Safe to call with no timer
    /// armed (a no-op) — every PeerHub join/resume path calls this unconditionally.
    public func onClientBack() {
        lock.withLock { graceTimer?.cancel(); graceTimer = nil }
    }

    /// Grace expired with nobody driving: stop every stream — AND KEEP THE SESSION. That is the whole
    /// point (docs/superpowers/specs/2026-09-29-host-session-state-design.md): nothing is captured for
    /// nobody, and the next driver is reconciled back to exactly what was open. Until 2026-09-29 this
    /// reset the view set too, so a client arriving 10 s after the last one left found nothing.
    ///
    /// LOAD-BEARING lock discipline — snapshot `streams` under `lock`, then `stop()`/`invalidate()`
    /// OUTSIDE it. `firedBy` guards the GCD cancel/fire race: `DispatchSourceTimer.cancel()` does NOT
    /// retract a handler already dispatched, so a superseded timer's late fire must be a no-op.
    private func teardownAllSources(firedBy timer: DispatchSourceTimer) {
        let dead: [SourceStream] = lock.withLock {
            guard graceTimer === timer else { return [] }
            graceTimer = nil
            driving = false
            let all = Array(streams.values)
            streams.removeAll()
            return all
        }
        stopAndBroadcast(dead)
    }

    /// **STOP SHARING STOPS THE CAPTURES NOW** (`HostSession.stopStreams`, called by `SharingRoom.stop()`
    /// after every relay client has left): every stream stops at once and the grace timer those
    /// departures armed is cancelled — and the STATE is kept (windows, focus, view), unlike `endSession`.
    /// The grace protects a driver that may reconnect, and after Stop none can: without this the SCK
    /// streams ran ~10 s for nobody, the screen-recording indicator stayed lit and the encoders burned CPU.
    func stopRemoteStreams() {
        guard lock.withLock({ presentation != .nativeSimulators }) else { return }
        stopStreamsKeepingSession()
    }

    func stopStreamsKeepingSession() {
        let dead: [SourceStream] = lock.withLock {
            graceTimer?.cancel(); graceTimer = nil
            driving = false
            let all = Array(streams.values)
            streams.removeAll()
            return all
        }
        stopAndBroadcast(dead)
    }

    private func stopAndBroadcast(_ dead: [SourceStream]) {
        for s in dead {
            s.stop()                 // drains in-flight capture->encode (barrier) before the encoder invalidates
            s.encoder?.invalidate()  // deterministic VTCompressionSessionInvalidate; no-op for AV1Encoder
        }
        refreshLivenessWatch()       // nothing streams → stop the liveness poll
        broadcastViewSet()           // `subs` empty; `windows`, focus and view unchanged
    }

    // MARK: - focus + attach pipeline

    /// Re-rate the two affected streams and re-point input focus. `demote` drops to the throttle profile; `promote`
    /// goes to its full prefs and its injector receives input (nil for a window / a not-yet-booted source). Snapshots
    /// refs under `lock`, calls encoder/source/injector methods OUTSIDE it (never holds `lock` across those calls).
    private func applyFocus(demote: String?, promote: String?, routeInput: Bool = true) {
        lock.lock()
        let dStream = demote.flatMap { streams[$0] }
        let dEnc = dStream?.encoder; let dSrc = dStream?.source
        let dPrefs = dStream.map { effectiveVideoPrefs(full: $0.fullPrefs, focused: false, hidden: hidden,
                                                       throttleFps: throttleFps,
                                                       throttleBitrateBps: throttleBitrateBps) }
        let pStream = promote.flatMap { streams[$0] }
        let pEnc = pStream?.encoder; let pSrc = pStream?.source
        // Through effectiveVideoPrefs, NOT fullPrefs directly: a focus change while the tab is
        // hidden must not restore full rate to the newly-focused source.
        let pPrefs = pStream.map { effectiveVideoPrefs(full: $0.fullPrefs, focused: true, hidden: hidden,
                                                       throttleFps: throttleFps,
                                                       throttleBitrateBps: throttleBitrateBps) }
        let ratio = fecMediaRatio
        lock.unlock()
        // Both arms re-derive from `fullPrefs` (the request) times the current ratio — never from
        // whatever the encoder was last set to. See fecAppliedBitrate for why that direction matters.
        if let e = dEnc, let p = dPrefs { e.setFps(p.fps); e.setBitrate(fecAppliedBitrate(requested: p.bitrateBps, ratio: ratio)); dSrc?.setScale(p.scale); dSrc?.setFpsCap(p.fps) }
        if let e = pEnc, let p = pPrefs { e.setFps(p.fps); e.setBitrate(fecAppliedBitrate(requested: p.bitrateBps, ratio: ratio)); pSrc?.setScale(p.scale); pSrc?.setFpsCap(p.fps) }
        if routeInput { routeFocusedSource(promote) }
    }

    private func routeFocusedSource(_ source: String?, activation: String? = nil,
                                    terminal: Bool = false, attachment: Bool = false) {
        let snapshot: (UInt64, InputInjector?, String?)? = lock.withLock {
            if attachment && scopedTerminalInput { return nil }
            guard terminal || session.focused == source else { return nil }
            let expectedFocus = session.focused
            let inj = source.flatMap { streams[$0]?.injector }
            let identity = inj.map(ObjectIdentifier.init)
            if !hasFocusRoutingPlan || routedSource != source || routedInjector != identity || activation != nil {
                focusRoutingGeneration &+= 1
            }
            hasFocusRoutingPlan = true; routedSource = source; routedInjector = identity
            scopedTerminalInput = terminal
            return (focusRoutingGeneration, inj, expectedFocus)
        }
        guard let (generation, inj, expectedFocus) = snapshot,
              let route = channelHub?.prepareSourceFocus(source: source, revision: generation, activation: activation) else { return }
        focusQueue.async { [weak self] in
            guard let self else { return }
            func current() -> Bool {
                let currentSource = self.lock.withLock {
                    self.focusRoutingGeneration == generation && self.session.focused == expectedFocus &&
                        (terminal || source.flatMap { self.streams[$0]?.injector } === inj)
                }
                return currentSource && self.channelHub?.sourceFocusIsCurrent(route) == true
            }
            guard current() else { return }
            // No manager/hub lock is held while waiting for the outgoing queue or AX. A fresh native
            // activation also drains a same-injector route, including ownership A→B→A.
            if let outgoing = self.channelHub?.beginInjectorSwitch(to: inj, forceDrain: activation != nil) {
                let drained = DispatchSemaphore(value: 0)
                outgoing.drainForFocusChange { drained.signal() }
                drained.wait()
            }
            guard current() else { return }
            inj?.raise()
            guard current() else { return }
            if activation != nil, inj?.awaitFrontmost() == false {
                self.channelHub?.failSourceFocus(route, error: "focus-unavailable")
                return
            }
            guard current() else { return }
            if self.channelHub?.commitSourceFocus(route, injector: inj) == true {
                CursorOverlayState.shared.setFocused(source)
            }
        }
    }

    /// Attach the capture source + injector to the stream's encoder. Guarded by an
    /// IDENTITY check (`streams[id] === stream`): an unsubscribe-then-resubscribe of the same source replaces the
    /// stream object, so a superseded boot commits into nothing and tears down what it built (latest-wins per source,
    /// replacing Milestone A's global `swapQueue` barrier).
    private func buildAndAttach(stream: SourceStream, target: SourceTarget) async {
        channelHub?.broadcastControl(simStatusJSON(udid: "", phase: "attaching", message: nil))

        // TARGET-SPECIFIC PREPARATION — and it is the ONLY thing that branches here. A window may need
        // waking and pulling on screen before it can be captured or clicked; a display is always exactly
        // where it is and always has a backing surface, so both steps answer problems it does not have.
        if case .window(let wid) = target {
            // Wake a minimized window before capture — SCK yields no frames for a window with no backing
            // surface. Best-effort + unconditional (a no-op when already on-screen); a failure just leaves the
            // spec-1 "no video" overlay + the Accessibility note surfaced below. Runs OUTSIDE any lock and
            // touches only the wid + a fresh AX tree.
            if !WindowAX.unminimize(windowID: CGWindowID(wid)) && !AXIsProcessTrusted() {
                print("[window] un-minimize skipped for wid \(wid): Accessibility permission absent")
            }
            // Pull a partially off-screen window fully on screen. Its off-screen strip captures and streams
            // fine, but the window server hit-tests clicks against ON-SCREEN geometry, so that part would be
            // dead to input. Best-effort, and a no-op when the window is already fully visible. MainActor:
            // it reads NSScreen. Runs OUTSIDE any lock, like the unminimize above.
            await MainActor.run { _ = WindowAX.nudgeOnScreen(windowID: CGWindowID(wid)) }
        }

        // EVERYTHING BELOW IS SHARED. It used to live inside the `.window` arm, which made adding a second
        // target a trap: a `.display` arm that skipped it built no source, wired no size callback and
        // attached nothing, while the transport still negotiated a track perfectly and reported healthy —
        // observed as `bind … selected AV1` beside `fec: media 0 pkts` and no capture line at all.
        let p = lock.withLock { stream.fullPrefs }
        let sizeSourceID = stream.sourceID
        let reportSize: (CGSize, CGFloat) -> Void = { [weak self] size, backingScale in
            self?.sourceSizeChanged(sizeSourceID, size: size, scale: backingScale)
        }
        let newSource: StreamVideoSource
        let newInjector: InputInjector?
        if case .simulator(let udid) = target {
            let display = SimDisplayState()
            let simulators = self.simulators
            let control = simulatorControl
            let capture = SimulatorCaptureSource(
                scaleFactor: p.scale, fps: p.fps, display: display,
                attach: { q, s, f, pr in simulators?.attachFramebuffer(udid, queue: q, surface: s, frame: f, properties: pr) },
                // Every read is logged with what it saw: the picture turns only on a read, so "the picture did not
                // turn" is either no read after the rotation or a read that still saw the old one.
                readDisplay: {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let info = control.displayInfo(udid: udid)
                    let ms = (DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
                    print("[sim] display \(udid): \(info.map { "\($0.rotation)" } ?? "unreadable") (\(ms) ms)")
                    return info
                },
                pointScale: lock.withLock { simInfos[udid].map { $0.w > 0 ? Double($0.pxW) / Double($0.w) : 1 } } ?? 3)
            capture.onSizeChange = reportSize
            capture.onLiveChange = { [weak self] live in self?.simulatorLive(sizeSourceID, live) }
            newSource = capture
            let points = lock.withLock { simInfos[udid].map { ($0.w, $0.h) } } ?? (402, 874)
            let epoch = stream.nativeEpoch
            newInjector = SimulatorInputInjector(udid: udid, connect: { simulators?.connectHID(udid) }, connectScroll: { simulators?.connectScrollHID(udid) }, display: display,
                control: control, nativePointW: points.0, nativePointH: points.1,
                isInputCurrent: { [weak self, weak stream] in
                    guard let epoch else { return true }
                    guard let self, let stream, self.channelHub?.currentDriverEpoch() == epoch else { return false }
                    return self.lock.withLock { self.presentation == .nativeSimulators && self.streams[stream.sourceID] === stream }
                })
        } else {
            newSource = makeSource(target: target, prefs: p)
            (newSource as? ScreenCaptureSource)?.onSizeChange = reportSize
            // BOTH window targets are input-capable through the same global-CGEvent injector. nil (a window whose
            // pid is unresolvable, or a display that is gone) → video-only, never a zero frame.
            if let capture=newSource as? WorkspaceCaptureSource {
                capture.onSizeChange = { [weak self] w,h in reportSize(CGSize(width:w,height:h),1);self?.workspace.captureStatus(nil)}
                capture.onError = { [weak self] error in
                    self?.workspace.captureStatus(error.localizedDescription)
                }
                let ownership = WorkspaceInputOwnership(epoch: stream.workspaceEpoch,
                    current: { [weak hub = channelHub] in hub?.currentDriverEpoch() })
                newInjector=WindowInputInjector(target:target,workspaceAdmission:{ [weak capture] x,y in capture?.hitAt(normalizedX:x,y:y) ?? false},workspaceReady:{ [weak capture] in ownership.isCurrent && capture?.inputReady == true },workspacePost:{ [weak hub = channelHub] event in
                    hub?.performInput(ifCurrentEpoch: ownership.epoch) { event.post(tap: .cghidEventTap) } ?? false
                })
            } else {newInjector = WindowInputInjector(target: target)}
        }
        // attach() raises the window (before routing input) when it commits + is focused. Only surface the
        // Accessibility prompt/note if attach COMMITTED (not superseded by a racing re-subscribe) — and
        // LAST, so attach's streaming(nil) can't clobber it (phase "error" is the only phase the client
        // renders a custom message on; video streams regardless of the permission).
        let committed = attach(stream: stream, source: newSource, injector: newInjector,
                               streamingStatus: simStatusJSON(udid: "", phase: "streaming", message: nil))
        if committed, case .window = target {
            WindowInputInjector.ensureAccessibilityPrompt { [weak self] note in
                self?.channelHub?.broadcastControl(simStatusJSON(udid: "", phase: "error", message: note))
            }
        }
    }

    /// Commit a freshly-built capture source (+ optional injector) into the stream under the identity re-check,
    /// then — IF the encoder already exists (codec resolved) — start it feeding the stream's OWN encoder. The
    /// capture-start is gated on `wirePlanLocked`: at attach time the encoder may still be nil (the codec answer
    /// hasn't settled), in which case the start is DEFERRED to `ensureEncoder` (whichever of boot/codec-resolve
    /// completes second wins the single start). Focus routing (injector) does NOT depend on the encoder, so it is
    /// re-derived here as before. If superseded (identity re-check fails), tear down what we built.
    /// Returns true if this build COMMITTED into the stream (not superseded) — the `.window` caller gates
    /// the Accessibility prompt on it so a superseded attempt doesn't surface a stray note.
    @discardableResult
    private func attach(stream: SourceStream, source newSource: StreamVideoSource, injector newInjector: InputInjector?, streamingStatus: Data) -> Bool {
        let plan: (oldSource: StreamVideoSource?, oldInjector: InputInjector?)? = lock.withLock {
            guard streams[stream.sourceID] === stream else { return nil }   // superseded by a re-subscribe → abandon
            let oldSource = stream.source; let oldInjector = stream.injector
            stream.source = newSource; stream.injector = newInjector
            wireIdleTicks(encoder: stream.encoder, source: newSource)
            return (oldSource, oldInjector)
        }
        guard let plan else {
            newSource.stop(); return false   // superseded → tear down what we built
        }
        plan.oldSource?.stop()     // stop any prior capture OUTSIDE the lock
        // Start feeding the encoder ONLY if it already exists (codec resolved). Re-checking under the lock right
        // before the start closes the stale-snapshot window: `wirePlanLocked` reads focus/prefs at that instant, so
        // a source that lost focus mid-boot starts throttled. nil ⇒ the codec answer hasn't settled yet; the start
        // is deferred to `ensureEncoder`. `started` makes this at-most-once regardless of which path fires it.
        let startPlan = lock.withLock { wirePlanLocked(stream) }
        if let sp = startPlan { commitStart(streamID: stream.sourceID, plan: sp) }
        if let capture = newSource as? SimulatorCaptureSource { startNative(capture, source: stream.sourceID) }

        // Input routing is encoder-independent — re-derive focus (may have moved during the boot) and route input
        // ONLY if THIS source is the current focus; a source that lost focus mid-boot must not clobber the shared injector.
        routeFocusedSource(stream.sourceID, attachment: true)
        channelHub?.broadcastControl(streamingStatus)
        return true
    }
}

public extension SimControlDelegate {
    func workspaceCapability(_ enabled:Bool,clientID:String) {}
    func workspaceConnectionCapability(_ enabled:Bool,clientID:String,connectionID:ObjectIdentifier) {workspaceCapability(enabled,clientID:clientID)}
    func workspaceRequest(action:String,app:String?,clientID:String) {}
}
