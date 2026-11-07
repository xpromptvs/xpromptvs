import XCTest
@testable import RdevCore
@testable import RdevE2E

/// The prepared-identity loader. It is product code behind an environment variable, so what matters
/// is that it is INERT unless asked for, and that asking for something it cannot supply is a
/// refusal rather than a quiet fall back to no identity at all.
final class E2ETestIdentityTests: XCTestCase {

    private func write(_ json: String) throws -> String {
        let path = NSTemporaryDirectory() + "rdev-test-identity-\(UUID().uuidString).json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// A minimal file of the shape `scripts/gen_e2e_test_identities.py` emits. The bundle is not a
    /// real chain — nothing here verifies one, and a loader that cared would be duplicating
    /// `E2EVerify`.
    private func file(root: String = String(repeating: "ab", count: 40)) -> String {
        func half(_ signing: String) -> String {
            """
            {"signing_private_key": "\(String(repeating: signing, count: 32))",
             "noise_private_key": "\(String(repeating: "22", count: 32))",
             "rendezvous_seed": "\(String(repeating: "33", count: 32))",
             "bundle": "\(String(repeating: "44", count: 20))"}
            """
        }
        return "{\"root\": \"\(root)\", \"host\": \(half("11")), \"client\": \(half("55"))}"
    }

    func testItIsInertUnlessAskedFor() {
        XCTAssertNil(E2ETestIdentity.stores(processEnvironment: [:]))
        XCTAssertNil(E2ETestIdentity.stores(processEnvironment: ["RDEV_E2E_TEST_IDENTITY": ""]))
        XCTAssertNil(E2ETestIdentity.stores(processEnvironment: ["RDEV_E2E_TEST_IDENTITY": "   "]))
    }

    /// **A test that asked for a prepared identity and did not get one must not quietly become a
    /// device with none** — it would enrol for real, or refuse every peer, and neither failure
    /// mentions the file.
    func testAnUnusableFileIsARefusalRatherThanNoIdentity() throws {
        XCTAssertNil(E2ETestIdentity.stores(
            processEnvironment: ["RDEV_E2E_TEST_IDENTITY": "/nonexistent/nope.json"]))
        let garbage = try write("{ not json")
        XCTAssertNil(E2ETestIdentity.stores(processEnvironment: ["RDEV_E2E_TEST_IDENTITY": garbage]))
        let shortKeys = try write("""
        {"root": "aabb", "host": {"signing_private_key": "00", "noise_private_key": "00",
         "rendezvous_seed": "00", "bundle": "00"},
         "client": {"signing_private_key": "00", "noise_private_key": "00",
         "rendezvous_seed": "00", "bundle": "00"}}
        """)
        XCTAssertNil(E2ETestIdentity.stores(
            processEnvironment: ["RDEV_E2E_TEST_IDENTITY": shortKeys]))
    }

    /// The trim is what makes this true, and it is here because nothing else tests it: an empty or
    /// whitespace-only value already fails at the filesystem, so the padded PATH is the only case
    /// that tells the trim apart from nothing at all.
    func testAPaddedPathStillResolves() throws {
        let path = try write(file())
        XCTAssertNotNil(E2ETestIdentity.stores(
            processEnvironment: ["RDEV_E2E_TEST_IDENTITY": "  \(path)  "]))
    }

    func testItInstallsBothRecordsAndTheDeviceIsReady() throws {
        let path = try write(file())
        let stores = try XCTUnwrap(E2ETestIdentity.stores(
            processEnvironment: ["RDEV_E2E_TEST_IDENTITY": path]))

        let manager = E2EIdentityManager(installations: stores.installations, trust: stores.trust)
        guard case .success(let loaded) = manager.load() else { return XCTFail("load") }
        guard case .ready(let cleanup) = loaded.state else {
            return XCTFail("expected ready, got \(loaded.state)")
        }
        XCTAssertFalse(cleanup)
        XCTAssertNotNil(loaded.deviceDescriptor)
        // §12.2: nothing has been published, and saying otherwise would hide a real failure behind
        // a fixture. A gate that wants `confirmed` has to actually publish.
        XCTAssertEqual(loaded.record.publicationStatus, .unconfirmed)
    }

    /// The two halves are different devices — a host and a client sharing one identity would make
    /// §11.1's expected-peer check meaningless.
    func testTheRoleSelectsWhichHalfIsInstalled() throws {
        let path = try write(file())
        let host = try XCTUnwrap(E2ETestIdentity.stores(
            processEnvironment: ["RDEV_E2E_TEST_IDENTITY": path, "RDEV_E2E_TEST_ROLE": "host"]))
        let client = try XCTUnwrap(E2ETestIdentity.stores(
            processEnvironment: ["RDEV_E2E_TEST_IDENTITY": path, "RDEV_E2E_TEST_ROLE": "client"]))
        XCTAssertNotEqual(host.installations.read(), client.installations.read())

        // An unknown role is the HOST, which is what a harness without the variable wants.
        let unknown = try XCTUnwrap(E2ETestIdentity.stores(
            processEnvironment: ["RDEV_E2E_TEST_IDENTITY": path, "RDEV_E2E_TEST_ROLE": "wat"]))
        XCTAssertEqual(unknown.installations.read(), host.installations.read())
    }

    /// **IN MEMORY, NEVER IN THE KEYCHAIN.** A test identity that persisted would outlive the run
    /// that made it and could be picked up by a later one that meant to be unenrolled.
    func testTheStoresAreInMemory() throws {
        let path = try write(file())
        let stores = try XCTUnwrap(E2ETestIdentity.stores(
            processEnvironment: ["RDEV_E2E_TEST_IDENTITY": path]))
        XCTAssertTrue(stores.installations is InstallationStore.Memory)
        XCTAssertTrue(stores.trust is InstallationStore.Memory)
    }
}
