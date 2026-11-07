import Foundation

/// Whether a window belongs to the host itself, and therefore must never reach a client.
///
/// WHY THIS EXISTS — it is a security boundary, not a cosmetic one. The host renders the pairing QR
/// (and the pairing code beside it) in its own window, for the WHOLE sharing session, not for a
/// short ceremony. Anything that carries that window to a client carries the pairing secret, and
/// anyone who can read it can derive the token and pair a device of their own with full control of
/// the Mac. That is an escalation from "may watch" to "may type".
///
/// THERE ARE FOUR PATHS OUT, and the first fix here closed only one of them:
///
///   1. display video      — a captured display containing our window
///   2. display thumbnails — the same, over the control channel
///   3. WINDOW VIDEO       — a client subscribing to `win:<our own window>`
///   4. WINDOW THUMBNAILS  — `request-thumbs` captures EVERY enumerated window and returns a JPEG of
///                           each, TO ANY CLIENT, WITH NO SUBSCRIPTION. One message, no setup.
///
/// Path 4 is the cheapest attack of the four and was open until the second fix. "A single-window
/// source is an explicit act by the user" was the argument for leaving 3 and 4 alone; it does not
/// hold, because a legitimate selection still discloses the secret to everything on the media path,
/// and path 4 involves no selection at all.
///
/// THE ARGUMENT ORIGINALLY REPLACED, in `ScreenCaptureSource.makeFilter`: nothing was excluded
/// because "the hall-of-mirrors case needs a client running ON the captured Mac, which is not the
/// deployment model". That treats the threat as GEOGRAPHIC. The secret does not leak by being looked
/// at; it leaks by being ENCODED INTO THE STREAM, which reaches wherever the stream reaches.
/// Distance is not the boundary; the data path is.
///
/// DISPLAY CAPTURE EXCLUDES BY APPLICATION, NOT BY A LIST OF WINDOW IDS. A window-id list is a
/// SNAPSHOT taken when the stream is built, and `reconfigure()` re-resolves the subject but keeps
/// only the size and scale — it discards the new filter. So a host window that appears AFTER the
/// stream started is never excluded, which is precisely the normal order of operations: start
/// sharing, then open pairing. `SCContentFilter(display:excludingApplications:exceptingWindows:)`
/// is evaluated by ScreenCaptureKit per frame and has no such window.
///
/// PURE, so the predicate is testable without ScreenCaptureKit, a GUI session or a TCC grant.
public enum SelfCapture {
    /// Is a window owned by this process, and therefore ineligible for capture, thumbnailing or
    /// listing?
    ///
    /// MATCHED ON PID, NOT ON BUNDLE IDENTIFIER. The product links this code INSIDE the
    /// native app (`docs/desktop-app.md`), so the windows to deny are that process's own and
    /// `getpid()` names it exactly. A bundle-identifier match would have to agree with whichever
    /// front-end loaded the library — `ai.xpromptvs.app` for the app, `dev.rdev.host` for the harness —
    /// and would silently deny NOTHING on a front-end nobody remembered to add, which looks exactly
    /// like working.
    ///
    /// An UNKNOWN owner (no owning application) is treated as OURS — fail closed. A window whose
    /// provenance cannot be established is not worth streaming, and the alternative is a hole that
    /// opens whenever ScreenCaptureKit declines to attribute a window.
    public static func isOwnWindow(ownerPID: Int32?, selfPID: Int32) -> Bool {
        guard let ownerPID else { return true }
        return ownerPID == selfPID
    }

    /// What a display filter should do.
    ///
    /// AN EMPTY EXCLUSION LIST IS NOT PROTECTION. `SCContentFilter(display:excludingApplications:)`
    /// with an empty array excludes nothing and captures happily, so a failure to resolve our own
    /// `SCRunningApplication` would otherwise produce a stream that looked protected and was not —
    /// fail-open, and invisible.
    ///
    /// CURRENT WINDOW VISIBILITY IS NOT AN INPUT, AND THAT IS THE WHOLE POINT. An earlier version of
    /// this decision returned "nothing to exclude" whenever the host had no windows on screen right
    /// now, **even when the application had resolved**. That reopened the exposure the switch to
    /// application scoping existed to close:
    ///
    ///   1. the host's windows are all closed — sharing continues, the app permits this and lives in
    ///      the status item (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed`)
    ///   2. a display stream starts, sees no own windows, and is built with an EMPTY exclusion list
    ///   3. the host window reopens and shows the pairing QR
    ///   4. the stream excludes nothing, and `reconfigure()` re-resolves the subject but keeps only
    ///      size and scale — it discards the new filter, so nothing ever corrects it
    ///
    /// An application exclusion is DYNAMIC: it covers windows that application opens later. So if the
    /// application resolved, exclude it — always, whether or not it currently has windows. A
    /// point-in-time observation of window visibility can only ever describe the past.
    ///
    /// THERE IS DELIBERATELY NO HEADLESS ESCAPE HATCH. A host that cannot be resolved refuses display
    /// capture rather than proceeding unprotected, rather than inferring one from "no windows just
    /// now". What makes that affordable is `displayExclusion` below, which gives the resolution a
    /// MEMORY — so "no windows just now" stops being the same thing as "unresolvable".
    public enum DisplayFilterDecision: Equatable, Sendable {
        case exclude
        case refuse
    }

    public static func displayFilterDecision(ownApplicationResolved: Bool) -> DisplayFilterDecision {
        ownApplicationResolved ? .exclude : .refuse
    }

    /// What to hand `SCContentFilter(display:excludingApplications:)`, or nil to refuse.
    ///
    /// THE RESOLUTION HAS A MEMORY, and it needs one. ScreenCaptureKit lists an application in
    /// `SCShareableContent.applications` only while it HAS shareable windows, so a host whose windows
    /// are all closed cannot name itself to the very API that would exclude it — and the product
    /// keeps sharing with every window closed (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed`).
    /// Without memory the rule above then refuses display capture outright, which is safe and also
    /// breaks the feature: MEASURED by `scripts/gate-capture-boundary.sh`, whose display arm received
    /// no frames at all and whose host logged "REFUSING display 1: own application unresolved".
    ///
    /// Remembering costs nothing in safety because an application exclusion is DYNAMIC — SCK
    /// evaluates it per frame — so an object resolved while a window existed keeps excluding windows
    /// that open later, which is exactly the property the switch to application scoping bought. The
    /// identity is this process, and a process does not stop being itself when its last window
    /// closes.
    ///
    /// A host that has NEVER been resolvable still refuses. That remains the fail-closed case, and it
    /// is the honest one: there is nothing to hand SCK, so there is no way to be protected.
    ///
    /// Generic over the application type so the rule is testable without ScreenCaptureKit.
    public static func displayExclusion<App>(current: [App], remembered: [App]) -> [App]? {
        // ONE RULE, ONE SITE: the emptiness decision stays in `displayFilterDecision` rather than
        // being restated here, so a change to what counts as resolved cannot be applied to one and
        // forgotten in the other.
        let resolved = current.isEmpty ? remembered : current
        switch displayFilterDecision(ownApplicationResolved: !resolved.isEmpty) {
        case .exclude: return resolved
        case .refuse:  return nil
        }
    }
}
