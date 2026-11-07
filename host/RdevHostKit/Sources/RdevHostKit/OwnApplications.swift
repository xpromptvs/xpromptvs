import AppKit
import Foundation
import ScreenCaptureKit
import RdevCore

/// The last `SCRunningApplication` this process resolved for itself.
///
/// ScreenCaptureKit lists an application in `SCShareableContent.applications` only while it HAS
/// shareable windows, so a host whose windows are all closed cannot name itself to the API that
/// would exclude it — and the product keeps sharing with every window closed. Holding the object
/// across that gap is what lets the exclusion survive it. See `SelfCapture.displayExclusion` for why
/// this is free in safety terms: an application exclusion is evaluated per frame, so an object
/// resolved while a window existed goes on excluding windows opened later.
///
/// Process-lifetime and never invalidated: it identifies THIS process, and a process does not stop
/// being itself when its last window closes.
private final class OwnApplicationMemory: @unchecked Sendable {
    static let shared = OwnApplicationMemory()
    private let lock = NSLock()
    private var apps: [SCRunningApplication] = []

    func remember(_ resolved: [SCRunningApplication]) {
        guard !resolved.isEmpty else { return }
        lock.lock(); apps = resolved; lock.unlock()
    }

    var recalled: [SCRunningApplication] {
        lock.lock(); defer { lock.unlock() }; return apps
    }
}

/// Note this process's own application if this content snapshot happens to name it.
///
/// Called from the LISTING paths as well as the filter paths, and deliberately so: listing runs often
/// and early, so by the time a display stream is built the memory is usually already warm — including
/// when the host's own window has closed in between.
func rememberOwnApplication(in content: SCShareableContent) {
    OwnApplicationMemory.shared.remember(matchingSelf(in: content))
}

private func matchingSelf(in content: SCShareableContent) -> [SCRunningApplication] {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    return content.applications.filter {
        SelfCapture.isOwnWindow(ownerPID: $0.processID, selfPID: selfPID)
    }
}

/// Resolve this process's own applications for a display exclusion filter, or refuse.
///
/// SHARED BY BOTH DISPLAY PATHS — `ScreenCaptureSource.makeFilter` and
/// `SourceThumbnailer.captureDisplay` — because the two must not drift: a rule enforced on the video
/// path and forgotten on the thumbnail path is exactly how the first version of this fix left the
/// cheapest route out wide open.
///
/// RETURNS nil TO MEAN REFUSE. `SCContentFilter(display:excludingApplications:exceptingWindows:)`
/// with an EMPTY array excludes nothing and captures happily, so a failure to resolve our own
/// `SCRunningApplication` would otherwise yield a stream that looks protected and is not. That is
/// fail-open, and invisible — the same shape as the defect the exclusion exists to remove.
///
/// CURRENT WINDOW VISIBILITY IS STILL NOT AN INPUT to what gets excluded; what changed is that a
/// snapshot which omits us no longer reads as "unresolvable". The rule itself lives in
/// `SelfCapture.displayExclusion`, pure and tested.
/// A cold cache is bootstrapped asynchronously without displaying or focusing a window.
func ownApplications(in content: SCShareableContent) async -> [SCRunningApplication]? {
    let current = matchingSelf(in: content)
    OwnApplicationMemory.shared.remember(current)
    if let resolved = SelfCapture.displayExclusion(current: current,
                                                   remembered: OwnApplicationMemory.shared.recalled) {
        return resolved
    }
    return await OwnApplicationBootstrap.resolve()
}

/// A cold background host may never have had a window in an SCK listing. In that case the
/// memory alone cannot help (staging Mac mini, 2026-10-21: no desktop preview or video until
/// someone opened the app). Give WindowServer a window to attribute, WITHOUT showing it.
/// Measured: a titled NSWindow with defer:false appears in an all-windows SCK query even when
/// never ordered in. Only its application identity is retained; the window carries no content.
@MainActor private enum OwnApplicationBootstrap {
    private static var pending: Task<[SCRunningApplication]?, Never>?

    static func resolve() async -> [SCRunningApplication]? {
        if let remembered = SelfCapture.displayExclusion(current: [SCRunningApplication](),
                                                         remembered: OwnApplicationMemory.shared.recalled) {
            return remembered
        }
        if let pending { return await pending.value }
        // Capture is an AppKit host's job. Do not create NSApplication or prompt for permissions
        // from a background/library caller that has not established a WindowServer connection.
        guard NSApp != nil else { return nil }
        let task = Task { @MainActor () -> [SCRunningApplication]? in
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 32, height: 32),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Capture identity"
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            // NEVER order this window in: that can unhide the host's other windows, stealing
            // display input and exposing UI locally. Creation alone is enough for attribution.
            defer { window.close() }
            for attempt in 0..<3 {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                    let own = matchingSelf(in: content)
                    if !own.isEmpty {
                        OwnApplicationMemory.shared.remember(own)
                        return own
                    }
                } catch {
                    print("[capture] own application resolution failed: \(error)")
                    return nil
                }
                if attempt < 2 { try? await Task.sleep(nanoseconds: 50_000_000) }
            }
            // Keep the security boundary fail-closed, and allow a later request to retry.
            return nil
        }
        pending = task
        let result = await task.value
        pending = nil
        return result
    }
}
