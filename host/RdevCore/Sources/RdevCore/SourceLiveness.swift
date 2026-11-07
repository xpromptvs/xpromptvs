import Foundation

/// Which watched sources currently produce frames, split by KIND.
///
/// LOAD-BEARING — TWO MAPS, NOT ONE. `CGWindowID` and `CGDirectDisplayID` are both `UInt32`
/// typealiases, so the compiler cannot tell them apart and a single combined map would silently let
/// window 7 and display 7 overwrite each other. The separation is by FIELD, which is why it needs a
/// test rather than a type — see `SourceLivenessTests`.
public struct LivenessSnapshot: Equatable, Sendable {
    public var windows: [UInt32: Bool]
    public var displays: [UInt32: Bool]
    public init(windows: [UInt32: Bool] = [:], displays: [UInt32: Bool] = [:]) {
        self.windows = windows; self.displays = displays
    }
    public var isEmpty: Bool { windows.isEmpty && displays.isEmpty }
}

/// Map the watched ids onto their liveness. A window is live when it is on an active Space's screen; a
/// display is live when it is still attached. Pure — the syscalls that produce the two "current" sets
/// live in `WindowLivenessMonitor`.
///
/// `uniquingKeysWith` rather than `uniqueKeysWithValues` so a duplicate watched id can never trap.
public func buildLivenessSnapshot(watchedWindows: [UInt32], onScreenWindows: Set<UInt32>,
                                  watchedDisplays: [UInt32], activeDisplays: Set<UInt32>) -> LivenessSnapshot {
    LivenessSnapshot(
        windows: Dictionary(watchedWindows.map { ($0, onScreenWindows.contains($0)) },
                            uniquingKeysWith: { a, _ in a }),
        displays: Dictionary(watchedDisplays.map { ($0, activeDisplays.contains($0)) },
                             uniquingKeysWith: { a, _ in a }))
}
