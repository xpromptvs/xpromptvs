import CryptoKit
import XCTest
@testable import RdevCore
@testable import RdevHostKit

/// **The Mac's own passkey ceremony, end to end without a person** (`E2EHostIdentity.signIn`,
/// `createPasskey`, `authorise`, through `E2EIdentityService`): a SOFTWARE passkey that signs real ES256
/// assertions with a P-256 key it holds, and a scripted Worker. What no test here can see is the
/// platform's own prompt and the bytes a real authenticator emits — that is a person's run with Touch ID
/// (`docs/e2e.md`, "The Mac's own passkey ceremony").
final class E2EPasskeyCeremonyTests: XCTestCase {

    static let rpID = "rp.example"
    static let origin = "https://rp.example"

    /// A passkey in software: one credential, signing whatever challenge it is handed, as a platform
    /// authenticator would after the person touched it. It can be told to refuse, and held open.
    final class SoftwarePasskey: PasskeyAuthenticator, @unchecked Sendable {
        let key = P256.Signing.PrivateKey()
        let credentialID: [UInt8] = Array(repeating: 0xC1, count: 20)
        private let lock = NSLock()
        private var _blob: [UInt8]?
        private var _asked: [(allowed: [[UInt8]], largeBlob: PasskeyLargeBlob?)] = []
        private var _registered = 0
        var refuse: PasskeyFailure?
        var hold: AsyncStream<Void>?

        var blob: [UInt8]? { get { lock.lock(); defer { lock.unlock() }; return _blob }
                             set { lock.lock(); _blob = newValue; lock.unlock() } }
        var asked: [(allowed: [[UInt8]], largeBlob: PasskeyLargeBlob?)] {
            lock.lock(); defer { lock.unlock() }; return _asked
        }
        var registered: Int { lock.lock(); defer { lock.unlock() }; return _registered }

        var root: [UInt8] {
            E2EIdentity.root(rpID: E2EPasskeyCeremonyTests.rpID, credentialID: credentialID,
                             rootPublicKey: Array(key.publicKey.x963Representation))!
        }
        var rootID: [UInt8] { E2EIdentity.rootID(root) }

        func assert(rpID: String, challenge: [UInt8], allowedCredentials: [[UInt8]],
                    largeBlob: PasskeyLargeBlob?) async -> Result<E2EPasskeyGrant.Answer, PasskeyFailure> {
            lock.lock(); _asked.append((allowedCredentials, largeBlob)); lock.unlock()
            if let hold { var it = hold.makeAsyncIterator(); _ = await it.next() }
            if let refuse { return .failure(refuse) }
            if !allowedCredentials.isEmpty && !allowedCredentials.contains(credentialID) {
                return .failure(.refused("NotAllowedError"))
            }
            let challengeB64 = base64urlEncode(Data(challenge))
            let clientData = Array(#"{"type":"webauthn.get","challenge":"\#(challengeB64)","origin":"\#(E2EPasskeyCeremonyTests.origin)","crossOrigin":false}"#.utf8)
            let authData = Array(SHA256.hash(data: Data(rpID.utf8))) + [0x05, 0, 0, 0, 0]
            let signed = Data(authData + Array(SHA256.hash(data: Data(clientData))))
            let signature = Array(try! key.signature(for: signed).derRepresentation)
            var read: [UInt8]?
            switch largeBlob {
            case .read?: read = blob
            case .write(let bytes)?: blob = bytes
            case nil: break
            }
            return .success(.init(credentialID: credentialID, clientDataJSON: clientData,
                                  authenticatorData: authData, signature: signature, largeBlob: read))
        }

        func register(rpID: String, challenge: [UInt8], userID: [UInt8],
                      userName: String) async -> Result<[UInt8], PasskeyFailure> {
            lock.lock(); _registered += 1; lock.unlock()
            if let refuse { return .failure(refuse) }
            let x963 = Array(key.publicKey.x963Representation)
            // COSE_Key {1: 2, 3: -7, -1: 1, -2: x, -3: y}
            let cose: [UInt8] = [0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]
                + Array(x963[1 ..< 33]) + [0x22, 0x58, 0x20] + Array(x963[33 ..< 65])
            let authData = Array(SHA256.hash(data: Data(rpID.utf8))) + [0x45, 0, 0, 0, 0]
                + Array(repeating: 0, count: 16) + [0, UInt8(credentialID.count)] + credentialID + cose
            // {"fmt": "none", "attStmt": {}, "authData": bytes}
            let attestation: [UInt8] = [0xA3, 0x63] + Array("fmt".utf8) + [0x64] + Array("none".utf8)
                + [0x67] + Array("attStmt".utf8) + [0xA0] + [0x68] + Array("authData".utf8)
                + [0x59, UInt8(authData.count >> 8), UInt8(authData.count & 0xFF)] + authData
            return .success(attestation)
        }
    }

    /// The Worker: the credential index, and §12.2's registration after a ceremony.
    final class Worker: E2EDirectoryClient.Transport, @unchecked Sendable {
        enum Index { case root([UInt8]), absent, down }
        private let lock = NSLock()
        private var _index: Index = .absent
        private var _paths: [String] = []
        var index: Index { get { lock.lock(); defer { lock.unlock() }; return _index }
                           set { lock.lock(); _index = newValue; lock.unlock() } }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
        func asked(_ last: String) -> Int { paths.filter { $0.hasSuffix(last) }.count }

        func send(_ request: URLRequest) async -> (Data, Int)? {
            let path = request.url!.path
            lock.lock(); _paths.append(path); let index = _index; lock.unlock()
            if path.hasPrefix("/credential/") {
                switch index {
                case .root(let r): return (Data(#"{"root":"\#(base64urlEncode(Data(r)))"}"#.utf8), 200)
                case .absent: return (Data(#"{"error":"not-found"}"#.utf8), 404)
                case .down: return nil
                }
            }
            if path.hasSuffix("/challenge") {
                return (Data(#"{"challenge":"\#(String(repeating: "A", count: 43))"}"#.utf8), 200)
            }
            return (Data(#"{"status":"registered"}"#.utf8), 200)
        }
    }

    struct World {
        let service: E2EIdentityService
        let identity: E2EHostIdentity
        let passkey: SoftwarePasskey
        let worker: Worker
        let pending: MemoryRecord
    }

    private func world() throws -> World {
        guard case .success(let origin) = E2EOrigin.resolve(Self.origin) else { throw Malformed() }
        let pending = MemoryRecord()
        let identity = E2EHostIdentity(
            origin: origin,
            manager: E2EIdentityManager(installations: InstallationStore.Memory(),
                                        trust: InstallationStore.Memory()),
            pendingRoot: pending)
        let worker = Worker()
        return World(service: E2EIdentityService(e2e: .success(identity), directory: worker),
                     identity: identity, passkey: SoftwarePasskey(), worker: worker, pending: pending)
    }

    private struct Malformed: Error {}

    private func leafCapabilities(_ w: World) -> UInt8? { w.identity.leafCapabilities()?.raw }

    // MARK: - signing in

    /// The whole point: ONE prompt, the identity the person picked, found through the Worker's index —
    /// adopted, committed at capabilities 7, then published (§12.2), which is what lets another device
    /// discover it.
    func testSigningInAdoptsTheIdentityTheAuthenticatorOffered() async throws {
        let w = try world()
        w.worker.index = .root(w.passkey.root)
        XCTAssertEqual(w.service.status(), .unenrolled)

        let result = await w.service.signIn(authenticator: w.passkey)
        guard case .success(let acceptance) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(acceptance, .adoptedNewRoot(rootID: w.passkey.rootID))
        XCTAssertEqual(w.passkey.asked.count, 1, "one prompt")
        XCTAssertEqual(w.passkey.asked.first?.allowed, [], "a discovery: the authenticator offers")
        XCTAssertEqual(w.passkey.asked.first?.largeBlob, .read)
        XCTAssertEqual(leafCapabilities(w), 7)
        XCTAssertEqual(w.service.trustedRootID(), w.passkey.rootID)
        XCTAssertEqual(w.worker.asked("/register"), 1, "published after the commit")
        guard case .ready(_, let publication) = w.service.status() else {
            return XCTFail("expected ready, got \(w.service.status())")
        }
        XCTAssertEqual(publication, .confirmed)
    }

    /// The authenticator's large blob names the root before anybody is asked — the Worker is not.
    func testTheLargeBlobAnswersBeforeTheWorker() async throws {
        let w = try world()
        w.passkey.blob = w.passkey.root
        w.worker.index = .down
        guard case .success = await w.service.signIn(authenticator: w.passkey) else {
            return XCTFail("the blob should have been enough")
        }
        XCTAssertEqual(w.worker.asked("/credential/\(base64urlEncode(Data(w.passkey.credentialID)))"), 0)
    }

    /// §4: the Worker's answer is a HINT. A descriptor naming the credential beside another key — the
    /// squatting the index fix stops, or a lying Worker — fails the assertion, and nothing is adopted.
    func testAWorkerNamingAnotherKeyIsRefused() async throws {
        let w = try world()
        let other = P256.Signing.PrivateKey()
        w.worker.index = .root(E2EIdentity.root(rpID: Self.rpID, credentialID: w.passkey.credentialID,
                                                rootPublicKey: Array(other.publicKey.x963Representation))!)
        let result = await w.service.signIn(authenticator: w.passkey)
        XCTAssertEqual(result.failure, .ceremony(.unverified("signature")))
        XCTAssertEqual(w.service.status(), .unenrolled, "nothing adopted, and the flag released")
        XCTAssertNil(w.service.trustedRootID())
    }

    /// `verifyDiscoveredRoot`'s check `verifyBundle` does not need: a descriptor for another relying
    /// party is refused by name.
    func testADescriptorForAnotherRelyingPartyIsRefused() async throws {
        let w = try world()
        w.worker.index = .root(E2EIdentity.root(rpID: "elsewhere.example", credentialID: w.passkey.credentialID,
                                                rootPublicKey: Array(w.passkey.key.publicKey.x963Representation))!)
        let got1 = await w.service.signIn(authenticator: w.passkey).failure
        XCTAssertEqual(got1, .ceremony(.rootRPID))
    }

    /// Only the Worker's own `404 not-found` is "no identity"; a Worker that did not answer is unknown.
    func testAbsentAndUnknownAreDifferentAnswers() async throws {
        let w = try world()
        w.worker.index = .absent
        let got2 = await w.service.signIn(authenticator: w.passkey).failure
        XCTAssertEqual(got2, .ceremony(.notFound))
        w.worker.index = .down
        let got3 = await w.service.signIn(authenticator: w.passkey).failure
        XCTAssertEqual(got3, .ceremony(.lookupUnavailable))
        XCTAssertEqual(w.service.status(), .unenrolled)
    }

    /// A closed prompt is a decision: reported as `dismissed`, nothing changed, nothing claimed.
    func testADismissedPromptChangesNothing() async throws {
        let w = try world()
        w.worker.index = .root(w.passkey.root)
        w.passkey.refuse = .dismissed
        let result = await w.service.signIn(authenticator: w.passkey)
        XCTAssertEqual(result.failure, .ceremony(.passkey(.dismissed)))
        XCTAssertEqual(E2EPasskeyFailure.passkey(.dismissed).reason, "dismissed",
                       "the code the panel reads as \"back to the form\"")
        XCTAssertEqual(w.service.status(), .unenrolled)
    }

    // MARK: - creating

    /// Prompt one RETAINS the new passkey's descriptor before anything else can fail — the one moment
    /// it exists; prompt two signs this Mac's grant with exactly that credential, writes the descriptor
    /// to its large blob, and the retained entry goes on the commit.
    func testCreatingRetainsThePasskeyThenAuthorisesThisMac() async throws {
        let w = try world()
        guard case .success = await w.service.createPasskey(authenticator: w.passkey) else {
            return XCTFail("create")
        }
        XCTAssertEqual(w.pending.read(), w.passkey.root, "retained before the second prompt")
        XCTAssertTrue(w.service.hasPendingRoot)
        XCTAssertEqual(w.service.status(), .unenrolled, "creating alone adopts nothing")

        let result = await w.service.authorise(authenticator: w.passkey)
        guard case .success(let acceptance) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(acceptance, .adoptedNewRoot(rootID: w.passkey.rootID))
        XCTAssertEqual(w.passkey.asked.last?.allowed, [w.passkey.credentialID])
        XCTAssertEqual(w.passkey.asked.last?.largeBlob, .write(w.passkey.root))
        XCTAssertEqual(w.passkey.blob, w.passkey.root)
        XCTAssertNil(w.pending.read(), "committed: nothing left to finish")
        XCTAssertEqual(leafCapabilities(w), 7)
        XCTAssertEqual(w.worker.asked("/register"), 1, "and published, which indexes the credential")
    }

    /// A ceremony failure is NEVER a reason to drop the retained passkey — a cancel and "no such
    /// credential" are one error — so "Finish setting up" still works afterwards.
    func testACancelledSecondPromptKeepsThePasskeyToFinish() async throws {
        let w = try world()
        _ = await w.service.createPasskey(authenticator: w.passkey)
        w.passkey.refuse = .dismissed
        let got4 = await w.service.authorise(authenticator: w.passkey).failure
        XCTAssertEqual(got4,
                       .ceremony(.passkey(.dismissed)))
        XCTAssertNotNil(w.pending.read())
        w.passkey.refuse = nil
        guard case .success = await w.service.authorise(authenticator: w.passkey) else {
            return XCTFail("finishing should work")
        }
    }

    /// A passkey made here and never finished is resolved by signing in too, with no Worker entry —
    /// the one place a never-registered credential can be found — and stops being pending.
    func testSigningInWithAnUnfinishedPasskeyFindsIt() async throws {
        let w = try world()
        _ = await w.service.createPasskey(authenticator: w.passkey)
        w.worker.index = .absent
        guard case .success = await w.service.signIn(authenticator: w.passkey) else {
            return XCTFail("the retained descriptor should resolve it")
        }
        XCTAssertNil(w.pending.read())
    }

    func testFinishingWithNothingRetainedIsRefused() async throws {
        let w = try world()
        let got5 = await w.service.authorise(authenticator: w.passkey).failure
        XCTAssertEqual(got5, .ceremony(.noPending))
        XCTAssertEqual(w.passkey.asked.count, 0, "and no prompt")
    }

    /// Signing out takes an unfinished passkey with it: finishing adopts without asking anyone.
    func testSigningOutForgetsAnUnfinishedPasskey() async throws {
        let w = try world()
        _ = await w.service.createPasskey(authenticator: w.passkey)
        XCTAssertTrue(w.service.forget())
        XCTAssertNil(w.pending.read())
    }

    // MARK: - who may start one

    /// §10.1 forbids replacing a root: an enrolled Mac at capability 7 is refused another ceremony, by
    /// name, and with no prompt.
    func testAnEnrolledMacRefusesAnotherCeremony() async throws {
        let w = try world()
        w.worker.index = .root(w.passkey.root)
        _ = await w.service.signIn(authenticator: w.passkey)
        let prompts = w.passkey.asked.count

        guard case .failure(.notApplicable(let status)) = await w.service.signIn(authenticator: w.passkey),
              case .ready = status else { return XCTFail("signing in again must be refused") }
        guard case .failure(.notApplicable) = await w.service.createPasskey(authenticator: w.passkey) else {
            return XCTFail("creating a second identity must be refused")
        }
        XCTAssertEqual(w.passkey.asked.count, prompts)
        XCTAssertEqual(w.passkey.registered, 0)
        guard case .ready = w.service.status() else { return XCTFail("the flag was left claimed") }
    }

    /// **§10.3's upgrade.** A Mac adopted by code holds capability 2; signing in asks for ITS root's
    /// credential only (a device that trusts a root is not shopping) and commits a direct grant at 7.
    /// Creating is not offered to it — that would be a second identity.
    func testAMacAdoptedByCodeUpgradesBySigningInWithItsOwnRoot() async throws {
        let w = try world()
        guard case .success(let loaded) = w.identity.load(),
              let request = E2EPasskeyGrant.request(keys: loaded.installation.keys, capabilities: .hostOnly),
              case .success(let answer) = await w.passkey.assert(
                rpID: Self.rpID, challenge: request.challenge, allowedCredentials: [], largeBlob: nil),
              let root = E2EIdentity.parseRoot(w.passkey.root),
              let bundle = E2EPasskeyGrant.bundle(root: root, answer: answer, request: request,
                                                  keys: loaded.installation.keys, policy: w.identity.policy),
              case .success = w.identity.manager.acceptEnrollmentReturn(
                bundle: bundle, pendingOperationID: request.operationID, loaded: loaded,
                policy: w.identity.policy, newRoot: .discovered)
        else { return XCTFail("seeding a capability-2 Mac") }
        w.service.invalidateStatus()
        XCTAssertEqual(leafCapabilities(w), 2)

        guard case .failure(.notApplicable) = await w.service.createPasskey(authenticator: w.passkey) else {
            return XCTFail("an enrolled Mac creates no second identity")
        }
        let result = await w.service.signIn(authenticator: w.passkey)
        guard case .success(let acceptance) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(acceptance, .verified, "the same root, nothing new adopted")
        XCTAssertEqual(w.passkey.asked.last?.allowed, [w.passkey.credentialID])
        XCTAssertNil(w.passkey.asked.last?.largeBlob, "nothing to discover")
        XCTAssertEqual(leafCapabilities(w), 7)
        XCTAssertEqual(w.worker.asked("/credential/\(base64urlEncode(Data(w.passkey.credentialID)))"), 0)
    }

    /// **Two clicks must not become two prompts.** The claim is synchronous, so a second ceremony while
    /// the first's prompt is up is refused — and the status says a ceremony is in flight.
    func testASecondCeremonyWhileOneIsInFlightIsRefused() async throws {
        let w = try world()
        w.worker.index = .root(w.passkey.root)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        w.passkey.hold = stream
        let service = w.service, passkey = w.passkey
        let first = Task { await service.signIn(authenticator: passkey) }
        let deadline = Date().addingTimeInterval(5)
        while w.service.status() != .enrolling && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(w.service.status(), .enrolling)

        let got6 = await w.service.createPasskey(authenticator: w.passkey).failure
        XCTAssertEqual(got6, .alreadyEnrolling)
        continuation.yield(); continuation.finish()
        guard case .success = await first.value else { return XCTFail("the first should finish") }
        XCTAssertEqual(w.passkey.registered, 0)
    }

    func testAnUnavailableIdentityRunsNoCeremony() async {
        let service = E2EIdentityService(e2e: .failure(.origin(.unsupportedPath)), directory: Worker())
        let passkey = SoftwarePasskey()
        let got7 = await service.signIn(authenticator: passkey).failure
        XCTAssertEqual(got7,
                       .unavailable(.origin(.unsupportedPath)))
        XCTAssertEqual(passkey.asked.count, 0)
    }

    // MARK: - the credential lookup

    /// The request names the configured origin and the credential as unpadded base64url — and only the
    /// Worker's own `not-found` is absence.
    func testTheLookupAsksTheConfiguredOrigin() async throws {
        final class Recorder: E2EDirectoryClient.Transport, @unchecked Sendable {
            var url: URL?
            var answer: (Data, Int)?
            func send(_ request: URLRequest) async -> (Data, Int)? { url = request.url; return answer }
        }
        let r = Recorder()
        let lookup = E2ECredentialLookup(origin: URL(string: "https://cp.example:8443")!, transport: r)
        r.answer = (Data(#"{"error":"not-found"}"#.utf8), 404)
        let got8 = await lookup.root(credentialID: [0xFB, 0xFF])
        XCTAssertEqual(got8, .absent)
        XCTAssertEqual(r.url?.absoluteString, "https://cp.example:8443/credential/-_8")
        r.answer = (Data("gone".utf8), 404)
        let got9 = await lookup.root(credentialID: [1])
        XCTAssertEqual(got9, .unknown, "a 404 that is not the Worker's")
        r.answer = (Data(#"{"root":"AQID"}"#.utf8), 200)
        let got10 = await lookup.root(credentialID: [1])
        XCTAssertEqual(got10, .found([1, 2, 3]))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
