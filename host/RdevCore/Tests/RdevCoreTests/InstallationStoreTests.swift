import XCTest
@testable import RdevCore

/// What happens to a §10.2 installation record on the way in and out of storage — and above all,
/// what happens when it is there and cannot be read.
final class InstallationStoreTests: XCTestCase {

    private func outcome(_ r: Result<InstallationStore.Outcome, InstallationStore.Failure>)
        -> String {
        switch r {
        case .success(.loaded): return "loaded"
        case .success(.created): return "created"
        case .failure(let f): return f.rawValue
        }
    }

    func testAnEmptyStoreCreatesAndPersists() throws {
        let backend = InstallationStore.Memory()
        let first = InstallationStore.loadOrCreate(backend)
        XCTAssertEqual(outcome(first), "created")
        XCTAssertEqual(backend.writes, 1)

        // PAIRED: a store that never wrote would satisfy the first assertion, and one that wrote
        // every time would satisfy neither this nor the identity comparison below.
        let second = InstallationStore.loadOrCreate(backend)
        XCTAssertEqual(outcome(second), "loaded")
        XCTAssertEqual(backend.writes, 1, "a second call must not rewrite the record")

        guard case .success(.created(let a)) = first,
              case .success(.loaded(let b)) = second else { return XCTFail("outcomes") }
        XCTAssertEqual(a, b, "the identity that came back must be the one that was made")
    }

    /// **FIRST-TIME CREATION IS SINGLE-FLIGHT.** Two callers finding the store empty at once must
    /// end up holding ONE installation. Before this, each generated its own keys and wrote them, the
    /// last write won, and a caller that had already acted on the other set — §12.1's enrollment,
    /// certifying the keys it loaded — left the device with a chain for keys it no longer held:
    /// §12.2's registration was then signed with the surviving keys and refused `401 signature`
    /// (status 8). MEASURED 2026-09-25 in the native app, where the first `status()` and the detached
    /// `retryRegistration` that `E2EIdentityService.shared` fires each created a key set on EVERY
    /// fresh launch (4 of 4).
    ///
    /// The backend is slow on purpose, so every caller reads "empty" before any has written — the
    /// window the race needs, made wide enough to hit every time instead of now and then.
    ///
    /// **RED NEEDS PARALLELISM.** On a single core `concurrentPerform` can run the eight calls one
    /// after another, and serial callers never race — the test would pass without the lock. It is
    /// skipped there rather than allowed to pass vacuously.
    func testConcurrentFirstLoadsCreateOneInstallation() throws {
        try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount < 2,
                      "needs ≥ 2 cores to race; on one it would pass without the lock")
        final class Slow: InstallationStore.Backend, @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [UInt8]?
            private(set) var writes = 0
            func read() -> [UInt8]? {
                lock.lock(); let s = stored; lock.unlock()
                Thread.sleep(forTimeInterval: 0.02)
                return s
            }
            func write(_ bytes: [UInt8]) -> Bool {
                lock.lock(); stored = bytes; writes += 1; lock.unlock()
                return true
            }
            func delete() -> Bool { lock.lock(); stored = nil; lock.unlock(); return true }
        }
        let backend = Slow()
        let resultsLock = NSLock()
        var installations: [DeviceIdentity.Installation] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            switch InstallationStore.loadOrCreate(backend) {
            case .success(.created(let i)), .success(.loaded(let i)):
                resultsLock.lock(); installations.append(i); resultsLock.unlock()
            case .failure: break
            }
        }
        // PAIRED with a non-zero guard: eight callers must all have come back with SOMETHING.
        XCTAssertEqual(installations.count, 8)
        XCTAssertEqual(backend.writes, 1, "exactly one caller may create the installation")
        XCTAssertEqual(Set(installations.map { DeviceIdentity.encode($0) }).count, 1,
                       "every caller must hold the SAME keys")
    }

    /// **`destroy` WAITS FOR A FIRST CREATION IN FLIGHT.** A `forget()` racing a first
    /// `loadOrCreate` used to delete the (still empty) store, after which the creation's write landed
    /// — so the device came back from "signed out" holding a fresh key set nobody asked for. Now the
    /// two share the creation lock: the delete happens after the write, and the store ends EMPTY.
    func testDestroyIsSerialisedAgainstAFirstCreation() {
        final class SlowWrite: InstallationStore.Backend, @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [UInt8]?
            let reading = DispatchSemaphore(value: 0)
            func read() -> [UInt8]? { lock.lock(); defer { lock.unlock() }; reading.signal(); return stored }
            func write(_ bytes: [UInt8]) -> Bool {
                Thread.sleep(forTimeInterval: 0.2)   // the window: creation has read "empty", not yet written
                lock.lock(); stored = bytes; lock.unlock(); return true
            }
            func delete() -> Bool { lock.lock(); stored = nil; lock.unlock(); return true }
            var current: [UInt8]? { lock.lock(); defer { lock.unlock() }; return stored }
        }
        let backend = SlowWrite()
        let created = expectation(description: "first creation finished")
        DispatchQueue.global().async {
            if case .success(.created) = InstallationStore.loadOrCreate(backend) { created.fulfill() }
        }
        backend.reading.wait()   // the creation is inside the lock, past its read
        XCTAssertTrue(InstallationStore.destroy(backend))
        wait(for: [created], timeout: 5)
        XCTAssertNil(backend.current, "a destroy issued during a first creation must win: the store ends empty")
    }

    /// THE DECISION THIS FILE EXISTS FOR. Something is stored and it is not a record; overwriting it
    /// generates a new device and silently abandons every grant the old one held. A transient read
    /// fault and a genuinely corrupt record are indistinguishable from here, and only one of them is
    /// worth destroying an identity over — so neither is, without a person.
    func testAnUnreadableRecordIsRefusedAndLeftAlone() {
        let junk: [UInt8] = Array("not an installation record at all, but exactly as long".utf8)
        let backend = InstallationStore.Memory(junk)
        XCTAssertEqual(outcome(InstallationStore.loadOrCreate(backend)), "unreadable-record")
        XCTAssertEqual(backend.stored, junk, "the unreadable bytes must still be there")
        XCTAssertEqual(backend.writes, 0, "nothing may be written over them")
    }

    func testAnEmptyStoreIsNotAnUnreadableOne() {
        // The two are different outcomes and must not collapse: one is a device that has never run,
        // the other is a device whose identity is in trouble.
        XCTAssertEqual(outcome(InstallationStore.loadOrCreate(InstallationStore.Memory())), "created")
        XCTAssertEqual(outcome(InstallationStore.loadOrCreate(InstallationStore.Memory([]))),
                       "unreadable-record")
    }

    /// §12.3: "unsuccessful durable write grants no authority". A caller that ignored this would be
    /// running an identity it cannot resume after a restart.
    func testAFailedWriteIsAFailureNotAnIdentity() {
        XCTAssertEqual(outcome(InstallationStore.loadOrCreate(InstallationStore.ReadOnly())),
                       "write-failed")
    }

    func testGenerationFailureIsReportedRatherThanPapered() {
        // A randomness source that returns the wrong width stands in for a refusing CSPRNG.
        let backend = InstallationStore.Memory()
        let outcomeString = outcome(InstallationStore.loadOrCreate(backend) { _ in [] })
        XCTAssertEqual(outcomeString, "generation-failed")
        XCTAssertNil(backend.stored)
    }

    func testDestroyIsTheOnlyPathThatDiscardsKeys() throws {
        let backend = InstallationStore.Memory()
        guard case .success(.created(let made)) = InstallationStore.loadOrCreate(backend) else {
            return XCTFail("created")
        }
        XCTAssertTrue(InstallationStore.destroy(backend))
        XCTAssertNil(backend.stored)

        // ...and what comes back afterwards is a DIFFERENT device. §10.2: "Private-key loss means
        // generating new keys and enrolling again, not reconstructing the old device."
        guard case .success(.created(let remade)) = InstallationStore.loadOrCreate(backend) else {
            return XCTFail("created again")
        }
        XCTAssertNotEqual(made, remade)
        XCTAssertNotEqual(made.rendezvousSeed, remade.rendezvousSeed,
                          "reinstallation generates BOTH anew, address included")
    }

    /// `Memory` is a class rather than a struct so it behaves like storage. As a value type
    /// `loadOrCreate` would write into a copy, every caller would appear to get a fresh identity
    /// forever, and a test using one would pass while proving nothing about persistence.
    func testTheMemoryBackendActuallyRemembers() {
        let backend = InstallationStore.Memory()
        _ = InstallationStore.loadOrCreate(backend)
        XCTAssertNotNil(backend.stored)
        XCTAssertNotNil(DeviceIdentity.decode(backend.stored!))
    }

    func testARoundTripSurvivesARestart() throws {
        let backend = InstallationStore.Memory()
        guard case .success(.created(let made)) = InstallationStore.loadOrCreate(backend) else {
            return XCTFail("created")
        }
        // A "restart": a brand-new backend over the same bytes, which is all a restart is.
        let afterRestart = InstallationStore.Memory(backend.stored)
        guard case .success(.loaded(let loaded)) =
                InstallationStore.loadOrCreate(afterRestart) else { return XCTFail("loaded") }
        XCTAssertEqual(loaded, made)
        XCTAssertEqual(loaded.route, made.route, "the durable route survives too, by construction")
    }
}
