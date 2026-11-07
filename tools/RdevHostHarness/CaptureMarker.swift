import AppKit

/// A STAND-IN FOR THE PAIRING SURFACE: a window owned by the host process, on screen, painted one
/// saturated colour that nothing else on a test machine produces.
///
/// TEST-ONLY, behind `RDEV_CAPTURE_MARKER=1`, and it exists because §16 of the E2E protocol
/// specification cannot be gated without it. The rule is that a pairing secret must never reach
/// captured video, thumbnails or previews; the product renders that secret in a host window, and the
/// only way to prove the exclusion works is to put something in a host window and go looking for it
/// in what the client receives.
///
/// **Flat and static ON PURPOSE.** A real pairing panel is a still QR, and a QR cannot survive a
/// lossy encoder at thumbnail scale — decoding one would test the encoder, not the boundary. A large
/// flat field of a single extreme colour survives every codec, every scale and every colour-space
/// tag, so a detector for it answers exactly one question: did these pixels reach the client. The
/// liveness half of the oracle is the FOREIGN window's job (`tools/CaptureProbeTarget`), which
/// animates; a black frame or a stalled encoder must not be able to pass as protection.
///
/// **NEVER set `sharingType = .none` on this window.** That is AppKit's own per-window capture
/// exclusion, applied by the WindowServer before rdev sees anything — it would make every arm of the
/// gate pass while rdev's exclusion was removed entirely. The window is deliberately as capturable as
/// any other; the whole claim is that rdev refuses to capture it anyway.
final class CaptureMarkerWindow {

    /// Pure magenta. Chosen for distance from anything a desktop shows by accident and from the
    /// foreign probe's green, so "the marker leaked" and "capture is alive" can never be confused.
    /// The gate asserts this colour is ABSENT from the screen before the window opens, so an actual
    /// magenta wallpaper is refused as a precondition rather than silently believed.
    static let color = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

    private let window: NSWindow

    /// Large ON PURPOSE. Every detector downstream measures the marker as a FRACTION of the frame,
    /// and on a display capture a small window is a small fraction — which puts the leak threshold
    /// close to the noise floor and turns a security assertion into a margin call. At this size a
    /// real leak is tens of percent of the display and the threshold sits an order of magnitude below
    /// it, so the arm can be both sensitive and flake-free.
    init(size: NSSize = NSSize(width: 800, height: 800)) {
        // TITLED, and that is load-bearing rather than cosmetic. `ScreenCaptureSource.listWindows`
        // skips any window whose `SCWindow.title` is empty, and a BORDERLESS window has no title as
        // far as the WindowServer is concerned — so a borderless marker would be absent from the
        // source list no matter what `SelfCapture` did, and the gate's "the host's own window is
        // never listed" arm would pass while proving nothing. Measured, not assumed: the first run of
        // the gate failed because its foreign probe window was borderless and never appeared either.
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "rdev pairing (capture-boundary marker)"
        window.backgroundColor = Self.color
        window.isOpaque = true
        // ABOVE ordinary windows: for DISPLAY capture an occluded window contributes no pixels, so an
        // exclusion bug would look exactly like a pass. Floating keeps it in the display's picture.
        window.level = .floating
        window.ignoresMouseEvents = true          // never steal a click from whatever else is under test
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
    }

    /// Show and hide on a cycle, forever.
    ///
    /// THE CYCLE IS THE TEST, not a convenience. §16's rule is that exclusion is by APPLICATION and
    /// never by a snapshot of window ids: a window-id list is fixed when the stream is built, so a
    /// host window that appears AFTERWARDS is never excluded — and "start sharing, then open pairing"
    /// is the normal order of operations. Opening this window only at launch would let a snapshot
    /// implementation pass. Closing and reopening it mid-stream covers the same rule from the other
    /// side, and costs nothing.
    func startCycling(shownSeconds: Double = 6, hiddenSeconds: Double = 3) {
        func show() {
            // THIS ALSO UN-HIDES THE APPLICATION, and the gate depends on it. A display taking input
            // focus hides this process (`OwnWindows`), and a hidden marker would make every capture
            // arm after the display subscribe pass for free. MEASURED 2026-09-25: `orderFrontRegardless`
            // on a hidden app's window unhides the whole app and posts `didUnhideNotification` — so
            // the marker comes back on its next cycle, exactly as a pairing window opened at the Mac
            // mid-session would. An explicit unhide here was tried and changed nothing.
            window.orderFrontRegardless()
            // The id is how the gate asks the second question: the marker window must not merely be
            // absent from the pixels, it must be absent from `list-sources`, and subscribing to it by
            // explicit id must yield nothing. `windowNumber` is only assigned once a window is
            // ordered in, which is why this prints here and not in `init`.
            print("[marker] shown id=\(window.windowNumber) — \(Int(shownSeconds))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + shownSeconds) { hide() }
        }
        func hide() {
            window.orderOut(nil)
            print("[marker] hidden — \(Int(hiddenSeconds))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + hiddenSeconds) { show() }
        }
        show()
    }
}
