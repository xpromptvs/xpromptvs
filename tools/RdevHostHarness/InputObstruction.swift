import AppKit

/// A STAND-IN FOR THE HOST'S OWN WINDOW STANDING IN THE WAY: an ordinary, clickable, host-owned
/// window opened over a given screen rectangle.
///
/// TEST-ONLY, behind `RDEV_OWN_WINDOW_OVER=x,y,w,h` (global points, TOP-LEFT origin — the space
/// `kCGWindowBounds` and the input injector use), for `scripts/smoke-desktop.sh`. The defect it
/// reproduces: display capture cuts this process's windows out of the picture, but a display
/// client's taps are real clicks at real coordinates, so a host window in front of what the client
/// sees took every tap over it — measured on the Mac mini as a desktop that "froze". The smoke puts
/// this over `WinTapTarget` and requires its taps to arrive there anyway.
///
/// **Everything the capture marker is NOT, on purpose.** It ACCEPTS mouse events (the marker ignores
/// them so it can never steal a click from the capture gate — this one exists to be in the way), it
/// sits at the ordinary level (the product's window is not floating, and a floating window would
/// test an arrangement nothing ships), and it records any click it gets, so a failure says WHERE the
/// tap went rather than only that it never arrived.
final class InputObstructionWindow {
    private let window: NSWindow

    /// `spec` is `x,y,w,h` in global top-left points; nil when it cannot be parsed.
    init?(spec: String) {
        let n = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4, n[2] > 0, n[3] > 0, let primary = NSScreen.screens.first else { return nil }
        // AppKit's origin is the PRIMARY screen's bottom-left, CoreGraphics' its top-left.
        let frame = NSRect(x: n[0], y: primary.frame.height - n[1] - n[3], width: n[2], height: n[3])
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "rdev own-window obstruction"
        window.backgroundColor = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        window.isOpaque = true
        window.contentView = ClickRecorder(frame: NSRect(origin: .zero, size: frame.size))
    }

    func show() {
        window.orderFrontRegardless()
        print("[obstruction] shown id=\(window.windowNumber) over \(Int(window.frame.width))x\(Int(window.frame.height))pt")
    }

    /// `RDEV_OWN_WINDOW_RETURNS=1`: two seconds after this application is HIDDEN, bring the window
    /// back — which unhides the whole application, exactly as a person at the Mac clicking the Dock
    /// icon, or the app raising its own window, does mid-session. Once only, so the smoke's taps
    /// meet exactly one return.
    func returnOnceAfterHide() {
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.window.orderFrontRegardless()
                print("[obstruction] RETURNED — the application is back in front of the display (hidden=\(NSApp.isHidden))")
            }
        }
    }

    /// Prints every click it receives. A tap that shows up here is a tap the client aimed at what it
    /// could see and delivered into this host's own, invisible, window.
    private final class ClickRecorder: NSView {
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            print("[obstruction] CLICK at \(Int(p.x)),\(Int(p.y)) — a display tap landed in this host's own window")
        }
    }
}
