import AppKit

/// The harness's pairing surface: a window IT OWNS, showing the connect QR and the pairing code.
///
/// TWO REASONS IT EXISTS, and the second is the one that made it urgent.
///
/// 1. IT MATCHES THE PRODUCT. The native app renders its pairing QR in its own window, and that
///    window is what §16 of the E2E protocol specification protects — the capture boundary excludes
///    the host's own application so the credential never reaches a client. The harness used to print
///    the same QR into the terminal that launched it, where no own-process exclusion can reach it.
///    Moving it here puts the harness's credential behind the same boundary the product's sits behind,
///    and lets `scripts/gate-capture-boundary.sh` exercise a REAL credential surface rather than only
///    a synthetic marker.
///
/// 2. WITHOUT A WINDOW, THE HARNESS CANNOT CAPTURE A DISPLAY AT ALL. ScreenCaptureKit lists an
///    application in `SCShareableContent.applications` only while it owns shareable windows, so a
///    process with none cannot name itself to the very API that would exclude it — and
///    `SelfCapture.displayExclusion` then refuses, correctly, because an empty exclusion list excludes
///    nothing and captures happily. MEASURED, not inferred: with the harness window-less,
///    `SCShareableContent` reported 63 applications and 275 windows across the machine and matched
///    THIS process zero times, with `onScreenWindowsOnly` false as well as true. `smoke-desktop.sh`
///    failed on exactly that ("no '[display] capturing display' line"). Owning a window fixes it at
///    the root instead of adding a flag that says "trust me".
///
/// WHAT STAYS ON STDOUT, deliberately: `PAIR code=<code> token=<token>` (five smokes parse it) and
/// `Pairing code: <code>` (four gates do). Those are frozen test contracts, and this window does not
/// pretend to have closed them — the SCANNABLE QR leaves the foreign terminal, the code strings do
/// not. §16 rule 6 stands: a provisioning path into a terminal the host does not own needs its own
/// treatment, and the harness's is a deliberate, documented test affordance rather than an oversight.
final class PairingWindow {

    private let window: NSWindow

    /// TOP-LEFT AND SMALL, ON PURPOSE. Several GUI smokes tap computed points on the desktop or on a
    /// target window, and a large host window in the middle of the screen would swallow those taps —
    /// which would present as "input is broken" rather than as "the harness grew a window". It is
    /// `.normal` level for the same reason: it must not cover a smoke's target.
    init(qr: [[Bool]]?, pairingCode: String, connectURL: String) {
        let size = NSSize(width: 300, height: 380)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Xpromptvs pairing (harness)"
        window.level = .normal
        window.backgroundColor = .white
        window.contentView = PairingView(qr: qr, code: pairingCode, url: connectURL)
        // NOTHING HERE IS INTERACTIVE — it is a QR and two strings — so it must never be able to
        // swallow an injected click. Several GUI smokes post CGEvents at computed screen points, and
        // a host window that ate one would present as "input is broken" rather than as "the harness
        // grew a window". Passing clicks through costs this window nothing and removes the whole
        // class of interference, wherever it happens to sit.
        window.ignoresMouseEvents = true
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: f.minX + 20, y: f.maxY - 20))
        }
    }

    func show() {
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the harness is an accessory app
        // driving someone else's session, and stealing key focus from whatever a smoke just raised is
        // exactly the kind of interference this window has to avoid.
        window.orderFrontRegardless()
    }
}

private final class PairingView: NSView {
    private let qr: [[Bool]]?
    private let code: String
    private let url: String

    init(qr: [[Bool]]?, code: String, url: String) {
        self.qr = qr; self.code = code; self.url = url
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        var y: CGFloat = 12
        if let qr, !qr.isEmpty {
            // A QUIET ZONE IS PART OF THE SYMBOL. Without a light border a scanner cannot find the
            // finder patterns, and the QR reads as simply not working rather than as badly rendered —
            // the terminal renderer pads for the same reason.
            let quiet = 2
            let modules = qr.count + quiet * 2
            let side = min(bounds.width - 24, 240)
            let cell = (side / CGFloat(modules)).rounded(.down)
            let dim = cell * CGFloat(modules)
            let originX = ((bounds.width - dim) / 2).rounded()
            NSColor.white.setFill()
            NSRect(x: originX, y: y, width: dim, height: dim).fill()
            NSColor.black.setFill()
            for (r, row) in qr.enumerated() {
                for (c, on) in row.enumerated() where on {
                    NSRect(x: originX + CGFloat(c + quiet) * cell,
                           y: y + CGFloat(r + quiet) * cell,
                           width: cell, height: cell).fill()
                }
            }
            y += dim + 10
        }

        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        draw(code, at: &y, font: mono, color: .black)
        draw(url, at: &y, font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular), color: .darkGray)
    }

    private func draw(_ s: String, at y: inout CGFloat, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let box = NSRect(x: 10, y: y, width: bounds.width - 20, height: 40)
        (s as NSString).draw(with: box, options: [.usesLineFragmentOrigin], attributes: attrs)
        y += 34
    }
}
