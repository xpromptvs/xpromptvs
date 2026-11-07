import Foundation
import ShellstormCore

/// ONE PROCESS PER PROFILE. LaunchServices dedupes `open`, but not an executable run directly (the
/// gates and `dev-local.sh` do that), so a lock in the profile directory decides. A second process
/// asks the first to activate and exits 0 — Electron's `requestSingleInstanceLock` contract.
enum SingleInstance {
    private static var fd: Int32 = -1

    static func acquire(_ profile: AppProfile) -> Bool {
        try? FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        fd = open(profile.directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }   // cannot lock: run rather than refuse to start
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    static func name(_ profile: AppProfile) -> Notification.Name { .init("\(AppProfile.folder).activate.\(profile.name)") }

    static func signalPrimary(_ profile: AppProfile) {
        DistributedNotificationCenter.default().postNotificationName(name(profile), object: nil, userInfo: nil,
                                                                      deliverImmediately: true)
    }

    static func observeActivation(_ profile: AppProfile, _ activate: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: name(profile), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { activate() }
        }
    }
}
