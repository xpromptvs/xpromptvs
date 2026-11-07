import XCTest
@testable import RdevCore

/// §10.1's identity as a person reads it, against the same vectors the TypeScript encoder is held
/// to. **The Mac and the browser showing different strings would break the one comparison this code
/// exists for**, and asserting each against a third implementation is the only way to see them agree
/// rather than each agreeing with its own stand-in.
final class E2EIdentityCodeTests: XCTestCase {

    private struct Vector: Decodable { let root_id: String, code: String }
    private struct Fixture: Decodable {
        let alphabet: String, bytes: Int, vectors: [Vector]
    }
    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/identity-code.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    private var fx: Fixture { Self.fx }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }

    func testEveryVectorAgrees() {
        for v in fx.vectors {
            XCTAssertEqual(E2EIdentity.code(rootID: hex(v.root_id)), v.code, v.root_id)
        }
    }

    /// A transposed alphabet passes on whichever rows happen to agree, so the set must reach all 32.
    func testTheVectorsReachEveryCharacter() {
        let seen = Set(fx.vectors.flatMap { $0.code.replacingOccurrences(of: "-", with: "") })
        XCTAssertEqual(seen, Set(fx.alphabet))
    }

    /// Only the first ten bytes are read — the fixture's 0xAA tails say so, and so does this.
    func testOnlyTheFirstTenBytesMatter() {
        var a = [UInt8](repeating: 0x11, count: 32)
        var b = a
        b[10] = 0x99
        XCTAssertEqual(E2EIdentity.code(rootID: a), E2EIdentity.code(rootID: b))
        a[9] = 0x99
        XCTAssertNotEqual(E2EIdentity.code(rootID: a), E2EIdentity.code(rootID: b))
    }

    /// Empty rather than a shorter code: a caller showing "" obviously has nothing, while a short
    /// code looks like an identity and is not one.
    func testTooFewBytesIsNothing() {
        XCTAssertEqual(E2EIdentity.code(rootID: [UInt8](repeating: 0, count: 9)), "")
    }
}
