import Foundation
import RdevAppHost
import RdevCore
import ShellstormCore

/// **THE SESSION'S TERMINAL TABS OUTLIVE A QUIT** (docs/terminal.md, "Tabs that come back"): saved to the
/// profile's `terminal-tabs.json` every few seconds while the app runs and once more at quit, BEFORE the
/// session ends; restored at the next launch, before any window — a `pty:` tab as a new shell in the
/// directory it was in, under its name, a `tmux:` tab re-attached if its session still exists. A crash
/// loses at most the last few seconds. The saves are on the main thread: reading the tabs is a lock and one
/// `proc_pidinfo` per shell.
@MainActor
final class TerminalTabsKeeper {
    static let interval: TimeInterval = 5
    private var file: TerminalTabsFile
    private var timer: Timer?

    init(profile: AppProfile) { file = TerminalTabsFile(dir: profile.directory) }

    /// At launch, after the session exists and before any client: what was saved comes back.
    func restore() {
        guard let data = file.read(), let saved = SavedTerminalTabs(json: data),
              !saved.tabs.isEmpty || !(saved.agents?.tabs.isEmpty ?? true) else { return }
        SharingHost.shared.restoreTerminalTabs(saved)
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The tabs as they are now; nothing once the session has ended.
    func save() {
        guard let saved = SharingHost.shared.savedTerminalTabs() else { return }
        file.write(saved.json())
    }

    /// The quit: one last save, then no more — the session is about to close every tab.
    func stop() {
        timer?.invalidate(); timer = nil
        save()
    }
}
