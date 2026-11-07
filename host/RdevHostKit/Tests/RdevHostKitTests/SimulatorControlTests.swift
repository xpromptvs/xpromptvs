import XCTest
import RdevCore
@testable import RdevHostKit

/// Every `devicectl` call rdev makes, as the command line it runs — the only contract with a supported tool.
final class SimulatorControlTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var calls: [(args: [String], stdin: Data?)] = []
        var reply: (Int32, Data) = (0, Data())
    }

    private func control(_ r: Recorder) -> SimulatorControl {
        SimulatorControl(run: { args, stdin, _ in r.calls.append((args, stdin)); return r.reply })
    }

    func testRotate() {
        let r = Recorder()
        XCTAssertTrue(control(r).rotate(udid: "U", left: true))
        XCTAssertEqual(r.calls.last?.args, ["devicectl", "device", "orientation", "rotate", "--device", "U", "left"])
        _ = control(r).rotate(udid: "U", left: false)
        XCTAssertEqual(r.calls.last?.args.last, "right")
    }

    func testShake() {
        let r = Recorder()
        XCTAssertTrue(control(r).shake(udid: "U"))
        XCTAssertEqual(r.calls.last?.args, ["devicectl", "device", "notification", "post", "--device", "U",
                                            "--name", "com.apple.UIKit.SimulatorShake"])
    }

    func testThePasteboardTakesTheTextOnStdin() {
        let r = Recorder()
        XCTAssertTrue(control(r).copyToPasteboard(udid: "U", text: "héllo 😀"))
        XCTAssertEqual(r.calls.last?.args, ["devicectl", "device", "pasteboard", "copy", "--device", "U"])
        XCTAssertEqual(r.calls.last?.stdin, Data("héllo 😀".utf8))
    }

    func testDisplayInfo() {
        let r = Recorder()
        r.reply = (0, Data(#"{"result":{"displays":[{"currentOrientation":"rot90","nativeSize":[1206,2622],"pointScale":3,"primary":true}]}}"#.utf8))
        XCTAssertEqual(control(r).displayInfo(udid: "U")?.rotation, .rot90)
        XCTAssertEqual(r.calls.last?.args, ["devicectl", "device", "info", "displays", "--device", "U", "-j", "-"])
    }

    func testAFailureIsFalseOrNil() {
        let r = Recorder()
        r.reply = (1, Data())
        XCTAssertFalse(control(r).shake(udid: "U"))
        XCTAssertNil(control(r).displayInfo(udid: "U"))
        let timedOut = SimulatorControl(run: { _, _, _ in nil })
        XCTAssertFalse(timedOut.rotate(udid: "U", left: true))
    }

    func testTheCatalogsConversion() throws {
        let s = try XCTUnwrap(SimulatorCatalog.simInfo(udid: "U", name: "iPhone 18 Pro", runtime: "iOS 27.0", state: 3,
                                                        pixels: CGSize(width: 1206, height: 2622), scale: 3))
        XCTAssertEqual(s, SimInfo(udid: "U", name: "iPhone 18 Pro", os: "iOS 27.0", state: .booted,
                                  w: 402, h: 874, pxW: 1206, pxH: 2622))
        XCTAssertNil(SimulatorCatalog.simInfo(udid: "U", name: "x", runtime: "iOS 27.0", state: 0,
                                              pixels: CGSize(width: 1, height: 1), scale: 1), "creating")
        XCTAssertNil(SimulatorCatalog.simInfo(udid: "U", name: "x", runtime: "iOS 27.0", state: 3,
                                              pixels: .zero, scale: 3), "no screen")
    }

    /// FINAL REVIEW I9. A child that exits WITHOUT reading its stdin (devicectl refusing a shut-down device) must neither
    /// hang the caller nor kill the host: the write that fills the pipe must not block past the deadline, and the
    /// EPIPE it then meets must not be a SIGPIPE.
    func testAChildThatNeverReadsItsStdinCannotHangOrKillTheHost() {
        let t0 = Date()
        let r = SimulatorControl.run(executable: "/usr/bin/true", arguments: [], stdin: Data(repeating: 0x61, count: 1 << 20),
                                     deadline: 5)
        XCTAssertEqual(r?.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
    }

    func testADeadlineKillsAChildThatNeverExits() {
        let t0 = Date()
        XCTAssertNil(SimulatorControl.run(executable: "/bin/sleep", arguments: ["10"], stdin: nil, deadline: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }
}
