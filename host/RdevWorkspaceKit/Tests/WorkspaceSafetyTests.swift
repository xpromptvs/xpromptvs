import Foundation
import CoreGraphics
import RdevWorkspaceKit
import XCTest

final class WorkspaceSafetyTests: XCTestCase {
    func testIdentityRequiresProcessGenerationAndBundle() {
        let a: [String: Any] = ["pid": 42, "generation": "123:456", "bundle": "org.example.App"]
        XCTAssertTrue(RWKSameProcess(a, a))
        for field in ["pid", "generation", "bundle"] {
            var b = a; b.removeValue(forKey: field)
            XCTAssertFalse(RWKSameProcess(a, b))
        }
        var replacement = a; replacement["generation"] = "123:457"
        XCTAssertFalse(RWKSameProcess(a, replacement))
        XCTAssertFalse(RWKSameProcess([:], [:]))
    }
    func testClampingHandlesNegativeDisplayOriginAndOversize() {
        let bounds = CGRect(x: -1280, y: -400, width: 1280, height: 800)
        let frame = RWKClampFrame(CGRect(x: 999, y: 999, width: 1600, height: 1000), bounds)
        XCTAssertEqual(frame, bounds)
        XCTAssertEqual(RWKClampFrame(CGRect(x: -1200, y: -350, width: 500, height: 400), bounds), CGRect(x: -1200, y: -350, width: 500, height: 400))
    }
    func testLargeWindowsLeaveRoomForDistinctApplicationPlacement() {
        let workspace = CGRect(x: -1280, y: 100, width: 1280, height: 800)
        let original = CGRect(x: 20, y: 20, width: 1600, height: 1000)
        let first = RWKInitialFrame(original, workspace, 0)
        let second = RWKInitialFrame(original, workspace, 1)
        XCTAssertTrue(workspace.contains(first))
        XCTAssertTrue(workspace.contains(second))
        XCTAssertNotEqual(first.origin, second.origin)
        XCTAssertGreaterThan(second.minY, first.minY)
    }
    func testUnresolvedAndMalformedColdJournalsAreRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.json")
        for text in ["broken", "{}", "[{\"state\":\"moved\"}]", "[{\"state\":\"recorded\"}]"] {
            try text.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try RWKWorkspace(journalURL: url))
        }
        try "[]".write(to: url, atomically: true, encoding: .utf8)
        let workspace = try RWKWorkspace(journalURL: url)
        XCTAssertEqual(workspace.displayID, 0)
        XCTAssertTrue(workspace.snapshot.isEmpty)
    }

    func testReadableColdJournalReportsUnresolvedRecordsWithoutChangingIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.json")
        let contents = "[{\"state\":\"moved\"},{\"state\":\"restored\"},{\"state\":\"recorded\"}]"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RWKWorkspace(journalURL: url)) { error in
            XCTAssertEqual((error as NSError).userInfo["unresolvedCount"] as? Int, 2)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), contents)
    }
}
