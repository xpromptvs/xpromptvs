import Foundation

/// Who owns a subscribed source's audio.
///
/// SCK CANNOT ISOLATE A WINDOW'S AUDIO FROM ITS APPLICATION'S, which is the whole reason this type
/// exists: two subscribed windows of one app would each carry that app's audio and the browser
/// would mix it twice. MEASURED 2026-09-03 — a paused, silent QuickTime window carried a different
/// QuickTime window's audio at 99.4%. See the spec's `Measured` section, arm H.
public enum AudioOwner: Equatable, Sendable {
    /// A window source — the pid of the application that owns the window.
    case application(pid: Int32)
    /// A display source. SCK gives it the system mix, so it owns EVERY application's audio.
    case everything
    /// A SIMULATOR source: its sound plays through `launchd_sim` processes no ScreenCaptureKit window owns, so it
    /// carries nothing — and must not be `.everything`, which would let it silence every window.
    case silent
}

public struct AudioSource: Equatable, Sendable {
    public let id: String
    public let owner: AudioOwner
    public init(id: String, owner: AudioOwner) { self.id = id; self.owner = owner }
}

/// The election. PURE, so the rule is testable without a capture session, a peer or a browser.
public enum AudioOwnership {
    /// `sources` in SUBSCRIPTION ORDER, oldest first. Returns, for every source, the id that carries
    /// its audio: mapped to ITSELF means it carries its own; mapped to another id means it YIELDED.
    ///
    /// THE YIELD TARGET IS RETURNED BY NAME rather than as a bare bool, because the client renders
    /// it ("audio from <window>"). A silent window that cannot say why it is silent is a bug report.
    public static func elect(_ sources: [AudioSource]) -> [String: String] {
        var out: [String: String] = [:]
        // A DISPLAY IS NOT AN APPLICATION, so it is resolved before the per-pid pass rather than
        // within it: "first subscriber wins" ranks WITHIN an app, and a display outranks every app
        // regardless of when it was subscribed.
        if let display = sources.first(where: { $0.owner == .everything }) {
            for s in sources { out[s.id] = display.id }
            return out
        }
        var firstForPid: [Int32: String] = [:]
        for s in sources {
            if case .silent = s.owner { out[s.id] = s.id; continue }
            guard case .application(let pid) = s.owner else { continue }
            if let owner = firstForPid[pid] {
                out[s.id] = owner
            } else {
                firstForPid[pid] = s.id
                out[s.id] = s.id
            }
        }
        return out
    }

    /// The ids that CARRY audio — exactly the sources the election mapped to themselves.
    public static func carriers(_ sources: [AudioSource]) -> Set<String> {
        Set(elect(sources).filter { $0.key == $0.value }.keys)
    }
}
