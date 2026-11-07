import XCTest
@testable import RdevCore

final class SourceInputRouteTests: XCTestCase {
    func testNoRouteWithoutCurrentOwnerOrBeforeCommit() throws {
        var route = SourceInputRoute()
        XCTAssertNil(route.intend(source: "win:1", revision: 1, request: "a"))
        route.setOwner("driver")
        let a = try XCTUnwrap(route.intend(source: "win:1", revision: 1, request: "a"))
        XCTAssertFalse(route.permits(owner: "driver", source: "win:1", lease: "lease-a"))
        XCTAssertTrue(route.commit(a, lease: "lease-a"))
        XCTAssertTrue(route.permits(owner: "driver", source: "win:1", lease: "lease-a"))
        XCTAssertFalse(route.permits(owner: "other", source: "win:1", lease: "lease-a"))
        XCTAssertFalse(route.permits(owner: "driver", source: "win:2", lease: "lease-a"))
        XCTAssertFalse(route.permits(owner: "driver", source: "win:1", lease: "wrong"))
    }

    func testNewIntentImmediatelyFencesOldInputAndRejectsItsLateCommit() throws {
        var route = SourceInputRoute(); route.setOwner("driver")
        let a = try XCTUnwrap(route.intend(source: "win:1", revision: 1, request: "a"))
        _ = route.commit(a, lease: "a")
        let b = try XCTUnwrap(route.intend(source: "win:2", revision: 2, request: "b"))
        XCTAssertFalse(route.permits(owner: "driver", source: "win:1", lease: "a"))
        XCTAssertFalse(route.commit(a, lease: "late-a"))
        XCTAssertTrue(route.commit(b, lease: "b"))
    }

    func testABACannotReviveOldInputOrABlockedFocusCommit() throws {
        var route = SourceInputRoute(); route.setOwner("driver")
        let a1 = try XCTUnwrap(route.intend(source: "win:1", revision: 1, request: "a1"))
        _ = route.commit(a1, lease: "a1")
        let b = try XCTUnwrap(route.intend(source: "win:2", revision: 2, request: "b"))
        let a3 = try XCTUnwrap(route.intend(source: "win:1", revision: 3, request: "a3"))
        XCTAssertFalse(route.commit(b, lease: "late-b"))
        XCTAssertFalse(route.commit(a1, lease: "late-a1"))
        XCTAssertTrue(route.commit(a3, lease: "a3"))
        XCTAssertFalse(route.permits(owner: "driver", source: "win:1", lease: "a1"))
        XCTAssertTrue(route.permits(owner: "driver", source: "win:1", lease: "a3"))
    }

    func testOlderHostRevisionCannotReplaceCurrentIntent() throws {
        var route = SourceInputRoute(); route.setOwner("driver")
        let b = try XCTUnwrap(route.intend(source: "win:2", revision: 9, request: "b"))
        _ = route.commit(b, lease: "b")
        XCTAssertNil(route.intend(source: "win:1", revision: 8, request: "old"))
        XCTAssertNil(route.intend(source: "win:1", revision: 9, request: "conflicting"))
        XCTAssertTrue(route.permits(owner: "driver", source: "win:2", lease: "b"))
    }

    func testSameInjectorRecommitAndRepeatedIntentKeepItsLease() throws {
        var route = SourceInputRoute(); route.setOwner("driver")
        let a = try XCTUnwrap(route.intend(source: "win:1", revision: 1, request: "a"))
        _ = route.commit(a, lease: "a")
        XCTAssertEqual(route.intend(source: "win:1", revision: 1), a)
        XCTAssertEqual(route.intend(source: "win:1", revision: 1, request: "a"), a)
        XCTAssertTrue(route.commit(a, lease: "a"))
        XCTAssertTrue(route.permits(owner: "driver", source: "win:1", lease: "a"))
    }

    func testNewNativeActivationAtSameHostRevisionNeedsANewLease() throws {
        var route = SourceInputRoute(); route.setOwner("driver")
        let first = try XCTUnwrap(route.intend(source: "sim:A", revision: 1, request: "first"))
        _ = route.commit(first, lease: "first")
        let next = try XCTUnwrap(route.intend(source: "sim:A", revision: 1, request: "new-window"))
        XCTAssertNotEqual(first, next)
        XCTAssertFalse(route.commit(first, lease: "late"))
        XCTAssertFalse(route.permits(owner: "driver", source: "sim:A", lease: "first"))
        XCTAssertTrue(route.commit(next, lease: "new"))
    }

    func testOwnerABAOrReadmissionInvalidatesOldTicketsEvenWithSameSourceAndRequest() throws {
        var route = SourceInputRoute(); route.setOwner("a")
        let old = try XCTUnwrap(route.intend(source: "win:1", revision: 1, request: "same"))
        _ = route.commit(old, lease: "old")
        route.setOwner("b"); route.setOwner("a")
        let next = try XCTUnwrap(route.intend(source: "win:1", revision: 1, request: "same"))
        XCTAssertNotEqual(old, next)
        XCTAssertFalse(route.commit(old, lease: "late"))
        XCTAssertTrue(route.commit(next, lease: "new"))
        route.setOwner(nil)
        XCTAssertFalse(route.permits(owner: "a", source: "win:1", lease: "new"))
        XCTAssertFalse(route.commit(next, lease: "too-late"))
    }

    func testNoInputRouteForTerminalAndNoReuseOfAnIssuedLease() throws {
        var route = SourceInputRoute(); route.setOwner("driver")
        let a = try XCTUnwrap(route.intend(source: "win:1", revision: 1, request: "a"))
        _ = route.commit(a, lease: "issued")
        let terminal = try XCTUnwrap(route.intend(source: nil, revision: 2))
        XCTAssertFalse(route.commit(terminal, lease: "terminal"))
        XCTAssertFalse(route.permits(owner: "driver", source: "win:1", lease: "issued"))
        let next = try XCTUnwrap(route.intend(source: "win:1", revision: 3, request: "next"))
        XCTAssertFalse(route.commit(next, lease: "issued"))
        XCTAssertFalse(route.commit(next, lease: ""))
        XCTAssertTrue(route.commit(next, lease: "new"))
    }
}
