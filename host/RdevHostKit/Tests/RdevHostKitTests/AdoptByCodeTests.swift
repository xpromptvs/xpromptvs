import RdevCore
import RdevE2E
import XCTest
@testable import RdevHostKit

/// **Adopt by code, with only the socket faked.**
///
/// The handshake under test is the production one: a real `E2EClientGate` in `pair` — the Mac —
/// against a real `E2ESignallingGate` — the Issuer — with a `Shuttle` carrying envelopes between
/// them instead of a WebSocket. A stub that replayed recorded bytes would agree with whatever
/// mistake produced the recording.
///
/// **The Swift responder mints capability 1**, because that is what a Mac issues to a guest. In the
/// product the Issuer here is a BROWSER minting capability 2 with a passkey, which
/// `protocol/test/e2e-host-gate.test.ts` drives and `e2e/adopt-by-code-check.mjs` drives for real.
/// What this file is about is the Mac's half: it initiates, it commits what it is given after the
/// manager has verified it, and it commits NOTHING otherwise.
final class AdoptByCodeTests: XCTestCase {

    // MARK: - the fixture, and a device that is not this one

    private struct Device: Decodable {
        let signing_private_key: String, noise_private_key: String
        let descriptor: String, device_id: String, bundle: String
    }
    private struct Route: Decodable { let rcode: String, rtoken: String }
    private struct Fixture: Decodable {
        let rp_id: String, allowed_origins: [String], root_id: String
        let devices: [String: Device]
        let routes: [String: Route]
    }
    private static let fx: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-session.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    private var fx: Fixture { Self.fx }
    private func dev(_ n: String) -> Device { fx.devices[n]! }
    private var policy: E2EVerify.Policy { .init(rpID: fx.rp_id, allowedOrigins: fx.allowed_origins) }

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }

    private static func b64u(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func fromB64u(_ s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { [UInt8]($0) }
    }

    // MARK: - the world

    private let room = "room-1"

    /// §9.1's material, with the ROOM CODE the responder was built for. The psk's value is
    /// irrelevant; that both ends hold the same one is the whole of what it buys.
    private func material(psk: [UInt8] = [UInt8](repeating: 0x5a, count: 32)) -> PairingMaterial {
        PairingMaterial(code: room, token: "token-1", psk: psk)
    }

    private func opened(_ m: PairingMaterial) -> PairingWindowOpener.Opened {
        .init(seed: [UInt8](repeating: 0x11, count: 16), carrier: "AAAAAAAAAAAAAAAAAAAAAA",
              material: m, sessionURL: "http://127.0.0.1:8787/session/\(m.code)")
    }

    private func responder(psk: [UInt8]) -> E2ESignallingGate {
        let route = fx.routes["H"]!
        return E2ESignallingGate(config: .init(
            device: hex(dev("H").descriptor), bundle: hex(dev("H").bundle),
            noisePrivateKey: hex(dev("H").noise_private_key),
            route: RendezvousRoute(rcode: route.rcode, rtoken: route.rtoken),
            trustedRootID: hex(fx.root_id), policy: policy,
            publicationStatus: .confirmed, pairingPSK: psk,
            signingPrivateKey: hex(dev("H").signing_private_key)), roomCode: room)
    }

    /// Carries envelopes between the Mac's gate and a real responder. Not a recording: the responder
    /// answers each message as it arrives, so the bytes are the ones a real session would carry.
    private final class Shuttle: AdoptByCode.Transport, @unchecked Sendable {
        let gate: E2ESignallingGate
        let continuation: AsyncStream<AdoptByCode.Event>.Continuation

        init(gate: E2ESignallingGate, continuation: AsyncStream<AdoptByCode.Event>.Continuation) {
            self.gate = gate
            self.continuation = continuation
        }

        func send(ct: String, peer: String, mode: E2EWire.Mode?) {
            guard let bytes = AdoptByCodeTests.fromB64u(ct) else { return }
            switch gate.receive(bytes, mode: mode) {
            case .success(.reply(let out)):
                continuation.yield(.e2e(ct: AdoptByCodeTests.b64u(out), peer: nil))
            case .success:
                break
            case .failure:
                // A responder that refuses says so by going away, which is what a relay would show.
                continuation.yield(.closed)
            }
        }

        func close() { continuation.finish() }
    }

    private func stores() -> (InstallationStore.Backend, InstallationStore.Backend) {
        (InstallationStore.Memory(), InstallationStore.Memory())
    }

    /// An `AdoptByCode` wired to a real responder over a `Shuttle`.
    private func subject(manager: E2EIdentityManager,
                         issuerPSK: [UInt8],
                         macPSK: [UInt8],
                         peerJoins: Bool = true,
                         windowSeconds: Double = 120) -> AdoptByCode {
        let gate = responder(psk: issuerPSK)
        let m = material(psk: macPSK)
        return AdoptByCode(
            manager: manager, policy: policy,
            openWindow: { _ in .success(self.opened(m)) },
            connect: { _, _ in
                let (stream, continuation) = AsyncStream<AdoptByCode.Event>.makeStream()
                if peerJoins { continuation.yield(.peerJoined("browser-1")) }
                return (Shuttle(gate: gate, continuation: continuation), stream)
            },
            windowSeconds: windowSeconds)
    }

    // MARK: - the three that matter

    /// The whole path: the Mac speaks first, the Issuer answers, and the chain that comes back is
    /// committed. **The commit is what makes this real** — the socket closing changes nothing after.
    func testAnIssuedChainIsCommitted() async throws {
        let (keys, trust) = stores()
        let manager = E2EIdentityManager(installations: keys, trust: trust)
        let psk = [UInt8](repeating: 0x5a, count: 32)

        let phase = await subject(manager: manager, issuerPSK: psk, macPSK: psk)
            .start(signalingBase: "http://127.0.0.1:8787")

        guard case .enrolled(let deviceID) = phase else {
            return XCTFail("expected enrolled, got \(phase)")
        }
        let loaded = try manager.load().get()
        let bundle = try XCTUnwrap(loaded.record.bundle, "a committed chain is a stored one")
        XCTAssertEqual(deviceID, E2EIdentity.deviceID(try XCTUnwrap(loaded.deviceDescriptor)))
        XCTAssertEqual(loaded.trustedRootID, hex(fx.root_id), "the root it learned is the Issuer's")

        // The chain verifies under that root and certifies THIS device — the two things the manager
        // refuses to commit without, asserted here so a change to it cannot pass silently.
        let verified = try XCTUnwrap(try? E2EVerify.verifyBundle(
            bundle, trustedRootID: hex(fx.root_id), policy: policy).get())
        XCTAssertEqual(verified.leafDevice.bytes, loaded.deviceDescriptor)
    }

    /// **A psk disagreement commits nothing.** XXpsk3 mixes the secret in at message 3, so a scanner
    /// who did not read this Mac's screen cannot finish the handshake — which is the entire
    /// assurance this path rests on.
    func testAPskDisagreementEnrollsNothing() async throws {
        let (keys, trust) = stores()
        let manager = E2EIdentityManager(installations: keys, trust: trust)

        let phase = await subject(manager: manager,
                                  issuerPSK: [UInt8](repeating: 0x5a, count: 32),
                                  macPSK: [UInt8](repeating: 0x5b, count: 32))
            .start(signalingBase: "http://127.0.0.1:8787")

        guard case .failed(let reason) = phase else {
            return XCTFail("expected a refusal, got \(phase)")
        }
        // Named, so this cannot pass because something unrelated went wrong first.
        XCTAssertTrue(reason.hasPrefix("gate/") || reason == "disconnected", reason)
        XCTAssertNil(try manager.load().get().record.bundle, "nothing may be committed")
        XCTAssertNil(try manager.load().get().record.root, "and no root may be adopted")
    }

    /// §9.1's window is bounded. A QR nobody scans expires, and a secret left readable forever is
    /// what that sentence exists to prevent.
    func testAnUnscannedWindowExpires() async throws {
        let (keys, trust) = stores()
        let manager = E2EIdentityManager(installations: keys, trust: trust)
        let psk = [UInt8](repeating: 0x5a, count: 32)

        let phase = await subject(manager: manager, issuerPSK: psk, macPSK: psk,
                                  peerJoins: false, windowSeconds: 0.05)
            .start(signalingBase: "http://127.0.0.1:8787")

        guard case .failed = phase else { return XCTFail("expected expiry, got \(phase)") }
        XCTAssertNil(try manager.load().get().record.bundle)
    }

    /// **An enrolled Mac is not adopted a second time.** §10.1 forbids an incoming chain replacing a
    /// trusted root, and upgrading is §12.1's ceremony rather than this one.
    func testAnEnrolledMacRefusesToBeAdopted() async throws {
        let (keys, trust) = stores()
        let manager = E2EIdentityManager(installations: keys, trust: trust)
        let psk = [UInt8](repeating: 0x5a, count: 32)
        _ = await subject(manager: manager, issuerPSK: psk, macPSK: psk)
            .start(signalingBase: "http://127.0.0.1:8787")
        let first = try XCTUnwrap(try manager.load().get().record.bundle)

        let again = await subject(manager: manager, issuerPSK: psk, macPSK: psk)
            .start(signalingBase: "http://127.0.0.1:8787")

        guard case .failed(let reason) = again else { return XCTFail("expected a refusal, got \(again)") }
        XCTAssertEqual(reason, "already-enrolled")
        XCTAssertEqual(try manager.load().get().record.bundle, first, "the old chain is untouched")
    }
}
