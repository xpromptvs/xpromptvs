import XCTest
@testable import ShellstormCore

final class NativeSourceWindowTicketsTests: XCTestCase {
    func testTicketIsOneUseAndRequiresItsOwnerAndGeneration() throws {
        var tickets = NativeSourceWindowTickets()
        let key = try XCTUnwrap(tickets.prepare(owner: 1, generation: 7, source: "win:42", ticket: "ticket-a"))
        XCTAssertNil(tickets.consume(ticket: "ticket-a", owner: 2, generation: 7))
        XCTAssertNil(tickets.consume(ticket: "ticket-a", owner: 1, generation: 6))
        XCTAssertFalse(tickets.contains(key))
        XCTAssertEqual(tickets.consume(ticket: "ticket-a", owner: 1, generation: 7), key)
        XCTAssertTrue(tickets.contains(key))
        XCTAssertNil(tickets.consume(ticket: "ticket-a", owner: 1, generation: 7))
    }

    func testIdenticalSourceIDsOnDifferentMacsDoNotCollide() throws {
        var tickets = NativeSourceWindowTickets()
        let a = try XCTUnwrap(tickets.prepare(owner: 1, generation: 1, source: "sim:same-id", ticket: "a"))
        let b = try XCTUnwrap(tickets.prepare(owner: 2, generation: 1, source: "sim:same-id", ticket: "b"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(tickets.consume(ticket: "a", owner: 1, generation: 1), a)
        XCTAssertEqual(tickets.consume(ticket: "b", owner: 2, generation: 1), b)
        tickets.retire(owner: 1, generation: 1)
        XCTAssertFalse(tickets.contains(a))
        XCTAssertTrue(tickets.contains(b))
    }

    func testOwnerRetirementInvalidatesPendingAndActiveWindows() throws {
        var tickets = NativeSourceWindowTickets()
        let active = try XCTUnwrap(tickets.prepare(owner: 1, generation: 3, source: "win:1", ticket: "active"))
        _ = tickets.consume(ticket: "active", owner: 1, generation: 3)
        _ = tickets.prepare(owner: 1, generation: 3, source: "dsp:2", ticket: "pending")
        tickets.retire(owner: 1, generation: 3)
        XCTAssertFalse(tickets.contains(active))
        XCTAssertNil(tickets.consume(ticket: "pending", owner: 1, generation: 3))
        XCTAssertNil(tickets.prepare(owner: 1, generation: 3, source: "win:9", ticket: "late"))
        XCTAssertNotNil(tickets.prepare(owner: 1, generation: 4, source: "win:1", ticket: "new-generation"))
    }

    func testRetiringBeforeTheFirstWindowPreventsLateCreation() {
        var tickets = NativeSourceWindowTickets()
        tickets.retire(owner: 1, generation: 4)
        XCTAssertNil(tickets.prepare(owner: 1, generation: 4, source: "win:1", ticket: "late"))
        XCTAssertNil(tickets.prepare(owner: 1, generation: 3, source: "win:1", ticket: "older"))
        XCTAssertNotNil(tickets.prepare(owner: 1, generation: 5, source: "win:1", ticket: "next"))
    }

    func testAdvancingAnOwnerGenerationRetiresOldTicketsWithoutTouchingOtherOwners() throws {
        var tickets = NativeSourceWindowTickets()
        let old = try XCTUnwrap(tickets.prepare(owner: 1, generation: 1, source: "win:1", ticket: "old"))
        let other = try XCTUnwrap(tickets.prepare(owner: 2, generation: 1, source: "win:1", ticket: "other"))
        _ = tickets.consume(ticket: "other", owner: 2, generation: 1)
        _ = tickets.prepare(owner: 1, generation: 2, source: "win:1", ticket: "new")
        XCTAssertNil(tickets.consume(ticket: "old", owner: 1, generation: 1))
        XCTAssertFalse(tickets.contains(old))
        XCTAssertTrue(tickets.contains(other))
        tickets.retire(owner: 1, generation: 1) // A late old-owner callback cannot retire generation 2.
        XCTAssertNotNil(tickets.consume(ticket: "new", owner: 1, generation: 2))
    }

    func testStaleCloseCannotRetireANewerSourceIncarnation() throws {
        var tickets = NativeSourceWindowTickets()
        let old = try XCTUnwrap(tickets.prepare(owner: 1, generation: 1, source: "win:1", ticket: "first"))
        _ = tickets.consume(ticket: "first", owner: 1, generation: 1)
        tickets.retire(key: old)
        let next = try XCTUnwrap(tickets.prepare(owner: 1, generation: 1, source: "win:1", ticket: "second"))
        XCTAssertGreaterThan(next.incarnation, old.incarnation)
        _ = tickets.consume(ticket: "second", owner: 1, generation: 1)
        tickets.retire(key: old)
        XCTAssertTrue(tickets.contains(next))
        XCTAssertFalse(tickets.contains(old))
    }

    func testDuplicatePreparationCannotCreateTwoWindowsOrReuseAnIssuedTicket() throws {
        var tickets = NativeSourceWindowTickets()
        let key = try XCTUnwrap(tickets.prepare(owner: 1, generation: 1, source: "win:1", ticket: "first"))
        XCTAssertNil(tickets.prepare(owner: 1, generation: 1, source: "win:1", ticket: "duplicate"))
        XCTAssertNil(tickets.consume(ticket: "duplicate", owner: 1, generation: 1))
        _ = tickets.consume(ticket: "first", owner: 1, generation: 1)
        XCTAssertNil(tickets.prepare(owner: 1, generation: 1, source: "win:1", ticket: "still-active"))
        tickets.retire(key: key)
        XCTAssertNil(tickets.prepare(owner: 1, generation: 1, source: "win:1", ticket: "first"))
        XCTAssertNotNil(tickets.prepare(owner: 1, generation: 1, source: "win:1", ticket: "fresh"))
    }

    func testRetiringPendingSourceInvalidatesItsTicketOnly() throws {
        var tickets = NativeSourceWindowTickets()
        let a = try XCTUnwrap(tickets.prepare(owner: 1, generation: 1, source: "win:1", ticket: "a"))
        let b = try XCTUnwrap(tickets.prepare(owner: 1, generation: 1, source: "dsp:2", ticket: "b"))
        tickets.retire(key: a)
        XCTAssertNil(tickets.consume(ticket: "a", owner: 1, generation: 1))
        XCTAssertEqual(tickets.consume(ticket: "b", owner: 1, generation: 1), b)
    }
}
