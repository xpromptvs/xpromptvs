import XCTest
@testable import RdevCore
@testable import RdevHostKit

/// The assembly: which stores, which origin, which policy. Everything under it is tested elsewhere;
/// what is tested here is that the four pieces agree, and that assembling them writes nothing.
final class E2EHostIdentityTests: XCTestCase {

    private func assemble(_ base: String,
                          trust: @escaping () -> InstallationStore.Backend? = { InstallationStore.Memory() })
        -> Result<E2EHostIdentity, E2EHostIdentity.Failure> {
        E2EHostIdentity.assemble(signalingBase: base, installations: InstallationStore.Memory(),
                                 trust: trust)
    }

    func testThePolicyComesFromTheSameResolutionAsTheBrowserURL() throws {
        guard case .success(let identity) = assemble("http://127.0.0.1:8787") else {
            return XCTFail("expected an assembly")
        }
        XCTAssertEqual(identity.origin.url.absoluteString, "http://127.0.0.1:8787")
        XCTAssertEqual(identity.policy.rpID, "127.0.0.1")
        XCTAssertEqual(identity.policy.allowedOrigins, ["http://127.0.0.1:8787"])
    }

    /// A plaintext LAN origin is no relying party a passkey can be made for, so the host says so at
    /// assembly rather than failing every ceremony later for a reason nothing would name.
    func testAMisconfiguredOriginIsRefusedWithItsReason() {
        guard case .failure(let f) = assemble("http://192.168.1.5:8787") else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(f, .origin(.insecure))
    }

    /// **THE ORDER IS THE POINT.** Constructing the real trust store creates
    /// `~/Library/Application Support/dev.rdev.host/`; a host that cannot host a ceremony must not
    /// leave that behind. The closure is how that is observable instead of merely intended.
    func testAMisconfiguredOriginNeverReachesStorage() {
        var constructed = 0
        _ = assemble("http://192.168.1.5:8787", trust: { constructed += 1; return InstallationStore.Memory() })
        XCTAssertEqual(constructed, 0)

        _ = assemble("https://cp.example", trust: { constructed += 1; return InstallationStore.Memory() })
        XCTAssertEqual(constructed, 1, "and a good one does construct it")
    }

    func testNowhereToWriteIsItsOwnFailure() {
        guard case .failure(let f) = assemble("https://cp.example", trust: { nil }) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(f, .storageUnavailable)
    }

    /// Assembly touches neither record. The first write is `load()`'s, which is also the only thing
    /// that can create keys.
    func testAssemblyPersistsNothing() throws {
        let installations = InstallationStore.Memory()
        let trust = InstallationStore.Memory()
        let identity = try XCTUnwrap(try? E2EHostIdentity.assemble(
            signalingBase: "https://cp.example", installations: installations,
            trust: { trust }).get())
        XCTAssertNil(installations.read())
        XCTAssertNil(trust.read())

        guard case .success(let loaded) = identity.load() else { return XCTFail("expected a load") }
        XCTAssertEqual(loaded.state, .unenrolled)
        XCTAssertNotNil(installations.read(), "load() is what creates the installation")
        XCTAssertNil(trust.read(), "and enrollment is what writes trust")
    }

    /// The relying party a passkey ceremony runs for comes from configuration — the product's on its
    /// domain, the one the app's `webcredentials:` entitlement names — and never from anything a server says.
    func testTheRelyingPartyIsTheProductsOnItsDomain() throws {
        for base in ["https://xpromptvs.ai", "https://app.xpromptvs.ai"] {
            guard case .success(let identity) = assemble(base) else { return XCTFail("expected an assembly") }
            // The client's move to `app.` moved no passkey: the relying party is still the apex's.
            XCTAssertEqual(identity.relyingParty, "xpromptvs.ai", base)
            XCTAssertEqual(identity.policy.allowedOrigins, ["https://xpromptvs.ai", "https://app.xpromptvs.ai"], base)
        }
    }
}
