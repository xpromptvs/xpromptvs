import IOSurface
import RdevSimKit
import XCTest

/// AGAINST A REAL SIMULATOR the runner created and booted — never a person's. Skipped without RDEV_SIM_LIVE_UDID.
final class RdevSimKitLiveTests: XCTestCase {
    private var udid: String!
    private var set: RSKDeviceSet!

    override func setUpWithError() throws {
        guard let u = ProcessInfo.processInfo.environment["RDEV_SIM_LIVE_UDID"], !u.isEmpty else {
            throw XCTSkip("set RDEV_SIM_LIVE_UDID to a booted simulator you created")
        }
        udid = u
        set = try RSKDeviceSet.load(withDeveloperDir: Self.developerDir())
    }

    static func developerDir() -> String {
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); p.arguments = ["-p"]; p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `availableDevices`, `runtimeIdentifier` and `runtime.name` were UNMEASURED when the shim was written.
    func testListsTheDeviceWithItsRuntimeAndScreen() throws {
        let d = try XCTUnwrap(try set.iOSDevices().first { $0.udid == udid })
        XCTAssertTrue(d.runtimeName.hasPrefix("iOS "), d.runtimeName)
        XCTAssertEqual(d.state, 3, "booted")
        XCTAssertGreaterThan(d.screenPixels.width, 0)
        XCTAssertGreaterThan(d.screenScale, 1)
        print("[live] \(d.name) \(d.runtimeName) \(d.screenPixels) @\(d.screenScale)x CoreSimulator \(set.coreSimulatorVersion)")
    }

    func testTheFramebufferDeliversASurface() throws {
        let got = expectation(description: "a surface")
        got.assertForOverFulfill = false
        let q = DispatchQueue(label: "live.fb")
        let fb = try RSKFramebuffer.attach(toDevice: udid, in: set, queue: q,
                                           surfaceChanged: { s in if s != nil { got.fulfill() } },
                                           framePresented: {}, propertiesChanged: {})
        wait(for: [got], timeout: 5)
        print("[live] framebuffer path \(fb.callbackPath)")
        fb.detach()
    }

    func testTheDigitizerAnswersAndTakesAHomePress() throws {
        let h = try RSKHIDConnection.connect(toDevice: udid, in: set, attempts: 2)
        XCTAssertFalse(h.invalidated)
        h.send(RSKButtonMessage(0x0C, 0x40, true))
        Thread.sleep(forTimeInterval: 0.1)
        h.send(RSKButtonMessage(0x0C, 0x40, false))
        h.close()
        XCTAssertTrue(h.invalidated)
    }
}
