import Foundation
import RdevHostKit

/// The psk of the window this process opened, held for the `pair` handshake that will need it.
///
/// **It is kept HERE and not returned**, which is the whole reason this box exists: the value never
/// crosses the C boundary, so it cannot reach the renderer, a log, or a crash report through any
/// path the app controls.
final class PairingWindowBox: @unchecked Sendable {
    static let shared = PairingWindowBox()
    private let lock = NSLock()
    private var opened: PairingWindowOpener.Opened?

    func remember(_ o: PairingWindowOpener.Opened) {
        lock.lock(); opened = o; lock.unlock()
    }

    var psk: [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return opened?.material.psk
    }
}
