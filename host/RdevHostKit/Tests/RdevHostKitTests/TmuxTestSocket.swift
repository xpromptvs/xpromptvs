import Foundation
import RdevTmuxRig

/// A test's PRIVATE tmux server leaves its socket FILE behind on `kill-server`; every test that starts
/// one removes it in its teardown, by the exact `-L` name it chose (`PrivateTmux.removeSocket`, the one
/// place that knows where tmux puts it).
enum TmuxTestSocket {
    static func remove(_ name: String) { PrivateTmux.removeSocket(name) }
}
