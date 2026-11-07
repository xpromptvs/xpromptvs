import AppKit
import ShellstormCore
import WebKit

/// Native controls around the client's web tabs. The web view occupies the entire window;
/// only these two margins intercept input (native-chrome.css reserves the same space).
@MainActor
final class ClientChrome: NSView {
    // The same source JSON Vite imports for the workbench and product CSS variables. No fallback
    // constants: a missing resource is a broken assembly, not a reason to show different chrome.
    private struct Metrics: Decodable {
        let barHeight: CGFloat
        let controlCenterY: CGFloat
        let leftGrip: CGFloat
        let rightGrip: CGFloat
        let controlLeft: CGFloat
        let controlSpacing: CGFloat
    }
    private static let metrics: Metrics = {
        guard let url = Bundle.main.url(forResource: "native-chrome", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let metrics = try? JSONDecoder().decode(Metrics.self, from: data) else {
            preconditionFailure("Missing or invalid native-chrome.json; rebuild through assemble-app.sh")
        }
        return metrics
    }()
    private let left = WindowGrip()
    private let right = WindowGrip()
    private let middle = WindowGrip()
    private let lights = TrafficLights()
    private var gap = ChromeGap.none
    private var pictureFullScreen = false
    var onZoom: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    /// The web view's size while `LockstepZoom` sizes it AHEAD of the window; nil, the window's.
    var webSizeOverride: CGSize? { didSet { if webSizeOverride != oldValue { needsLayout = true } } }
    let webView: WKWebView
    private(set) var controls: [NSButton] = []

    override var isFlipped: Bool { true }

    init(window: NSWindow, webView: WKWebView) {
        self.webView = webView
        super.init(frame: webView.frame)
        addSubview(webView)
        addSubview(left)
        addSubview(right)
        addSubview(middle)
        for grip in [left, right, middle] { grip.onZoom = { [weak self] in self?.onZoom?() } }
        // Use AppKit's controls, including their accessibility and native hover treatment (`TrafficLights` answers
        // the group question the title bar's container would). The originals remain owned by the title bar and are
        // hidden, not repositioned.
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let actions = [#selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:)),
                       #selector(NSWindow.toggleFullScreen(_:))]
        var size = NSSize.zero
        for (index, kind) in kinds.enumerated() {
            window.standardWindowButton(kind)?.isHidden = true
            guard let button = NSWindow.standardWindowButton(kind, for: window.styleMask) else { continue }
            button.target = window
            button.action = actions[index]
            if kind == .zoomButton { button.target = self; button.action = #selector(toggleClientFullScreen) }
            button.setFrameOrigin(NSPoint(x: CGFloat(index) * Self.metrics.controlSpacing, y: 0))
            lights.addSubview(button)
            controls.append(button)
            size = NSSize(width: max(size.width, button.frame.maxX), height: max(size.height, button.frame.height))
        }
        // The group sits where the buttons sat, each centred on `controlCenterY`.
        lights.frame = NSRect(x: Self.metrics.controlLeft, y: Self.metrics.controlCenterY - size.height / 2,
                              width: size.width, height: size.height)
        left.addSubview(lights)
    }

    @objc private func toggleClientFullScreen() { onToggleFullScreen?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The page's empty stretch, measured at its own `width` (`ChromeGap`: used only at that width).
    func setGap(_ gap: ChromeGap) {
        self.gap = gap
        needsLayout = true
    }

    func setPictureFullScreen(_ on: Bool) {
        pictureFullScreen = on
        middle.isHidden = on
        left.isHidden = on
        right.isHidden = on
    }

    override func layout() {
        super.layout()
        webView.frame = NSRect(origin: .zero, size: webSizeOverride ?? bounds.size)
        // A gap measured at another width is none: the page runs AHEAD of the window in a lockstep zoom.
        let span = gap.grip(windowWidth: bounds.width, leftGrip: Self.metrics.leftGrip, rightGrip: Self.metrics.rightGrip)
        if let span { middle.frame = NSRect(x: span.start, y: 0, width: span.end - span.start, height: Self.metrics.barHeight) }
        middle.isHidden = pictureFullScreen || span == nil
        left.frame = NSRect(x: 0, y: 0, width: Self.metrics.leftGrip, height: Self.metrics.barHeight)
        right.frame = NSRect(x: max(Self.metrics.leftGrip, bounds.width - Self.metrics.rightGrip), y: 0, width: Self.metrics.rightGrip, height: Self.metrics.barHeight)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = true
        }
    }
}

/// **THE TRAFFIC LIGHTS' GROUP, OUTSIDE THE TITLE BAR** (2026-10-04, reported: "window chrome traffic lights don't respond
/// to hover like native controls"). AppKit's own buttons (`_NSThemeWidget`) draw their hover glyphs (×, −, +) from
/// whether the mouse is in the GROUP, which they ask their superview (`-_mouseInGroup:` — the window's frame view,
/// `NSThemeFrame`, implements it for the title bar's own) — and they ask only when told the group was entered or left
/// (`-mouseEnteredOrExited`, which the frame sends its widgets). Moved here (`ClientChrome`), nobody answered and
/// nobody told them. This answers, from a tracking area over the three, and tells them on every enter and exit.
/// MEASURED off-screen on macOS 27 (the buttons rendered to a bitmap): answering alone changes nothing — the first
/// fix, which only redrew; answering plus `mouseEnteredOrExited` draws the glyphs (7,940 bytes of the three buttons'
/// render change), and back again restores the idle image exactly. PRIVATE, both: an AppKit that stops asking
/// leaves the buttons without their hover glyphs, as they were. A press between the buttons still drags the window
/// (the grip under it, `NSView.mouseDown` passing it on).
@MainActor
private final class TrafficLights: NSView {
    private var mouseInside = false {
        didSet {
            guard mouseInside != oldValue else { return }
            // What the window's frame does for its own buttons on an enter or exit: each re-asks `_mouseInGroup:`.
            let told = NSSelectorFromString("mouseEnteredOrExited")
            for b in subviews {
                if b.responds(to: told) { b.perform(told) }
                b.needsDisplay = true
            }
        }
    }
    override var isFlipped: Bool { true }

    /// Each button asks this when told the group was entered or left (`mouseEnteredOrExited`, above).
    @objc func _mouseInGroup(_ button: NSButton) -> Bool { mouseInside }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        syncWithPointer()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncWithPointer() }
    override func mouseEntered(with event: NSEvent) { mouseInside = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false }

    /// Where the pointer is NOW — a window that moved, or came back from the Dock, under a pointer that did not.
    private func syncWithPointer() {
        guard let window else { mouseInside = false; return }
        mouseInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

@MainActor
private final class WindowGrip: NSView {
    var onZoom: (() -> Void)?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onZoom?()
        } else {
            window?.performDrag(with: event)
        }
    }
}
