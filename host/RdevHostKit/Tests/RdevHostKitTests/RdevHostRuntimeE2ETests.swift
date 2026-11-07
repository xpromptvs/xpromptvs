import XCTest
@testable import RdevCore
@testable import RdevHostKit

/// The host's E2E status machine: what a poll reports. The ceremonies that change it are
/// `E2EPasskeyCeremonyTests`'.
///
/// The identity is injected already assembled — the live one writes `~/Library`, and a Bazel test
/// sandbox must not. Everything below it is tested in its own suite; what is tested here is the part
/// the app polls.
final class RdevHostRuntimeE2ETests: XCTestCase {

    private struct Device: Decodable { let bundle: String, descriptor: String }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String], root: String, root_id: String
        let devices: [String: Device]
    }
    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-session.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    private var fx: Fixture { Self.fx }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }

    /// Seeded so the installation is the fixture's device H, which is what makes H's bundle a valid
    /// return for it.
    private func identity(trust: InstallationStore.Backend) throws -> E2EHostIdentity {
        var draw = 0
        let seeded: (Int) -> [UInt8] = { count in
            draw += 1
            switch draw {
            case 1: return Array(repeating: 0x11, count: count)
            case 2: return Array(repeating: 0x2A, count: count)
            default: return Array(repeating: 0xE0, count: count)
            }
        }
        guard case .success(let origin) = E2EOrigin.resolve(fx.allowed_origins[0]) else {
            throw E2EOrigin.Failure.malformed
        }
        XCTAssertEqual(origin.rpID, fx.rp_id, "the fixture's policy and the resolver agree")
        return E2EHostIdentity(
            origin: origin,
            manager: E2EIdentityManager(installations: InstallationStore.Memory(), trust: trust,
                                        randomBytes: seeded))
    }

    private func runtime(_ e2e: Result<E2EHostIdentity, E2EHostIdentity.Failure>) -> RdevHostRuntime {
        RdevHostRuntime(config: HostConfig.from(environment: [:]), code: "c", token: "t",
                        e2e: E2EIdentityService(e2e: e2e))
    }

    // MARK: - what a poll reports

    func testAnUnenrolledHostSaysSo() throws {
        let host = runtime(.success(try identity(trust: InstallationStore.Memory())))
        XCTAssertEqual(host.e2eStatus(), .unenrolled)
        XCTAssertEqual(host.e2eStatus().summary, "unenrolled")
    }

    /// **The two unavailable reasons are kept apart all the way to the status line**, because a
    /// plaintext origin and a read-only home directory need completely different fixes and neither
    /// is fixed by retrying.
    func testAnUnassembledIdentityReportsWhy() {
        let host = runtime(.failure(.origin(.insecure)))
        XCTAssertEqual(host.e2eStatus(), .unavailable(.origin(.insecure)))
        XCTAssertEqual(host.e2eStatus().summary, "unavailable (origin: insecure)")
        XCTAssertNil(host.e2eIdentity)

        let noDisk = runtime(.failure(.storageUnavailable))
        XCTAssertEqual(noDisk.e2eStatus().summary, "unavailable (nowhere to write)")
    }

    /// Stored bytes that cannot be read are a PERSON'S decision — overwriting them would silently
    /// abandon an identity — so the status says blocked rather than "not enrolled yet", which is
    /// what would start a ceremony over the top of one.
    func testAnUnreadableTrustRecordIsBlockedRatherThanUnenrolled() throws {
        let trust = InstallationStore.Memory()
        _ = trust.write([0xFF, 0xFF, 0xFF])
        let host = runtime(.success(try identity(trust: trust)))
        XCTAssertEqual(host.e2eStatus(), .blocked(.unreadableTrust))
    }

    /// §12.4 says an interrupted operation is RESUMED, not restarted. This build's own ceremony is
    /// §12.1's local one, with nothing to resume to, so the state is reported and refused — starting a
    /// fresh one would reserve a second window for a device that already has one outstanding.
    func testAnInterruptedOperationIsRefusedRatherThanRestarted() throws {
        var record = E2ETrustStore.Record()
        record.pending = E2ETrustStore.PendingOperation(
            operationID: Array(repeating: 7, count: 32),
            responderDeviceID: Array(repeating: 8, count: 32),
            route: RendezvousRoute(rcode: "r", rtoken: "t"))
        let trust = InstallationStore.Memory()
        _ = trust.write(E2ETrustStore.encode(record)!)

        let host = runtime(.success(try identity(trust: trust)))
        XCTAssertEqual(host.e2eStatus(), .resumable)
    }
}
