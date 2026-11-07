import Foundation

/// The APP's preferences, in `app-settings.json` in the profile directory.
///
/// - `autoShare` is needed before any window exists (auto share is decided at launch).
/// - `smoothScroll` is the terminal's smooth scrolling (`web/src/shared/smooth-scroll-pref.ts`). It lives
///   HERE, not in a page's storage, because the dashboard (`app://ui`) and the session windows
///   (`app://client`) are two origins with two storages — this is the one value they all read, write and
///   are pushed (`UIBridge` / `ClientBridge` `setSmoothScroll`).
///
/// A file that is missing, broken or hand-edited is the defaults, KEY BY KEY — auto-share defaults off, smooth scrolling defaults on.
public struct AppSettings: Equatable, Sendable {
    public var allowRemoteUpdates: Bool
    public var showDashboardOnStartup: Bool = false
    public var autoShare: Bool
    public var smoothScroll: Bool
    public init(autoShare: Bool, smoothScroll: Bool = true, allowRemoteUpdates: Bool = true) { self.allowRemoteUpdates = allowRemoteUpdates; self.autoShare = autoShare; self.smoothScroll = smoothScroll }

    static let file = "app-settings.json"

    public static func parse(_ data: Data?) -> AppSettings {
        let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func flag(_ key: String, fallback: Bool = false) -> Bool {
            guard let v = o[key] as? NSNumber, CFGetTypeID(v) == CFBooleanGetTypeID() else { return fallback }
            return v.boolValue
        }
        var settings = AppSettings(autoShare: flag("autoShare"), smoothScroll: flag("smoothScroll", fallback: true), allowRemoteUpdates: flag("allowRemoteUpdates", fallback: true))
        settings.showDashboardOnStartup = flag("showDashboardOnStartup")
        return settings
    }

    public static func read(dir: URL) -> AppSettings { parse(try? Data(contentsOf: dir.appendingPathComponent(file))) }

    /// Atomic: a crash mid-write leaves the old file, never half a new one. NOT public: the app changes a
    /// key through `update`, never by writing a struct it built — one built with `init(autoShare:)` would
    /// silently reset every other key (`setAutoShare` did exactly that until smooth scrolling needed one).
    func write(dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["showDashboardOnStartup": showDashboardOnStartup, "autoShare": autoShare, "smoothScroll": smoothScroll, "allowRemoteUpdates": allowRemoteUpdates],
                                              options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: dir.appendingPathComponent(Self.file), options: .atomic)
    }

    /// Change ONE setting and keep the rest: read, change, write. Returns what was written.
    @discardableResult
    public static func update(dir: URL, _ change: (inout AppSettings) -> Void) throws -> AppSettings {
        var s = read(dir: dir)
        change(&s)
        try s.write(dir: dir)
        return s
    }

    /// Whether to share at start, and why — the reason is logged.
    public static func autoShareReason(argv: [String], env: [String: String], settings: AppSettings) -> String? {
        if argv.contains("--share") { return "--share" }
        if env["RDEV_AUTO_SHARE"] == "1" { return "RDEV_AUTO_SHARE=1" }
        if settings.autoShare { return "the Auto share on start setting" }
        return nil
    }
}
