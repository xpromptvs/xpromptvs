import AppKit
import Foundation

/// Watches the SYSTEM cursor and reports its image whenever the shape changes, so the client can render the
/// host app's cursor on its own pointer (cursor passthrough). Only the shape travels — never a position.
///
/// LOAD-BEARING (measured 2026-07-27): `NSCursor.currentSystem` only refreshes while the RUN LOOP is pumped.
/// A spike that slept on the main thread read cursors that lagged a full move behind, which would present as
/// "the cursor is just laggy" rather than an obvious bug. So this is a main-run-loop timer, never a sleep
/// loop. With the loop pumped, the reported shape follows a posted `mouseMoved` in ~20-30 ms.
///
/// It polls ONLY while hovering is actually happening (`noteHover` arms it; it disarms itself `idleAfter`
/// seconds after the last hover), so an idle session costs nothing.
///
/// AppKit affinity: `NSCursor` is read on the MAIN thread only, and `onChange` is invoked there too — the
/// callee must not hold any host lock.
/// @unchecked Sendable: every mutable field (`timer`, `lastPNG`, `lastHoverAt`) is touched ONLY on the main
/// thread — `noteHover`/`stop` hop there explicitly and `tick` is called by a main-run-loop timer.
public final class CursorWatcher: @unchecked Sendable {
    /// (png1x, png3x, widthPt, heightPt, hotspotXPt, hotspotYPt)
    private let onChange: @Sendable (Data, Data, Int, Int, Int, Int) -> Void
    private var timer: Timer?
    // Read only on the main queue by focused host routing checks.
    var isPollingForTests: Bool { timer != nil }
    private var lastPNG: Data?
    private var lastHoverAt = Date.distantPast
    /// Stop polling this long after the last hover — the pointer has left, so the shape can't change.
    private let idleAfter: TimeInterval = 2.0
    private let interval: TimeInterval = 0.05

    public init(onChange: @escaping @Sendable (Data, Data, Int, Int, Int, Int) -> Void) { self.onChange = onChange }

    /// A hover just arrived: (re)arm the poll. Safe to call at pointer-move rates — it only starts a timer
    /// when none is running.
    public func noteHover() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastHoverAt = Date()
            guard self.timer == nil else { return }
            let t = Timer(timeInterval: self.interval, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    public func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate(); self?.timer = nil; self?.lastPNG = nil
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastHoverAt) > idleAfter {
            timer?.invalidate(); timer = nil
            return
        }
        guard let c = NSCursor.currentSystem, let png = CursorWatcher.png(c.image, scale: 1) else { return }
        guard png != lastPNG else { return }   // byte-identical => same shape; don't resend
        lastPNG = png
        let highResolution = CursorWatcher.png(c.image, scale: 3) ?? png
        onChange(png, highResolution,
                 Int(c.image.size.width.rounded()), Int(c.image.size.height.rounded()),
                 Int(c.hotSpot.x.rounded()), Int(c.hotSpot.y.rounded()))
    }

    /// Render at the requested density, retaining point geometry. The 1x image is for CSS cursors;
    /// the 3x overlay is displayed with explicit point dimensions by the client.
    static func png(_ img: NSImage, scale: Int) -> Data? {
        let w = Int(img.size.width.rounded()), h = Int(img.size.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
