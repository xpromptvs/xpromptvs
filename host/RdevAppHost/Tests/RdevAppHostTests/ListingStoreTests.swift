import XCTest
@testable import RdevAppHost

final class ListingStoreTests: XCTestCase {
    let a = ListingRow(label: "Studio", code: "c1", token: "t1", deviceID: "d1")
    let b = ListingRow(label: "", code: "c2", token: "t2", deviceID: "d2")

    func testTheFirstReadStartsAFetchAndSaysLoading() {
        var s = ListingStore()
        XCTAssertTrue(s.read(refresh: false))
        XCTAssertEqual(s.snapshot.state, .loading)
        XCTAssertFalse(s.read(refresh: true), "a fetch is already in flight")
    }

    func testAFailureKeepsThePreviousRowsMarkedUnreachable() {
        var s = ListingStore()
        _ = s.read(refresh: false); s.store([a], epoch: s.epoch)
        _ = s.read(refresh: true);  s.store(nil, epoch: s.epoch)
        XCTAssertEqual(s.snapshot, Listing(state: .error, error: "unreachable", refreshing: false, rows: [a]))
    }

    func testAFailureWithNothingKnownIsAnEmptyErrorNotLoading() {
        var s = ListingStore()
        _ = s.read(refresh: false); s.store(nil, epoch: s.epoch)
        XCTAssertEqual(s.snapshot, Listing(state: .error, error: "unreachable", refreshing: false, rows: []))
    }

    func testAFetchStartedUnderAForgottenIdentityIsDiscarded() {
        var s = ListingStore()
        _ = s.read(refresh: false)
        let old = s.epoch
        s.forget()
        s.store([a], epoch: old)
        XCTAssertEqual(s.snapshot.state, .loading)
        s.streamed([b], epoch: old)
        XCTAssertEqual(s.snapshot.state, .loading)
    }

    func testALiveStreamAnswersAForcedRefreshWithoutAFetch() {
        var s = ListingStore()
        s.streamed([a], epoch: s.epoch)
        XCTAssertFalse(s.read(refresh: true))
        s.setWatchLive(false)
        XCTAssertTrue(s.read(refresh: true))
        XCTAssertTrue(s.snapshot.refreshing)
    }

    func testDisplayNamesAnUnnamedMacAndDropsRowsWithoutAKey() {
        let keyless = ListingRow(label: "X", code: "c3", token: "", deviceID: "d3")
        let l = Listing(state: .ready, error: "", refreshing: false, rows: [a, b, keyless])
        XCTAssertEqual(l.display.map(\.name), ["Studio", "Unnamed Mac"])
        XCTAssertEqual(l.display.map(\.code), ["c1", "c2"])
    }
}
