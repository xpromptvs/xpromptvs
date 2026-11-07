import XCTest
@testable import RdevCore

/// The §9.2 durable-route derivation, against vectors a THIRD implementation produced
/// (`scripts/gen_rendezvous_fixture.py`).
final class RendezvousSeedTests: XCTestCase {

    private struct Case: Decodable {
        let name: String, seed: String, rcode: String, rtoken: String
        let pairing_code: String?, pairing_seed: String?, pairing_token: String?
    }
    private struct Fixture: Decodable { let salt: String, alphabet: String; let cases: [Case] }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/rendezvous-v7.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }

    func testMatchesTheCrossImplementationVectors() throws {
        let f = try fixture()
        XCTAssertFalse(f.cases.isEmpty, "an empty fixture would assert nothing")
        for c in f.cases {
            let route = try XCTUnwrap(RendezvousSeed.derive(seed: hex(c.seed)), c.name)
            XCTAssertEqual(route.rcode, c.rcode, c.name)
            XCTAssertEqual(route.rtoken, c.rtoken, c.name)
        }
    }

    /// The constants ARE the derivation. A fixture regenerated under a different salt would agree
    /// with itself forever and with no shipped build.
    func testTheFixturesSaltAndAlphabetAreTheOnesThisModuleUses() throws {
        let f = try fixture()
        XCTAssertEqual(f.salt, RendezvousSeed.salt)
        XCTAssertEqual(f.alphabet, String(RendezvousSeed.alphabet))
    }

    /// §9.1 and §9.2 are THE SAME CONSTRUCTION under different labels, which is exactly why this is
    /// worth a test: a build deriving a durable route under the pairing salt would produce a
    /// perfectly well-formed code and token, register them, and be unreachable at the address every
    /// peer persisted.
    func testTheLabelSeparatesTheTwoDerivationsCompletely() throws {
        let f = try fixture()
        let c = try XCTUnwrap(f.cases.first { $0.pairing_code != nil })
        let route = try XCTUnwrap(RendezvousSeed.derive(seed: hex(c.seed)))
        // §9.1's seed is 16 bytes and §9.2's is 32, so the fixture carries the pairing half
        // explicitly: the first 16 bytes of the same material, under the other label.
        let pairing = try XCTUnwrap(PairingSeed.derive(seed: hex(try XCTUnwrap(c.pairing_seed))))

        XCTAssertNotEqual(RendezvousSeed.salt, PairingSeed.salt)
        XCTAssertEqual(route.rcode, c.rcode)
        XCTAssertEqual(pairing.code, c.pairing_code)
        XCTAssertNotEqual(route.rcode, pairing.code)
        XCTAssertNotEqual(route.rtoken, pairing.token)
    }

    /// §9.2 has NO psk by design: a durable route is public, and all the authority is in the chain.
    /// Asserted because "add a psk here for symmetry with §9.1" is the tempting wrong move — a
    /// durable pre-shared key would turn room seizure from denial of service into impersonation.
    func testADurableRouteCarriesNoSecret() throws {
        let route = try XCTUnwrap(RendezvousSeed.derive(seed: Array(repeating: 0, count: 32)))
        XCTAssertEqual(route, RendezvousRoute(rcode: route.rcode, rtoken: route.rtoken),
                       "RendezvousRoute has exactly two fields; adding a third fails this")
    }

    func testSeedLengthIsEnforcedNeverPadded() {
        for n in [0, 16, 31, 33, 64] {
            XCTAssertNil(RendezvousSeed.derive(seed: Array(repeating: 0, count: n)), "\(n) bytes")
        }
    }

    func testRouteShape() throws {
        let f = try fixture()
        let route = try XCTUnwrap(RendezvousSeed.derive(seed: hex(f.cases[0].seed)))
        XCTAssertEqual(route.rcode.count, 8)
        XCTAssertTrue(route.rcode.allSatisfy { RendezvousSeed.alphabet.contains($0) })
        // Lowercase, v4, RFC 4122 variant — the session Durable Object compares tokens as exact
        // strings against what `crypto.randomUUID()` minted.
        XCTAssertEqual(route.rtoken, route.rtoken.lowercased())
        XCTAssertEqual(route.rtoken.count, 36)
        let parts = route.rtoken.split(separator: "-")
        XCTAssertEqual(parts.map(\.count), [8, 4, 4, 4, 12])
        XCTAssertEqual(parts[2].first, "4")
        XCTAssertTrue("89ab".contains(parts[3].first!))
    }
}
