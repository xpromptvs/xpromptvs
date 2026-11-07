import XCTest
@testable import RdevCore

/// §12.3's commit order. `protocol/test/e2e-enrollment.test.ts` asserts the same rules.
///
/// THE ORDERING IS THE FEATURE: durable local commit → publication attempt → outcome →
/// acknowledgement → background retries. A reducer, so a CRASH is dropping the returned journal on
/// the floor and a RESTART is applying the next event to the last journal actually written — which
/// is §17.2's "restart from serialized durable state only", expressed as ordinary code.
final class E2EEnrollmentTests: XCTestCase {

    private func id(_ n: UInt8) -> [UInt8] { Array(repeating: n, count: 32) }
    private var device: [UInt8] { id(1) }
    private var other: [UInt8] { id(2) }
    private var op: [UInt8] { id(0x10) }
    private var otherOp: [UInt8] { id(0x11) }
    private var grant: [UInt8] { id(0x20) }
    private let bundle: [UInt8] = [1, 2, 3, 4]

    private func step(_ journal: E2EEnrollment.Journal,
                      _ event: E2EEnrollment.Event,
                      _ file: StaticString = #filePath,
                      _ line: UInt = #line) throws -> E2EEnrollment.Journal {
        switch E2EEnrollment.apply(journal, event) {
        case .success(let j): return j
        case .failure(let f):
            XCTFail("expected ok, got \(f.rawValue)", file: file, line: line)
            throw f
        }
    }

    private func failure(_ journal: E2EEnrollment.Journal,
                         _ event: E2EEnrollment.Event) -> String {
        switch E2EEnrollment.apply(journal, event) {
        case .success: return "ok"
        case .failure(let f): return f.rawValue
        }
    }

    private func reserved(_ journal: E2EEnrollment.Journal = .init(),
                          deviceID: [UInt8]? = nil,
                          operationID: [UInt8]? = nil) throws -> E2EEnrollment.Journal {
        try step(journal, .reserve(deviceID: deviceID ?? device,
                                   operationID: operationID ?? op))
    }

    private func committed(_ journal: E2EEnrollment.Journal? = nil) throws -> E2EEnrollment.Journal {
        let start = try journal ?? reserved()
        return try step(start, .commit(deviceID: device, operationID: op,
                                       grantID: grant, bundle: bundle))
    }

    // MARK: - the acknowledgement is gated on the transaction

    func testNothingMayBeAcknowledgedBeforeTheCommit() throws {
        var j = E2EEnrollment.Journal()
        XCTAssertFalse(j.mayAcknowledge(operationID: op))
        j = try reserved(j)
        // RESERVED IS NOT COMMITTED. The grant may already be computed — §12.3 allows that — but it
        // must not escape, and this is what says so.
        XCTAssertFalse(j.mayAcknowledge(operationID: op))
        j = try committed(j)
        XCTAssertTrue(j.mayAcknowledge(operationID: op))
    }

    /// §12.2: publication "is not a hard precondition" for access. A rejected job is still an
    /// enrolled device — the endpoint's own verification is what authorized it.
    func testAcknowledgementDoesNotWaitOnPublication() throws {
        var j = try committed()
        XCTAssertTrue(j.mayAcknowledge(operationID: op))
        j = try step(j, .publicationAttempt(operationID: op, response: .httpStatus(422)))
        XCTAssertEqual(j.job(operationID: op)?.status, .rejected)
        XCTAssertTrue(j.mayAcknowledge(operationID: op))
    }

    func testOnlyTheCommittedOperationMayBeAcknowledged() throws {
        XCTAssertFalse(try committed().mayAcknowledge(operationID: otherOp))
    }

    // MARK: - §12.3: only one request wins a window

    func testASecondDeviceIsRefused() throws {
        let j = try reserved()
        XCTAssertEqual(failure(j, .reserve(deviceID: other, operationID: otherOp)), "window-taken")
    }

    func testTheSameRequestReReservingIsIdempotent() throws {
        let j = try reserved()
        XCTAssertEqual(try reserved(j).window, j.window)
    }

    func testADifferentOperationFromTheSameDeviceIsStillADifferentRequest() throws {
        let j = try reserved()
        XCTAssertEqual(failure(j, .reserve(deviceID: device, operationID: otherOp)), "window-taken")
    }

    func testACommittedOrClosedWindowTakesNoFurtherReservations() throws {
        XCTAssertEqual(failure(try committed(), .reserve(deviceID: other, operationID: otherOp)),
                       "window-unavailable")
        let closed = try step(E2EEnrollment.Journal(), .expire)
        XCTAssertEqual(failure(closed, .reserve(deviceID: device, operationID: op)),
                       "window-unavailable")
    }

    // MARK: - §12.3: reservation, grant and job are ONE transaction

    func testACommitWithNoReservationIsRefused() {
        XCTAssertEqual(failure(E2EEnrollment.Journal(),
                               .commit(deviceID: device, operationID: op, grantID: grant,
                                       bundle: bundle)), "not-reserved")
    }

    func testACommitForAnotherDeviceOrOperationIsRefused() throws {
        let j = try reserved()
        XCTAssertEqual(failure(j, .commit(deviceID: other, operationID: op, grantID: grant,
                                          bundle: bundle)), "wrong-reservation")
        XCTAssertEqual(failure(j, .commit(deviceID: device, operationID: otherOp, grantID: grant,
                                          bundle: bundle)), "wrong-reservation")
    }

    func testTheWindowTheJobAndTheDestroyedSecretAllMoveTogether() throws {
        let before = try reserved()
        XCTAssertTrue(before.jobs.isEmpty)
        XCTAssertTrue(before.window.secretIsLive)

        let after = try committed(before)
        XCTAssertEqual(after.jobs.count, 1)
        guard case .committed = after.window else { return XCTFail("committed") }
        // §12.3: the secret is destroyed as part of the committing transaction.
        XCTAssertFalse(after.window.secretIsLive)
    }

    func testReplayingTheSameCommitIsIdempotent() throws {
        let j = try committed()
        let replayed = try committed(j)
        XCTAssertEqual(replayed, j)
        XCTAssertEqual(replayed.jobs.count, 1)
        XCTAssertEqual(failure(j, .commit(deviceID: other, operationID: otherOp, grantID: grant,
                                          bundle: bundle)), "not-reserved")
    }

    /// §17.2: "restart from serialized durable state only." A crash is dropping the returned journal.
    func testACrashBeforeTheDurableWriteLeavesTheWindowReservable() throws {
        let reservedJournal = try reserved()
        XCTAssertEqual(try committed(reservedJournal).jobs.count, 1)

        // ...and the restart, from what was actually written — which is `reserved`.
        XCTAssertTrue(reservedJournal.jobs.isEmpty)
        XCTAssertFalse(reservedJournal.mayAcknowledge(operationID: op))
        XCTAssertTrue(try committed(reserved(reservedJournal)).mayAcknowledge(operationID: op))
    }

    // MARK: - §12.2: the publication job

    func testAFreshJobRetriesAndPreservesItsPayload() throws {
        let job = try XCTUnwrap(try committed().job(operationID: op))
        XCTAssertTrue(job.retriesNow)
        // §12.2: "a retry obtains another challenge but preserves the operation ID and payload."
        XCTAssertEqual(job.bundle, bundle)
        XCTAssertEqual(job.operationID, op)
    }

    func testATransientOutcomeRetriesAndATerminalOnePauses() throws {
        var j = try step(try committed(), .publicationAttempt(operationID: op,
                                                              response: .httpStatus(503)))
        XCTAssertTrue(try XCTUnwrap(j.job(operationID: op)).retriesNow)
        XCTAssertEqual(j.job(operationID: op)?.attempts, 1)

        j = try step(j, .publicationAttempt(operationID: op, response: .httpStatus(400)))
        // "Paused, pending corrective action" — not looped, and not abandoned either.
        XCTAssertFalse(try XCTUnwrap(j.job(operationID: op)).retriesNow)
        XCTAssertTrue(try XCTUnwrap(j.job(operationID: op)).paused)
        XCTAssertTrue(j.pendingJobs.isEmpty)
        XCTAssertEqual(j.jobs.count, 1)
    }

    func testConfirmedIsTerminalEvenForTheEndpointHoldingTheJob() throws {
        var j = try step(try committed(), .publicationAttempt(operationID: op,
                                                              response: .acknowledged))
        XCTAssertEqual(j.job(operationID: op)?.status, .confirmed)
        j = try step(j, .publicationAttempt(operationID: op, response: .noReply))
        XCTAssertEqual(j.job(operationID: op)?.status, .confirmed)
        XCTAssertFalse(try XCTUnwrap(j.job(operationID: op)).retriesNow)
    }

    func testAPausedJobResumesOnlyOnAnExplicitAction() throws {
        var j = try step(try committed(), .publicationAttempt(operationID: op,
                                                              response: .httpStatus(403)))
        XCTAssertFalse(try XCTUnwrap(j.job(operationID: op)).retriesNow)
        j = try step(j, .resume(operationID: op))
        XCTAssertTrue(try XCTUnwrap(j.job(operationID: op)).retriesNow)
        XCTAssertEqual(j.job(operationID: op)?.attempts, 1)
    }

    func testAnUnknownOperationIsNotSilentlyIgnored() throws {
        let j = try committed()
        XCTAssertEqual(failure(j, .publicationAttempt(operationID: otherOp,
                                                      response: .acknowledged)),
                       "unknown-operation")
        XCTAssertEqual(failure(j, .resume(operationID: otherOp)), "unknown-operation")
    }

    // MARK: - §12.2: revocation stops jobs, irreversibly

    func testARevokedDevicesJobStops() throws {
        var j = try committed()
        XCTAssertEqual(j.pendingJobs.count, 1)
        j = try step(j, .revoked(deviceID: device))
        XCTAssertTrue(j.pendingJobs.isEmpty)
        XCTAssertTrue(try XCTUnwrap(j.job(operationID: op)).stopped)
    }

    func testAStoppedJobDoesNotResume() throws {
        // §10.5 has no unrevoke operation; a resume that restarted a revoked device's publication
        // would be the one path in this system that manufactures one.
        var j = try step(try committed(), .revoked(deviceID: device))
        j = try step(j, .resume(operationID: op))
        XCTAssertFalse(try XCTUnwrap(j.job(operationID: op)).retriesNow)
        XCTAssertTrue(try XCTUnwrap(j.job(operationID: op)).stopped)
    }

    /// AND ITS STATUS MUST NOT BE REWRITTEN EITHER, which is a separate fact from whether it runs.
    /// §12.2 obliges an endpoint to surface anything other than `confirmed`; a job reading
    /// `unconfirmed` says "still trying", and a stopped one never will be. Without this the guard
    /// in `resume` is invisible — `retriesNow` already consults `stopped`, so a mutation deleting
    /// the guard passed the whole suite.
    func testResumingAStoppedJobLeavesItsReportedStatusAlone() throws {
        var j = try step(try committed(), .publicationAttempt(operationID: op,
                                                              response: .httpStatus(403)))
        XCTAssertEqual(j.job(operationID: op)?.status, .rejected)
        XCTAssertTrue(try XCTUnwrap(j.job(operationID: op)).paused)

        j = try step(j, .revoked(deviceID: device))
        let before = try XCTUnwrap(j.job(operationID: op))
        j = try step(j, .resume(operationID: op))
        XCTAssertEqual(try XCTUnwrap(j.job(operationID: op)), before)
    }

    func testADeviceRevokedBeforeItsCommitGetsAJobThatNeverRuns() throws {
        var j = try step(E2EEnrollment.Journal(), .revoked(deviceID: device))
        j = try committed(reserved(j))
        XCTAssertTrue(try XCTUnwrap(j.job(operationID: op)).stopped)
        XCTAssertTrue(j.pendingJobs.isEmpty)
    }

    func testAnUnrelatedDevicesJobIsUntouched() throws {
        var j = try committed()
        j = try step(j, .revoked(deviceID: other))
        XCTAssertEqual(j.pendingJobs.count, 1)
    }

    // MARK: - §14: the window expires

    func testAnOpenOrReservedWindowClosesAndItsSecretDies() throws {
        for start in [E2EEnrollment.Journal(), try reserved()] {
            let closed = try step(start, .expire)
            XCTAssertEqual(closed.window, .closed)
            XCTAssertFalse(closed.window.secretIsLive)
        }
    }

    /// §14: "erase secret and abort unreserved handshakes; PRESERVE ESTABLISHED ROUTES."
    func testACommittedWindowIsNotTornDownByAnExpiry() throws {
        let after = try step(try committed(), .expire)
        guard case .committed = after.window else { return XCTFail("still committed") }
        XCTAssertTrue(after.mayAcknowledge(operationID: op))
        XCTAssertEqual(after.pendingJobs.count, 1)
    }

    /// A caller writes the RETURNED journal durably; one that mutated in place would already have
    /// changed the state a crash would restart from. Value semantics give this for free in Swift,
    /// which is exactly why the type is a struct — and why that is worth an assertion rather than
    /// an assumption, since the TypeScript mirror has to copy by hand to get the same property.
    func testTheReducerNeverMutatesTheJournalItWasGiven() throws {
        let before = try reserved()
        let snapshot = before
        _ = try committed(before)
        XCTAssertEqual(before, snapshot)
    }
}
