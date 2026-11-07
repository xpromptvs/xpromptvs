import XCTest
@testable import ShellstormCore

final class ConnectErrorTests: XCTestCase {
    let generic = "Could not connect. Check the session window for details."
    func testClientTextIsSentenceCased() {
        XCTAssertEqual(ConnectError.message(.client(text: "host left")), "Host left")
        XCTAssertEqual(ConnectError.message(.client(text: "  wss://x failed ")), "Wss://x failed")
    }
    func testAClientWithNoTextKeepsTheGenericSentence() {
        XCTAssertEqual(ConnectError.message(.client(text: nil)), generic)
        XCTAssertEqual(ConnectError.message(.client(text: "   ")), generic)
    }
    func testALoadFailureNamesTheErrorAndNeverSendsYouToTheBlankWindow() {
        let m = ConnectError.message(.load(domain: "NSURLErrorDomain", code: -1100, description: "The requested URL was not found on this server."))
        XCTAssertEqual(m, "The session window could not load (The requested URL was not found on this server.).")
        XCTAssertEqual(ConnectError.message(.load(domain: "WebKitErrorDomain", code: 102, description: nil)),
                       "The session window could not load (WebKitErrorDomain error 102).")
        XCTAssertNotEqual(m, generic)
    }
    func testClosedAndGone() {
        XCTAssertEqual(ConnectError.message(.closed), "Connection closed.")
        XCTAssertEqual(ConnectError.message(.gone), "The session window stopped. Try connecting again.")
    }
}
