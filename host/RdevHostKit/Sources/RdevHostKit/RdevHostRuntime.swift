import Foundation
import RdevCore
import RdevE2E

/// Everything the host IS, minus everything about being a CLI.
///
/// LOAD-BEARING: this type must never call `NSApp.run()` or `RunLoop.main.run()`. The CALLER
/// owns the run loop — the harness and the native app each call `NSApplication.shared.run()`
/// themselves. (Under Electron, running one here deadlocked Electron's main thread at dylib load,
/// which presented as the app hanging at launch with no error.)
///
/// It also does no printing and no AppKit bootstrap: the `PAIR`/QR lines are a harness concern,
/// and by the time the app starts a runtime the activation policy is long since set.
public final class RdevHostRuntime {
    private let config: HostConfig
    private let code: String
    private let token: String

    /// §9.1's psk for the pairing window this host is showing, handed to the room.
    private let pairingPSK: [UInt8]?

    // MARK: - the device's E2E identity
    //
    // OWNED BY A PROCESS-GLOBAL SERVICE, NOT BY THIS RUNTIME, and that is the difference between
    // "this Mac has no identity" and "this Mac has not started sharing". The two are independent: a
    // runtime exists only between `start()` and `stop()`, while the app's very first question —
    // before any session exists — is whether this Mac is enrolled at all. The C ABI asks the same
    // service directly, so there is one cache over one store rather than two that can disagree.
    private let e2eService: E2EIdentityService

    /// §12.2's session discovery, which replaced OAuth accounts. **Owned by the runtime, because the
    /// runtime is what knows the room**: it holds `code` and `token` already, so publishing needs no
    /// C ABI entry point and cannot disagree with what the app is showing.
    /// `docs/superpowers/specs/2026-09-13-passkey-only-identity.md`.
    private let publisher: E2ESessionPublisher

    /// `pairingPSK` is §9.1's third derived value for the window this host is showing. It NEVER
    /// leaves this process: not to the Control Plane, not to a log, not into captured output — the
    /// whole point of deriving it from a seed the Control Plane never sees.
    public convenience init(config: HostConfig, code: String, token: String,
                            pairingPSK: [UInt8]? = nil) {
        self.init(config: config, code: code, token: token, pairingPSK: pairingPSK,
                  e2e: E2EIdentityService.shared(signalingBase: config.signalingBase))
    }

    /// The service arrives ALREADY ASSEMBLED, which is what lets the status machine be tested at
    /// all: the live assembly reaches the Keychain, and a Bazel test sandbox has no keychain.
    init(config: HostConfig, code: String, token: String, pairingPSK: [UInt8]? = nil,
         e2e: E2EIdentityService, publisher: E2ESessionPublisher = E2ESessionPublisher()) {
        self.config = config
        self.code = code
        self.token = token
        self.pairingPSK = pairingPSK
        self.e2eService = e2e
        self.publisher = publisher
    }

    /// What this Mac's listing is doing, for the app's row. See `E2ESessionPublisher.State` for why
    /// "not yet reported" is a third answer and not a synonym for either of the other two.
    public func publicationState() -> E2ESessionPublisher.State { publisher.state() }

    /// The E2E identity's status, for a log line and the app's UI.
    public func e2eStatus() -> E2EHostStatus { e2eService.status() }

    /// This device's identity, for the parts of the host that have to present it.
    public var e2eIdentity: E2EHostIdentity? { e2eService.identity }

    /// The session and the door, BOTH from `start` to `stop` — the HARNESS's lifecycle, unchanged. The app
    /// keeps its session for its whole run instead (`SharingHost`).
    private var session: HostSession?
    private var room: SharingRoom?

    public func start() {
        let session = HostSession(config: config)
        let room = SharingRoom(session: session, config: config, code: code, token: token,
                               pairingPSK: pairingPSK, e2e: e2eService, publisher: publisher)
        self.session = session
        self.room = room
        room.start()
    }

    /// Sharing stops (the curtain first), then the session ends: every shell killed, every tmux tab
    /// detached, every stream stopped.
    public func stop() {
        room?.stop()
        session?.end()
        room = nil
        session = nil
    }

    public func setCurtain(_ on: Bool) {
        on ? CurtainController.shared.raise() : CurtainController.shared.lower()
    }

    public var curtainIsUp: Bool { CurtainController.shared.isUp }
}
