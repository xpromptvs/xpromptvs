import RdevCore
import XCTest
@testable import RdevHostKit

/// §9.1's inversion, host-side: the Issuer generates and the Worker registers.
///
/// The TypeScript mirror is `protocol/test/pairing-seed.test.ts`'s `openPairingWindow` block, and
/// the properties asserted are deliberately the same ones — three front ends open pairing windows,
/// and three answers to "what does the Worker learn" is three chances to get it wrong.
final class PairingWindowOpenerTests: XCTestCase {

    private func seed(_ fill: UInt8) -> [UInt8] { [UInt8](repeating: fill, count: PairingSeed.seedByteCount) }

    /// Records every body posted, so a test can assert on the BYTES that left rather than on intent.
    private actor Wire {
        private(set) var bodies: [String] = []
        private let answers: [Int]
        private var at = 0
        init(answers: [Int]) { self.answers = answers }
        func send(_ body: Data) -> (status: Int, body: Data) {
            bodies.append(String(decoding: body, as: UTF8.self))
            let status = at < answers.count ? answers[at] : answers.last ?? 200
            at += 1
            return (status, Data("{}".utf8))
        }
    }

    private func open(seeds: [UInt8], answers: [Int] = [200])
        async -> (Result<PairingWindowOpener.Opened, PairingWindowOpener.Failure>, Wire) {
        let wire = Wire(answers: answers)
        var next = 0
        let result = await PairingWindowOpener.open(
            signalingBase: "https://cp.test",
            random: { _ in
                let s = self.seed(seeds[min(next, seeds.count - 1)])
                next += 1
                return s
            },
            transport: { _, body in await wire.send(body) })
        return (result, wire)
    }

    func testUpdateRestartReusesTheExistingRendezvousWithoutSendingItsSeed() async throws {
        let original=seed(7),carrier=PairingSeed.encode(seed:original)!,wire=Wire(answers:[200])
        let result=await PairingWindowOpener.open(signalingBase:"https://cp.test",restoringCarrier:carrier,random:{_ in XCTFail("must not generate a new room");return []},transport:{_,body in await wire.send(body)})
        let opened=try result.get(),expected=PairingSeed.derive(seed:original)!
        XCTAssertEqual(opened.material.code,expected.code);XCTAssertEqual(opened.material.token,expected.token)
        let bodies=await wire.bodies
        XCTAssertFalse(bodies[0].contains(carrier));XCTAssertEqual(Set((try JSONSerialization.jsonObject(with:Data(bodies[0].utf8)) as! [String:Any]).keys),["code","token"])
    }
    // **THE SEED AND THE PSK NEVER LEAVE**, asserted on what was actually sent. A Control Plane
    // holding the seed can derive `psk` and complete a `pair` handshake with keys of its own.
    func testOnlyTheTwoPublicValuesAreRegistered() async throws {
        let (result, wire) = await open(seeds: [7])
        let opened = try result.get()
        let bodies = await wire.bodies
        XCTAssertEqual(bodies.count, 1)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(bodies[0].utf8))
                                 as? [String: String])
        XCTAssertEqual(Set(json.keys), ["code", "token"])
        XCTAssertEqual(json["code"], opened.material.code)
        XCTAssertEqual(json["token"], opened.material.token)

        XCTAssertFalse(bodies[0].contains(opened.carrier))
        XCTAssertFalse(bodies[0].contains(String(opened.carrier.dropFirst(4))))
        XCTAssertFalse(bodies[0].contains(base64urlEncode(Data(opened.material.psk))))
    }

    func testTheCarrierIsTheSeedAndDerivesTheSameMaterialBack() async throws {
        let (result, _) = await open(seeds: [3])
        let opened = try result.get()
        let decoded = try XCTUnwrap(PairingSeed.decode(opened.carrier))
        XCTAssertEqual(decoded, seed(3))
        let again = try XCTUnwrap(PairingSeed.derive(seed: decoded))
        XCTAssertEqual(again, opened.material)
    }

    // §9.2: "retried with fresh material, at most four times." FRESH — retrying the same seed would
    // ask for the same seized code forever.
    func testAConflictIsRetriedWithANewSeedFourTimesAtMost() async {
        let (result, wire) = await open(seeds: [1, 2, 3, 4, 5], answers: [409])
        XCTAssertEqual(result.failure, .conflict)
        let bodies = await wire.bodies
        XCTAssertEqual(bodies.count, PairingWindowOpener.conflictAttempts)
        XCTAssertEqual(Set(bodies).count, PairingWindowOpener.conflictAttempts)
    }

    func testAConflictThatClearsSucceeds() async {
        let (result, wire) = await open(seeds: [1, 2, 3], answers: [409, 409, 200])
        XCTAssertNil(result.failure)
        let bodies = await wire.bodies
        XCTAssertEqual(bodies.count, 3)
    }

    // A refusal is not a conflict: fresh material against a Worker that says 400 burns the budget on
    // an answer that will not change.
    func testARefusalStopsImmediately() async {
        let (result, wire) = await open(seeds: [1, 2, 3, 4], answers: [400])
        XCTAssertEqual(result.failure, .refused)
        let bodies = await wire.bodies
        XCTAssertEqual(bodies.count, 1)
    }

    func testAnUnreachableControlPlaneIsItsOwnAnswer() async {
        let result = await PairingWindowOpener.open(
            signalingBase: "https://cp.test",
            random: { _ in self.seed(1) },
            transport: { _, _ in nil })
        XCTAssertEqual(result.failure, .unreachable)
    }

    // **MEASURED, and it is why this test says "" rather than something that merely looks wrong.**
    // `URL(string: "not a url at all")` SUCCEEDS on Apple's Foundation — it percent-encodes the
    // spaces — so a test written against that string asserts nothing and fails for the wrong reason.
    func testAnUnusableBaseIsRefusedBeforeAnythingIsGenerated() async {
        let result = await PairingWindowOpener.open(
            signalingBase: "",
            random: { _ in XCTFail("a seed was generated for an address that cannot be built"); return [] },
            transport: { _, _ in XCTFail("a request was made"); return nil })
        XCTAssertEqual(result.failure, .malformed)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e }; return nil }
}
