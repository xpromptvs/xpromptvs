import AppKit
import ShellstormCore
import RdevCore

// Before anything reads the environment — see Instruments.
for (k, v) in Instruments.overrides(env: ProcessInfo.processInfo.environment) { setenv(k, v, 0) }

let channel = ReleaseIdentity.bundled()?.channel.rawValue ?? "staging"
var env = ProcessInfo.processInfo.environment
guard let profile = AppProfile.resolve(env: env, appSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], channel: channel) else {
    FileHandle.standardError.write(Data("RDEV_APP_PROFILE must be 1-64 of [A-Za-z0-9._-]\n".utf8))
    exit(2)
}

// Separate staging keys before the app constructs its host identity service.
if let path = profile.identityStoreName, env["RDEV_E2E_STORE"] == nil {
    setenv("RDEV_E2E_STORE", path, 1)
    env["RDEV_E2E_STORE"] = path
}

// ONE PROCESS PER PROFILE — before any window or NSApplication work. A second launch of the same
// profile asks the first to activate and exits 0.
if !SingleInstance.acquire(profile) {
    SingleInstance.signalPrimary(profile)
    exit(0)
}

// `main.swift`'s top-level statements are provably on the main thread (nothing has started the run
// loop yet, so there is no other thread they could be on) but are not themselves MainActor-isolated
// code as far as the compiler's static checking goes, so a call to AppDelegate's MainActor-isolated
// initializer needs an explicit assertion of the isolation this file already has at runtime.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated {
    AppDelegate(profile: profile, environment: ShellEnvironment(env: env, channel: channel))
}
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
