import AppKit
import ShellstormCore
import WebKit

private final class SourceHeader: NSView {
    var onMenu: ((NSPoint) -> Void)?
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) { onMenu?(convert(event.locationInWindow, from: nil)) }
}

/// A presentation endpoint, never a connection. The related WKWebView owns its document/input realm;
/// the connection page retains the only receiving peer and hands this document its received stream.
@MainActor
final class NativeSourceWindow: AppWindow, WKUIDelegate {
    let sourceKey: NativeSourceWindowKey
    private(set) var specification: NativeSourceWindowManifest.Source
    private let documentTicket: String
    private(set) var closing = false
    private let root = NSView(), header = SourceHeader(), buttons = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let audioLabel = NSTextField(labelWithString: "")
    private var fullScreen = FullScreenOwnership()
    private var theme: String
    private var applying = false, ready = false, loaded = false, fullscreenChanging = false
    private var closeReason = "user"
    private var pendingMinimized: Bool?
    private var programmaticMinimized: Bool?
    private var minimizeRevision: UInt64 = 0
    private var minimizeWasKey = false
    private var programmaticFrame: NSRect?
    private var needsOpeningSize: Bool
    private var scrollObserver: NativeSourceScrollObserver?
    var onEvent: ((String, [String: Any]) -> Void)?
    var onRetire: ((NativeSourceWindow, String) -> Void)?
    var onGeometry: ((NSRect) -> Void)?
    private var chrome: NativeSimulatorWindow.Chrome { NativeSimulatorWindow.Chrome.shared }

    init(key: NativeSourceWindowKey, source: NativeSourceWindowManifest.Source, theme: String,
         frame: NSRect?, ticket: String, configuration: WKWebViewConfiguration) {
        documentTicket = ticket
        sourceKey = key; specification = source; self.theme = theme
        needsOpeningSize = source.width == nil || source.height == nil
        let win = NSWindow(contentRect: frame ?? NSRect(x: 140, y: 100, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(kind: .source, window: win, webView: AppWebView(frame: .zero, configuration: configuration))
        webView.uiDelegate = self
        window.tabbingMode = .disallowed
        window.level = .normal; window.collectionBehavior = [.fullScreenPrimary]
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false; window.minSize = NSSize(width: 260, height: 240)
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
        root.wantsLayer = true; root.layer?.cornerRadius = chrome.cornerRadius; root.layer?.masksToBounds = true
        window.contentView = root; header.wantsLayer = true
        titleLabel.font = NSFont(name: "DM Sans", size: chrome.titleSize) ?? .systemFont(ofSize: chrome.titleSize)
        titleLabel.lineBreakMode = .byTruncatingTail; titleLabel.isSelectable = false
        titleLabel.maximumNumberOfLines = 1
        // A remote title must truncate rather than become an Auto Layout minimum for the window.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal; buttons.spacing = 2
        audioLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        audioLabel.isSelectable = false; audioLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(audioLabel)
        header.onMenu = { [weak self] point in
            guard let self, point.x < self.buttons.frame.minX else { return }
            self.onEvent?("action", ["name": "menu", "x": point.x, "y": 0])
        }
        for view in [header, webView, titleLabel, buttons] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(header); root.addSubview(webView); header.addSubview(titleLabel); header.addSubview(buttons)
        if source.kind == .simulator {
            button("Home", icon: "home", action: #selector(home))
            button("Keyboard", icon: "keyboard", action: #selector(keyboard))
        }
        button("Settings", icon: "settings", action: #selector(settings))
        button("Fit", icon: "fit", action: #selector(fitAction))
        button("Full Screen", icon: "fullscreen", action: #selector(fullscreen))
        button("Minimize", icon: "minimize", action: #selector(minimize))
        button("Close", icon: "close", action: #selector(closeSource))
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: chrome.headerHeight),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor), webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor), webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14), titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -9),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -7), buttons.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        apply(source: source, theme: theme)
        if let frame { window.setFrame(frame, display: false) } else { fit() }
        if NativeSourceScrollObserver.enabled { scrollObserver = NativeSourceScrollObserver(view: webView) { [weak self] value in
            guard let self, !self.closing else { return }
            self.webView.evaluateJavaScript("window.__rdevNativeSourceScroll?.(\(BridgeScripts.json(value)))")
        } }
    }

    private func button(_ label: String, icon name: String, action: Selector) {
        let shape = chrome.icons[name]!
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform(); transform.scale(by: 18.0 / 24.0); transform.concat()
            NSColor.black.set()
            func stroke(_ path: NSBezierPath) { path.lineWidth = 1.7; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke() }
            for points in shape.lines {
                let path = NSBezierPath(); path.move(to: NSPoint(x: points[0], y: points[1]))
                for i in stride(from: 2, to: points.count, by: 2) { path.line(to: NSPoint(x: points[i], y: points[i + 1])) }
                stroke(path)
            }
            for c in shape.circles { let path = NSBezierPath(ovalIn: NSRect(x: c[0]-c[2], y: c[1]-c[2], width: 2*c[2], height: 2*c[2])); path.fill(); stroke(path) }
            for r in shape.rects { stroke(NSBezierPath(roundedRect: NSRect(x: r[0], y: r[1], width: r[2], height: r[3]), xRadius: r[4], yRadius: r[4])) }
            return true
        }
        image.isTemplate = true
        let control = NSButton(image: image, target: self, action: action)
        control.isBordered = false; control.toolTip = label; control.setAccessibilityLabel(label)
        control.widthAnchor.constraint(equalToConstant: 28).isActive = true
        control.heightAnchor.constraint(equalToConstant: 28).isActive = true
        buttons.addArrangedSubview(control)
    }
    private func color(_ hex: String) -> NSColor {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return NSColor(red: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255, blue: CGFloat(value & 255)/255, alpha: 1)
    }
    private func paint() {
        let palette = theme == "light" ? chrome.light : chrome.dark
        window.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
        root.layer?.backgroundColor = color(palette.body).cgColor; header.layer?.backgroundColor = color(palette.header).cgColor
        titleLabel.textColor = color(window.isKeyWindow ? palette.text : palette.muted)
        audioLabel.textColor = color(palette.muted)
        for case let control as NSButton in buttons.arrangedSubviews { control.contentTintColor = color(palette.muted) }
    }
    func apply(source: NativeSourceWindowManifest.Source, theme: String) {
        specification = source; self.theme = theme; window.title = source.title; titleLabel.stringValue = source.title
        audioLabel.stringValue = source.audioStatus.map { $0.state == .muted ? "muted" : "audio elsewhere" } ?? ""
        audioLabel.toolTip = source.audioStatus?.title; audioLabel.isHidden = source.audioStatus == nil
        paint()
        if pendingMinimized == source.minimized { pendingMinimized = nil }
        if needsOpeningSize, source.width != nil, source.height != nil { needsOpeningSize = false; fit() }
        showIfReady()
    }
    func documentReady() { ready = true; showIfReady() }
    func showIfReady() {
        guard ready, !NSApp.isHidden else { return }
        applying = true; defer { applying = false }
        if pendingMinimized != nil || programmaticMinimized != nil { return }
        if specification.minimized {
            if !window.isMiniaturized { programmaticMinimized = true; window.orderFront(nil); window.miniaturize(nil) }
        } else {
            if window.isMiniaturized { programmaticMinimized = false; window.deminiaturize(nil) }
            if !window.isVisible { window.orderFront(nil) } // A track/document arrival never takes focus.
        }
    }
    func activateSource() {
        guard ready else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(webView); NSApp.activate()
    }
    func fit() {
        guard !window.styleMask.contains(.fullScreen), let available = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let logical = CGSize(width: specification.width ?? (specification.kind == .simulator ? 390 : 800),
                             height: specification.height ?? (specification.kind == .simulator ? 844 : 600))
        applying = true; defer { applying = false }
        let target = NativeSimulatorGeometry.openingFrame(device: logical, header: chrome.headerHeight, available: available, previous: window.frame)
        programmaticFrame = target; window.setFrame(target, display: true)
    }
    func confirmSize(width: Int, height: Int) {
        guard specification.kind == .window, !window.styleMask.contains(.fullScreen) else { return }
        applying = true; defer { applying = false }
        guard let available = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let frame = NativeSimulatorGeometry.openingFrame(device: CGSize(width: width, height: height),
            header: chrome.headerHeight, available: available, previous: window.frame)
        programmaticFrame = frame; window.setFrame(frame, display: true)
    }
    func setFullscreen(_ on: Bool) {
        applyFullScreen(fullScreen.pageAsks(on, isFullScreen: window.styleMask.contains(.fullScreen)))
    }
    private func applyFullScreen(_ action: FullScreenOwnership.Action) {
        guard action == .toggle, !closing else { return }
        let request = fullScreen.requestID
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.fullScreen.toggleIgnored(id: request, isFullScreen: self.window.styleMask.contains(.fullScreen))
        }
    }
    func closeForOwner(_ reason: String) { closeReason = reason; window.close() }
    override func shouldClose() -> Bool {
        onEvent?("action", ["name": "close", "land": window.isKeyWindow]); return true
    }
    override func willClose() { scrollObserver?.invalidate(); closing = true; onRetire?(self, closeReason) }
    override func didCommitLoad() {
        guard NativeSourceDocument.ticket(url: webView.url) == documentTicket else { return }
        if loaded { onRetire?(self, "reload") } else { loaded = true }
    }
    override func loadFailed(_ error: any Error) {
        let value = error as NSError
        if value.domain != NSURLErrorDomain || value.code != NSURLErrorCancelled { onRetire?(self, "load-error") }
    }
    override func processGone() { onRetire?(self, "process") }
    override func keyChanged(_ key: Bool) { if !key { scrollObserver?.cancel() }; paint(); onEvent?("key", ["keyWindow": key]); visibilityChanged() }
    override func visibilityChanged() {
        onEvent?("visibility", ["visible": window.isVisible && !window.isMiniaturized && !NSApp.isHidden,
            "minimized": window.isMiniaturized, "keyWindow": window.isKeyWindow])
    }
    override func willMiniaturize() { minimizeWasKey = window.isKeyWindow }
    override func miniaturized(_ value: Bool) {
        guard window.isMiniaturized == value else { visibilityChanged(); return }
        let silent = programmaticMinimized == value
        programmaticMinimized = nil
        if !silent && !applying {
            pendingMinimized = value
            minimizeRevision &+= 1; let revision = minimizeRevision
            onEvent?("action", ["name": value ? "minimize" : "restore", "land": value && minimizeWasKey])
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.closing, self.minimizeRevision == revision, self.pendingMinimized == value else { return }
                self.pendingMinimized = nil; self.showIfReady()
            }
        }
        visibilityChanged()
        if silent { showIfReady() }
    }
    override func geometryChanged(resized: Bool) {
        onGeometry?(window.frame)
        let silent = programmaticFrame == window.frame
        if !silent { programmaticFrame = nil }
        if resized && !silent && !applying && !window.inLiveResize && !fullscreenChanging && !window.styleMask.contains(.fullScreen) { reportResize() }
    }
    private func reportResize() {
        guard specification.kind == .window else { return } // Displays/simulators resize their viewport, not the remote source.
        onEvent?("action", ["name": "resize", "width": Int(webView.bounds.width.rounded()), "height": Int(webView.bounds.height.rounded())])
    }
    override func liveResizeChanged(_ held: Bool) {
        webView.evaluateJavaScript("window.__rdevNativeSourceResize?.(\(held ? "true" : "false"))")
        if !held && !applying { reportResize() }
    }
    override func fullScreenWillChange() { fullscreenChanging = true; fullScreen.began() }
    override func fullScreenDidChange(failed: Bool) {
        fullscreenChanging = false
        let actual = window.styleMask.contains(.fullScreen)
        let landing = fullScreen.landed(isFullScreen: actual, failed: failed)
        // Don't echo an intermediate landing over a newer opposite request. It would reset the
        // desired state through the host before the next-turn settle can finish the early exit.
        if !landing.settle || fullScreen.want == actual {
            onEvent?("action", ["name": "fullscreen", "on": actual])
        }
        visibilityChanged()
        if landing.settle {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyFullScreen(self.fullScreen.settle(isFullScreen: self.window.styleMask.contains(.fullScreen)))
            }
        }
    }
    // Only the issued bundled document may navigate this view. No arbitrary same-origin content.
    override func navigationPolicy(_ action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = NativeSourceDocument.ticket(url: action.request.url) == documentTicket
        decisionHandler(allowed && action.targetFrame?.isMainFrame != false ? .allow : .cancel)
    }
    func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    @objc private func home() { onEvent?("action", ["name": "home"]) }
    @objc private func keyboard() { onEvent?("action", ["name": "keyboard"]) }
    @objc private func settings() { onEvent?("action", ["name": "settings"]) }
    @objc private func fitAction() { fit(); onEvent?("action", ["name": "fit"]) }
    @objc private func fullscreen() {
        if fullScreen.running || fullScreen.requested { setFullscreen(!fullScreen.want); return }
        let actual = window.styleMask.contains(.fullScreen)
        let action = fullScreen.pageAsks(!actual, isFullScreen: actual)
        // This is an explicit native user control, so it can also leave a fullscreen the
        // person entered through a system action (pageAsks deliberately preserves that case).
        if actual && action == .none { window.toggleFullScreen(nil) } else { applyFullScreen(action) }
    }
    #if RDEV_DEV_BUILD
    func captureNativeScrollForCheck(_ event: NSEvent, at: NSPoint) { scrollObserver?.capture(event, at: at) }
    var fullscreenCheckState: [String: Bool] {
        ["actual": window.styleMask.contains(.fullScreen), "running": fullScreen.running,
         "requested": fullScreen.requested, "want": fullScreen.want, "ours": fullScreen.ours]
    }
    #endif
    @objc private func minimize() { window.miniaturize(nil) }
    @objc private func closeSource() { window.performClose(nil) }
}
