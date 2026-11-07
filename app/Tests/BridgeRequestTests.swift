import XCTest
@testable import ShellstormCore

final class BridgeRequestTests: XCTestCase {
    func testMalformedBodiesAreRefused() {
        XCTAssertNil(BridgeRequest(body: "state"))
        XCTAssertNil(BridgeRequest(body: ["args": []]))
        XCTAssertNil(BridgeRequest(body: ["op": ""]))
        XCTAssertNil(BridgeRequest(body: ["op": String(repeating: "x", count: 65)]))
        XCTAssertNil(BridgeRequest(body: ["op": "x", "args": Array(repeating: 1, count: 9)]))
    }
    func testTypedArgumentsRefuseTheWrongType() {
        let r = BridgeRequest(body: ["op": "x", "args": [NSNumber(value: 1), "s", NSNumber(value: true), NSNull()]])!
        XCTAssertNil(r.string(0)); XCTAssertEqual(r.string(1), "s"); XCTAssertNil(r.string(9))
        XCTAssertFalse(r.bool(0), "a number 1 is not true"); XCTAssertTrue(r.bool(2)); XCTAssertFalse(r.bool(3))
        XCTAssertTrue(r.isNull(3)); XCTAssertFalse(r.isNull(1)); XCTAssertFalse(r.isNull(9), "absent is not null")
    }
    /// A list of strings — the paths a paste prepares, the urls it discards — bounded like everything a page sends:
    /// at most 32 (a delivery's items), each at most 4096 UTF-16 units, every element a string.
    func testStringsIsAListOfStringsOrNothing() {
        XCTAssertEqual(BridgeRequest(body: ["op": "x", "args": [["/a", "/b c"]]])?.strings(0), ["/a", "/b c"])
        XCTAssertEqual(BridgeRequest(body: ["op": "x", "args": [[String]()]])?.strings(0), [])
        XCTAssertNil(BridgeRequest(body: ["op": "x", "args": [["/a", 3] as [Any]]])?.strings(0))
        XCTAssertNil(BridgeRequest(body: ["op": "x", "args": ["/a"]])?.strings(0))
        XCTAssertNil(BridgeRequest(body: ["op": "x", "args": [Any]()])?.strings(0))
        XCTAssertNil(BridgeRequest(body: ["op": "x", "args": [Array(repeating: "a", count: 33)]])?.strings(0))
        XCTAssertNil(BridgeRequest(body: ["op": "x", "args": [[String(repeating: "a", count: 4097)]]])?.strings(0))
        XCTAssertEqual(BridgeRequest(body: ["op": "x", "args": [[String(repeating: "a", count: 4096)]]])?.strings(0)?.count, 1)
    }

    /// A count (`setBell`): a JS NUMBER that is a whole number inside the range — never a Bool (which WebKit also
    /// hands over as an NSNumber), a string, a fraction, NaN or one outside it.
    func testIntIsAWholeNumberInRangeOrNothing() {
        let r = BridgeRequest(body: ["op": "x", "args": [NSNumber(value: 3), NSNumber(value: 3.0), NSNumber(value: 2.5),
                                                         NSNumber(value: true), "3", NSNumber(value: -1),
                                                         NSNumber(value: 1000), NSNumber(value: Double.nan)]])!
        XCTAssertEqual(r.int(0, in: 0...999), 3)
        XCTAssertEqual(r.int(1, in: 0...999), 3, "JS has one number type: 3.0 is 3")
        XCTAssertNil(r.int(2, in: 0...999))
        XCTAssertNil(r.int(3, in: 0...999), "true is not 1")
        XCTAssertNil(r.int(4, in: 0...999))
        XCTAssertNil(r.int(5, in: 0...999))
        XCTAssertNil(r.int(6, in: 0...999))
        XCTAssertNil(r.int(7, in: 0...999))
        XCTAssertNil(r.int(9, in: 0...999), "absent")
        XCTAssertNil(BridgeRequest(body: ["op": "x", "args": [NSNumber(value: 1e300)]])!.int(0, in: 0...999))
    }

    func testMotionTakesOnlyLiteralTrues() {
        let r = BridgeRequest(body: ["op": "x", "args": [["debug": NSNumber(value: true), "slow": "yes", "reduced": NSNumber(value: true)], "nope"]])!
        XCTAssertEqual(r.motion(0), Motion(debug: true, slow: false))
        XCTAssertNil(r.motion(1))
    }
    /// The Electron handler bounded a pairing with JS `pairing.slice(0, 4096)` — UTF-16 CODE UNITS,
    /// not Swift Characters (a grapheme cluster can be many units).
    func testPairingIsBoundedInUTF16UnitsLikeJSSlice() {
        let short = BridgeRequest(body: ["op": "openClient", "args": ["AAAA"]])!
        XCTAssertEqual(short.pairing(0), "AAAA")
        XCTAssertNil(BridgeRequest(body: ["op": "openClient", "args": [NSNumber(value: 1)]])!.pairing(0))

        let exact = String(repeating: "a", count: 4096)
        XCTAssertEqual(BridgeRequest(body: ["op": "openClient", "args": [exact + "b"]])!.pairing(0), exact)

        // 4096 emoji are 4096 Characters but 8192 units: JS keeps 2048 of them.
        let emoji = String(repeating: "😀", count: 4096)
        let bounded = BridgeRequest(body: ["op": "openClient", "args": [emoji]])!.pairing(0)!
        XCTAssertEqual(bounded.utf16.count, 4096)
        XCTAssertEqual(bounded, String(repeating: "😀", count: 2048))

        // A non-BMP character straddling the boundary: JS would keep a LONE high surrogate, which
        // `encodeURIComponent` then throws on. A Swift String cannot hold one, so the half pair is
        // DROPPED — never replaced with U+FFFD, never allowed to push the result past 4096 units.
        let straddle = String(repeating: "a", count: 4095) + "😀"
        let cut = BridgeRequest(body: ["op": "openClient", "args": [straddle]])!.pairing(0)!
        XCTAssertEqual(cut, String(repeating: "a", count: 4095))
        XCTAssertFalse(cut.unicodeScalars.contains("\u{FFFD}"))
    }
    func testClientURLMatchesWindowsTs() {
        XCTAssertEqual(ClientURL.make(pairing: nil, motion: nil), "app://client/index.html")
        // Smooth scrolling is NOT handed over in the URL: the app keeps it natively and every window reads it.
        XCTAssertEqual(ClientURL.make(pairing: "a b&c", motion: Motion(debug: true, slow: true)),
                       "app://client/index.html?debug=1&motionSlow=1#pairing=a%20b%26c")
        XCTAssertEqual(ClientURL.make(pairing: nil, motion: Motion(debug: false, slow: true)),
                       "app://client/index.html")
    }

    /// "This Mac" (docs/desktop-app.md, "The local window"): the client window routed to a socket to the
    /// app's own host — no pairing, the page's own motion preferences after the route.
    func testTheLocalWindowsURL() {
        XCTAssertEqual(ClientURL.local(motion: nil), "app://client/index.html?local=1")
        XCTAssertEqual(ClientURL.local(motion: Motion(debug: true, slow: true)),
                       "app://client/index.html?local=1&debug=1&motionSlow=1")
    }
}
