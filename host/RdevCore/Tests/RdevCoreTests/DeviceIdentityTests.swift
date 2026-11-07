import XCTest
@testable import RdevCore

/// §10.2's local device keys, against vectors a THIRD implementation produced
/// (`scripts/gen_device_identity_fixture.py`) and which `protocol/test/device-identity.test.ts`
/// asserts too.
///
/// THE POINT IS THE PUBLIC KEYS. Ed25519 has a seed form and an expanded form and X25519 clamps its
/// scalar; two runtimes disagreeing about the public keys a private key implies give the device a
/// different `device_id` in each — which presents as a grant that verifies everywhere except on the
/// device it was issued to.
final class DeviceIdentityTests: XCTestCase {

    private struct Case: Decodable {
        let name: String
        let signing_private_key: String, signing_public_key: String
        let noise_private_key_raw: String, noise_private_key: String, noise_public_key: String
        let rendezvous_seed: String, descriptor: String, device_id: String, record: String
    }
    private struct Fixture: Decodable { let root_id: String; let cases: [Case] }

    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/device-identity.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    private var fx: Fixture { Self.fx }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private var rootID: [UInt8] { hex(fx.root_id) }

    func testMatchesTheCrossImplementationVectors() throws {
        XCTAssertFalse(fx.cases.isEmpty, "an empty fixture would assert nothing")
        for c in fx.cases {
            let keys = try XCTUnwrap(DeviceIdentity.Keys(
                signingPrivateKey: hex(c.signing_private_key),
                noisePrivateKey: hex(c.noise_private_key)), c.name)
            XCTAssertEqual(hex(try XCTUnwrap(keys.signingPublicKey)), c.signing_public_key, c.name)
            XCTAssertEqual(hex(try XCTUnwrap(keys.noisePublicKey)), c.noise_public_key, c.name)
            XCTAssertEqual(hex(try XCTUnwrap(keys.descriptor(rootID: rootID))), c.descriptor, c.name)
            XCTAssertEqual(hex(try XCTUnwrap(keys.deviceID(rootID: rootID))), c.device_id, c.name)

            let installation = try XCTUnwrap(DeviceIdentity.Installation(
                keys: keys, rendezvousSeed: hex(c.rendezvous_seed)))
            XCTAssertEqual(hex(DeviceIdentity.encode(installation)), c.record, c.name)
            let back = try XCTUnwrap(DeviceIdentity.decode(hex(c.record)), c.name)
            XCTAssertEqual(back, installation, c.name)
        }
    }

    /// X25519 clamps its scalar internally, so an unclamped key yields the SAME public key. Clamping
    /// before storing is therefore a decision about the RECORD, not about the cryptography — and a
    /// runtime that skipped it would write a byte-different record that nevertheless works.
    func testClampingChangesTheStoredBytesAndNotThePublicKey() throws {
        for c in fx.cases {
            let raw = hex(c.noise_private_key_raw)
            XCTAssertEqual(hex(DeviceIdentity.clampedX25519(raw)), c.noise_private_key, c.name)
            let unclamped = try XCTUnwrap(DeviceIdentity.Keys(
                signingPrivateKey: hex(c.signing_private_key), noisePrivateKey: raw))
            XCTAssertEqual(hex(try XCTUnwrap(unclamped.noisePublicKey)), c.noise_public_key, c.name)
        }
    }

    // MARK: - both keys are identity

    /// §10.2: "Changing either key creates a new device identity." A build that regenerated one and
    /// kept the other has not rotated anything — it has become a different device holding a grant
    /// that no longer describes it.
    func testEitherKeyChangingIsADifferentDevice() throws {
        let base = fx.cases[2]
        let other = fx.cases[3]
        let id = { (s: String, n: String) -> String in
            let k = DeviceIdentity.Keys(signingPrivateKey: self.hex(s), noisePrivateKey: self.hex(n))!
            return self.hex(k.deviceID(rootID: self.rootID)!)
        }
        XCTAssertEqual(id(base.signing_private_key, base.noise_private_key), base.device_id)
        XCTAssertNotEqual(id(other.signing_private_key, base.noise_private_key), base.device_id)
        XCTAssertNotEqual(id(base.signing_private_key, other.noise_private_key), base.device_id)
    }

    func testADifferentRootIsADifferentDevice() throws {
        // The descriptor names its root, so the same keys under another identity are another device.
        let c = fx.cases[2]
        let keys = try XCTUnwrap(DeviceIdentity.Keys(signingPrivateKey: hex(c.signing_private_key),
                                                     noisePrivateKey: hex(c.noise_private_key)))
        let elsewhere = try XCTUnwrap(keys.deviceID(rootID: Array(repeating: 9, count: 32)))
        XCTAssertNotEqual(hex(elsewhere), c.device_id)
    }

    // MARK: - the stored record

    func testARecordThatIsNotOneIsRefusedNotReadAsKeyMaterial() throws {
        let good = hex(fx.cases[0].record)
        XCTAssertNotNil(DeviceIdentity.decode(good))
        XCTAssertNil(DeviceIdentity.decode(good + [0]))
        XCTAssertNil(DeviceIdentity.decode(Array(good.dropLast())))
        XCTAssertNil(DeviceIdentity.decode(Array(repeating: 0, count: 96)))   // 96 bytes, no label
        XCTAssertNil(DeviceIdentity.decode([]))
        var wrongLabel = good
        wrongLabel[2] = UInt8(ascii: "X")
        XCTAssertNil(DeviceIdentity.decode(wrongLabel))
    }

    func testAWrongWidthKeyIsRefusedRatherThanPadded() {
        XCTAssertNil(DeviceIdentity.Keys(signingPrivateKey: Array(repeating: 0, count: 31),
                                         noisePrivateKey: Array(repeating: 0, count: 32)))
        XCTAssertNil(DeviceIdentity.Keys(signingPrivateKey: Array(repeating: 0, count: 32),
                                         noisePrivateKey: Array(repeating: 0, count: 33)))
        let keys = DeviceIdentity.Keys(signingPrivateKey: Array(repeating: 0, count: 32),
                                       noisePrivateKey: Array(repeating: 0, count: 32))!
        XCTAssertNil(DeviceIdentity.Installation(keys: keys,
                                                 rendezvousSeed: Array(repeating: 0, count: 31)))
    }

    // MARK: - generation

    func testGenerationDrawsThreeIndependentValuesAndClamps() throws {
        var draws: [Int] = []
        var n: UInt8 = 0
        let fake: (Int) -> [UInt8] = { count in
            draws.append(count)
            n += 1
            return Array(repeating: n, count: count)
        }
        let i = try XCTUnwrap(DeviceIdentity.generate(randomBytes: fake))
        XCTAssertEqual(draws, [32, 32, 32])
        // Three DIFFERENT draws, not one seed expanded three ways: these are a signing identity, a
        // DH identity and a public address that must not be linkable by anyone who learns one.
        XCTAssertNotEqual(i.keys.signingPrivateKey, i.keys.noisePrivateKey)
        XCTAssertNotEqual(i.keys.noisePrivateKey, i.rendezvousSeed)
        XCTAssertEqual(i.keys.noisePrivateKey,
                       DeviceIdentity.clampedX25519(Array(repeating: 2, count: 32)))
    }

    func testTwoGenerationsShareNothing() throws {
        let a = try XCTUnwrap(DeviceIdentity.generate())
        let b = try XCTUnwrap(DeviceIdentity.generate())
        XCTAssertNotEqual(a.keys.signingPrivateKey, b.keys.signingPrivateKey)
        XCTAssertNotEqual(a.keys.noisePrivateKey, b.keys.noisePrivateKey)
        XCTAssertNotEqual(a.rendezvousSeed, b.rendezvousSeed)
    }

    func testARoundTripThroughTheRecordPreservesTheIdentityExactly() throws {
        let i = try XCTUnwrap(DeviceIdentity.generate())
        let back = try XCTUnwrap(DeviceIdentity.decode(DeviceIdentity.encode(i)))
        XCTAssertEqual(back, i)
        XCTAssertEqual(back.keys.deviceID(rootID: rootID), i.keys.deviceID(rootID: rootID))
    }

    /// §10.2 keeps the keys and the seed in ONE record because they share a lifetime: regenerating
    /// the keys while keeping the seed would leave a new device answering at the old address, and
    /// §9.2 requires a durable-route conflict to fail visibly rather than have an identity change
    /// quietly behind a stable address.
    func testTheInstallationsRouteIsItsSeedsRoute() throws {
        let i = try XCTUnwrap(DeviceIdentity.generate())
        XCTAssertEqual(i.route, RendezvousSeed.derive(seed: i.rendezvousSeed))
        XCTAssertNotNil(i.route)
    }
}
