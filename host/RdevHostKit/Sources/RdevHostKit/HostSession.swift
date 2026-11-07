import Foundation
import LLVCore
import RdevCore

/// **THE SESSION — what every client of this Mac shares** (docs/sources-and-focus.md, "The session's
/// lifetime"): the terminals, the window state (`SimManager`), `ChannelHub`, the relay clients' `PeerHub`
/// and the socket clients. **IT OUTLIVES SHARING**: the app creates it at launch and ends it at quit,
/// and Start/Stop Sharing only open and close the door (`SharingRoom`). The harness's `RdevHostRuntime`
/// builds and ends both together, so its lifecycle is unchanged. Creating it is cheap: no capture and no
/// shell until a client asks.
///
/// LOAD-BEARING, as `RdevHostRuntime` says of itself: nothing here runs a run loop.
///
/// `@unchecked Sendable`: every member is itself thread-safe, and the app reads `tabCount` on the main
/// thread while clients drive the session from theirs.
public final class HostSession: @unchecked Sendable {
    let terminals: TerminalManager
    public var hostUpdates: HostUpdates { channelHub.hostUpdates }
    let channelHub: ChannelHub
    let peerHub: PeerHub
    let simManager: SimManager?
    let sockets: SocketClients
    /// The paste folder (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §6), the session's for its
    /// whole life: emptied at launch and at `end`, swept every hour and after every save.
    let pasteStore: PasteStore
    /// The driver's pastes and drops, received and delivered; `channelHub.paste`.
    let paste: PasteReceiver
    /// Every 5 s: a stalled delivery is abandoned (§3); every hour, the folder is swept (§6). Off every hub
    /// and manager lock — both calls only queue work onto the paste queue.
    private let pasteTimer: DispatchSourceTimer

    // Retained for the runtime's lifetime. Several of these are load-bearing retains, not
    // tidiness: TestPatternSource's timer only weakly captures self, so dropping the reference
    // deallocates it and no frames are ever encoded (silently breaks the headless smoke).
    // Concrete, not `SimVideoSource`: `rebuildSharedEncoder` calls `retarget(to:)`, which is the test
    // pattern's own affordance and deliberately not part of the protocol every capture source conforms to.
    private var testPatternSource: TestPatternSource?
    /// The headless path's Opus encoder. LOAD-BEARING retain for the reason `overlaySink` is one:
    /// `TestPatternSource.onAudioFrame` captures it WEAKLY, so an unretained encoder would leave the
    /// tone emitting into nothing — a silent gate rather than a crash.
    private var testPatternAudioEncoder: OpusEncoderAdapter?
    /// LOAD-BEARING retain, exactly like `testPatternSource`: `TestPatternSource.sink` is WEAK, so a
    /// FrameOverlaySink referenced only by the pattern deallocates immediately and the pattern emits
    /// into nothing — a frozen client, not a crash. nil whenever no overlay is installed.
    private var overlaySink: VideoFrameSink?

    public init(config: HostConfig) {
        PionBridge.start()

        let initialInjector: InputInjector? = config.useTestPattern ? LoggingInjector() : nil

        // THE libaom SPEED/QUALITY KNOB, EXPOSED FOR MEASUREMENT. `cpu-used` runs 0 (slowest, best
        // quality per bit) to 12 (fastest, worst), and the engine's control profile pins 12 — LLV's
        // own measured configuration, adopted wholesale at the cutover and never re-derived for
        // rdev's resolutions. It is the single largest quality lever on this path and the encode
        // budget is nowhere near spent: measured 1.0 ms p50 against a 16.7 ms frame at 60 fps.
        //
        // IT IS A MEASUREMENT KNOB, NOT A TUNED DEFAULT. Unset leaves `RealtimeVideoEncoder`'s own
        // default, so behaviour is unchanged and cannot drift from LibaomTuningProfile; choosing a
        // value — per resolution or otherwise — is still separate, measured work. An out-of-range
        // or unparseable value is REFUSED loudly rather than clamped: a typo that silently encoded
        // at a different speed than asked would corrupt exactly the comparison this exists to serve.
        //
        // Swift reads the environment live, so unlike the Go side's RDEV_LLV_* variables this one
        // has no snapshot-at-init trap.
        var cpuUsedOverride: Int?
        if let raw = ProcessInfo.processInfo.environment["RDEV_LIBAOM_CPU_USED"]?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            // THE FLOOR IS 0 AGAIN: libaom's full range. It was 7 for one day, on the measured
            // grounds that 5 and 6 segfaulted in motion search -- which they did, but the cause was
            // rdev's own malformed `kf_max_dist = 0`, not the speed setting. With that fixed
            // (CAOMBridge.c, infinite-GOP comment) the whole range encodes.
            //
            // LOWER IS SLOWER AND BETTER, and the budget is barely touched: encode measured ~1.0 ms
            // p50 against a 16.7 ms frame at 60 fps, so there is room to spend. Choosing a value per
            // resolution is still separate, measured work -- this is the knob that makes measuring
            // it possible without an engine edit.
            guard let value = Int(raw), (0...12).contains(value) else {
                fatalError("RDEV_LIBAOM_CPU_USED=\(raw) is not an integer in 0...12")
            }
            cpuUsedOverride = value
            print("[encode] libaom cpu-used pinned to \(value) "
                + "(default \(RealtimeVideoEncoder.defaultCpuUsed); lower is slower and better)")
        }
        let cpuUsed = cpuUsedOverride ?? RealtimeVideoEncoder.defaultCpuUsed

        // Eager encoder for the headless TestPattern ("test") path ONLY, and AV1 because it is
        // rdev's most-preferred codec — the one a track resolves to unless the answer excludes it.
        // When it does, `codecResolved` rebuilds through `rebuildSharedEncoder` below, so this is a
        // starting point rather than a decision.
        let encoder: VideoEncoding = LLVEncoderAdapter(fps: config.fps, bitrateBps: config.bitrateBps,
                                                      label: "test", cpuUsed: cpuUsed)

        // One encoder per SOURCE, built once the track's codec is reported. `label` is the source
        // id, which is what tells the [encode] resolution lines apart.
        //
        // THE SWITCH IS GONE BECAUSE THE CHOICE IS GONE. `VTEncoder` (H.264/H.265, VideoToolbox) and
        // `AV1Encoder` (SVT-AV1 through rdev's own Go bridge) were both deleted with that bridge:
        // THE CODEC IS HONOURED. It was ignored while rdev was AV1-only — the bridge reported AV1
        // for every track, so building anything else was unreachable — and the placeholder logged a
        // line for whoever re-added negotiation. This is that moment.
        //
        // IGNORING IT IS THE WORST AVAILABLE FAILURE, which is why it is worth a comment rather
        // than a one-word diff: the track negotiates H.264, the encoder produces AV1, and rdev ships
        // AV1 bytes under an H.264 payload type. The host encodes at full rate, RTP flows,
        // FlexFEC negotiates, every state reads healthy — and the browser decodes nothing. That is
        // this project's signature failure, and the forced-codec gate exists because no unit test
        // in either language can see it.
        let makeEncoder: (String, Int, Int, NegotiatedCodec) -> VideoEncoding = { label, f, b, codec in
            LLVEncoderAdapter(fps: f, bitrateBps: b, label: label, cpuUsed: cpuUsed, codec: codec)
        }

        let terminals = TerminalManager(cols: 80, rows: 24)
        // tmux terminals need a tmux binary; the packaged app's PATH has no Homebrew in it, which is
        // why `locate` looks there first. Without one the palette says so and nothing else changes.
        terminals.tmux = TmuxRunner.locate()
        print(terminals.tmux.map { "[tmux] using \($0.path)\($0.socketArgs.isEmpty ? "" : " " + $0.socketArgs.joined(separator: " "))" }
              ?? "[tmux] not found — tmux terminals unavailable")

        var patternSource: TestPatternSource?
        var patternAudio: OpusEncoderAdapter?
        var overlay: VideoFrameSink?
        if config.useTestPattern {
            // The timecode stamp is 576x24 px and does not fit the default 320x240 pattern, so the
            // probe path gets a larger one. Unconditionally keeping 320x240 would leave the probe
            // silently unstamped.
            let src = FrameOverlaySink.probeEnabled ? TestPatternSource(width: 640, height: 480)
                                                    : TestPatternSource()
            let sink = FrameOverlaySink.install(on: encoder, sourceID: nil)
            overlay = sink        // LOAD-BEARING retain — see the property comment
            // THE TONE, for scripts/gate-audio-negotiation.sh. Wired BEFORE `start`, because the
            // pattern only arms its audio timer when a handler is already present — an audio path
            // that silently never starts is the failure this whole gate exists to detect.
            let audioEnc = OpusEncoderAdapter(sourceID: "test")
            patternAudio = audioEnc   // LOAD-BEARING retain, exactly like `overlaySink`
            let videoOnlyInstrument = ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1"
                && ProcessInfo.processInfo.environment["RDEV_AV1_REFERENCE_TEST_VIDEO_ONLY"] == "1"
            // The single-stream network impairment instrument learns its source from
            // the first RTP packet. A test tone arriving first would select audio.
            if !videoOnlyInstrument {
                src.onAudioFrame = { [weak audioEnc] frame in audioEnc?.encode(frame) }
            }
            if ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1",
               let pauseFile = ProcessInfo.processInfo.environment["RDEV_AV1_REFERENCE_TEST_PAUSE_FILE"] {
                var paused = false
                src.shouldEmitVideoFrame = {
                    let next = FileManager.default.fileExists(atPath: pauseFile)
                    if next != paused {
                        paused = next
                        print("[av1-ref-capture] \(paused ? "paused" : "resumed")")
                    }
                    return !paused
                }
            }
            src.start(into: sink)
            patternSource = src   // LOAD-BEARING retain — see the property comment
        }

        let channelHub = ChannelHub(terminals: terminals, injector: initialInjector, encoder: encoder)
        if let agents = AgentProviders.make() { channelHub.installAgents(agents) }
        channelHub.sharedAudioEncoder = patternAudio

        var simManager: SimManager?
        if !config.useTestPattern {
            let initialPrefs = VideoPrefs(fps: config.fps, scale: config.scale,
                                          bitrateBps: config.bitrateBps)
            let mgr = SimManager(makeEncoder: makeEncoder, channelHub: channelHub,
                                 defaultPrefs: initialPrefs, bitrateCap: config.bitrateCapBps,
                                 throttleFps: config.throttleFps,
                                 throttleBitrateBps: config.throttleBitrateBps,
                                 // LAZY: nothing of CoreSimulator loads until the first listing, so a Mac
                                 // without Xcode pays nothing (docs/superpowers/specs/2026-10-13-simulator-sources-design.md).
                                 simulators: SimulatorCatalog())
            // ORDER MATTERS: simDelegate before isVideoSubscribed.
            channelHub.simDelegate = mgr
            channelHub.isVideoSubscribed = { [weak mgr] in mgr?.hasSubscription ?? false }
            simManager = mgr
        }

        // The budget every session divides between media and FEC. It is the bitrate CAP, which no
        // client request can exceed by definition — see fecAppliedBitrate for why the controller's
        // absolute figure has to become a ratio. Zero while recovery is `nack-rtx` (the default):
        // the engine refuses a non-zero budget outside FlexFEC mode.
        // PASSED UNCONDITIONALLY, and the engine drops it when recovery is `nack-rtx`. Gating it on
        // RDEV_LLV_RECOVERY here would put a SECOND reader of that variable in a second language —
        // the very duplication the cap itself is passed across the ABI to avoid — and the two could
        // then disagree about which mode is running.
        let peerHub = PeerHub(channelHub: channelHub, fps: config.fps,
                              totalRTPBudgetBps: UInt32(clamping: config.bitrateCapBps))

        // THE PASTE FOLDER (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §6): the config's — the
        // app passes its profile's, `RDEV_PASTE_DIR` overrides it — else this process's own Caches folder (the
        // harness's is `dev.rdev.host`). Emptied at launch: a run that ended cleanly left nothing there, so
        // anything left is a crash's.
        let pasteStore = PasteStore(directory: config.pasteDirectory.map { URL(fileURLWithPath: $0) }
            ?? PasteStore.defaultDirectory(bundleID: Bundle.main.bundleIdentifier ?? "dev.rdev.host"))
        pasteStore.prepareAtLaunch()
        // WEAK captures: the hub holds the receiver, so a receiver holding the hub — or the window state or
        // the terminals, which hold the hub — would be a cycle that outlives the session.
        let paste = PasteReceiver(store: pasteStore, destinations: .init(
            typeIntoTerminal: { [weak terminals] pieces, tab in terminals?.typePaste(pieces, into: tab) ?? false },
            windowTarget: { [weak simManager] source in simManager?.pasteTarget(sourceID: source) },
            writePasteboard: { content, done in WindowPasteboard.write(content, completion: done) },
            // A REAL drop at the point, onto that window only; `false` and the receiver pastes instead (§5).
            drop: { content, point, window, cancelled, done in
                HostDrop.perform(content, at: point, targetWindowID: window, isCancelled: cancelled, completion: done)
            }),
            reply: { [weak channelHub] data, clientId in channelHub?.sendBulk(data, to: clientId) })
        // Before any client: nothing can reach the hub until `SocketClients` and `PeerHub` admit one.
        channelHub.paste = paste
        let pasteTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        pasteTimer.schedule(deadline: .now() + 5, repeating: 5)
        var ticks = 0   // the handler never runs concurrently with itself
        pasteTimer.setEventHandler { [weak paste] in
            guard let paste else { return }
            paste.checkStalls()
            ticks += 1
            if ticks % 720 == 0 { paste.sweepFolder() }     // 720 × 5 s: hourly
        }
        pasteTimer.resume()

        self.terminals = terminals
        self.channelHub = channelHub
        self.simManager = simManager
        self.peerHub = peerHub
        self.sockets = SocketClients(hub: channelHub)
        self.pasteStore = pasteStore
        self.paste = paste
        self.pasteTimer = pasteTimer
        self.testPatternSource = patternSource
        self.testPatternAudioEncoder = patternAudio
        self.overlaySink = overlay

        if config.useTestPattern {
            // Rebuild the shared encoder in whatever the answer settled on, and re-point the pattern at it.
            //
            // Retargeting here — before ChannelHub stores the result — is safe because ChannelHub binds
            // the return value to a strong local for the whole swap and then assigns it to `encoder`. So
            // `fresh` is retained continuously from the moment it is created, which matters:
            // TestPatternSource holds its sink WEAKLY, and an unretained encoder would leave the pattern
            // emitting into nothing (a frozen client, not a crash).
            // fps/bitrate are captured by VALUE so the closure holds no reference to `self.config`.
            let fps = config.fps, bitrateBps = config.bitrateBps
            channelHub.rebuildSharedEncoder = { [weak self] codec in
                guard let self, let src = self.testPatternSource else { return nil }
                let fresh = makeEncoder("test", fps, bitrateBps, codec)
                let sink = FrameOverlaySink.install(on: fresh, sourceID: nil)
                // Retain BEFORE retarget, for the same reason the comment above `overlaySink` gives:
                // the pattern's sink is weak, so the new decorator must already be owned when the
                // pattern starts pointing at it.
                self.overlaySink = sink
                src.retarget(to: sink)
                return fresh
            }
        }
    }

    /// Take a window-less client's socket — the app's local window (docs/desktop-app.md, "The local
    /// window"). After `end` it is refused: `SocketClients.closeAll` stops accepting.
    public func accept(_ socket: MessageSocket) { sockets.accept(socket) }
    public func acceptLocal(_ socket: MessageSocket) -> LocalSimulatorSession { sockets.acceptLocal(socket, manager: simManager) }

    /// Open terminal tabs — what keeps the app alive with no window open (`AppLifecycle`).
    public var tabCount: Int {
        let state=simManager?.localSimulatorState.0
        return terminals.tabCount + (state?.windows.filter { NativeSimulatorPolicy.isSimulator($0.source) }.count ?? 0) + (state?.agents.count ?? 0)
    }

    /// The terminal tabs as the app saves them for its next launch (docs/terminal.md, "Tabs that come back").
    public func savedTerminalTabs() -> SavedTerminalTabs {
        var (saved,ids)=terminals.savedTabState()
        saved.agents=simManager?.savedAgentTabs(terminalIDs:ids)
        return saved
    }

    /// The app's launch: the tabs it saved come back — only into a session with none, before any client.
    /// Returns how many did.
    @discardableResult
    public func restoreTerminalTabs(_ saved: SavedTerminalTabs) -> Int {
        let saved = saved.restoring(graphicalAgents: ProductFeatures.graphicalAgents)
        guard terminals.isEmpty,simManager?.localSimulatorState.0.agents.isEmpty != false else{return 0}
        let restored=terminals.restoreTabs(saved)
        if let agents=saved.agents {
            channelHub.agents?.restoreKnownTabs(agents.tabs.map(\.id))
            simManager?.restoreAgentTabs(agents,terminalIDs:restored)
        }
        return restored.count
    }

    /// Stop Sharing: every capture stops NOW, the window state stays (`SimManager.stopStreamsKeepingSession`).
    func stopStreams() { simManager?.stopRemoteStreams() }

    /// **THE SESSION ENDS** — a quit, or the harness stopping. Every socket client is closed and no new
    /// one is admitted. Every shell is KILLED and every tmux tab DETACHED (its session keeps running).
    /// Every stream stops and the window state is forgotten. Idempotent.
    ///
    /// Until 2026-09-30 this was Stop Sharing's (docs/superpowers/specs/2026-09-29-host-session-state-design.md,
    /// amended by 2026-09-30-transport-generic-protocol-local-window-design.md). Dropping the managers
    /// alone left the shells running with nothing attached: nothing closed the tabs, and PtyProcess had
    /// no deinit.
    public func restoreWorkspace(forQuit:Bool=false,completion:@escaping @Sendable(String?)->Void) {
        guard let simManager else{completion(nil);return}
        simManager.restoreWorkspace(forQuit:forQuit,completion:completion)
    }
    public func end() {
        channelHub.agents?.close()
        sockets.closeAll(reason: "the session ended")
        terminals.closeAll()
        simManager?.endSession()
        testPatternSource = nil
        // THE PASTE FOLDER IS EMPTIED AT QUIT (§6). Every delivery is abandoned FIRST, and `abandonAll`
        // waits for the paste queue: a partial still being written behind the emptying would outlive the quit.
        pasteTimer.cancel()
        paste.abandonAll()
        pasteStore.emptyAll()
    }
}
