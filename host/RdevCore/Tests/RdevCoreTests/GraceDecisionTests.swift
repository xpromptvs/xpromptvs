import XCTest
@testable import RdevCore

final class GraceDecisionTests: XCTestCase {
    func testSuspendEntersGrace() { XCTAssertEqual(graceDecide(held: false, .suspend), .hold) }
    func testDoubleSuspendIgnored() { XCTAssertEqual(graceDecide(held: true, .suspend), .ignore) }
    func testResumeIceRestarts() { XCTAssertEqual(graceDecide(held: true, .resume(.ice)), .restartICE) }
    func testResumeRebuildRebuilds() { XCTAssertEqual(graceDecide(held: true, .resume(.rebuild)), .rebuild) }
    func testResumeWhenNotHeldIsFreshJoin() { XCTAssertEqual(graceDecide(held: false, .resume(.ice)), .freshJoin) }
    func testExpiryWhileHeldTearsDown() { XCTAssertEqual(graceDecide(held: true, .graceExpired), .teardown) }
    func testExpiryWhenNotHeldIgnored() { XCTAssertEqual(graceDecide(held: false, .graceExpired), .ignore) }
}
