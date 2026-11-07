import AppKit
import ShellstormCore
import WebKit

/// Runs `LockstepResize` for one client window (docs/desktop-app.md, "Expand and restore"). Each step:
/// the web view is sized first (through `ClientChrome.webSizeOverride`, so nothing re-lays it out to the
/// window meanwhile), and the window moves inside WebKit's presentation callback for that size — the
/// turn that applied the page's commit, before Core Animation flushes it. The next step starts on the
/// following main-queue turn, outside WebKit's commit dispatch.
///
/// For the run, WKWebView's layer-hosting subview stops clipping (`overflowHost`): a SHRUNKEN web view
/// then keeps showing the page laid out for the window it is still in, until the commit for its new size
/// arrives with the window that matches it. Without that view (another WebKit) a shrinking dimension
/// follows the window and its stale page is clipped for one step; without the presentation SPI every step
/// is a display frame, as before.
@MainActor
final class LockstepZoom {
    /// A step whose presentation never comes — a hung or reloading page — moves the window anyway.
    static let stepTimeout: TimeInterval = 0.12
    private static let presentationSPI = NSSelectorFromString("_doAfterNextPresentationUpdate:")

    private let window: NSWindow
    private let chrome: ClientChrome
    private var plan: LockstepResize?
    private var step = 0
    private var overflowHost: NSView?
    private var onDone: (() -> Void)?
#if RDEV_DEV_BUILD
    /// `e2e/app-chrome-check.mjs`'s mutations, each of which must fail its arm: `animator` is the 240 ms
    /// `animator().setFrame` this replaced, `nowait` moves the window without waiting for the page,
    /// `noclip` keeps WebKit's clip on.
    var mutation: String?
#endif

    init(window: NSWindow, chrome: ClientChrome) {
        self.window = window
        self.chrome = chrome
    }

    var running: Bool { plan != nil }

    /// Animate to `target` (a window frame); `done` runs once it lands, never after `cancel`.
    func run(to target: NSRect, duration: TimeInterval, done: @escaping () -> Void) {
        cancel()
#if RDEV_DEV_BUILD
        if mutation == "animator" {   // the design this replaced, as the check's negative control
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                window.animator().setFrame(target, display: true)
            } completionHandler: { done() }
            return
        }
#endif
        plan = LockstepResize(from: window.frame, to: target, start: CACurrentMediaTime(), duration: duration)
        onDone = done
        overflowHost = releaseClip()
        advance()
    }

    /// Stop where the window is, and give WebKit back its clip and the web view back to the window.
    func cancel() {
        guard plan != nil else { return }
        end()
    }

    private func advance() {
        guard let plan else { return }
        step += 1
        let token = step
        let (frame, last) = plan.frame(at: CACurrentMediaTime())
        let target = window.contentRect(forFrameRect: frame).size
        chrome.webSizeOverride = LockstepResize.webSize(showing: chrome.bounds.size, target: target,
                                                        overflows: overflowHost != nil)
        // The size leaves NOW: `setFrameSize:` is where WKWebView sends it to the web process.
        chrome.layoutSubtreeIfNeeded()
        var moved = false
        let move = { [weak self] in
            guard let self, !moved, self.step == token, self.plan != nil else { return }
            moved = true
            self.chrome.webSizeOverride = nil
            self.window.setFrame(frame, display: true)
            if last { let done = self.onDone; self.end(); done?() }
            else { DispatchQueue.main.async { [weak self] in self?.advance() } }
        }
        let presents = chrome.webView.responds(to: Self.presentationSPI)
#if RDEV_DEV_BUILD
        let wait = presents && mutation != "nowait"
#else
        let wait = presents
#endif
        if wait {
            typealias AfterNextPresentation = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
            let call = unsafeBitCast(chrome.webView.method(for: Self.presentationSPI), to: AfterNextPresentation.self)
            call(chrome.webView, Self.presentationSPI) { move() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wait ? Self.stepTimeout : 1.0 / 60)) { move() }
    }

    private func end() {
        plan = nil
        onDone = nil
        step += 1
        chrome.webSizeOverride = nil
        overflowHost?.clipsToBounds = true
        overflowHost = nil
    }

    /// WKWebView's layer-hosting view (`WKFlippedView`) clips the page to the web view's frame: WebKit asks
    /// AppKit for it with its layer contents placement. Released only for a run, and only if it is there.
    private func releaseClip() -> NSView? {
#if RDEV_DEV_BUILD
        if mutation == "noclip" { return nil }
#endif
        guard let host = chrome.webView.subviews.first(where: {
            String(describing: type(of: $0)) == "WKFlippedView" && $0.clipsToBounds
        }) else { return nil }
        host.clipsToBounds = false
        return host
    }
}
