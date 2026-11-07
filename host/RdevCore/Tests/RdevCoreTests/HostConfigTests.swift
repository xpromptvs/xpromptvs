import XCTest
@testable import RdevCore

final class HostConfigTests: XCTestCase {
    func testDefaultsWithEmptyEnvironment() {
        let c = HostConfig.from(environment: [:])
        XCTAssertEqual(c.signalingBase, "http://localhost:8787")
        XCTAssertFalse(c.useTestPattern)
        XCTAssertEqual(c.fps, 60)
        XCTAssertEqual(c.scale, 1.0)
        XCTAssertEqual(c.bitrateBps, 2_000_000)
        XCTAssertEqual(c.bitrateCapBps, 20_000_000)
        XCTAssertEqual(c.throttleFps, 8)
        XCTAssertEqual(c.throttleBitrateBps, 400_000)
        XCTAssertFalse(c.curtainSelfTest)
    }

    func testPasteDirectoryComesFromTheEnvironmentOnly() {
        XCTAssertEqual(HostConfig.from(environment: ["RDEV_PASTE_DIR": "/tmp/x"]).pasteDirectory, "/tmp/x")
        XCTAssertNil(HostConfig.from(environment: [:]).pasteDirectory)
        XCTAssertNil(HostConfig.from(environment: ["RDEV_PASTE_DIR": ""]).pasteDirectory)
    }

    /// LOAD-BEARING: the STARTING bitrate must default to 2 Mbps, never to the cap.
    /// It used to fall back to the cap, which was invisible while the two were equal —
    /// raising the cap alone would silently have started every source at 20 Mbps.
    func testStartingBitrateDoesNotFollowTheCap() {
        let c = HostConfig.from(environment: ["RDEV_VIDEO_BITRATE_CAP_BPS": "50000000"])
        XCTAssertEqual(c.bitrateCapBps, 50_000_000)
        XCTAssertEqual(c.bitrateBps, 2_000_000)
    }

    func testRequestedBitrateIsClampedToTheCap() {
        let c = HostConfig.from(environment: ["RDEV_VIDEO_BITRATE_BPS": "99000000"])
        XCTAssertEqual(c.bitrateBps, 20_000_000)
    }

    func testExplicitValuesAreRead() {
        let c = HostConfig.from(environment: [
            "RDEV_SIGNALING": "http://127.0.0.1:8787",
            "RDEV_TEST_PATTERN": "1",
            "RDEV_VIDEO_SCALE": "0.5",
            "RDEV_THROTTLE_FPS": "3",
            "RDEV_THROTTLE_BITRATE_BPS": "100000",
            "RDEV_CURTAIN_TEST": "1",
        ])
        XCTAssertEqual(c.signalingBase, "http://127.0.0.1:8787")
        XCTAssertTrue(c.useTestPattern)
        XCTAssertEqual(c.scale, 0.5)
        XCTAssertEqual(c.throttleFps, 3)
        XCTAssertEqual(c.throttleBitrateBps, 100_000)
        XCTAssertTrue(c.curtainSelfTest)
    }

    /// A typo must not take the host down or silently pick something surprising.
    func testUnparseableValuesFallBackToDefaults() {
        let c = HostConfig.from(environment: [
            "RDEV_VIDEO_SCALE": "banana",
            "RDEV_THROTTLE_FPS": "",
            "RDEV_VIDEO_BITRATE_BPS": "not-a-number",
        ])
        XCTAssertEqual(c.scale, 1.0)
        XCTAssertEqual(c.throttleFps, 8)
        XCTAssertEqual(c.bitrateBps, 2_000_000)
    }

    /// Only the exact string "1" enables a flag — "0"/"true"/"" must not.
    func testFlagsRequireExactlyOne() {
        XCTAssertFalse(HostConfig.from(environment: ["RDEV_TEST_PATTERN": "0"]).useTestPattern)
        XCTAssertFalse(HostConfig.from(environment: ["RDEV_TEST_PATTERN": "true"]).useTestPattern)
        XCTAssertTrue(HostConfig.from(environment: ["RDEV_TEST_PATTERN": "1"]).useTestPattern)
    }

    func testKeepAwakeDefaultsOnAndOptsOutOnZero() {
        XCTAssertTrue(HostConfig.from(environment: [:]).keepAwake)
        XCTAssertFalse(HostConfig.from(environment: ["RDEV_KEEP_AWAKE": "0"]).keepAwake)
        // Anything else is ON. A shared Mac that cannot be captured is the failure this prevents, so
        // the variable must be an explicit opt-out, never a typo-activated one.
        XCTAssertTrue(HostConfig.from(environment: ["RDEV_KEEP_AWAKE": "yes"]).keepAwake)
    }
}
