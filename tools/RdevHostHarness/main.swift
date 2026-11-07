import Foundation
import AppKit
import RdevCore
import RdevHostKit

// Unbuffer stdout: when stdout is a pipe/file (not a TTY) it is block-buffered, so the PAIR
// line would never flush while the host runs. The smokes read these lines as they happen.
setbuf(stdout, nil)

let config = HostConfig.from(environment: ProcessInfo.processInfo.environment)

/// Best-effort terminal width, for sizing the connect QR so it never wraps.
func terminalColumns() -> Int {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
    if let s = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(s), n > 0 { return n }
    return 80
}

// ScreenCaptureKit's SCContentFilter queries the WindowServer and aborts with CGS_REQUIRE_INIT
// in a bare CLI binary with no WindowServer connection. Establish one as a background accessory
// app BEFORE any window capture. Skipped on the test-pattern path, which must stay AppKit-free.
if !config.useTestPattern {
    NSApplication.shared.setActivationPolicy(.accessory)
    // This binary is its own UIElement app with its OWN TCC identity — it does not inherit the
    // terminal's Screen Recording grant. A fresh grant needs a RESTART to take effect (macOS
    // caches the decision at process start), so say so rather than failing -3801 silently.
    if CGPreflightScreenCaptureAccess() {
        print("[perm] Screen Recording: granted")
    } else {
        print("[perm] Screen Recording: NOT granted — prompting now.")
        print("[perm] Grant this binary in System Settings › Privacy & Security › Screen Recording,")
        print("[perm] then RESTART the host (the grant only takes effect on a fresh launch).")
        _ = CGRequestScreenCaptureAccess()
    }
}

// MARK: - Pair
//
// §9.1: THE ISSUER GENERATES. One 32-byte seed becomes `code`, `token` and `psk`; only the two
// public values are registered with the Control Plane, and the seed is what a person carries.
let sem = DispatchSemaphore(value: 0)
nonisolated(unsafe) var opened: PairingWindowOpener.Opened?
nonisolated(unsafe) var openFailure: PairingWindowOpener.Failure?
Task {
    switch await PairingWindowOpener.open(signalingBase: config.signalingBase) {
    case .success(let o): opened = o
    case .failure(let f): openFailure = f
    }
    sem.signal()
}
sem.wait()
guard let pair = opened else {
    fputs("FATAL: could not open a pairing window at \(config.signalingBase): "
          + "\(openFailure?.rawValue ?? "unknown")\n", stderr)
    exit(1)
}

// FROZEN FORMAT: 5 smokes parse this line with sed. Do not change spacing or case.
//
// **THE PSK IS NOT HERE AND MUST NEVER BE.** §16 keeps the seed out of captured output, and these
// two values are the ones the Control Plane already knows — printing the material a handshake needs
// would defeat the whole derivation.
print("PAIR code=\(pair.material.code) token=\(pair.material.token)")
print("Pairing code: \(pair.carrier)")
// **THE SEED RIDES IN THE FRAGMENT.** A query reaches the Control Plane on the first navigation and
// §9.1 forbids the seed getting there; a fragment is the one part of a URL no browser sends. The
// code and token stay in the query because the client's module gate reads them from `location.search`.
let connectURL = "\(config.signalingBase)/?code=\(pair.material.code)"
    + "&token=\(pair.material.token)#pair=\(pair.carrier)"

// THE SCANNABLE QR IS RENDERED IN A WINDOW THIS PROCESS OWNS, not into the terminal that launched it
// — see `PairingWindow.swift` for both reasons, one of which is that a window-less host cannot
// capture a display at all. The two code STRINGS above stay on stdout because nine smokes and gates
// parse them; that exemption is deliberate and §16 rule 6 still describes it accurately.
//
// Skipped on the test-pattern path, which is headless by design: no WindowServer, no TCC, no AppKit.
// That path exposes one synthetic source and enumerates no displays, so it needs no exclusion either.
nonisolated(unsafe) var pairingWindow: PairingWindow?
if !config.useTestPattern {
    MainActor.assumeIsolated {
        let w = PairingWindow(qr: QRMatrix.from(connectURL), pairingCode: pair.carrier,
                              connectURL: connectURL)
        pairingWindow = w
        w.show()
    }
    print("Pairing QR: in the harness's own window (excluded from capture, like the app's)")
} else {
    print("Or open: \(connectURL)\n")
}

// MARK: - Runtime
// The psk goes to the runtime and NOWHERE else: it is what makes `pair` answerable, and §16 keeps
// it out of every log and every captured frame.
let runtime = RdevHostRuntime(config: config, code: pair.material.code,
                              token: pair.material.token, pairingPSK: pair.material.psk)

runtime.start()

// The harness enrols NO identity of its own (2026-10-06): a passkey ceremony needs the app's
// `webcredentials:` entitlement, which an unbundled CLI cannot carry. A gate seeds one
// (`RDEV_E2E_TEST_IDENTITY`, `e2e/lib/seed-identity.mjs`); the product's ceremony is the app's
// (`docs/e2e.md`, "The Mac's own passkey ceremony").

// MARK: - Curtain test affordances (harness only)
//   kill -USR1 <pid>  raises the curtain    kill -USR2 <pid>  lowers it
// signal() handlers run in a limited async-signal-safe context, so just hop to the controller.
signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)
let curtainUp = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
curtainUp.setEventHandler { runtime.setCurtain(true) }
curtainUp.resume()
let curtainDown = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
curtainDown.setEventHandler { runtime.setCurtain(false) }
curtainDown.resume()
print("[curtain] test toggle ready — kill -USR1 \(ProcessInfo.processInfo.processIdentifier) to raise, -USR2 to lower")

// MARK: - SIGTERM ends the session (harness only, opt-in)
//
// THE HARNESS NEVER ENDED ITS SESSION: a SIGTERM (what every gate sends) or the status menu's Quit killed it
// where it stood, so nothing ran `RdevHostRuntime.stop()` — and with it `HostSession.end()`, which empties the
// paste folder (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §6); only the NEXT launch did.
// `RDEV_HARNESS_END_ON_TERM=1` makes a SIGTERM the product's quit: sharing stops, the session ends, the process
// exits 0. `e2e/paste-live-check.mjs`'s cleanup arm asks for it. OPT-IN, so every other gate's SIGTERM still
// kills at once — and BOUNDED: a second source on a background queue exits anyway 10 s later, so a wedged main
// thread cannot turn a SIGTERM into a leaked host.
nonisolated(unsafe) var endOnTerm: [DispatchSourceSignal] = []
if ProcessInfo.processInfo.environment["RDEV_HARNESS_END_ON_TERM"] == "1" {
    signal(SIGTERM, SIG_IGN)
    let end = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    end.setEventHandler {
        runtime.stop()
        print("[harness] SIGTERM — the session ended; exiting")
        exit(0)
    }
    let bound = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    bound.setEventHandler {
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("[harness] the session did not end within 10 s of SIGTERM — exiting anyway\n", stderr)
            _exit(70)
        }
    }
    end.resume()
    bound.resume()
    endOnTerm = [end, bound]
    print("[harness] RDEV_HARNESS_END_ON_TERM=1 — a SIGTERM ends the session before exiting")
}

// MARK: - Capture-boundary marker (harness only)
//
// `RDEV_CAPTURE_MARKER=1` opens a host-owned window painted one extreme colour and cycles it on and
// off for the life of the process. It is the subject of `scripts/gate-capture-boundary.sh`: §16 of
// the E2E protocol specification says a pairing secret must never reach captured video, thumbnails or
// previews, and the product renders that secret in a host window, so the only way to prove the
// exclusion works is to put something findable in a host window and go looking for it.
//
// READ THE COMMENTS IN CaptureMarker.swift BEFORE CHANGING ANY OF THIS — in particular why the window
// is deliberately as capturable as any other, and why it appears AFTER sharing has started rather
// than at launch. Kept out of `HostConfig` on purpose: it is a harness affordance, and the product's
// configuration surface is not the place to describe one. Skipped on the test-pattern path, which is
// headless and has no WindowServer.
nonisolated(unsafe) var captureMarker: CaptureMarkerWindow?
if !config.useTestPattern, ProcessInfo.processInfo.environment["RDEV_CAPTURE_MARKER"] == "1" {
    MainActor.assumeIsolated {
        let m = CaptureMarkerWindow()
        captureMarker = m
        m.startCycling()
    }
    print("[marker] RDEV_CAPTURE_MARKER=1 — host-owned marker window cycling; it must never reach a client")
}

// `RDEV_OWN_WINDOW_OVER=x,y,w,h` opens an ordinary, clickable host-owned window over that rectangle,
// for `scripts/smoke-desktop.sh`: a display client's taps must reach what it SEES there, which is
// whatever is behind this window. See InputObstruction.swift.
nonisolated(unsafe) var inputObstruction: InputObstructionWindow?
if !config.useTestPattern, let spec = ProcessInfo.processInfo.environment["RDEV_OWN_WINDOW_OVER"] {
    MainActor.assumeIsolated {
        guard let w = InputObstructionWindow(spec: spec) else {
            print("[obstruction] RDEV_OWN_WINDOW_OVER=\(spec) is not x,y,w,h — no obstruction opened")
            return
        }
        inputObstruction = w
        w.show()
        if ProcessInfo.processInfo.environment["RDEV_OWN_WINDOW_RETURNS"] == "1" { w.returnOnceAfterHide() }
    }
}

if config.curtainSelfTest {
    print("[curtain] RDEV_CURTAIN_TEST=1 — shield will raise 2s after launch, lower after 10s")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        runtime.setCurtain(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { runtime.setCurtain(false) }
    }
}

// MARK: - Run loop (the FRONT-END owns this, never the runtime)
if !config.useTestPattern {
    var statusMenu: StatusMenuController?
    MainActor.assumeIsolated { statusMenu = StatusMenuController() }
    _ = statusMenu   // retain for process lifetime
    print("[curtain] menu-bar Lock Screen ready (panic-unlock: ⌃⌥⌘U)")
    NSApplication.shared.run()
} else {
    RunLoop.main.run()
}
