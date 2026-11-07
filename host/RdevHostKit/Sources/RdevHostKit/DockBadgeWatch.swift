import AppKit
import ApplicationServices
import Foundation
import RdevCore

/// A WINDOW TAB'S BELL — the HOST's half (docs/window-capture-and-input.md, "A window's bell"). Reads the
/// Dock's application badges about once a second while the session has windows and a driver, and rings
/// (`onRing`) the session's windows of every application whose badge ROSE (`DockBadge`, `DockBadgeBaseline`).
/// SimManager sends each group to the driver as a `window-bell`.
///
/// All mutable state is confined to `queue`; the reader, the owner lookup and `onRing` run on it, never under
/// SimManager's or the hub's lock.
/// @unchecked Sendable: `timer`, `targets`, `baseline` are only ever touched on `queue`.
final class DockBadgeWatch: @unchecked Sendable {
    /// One window of the session: its source id and its owner's pid.
    struct Target: Equatable { let source: String; let pid: pid_t }

    private let queue = DispatchQueue(label: "rdev.dock.badges")
    private let intervalMs: Int
    private var timer: DispatchSourceTimer?
    private var targets: [Target] = []
    private var baseline = DockBadgeBaseline()

    /// One reading of the Dock, or nil when it cannot be read at all (no Accessibility, no Dock process, its
    /// tree failing) — a tick that changes nothing. Tests supply their own.
    var read: () -> DockReading? = { DockBadgeReader.read() }
    /// The application that owns `pid`: its bundle path (symlinks resolved) and identifier. Tests supply
    /// their own.
    var appOf: (pid_t) -> (path: String?, bundleID: String?) = { DockBadgeReader.app(pid: $0) }
    /// Every window of one application whose badge rose, in the session's order. Called on `queue`.
    var onRing: (([String]) -> Void)?

    /// `intervalMs`: the poll period — ~1 s in the product; tests pass a long one and `pollForTests`.
    init(intervalMs: Int = 1000) { self.intervalMs = intervalMs }

    /// Watch these windows — or nothing, which STOPS the poll (no driver, or no window). A start reads the
    /// Dock at once, and that reading is the BASELINE: a badge already showing is not news.
    func setTargets(_ next: [Target]) {
        queue.async { [self] in
            targets = next
            if next.isEmpty { timer?.cancel(); timer = nil; baseline.reset(); return }
            guard timer == nil else { return }
            baseline.reset()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
            t.setEventHandler { [weak self] in self?.poll() }
            timer = t
            t.resume()
            poll()
        }
    }

    /// TEST-ONLY: one tick, now, and wait for it.
    func pollForTests() { queue.sync { poll() } }
    /// TEST-ONLY: whether the poll is running.
    var isWatchingForTests: Bool { queue.sync { timer != nil } }

    private func poll() {
        guard !targets.isEmpty, let reading = read() else { return }
        let items = reading.items
        let rose = baseline.observe(reading)
        guard !rose.isEmpty else { return }
        let windows = targets.map { t -> WindowOwnerApp in
            let a = appOf(t.pid)
            return WindowOwnerApp(source: t.source, path: a.path, bundleID: a.bundleID)
        }
        for group in DockBadge.ringing(windows: windows, items: items, rose: rose) { onRing?(group) }
    }
}

/// The Dock's AX tree, read. The Dock lists each running application (and each kept in it) as an
/// `AXApplicationDockItem` under its `AXList`, with `AXURL` (the bundle) and `AXStatusLabel` (the badge's
/// text, absent with none) — measured 2026-10-02 (`Telegram` "..21", `System Settings` "1"). It carries no
/// attribute for a BOUNCE. Fails closed and quietly: no Accessibility, no Dock, or a failure reading its TREE
/// (the app's lists, a list's items) reads as nil — a tick that changes nothing. A failure reading one ITEM is
/// that item's alone (`reading(dock:raw:)`).
///
/// EVERY ELEMENT READ CARRIES THE 0.25 s TIMEOUT (review F2): `AXUIElementSetMessagingTimeout` on an element
/// sets it for THAT element only, so the app's alone left every list and item read on the 6 s default. Never
/// on the system-wide element — that would change every AX call the host makes.
enum DockBadgeReader {
    static let timeout: Float = 0.25

    /// One item as AX answered: its subrole and bundle (nil when unread), and its badge read's own result.
    struct RawItem {
        let subrole: String?
        let url: URL?
        let labelError: AXError
        let label: AnyObject?
    }

    static func read() -> DockReading? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let lists = children(app) else { return nil }
        var raw: [RawItem] = []
        for list in lists {
            guard let items = children(list) else { return nil }
            for item in items {
                AXUIElementSetMessagingTimeout(item, timeout)
                let (labelError, label) = copy(item, "AXStatusLabel")
                raw.append(RawItem(subrole: copy(item, kAXSubroleAttribute).1 as? String,
                                   url: copy(item, "AXURL").1 as? URL, labelError: labelError, label: label))
            }
        }
        return reading(dock: dock.processIdentifier, raw: raw)
    }

    /// PURE: what the raw answers mean. Only application items with a bundle count; one whose subrole or
    /// bundle could not be read is LEFT OUT (its baseline survives one missing reading, `DockBadgeBaseline`).
    static func reading(dock: pid_t, raw: [RawItem],
                        bundleID: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }) -> DockReading {
        DockReading(dock: dock, items: raw.compactMap { r in
            guard r.subrole == "AXApplicationDockItem", let url = r.url else { return nil }
            return DockItemReading(path: path(url), bundleID: bundleID(url), label: label(r.labelError, r.label))
        })
    }

    /// PURE (review F1): a badge read's result. NO BADGE is only what AX says is no value — `.noValue`, or an
    /// item that has no such attribute (`.attributeUnsupported`); a success carrying a blank string too. ANY
    /// OTHER failure (`.cannotComplete` — the Dock busy or a timeout —, `.invalidUIElement`, …) or a success
    /// that is not a string is UNREADABLE, which keeps the item's baseline: recorded as "no badge", the next
    /// good read of the same label was a rise.
    static func label(_ error: AXError, _ value: AnyObject?) -> DockLabel {
        switch error {
        case .success:
            guard let s = value as? String else { return .unreadable }
            return DockBadge.label(s) == nil ? .none : .badge(s)
        case .noValue, .attributeUnsupported:
            return .none
        default:
            return .unreadable
        }
    }

    /// The application owning `pid`, named as a Dock item is: its bundle path, symlinks resolved.
    static func app(pid: pid_t) -> (path: String?, bundleID: String?) {
        guard let a = NSRunningApplication(processIdentifier: pid) else { return (nil, nil) }
        return (a.bundleURL.map(path), a.bundleIdentifier)
    }

    static func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    /// `e`'s children, its timeout set first — nil when the read failed (not an empty list).
    private static func children(_ e: AXUIElement) -> [AXUIElement]? {
        AXUIElementSetMessagingTimeout(e, timeout)
        let (err, v) = copy(e, kAXChildrenAttribute)
        guard err == .success else { return nil }
        return v as? [AXUIElement]
    }

    private static func copy(_ e: AXUIElement, _ attr: String) -> (AXError, AnyObject?) {
        var v: AnyObject?
        let err = AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        return (err, err == .success ? v : nil)
    }
}
