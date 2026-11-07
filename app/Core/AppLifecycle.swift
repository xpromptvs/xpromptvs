/// Whether closing the last window quits the app — `applicationShouldTerminateAfterLastWindowClosed`'s
/// rule, pure so it is testable.
///
/// **AppKit does not count an ORDERED-OUT window** when it decides the last window has closed, and
/// a pending connect's client window is created ordered out (it is revealed on `connected`).
/// Electron's `window-all-closed` counted hidden windows, so closing the dashboard mid-connect left
/// the attempt running there; here it quit the app (measured, `e2e/app-lifecycle-check.mjs`). So a
/// client window that still EXISTS, visible or not, or an attempt that has not opened its window
/// yet, keeps the app alive. Sharing keeps it alive too — it lives on in the status item.
///
/// **So does a passkey ceremony IN FLIGHT** (`enrolling`, 2): its prompt is up and its grant is being
/// written, and quitting under it would leave a half-made identity (it was the browser-aided §12.1 —
/// closing the dashboard quit the app and killed it, measured with `app-enroll-check.mjs`, deleted with
/// the courier on 2026-10-06). `interrupted` (4) does NOT: it is a PERSISTED §9.2 operation this build
/// cannot resume, nothing runs for it in this process, and holding the app open for it would hold it
/// open forever. When the ceremony SETTLES (`ceremonySettled`) the rule is asked again.
///
/// **SO DO THE SESSION'S TABS** (2026-09-30, the local window): the session belongs to the app, not to
/// sharing, so shells open in This Mac keep the app running in the menu bar with every window closed.
/// When the last tab goes with no window open, the rule is asked again (`sessionEmptied`).
public enum AppLifecycle {
    /// `E2EStatusCode.enrolling` — a ceremony this process is running.
    static let ceremonyInFlight: Set<Int> = [2]

    public static func quitsAfterLastWindowClosed(sharing: Bool, clientWindows: Int, pendingConnects: Int,
                                                  e2eStatus: Int, sessionTabs: Int) -> Bool {
        !sharing && clientWindows == 0 && pendingConnects == 0 && !ceremonyInFlight.contains(e2eStatus)
            && sessionTabs == 0
    }

    /// True on the transition to NO tabs — the moment an app kept alive only by its tabs must re-ask the
    /// last-window rule. The first reading (`from` nil) is not one.
    public static func sessionEmptied(from: Int?, to: Int) -> Bool {
        guard let from else { return false }
        return from > 0 && to == 0
    }

    /// True on the transition OUT of an in-flight ceremony (to ready, back to unenrolled, …) — the
    /// moment an app kept alive only by it must re-ask the last-window rule.
    public static func ceremonySettled(from: Int?, to: Int) -> Bool {
        guard let from else { return false }
        return ceremonyInFlight.contains(from) && !ceremonyInFlight.contains(to)
    }

    /// The e2e statuses with a committed chain — `ready`, `readyListingNotConfirmed`, `readyPublicationRejected`.
    public static let readyStatuses: Set<Int> = [5, 7, 8]

    /// True on the transition INTO ready from anything else — a Mac enrolled while running (added by code, signed in)
    /// — the moment a room already sharing must start its listing (`SharingHost.publishIfReady`). The first reading is
    /// no transition: a Mac launched ready lists itself at its Share.
    public static func becameReady(from: Int?, to: Int) -> Bool {
        guard let from else { return false }
        return !readyStatuses.contains(from) && readyStatuses.contains(to)
    }
}
