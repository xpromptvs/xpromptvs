import AppKit

// Four-quadrant click recorder — the macOS counterpart of the retired iOS SimTapTarget, and the
// deterministic capture + input target for the window smokes.
//
// Contract deliberately matched to the old iOS app, so the smokes' assertions are unchanged:
//   * four solid quadrants: TL red, TR green, BL blue, BR yellow
//   * one "x,y" line per LEFT click, window-local, TOP-LEFT origin
//   * one "rclick,<phase>,x,y,<mods>" line per RIGHT mouse event
//   * the log file is truncated at launch
//
// Plus two things the simulator app could not do:
//   * prints WINDOW_ID=<cgWindowID>, so a smoke never enumerates windows or guesses by name
//   * the log path is argv, so there is no simctl container to spelunk
//
// NOTE this is `main.swift` with top-level code, and build.sh does NOT pass -parse-as-library —
// the two are mutually exclusive. (SimTapTarget used @main + -parse-as-library; either works.)

let args = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let logPath = argValue("--log") ?? (NSTemporaryDirectory() + "rdev-wintaptarget-taps.csv")
let winW = Double(argValue("--width") ?? "") ?? 640
let winH = Double(argValue("--height") ?? "") ?? 480

/// LOAD-BEARING: `isFlipped` gives this view a TOP-LEFT origin, which is what makes both the drawing
/// and the recorded coordinates match `kCGWindowBounds` and the video stream. AppKit's default is
/// bottom-left; without this the quadrant colours mirror vertically AND every recorded y is inverted,
/// which would flip the smokes' `tap2.y > tap1.y` assertion into asserting the opposite — and it would
/// still PASS, because the taps are generated in a fixed order. The Task 1 gate exists for this line.
final class QuadrantView: NSView {
    private let logURL: URL

    init(frame: NSRect, logURL: URL) {
        self.logURL = logURL
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Deliver a click even when the window is not already frontmost. By default AppKit swallows the
    /// first click on an inactive window to activate it, which would silently drop a tap — the exact
    /// failure the smokes would read as "input never arrived".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width / 2, h = bounds.height / 2
        NSColor.red.setFill();    NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor.green.setFill();  NSRect(x: w, y: 0, width: w, height: h).fill()
        NSColor.blue.setFill();   NSRect(x: 0, y: h, width: w, height: h).fill()
        NSColor.yellow.setFill(); NSRect(x: w, y: h, width: w, height: h).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        record(x: Int(p.x.rounded()), y: Int(p.y.rounded()))
    }

    // ── right click, for scripts/gate-window-input.sh ─────────────────────────────────────────────
    //
    // PREFIXED LINES, unlike a left tap's bare `x,y`: the existing smokes parse field 0 of a tap as a
    // number, and an unprefixed right line would read as NaN. That asymmetry is also what makes the
    // gate's PAIRED guard possible — a right press must record `rclick` AND an ordinary tap must
    // still record a bare pair, or "every click became a right click" would pass on its own.
    //
    // NOT calling `super`: NSView's default `rightMouseDown` pops up the view's context menu, and a
    // menu tracking loop would block this app's run loop until something dismissed it — a hang, not
    // a failure, which is the worst thing a gate can do. This view has no menu today, so super would
    // be harmless today; the override is what keeps that true if one is ever added.
    override func rightMouseDown(with event: NSEvent) { recordRight("down", event) }
    override func rightMouseUp(with event: NSEvent) { recordRight("up", event) }
    override func rightMouseDragged(with event: NSEvent) { recordRight("drag", event) }

    private func recordRight(_ phase: String, _ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        append("rclick,\(phase),\(Int(p.x.rounded())),\(Int(p.y.rounded())),"
             + "\(Self.modsText(event.modifierFlags))")
        FileHandle.standardError.write(Data("[rclick] \(phase)\n".utf8))
    }

    // ── keyboard + scroll recording, for scripts/gate-window-input.sh ─────────────────────────────
    //
    // TAP LINES STAY BYTE-IDENTICAL (`x,y`): the existing smokes parse field 0 as a number, and a
    // prefixed line would read as NaN. Every new line carries a type prefix instead, and can only
    // appear in a run that actually injects keys or scroll — which no existing smoke does.
    // Verified: gate-wintaptarget.sh still passes unchanged against this file.
    //
    // OBSERVED, and it is the ⌘-swallows-keyup rule showing up in real data: a ⌘C run records
    // `key,down,8,cmd,63` with NO matching `key,up` — macOS does not deliver the keyup to the app
    // while Command is held. See `HeldKeys` in RdevCore for what the host does about it.

    /// LOAD-BEARING for the keyboard gate: a view that is not the first responder receives no
    /// keyDown at all, and the run would read as "keys never arrived" — indistinguishable from a
    /// broken injector.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) { recordKey(event, down: true) }
    override func keyUp(with event: NSEvent) { recordKey(event, down: false) }

    override func flagsChanged(with event: NSEvent) {
        append("flags,\(Self.modsText(event.modifierFlags))")
    }

    override func scrollWheel(with event: NSEvent) {
        append("scroll,\(Self.phaseText(event.phase)),\(Self.phaseText(event.momentumPhase)),"
             + "\(event.hasPreciseScrollingDeltas ? 1 : 0),"
             + "\(Int(event.scrollingDeltaX.rounded())),\(Int(event.scrollingDeltaY.rounded())),"
             + "\(Self.modsText(event.modifierFlags))")
    }

    private func recordKey(_ event: NSEvent, down: Bool) {
        // Hex scalars rather than the characters themselves: no escaping to get wrong, and a shell
        // gate can compare an exact sequence. "hello" -> 68|65|6c|6c|6f
        let scalars = (event.characters ?? "").unicodeScalars.map { String($0.value, radix: 16) }
        append("key,\(down ? "down" : "up"),\(event.keyCode),"
             + "\(Self.modsText(event.modifierFlags)),\(scalars.joined(separator: "|"))")
    }

    /// Only the device-INDEPENDENT bits, as words. The raw value carries device-dependent noise that
    /// would make an exact comparison in a shell gate meaningless.
    private static func modsText(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.shift)    { parts.append("shift") }
        if flags.contains(.control)  { parts.append("ctrl") }
        if flags.contains(.option)   { parts.append("opt") }
        if flags.contains(.command)  { parts.append("cmd") }
        if flags.contains(.capsLock) { parts.append("caps") }
        return parts.isEmpty ? "-" : parts.joined(separator: "+")
    }

    private static func phaseText(_ phase: NSEvent.Phase) -> String {
        if phase.contains(.began) { return "began" }
        if phase.contains(.changed) { return "changed" }
        if phase.contains(.ended) { return "ended" }
        if phase.contains(.cancelled) { return "cancelled" }
        if phase.contains(.mayBegin) { return "mayBegin" }
        if phase.contains(.stationary) { return "stationary" }
        return "none"
    }

    private func record(x: Int, y: Int) {
        append("\(x),\(y)")
        FileHandle.standardError.write(Data("[tap] \(x),\(y)\n".utf8))
    }

    private func append(_ line: String) {
        let text = line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            // LOAD-BEARING fallback: FileHandle(forWritingTo:) returns nil when the file does not
            // exist, so without this a tap is silently DISCARDED if anything removed the log after
            // launch. That reads downstream as "input never arrived" — indistinguishable from a
            // broken injector. (SimTapTarget had this branch; dropping it in the port cost a real
            // debugging detour during the Task 1 gate.)
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

let logURL = URL(fileURLWithPath: logPath)
// Fresh log per launch, so each smoke run starts clean (same as the iOS app).
try? "".write(to: logURL, atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // MUST be regular: an accessory app has no window for SCK to list

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
    styleMask: args.contains("--resizable") ? [.titled, .closable, .resizable] : [.titled, .closable],
    backing: .buffered,
    defer: false)
window.title = "WinTapTarget"
window.contentView = QuadrantView(frame: NSRect(x: 0, y: 0, width: winW, height: winH), logURL: logURL)
window.center()
window.makeKeyAndOrderFront(nil)
// No first responder ⇒ no keyDown ever arrives, which the gate would read as "keys never delivered".
window.makeFirstResponder(window.contentView)
app.activate(ignoringOtherApps: true)

// Geometry is reported to stdout AND to a sidecar file at "<log>.info".
//
// The sidecar is not redundant. A harness must launch this through `open` (i.e. LaunchServices) for
// the app to register as a foreground app — launched directly, `lsappinfo` reports type=NULL, the
// app never becomes properly activatable, and clicks land on whatever window is above it. But `open`
// detaches stdio, so stdout is unreadable exactly when it is needed. Hence the file.
var info = "RESIZABLE=\(args.contains("--resizable") ? 1 : 0)\nPID=\(getpid())\nWINDOW_ID=\(window.windowNumber)\nLOG=\(logPath)\n"

// The content rect in SCREEN coordinates with a TOP-LEFT origin — the space cliclick, CGEvent and
// kCGWindowBounds all use. Reported so a harness can click an exact fraction of the content area
// without guessing at the titlebar height. AppKit works bottom-left, hence the flip against the
// primary screen's height. (Single-display assumption; this is a test tool.)
if let cv = window.contentView {
    let inScreen = window.convertToScreen(cv.frame)
    let primaryH = NSScreen.screens.first?.frame.height ?? inScreen.maxY
    info += "CONTENT=\(Int(inScreen.origin.x)),\(Int(primaryH - inScreen.maxY)),"
          + "\(Int(inScreen.width)),\(Int(inScreen.height))\n"
}

setbuf(stdout, nil)
print(info, terminator: "")
fflush(stdout)
// Written LAST, so a harness that polls for this file knows every value in it is already final.
try? info.write(to: URL(fileURLWithPath: logPath + ".info"), atomically: true, encoding: .utf8)

app.run()
