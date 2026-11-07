import AppKit
import QuartzCore
import RdevHostKit

@MainActor
final class SimulatorMetalView: NSView, @preconcurrency NSTextInputClient {
    private var marked = NSAttributedString(string: "")
    private var interpreting: NSEvent?
    private var interpretingComposition = false
    private var forwardedKeys = Set<UInt16>()
    var insert: ((String) -> Void)?
    private let metal = CAMetalLayer()
    private(set) var renderer: SimulatorMetalRenderer?
    private(set) var devicePointSize = CGSize(width: 402, height: 874)
    private var shownSize = CGSize(width: 402, height: 874)
    var onError: ((String) -> Void)?
    var onFrameSize: ((CGSize) -> Void)?
    var event: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer = metal
        retryRenderer()
    }
    func retryRenderer() {
        renderer?.stop()
        do {
            renderer = try SimulatorMetalRenderer(layer: metal)
            renderer?.onError = { [weak self] message in DispatchQueue.main.async { self?.onError?(message) } }
        } catch { renderer = nil; DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) } }
        updateViewport()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var pictureRect: CGRect {
        let fit = min(bounds.width / shownSize.width, bounds.height / shownSize.height)
        let size = CGSize(width: shownSize.width * fit, height: shownSize.height * fit)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
    func updateSize(_ frame: SimulatorSurfaceFrame) {
        let size = frame.rotation.shownSize(nativeW: frame.surface.width, nativeH: frame.surface.height)
        shownSize = CGSize(width: size.w, height: size.h)
        devicePointSize = CGSize(width: Double(size.w) / frame.pointScale, height: Double(size.h) / frame.pointScale)
        onFrameSize?(devicePointSize)
    }
    override func layout() { super.layout(); updateViewport() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateViewport() }
    private func updateViewport() {
        let scale = window?.backingScaleFactor ?? 1
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        renderer?.setViewport(size: bounds.size, scale: scale)
    }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); event?(e) }
    override func mouseDragged(with e: NSEvent) { event?(e) }
    override func mouseUp(with e: NSEvent) { event?(e) }
    override func scrollWheel(with e: NSEvent) { event?(e) }
    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) { forwardKey(e); return }
        interpretingComposition = hasMarkedText()
        interpreting = e; interpretKeyEvents([e]); interpreting = nil
    }
    private func forwardKey(_ e: NSEvent) { forwardedKeys.insert(e.keyCode); event?(e) }
    override func doCommand(by selector: Selector) { if let e = interpreting { forwardKey(e) } }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        let composed = interpretingComposition || hasMarkedText()
        marked = NSAttributedString(string: "")
        // NSTextInputClient still handles dead keys/IME commits. A normal physical ASCII key keeps
        // its down/up lifetime instead of simText synthesizing an immediate up (and releasing Shift).
        if let e = interpreting, !composed, text == e.characters,
           !e.modifierFlags.contains(.option), text.utf8.count == 1, text.utf8.first! < 128 {
            forwardKey(e)
        } else { insert?(text) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(pictureRect, to: nil)) ?? .zero
    }
    override func keyUp(with e: NSEvent) { if forwardedKeys.remove(e.keyCode) != nil { event?(e) } }
    override func flagsChanged(with e: NSEvent) { event?(e) }
}
