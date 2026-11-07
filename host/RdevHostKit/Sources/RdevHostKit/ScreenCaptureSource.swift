import AppKit
import Foundation
import CoreVideo
import ScreenCaptureKit
import RdevCore

/// Captures ONE on-screen subject via ScreenCaptureKit — a window today, a whole display once
/// `SourceTarget.display` is wired through — and feeds each frame to that source's encoder. Video-only
/// (input lives in `WindowInputInjector`). Requires the Screen Recording TCC permission.
///
/// ONE CLASS FOR BOTH TARGETS, DELIBERATELY. Nearly everything here is target-agnostic and was
/// expensive to get right: the `63/64 x 1/fps` minimumFrameInterval rule, queueDepth with clamp
/// readback, grid mode, the frame-arrival stall watchdog, PTS stamping, the SCStreamDelegate
/// stream-died channel, and the pool-recreate-on-scale-change rule. A second capture class would fork
/// from this one on the next fix while every gate stayed green — the same reasoning that keeps the
/// FlexFEC controller policy out of this repo.
/// @unchecked Sendable: `sink` and the depth-1 encode handoff are guarded by `handoffLock` (the
/// SCStream callback writes it, the encode queue reads it); `stream`/`stopped` by `lifecycleLock`;
/// `scaleFactor`/`fps` by `paramLock`;
/// `sizeTimer`/`lastPointSize` by `sizeQueue`.
public final class ScreenCaptureSource: NSObject, SimVideoSource, StreamVideoSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let target: SourceTarget

    /// The window id, for the WINDOW-ONLY paths (the SCShareableContent lookup, the size poll's
    /// on-screen check, the log lines). Every read is already inside a `.window` branch, so a display
    /// target reaching one is a programming error rather than a runtime condition.
    private var windowID: CGWindowID {
        guard case .window(let w) = target else {
            preconditionFailure("windowID read on a display capture source")
        }
        return CGWindowID(w)
    }
    private let paramLock = NSLock()
    private var scaleFactor: Double
    private var fps: Int
    private var sink: VideoFrameSink?
    /// The backing scale of the display the window was last configured against, cached because `pollSize`
    /// runs on `sizeQueue` and cannot resolve it — `backingScale(displayID:)` is main-actor (NSScreen).
    /// Written by `makeConfig`, the single funnel both `startStream` and `reconfigure` go through, each of
    /// which hands it a freshly resolved value. Guarded by `paramLock`.
    private var lastBackingScale: CGFloat = 2.0
    /// The window's size in NATIVE PIXELS as of the last configuration — `points x backingScale`, i.e. what
    /// `scaleFactor == 1.0` captures. Written by `makeConfig` (the single funnel that already has both
    /// terms), read by `nativePixelSize`. Guarded by `paramLock`.
    private var lastNativePixels: CGSize?
    /// Fired with the window's live POINT size and the backing scale of the display it is on, so the
    /// subscriber can publish both the point size and the NATIVE PIXEL size. Fired when capture starts and
    /// on every size change the poll observes.
    /// Called on `sizeQueue` — the handler must not take `SimManager.lock` (see SimManager's wiring).
    public var onSizeChange: (@Sendable (CGSize, CGFloat) -> Void)?
    /// Fired once when SCK kills the stream, carrying the OSStatus. Set by whoever owns the source;
    /// nil means nobody is listening, which is still strictly better than the delegate being nil,
    /// because the log line above happens either way.
    public var onCaptureStopped: (@Sendable (Int) -> Void)?
    private let lifecycleLock = NSLock()   // guards `stream` + `stopped` + `starting`
    private var stream: SCStream?
    private var stopped = false
    /// When the current stream started (`lifecycleLock`), and the restart decision (`CaptureRestart`) after a failure.
    private var startedAt: Date?
    private var restart = CaptureRestart()
    /// Set by the first `start(into:)`; a later one only swaps the sink. See `start(into:)`.
    private var starting = false
    private let sampleQueue = DispatchQueue(label: "rdev.window.capture")
    /// SCK's AUDIO delivery queue. SEPARATE FROM `sampleQueue` BY CONSTRUCTION, which is what keeps
    /// the "encode must not run on the capture queue" invariant intact for video: SCK will not
    /// deliver a queue's next buffer until that queue's callback returns, and video's callback
    /// returning promptly is worth ~300 frames per 5 s against 40-88.
    ///
    /// Opus encode of a 10 ms frame is tens of microseconds, so it runs INLINE on this queue rather
    /// than through a second depth-3 handoff. That is a measurement still to be taken, not an
    /// assumption to keep: if it ever stops being true, copy the video path's drop-oldest handoff.
    private let audioQueue = DispatchQueue(label: "rdev.window.audio", qos: .userInteractive)
    /// Confined to `audioQueue`. SCK delivers audio serially on that queue, so no lock is needed —
    /// and adding one would be the only thing making this shared.
    private var framer = AudioFraming()
    /// Set by SimManager before `start(into:)`; read on `audioQueue` only.
    public var onAudioFrame: ((AudioFraming.Frame) -> Void)?
    /// ENCODE RUNS HERE, NOT ON `sampleQueue`. See `didOutputSampleBuffer`.
    private let encodeQueue = DispatchQueue(label: "rdev.window.encode", qos: .userInteractive)
    /// Guards the depth-1 handoff below AND `sink`, which the encode queue now reads.
    private let handoffLock = NSLock()
    /// HOW MANY CAPTURED FRAMES MAY WAIT FOR THE ENCODER.
    ///
    /// Three, not one: a single slow encode is a transient, and dropping a frame for every one of them
    /// costs smoothness the encoder was about to recover on its own. Three absorbs a spike; SUSTAINED
    /// slowness still sheds, which is the behaviour that matters — it is what keeps encoder lag from
    /// turning into unbounded latency.
    ///
    /// PAIRED WITH `cfg.queueDepth` BELOW, and the pairing is the constraint: every frame held here is
    /// one ScreenCaptureKit cannot recycle, and a client holding too many stops being delivered to at
    /// all. Depth 3 against a queueDepth of 8 leaves SCK five buffers to work with.
    ///
    /// 3 VERSUS 1 IS UNMEASURED, and deliberately recorded as such. Three A/B runs on one machine at
    /// 3342x2160 could not separate them — depth 1 went 45.9/48.2/43.1/37.9 fps in one run and
    /// 47.8/51.4/16.8/19.7 in the next, while depth 3 went 20.5/11.6/26.8/33.8. Run-to-run variance
    /// exceeds the difference, so neither number here is evidence for the other. What IS measured is
    /// the change that matters: encoding off the capture queue at all, worth ~5x (see the class doc).
    static let encodeDepth = 3
    /// Captured frames waiting to encode, oldest first. Guarded by handoffLock, never longer than
    /// `encodeDepth`.
    private var pending: [(buffer: CVPixelBuffer, ptsNs: Int64)] = []
    private var encodeInFlight = false             // guarded by handoffLock
    private var coalescedFrames = 0                // guarded by handoffLock
    private var lastCoalesceReport: Double = 0     // guarded by handoffLock
    private let sizeQueue = DispatchQueue(label: "rdev.window.size")   // guards `sizeTimer`/`lastPointSize`/`wasOnScreen`
    private var sizeTimer: DispatchSourceTimer?
    private var lastPointSize: CGSize = .zero
    private var wasOnScreen = true    // false while the window is off-screen (minimized / another Space)

    public init(windowID: CGWindowID, scaleFactor: Double, fps: Int) {
        self.target = .window(Int(windowID))
        self.scaleFactor = min(max(scaleFactor, 0.05), 1.0)
        self.fps = max(fps, 1)
        super.init()
    }

    /// Capture a whole display. Same clamps as the window initializer — the two differ only in what
    /// they are pointed at, which is the entire reason this class takes a `SourceTarget`.
    public init(displayID: CGDirectDisplayID, scaleFactor: Double, fps: Int) {
        self.target = .display(Int(displayID))
        self.scaleFactor = min(max(scaleFactor, 0.05), 1.0)
        self.fps = max(fps, 1)
        super.init()
    }

    /// Enumerate capturable windows: on-screen windows (ScreenCaptureKit — authoritative titles + the auth
    /// signal) plus MINIMIZED windows (public `CGWindowList(.optionAll)` filtered to layer-0 titled windows
    /// that are off-screen AND AX-confirmed minimized). Other off-screen windows (another Space, etc.) are
    /// dropped this increment — they can't be woken without SkyLight. `authorized` is false when Screen
    /// Recording permission is missing (SCShareableContent throws) → the caller sends an empty list + a status.
    public static func listWindows() async -> (windows: [WindowInfo], authorized: Bool) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            print("[window] SCShareableContent failed (Screen Recording permission?): \(error)")
            return ([], false)
        }
        // WARM THE OWN-APPLICATION MEMORY HERE, where content is already in hand. Listing runs often
        // and early, so a display stream built later — possibly after the host's last window closed,
        // at which point SCK stops naming us at all — still has something to exclude. See
        // `SelfCapture.displayExclusion`.
        rememberOwnApplication(in: content)
        var out = content.windows.compactMap { w -> WindowInfo? in
            // OUR OWN WINDOWS ARE NEVER LISTED (`SelfCapture`): the pairing QR lives in one, and a
            // window that cannot be picked cannot be subscribed to by name either. This is defence
            // in depth — the boundary that matters is at capture and thumbnail time, below and in
            // SourceThumbnailer, because a client can name a window id without listing it first.
            guard !SelfCapture.isOwnWindow(ownerPID: w.owningApplication?.processID,
                                           selfPID: ProcessInfo.processInfo.processIdentifier)
            else { return nil }
            guard w.isOnScreen, let title = w.title, !title.isEmpty,
                  w.frame.width >= 64, w.frame.height >= 64 else { return nil }
            let app = w.owningApplication?.applicationName ?? "?"
            // `SCWindow.frame` is POINTS — exactly what the client wants for actual-size rendering.
            return WindowInfo(id: Int(w.windowID), app: app, title: title,
                              w: Int(w.frame.width.rounded()), h: Int(w.frame.height.rounded()))
        }
        let onScreenIDs = Set(out.map { $0.id })
        out.append(contentsOf: minimizedWindows(excluding: onScreenIDs))
        return (out, true)
    }

    /// Every attached display, as `DisplayInfo`. Uses ScreenCaptureKit rather than
    /// `CGGetActiveDisplayList` so the auth failure mode matches `listWindows` exactly: no Screen
    /// Recording permission means an EMPTY list, not a list of displays we cannot capture.
    ///
    /// `SCDisplay.frame` is POINTS. We deliberately do NOT read `SCDisplay.width`/`.height` — the
    /// points-versus-pixels question has already cost this project once (`SCWindow.frame` is points
    /// while `SCWindow.width`/`height` are pixels), and one derivation shared by both targets beats
    /// trusting a second API to agree with the first.
    public static func listDisplays() async -> [DisplayInfo] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            // LOG IT, exactly as listWindows does. Returning [] silently is how "the Desktop vanished
            // from the palette" becomes invisible in the host log: the windows keep listing (that is a
            // separate call), so the palette looks merely incomplete rather than broken.
            print("[display] SCShareableContent failed (Screen Recording permission?): \(error)")
            return []
        }
        rememberOwnApplication(in: content)   // same reason as listWindows above
        let names = await displayNames()
        return content.displays.map { d in
            DisplayInfo(id: Int(d.displayID),
                        name: names[d.displayID] ?? "Display \(d.displayID)",
                        w: Int(d.frame.width.rounded()), h: Int(d.frame.height.rounded()))
        }
    }

    /// CGDirectDisplayID -> the user-facing name macOS shows in System Settings. NSScreen is
    /// main-thread-affine, hence the hop.
    @MainActor private static func displayNames() -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            out[n.uint32Value] = screen.localizedName
        }
        return out
    }

    /// Every currently-attached display id. Public CoreGraphics only — no ScreenCaptureKit round trip,
    /// because this runs on the size-poll and liveness paths at 1-3 Hz.
    static func activeDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }

    /// What this host can currently capture. Public CoreGraphics only — no ScreenCaptureKit round
    /// trip, because this rides `listSources`, which is on the palette's own path.
    ///
    /// ONLINE-BUT-NOT-ACTIVE IS THE WHOLE POINT: a sleeping display stays ONLINE, so counting online
    /// displays alone reports a healthy machine while nothing at all can be captured.
    static func displayStatus() -> HostDisplayStatus {
        var active: UInt32 = 0
        var online: UInt32 = 0
        // Count-only form: a nil array with maxDisplays 0 fills in the count.
        _ = CGGetActiveDisplayList(0, nil, &active)
        _ = CGGetOnlineDisplayList(0, nil, &online)
        return HostDisplayStatus(
            availability: .from(activeCount: Int(active), onlineCount: Int(online)),
            locked: sessionIsLocked())
    }

    /// nil when the session dictionary cannot be read. The key is ABSENT on some paths, which means
    /// NOT locked; only an unreadable dictionary is genuinely unknown, and nil must not become false.
    private static func sessionIsLocked() -> Bool? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Off-screen standard windows that AX reports as minimized → `WindowInfo(minimized: true)`. One AX
    /// round-trip per off-screen candidate (bounded by the 1s timeout in `WindowAX`); fail-closed drops any we
    /// can't confirm. `excluding` skips ids already returned as on-screen.
    private static func minimizedWindows(excluding onScreenIDs: Set<Int>) -> [WindowInfo] {
        guard let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }

        // Filter FIRST, then probe AX once per owning app. The AX round trip is the expensive part —
        // and against a hung app it costs the full messaging timeout — so it must be paid per PROCESS,
        // never per window. See `WindowAX.minimizedWindowIDs` for the 91-second measurement that
        // motivated this shape.
        struct Candidate { let id: CGWindowID; let app: String; let title: String; let w: Int; let h: Int }
        var byPID: [pid_t: [Candidate]] = [:]
        for d in all {
            guard let num = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  !onScreenIDs.contains(Int(num)),
                  (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let title = d[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            var bounds = CGRect.zero
            guard let b = d[kCGWindowBounds as String] as? [String: Any],
                  CGRectMakeWithDictionaryRepresentation(b as CFDictionary, &bounds),
                  bounds.width >= 64, bounds.height >= 64 else { continue }
            byPID[pid, default: []].append(
                Candidate(id: num, app: (d[kCGWindowOwnerName as String] as? String) ?? "?", title: title,
                          w: Int(bounds.width.rounded()), h: Int(bounds.height.rounded())))
        }

        var result: [WindowInfo] = []
        for (pid, candidates) in byPID {
            let minimized = WindowAX.minimizedWindowIDs(pid: pid)   // one AX round trip per app
            if minimized.isEmpty { continue }
            for c in candidates where minimized.contains(c.id) {
                result.append(WindowInfo(id: Int(c.id), app: c.app, title: c.title, minimized: true,
                                         w: c.w, h: c.h))
            }
        }
        return result
    }

    // MARK: - StreamVideoSource

    /// Feed `sink` from this capture. IDEMPOTENT ON THE STREAM: the first call starts SCK, every later
    /// call only swaps the sink, so a codec rebuild re-points a RUNNING capture at its new encoder.
    ///
    /// WHY NOT A FRESH SOURCE PER CODEC (which is what the rebuild did until 2026-09-04): stopping an
    /// SCStream on a window while a sibling stream on the same window is starting takes the sibling
    /// down with `-3805` ("application connection being interrupted") — measured twice in the latency
    /// campaign, on the first codec switch of every run, since audio capture (2026-09-03) gave both
    /// streams a tap on the same application. The receiver then reads `frames=0/0` forever with the
    /// subscription, the bind and the encoder all healthy. Keeping the one stream and swapping what it
    /// feeds has no such race, and the picture never even gaps.
    public func start(into sink: VideoFrameSink) {
        handoffLock.lock(); self.sink = sink; handoffLock.unlock()
        let first = lifecycleLock.withLock { () -> Bool in
            if starting { return false }
            starting = true
            return true
        }
        guard first else { return }
        Task { [weak self] in await self?.startStream() }
    }

    /// Resolve the target into everything the stream needs: a content filter, the subject's size in
    /// POINTS, and the backing scale of the display it lives on. Returns nil when the subject cannot be
    /// found, having already logged why.
    ///
    /// THIS IS THE ONLY PLACE THE TWO TARGETS DIVERGE. Everything after it — the delegate, the start
    /// race, the size tracking, the config — is shared.
    private func resolveSubject() async throws -> (filter: SCContentFilter, pointSize: CGSize, scale: CGFloat)? {
        switch target {
        case .workspace: return nil
        case .simulator(let u):
            // UNREACHABLE: SimManager never builds a ScreenCaptureSource for a simulator — it captures its framebuffer
            // (SimulatorCaptureSource). Fails like a window that no longer exists.
            print("[capture] simulator \(u) is not a ScreenCaptureKit subject"); return nil
        case .window(let w):
            let wid = CGWindowID(w)
            // Retry briefly (~1.6s): a just-un-minimized window may not appear in SCShareableContent
            // immediately (window-liveness spec 2 activation-on-subscribe). Its frame may still be
            // animating to full size when found; `startSizeTracking` corrects the capture size once it
            // settles, and thereafter tracks live window resizes.
            var win: SCWindow?
            var displays: [SCDisplay] = []
            for attempt in 0..<8 {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                if let w = content.windows.first(where: { $0.windowID == wid }) {
                    win = w; displays = content.displays; break
                }
                if attempt < 7 { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
            guard let win else {
                print("[window] window \(wid) not found after retries"); return nil
            }
            // THE CAPTURE BOUNDARY, not the picker. A client may name any window id — listing is a
            // convenience, not an authorization — so refusing here is what actually holds. Our own
            // window carries the pairing QR; streaming it hands over the credential.
            guard !SelfCapture.isOwnWindow(ownerPID: win.owningApplication?.processID,
                                           selfPID: ProcessInfo.processInfo.processIdentifier)
            else {
                print("[window] refusing to capture our own window \(wid) — it carries the pairing secret")
                return nil
            }
            return (SCContentFilter(desktopIndependentWindow: win),
                    win.frame.size,
                    await backingScale(displayID: displayID(for: win, in: displays)))

        case .display(let d):
            let wanted = CGDirectDisplayID(d)
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let disp = content.displays.first(where: { $0.displayID == wanted }) else {
                print("[display] display \(wanted) not found"); return nil
            }
            // EXCLUDED BY APPLICATION, NOT BY A SNAPSHOT OF WINDOW IDS — see `SelfCapture`. The
            // first version of this fix passed the window ids enumerated at stream-creation time,
            // which is frozen: `reconfigure()` re-resolves the subject but keeps only the size and
            // scale (it discards the new filter), so a host window appearing AFTER the stream
            // started was never excluded. That is the normal order of operations — start sharing,
            // then open pairing — so the snapshot missed the case it existed for.
            //
            // `excludingApplications:` is evaluated by ScreenCaptureKit per frame and has no such
            // window. The artefact is the accepted cost: where our window sits, the frame shows
            // whatever SCK composites in its place.
            //
            // AN EMPTY EXCLUSION LIST IS NOT PROTECTION: it excludes nothing and captures happily.
            // So a failure to resolve our own application REFUSES rather than producing a stream
            // that looks protected and is not — the same fail-open shape this mechanism exists to
            // remove. The shared resolver bootstraps a cold host without showing UI; if it still
            // cannot identify this process, `SelfCapture.displayFilterDecision` keeps it closed.
            guard let ownApps = await ownApplications(in: content) else {
                print("[display] REFUSING display \(wanted): own application unresolved — " +
                      "an empty exclusion would protect nothing")
                return nil
            }
            return (SCContentFilter(display: disp, excludingApplications: ownApps, exceptingWindows: []),
                    disp.frame.size,
                    await backingScale(displayID: wanted))
        }
    }

    /// The log prefix for this target, so `[window]` and `[display]` lines stay greppable apart.
    private var logTag: String {
        if case .display = target { return "display" }
        return "window"
    }

    /// How this target names itself in a log line.
    private var logSubject: String {
        switch target {
        case .window(let w): return "window \(w)"
        case .display(let d): return "display \(d)"
        case .workspace: return "application workspace"
        case .simulator(let u): return "simulator \(u)"
        }
    }

    /// What a gated start produced (`startStream`).
    private enum StartOutcome {
        case started(SCStream, pointSize: CGSize, scale: CGFloat, cfg: SCStreamConfiguration)
        case gone
        case failed(Error)
    }

    /// Start the stream — INSIDE `SCKGate` as a `start`, so no palette preview screenshot (a capture that starts and
    /// stops) overlaps it: a sibling capture stopping while this one starts kills it with `-3805`. A failure to start,
    /// like a stream that stops (`didStopWithError`), is started again after `CaptureRestart`'s backoff.
    private func startStream() async {
        await SCKGate.shared.enter(.start)
        let outcome = await startStreamGated()
        await SCKGate.shared.leave()
        switch outcome {
        case .gone:
            return
        case .failed(let error):
            print("[\(logTag)] startCapture failed: \(error)")
            recover("its start failed (\(error.localizedDescription))", code: (error as NSError).code, ranFor: nil)
        case .started(let s, let pointSize, let scale, let cfg):
            // If stop() raced ahead during the awaits above, tear down the just-started stream
            // instead of orphaning it (single-feeder + no leaked capture session).
            let aborted = lifecycleLock.withLock {
                if stopped { return true }
                self.stream = s
                self.startedAt = Date()
                return false
            }
            if aborted { try? await s.stopCapture(); return }
            print("[\(logTag)] capturing \(logSubject) \(Int(pointSize.width))x\(Int(pointSize.height))pt " +
                  "@\(scale)x -> \(cfg.width)x\(cfg.height)px fps=\(fps)")
            startSizeTracking(initial: pointSize)
            onSizeChange?(pointSize, scale)   // subscriber learns the size without waiting for a change
        }
    }

    private func startStreamGated() async -> StartOutcome {
        do {
            guard let (filter, pointSize, scale) = try await resolveSubject() else { return .gone }
            let cfg = makeConfig(pointSize: pointSize, backingScale: scale)
            // THE DELEGATE IS THE ONLY CHANNEL MACOS HAS FOR "THIS STREAM IS DEAD", and it used to be
            // nil — so a stream that stopped took the video with it and said NOTHING, anywhere. The
            // observed shape is a session that streams happily and then goes silent for good: no
            // `[encode]` line (recordOutput is per-frame, so zero frames means zero lines), no
            // `encode failed:` (the encoder was never reached), `fec: media 0 pkts` forever, while the
            // peer, the control channel and input all stay healthy. Nothing in the host could tell
            // that from "the window is idle", and WindowLivenessMonitor could not help: it watches
            // ON-SCREEN state, and the window is still perfectly on screen.
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await s.startCapture()
            // A margin past "started" before a preview may stop beside it.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return .started(s, pointSize: pointSize, scale: scale, cfg: cfg)
        } catch {
            return .failed(error)
        }
    }

    /// **START AGAIN, after a failure** (`CaptureRestart`): the delay it decides, or — out of attempts, a permission
    /// refusal, or this source stopped — the end, said once and handed to `onCaptureStopped`.
    private func recover(_ why: String, code: Int?, ranFor: Double?) {
        let decision: (delay: Double?, attempt: Int, stopped: Bool) = lifecycleLock.withLock {
            if stopped { return (nil, restart.attempts, true) }
            stream = nil
            startedAt = nil
            let delay = restart.next(code: code, ranFor: ranFor)
            return (delay, restart.attempts, false)
        }
        if decision.stopped { return }
        sizeQueue.async { [weak self] in self?.sizeTimer?.cancel(); self?.sizeTimer = nil }
        guard let delay = decision.delay else {
            print("[\(logTag)] capture of \(logSubject) is dead and will not resume: \(why)")
            onCaptureStopped?(code ?? 0)
            return
        }
        print("[\(logTag)] restarting the capture of \(logSubject) in \(delay)s " +
              "(attempt \(decision.attempt) of \(CaptureRestart.maxAttempts)): \(why)")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.lifecycleLock.withLock({ self.stopped }) else { return }
            await self.startStream()
        }
    }

    /// TAKES A POINT SIZE, NOT AN SCWindow — that is the whole of what differs between capturing a
    /// window and capturing a display. Every rule below (the 63/64 interval, queueDepth with its clamp
    /// readback, the pixel format, cursor-free capture) is target-agnostic and stays single-copy.
    private func makeConfig(pointSize: CGSize, backingScale: CGFloat) -> SCStreamConfiguration {
        paramLock.lock()
        let sf = scaleFactor; let f = fps
        lastBackingScale = backingScale
        lastNativePixels = CGSize(width: (pointSize.width * backingScale).rounded(),
                                  height: (pointSize.height * backingScale).rounded())
        paramLock.unlock()
        let cfg = SCStreamConfiguration()
        // `pointSize` is in POINTS but SCStreamConfiguration dims are PIXELS. Multiply by the display's backing
        // scale (2 on retina) so scale 1.0 == full native pixel resolution and 0.5 == 1x (points). Without this a
        // retina window streams at 1x max — half the linear detail. Mirrors the sim path, whose IOSurface is
        // already retina and which `RDEV_VIDEO_SCALE` multiplies the same way.
        cfg.width  = max(2, Int((pointSize.width  * backingScale * sf).rounded()) & ~1)
        cfg.height = max(2, Int((pointSize.height * backingScale * sf).rounded()) & ~1)
        // A CEILING ON RATE, AND ASKING FOR EXACTLY 1/fps IS THE WRONG CEILING — it silently costs
        // ~8% of the frame rate AND most of the smoothness.
        //
        // SCK refuses to deliver a frame that arrives even fractionally sooner than this interval,
        // and a compositor tick never lands on an exact 1/60 s grid: this display refreshes every
        // 8.2988 ms, so two refreshes are 16.5975 ms against a 16.6667 ms request. Every such tick is
        // rejected and the frame waits for the NEXT one, three refreshes out. The result is not a
        // clean lower rate but a BEAT between the two — measured 55.6 fps with capture intervals
        // split 42% at 16 ms and 45% at 18 ms, and 7% of frames stalling 33-41 ms.
        //
        // ASKING FOR A HAIR UNDER 1/fps LETS THE EARLY TICK THROUGH: 60.0 fps, 98% of intervals in
        // one bin, and receiver-measured judder from 8.78 ms p95 to 0.83 ms. The ceiling stays honest
        // because SCK still cannot outrun the content.
        //
        // THE TOLERANCE IS PROPORTIONAL, NOT `fps + 1`. The same tie happens at any rate whose period
        // is near a multiple of the refresh period — at the 8 fps unfocused throttle, 125 ms against
        // 15 refreshes of 124.48 ms — and `+1` would be a 12.5% rate change there while being 1.6%
        // here. 63/64 is one relative tolerance for every rate, and a binary fraction so the
        // timescale stays exact.
        //
        // KNOWN LIMIT: a rate that is not near ANY multiple of the refresh period still beats — a
        // 60 fps cap on a 144 Hz panel wants 8.68 refreshes and cannot have them. Keying the interval
        // off the display's ACTUAL refresh rate is the principled version and is not built.
        cfg.minimumFrameInterval = CMTime(value: 63, timescale: CMTimeScale(64 * max(f, 1)))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // EIGHT, PAIRED WITH `encodeDepth` (3). rdev can hold three frames waiting to encode, and every
        // one of those is a buffer SCK cannot recycle — a client holding too many stops being
        // delivered to at all. Eight leaves five for SCK to fill while rdev is at its limit. Measured
        // previously: depth 1 yields zero frames, and 2-8 are indistinguishable when nothing is held.
        cfg.queueDepth = 8
        // The cursor is NEVER captured. Beyond being unwanted in the stream, it would be actively
        // misleading: WindowInputInjector synthesizes only mouseDown/dragged/up + scrollWheel (never
        // mouseMoved), so the host cursor jumps on press/drag and then sits wherever it was left — a
        // position unrelated to where the remote user is pointing. The browser draws its own cursor over
        // the <video>, so nothing is lost. Matches SourceThumbnailer, which also captures cursor-free.
        cfg.showsCursor = false
        // LOAD-BEARING — THIS IS IN makeConfig, NOT startStream. `reconfigure()` calls
        // `updateConfiguration(makeConfig(...))` on every window resize, driven by the 300 ms size
        // poll. Set once at stream creation, `capturesAudio` is silently cleared the first time the
        // window is resized: audio works, then stops ~300 ms later, with nothing logged and no state
        // anywhere reporting a change.
        //
        // MEASURED 2026-09-03: a desktopIndependentWindow filter yields THAT APPLICATION's audio and
        // only that application's — 826 buffers of silence while a different app was at full scale.
        // See the spec's `Measured` section; the ownership election exists because of the corollary,
        // that two windows of one app each carry the whole app's audio.
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        // rdev's own process makes no sound today, but the app's web views can, and an app capturing
        // its own output would feed it back into the stream it came from.
        cfg.excludesCurrentProcessAudio = true
        return cfg
    }

    /// CGDirectDisplayID of the display the window's center sits on (pure value math, any thread). `SCWindow.frame`
    /// and `SCDisplay.frame` share the same points/top-left space, so match by center; fall back to the first display.
    private func displayID(for win: SCWindow, in displays: [SCDisplay]) -> CGDirectDisplayID? {
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        return (displays.first { $0.frame.contains(center) } ?? displays.first)?.displayID
    }

    /// The backing scale (2.0 retina, 1.0 non-retina) of `displayID`'s screen, so we capture NATIVE pixels. Read
    /// on the main actor — NSScreen is main-thread-affine — matching the display by its screen number. Falls back
    /// to the main screen, then 2.0 (assume retina).
    @MainActor private func backingScale(displayID: CGDirectDisplayID?) -> CGFloat {
        if let displayID, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) { return screen.backingScaleFactor }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    public func stop() {
        lifecycleLock.lock()
        stopped = true
        let s = stream; stream = nil
        lifecycleLock.unlock()
        sizeQueue.async { [weak self] in self?.sizeTimer?.cancel(); self?.sizeTimer = nil }
        Task { try? await s?.stopCapture() }
        // TWO BARRIERS NOW, because encode no longer runs on the capture queue. First stop accepting
        // samples, then drop the sink and the pending frame, then wait for any encode already running
        // — otherwise `stop()` could return while a frame is still being encoded into a dead sink.
        sampleQueue.sync { }
        handoffLock.lock()
        sink = nil
        pending.removeAll()          // release SCK's buffers immediately rather than at the next drain
        handoffLock.unlock()
        encodeQueue.sync { }
    }

    public func setScale(_ v: Double) {
        paramLock.lock(); scaleFactor = min(max(v, 0.05), 1.0); paramLock.unlock()
        reconfigure()
    }

    public func setFpsCap(_ fps: Int) {
        paramLock.lock(); self.fps = max(fps, 1); paramLock.unlock()
        reconfigure()
    }

    public var nativePixelSize: CGSize? {
        paramLock.lock(); defer { paramLock.unlock() }
        return lastNativePixels
    }

    private func currentBackingScale() -> CGFloat {
        paramLock.lock(); defer { paramLock.unlock() }
        return lastBackingScale
    }

    /// Re-apply the configuration at the subject's CURRENT size. Goes through the same `resolveSubject`
    /// seam as `startStream`, so a window resize and a display mode change take one code path.
    private func reconfigure() {
        lifecycleLock.lock(); let s = stream; lifecycleLock.unlock()
        guard let s else { return }
        Task { [weak self] in
            // `try?` on a throwing function that RETURNS an optional flattens to one optional, so a
            // single unwrap covers both "it threw" and "the subject is gone".
            guard let self, let resolved = try? await self.resolveSubject() else { return }
            let (_, pointSize, scale) = resolved
            try? await s.updateConfiguration(self.makeConfig(pointSize: pointSize, backingScale: scale))
        }
    }

    /// Live window-size tracking: poll the window's on-screen bounds and `reconfigure()` when the size changes,
    /// so a resized window (or a freshly un-minimized one still animating to full size) streams at its true
    /// size instead of the size locked in at capture start (SCStream does NOT auto-resize with its window).
    /// Started once capture is running; cancelled in `stop()`. Cheap: one CGWindowList read per tick; the
    /// heavier SCShareableContent reconfigure fires ONLY on a size change or an off→on-screen return. Confined
    /// to `sizeQueue`.
    private func startSizeTracking(initial: CGSize) {
        sizeQueue.async { [weak self] in
            guard let self else { return }
            self.lastPointSize = initial
            self.wasOnScreen = true
            self.sizeTimer?.cancel()   // a restarted capture replaces its predecessor's timer
            let t = DispatchSource.makeTimerSource(queue: self.sizeQueue)
            t.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(300))
            t.setEventHandler { [weak self] in self?.pollSize() }
            self.sizeTimer = t
            t.resume()
        }
    }

    /// One size-poll tick (on `sizeQueue`). Reconfigure the stream when EITHER the window's point size changed
    /// by >=2pt (a live resize; ignore sub-pixel jitter) OR the window just came back on-screen after being
    /// off-screen (un-minimized, or returned from another Space). The off→on case is LOAD-BEARING: SCK leaves
    /// the stream at a REDUCED internal resolution while the window is off-screen and does NOT restore full res
    /// on return unless we re-apply the config — and the window's bounds are unchanged across a Space move, so a
    /// size-delta check alone would miss it (the "low-res until I resize" bug). A window that is off-screen
    /// reads nil → record it and skip (liveness handles the client overlay).
    private func pollSize() {
        guard let bounds = onScreenBounds() else { wasOnScreen = false; return }
        let sz = bounds.size
        let returned = !wasOnScreen
        wasOnScreen = true
        guard returned || abs(sz.width - lastPointSize.width) >= 2 || abs(sz.height - lastPointSize.height) >= 2 else { return }
        lastPointSize = sz
        onSizeChange?(sz, currentBackingScale())
        reconfigure()
    }

    /// The SUBJECT's bounds iff it is currently on screen, else nil. For a window: the same authoritative
    /// `.optionOnScreenOnly` check `WindowLivenessMonitor` uses (minimized/off-Space/closed all read nil), so
    /// the off→on transition in `pollSize` is reliable (unlike `.optionIncludingWindow`, which is on-screen-only
    /// AND ambiguous here). One CGWindowList syscall. For a display: attached, per CGGetActiveDisplayList.
    private func onScreenBounds() -> CGRect? {
        switch target {
        case .workspace: return nil
        case .simulator:
            // UNREACHABLE: SimManager never builds a ScreenCaptureSource for a simulator — it captures its framebuffer
            // (SimulatorCaptureSource). Fails like a window that no longer exists.
            return nil
        case .window(let w):
            let wid = CGWindowID(w)
            guard let arr = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
                  let d = arr.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == wid }),
                  let b = d[kCGWindowBounds as String] as? [String: Any] else { return nil }
            var r = CGRect.zero
            return CGRectMakeWithDictionaryRepresentation(b as CFDictionary, &r) ? r : nil

        case .display(let d):
            // A DISPLAY DOES NOT RESIZE, BUT ITS MODE CHANGES — a scaled-resolution switch moves the
            // point size, and `pollSize`'s >=2pt rule catches it unchanged. Detach reads nil, which is
            // the same shape as a minimized window, so `pollSize`'s off->on branch ALSO covers a
            // display coming back: SCK leaves the stream at a reduced internal resolution across the
            // gap and needs the config re-applied, exactly as it does for a window returning from
            // another Space. `CGDisplayBounds` reports .zero for an id that is gone, which a size
            // check alone would read as a legitimate resize to nothing.
            let wanted = CGDirectDisplayID(d)
            guard ScreenCaptureSource.activeDisplayIDs().contains(wanted) else { return nil }
            let b = CGDisplayBounds(wanted)
            return (b.width > 0 && b.height > 0) ? b : nil
        }
    }

    // MARK: - SCStreamOutput

    /// SCK has torn this stream down. It is TERMINAL — the stream never resumes on its own, and
    /// nothing here restarts it yet, so this reports rather than recovers.
    ///
    /// THE ERROR CODE IS THE POINT. This project already has two documented ways for a stream to die
    /// under it, and they want opposite responses: `-3801` is a permission/TCC identity problem,
    /// `-3811` is per-process SCK state that only a host restart clears, and `-3815` follows the
    /// display idle-sleeping, which is why the curtain holds a power assertion and ordinary capture
    /// holds none. Guessing between them from a frozen picture is impossible; reading the number is
    /// trivial. Logged with the SUBJECT so it is greppable beside that source's `[encode]` lines.
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        // `logSubject`, NOT `windowID`. Reading `windowID` here TRAPS on a display target and takes the
        // whole host process down — and this is the one path that fires exactly when something has
        // already gone wrong, so the crash lands on top of the failure it was meant to report.
        print("[\(logTag)] STREAM STOPPED \(logSubject): \(error.localizedDescription) (code \(code))")
        // NOT THE END ANY MORE (2026-10-07): it was, and the window stayed dark with everything else healthy.
        let ranFor = lifecycleLock.withLock { startedAt.map { Date().timeIntervalSince($0) } }
        recover("the stream stopped (code \(code))", code: code, ranFor: ranFor)
    }

    /// LOAD-BEARING — ENCODE MUST NOT RUN ON THIS QUEUE.
    ///
    /// `sampleHandlerQueue` is ScreenCaptureKit's delivery queue. Encoding inline back-pressures it:
    /// SCK will not deliver the next frame until this returns, so a slow encode throttles CAPTURE, not
    /// just encode. Measured on a 3342x2160 display with software AV1: **40-88 frames delivered per
    /// 5 s window instead of ~300**, intervals p50 106 ms and max 322 ms, `late 39.8%` — and every
    /// downstream symptom (a sparse bursty stream, a receiver asking for keyframes on a LOOPBACK path
    /// with `lost=0 nack=0`, the encoder collapsing to 8 fps) followed from that one coupling.
    ///
    /// BOUNDED AT `encodeDepth`, DROPPING THE OLDEST. Three frames absorb a transient encode spike
    /// without shedding anything; sustained slowness still sheds, which is what keeps encoder lag from
    /// becoming unbounded latency. Dropping the OLDEST rather than the incoming frame is what makes
    /// that true — discarding the newest would leave the encoder grinding through stale frames.
    ///
    /// Retaining the CVPixelBuffer is what makes this safe: the image buffer is only valid while
    /// something holds it, and assigning it here retains it independently of the CMSampleBuffer.
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            handleAudio(sampleBuffer)
            return
        }
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ns = Int64(DispatchTime.now().uptimeNanoseconds)
        handoffLock.lock()
        guard sink != nil else { handoffLock.unlock(); return }   // stopped, or not yet started
        // FULL: drop the OLDEST, not the incoming one. Discarding the newest would leave the encoder
        // grinding through stale frames while fresh ones are thrown away — latency growing for no
        // gain. COUNTED, not silently discarded: a drop nobody reports is how a starved encoder looks
        // identical to a healthy one.
        if pending.count >= Self.encodeDepth {
            pending.removeFirst()
            coalescedFrames += 1
        }
        pending.append((pb, ns))
        let shouldStart = !encodeInFlight
        if shouldStart { encodeInFlight = true }
        handoffLock.unlock()
        if shouldStart { encodeQueue.async { [weak self] in self?.drainEncodes() } }
    }

    /// Encode whatever is pending until nothing is, then release the in-flight flag. Runs on
    /// `encodeQueue`; `sink.encode` is called with NO lock held, because it can take hundreds of
    /// milliseconds and holding `handoffLock` across it would reintroduce the stall this exists to
    /// remove — the capture callback would block on the lock instead of on the encoder.
    private func drainEncodes() {
        while true {
            handoffLock.lock()
            guard !pending.isEmpty, let sink else {
                encodeInFlight = false
                handoffLock.unlock()
                return
            }
            let next = pending.removeFirst()
            let report = coalesceReportLocked()
            handoffLock.unlock()
            if let report { print(report) }
            sink.encode(next.buffer, ptsNs: next.ptsNs)
        }
    }

    /// A once-per-5s line when frames were coalesced, or nil. Caller must hold `handoffLock`.
    ///
    /// Reported separately from `[capture] late`, which is measured at the ENCODER's input and so now
    /// describes the stream AFTER coalescing — it can look healthy while frames are being shed here.
    private func coalesceReportLocked() -> String? {
        guard coalescedFrames > 0 else { return nil }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastCoalesceReport >= 5 else { return nil }
        let dropped = coalescedFrames
        let span = lastCoalesceReport == 0 ? 5 : now - lastCoalesceReport
        lastCoalesceReport = now
        coalescedFrames = 0
        return String(format: "[%@] %@ coalesced %d frame(s) in %.1fs — the encoder is behind capture",
                      logTag, logSubject, dropped, span)
    }

    /// Convert one SCK audio buffer to interleaved float and hand whole frames on.
    ///
    /// SCK delivers float32 NON-INTERLEAVED at 48 kHz; Opus takes interleaved. The conversion lives
    /// here rather than in `AudioFraming` so everything about frame sizes, timestamps and gaps stays
    /// testable with plain arrays and no CoreAudio in the loop.
    ///
    /// THE CAPTURE PTS IS USED, NOT THE ARRIVAL TIME, AND THAT IS THE OPPOSITE OF THE VIDEO PATH
    /// ABOVE — deliberately. Video stamps arrival because a measured A/B found the presentation
    /// timestamp WORSE (offsetJitter p95 8.66 → 13.70 ms): with a 10 ms jitter buffer there is
    /// nothing to absorb the variable delay between capture and the moment the host holds the frame.
    /// Audio has no such problem: its PTS comes from the audio hardware clock and IS the quantity to
    /// reproduce, while arrival jitter above the framer's 5 ms tolerance would trigger a FALSE
    /// re-anchor — an audible glitch caused by delivery, not by content.
    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let sink = onAudioFrame, CMSampleBufferIsValid(sb) else { return }
        var interleaved: [Float] = []
        try? sb.withAudioBufferList { abl, _ in
            let buffers = Array(abl)
            guard let first = buffers.first, let firstData = first.mData else { return }
            let samplesPerBuffer = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard samplesPerBuffer > 0 else { return }
            // ONE BUFFER CARRYING BOTH CHANNELS is already interleaved and needs no transposition;
            // one buffer PER CHANNEL is the non-interleaved shape SCK actually delivers. Handling
            // both means a format change cannot silently halve the rate or swap the channels.
            if buffers.count == 1 {
                let p = firstData.assumingMemoryBound(to: Float.self)
                interleaved = Array(UnsafeBufferPointer(start: p, count: samplesPerBuffer))
                return
            }
            interleaved = [Float](repeating: 0, count: samplesPerBuffer * buffers.count)
            for (channel, buffer) in buffers.enumerated() {
                guard let data = buffer.mData else { continue }
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<samplesPerBuffer { interleaved[i * buffers.count + channel] = p[i] }
            }
        }
        guard !interleaved.isEmpty else { return }
        for frame in framer.append(interleaved, ptsNs: Self.captureNanos(sb)) { sink(frame) }
    }

    /// A sample buffer's presentation time in nanoseconds.
    ///
    /// SECONDS AND REMAINDER SEPARATELY, never `value * 1e9 / timescale` in one step: an audio PTS is
    /// commonly a SAMPLE COUNT at timescale 48000, and on a machine up for a couple of weeks that
    /// product overflows Int64 while looking perfectly reasonable in a debugger. Falls back to
    /// uptime for an invalid stamp, which `AudioFraming` then treats as the anchor.
    private static func captureNanos(_ sb: CMSampleBuffer) -> Int64 {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTIME_IS_VALID(pts), pts.timescale != 0 else {
            return Int64(DispatchTime.now().uptimeNanoseconds)
        }
        let scale = Int64(pts.timescale)
        let seconds = Int64(pts.value) / scale
        let remainder = Int64(pts.value) % scale
        return seconds * 1_000_000_000 + remainder * 1_000_000_000 / scale
    }

}
