/// **A client window's macOS full screen, as its PAGE asks for it** (`__rdevShell.setFullscreen`, the
/// web client's full-screen window mode) and as AppKit reports its transitions. The app puts its OWN
/// window full screen rather than letting WebKit's element full screen do it: Esc then stays a key the
/// page forwards to the Mac (WebKit's full screen spends it on leaving), and nothing depends on WebKit's
/// rules for a page asking (it refused a window that was not frontmost, measured 2026-09-29).
///
/// THE WINDOW IS THE PAGE'S TO GIVE BACK ONLY IF THE PAGE PUT IT THERE, AND A TRANSITION THE PERSON
/// MADE IS THEIRS. A person who pressed the green button before the page asked keeps their full screen
/// when the page's mode ends; a person who LEAVES full screen while the page's mode is on — the page's
/// full screen or their own under it — takes the page's mode out with it (`pageLost`), and the window
/// stays out. Which transition is whose is known by `began`: one this asked for (`requested`) or not.
///
/// AppKit ignores `toggleFullScreen` while a transition runs, so a change of mind is applied by `settle`,
/// which the window runs on the NEXT main-loop turn after a landing and decides THEN; a toggle AppKit
/// never started is forgotten (`toggleIgnored`), and a failure is never retried. Pure: `ClientWindow`
/// feeds it the window's state and does what it returns.
public struct FullScreenOwnership: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case none, toggle }

    public struct Landing: Equatable, Sendable {
        /// The page's full screen ended without the page asking — tell it (`__rdevFullscreenLeft`).
        public let pageLost: Bool
        /// Run `settle` on the next turn: the page may have changed its mind while this ran.
        public let settle: Bool
        public init(pageLost: Bool, settle: Bool) { self.pageLost = pageLost; self.settle = settle }
    }

    /// What the page last asked for.
    public private(set) var want = false
    /// The window's full screen (current, or on its way) is one the PAGE started.
    public private(set) var ours = false
    /// A toggle this asked AppKit for, which AppKit has not yet begun.
    public private(set) var requested = false
    /// Names each toggle, so a late verdict on an older one (`toggleIgnored`) cannot void a newer one.
    public private(set) var requestID = 0
    /// A transition is running, from `windowWill…FullScreen` until it lands.
    public private(set) var running = false
    /// The running transition is the PERSON's — `began` found no request of ours.
    private var persons = false
    /// What the page wanted when the running transition began.
    private var wantedAtBegin = false

    public init() {}

    private var busy: Bool { requested || running }

    /// The page asks for full screen (true) or gives it back (false).
    public mutating func pageAsks(_ on: Bool, isFullScreen: Bool) -> Action {
        want = on
        return busy ? .none : reconcile(isFullScreen: isFullScreen)
    }

    /// The page went — its web process died, or the window loaded a new one — so nothing is left to press
    /// `Exit`: its full screen goes with it (the person's stays).
    public mutating func pageGone(isFullScreen: Bool) -> Action {
        want = false
        return busy ? .none : reconcile(isFullScreen: isFullScreen)
    }

    /// AppKit began a transition — the one this asked for, or the person's.
    public mutating func began() {
        running = true
        persons = !requested
        requested = false
        wantedAtBegin = want
    }

    /// A transition ended where the window now is; `failed` when AppKit could not complete it.
    public mutating func landed(isFullScreen: Bool, failed: Bool) -> Landing {
        running = false
        let personsTransition = persons
        persons = false
        if failed {
            // Nothing moved. OURS stays exactly as the window is: an entry that failed is not the page's
            // (and not retried behind the person's back — `want` goes too, the page keeps its own mode),
            // an exit that failed still is, for the page to give back later. No settle: no retry loop.
            if !personsTransition {
                ours = isFullScreen
                if !isFullScreen { want = false }
            }
            return Landing(pageLost: false, settle: false)
        }
        if personsTransition {
            if isFullScreen { ours = false; return Landing(pageLost: false, settle: false) }  // theirs
            ours = false
            // The person LEFT full screen with the page's mode on: the mode follows them out, and the window
            // stays out. An ask that arrived only DURING their exit is a fresh ask, applied on the settle.
            if wantedAtBegin { want = false; return Landing(pageLost: true, settle: false) }
            return Landing(pageLost: false, settle: true)
        }
        return Landing(pageLost: false, settle: true)
    }

    /// After a landing, on the next main-loop turn: apply what the page wants NOW.
    public mutating func settle(isFullScreen: Bool) -> Action {
        busy ? .none : reconcile(isFullScreen: isFullScreen)
    }

    /// The toggle named `id` never began — AppKit declined it. Forget it, so later asks are heard; the window
    /// is where it is, and the page's by `ours` only if it is full screen and the page wanted OUT.
    public mutating func toggleIgnored(id: Int, isFullScreen: Bool) {
        guard requested, id == requestID else { return }
        requested = false
        ours = isFullScreen && !want
    }

    private mutating func reconcile(isFullScreen: Bool) -> Action {
        if want && !isFullScreen { ours = true; return request() }
        if !want && isFullScreen && ours { ours = false; return request() }
        return .none
    }

    private mutating func request() -> Action {
        requested = true
        requestID += 1
        return .toggle
    }
}
