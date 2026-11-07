import RdevCore
import RdevE2E
import XCTest
@testable import RdevHostKit

/// **ADD DEVICE BY CODE, Mac to Mac, with only the relay and the passkey faked** (docs/pairing.md, "Add device by
/// code"). A REAL new Mac (`AdoptByCode`: its window, its `E2EClientGate` in `pair`, its commit) against the REAL
/// issuer (`AddDeviceByCode`: `E2ESignallingGate` with `PairIssuer.passkey`, the root's passkey signing a direct
/// grant), an in-memory relay between them, and `E2EPasskeyCeremonyTests.SoftwarePasskey` as the root — so the
/// chain the new Mac commits is one the product built and the product verified, end to end.
final class AddDeviceByCodeTests: XCTestCase {

    // MARK: - the relay

    /// One room: the new Mac is its host, the issuer its one client. What a host sends to `peer` reaches the
    /// client; what the client sends reaches the host tagged with the client's id; either side closing is the
    /// other's `closed`.
    final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private var host: AsyncStream<AdoptByCode.Event>.Continuation?
        private var client: AsyncStream<AddDeviceByCode.Event>.Continuation?
        static let clientID = "c1"
        /// The next client → host message is lost on the way (the Mac mini's connection dropping as its chain was
        /// sent, 2026-10-07).
        var dropNextToHost = false
        /// The real relay holds a closed client's place for 180 s before telling the host (`GRACE_MS`); false
        /// models that window — the host hears nothing.
        var announceClientClose = true

        var connectHost: AdoptByCode.Connect {
            { [self] _, _ in
                let (stream, continuation) = AsyncStream<AdoptByCode.Event>.makeStream()
                lock.withLock { host = continuation }
                return (HostSide(relay: self), stream)
            }
        }
        var connectClient: AddDeviceByCode.Connect {
            { [self] _, _ in
                let (stream, continuation) = AsyncStream<AddDeviceByCode.Event>.makeStream()
                let h = lock.withLock { () -> AsyncStream<AdoptByCode.Event>.Continuation? in
                    client = continuation
                    return host
                }
                h?.yield(.peerJoined(Self.clientID))
                return (ClientSide(relay: self), stream)
            }
        }

        func toClient(_ ct: String, mode: E2EWire.Mode?) { lock.withLock { client }?.yield(.e2e(ct: ct, mode: mode)) }
        func toHost(_ ct: String, mode: E2EWire.Mode? = nil) {
            let h = lock.withLock { () -> AsyncStream<AdoptByCode.Event>.Continuation? in
                if dropNextToHost { dropNextToHost = false; return nil }
                return host
            }
            h?.yield(.e2e(ct: ct, peer: Self.clientID, mode: mode))
        }
        func hostClosed() {
            let (h, c) = lock.withLock { (host, client) }
            h?.finish(); c?.yield(.closed)
        }
        func clientClosed() {
            let (h, c, announce) = lock.withLock { (host, client, announceClientClose) }
            c?.finish()
            if announce { h?.yield(.closed) }
        }

        struct HostSide: AdoptByCode.Transport {
            let relay: Relay
            func send(ct: String, peer: String, mode: E2EWire.Mode?) { relay.toClient(ct, mode: mode) }
            func close() { relay.hostClosed() }
        }
        struct ClientSide: AddDeviceByCode.Transport {
            let relay: Relay
            func send(ct: String) { relay.toHost(ct) }
            func close() { relay.clientClosed() }
        }
    }

    // MARK: - the world

    private static let policy = E2EVerify.Policy(rpID: E2EPasskeyCeremonyTests.rpID,
                                                 allowedOrigins: [E2EPasskeyCeremonyTests.origin])

    /// A Mac signed in with the software passkey: its identity holds the root and a chain at capability 7.
    private func issuer() async throws -> (identity: E2EHostIdentity, passkey: E2EPasskeyCeremonyTests.SoftwarePasskey) {
        guard case .success(let origin) = E2EOrigin.resolve(E2EPasskeyCeremonyTests.origin) else { throw Malformed() }
        let identity = E2EHostIdentity(origin: origin,
                                       manager: E2EIdentityManager(installations: InstallationStore.Memory(),
                                                                   trust: InstallationStore.Memory()),
                                       pendingRoot: MemoryRecord())
        let passkey = E2EPasskeyCeremonyTests.SoftwarePasskey()
        let worker = E2EPasskeyCeremonyTests.Worker()
        worker.index = .root(passkey.root)
        guard case .success = await identity.signIn(authenticator: passkey, transport: worker) else { throw Malformed() }
        return (identity, passkey)
    }

    /// The new Mac: no identity, a pairing window whose carrier is the one a person would read off its screen.
    private struct NewMac {
        let manager: E2EIdentityManager
        let adopt: AdoptByCode
        let carrier: String
    }

    private func newMac(relay: Relay, stallSeconds: Double = 150) throws -> NewMac {
        let seed = (0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }
        let carrier = try XCTUnwrap(PairingSeed.encode(seed: seed))
        let material = try XCTUnwrap(PairingSeed.derive(seed: seed))
        let opened = PairingWindowOpener.Opened(seed: seed, carrier: carrier, material: material,
                                                sessionURL: "https://rp.example/session/\(material.code)")
        let manager = E2EIdentityManager(installations: InstallationStore.Memory(), trust: InstallationStore.Memory())
        let adopt = AdoptByCode(manager: manager, policy: Self.policy, openWindow: { _ in .success(opened) },
                                connect: relay.connectHost, stallSeconds: stallSeconds)
        return NewMac(manager: manager, adopt: adopt, carrier: carrier)
    }

    private struct Malformed: Error {}

    /// `task`'s value, or nil if it takes longer than `seconds` — a test of a bound must FAIL when the bound is gone,
    /// not hang.
    /// (Not a task group: one returns only once EVERY child has, so a task that never ends kept it waiting too.)
    private func within<T: Sendable>(_ seconds: Double, _ task: Task<T, Never>) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let first = FirstOf(c)
            Task { first.resume(await task.value) }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); first.resume(nil) }
        }
    }

    private func eventually(_ what: String, timeout: Double = 5,
                            _ check: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await check() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out: \(what)")
        throw Malformed()
    }

    /// The new Mac shows its code; this Mac joins with it and reaches "Add this Mac?".
    private func reachConfirm(relay: Relay, mac: NewMac, add: AddDeviceByCode)
        async throws -> (macDone: Task<AdoptByCode.Phase, Never>, addDone: Task<AddDeviceByCode.Phase, Never>) {
        let macDone = Task { await mac.adopt.start(signalingBase: "https://rp.example") }
        try await eventually("the new Mac shows its code") {
            if case .waiting = await mac.adopt.phase { return true }
            return false
        }
        let carrier = mac.carrier
        let addDone = Task { await add.start(carrier: carrier, signalingBase: "https://rp.example") }
        try await eventually("Add this Mac?") {
            if case .confirm = await add.phase { return true }
            return false
        }
        return (macDone, addDone)
    }

    // MARK: - the flow

    /// **The whole flow**: the new Mac speaks first, this Mac answers, the person is asked to confirm the
    /// identity — NAMED, before anything is signed — and only then does the root's passkey sign. The new Mac
    /// commits a DIRECT, root-issued capability-2 grant for its own descriptor, bound to the live handshake.
    func testAMacAddsANewMacWithItsPasskey() async throws {
        let relay = Relay()
        let (identity, passkey) = try await issuer()
        let mac = try newMac(relay: relay)
        let add = AddDeviceByCode(identity: identity, authenticator: passkey, connect: relay.connectClient)
        let (macDone, addDone) = try await reachConfirm(relay: relay, mac: mac, add: add)

        let asked = await add.phase
        XCTAssertEqual(asked, .confirm(identityCode: E2EIdentity.code(rootID: passkey.rootID)),
                       "the identity the new Mac will join, named")
        XCTAssertEqual(passkey.asked.count, 1, "only the sign-in so far: nothing signed before the person says yes")

        await add.decide(true)
        let added = await addDone.value
        guard case .added = added else { return XCTFail("not added: \(added)") }
        XCTAssertEqual(passkey.asked.last?.allowed, [passkey.credentialID], "the ROOT's credential, by name")

        let outcome = await macDone.value
        guard case .enrolled = outcome else { return XCTFail("the new Mac did not enrol: \(outcome)") }
        guard case .success(let loaded) = mac.manager.load(), let bundle = loaded.record.bundle else {
            return XCTFail("nothing committed")
        }
        let chain = try E2EVerify.verifyBundle(bundle, trustedRootID: passkey.rootID, policy: Self.policy).get()
        XCTAssertEqual(chain.capabilities.raw, 2, "share only — a Mac added by code may do nothing else")
        XCTAssertEqual(chain.leaf.issuerKind, .root, "a DIRECT grant, the one a browser issues")
        XCTAssertEqual(chain.leafDevice.bytes, loaded.deviceDescriptor)
        guard case .remote = chain.leaf.binding else { return XCTFail("not bound to the handshake") }
    }

    /// **THE CHAIN LOST ON THE WAY** — what happened adding the Mac mini (2026-10-07): its connection dropped as its
    /// chain was sent, the laptop said "added", and the mini sat on "Adding this Mac…" for good. Now this side says
    /// added only on the new Mac's word, which never comes — `unconfirmed` — and the new Mac, hearing nothing more
    /// (the real relay tells it nothing for 180 s), gives up as `stalled`.
    func testAChainLostOnTheWayIsNotCalledAddedAndTheNewMacStopsWaiting() async throws {
        let relay = Relay()
        relay.announceClientClose = false
        let (identity, passkey) = try await issuer()
        let mac = try newMac(relay: relay, stallSeconds: 1)
        let add = AddDeviceByCode(identity: identity, authenticator: passkey, connect: relay.connectClient,
                                  ackSeconds: 0.3)
        let (macDone, addDone) = try await reachConfirm(relay: relay, mac: mac, add: add)
        relay.dropNextToHost = true                           // the chain never arrives
        await add.decide(true)
        let issued = await add.phase
        XCTAssertEqual(issued, .finishing, "sent, and waiting for the new Mac's word — not added")
        let unconfirmed = await within(5, addDone)
        XCTAssertEqual(unconfirmed, .failed(reason: "unconfirmed"))
        let outcome = await within(5, macDone)
        XCTAssertEqual(outcome, .failed(reason: "stalled"))
        if outcome == nil { await mac.adopt.cancel(); _ = await macDone.value }
        guard case .success(let loaded) = mac.manager.load() else { return XCTFail("unreadable") }
        XCTAssertNil(loaded.record.bundle)
    }

    /// **STOP on the new Mac, mid-handshake**: it ends there, and this side hears the room close.
    func testStoppingTheNewMacMidHandshakeEndsBothSides() async throws {
        let relay = Relay()
        let (identity, passkey) = try await issuer()
        let mac = try newMac(relay: relay)
        let add = AddDeviceByCode(identity: identity, authenticator: passkey, connect: relay.connectClient)
        let (macDone, addDone) = try await reachConfirm(relay: relay, mac: mac, add: add)
        await mac.adopt.cancel()
        let stopped = await macDone.value
        XCTAssertEqual(stopped, .failed(reason: "cancelled"))
        let issuerSaw = await addDone.value
        XCTAssertEqual(issuerSaw, .failed(reason: "disconnected"))
        XCTAssertEqual(passkey.asked.count, 1, "nothing signed")
    }

    /// "No" is a decision: nothing is signed, and the new Mac commits nothing.
    func testDecliningSignsNothingAndTheNewMacCommitsNothing() async throws {
        let relay = Relay()
        let (identity, passkey) = try await issuer()
        let mac = try newMac(relay: relay)
        let add = AddDeviceByCode(identity: identity, authenticator: passkey, connect: relay.connectClient)
        let (macDone, addDone) = try await reachConfirm(relay: relay, mac: mac, add: add)
        await add.decide(false)
        let declined = await addDone.value
        XCTAssertEqual(declined, .failed(reason: "cancelled"))
        XCTAssertEqual(passkey.asked.count, 1, "the passkey was never asked")
        let outcome = await macDone.value
        guard case .failed = outcome else { return XCTFail("the new Mac enrolled: \(outcome)") }
        guard case .success(let loaded) = mac.manager.load() else { return XCTFail("unreadable") }
        XCTAssertNil(loaded.record.bundle)
    }

    /// A dismissed passkey prompt is a cancel, and nothing reaches the new Mac.
    func testADismissedPasskeyPromptAddsNothing() async throws {
        let relay = Relay()
        let (identity, passkey) = try await issuer()
        let mac = try newMac(relay: relay)
        let add = AddDeviceByCode(identity: identity, authenticator: passkey, connect: relay.connectClient)
        let (macDone, addDone) = try await reachConfirm(relay: relay, mac: mac, add: add)
        passkey.refuse = .dismissed
        await add.decide(true)
        let dismissed = await addDone.value
        XCTAssertEqual(dismissed, .failed(reason: "cancelled"))
        let outcome = await macDone.value
        guard case .failed = outcome else { return XCTFail("the new Mac enrolled: \(outcome)") }
    }

    /// **A code pasted into CONNECT** starts a guest pairing, whose first message names a mode: the new Mac
    /// says that, rather than the `gate/noise` the message produced read as a reply (2026-10-07).
    func testTheNewMacSaysWhenItsCodeWasEnteredInConnect() async throws {
        let relay = Relay()
        let mac = try newMac(relay: relay)
        let macDone = Task { await mac.adopt.start(signalingBase: "https://rp.example") }
        try await eventually("the new Mac shows its code") {
            if case .waiting = await mac.adopt.phase { return true }
            return false
        }
        _ = relay.connectClient(URL(string: "wss://rp.example/session/x")!, "t")   // a guest joins…
        relay.toHost(String(repeating: "A", count: 43), mode: .pair)            // …and opens a handshake of its own
        let refused = await macDone.value
        XCTAssertEqual(refused, .failed(reason: "entered-in-connect"))
    }

    /// What a typo, or a room where no Mac speaks, look like.
    func testNotACodeAndNoAnswer() async throws {
        let (identity, passkey) = try await issuer()
        let relay = Relay()
        let typo = AddDeviceByCode(identity: identity, authenticator: passkey, connect: relay.connectClient)
        let typed = await typo.start(carrier: "not a code", signalingBase: "https://rp.example")
        XCTAssertEqual(typed, .failed(reason: "not-a-code"))
        let silent = AddDeviceByCode(identity: identity, authenticator: passkey, connect: relay.connectClient,
                                     answerSeconds: 0.05)
        let carrier = try XCTUnwrap(PairingSeed.encode(seed: [UInt8](repeating: 7, count: 16)))
        let quiet = await silent.start(carrier: carrier, signalingBase: "https://rp.example")
        XCTAssertEqual(quiet, .failed(reason: "no-answer"))
    }

    /// A Mac with no identity has nothing to add a Mac to.
    func testAMacWithNoIdentityCannotAddOne() async throws {
        guard case .success(let origin) = E2EOrigin.resolve(E2EPasskeyCeremonyTests.origin) else { throw Malformed() }
        let bare = E2EHostIdentity(origin: origin,
                                   manager: E2EIdentityManager(installations: InstallationStore.Memory(),
                                                               trust: InstallationStore.Memory()),
                                   pendingRoot: MemoryRecord())
        let add = AddDeviceByCode(identity: bare, authenticator: E2EPasskeyCeremonyTests.SoftwarePasskey(),
                                  connect: Relay().connectClient)
        let carrier = try XCTUnwrap(PairingSeed.encode(seed: [UInt8](repeating: 7, count: 16)))
        let none = await add.start(carrier: carrier, signalingBase: "https://rp.example")
        XCTAssertEqual(none, .failed(reason: "no-identity"))
    }
}

/// Resumes its continuation once, with whichever value comes first (`AddDeviceByCodeTests.within`).
private final class FirstOf<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T?, Never>?
    init(_ c: CheckedContinuation<T?, Never>) { self.c = c }
    func resume(_ v: T?) { lock.withLock { let k = c; c = nil; return k }?.resume(returning: v) }
}
