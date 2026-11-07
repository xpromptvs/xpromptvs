import Foundation
import RdevCore

/// Everything rdev asks of a simulator through a SUPPORTED tool — `xcrun devicectl`, whose JSON output its own help
/// says "is versioned and will remain stable across releases". Rotation, shake, the pasteboard and the display's
/// rotation go here rather than through private API (spec, "Architecture").
///
/// EVERY CALL IS A SUBPROCESS WITH A DEADLINE, and BLOCKS: call it off the main thread and off any lock.
public struct SimulatorControl: Sendable {
    /// `xcrun <args>` with `stdin`, killed at `deadline` seconds. nil when it could not run or was killed.
    public typealias Runner = @Sendable (_ args: [String], _ stdin: Data?, _ deadline: TimeInterval) -> (status: Int32, stdout: Data)?

    public static let shakeNotification = "com.apple.UIKit.SimulatorShake"
    public static let live = SimulatorControl(run: SimulatorControl.xcrun)

    let run: Runner
    public init(run: @escaping Runner) { self.run = run }

    public func displayInfo(udid: String) -> SimDisplayInfo? {
        guard let r = run(["devicectl", "device", "info", "displays", "--device", udid, "-j", "-"], nil, 10),
              r.status == 0 else { return nil }
        return SimDisplayInfo.parse(devicectlJSON: r.stdout)
    }

    public func rotate(udid: String, left: Bool) -> Bool {
        ok(["devicectl", "device", "orientation", "rotate", "--device", udid, left ? "left" : "right"])
    }

    public func shake(udid: String) -> Bool {
        ok(["devicectl", "device", "notification", "post", "--device", udid, "--name", Self.shakeNotification])
    }

    /// The simulator's GENERAL pasteboard, as plain text (measured: read back by `pasteboard paste` and `simctl pbpaste`).
    public func copyToPasteboard(udid: String, text: String) -> Bool {
        ok(["devicectl", "device", "pasteboard", "copy", "--device", udid], stdin: Data(text.utf8))
    }

    private func ok(_ args: [String], stdin: Data? = nil) -> Bool {
        run(args, stdin, 15)?.status == 0
    }

    static func xcrun(_ args: [String], _ stdin: Data?, _ deadline: TimeInterval) -> (status: Int32, stdout: Data)? {
        run(executable: "/usr/bin/xcrun", arguments: args, stdin: stdin, deadline: deadline)
    }

    /// `executable` with `arguments` and `stdin`, killed at `deadline` seconds; nil when it could not run or was killed.
    static func run(executable: String, arguments args: [String], stdin: Data?,
                    deadline: TimeInterval) -> (status: Int32, stdout: Data)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        if let stdin {
            // A CHILD THAT EXITS WITHOUT READING ITS STDIN (devicectl refusing a shut-down device) must neither hang this
            // caller nor kill the host (final review I9; `testAChildThatNeverReadsItsStdinCannotHangOrKillTheHost`):
            // the legacy `write(_:)` RAISED an Objective-C exception on EPIPE — uncatchable from Swift — and blocked
            // before the deadline below was even armed. So the write is its own task, after the start, under
            // `F_SETNOSIGPIPE` (EPIPE is an error, never a signal), through the THROWING `write(contentsOf:)`.
            let writer = input.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }
        // READ CONCURRENTLY: a child that fills the pipe's buffer blocks until someone reads it, and would then
        // never exit for the semaphore below.
        let collected = DispatchQueue(label: "rdev.xcrun.read")
        var data = Data()
        let reading = DispatchGroup()
        reading.enter()
        collected.async { data = out.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        guard exited.wait(timeout: .now() + deadline) == .success else {
            p.terminate()
            return nil
        }
        reading.wait()
        return (p.terminationStatus, data)
    }
}
