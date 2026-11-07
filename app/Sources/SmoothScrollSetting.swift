import ShellstormCore
import WebKit

/// **The app's ONE smooth-scrolling value** (`AppSettings.smoothScroll`, `app-settings.json`). The
/// dashboard (`app://ui`) and every session window (`app://client`) are two origins with two web
/// storages, so neither can be the truth: both bridges read it (`smoothScroll`) and write it
/// (`setSmoothScroll`), and every write is pushed to EVERY window the app has — the dashboard's checkbox
/// and each session's open tabs follow at once, whichever window changed it
/// (`web/src/shared/smooth-scroll-pref.ts`, `followNativeSmoothScroll`).
@MainActor
enum SmoothScrollSetting {
    static func read(_ profile: AppProfile) -> Bool { AppSettings.read(dir: profile.directory).smoothScroll }

    /// Save, then push to every window — the one that asked included, which applies what it already has.
    static func write(_ on: Bool, profile: AppProfile, windows: AppWindows?) throws -> Bool {
        let saved = try AppSettings.update(dir: profile.directory) { $0.smoothScroll = on }.smoothScroll
        let js = "window.__rdevSmoothScroll?.(\(saved ? "true" : "false"))"
        for w in windows?.all() ?? [] { w.webView.evaluateJavaScript(js) }
        return saved
    }
}
