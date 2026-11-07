import XCTest
@testable import ShellstormCore

final class NativeSourceWindowManifestTests: XCTestCase {
    private func source(_ id: String = "win:11", kind: String = "window") -> [String: Any] {
        ["source": id, "kind": kind, "title": "Editor", "minimized": false, "width": 640, "height": 480]
    }
    private func manifest(_ sources: [[String: Any]]? = nil) -> [String: Any] {
        ["generation": 1, "revision": 2, "driving": true, "focused": "win:11", "theme": "dark", "sources": sources ?? [source()]]
    }
    func testSnapshotPreservesFullMembershipIncludingMinimizedSources() throws {
        var minimized = source("sim:fixture", kind: "simulator"); minimized["minimized"] = true
        let value = try XCTUnwrap(NativeSourceWindowManifest.parse(manifest([source(), minimized])))
        XCTAssertEqual(value.generation, 1); XCTAssertEqual(value.revision, 2)
        XCTAssertTrue(value.driving); XCTAssertEqual(value.focused, "win:11")
        XCTAssertEqual(value.sources.map(\.source), ["win:11", "sim:fixture"])
        XCTAssertTrue(value.sources[1].minimized)
        XCTAssertEqual(value.sources[0].width, 640)
    }
    func testScalarTypesAndSafeIntegerGenerationsAreExact() {
        for (field, value) in [("generation", true as Any), ("generation", -1), ("generation", 9_007_199_254_740_992 as Any),
                               ("revision", 1.5), ("driving", 1), ("theme", "system")] {
            var object = manifest(); object[field] = value
            XCTAssertNil(NativeSourceWindowManifest.parse(object), field)
        }
        XCTAssertNil(NativeSourceWindowManifest.parse([]))
    }
    func testDuplicateUnknownAndUnboundedSourceDescriptorsAreRefused() {
        XCTAssertNil(NativeSourceWindowManifest.parse(manifest([source(), source()])))
        for invalid in [source("", kind: "window"), source("apps:fixture", kind: "application"),
                        source(String(repeating: "s", count: 257))] {
            var object = manifest([invalid]); object["focused"] = NSNull()
            XCTAssertNil(NativeSourceWindowManifest.parse(object))
        }
        var long = source(); long["title"] = String(repeating: "é", count: 513)
        XCTAssertNil(NativeSourceWindowManifest.parse(manifest([long])))
    }
    func testUnknownSizesAreAllowedButInvalidGeometryIsNot() throws {
        var unknown = source(); unknown.removeValue(forKey: "width"); unknown.removeValue(forKey: "height")
        let parsed = try XCTUnwrap(NativeSourceWindowManifest.parse(manifest([unknown])))
        XCTAssertNil(parsed.sources[0].width); XCTAssertNil(parsed.sources[0].height)
        for value in [0.0, -1, Double.infinity, Double.nan, 32769] {
            var invalid = source(); invalid["width"] = value
            XCTAssertNil(NativeSourceWindowManifest.parse(manifest([invalid])))
        }
        var invalid = source(); invalid["minimized"] = 1
        XCTAssertNil(NativeSourceWindowManifest.parse(manifest([invalid])))
    }
    func testTerminalAndPassiveSnapshotsDoNotInventAFocusedSource() throws {
        var terminal = manifest(); terminal["focused"] = NSNull(); terminal["driving"] = false
        XCTAssertNil(try XCTUnwrap(NativeSourceWindowManifest.parse(terminal)).focused)
        var missing = manifest(); missing.removeValue(forKey: "focused")
        XCTAssertNil(NativeSourceWindowManifest.parse(missing))
        var invalid = manifest(); invalid["focused"] = "win:99"
        XCTAssertNil(NativeSourceWindowManifest.parse(invalid))
    }
    func testAudioHintAcceptsOnlyMutedOrYieldedWithABoundedExplanation() throws {
        for state in ["muted", "yielded"] {
            var value = source(); value["audioStatus"] = ["state": state, "title": "Audio elsewhere"]
            XCTAssertNotNil(NativeSourceWindowManifest.parse(manifest([value])))
        }
        for hint: [String: Any] in [["state": "unknown", "title": "Unknown"], ["state": "muted", "title": String(repeating: "é", count: 513)]] {
            var value = source(); value["audioStatus"] = hint
            XCTAssertNil(NativeSourceWindowManifest.parse(manifest([value])))
        }
    }

}
