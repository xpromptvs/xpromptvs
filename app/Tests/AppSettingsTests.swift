import XCTest
@testable import ShellstormCore

final class AppSettingsTests: XCTestCase {
    func testLaunchDashboardDefaultsOffAndOptInSurvivesOtherWrites() throws {
        XCTAssertFalse(AppSettings.parse(nil).showDashboardOnStartup)
        XCTAssertFalse(AppSettings.parse(Data(#"{"showDashboardOnStartup":"false"}"#.utf8)).showDashboardOnStartup)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try AppSettings.update(dir: dir) { $0.showDashboardOnStartup = true }
        try AppSettings.update(dir: dir) { $0.autoShare = true }
        XCTAssertTrue(AppSettings.read(dir: dir).showDashboardOnStartup)
        XCTAssertTrue(AppSettings.read(dir: dir).autoShare)
    }
    func testRemoteUpdatesDefaultOnAndPreserveOtherSettings() throws {
        XCTAssertTrue(AppSettings.parse(nil).allowRemoteUpdates)
        XCTAssertTrue(AppSettings.parse(Data(#"{"allowRemoteUpdates":0}"#.utf8)).allowRemoteUpdates)
        XCTAssertFalse(AppSettings.parse(Data(#"{"allowRemoteUpdates":false}"#.utf8)).allowRemoteUpdates)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try AppSettings.update(dir: dir) { $0.autoShare = true; $0.smoothScroll = false }
        try AppSettings.update(dir: dir) { $0.allowRemoteUpdates = false }
        let s = AppSettings.read(dir: dir)
        XCTAssertTrue(s.autoShare); XCTAssertFalse(s.smoothScroll); XCTAssertFalse(s.allowRemoteUpdates)
    }
    func testAnythingButALiteralTrueIsOff() {
        for text in [nil, "", "not json", "[]", "null", "42", #"{"autoShare":"yes"}"#, #"{"autoShare":1}"#, "{}"] {
            XCTAssertEqual(AppSettings.parse(text.map { Data($0.utf8) }), AppSettings(autoShare: false), text ?? "nil")
        }
        XCTAssertEqual(AppSettings.parse(Data(#"{"autoShare":true,"other":1}"#.utf8)), AppSettings(autoShare: true))
    }
    func testRoundTripCreatesTheDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("nested")
        XCTAssertEqual(AppSettings.read(dir: dir), AppSettings(autoShare: false))
        try AppSettings(autoShare: true).write(dir: dir)
        XCTAssertEqual(AppSettings.read(dir: dir), AppSettings(autoShare: true))
        let text = try String(contentsOf: dir.appendingPathComponent("app-settings.json"), encoding: .utf8)
        XCTAssertTrue(text.contains(#""autoShare" : true"#) || text.contains(#""autoShare":true"#))
    }
    /// Smooth scrolling is the one value the dashboard and every session window share (they are two
    /// origins with two web storages): it defaults on, and each key stands on its own.
    func testSmoothScrollIsItsOwnKey() {
        XCTAssertFalse(AppSettings.parse(Data(#"{"smoothScroll":false}"#.utf8)).smoothScroll)
        XCTAssertEqual(AppSettings.parse(Data(#"{"smoothScroll":true}"#.utf8)), AppSettings(autoShare: false, smoothScroll: true))
        XCTAssertEqual(AppSettings.parse(Data(#"{"autoShare":true,"smoothScroll":"yes"}"#.utf8)),
                       AppSettings(autoShare: true, smoothScroll: true))
        XCTAssertEqual(AppSettings.parse(Data(#"{"autoShare":"yes","smoothScroll":true}"#.utf8)),
                       AppSettings(autoShare: false, smoothScroll: true))
        XCTAssertEqual(AppSettings.parse(nil), AppSettings(autoShare: false, smoothScroll: true))
    }
    /// Changing one setting keeps the other: `setAutoShare` wrote `AppSettings(autoShare:)` whole, which
    /// with a second key would have switched smooth scrolling off every time.
    func testUpdateKeepsTheOtherKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try AppSettings.update(dir: dir) { $0.autoShare = true }
        let after = try AppSettings.update(dir: dir) { $0.smoothScroll = true }
        XCTAssertEqual(after, AppSettings(autoShare: true, smoothScroll: true))
        try AppSettings.update(dir: dir) { $0.autoShare = false }
        XCTAssertEqual(AppSettings.read(dir: dir), AppSettings(autoShare: false, smoothScroll: true))
    }
    func testFlagThenVariableThenSetting() {
        let off = AppSettings(autoShare: false), on = AppSettings(autoShare: true)
        XCTAssertEqual(AppSettings.autoShareReason(argv: ["x", "--share"], env: [:], settings: off), "--share")
        XCTAssertEqual(AppSettings.autoShareReason(argv: [], env: ["RDEV_AUTO_SHARE": "1"], settings: off), "RDEV_AUTO_SHARE=1")
        XCTAssertEqual(AppSettings.autoShareReason(argv: [], env: [:], settings: on), "the Auto share on start setting")
        XCTAssertNil(AppSettings.autoShareReason(argv: [], env: ["RDEV_AUTO_SHARE": "0"], settings: off))
    }
}
