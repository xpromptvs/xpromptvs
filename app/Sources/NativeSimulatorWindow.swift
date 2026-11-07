import AppKit
import CoreText
import RdevCore
import RdevHostKit
import ShellstormCore

private final class SimulatorPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
private final class SimulatorHeader: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

@MainActor
final class NativeSimulatorWindow: NSObject, NSWindowDelegate {
    struct Chrome: Decodable {
        struct Palette: Decodable { let header: String, body: String, text: String, muted: String }
        let headerHeight: CGFloat, cornerRadius: CGFloat, titleSize: CGFloat
        struct Icon: Decodable { let lines: [[CGFloat]], circles: [[CGFloat]], rects: [[CGFloat]] }
        let icons: [String: Icon]
        let dark: Palette, light: Palette
        static let shared: Chrome = {
            let root = Bundle.main.resourceURL!.appendingPathComponent("web")
            CTFontManagerRegisterFontsForURL(root.appendingPathComponent("shellstorm/dm-sans.ttf") as CFURL, .process, nil)
            guard let data = try? Data(contentsOf: root.appendingPathComponent("window-chrome.json")),
                  let value = try? JSONDecoder().decode(Chrome.self, from: data) else {
                preconditionFailure("Missing window-chrome.json; rebuild through build:check")
            }
            return value
        }()
    }
    let source: String
    let generation: UInt64
    let window: NSWindow
    let picture = SimulatorMetalView(frame: .zero)
    private let header = SimulatorHeader()
    private let titleLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "Booting…")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private weak var localSession: LocalSimulatorSession?
    private let root = NSView()
    private let buttons = NSStackView()
    private var frameObservation: LocalSimulatorObservation?
    private var applying = false
    private var closingForHandoff = false
    private var simulatorState: SimState = .booting
    private var hasFrame = false
    private var needsOpeningSize = true
    private var lastTheme = "dark"
    private var lastState: NativeWindowState
    private let send: (InboundMessage) -> Void
    private lazy var input = NativeSimulatorInput(send: send)
    var onGeometry: ((NSRect) -> Void)?
    var onGone: (() -> Void)?

    init(state: NativeWindowState, generation: UInt64, frame: NSRect?, send: @escaping (InboundMessage) -> Void) {
        source = state.source; self.generation = generation; lastState = state; self.send = send
        window = SimulatorPanel(contentRect: frame ?? NSRect(x: 140, y: 100, width: 402, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.delegate = self; window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 260, height: 240)
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
        root.wantsLayer = true; root.layer?.cornerRadius = Chrome.shared.cornerRadius; root.layer?.masksToBounds = true
        window.contentView = root
        for view in [header, picture, status, retryButton] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        header.wantsLayer = true
        titleLabel.font = NSFont(name: "DM Sans", size: Chrome.shared.titleSize) ?? .systemFont(ofSize: Chrome.shared.titleSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(titleLabel)
        buttons.orientation = .horizontal; buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(buttons)
        button("Home", symbol: "home", action: #selector(home))
        button("Keyboard", symbol: "keyboard", action: #selector(keyboard))
        button("Settings", symbol: "settings", action: #selector(deviceMenu))
        button("Fit", symbol: "fit", action: #selector(fit))
        let gap = NSView(); gap.widthAnchor.constraint(equalToConstant: 9).isActive = true; buttons.addArrangedSubview(gap)
        button("Minimize", symbol: "minimize", action: #selector(minimize))
        button("Close", symbol: "close", action: #selector(closeTab))
        retryButton.target = self; retryButton.action = #selector(retryDisplay); retryButton.isHidden = true
        status.alignment = .center; status.font = .systemFont(ofSize: 13)
        status.wantsLayer = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: Chrome.shared.headerHeight),
            picture.topAnchor.constraint(equalTo: header.bottomAnchor), picture.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: root.leadingAnchor), picture.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14), titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -9),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -7), buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            retryButton.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            retryButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            status.centerXAnchor.constraint(equalTo: picture.centerXAnchor), status.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
        ])
        picture.event = { [weak self] event in guard let self else { return }; self.input.handle(event, in: self.picture) }
        picture.insert = { [weak self] text in self?.input.text(text) }
        picture.onError = { [weak self] message in self?.showStatus(message, retry: true) }
        if let frame { window.setFrame(frame, display: false) }
        apply(state: state, focused: false, statusText: "Booting…", theme: "dark")
    }
    private func button(_ label: String, symbol: String, action: Selector) {
        let b = NSButton(image: icon(symbol), target: self, action: action)
        b.isBordered = false; b.toolTip = label; b.setAccessibilityLabel(label)
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true; b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        buttons.addArrangedSubview(b)
    }
    private func icon(_ name: String) -> NSImage {
        let shape = Chrome.shared.icons[name]!
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            let t = NSAffineTransform(); t.scale(by: 18.0 / 24.0); t.concat()
            NSColor.black.set()
            func stroke(_ path: NSBezierPath) { path.lineWidth = 1.7; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke() }
            for points in shape.lines {
                let path = NSBezierPath(); path.move(to: NSPoint(x: points[0], y: points[1]))
                for i in stride(from: 2, to: points.count, by: 2) { path.line(to: NSPoint(x: points[i], y: points[i + 1])) }
                stroke(path)
            }
            for c in shape.circles { let p = NSBezierPath(ovalIn: NSRect(x: c[0]-c[2], y: c[1]-c[2], width: 2*c[2], height: 2*c[2])); p.fill(); stroke(p) }
            for r in shape.rects { stroke(NSBezierPath(roundedRect: NSRect(x: r[0], y: r[1], width: r[2], height: r[3]), xRadius: r[4], yRadius: r[4])) }
            return true
        }
        image.isTemplate = true
        return image
    }
    func attach(_ session: LocalSimulatorSession) {
        localSession = session
        let renderer = picture.renderer
        // Only size/liveness changes cross main. The per-frame path goes directly to Metal's mailbox.
        let stateLock = NSLock(); var signature = ""
        frameObservation = session.frames(source: source, generation: generation) { [weak self] frame in
            if let frame { renderer?.submit(frame) } else { renderer?.clear() }
            let next = frame.map { "\($0.surface.width)x\($0.surface.height):\($0.rotation.rawValue):\($0.pointScale)" } ?? "off"
            let changed = stateLock.withLock { () -> Bool in if next == signature { return false }; signature = next; return true }
            guard changed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closingForHandoff else { return }
                self.hasFrame = frame != nil
                if let frame {
                    self.picture.updateSize(frame)
                    if self.needsOpeningSize { self.needsOpeningSize = false; self.fit() }
                    self.picture.isHidden = false; self.status.isHidden = true; self.retryButton.isHidden = true
                    self.prepareScrollGestures(session)
                }
                else { self.input.nativeScrollSupported = false; self.input.release(); self.showStatus(self.offlineText) }
            }
        }
    }
    var nativeScrollReady: Bool { input.nativeScrollSupported }
    private func prepareScrollGestures(_ session: LocalSimulatorSession) {
        guard NativeSourceScrollObserver.enabled else { return }
        session.prepareScrollGestures(source: source, generation: generation) { [weak self, weak session] ready in
            DispatchQueue.main.async {
                guard let self, let session, !self.closingForHandoff, self.localSession === session, session.current(self.generation) else { return }
                self.input.nativeScrollSupported = ready
            }
        }
    }
    func apply(state: NativeWindowState, focused: Bool, statusText: String?, theme: String) {
        applying = true; defer { applying = false }
        lastState = state; lastTheme = theme
        window.title = state.title; titleLabel.stringValue = state.title
        let palette = theme == "light" ? Chrome.shared.light : Chrome.shared.dark
        header.layer?.backgroundColor = color(palette.header).cgColor
        root.layer?.backgroundColor = color(palette.body).cgColor
        titleLabel.textColor = color(focused ? palette.text : palette.muted)
        status.textColor = color(palette.muted)
        for case let b as NSButton in buttons.arrangedSubviews { b.contentTintColor = color(palette.muted) }
        if let statusText, !hasFrame { showStatus(statusText) }
        if state.minimized, !window.isMiniaturized { window.miniaturize(nil) }
        else if !state.minimized, window.isMiniaturized { window.deminiaturize(nil) }
        picture.renderer?.setVisible(!state.minimized)
    }
    func setDeviceState(_ state: SimState) { simulatorState = state; if !hasFrame { showStatus(offlineText) } }
    private var offlineText: String {
        switch simulatorState { case .shutdown: return "Shut down"; case .shuttingDown: return "Shutting down…"; default: return "Booting…" }
    }
    private func showStatus(_ message: String, retry: Bool = false) {
        status.stringValue = message; status.isHidden = false; picture.isHidden = true; retryButton.isHidden = !retry
    }
    @objc private func retryDisplay() {
        guard let session = localSession else { return }
        frameObservation?.cancel(); frameObservation = nil
        picture.retryRenderer(); attach(session)
    }
    func show(focus: Bool) {
        guard !lastState.minimized else { return }
        applying = true
        if focus { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(picture) } else { window.orderFront(nil) }
        applying = false
    }
    #if RDEV_DEV_BUILD
    func scrollForTest(dx: CGFloat, dy: CGFloat) {
        input.scroll(at: CGPoint(x: picture.pictureRect.midX, y: picture.pictureRect.midY), in: picture, dx: dx, dy: dy, precise: true)
    }
    #endif
    func closeForHandoff() {
        closingForHandoff = true; frameObservation?.cancel(); frameObservation = nil
        picture.renderer?.stop(); window.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingForHandoff { return true }
        closeTab(); return false
    }
    func windowWillClose(_ notification: Notification) { frameObservation?.cancel(); picture.renderer?.stop(); onGone?() }
    func windowDidBecomeKey(_ notification: Notification) {
        guard !applying else { return }
        send(.focusSource(source: source)); send(.setView(surface: .windows, fullscreen: nil))
    }
    func windowDidResignKey(_ notification: Notification) { input.release() }
    func windowDidMiniaturize(_ notification: Notification) { picture.renderer?.setVisible(false); if !applying { send(.minimizeWindow(source: source, land: true)) } }
    func windowDidDeminiaturize(_ notification: Notification) { picture.renderer?.setVisible(true); if !applying { send(.restoreWindow(source: source)) } }
    func windowDidMove(_ notification: Notification) { onGeometry?(window.frame) }
    func windowDidResize(_ notification: Notification) { onGeometry?(window.frame) }
    @objc private func closeTab() { send(.unsubscribe(source: source, land: window.isKeyWindow)) }
    @objc private func minimize() { window.miniaturize(nil) }
    @objc private func home() { send(.simAction(source: source, action: .home)) }
    @objc private func keyboard() { send(.simAction(source: source, action: .keyboard)) }
    @objc private func fit() {
        guard let available = (window.screen ?? NSScreen.main)?.visibleFrame,
              !window.styleMask.contains(.fullScreen) else { return }
        let frame = NativeSimulatorGeometry.openingFrame(device: picture.devicePointSize,
            header: Chrome.shared.headerHeight, available: available, previous: window.frame)
        // fullSizeContentView makes the custom header and framebuffer occupy the entire window frame.
        window.setFrame(frame, display: true)
    }
    @objc private func deviceMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let actions: [(String, SimAction)] = simulatorState == .booted
            ? [("Home", .home), ("App Switcher", .appSwitcher), ("Lock", .lock), ("Rotate Left", .rotateLeft),
               ("Rotate Right", .rotateRight), ("Shake", .shake), ("Volume Up", .volumeUp), ("Volume Down", .volumeDown),
               ("Siri", .siri), ("Shut Down", .shutdown)]
            : simulatorState == .shutdown ? [("Boot", .boot)] : []
        for (title, action) in actions {
            let item = NSMenuItem(title: title, action: #selector(deviceAction), keyEquivalent: "")
            item.target = self; item.representedObject = action.rawValue; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    @objc private func deviceAction(_ item: NSMenuItem) {
        if let name = item.representedObject as? String, let action = SimAction(rawValue: name) { send(.simAction(source: source, action: action)) }
    }
    private func color(_ hex: String) -> NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
