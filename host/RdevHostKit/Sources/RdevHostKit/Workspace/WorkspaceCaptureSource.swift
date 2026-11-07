import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import RdevCore
import RdevWorkspacePacking

/// Opt-in, fixed-format workspace source. The protected display stream supplies only its native
/// menu band and one system-audio feed. All remaining pixels come from owner-validated window
/// layers; membership is deliberately not a capture inclusion list.
public final class WorkspaceCaptureSource: NSObject, StreamVideoSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    public var onSizeChange: ((Int, Int) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onAudioFrame: ((AudioFraming.Frame) -> Void)?
    public var nativePixelSize: CGSize? { CGSize(width: 1280, height: 800) }
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["RDEV_INSTRUMENTS"] == "1"
    private let diagnosticsLock = NSLock()
    private var diagnosticLines = 0
    private var diagnosticPhase = "idle"
    private func trace(_ phase: String, token: UUID) {
        guard diagnosticsEnabled else { return }
        diagnosticsLock.lock()
        diagnosticPhase = phase
        let emit = diagnosticLines < 200
        diagnosticLines += 1
        diagnosticsLock.unlock()
        if emit {
            let line = "[workspace-capture] t=\(ProcessInfo.processInfo.systemUptime) generation=\(token) display=\(displayID) \(phase)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
    private let state = NSLock()
    private var generation = UUID()
    private var running = false
    private var sink: VideoFrameSink?
    private var compositor: WorkspaceCompositor?
    private var baseStream: SCStream?
    private var catalogTimer: Timer?
    private var catalogGeneration: UUID?
    private var catalogQueryGeneration: UUID?
    private var lastCatalog = 0.0
    private var display: SCDisplay?
    private var fps = 60
    private var lastFrameNs: Int64 = 0
    private var latestMask: CVPixelBuffer?
    private var loggedBaseSample = false // under state
    private let samples = DispatchQueue(label: "workspace.base.samples")
    private let audio = DispatchQueue(label: "workspace.audio")
    private let encoding = DispatchQueue(label: "workspace.encode", qos: .userInteractive)
    private var framer = AudioFraming()
    private var pending: [(CVPixelBuffer, CVPixelBuffer, Int64, UUID)] = []
    private var draining = false
    private var restartPolicy = CaptureRestart()
    private var restartWork: DispatchWorkItem?
    private var retrySink: VideoFrameSink?
    private var baseStartedAt: Double?
    private var startupWatchdog: DispatchWorkItem?
    private let captureStartOverride: (() -> Void)?

    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID; captureStartOverride = nil; super.init()
    }
    /// Dependency seam for lifecycle tests: no display, TCC prompt or native stream is created.
    init(displayID: CGDirectDisplayID, captureStart: @escaping () -> Void) {
        self.displayID = displayID; captureStartOverride = captureStart; super.init()
    }
    public var inputReady: Bool {
        state.withLock { running && latestMask != nil && compositor != nil }
    }

    public func start(into sink: VideoFrameSink) {
        state.lock()
        guard !running else { self.sink = sink; state.unlock(); return }
        restartWork?.cancel(); restartWork = nil; retrySink = nil
        restartPolicy = CaptureRestart()
        running = true; generation = UUID(); self.sink = sink
        let token = generation
        state.unlock()
        beginCapture(token: token)
    }

    private func beginCapture(token: UUID) {
        if let captureStartOverride {
            let installed = state.withLock { () -> Bool in
                guard running, generation == token else { return false }
                baseStartedAt = ProcessInfo.processInfo.systemUptime; return true
            }
            if installed { captureStartOverride() }; return
        }
        trace("startup scheduled", token: token)
        let watchdog = DispatchWorkItem { [weak self] in
            if let self, self.active(token) {
                let phase = self.diagnosticsLock.withLock { self.diagnosticPhase }
                self.trace("startup watchdog lastPhase=\(phase)", token: token)
            }
            self?.recoverAfterBaseFailure(NSError(domain: "AppWorkspaceCapture", code: -3902,
                userInfo: [NSLocalizedDescriptionKey: "Workspace capture startup timed out"]), token: token)
        }
        let installed = state.withLock { () -> Bool in
            guard running, generation == token else { return false }
            startupWatchdog?.cancel(); startupWatchdog = watchdog; return true
        }
        guard installed else { return }
        // Native audio+display initialization took ~4 s in the product probe. This is a startup
        // budget, independent of the 100 ms lease guarding already-running layer frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: watchdog)
        Task { @MainActor [weak self] in await self?.startCapture(generation: token) }
    }

    private func active(_ token: UUID) -> Bool {
        state.lock(); defer { state.unlock() }; return running && generation == token
    }

    @MainActor private func startCapture(generation token: UUID) async {
        guard active(token) else { return }
        do {
            trace("shareable begin", token: token)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            trace("shareable end windows=\(content.windows.count) displays=\(content.displays.count)", token: token)
            guard active(token) else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }),
                  display.width == 1280, display.height == 800 else {
                fail("Workspace display or host capture identity is unavailable", token: token); return
            }
            trace("ownApplications begin", token: token)
            let ownApplicationsResult = await ownApplications(in: content)
            trace("ownApplications end count=\(ownApplicationsResult?.count ?? 0)", token: token)
            guard let own = ownApplicationsResult, !own.isEmpty else {
                fail("Workspace display or host capture identity is unavailable", token: token); return
            }
            guard active(token) else { return }
            self.display = display
            let compositor = WorkspaceCompositor(onFailure: { [weak self] message in self?.fail(message, token: token) }) { [weak self] color, mask, pts in
                guard let mask else { return }; self?.enqueue(color, mask: mask, pts: pts, token: token)
            }
            let installed = state.withLock { () -> Bool in
                guard running, generation == token else { return false }
                self.compositor = compositor; return true
            }
            guard installed else { compositor.stop(); return }
            trace("compositor update begin", token: token)
            compositor.update(content: content, display: display, origin: display.frame.origin, menuHeight: menuHeight(display: display))
            trace("compositor update end", token: token)
            guard active(token) else { return }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            filter.includeMenuBar = true
            let cfg = SCStreamConfiguration()
            cfg.width = 1280; cfg.height = 800; cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false; cfg.shouldBeOpaque = false; cfg.queueDepth = 8
            cfg.minimumFrameInterval = CMTime(value: 63, timescale: 64 * 60)
            cfg.colorSpaceName = CGColorSpace.itur_709
            cfg.capturesAudio = true; cfg.sampleRate = 48000; cfg.channelCount = 2
            trace("base configuration audio=\(cfg.capturesAudio)", token: token)
            cfg.excludesCurrentProcessAudio = true
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: samples)
            if cfg.capturesAudio {try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audio)}
            guard state.withLock({ () -> Bool in
                guard running, generation == token else { return false }
                baseStream = stream; return true
            }) else { return }
            if diagnosticsEnabled {
                let gate = await SCKGate.shared.state
                trace("gate wait kind=\(String(describing: gate.kind)) holders=\(gate.holders) waiting=\(gate.waiting)", token: token)
            }
            await SCKGate.shared.enter(.start)
            trace("gate acquired", token: token)
            do {
                if active(token) {
                    trace("stream start begin", token: token)
                    try await stream.startCapture()
                    trace("stream start end", token: token)
                }
                await SCKGate.shared.leave()
            } catch { await SCKGate.shared.leave(); throw error }
            guard active(token) else { return } // Teardown owns this generation's stream stop.
            guard state.withLock({ () -> Bool in
                guard running, generation == token else { return false }
                startupWatchdog?.cancel(); startupWatchdog = nil
                baseStartedAt = ProcessInfo.processInfo.systemUptime; return true
            }) else { return }
            lastCatalog = ProcessInfo.processInfo.systemUptime
            onSizeChange?(1280, 800)
            catalogGeneration = token
            catalogTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshCatalog(token: token) }
            }
        } catch { recoverAfterBaseFailure(error, token: token) }
    }

    /// Query the native menu-band geometry instead of transplanting the spike's fixed 30 px band.
    @MainActor private func menuHeight(display: SCDisplay) -> CGFloat {
        let records = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        for record in records {
            guard let layer = record[kCGWindowLayer as String] as? Int,
                  layer == Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(rect.minY - display.frame.minY) <= 1,
                  rect.width >= display.frame.width - 1, rect.height > 0, rect.height < 100 else { continue }
            return rect.height
        }
        return min(99, max(0, NSApp?.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness))
    }

    @MainActor private func refreshCatalog(token: UUID) async {
        checkFirstFrameDeadline()
        guard active(token) else { return }
        if catalogQueryGeneration == token {
            if ProcessInfo.processInfo.systemUptime - lastCatalog > 2 {
                recoverAfterBaseFailure(NSError(domain: "AppWorkspaceCapture", code: -3901,
                    userInfo: [NSLocalizedDescriptionKey: "Workspace window discovery timed out"]), token: token)
            }
            return
        }
        catalogQueryGeneration = token
        defer { if catalogQueryGeneration == token { catalogQueryGeneration = nil } }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard active(token) else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                fail("Workspace display disappeared", token: token); return
            }
            lastCatalog = ProcessInfo.processInfo.systemUptime
            compositor?.update(content: content, display: display, origin: display.frame.origin, menuHeight: menuHeight(display: display))
        } catch { recoverAfterBaseFailure(error, token: token) }
    }

    /// A successful native start is not evidence of a frame. A sibling stop can leave SCK
    /// silent without a delegate error; do not cancel recovery merely because start returned.
    func checkFirstFrameDeadline(now: Double = ProcessInfo.processInfo.systemUptime) {
        let stalled = state.withLock { () -> UUID? in
            guard running, latestMask == nil, let began = baseStartedAt, now-began >= 3 else { return nil }
            return generation
        }
        guard let stalled else { return }
        trace("first composed frame timed out", token: stalled)
        recoverAfterBaseFailure(NSError(domain: "AppWorkspaceCapture", code: -3903,
            userInfo: [NSLocalizedDescriptionKey: "Workspace capture started without delivering a frame"]), token: stalled)
    }

    private func fail(_ message: String, token: UUID) {
        trace("fail \(message)", token: token)
        let error = NSError(domain: "AppWorkspaceCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        if stop(expectedGeneration: token) { onError?(error) }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        state.lock()
        let current = running && stream === baseStream, compositor = self.compositor
        let logSample = type == .screen && !loggedBaseSample
        if logSample { loggedBaseSample = true }
        let token = generation
        state.unlock()
        if logSample {
            let metadata = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
            trace("base first sample current=\(current) status=\(String(describing:metadata?.first?[.status]))", token: token)
        }
        guard current else { return }
        if type == .audio { handleAudio(sample); return }
        guard type == .screen, let buffer = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue else { return }
        compositor?.submit(base: buffer, pts: Self.captureNanos(sample))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        state.lock(); let token = generation, current = running && stream === baseStream; state.unlock()
        if current { recoverAfterBaseFailure(error, token: token) }
    }

    private func enqueue(_ color: CVPixelBuffer, mask: CVPixelBuffer, pts: Int64, token: UUID) {
        state.lock()
        guard running, generation == token else { state.unlock(); return }
        let first = latestMask == nil
        latestMask = mask
        if lastFrameNs > 0, pts - lastFrameNs < Int64(1_000_000_000 / max(1, fps)) { state.unlock(); return }
        lastFrameNs = pts
        if pending.count >= 3 { pending.removeFirst() }
        pending.append((color, mask, pts, token))
        let start = !draining; draining = true
        state.unlock()
        if first { trace("first composed frame queued", token: token) }
        if start { encoding.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while true {
            state.lock()
            guard !pending.isEmpty else { draining = false; state.unlock(); return }
            let (color, mask, pts, token) = pending.removeFirst()
            let sink = running && token == generation ? self.sink : nil
            state.unlock()
            guard let sink, active(token) else { continue }
            guard let packed = WorkspacePacking.pack(color: color, hit: mask) else {
                DispatchQueue.main.async { [weak self] in self?.fail("Workspace frame packing failed", token: token) }
                continue
            }
            guard active(token) else { continue }
            sink.encode(packed, ptsNs: pts)
        }
    }

    /// Host-side post-time guard; the browser independently uses its LAST PRESENTED mask.
    public func hitAt(normalizedX x: Double, y: Double) -> Bool {
        guard x.isFinite, y.isFinite, x >= 0, x < 1, y >= 0, y < 1 else { return false }
        state.lock(); let mask = running ? latestMask : nil, compositor = self.compositor; state.unlock()
        guard compositor?.acceptsInput(x: x * 1280, y: y * 800) == true, let mask, CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(mask) else { return false }
        return bytes.assumingMemoryBound(to: UInt8.self)[Int(y * 800) * CVPixelBufferGetBytesPerRow(mask) + Int(x * 1280)] >= 128
    }

    public func setScale(_ value: Double) {} // Fixed format; the browser advertises this restriction.
    public func setFpsCap(_ value: Int) { state.lock(); fps = max(1, min(60, value)); state.unlock() }
    public func stop() { _ = stop(expectedGeneration: nil) }
    @discardableResult private func stop(expectedGeneration expected: UUID?) -> Bool {
        state.lock()
        if let expected, generation != expected || !running { state.unlock(); return false }
        let stoppedGeneration = generation
        running = false; generation = UUID(); sink = nil; retrySink = nil
        restartWork?.cancel(); restartWork = nil; startupWatchdog?.cancel(); startupWatchdog = nil
        baseStartedAt = nil; latestMask = nil; loggedBaseSample = false; pending.removeAll(); lastFrameNs = 0
        let compositor = self.compositor, stream = baseStream; self.compositor = nil; baseStream = nil
        state.unlock()
        encoding.sync {} // No encode may outlive source teardown/encoder invalidation.
        stopNative(compositor: compositor, stream: stream, token: stoppedGeneration)
        return true
    }

    private func stopNative(compositor: WorkspaceCompositor?, stream: SCStream?, token: UUID) {
        Task { @MainActor [weak self] in
            compositor?.stop()
            if self?.catalogGeneration == token {
                self?.catalogTimer?.invalidate(); self?.catalogTimer = nil
            }
            if let stream {
                // A stop has the same exclusion requirements as a screenshot (which starts/stops
                // internally). It may share with stops, but never with any guarded stream start.
                await SCKGate.shared.enter(.still)
                try? await stream.stopCapture()
                await SCKGate.shared.leave()
            }
        }
    }

    /// Called only after delegate identity validation, or with the startup's own generation.
    /// Internal visibility lets tests inject the native failure without creating a GUI capture.
    func recoverAfterBaseFailure(_ error: Error, token suppliedToken: UUID? = nil) {
        state.lock()
        let token = suppliedToken ?? generation
        guard running, generation == token else { state.unlock(); return }
        let ranFor = baseStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 }
        let delay = restartPolicy.next(code: (error as NSError).code, ranFor: ranFor)
        let retainedSink = sink
        running = false; generation = UUID()
        let retryToken = generation
        sink = nil; latestMask = nil; loggedBaseSample = false; pending.removeAll(); lastFrameNs = 0; baseStartedAt = nil
        startupWatchdog?.cancel(); startupWatchdog = nil; restartWork?.cancel(); restartWork = nil
        let compositor = self.compositor, stream = baseStream; self.compositor = nil; baseStream = nil
        retrySink = delay == nil ? nil : retainedSink
        let work = DispatchWorkItem { [weak self] in self?.restartIfPending(token: retryToken) }
        if delay != nil { restartWork = work }
        state.unlock()
        trace("recover error=\((error as NSError).domain)/\((error as NSError).code) description=\(error.localizedDescription) retryDelay=\(String(describing: delay))", token: token)
        encoding.sync {}
        stopNative(compositor: compositor, stream: stream, token: token)
        if let delay { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        else if state.withLock({ generation == retryToken && !running }) {
            onError?(error) // Preserve -3801 and the original error domain/description.
        }
    }

    private func restartIfPending(token: UUID) {
        state.lock()
        guard generation == token, !running, let sink = retrySink else { state.unlock(); return }
        retrySink = nil; restartWork = nil
        running = true; generation = UUID(); self.sink = sink
        let next = generation
        state.unlock()
        trace("retry begin", token: next)
        beginCapture(token: next)
    }
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
