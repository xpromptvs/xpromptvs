import XCTest
@testable import RdevCore

/// The simulator's keyboard takes USB HID usages, and the table is read TWICE — once in `SimKeyUsage`, once in
/// `protocol/fixtures/sim-key-usages.json` — so a typo in either fails here instead of in a person's typing.
final class SimKeyUsageTests: XCTestCase {
    private struct Fixture: Decodable { let codes: [String: UInt32]; let chars: [String: [Value]] }
    private enum Value: Decodable {
        case n(UInt32), b(Bool)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .b(b) } else { self = .n(try c.decode(UInt32.self)) }
        }
    }
    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/sim-key-usages.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    func testEveryCodeAgreesWithTheFixture() {
        XCTAssertEqual(SimKeyUsage.codes, Self.fx.codes)
    }

    func testEveryCharacterAgreesWithTheFixture() {
        XCTAssertEqual(SimKeyUsage.chars.count, Self.fx.chars.count)
        for (s, v) in Self.fx.chars {
            guard case .n(let usage) = v[0], case .b(let shift) = v[1] else { return XCTFail("bad fixture row \(s)") }
            let got = SimKeyUsage.usage(forCharacter: Character(s))
            XCTAssertEqual(got?.usage, usage, "usage of \(s.debugDescription)")
            XCTAssertEqual(got?.shift, shift, "shift of \(s.debugDescription)")
        }
    }

    /// What a soft keyboard can produce that no US key types — the cases `sim-text` pastes instead.
    func testWhatNoKeyTypesIsNotTypeable() {
        XCTAssertNil(SimKeyUsage.usage(forCharacter: "é"))
        XCTAssertNil(SimKeyUsage.usage(forCharacter: "😀"))
        XCTAssertNil(SimKeyUsage.usage(forCode: "Unidentified"))
        XCTAssertTrue(SimKeyUsage.typeable("Hello, World!\n"))
        XCTAssertFalse(SimKeyUsage.typeable("héllo"))
        XCTAssertFalse(SimKeyUsage.typeable(""), "nothing to type is not a typing")
    }

    /// Measured 2026-10-13: these usages typed "abc", ⌘ (0xE3) + V (0x19) pasted, ⇧ (0xE1) chorded a capital.
    func testTheMeasuredUsages() {
        XCTAssertEqual(SimKeyUsage.usage(forCode: "KeyA"), 4)
        XCTAssertEqual(SimKeyUsage.leftCommand, 0xE3)
        XCTAssertEqual(SimKeyUsage.v, 0x19)
        XCTAssertEqual(SimKeyUsage.leftShift, 0xE1)
    }
}
