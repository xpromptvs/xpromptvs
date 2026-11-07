import RdevCore
import RdevE2E
import XCTest
@testable import RdevHostKit

/// **ADD DEVICE BY CODE OVER THE REAL RELAY** — both sides' real WebSocket transports (`SignalingTransport`) against a
/// running Worker, a person's pause before confirming. Opt-in: skipped unless `RDEV_LIVE_RELAY` names a Worker
/// (`wrangler dev`); run unsandboxed (`--strategy=TestRunner=local`).
final class AddDeviceByCodeLiveTests: XCTestCase {
    func testAddingOverTheRealRelayWithAPersonsPause() async throws {
        guard let base = ProcessInfo.processInfo.environment["RDEV_LIVE_RELAY"] else { throw XCTSkip("RDEV_LIVE_RELAY unset") }
        let pause = Double(ProcessInfo.processInfo.environment["RDEV_LIVE_PAUSE"] ?? "20") ?? 20
        guard case .success(let origin) = E2EOrigin.resolve(E2EPasskeyCeremonyTests.origin) else { return XCTFail("origin") }
        let identity = E2EHostIdentity(origin: origin,
                                       manager: E2EIdentityManager(installations: InstallationStore.Memory(),
                                                                   trust: InstallationStore.Memory()),
                                       pendingRoot: MemoryRecord())
        let passkey = E2EPasskeyCeremonyTests.SoftwarePasskey()
        let worker = E2EPasskeyCeremonyTests.Worker()
        worker.index = .root(passkey.root)
        guard case .success = await identity.signIn(authenticator: passkey, transport: worker) else { return XCTFail("sign in") }

        let policy = E2EVerify.Policy(rpID: E2EPasskeyCeremonyTests.rpID, allowedOrigins: [E2EPasskeyCeremonyTests.origin])
        let manager = E2EIdentityManager(installations: InstallationStore.Memory(), trust: InstallationStore.Memory())
        let adopt = AdoptByCode(manager: manager, policy: policy)
        let macDone = Task { await adopt.start(signalingBase: base) }
        var carrier = ""
        for _ in 0 ..< 500 {
            if case .waiting(let c, _) = await adopt.phase { carrier = c; break }
            if case .failed(let r) = await adopt.phase { return XCTFail("the new Mac: \(r)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(carrier.isEmpty, "the new Mac shows a code")
        print("LIVE carrier \(carrier)")

        let add = AddDeviceByCode(identity: identity, authenticator: passkey)
        let addDone = Task { await add.start(carrier: carrier, signalingBase: base) }
        var confirmed = false
        for _ in 0 ..< 1000 {
            let p = await add.phase
            if case .confirm = p { confirmed = true; break }
            if case .failed(let r) = p { return XCTFail("the issuer: \(r)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(confirmed, "Add this Mac?")
        print("LIVE confirm reached; pausing \(pause) s as a person would")
        try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
        await add.decide(true)
        let added = await addDone.value
        print("LIVE issuer: \(added)")
        let outcome = await withTaskGroup(of: AdoptByCode.Phase?.self) { group in
            group.addTask { await macDone.value }
            group.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        print("LIVE new Mac: \(String(describing: outcome)) (phase now \(await adopt.phase))")
        guard case .enrolled? = outcome else { return XCTFail("the new Mac did not enrol: \(String(describing: outcome)), phase \(await adopt.phase)") }
    }
}
