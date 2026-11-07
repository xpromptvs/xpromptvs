import RdevAppHost
import ShellstormCore
/// Source builds never replace themselves with the official Homebrew distribution.
@MainActor final class HostUpdateCoordinator {
    func acknowledgeRestart() async {}
    init(host: HostController, profile: AppProfile, environment: ShellEnvironment) {
        SharingHost.shared.hostUpdates.configure(release: nil, allowed: false, available: nil, handler: nil)
    }
}
