import Foundation

/// Native windows use the simulator's logical points at 100%, capped by the screen's usable area.
public enum NativeSimulatorGeometry {
    public static func openingFrame(device: CGSize, header: CGFloat, available: CGRect, previous: CGRect) -> CGRect {
        guard device.width > 0, device.height > 0, available.width > 0, available.height > header else { return previous }
        let scale = min(1, available.width / device.width, (available.height - header) / device.height)
        let size = CGSize(width: device.width * scale, height: device.height * scale + header)
        // Retain the old top-left where possible, including after a client handoff or screen removal.
        return CGRect(x: min(max(previous.minX, available.minX), available.maxX - size.width),
                      y: min(max(previous.maxY - size.height, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

public struct NativeWindowState: Equatable, Sendable {
    public let source: String
    public let title: String
    public let minimized: Bool
    public init(source: String, title: String, minimized: Bool) { self.source = source; self.title = title; self.minimized = minimized }
}
public struct NativeWindowsSnapshot: Sendable {
    public let generation: UInt64, revision: UInt64
    public let driving: Bool
    public let windows: [NativeWindowState]
    public let focusedSource: String?
    public let terminalActive: Bool
    public init(generation: UInt64, revision: UInt64, driving: Bool, windows: [NativeWindowState], focusedSource: String?, terminalActive: Bool) {
        self.generation = generation; self.revision = revision; self.driving = driving; self.windows = windows
        self.focusedSource = focusedSource; self.terminalActive = terminalActive
    }
}
public struct NativeWindowsDelta {
    public let create: [NativeWindowState], update: [NativeWindowState], close: [String]
    public let front: String?
}
/// Pure projection. Closing on a generation transition is never a session-close intent.
public struct NativeSimulatorWindowsModel {
    private var generation: UInt64 = 0, revision: UInt64 = 0
    private var windows: [NativeWindowState] = []
    private var focused: String?
    public init() {}
    /// Dock/second-launch activation raises existing local windows without changing session membership.
    public func activation() -> NativeWindowsDelta {
        let visible = windows.filter { !$0.minimized }
        return NativeWindowsDelta(create: [], update: visible, close: [],
            front: visible.contains { $0.source == focused } ? focused : nil)
    }
    public mutating func apply(_ snapshot: NativeWindowsSnapshot) -> NativeWindowsDelta {
        guard snapshot.generation > generation || (snapshot.generation == generation && snapshot.revision > revision) else {
            return NativeWindowsDelta(create: [], update: [], close: [], front: nil)
        }
        let replace = snapshot.generation != generation
        let wanted = snapshot.driving ? snapshot.windows : []
        let ids = Set(wanted.map(\.source)), old = replace ? [] : Set(windows.map(\.source))
        let close = windows.filter { replace || !ids.contains($0.source) }.map(\.source)
        let create = wanted.filter { !old.contains($0.source) }
        let update = wanted.filter { old.contains($0.source) }
        let nextFocus = snapshot.driving && !snapshot.terminalActive ? snapshot.focusedSource : nil
        let front = nextFocus != focused || replace ? nextFocus : nil
        windows = wanted; focused = nextFocus; generation = snapshot.generation; revision = snapshot.revision
        return NativeWindowsDelta(create: create, update: update, close: close, front: front)
    }
}
