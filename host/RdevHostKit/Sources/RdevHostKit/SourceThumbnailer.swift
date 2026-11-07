import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import RdevCore

/// One-shot source snapshots for the picker gallery. Captures a still per source and hands each result to
/// `send` as it completes (streaming: the list paints first, tiles fill in). Windows use SCScreenshotManager;
/// booted sims are added in the sim-capture task (they resolve to `unavailable` here). Bounded concurrency so
/// one slow app can't stall the batch. All capture/encode runs OFF any host lock; `send` (a `ChannelHub`
/// closure) is the only host-facing call. Params per the plan's Global Constraints.
public enum SourceThumbnailer {
    static let maxEdge = 320
    static let quality = 0.6
    static let maxConcurrent = 3

    /// Capture every source, emitting one `source-thumb` payload per source via `send`. Runs in batches of
    /// `maxConcurrent`. `send` may be called from any thread/task.
    ///
    /// TWO LANES, run side by side (final review I7): the Mac's windows and displays, and the simulators. A simulator's
    /// still is a `simctl` subprocess (0.5–2 s, more while its display sleeps, FOREVER behind a wedged
    /// CoreSimulatorService before it had a deadline), and the listing puts simulators FIRST — in one lock-step lane
    /// every window tile waited behind them.
    public static func run(sources: [Source], send: @escaping @Sendable (Data) -> Void) async {
        // ONE listing for the whole batch: it was fetched once PER SOURCE, the costliest part of a preview.
        let content = Listing(content: try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
        let (mac, simulators) = lanes(sources)
        async let simulatorLane: Void = batches(simulators, content: content, send: send)
        await batches(mac, content: content, send: send)
        await simulatorLane
    }

    /// The Mac's own sources, then the simulators, each in the listing's order. INTERNAL for the tests.
    static func lanes(_ sources: [Source]) -> (mac: [Source], simulators: [Source]) {
        (sources.filter { $0.kind != "sim" }, sources.filter { $0.kind == "sim" })
    }

    private static func batches(_ sources: [Source], content: Listing, send: @escaping @Sendable (Data) -> Void) async {
        var i = 0
        while i < sources.count {
            let batch = Array(sources[i..<min(i + maxConcurrent, sources.count)])
            await withTaskGroup(of: Void.self) { group in
                for src in batch { group.addTask { await captureOne(src, content: content, send: send) } }
            }
            i += maxConcurrent
        }
    }

    /// The batch's one `SCShareableContent`, read-only once fetched.
    private struct Listing: @unchecked Sendable { let content: SCShareableContent? }

    /// One screenshot, inside `SCKGate` as a `still`: a preview is a capture that starts and STOPS, and stopping beside a
    /// stream that is starting kills that stream (`-3805`) — a window picked before its preview loaded never streamed
    /// (2026-10-07).
    private static func screenshot(_ filter: SCContentFilter, _ cfg: SCStreamConfiguration) async throws -> CGImage {
        await SCKGate.shared.enter(.still)
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            await SCKGate.shared.leave()
            return image
        } catch {
            await SCKGate.shared.leave()
            throw error
        }
    }

    private static func captureOne(_ src: Source, content: Listing, send: @escaping @Sendable (Data) -> Void) async {
        switch parseSourceID(src.id) {
        case .window(let wid):
            if let shot = await captureWindow(CGWindowID(wid), content: content.content) {
                send(sourceThumbJSON(id: src.id, w: shot.w, h: shot.h, jpegBase64: shot.base64)); return
            }
        case .display(let did):
            if let shot = await captureDisplay(CGDirectDisplayID(did), content: content.content) {
                send(sourceThumbJSON(id: src.id, w: shot.w, h: shot.h, jpegBase64: shot.base64)); return
            }
        case .sim(let udid) where src.running:
            if let shot = await Task.detached(priority: .utility, operation: { captureSim(udid) }).value {
                send(sourceThumbJSON(id: src.id, w: shot.w, h: shot.h, jpegBase64: shot.base64)); return
            }
        default:
            break   // shut-down sim → unavailable
        }
        send(sourceThumbUnavailableJSON(id: src.id))
    }

    /// One-shot still of an on-screen window via SCScreenshotManager, captured directly at tile size (so no
    /// separate downscale pass). Composited independently, so a covered window still captures. nil if the
    /// window isn't on-screen (minimized/off-Space → caller emits unavailable) or capture/encode fails.
    private static func captureWindow(_ id: CGWindowID, content: SCShareableContent?) async -> (w: Int, h: Int, base64: String)? {
        // Not-found is the EXPECTED path for a minimized / off-Space window (the caller emits `unavailable`
        // and the tile shows its placeholder), so it stays silent — only a real capture error logs below.
        guard let content, let win = content.windows.first(where: { $0.windowID == id }) else { return nil }
        // THE CHEAPEST PATH OUT OF THE FOUR, and the last one closed. `request-thumbs` enumerates
        // EVERY window and returns a JPEG of each, to ANY client, WITH NO SUBSCRIPTION — so a single
        // control message would have returned a picture of the pairing QR. Refusing here rather than
        // in the enumerator is what holds, since a client can name an id directly.
        guard !SelfCapture.isOwnWindow(ownerPID: win.owningApplication?.processID,
                                       selfPID: ProcessInfo.processInfo.processIdentifier)
        else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let (w, h) = fitted(width: win.frame.width, height: win.frame.height, maxEdge: maxEdge)
        cfg.width = w; cfg.height = h
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        do {
            let image = try await screenshot(filter, cfg)
            guard let b64 = jpegBase64(image) else {
                print("[thumb] window \(id) jpeg encode failed")
                return nil
            }
            return (w, h, b64)
        } catch {
            // Don't swallow: an on-screen window that won't capture is worth seeing in the log (the tile
            // silently becomes a placeholder otherwise).
            print("[thumb] window \(id) capture failed: \(error)")
            return nil
        }
    }

    /// One-shot still of a whole display via SCScreenshotManager, captured directly at tile size — the cost
    /// is SETUP, not pixels (~17ms per source at any resolution), so there is no separate downscale pass.
    /// Cursor-free, matching both the window arm and the capture config. nil if the display is gone or
    /// capture/encode fails (the caller then emits `unavailable`, which terminates the tile's loading state
    /// so it can never spin forever).
    private static func captureDisplay(_ id: CGDirectDisplayID, content: SCShareableContent?) async -> (w: Int, h: Int, base64: String)? {
        guard let content, let disp = content.displays.first(where: { $0.displayID == id }) else { return nil }
        // EXCLUDED BY APPLICATION, matching the video path in ScreenCaptureSource. A window-id list
        // is a snapshot frozen at capture time and misses a host window opened later — and a display
        // thumbnail is a path out for the pairing QR that reaches every client's palette, including
        // clients that never subscribed to that display.
        // AN EMPTY EXCLUSION LIST IS NOT PROTECTION — see ScreenCaptureSource. Refuse rather than
        // emit a thumbnail that looks protected and is not; the caller then emits `unavailable`.
        guard let ownApps = await ownApplications(in: content) else {
            print("[thumb] REFUSING display \(id): own application unresolved")
            return nil
        }
        let filter = SCContentFilter(display: disp, excludingApplications: ownApps, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let (w, h) = fitted(width: disp.frame.width, height: disp.frame.height, maxEdge: maxEdge)
        cfg.width = w; cfg.height = h
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        do {
            let image = try await screenshot(filter, cfg)
            guard let b64 = jpegBase64(image) else {
                print("[thumb] display \(id) jpeg encode failed")
                return nil
            }
            return (w, h, b64)
        } catch {
            // Don't swallow: an attached display that won't capture is worth seeing in the log (the tile
            // silently becomes a placeholder otherwise).
            print("[thumb] display \(id) capture failed: \(error)")
            return nil
        }
    }

    /// One-shot screenshot of a booted sim via `simctl io <udid> screenshot <tmp.png>` → downscale →
    /// JPEG+base64. Blocking (subprocess); the caller runs it on a detached task. nil on any failure (incl.
    /// simctl's "Timeout waiting for screen surfaces" when the sim display is asleep → the tile stays a
    /// placeholder). Writes to an explicit temp FILE — NOT `-`/stdout: on this toolchain `simctl screenshot -`
    /// with a piped stdout writes a file literally named `-` in the cwd instead of feeding the pipe, so the
    /// pipe path both dropped the image and littered a stray `./-`. The in-process framebuffer one-shot is a
    /// possible future optimization; a temp file is robust and simple.
    private static func captureSim(_ udid: String) -> (w: Int, h: Int, base64: String)? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rdev-thumb-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A DEADLINE (final review I7): `waitUntilExit()` waited forever on a wedged CoreSimulatorService.
        guard SimulatorControl.xcrun(["simctl", "io", udid, "screenshot", "--type=png", tmp.path], nil, 5)?.status == 0,
              let png = try? Data(contentsOf: tmp), !png.isEmpty,
              let src = CGImageSourceCreateWithData(png as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let scaled = downscale(full, maxEdge: maxEdge),
              let b64 = jpegBase64(scaled) else { return nil }
        return (scaled.width, scaled.height, b64)
    }

    /// Downscale a CGImage so its longest edge is <= maxEdge (never up-scales), into a fresh RGBA context.
    private static func downscale(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let (w, h) = fitted(width: CGFloat(image.width), height: CGFloat(image.height), maxEdge: maxEdge)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Scale (width,height) so the longest edge is <= maxEdge (never up-scales); even dims (JPEG-friendly).
    static func fitted(width: CGFloat, height: CGFloat, maxEdge: Int) -> (Int, Int) {
        let longest = max(width, height, 1)
        let s = min(1, CGFloat(maxEdge) / longest)
        return (max(2, Int((width * s).rounded()) & ~1), max(2, Int((height * s).rounded()) & ~1))
    }

    /// JPEG-encode a CGImage at `quality` → base64. nil on encoder failure.
    static func jpegBase64(_ image: CGImage) -> String? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data).base64EncodedString()
    }
}
