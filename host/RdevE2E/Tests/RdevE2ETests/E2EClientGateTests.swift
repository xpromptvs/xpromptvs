import RdevCore
import RdevNoise
import XCTest
import RdevE2E

/// **The two production gates, driven against each other.**
///
/// `E2ESignallingGateTests` drives the responder with a hand-rolled client, and
/// `E2ESignallingTests` proves the two halves of §11 agree underneath. This is the one that says
/// the two objects a real session is made of can actually talk: `E2EClientGate` (RdevViewer's, and
/// the mirror of `protocol/src/e2e-signalling-gate.ts`) against `E2ESignallingGate` (the host's),
/// over real Noise, with no hand-written step in between.
///
/// A wiring defect that both hand-rolled harnesses reproduce identically is invisible to both of
/// them. This is what sees it.
final class E2EClientGateTests: XCTestCase {

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

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map {
            let i = s.index(s.startIndex, offsetBy: $0)
            return UInt8(s[i ... s.index(after: i)], radix: 16)!
        }
    }
    private func dev(_ n: String) -> Device { fx.devices[n]! }
    private var policy: E2EVerify.Policy { .init(rpID: fx.rp_id, allowedOrigins: fx.allowed_origins) }
    private let room = "room-1"

    private func hostGate(_ name: String = "H", room roomCode: String? = nil,
                          pairingPSK: [UInt8]? = nil) -> E2ESignallingGate {
        let route = fx.routes[name] ?? fx.routes["H"]!
        return E2ESignallingGate(config: .init(
            device: hex(dev(name).descriptor), bundle: hex(dev(name).bundle),
            noisePrivateKey: hex(dev(name).noise_private_key),
            route: RendezvousRoute(rcode: route.rcode, rtoken: route.rtoken),
            trustedRootID: hex(fx.root_id), policy: policy,
            publicationStatus: .confirmed, pairingPSK: pairingPSK,
            signingPrivateKey: hex(dev(name).signing_private_key)), roomCode: roomCode ?? room)
    }

    private func client(_ name: String = "C", room roomCode: String? = nil,
                        trustedRoot: [UInt8]? = nil,
                        expecting responderDeviceID: [UInt8]? = nil, appHello: [UInt8] = []) -> E2EClientGate {
        E2EClientGate(config: .init(
            device: hex(dev(name).descriptor), bundle: hex(dev(name).bundle),
            signingPrivateKey: hex(dev(name).signing_private_key),
            noisePrivateKey: hex(dev(name).noise_private_key),
            trustedRootID: trustedRoot ?? hex(fx.root_id), policy: policy,
            expectedResponderDeviceID: responderDeviceID, appHello: appHello), roomCode: roomCode ?? room)
    }

    /// Run the handshake to completion, returning both gates open. Every envelope goes through the
    /// OTHER gate's public surface — there is no step here that production does not take.
    @discardableResult
    private func connect(_ c: E2EClientGate, _ h: E2ESignallingGate,
                         mode: E2EWire.Mode = .auth) throws -> (Int, Int) {
        var clientSent = 0, hostSent = 0

        let opening = try XCTUnwrap(try? c.start().get())
        clientSent += 1
        // §11.3: the mode travels with the FIRST envelope and nothing else.
        XCTAssertEqual(opening.mode, mode)

        guard case .reply(let message2) = try h.receive(opening.ciphertext, mode: opening.mode).get()
        else { throw Unexpected("the host did not answer message 1") }
        hostSent += 1

        guard case .reply(let fromClient) = try c.receive(message2).get()
        else { throw Unexpected("the client did not answer message 2") }
        // **TWO envelopes.** Message 3 and `client-confirm` are separate Noise messages, and Noise
        // framing carries no length — concatenating them hands the host one message with the
        // other's bytes as its payload.
        XCTAssertEqual(fromClient.count, 2)

        guard case .nothing = try h.receive(fromClient[0], mode: nil).get()
        else { throw Unexpected("message 3 produced a reply") }
        clientSent += 1

        guard case .reply(let start) = try h.receive(fromClient[1], mode: nil).get()
        else { throw Unexpected("client-confirm produced no session-start") }
        clientSent += 1
        hostSent += 1

        guard case .nothing = try c.receive(start).get()
        else { throw Unexpected("session-start produced a reply") }
        return (clientSent, hostSent)
    }

    // MARK: - the happy path

    func testTheTwoGatesCompleteASessionAgainstEachOther() throws {
        let c = client(), h = hostGate()
        XCTAssertFalse(c.maySignal)
        XCTAssertFalse(h.maySignal)
        try connect(c, h)
        // §11.2's sentence, on both sides. Neither end signals until it is true.
        XCTAssertTrue(c.maySignal)
        XCTAssertTrue(h.maySignal)
    }

    /// `client-confirm`'s app_hello (docs/sources-and-focus.md, "The offer carries the tab bar"): the host's gate
    /// hands it over once open — and one over the cap goes EMPTY rather than costing the handshake.
    func testTheClientsAppHelloReachesTheHostOnceTheGateIsOpen() throws {
        let said = Array(#"{"grid":{"cols":120,"rows":40}}"#.utf8)
        let c = client(appHello: said), h = hostGate()
        XCTAssertEqual(h.appHello, [], "nothing before the gate")
        try connect(c, h)
        XCTAssertEqual(h.appHello, said)
        let c2 = client(appHello: [UInt8](repeating: 0, count: E2EWire.appHelloMax + 1)), h2 = hostGate()
        try connect(c2, h2)
        XCTAssertTrue(h2.maySignal)
        XCTAssertEqual(h2.appHello, [], "over the cap: sent empty")
    }

    func testEachEndAuthenticatesTHEOTHERSDevice() throws {
        let c = client(), h = hostGate()
        try connect(c, h)
        XCTAssertEqual(c.peerChain?.leafDevice.id, hex(dev("H").device_id))
        XCTAssertEqual(h.peerChain?.leafDevice.id, hex(dev("C").device_id))
    }

    func testSignallingTRAVELSBothWaysOnceTheGateIsOpen() throws {
        let c = client(), h = hostGate()
        try connect(c, h)

        // §11.3: "the same signalling JSON the plaintext envelopes carried" — so an offer and an
        // answer are what a session is for, and they are what this sends.
        let offer = Data(#"{"t":"offer","sdp":"v=0\r\n"}"#.utf8)
        guard case .signalling(let atClient) = try c.receive(try h.seal(offer).get()).get()
        else { return XCTFail("the client did not receive the host's offer") }
        XCTAssertEqual(atClient, offer)

        let answer = Data(#"{"t":"answer","sdp":"v=0\r\n"}"#.utf8)
        guard case .signalling(let atHost) = try h.receive(try c.seal(answer).get(), mode: nil).get()
        else { return XCTFail("the host did not receive the client's answer") }
        XCTAssertEqual(atHost, answer)
    }

    func testTheHANDSHAKEIsFiveEnvelopesAndNoMore() throws {
        // §17.3: "`client-confirm` and `session-start` must suffice to finish authorization without
        // a deadlock" — so a count is a real assertion here, not decoration. Three from the client
        // (m1, m3, confirm) and two from the host (m2, start).
        let (fromClient, fromHost) = try connect(client(), hostGate())
        XCTAssertEqual(fromClient, 3)
        XCTAssertEqual(fromHost, 2)
    }

    // MARK: - pairing, gate against gate

    /// **The whole pairing story, both production objects, no hand-written step.** A newcomer with
    /// no identity at all scans a code, and walks away with a chain — and nobody is asked anything,
    /// because possession of the psk is the authorisation §9.1 bought.
    func testAPairSessionGivesTheNewcomerAChainAndNobodyIsAsked() throws {
        let psk = [UInt8](repeating: 0x5C, count: 32)
        // **NO DESCRIPTOR, and that is the whole point of this test.** §10.2's descriptor names its
        // root and a newcomer does not know that root until message 2, so it arrives with KEYS and
        // names itself afterwards — §12.3: "persist trusted root … ── message 3: own descriptor".
        // Handing it `dev("N").descriptor` here, as an earlier version did, hid the ordering
        // completely: the fixture's newcomer already names the fixture's root, which no real
        // browser can.
        let c = E2EClientGate(config: .init(
            device: [], bundle: [],
            signingPrivateKey: hex(dev("N").signing_private_key),
            noisePrivateKey: hex(dev("N").noise_private_key),
            // NO TRUSTED ROOT. §11.1 allows the bootstrap only here, and only because the psk
            // authenticated the chain the root arrives in.
            trustedRootID: nil, policy: policy, mode: .pair, pairingPSK: psk), roomCode: room)
        let h = hostGate(pairingPSK: psk)

        try connect(c, h, mode: .pair)
        XCTAssertTrue(c.maySignal)
        XCTAssertTrue(h.maySignal)

        let accepted = try XCTUnwrap(c.acceptedBundle, "a paired device leaves with a chain")
        let chain = try E2EVerify.verifyBundle(accepted, trustedRootID: hex(fx.root_id),
                                               policy: policy).get()
        // The chain certifies the KEYS it arrived with, under the root it learned in message 2 —
        // which is the same descriptor the fixture happens to hold for N, arrived at the long way.
        XCTAssertEqual(chain.leafDevice.bytes, hex(dev("N").descriptor))
        XCTAssertEqual(chain.capabilities.raw, 1, "a paired device is a CLIENT")
    }

    /// The other half of the same sentence: no psk, no session. Not a refusal a person could
    /// override — the handshake cannot complete.
    func testAPairWithTheWrongPSKNeverOpens() throws {
        var theirs = [UInt8](repeating: 0x5C, count: 32)
        let h = hostGate(pairingPSK: theirs)
        theirs[0] ^= 0x80
        let c = E2EClientGate(config: .init(
            device: [], bundle: [],
            signingPrivateKey: hex(dev("N").signing_private_key),
            noisePrivateKey: hex(dev("N").noise_private_key),
            trustedRootID: nil, policy: policy, mode: .pair, pairingPSK: theirs), roomCode: room)

        XCTAssertThrowsError(try connect(c, h, mode: .pair))
        XCTAssertFalse(c.maySignal)
        XCTAssertFalse(h.maySignal)
        XCTAssertNil(c.acceptedBundle)
    }

    /// A `pair` configured without its key is refused BEFORE a byte is written, because the only
    /// other outcome is an unexplained Noise failure two messages later.
    func testAPairWithNoKeyAtAllIsRefusedAtStart() {
        let c = E2EClientGate(config: .init(
            device: [], bundle: [],
            signingPrivateKey: hex(dev("N").signing_private_key),
            noisePrivateKey: hex(dev("N").noise_private_key),
            trustedRootID: nil, policy: policy, mode: .pair, pairingPSK: nil), roomCode: room)
        XCTAssertEqual(c.start().failure, .notEstablished)
    }

    /// `enroll`: the newcomer already holds a root-signed chain and presents it. A root signature is
    /// the authorisation, so again nobody is asked.
    func testAnEnrollSessionHasItsChainAccepted() throws {
        let c = E2EClientGate(config: .init(
            device: hex(dev("C").descriptor), bundle: [],
            signingPrivateKey: hex(dev("C").signing_private_key),
            noisePrivateKey: hex(dev("C").noise_private_key),
            trustedRootID: hex(fx.root_id), policy: policy, mode: .enroll,
            newBundle: hex(dev("C").bundle)), roomCode: room)
        let h = hostGate()

        try connect(c, h, mode: .enroll)
        XCTAssertTrue(c.maySignal)
        XCTAssertEqual(c.acceptedBundle, hex(dev("C").bundle))
    }

    // MARK: - §11.2, the gate itself

    func testNothingMayBeSEALEDBeforeTheGateOpens() {
        let c = client()
        XCTAssertEqual(c.seal(Data("{}".utf8)).failure, .notEstablished)
        _ = c.start()
        // Started is not opened: the handshake is in flight and the peer is still a stranger.
        XCTAssertEqual(c.seal(Data("{}".utf8)).failure, .notEstablished)
    }

    func testStartingTwiceIsRefused() {
        let c = client()
        _ = c.start()
        XCTAssertEqual(c.start().failure, .notEstablished)
    }

    func testAClosedGateSignalsNothingMore() throws {
        let c = client(), h = hostGate()
        try connect(c, h)
        c.close()
        XCTAssertFalse(c.maySignal)
        XCTAssertEqual(c.seal(Data("{}".utf8)).failure, .notEstablished)
    }

    // MARK: - refusals

    func testADIFFERENTROOMFailsTheHandshake() throws {
        // The room is bound into the prologue, so the two sides derive different keys and message 2
        // does not decrypt. §11.3's answer to that is termination, not a retry.
        let c = client(), h = hostGate(room: "room-2")
        let opening = try XCTUnwrap(try? c.start().get())
        guard case .reply(let message2) = try h.receive(opening.ciphertext, mode: opening.mode).get()
        else { return XCTFail("the host refused message 1") }
        XCTAssertEqual(c.receive(message2).failure, .noise)
        // And it stays refused: a gate that answered again after refusing once is the oracle §11.3
        // exists to prevent.
        XCTAssertEqual(c.receive(message2).failure, .notEstablished)
    }

    func testAHOSTUNDERANOTHERROOTIsRefusedByTheCLIENT() throws {
        // The chain verifies on its own terms and not against ours. §10.1: an incoming chain may
        // never replace the root this device already trusts.
        let c = client(trustedRoot: [UInt8](repeating: 0x11, count: 32))
        let h = hostGate()
        let opening = try XCTUnwrap(try? c.start().get())
        guard case .reply(let message2) = try h.receive(opening.ciphertext, mode: opening.mode).get()
        else { return XCTFail("the host refused message 1") }
        XCTAssertEqual(c.receive(message2).failure, .session(.peerChain))
        XCTAssertFalse(c.maySignal)
    }

    func testTHEWRONGHOSTIsRefusedWhenOneWasSELECTED() throws {
        // §11.1: "A selected Host's `device_id` must also match the selection." The chain is
        // perfectly good; it is simply not the device this client chose.
        let c = client(expecting: hex(dev("X").device_id))
        let h = hostGate()
        let opening = try XCTUnwrap(try? c.start().get())
        guard case .reply(let message2) = try h.receive(opening.ciphertext, mode: opening.mode).get()
        else { return XCTFail("the host refused message 1") }
        XCTAssertEqual(c.receive(message2).failure, .session(.responderNotSelected))
    }

    func testAMODIFIEDENVELOPEDoesNotDecryptAndTheSessionDies() throws {
        let c = client(), h = hostGate()
        try connect(c, h)
        var sealed = try h.seal(Data(#"{"t":"offer"}"#.utf8)).get()
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertEqual(c.receive(sealed).failure, .noise)
        XCTAssertEqual(c.receive(sealed).failure, .notEstablished)
    }

    func testAREPLAYEDENVELOPEDoesNotDecryptTwice() throws {
        // Per-direction nonces: the second read is at the next counter, and the same ciphertext
        // cannot be authentic there.
        let c = client(), h = hostGate()
        try connect(c, h)
        let sealed = try h.seal(Data(#"{"t":"offer"}"#.utf8)).get()
        guard case .signalling = try c.receive(sealed).get() else { return XCTFail("not delivered") }
        XCTAssertEqual(c.receive(sealed).failure, .noise)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e }; return nil }
}

/// A step of the handshake produced the wrong SHAPE. Thrown rather than `XCTFail`-and-continue so a
/// broken connect stops at the step that broke rather than cascading through the ones after it.
private struct Unexpected: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
