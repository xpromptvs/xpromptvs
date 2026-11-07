import XCTest
@testable import ShellstormCore

/// `__rdevShell.request`'s allow-list. The page is on the other side of this boundary, so every
/// refusal is as much the product as every route: this must never become a proxy onto the LAN or
/// another origin.
final class WorkerRequestTests: XCTestCase {
    let root = String(repeating: "A", count: 42) + "_"          // 43 base64url characters
    let cred = "oQ98Kw"

    func testEachAllowedRoute() {
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/directory/\(root)/challenge"),
                       .success(.directoryChallenge(root: root)))
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/directory/\(root)/register"),
                       .success(.directoryRegister(root: root)))
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/directory/\(root)/list"),
                       .success(.directoryList(root: root)))
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/credential/\(cred)"),
                       .success(.credential(id: cred)))
        XCTAssertEqual(WorkerRequest.Route.directoryList(root: root).path, "/directory/\(root)/list")
        XCTAssertEqual(WorkerRequest.Route.credential(id: cred).method, "GET")
    }

    func testTheURLIsAlwaysTheSignallingOriginPlusTheRoutesOwnPath() {
        let url = WorkerRequest.url(base: "http://localhost:8787", route: .directoryList(root: root))
        XCTAssertEqual(url?.absoluteString, "http://localhost:8787/directory/\(root)/list")
        // A base that is not http(s) is no Worker.
        XCTAssertNil(WorkerRequest.url(base: "file:///etc", route: .credential(id: cred)))
        XCTAssertNil(WorkerRequest.url(base: "app://client", route: .credential(id: cred)))
        // A hand-built Route with junk in it is ENCODED into the path, never a query, never a trap.
        let odd = WorkerRequest.url(base: "http://localhost:8787", route: .credential(id: "a?b#c/../d"))
        XCTAssertNil(odd?.query); XCTAssertNil(odd?.fragment)
        XCTAssertEqual(odd?.host, "localhost")
        // The base's own path, query and credentials are dropped: only scheme, host and port survive.
        XCTAssertEqual(WorkerRequest.url(base: "https://u:p@cp.test:444/x?y", route: .credential(id: cred))?.absoluteString,
                       "https://cp.test:444/credential/\(cred)")
    }

    func testPublishIsNotOnTheListTheClientNeverPublishes() {
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/directory/\(root)/publish"), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/directory/\(root)/records"), .failure(.path))
    }

    func testAnotherOriginOrAnAbsoluteURLIsRefused() {
        for p in ["http://evil.test/credential/\(cred)", "https://127.0.0.1/credential/\(cred)",
                  "//evil.test/credential/\(cred)", "credential/\(cred)", "", "/"] {
            XCTAssertNotNil(WorkerRequest.validate(method: "GET", path: p).failureValue, p)
        }
    }

    func testTraversalAndEncodedSeparatorsAreRefused() {
        for p in ["/credential/..", "/credential/../health", "/directory/\(root)/../list",
                  "/credential/a%2Fb", "/credential/a%2fb", "/credential/%2e%2e", "/credential/a/b",
                  "/credential/\(cred)/", "/directory/\(root)//list", "/credential/a\\b"] {
            XCTAssertNotNil(WorkerRequest.validate(method: "GET", path: p).failureValue, p)
            XCTAssertNotNil(WorkerRequest.validate(method: "POST", path: p).failureValue, p)
        }
    }

    func testAQueryOrAFragmentIsRefused() {
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/credential/\(cred)?x=1"), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/directory/\(root)/list?"), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/credential/\(cred)#x"), .failure(.path))
    }

    func testBadCharsetAndBadLengthAreRefused() {
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/directory/\(String(root.dropLast()))/list"), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/directory/\(root)A/list"), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/directory/\(String(root.dropLast()))=/list"), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/credential/abc"), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/credential/" + String(repeating: "a", count: 345)), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/credential/" + String(repeating: "a", count: 344)),
                       .success(.credential(id: String(repeating: "a", count: 344))))
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/credential/ab+/"), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/credential/ab cd"), .failure(.path))
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/credential/ÄÄÄÄ"), .failure(.path))
    }

    func testUnknownPathsAreRefused() {
        for p in ["/health", "/pair", "/turn-creds", "/enroll", "/session/abc", "/index.html",
                  "/directory/\(root)", "/directory/\(root)/watch", "/credentials/\(cred)"] {
            XCTAssertEqual(WorkerRequest.validate(method: "GET", path: p), .failure(.path), p)
            XCTAssertEqual(WorkerRequest.validate(method: "POST", path: p), .failure(.path), p)
        }
    }

    func testTheWrongMethodIsRefused() {
        XCTAssertEqual(WorkerRequest.validate(method: "GET", path: "/directory/\(root)/list"), .failure(.method))
        XCTAssertEqual(WorkerRequest.validate(method: "PUT", path: "/directory/\(root)/register"), .failure(.method))
        XCTAssertEqual(WorkerRequest.validate(method: "POST", path: "/credential/\(cred)"), .failure(.method))
        XCTAssertEqual(WorkerRequest.validate(method: "DELETE", path: "/credential/\(cred)"), .failure(.method))
        XCTAssertEqual(WorkerRequest.validate(method: "post", path: "/directory/\(root)/list"), .failure(.method),
                       "methods are compared exactly — the page's helper upper-cases them")
    }

    func testBodiesAreBoundedAndAGETCarriesNone() {
        let list = WorkerRequest.Route.directoryList(root: root)
        XCTAssertNil(WorkerRequest.checkBody(nil, route: list))
        XCTAssertNil(WorkerRequest.checkBody(String(repeating: "x", count: WorkerRequest.maxRequestBody), route: list))
        XCTAssertEqual(WorkerRequest.checkBody(String(repeating: "x", count: WorkerRequest.maxRequestBody + 1), route: list),
                       .bodyTooLarge)
        // Counted in UTF-8 BYTES, which is what goes on the wire.
        XCTAssertEqual(WorkerRequest.checkBody(String(repeating: "é", count: WorkerRequest.maxRequestBody / 2 + 1), route: list),
                       .bodyTooLarge)
        XCTAssertEqual(WorkerRequest.checkBody("{}", route: .credential(id: cred)), .bodyNotAllowed)
        XCTAssertNil(WorkerRequest.checkBody(nil, route: .credential(id: cred)))
        XCTAssertEqual(WorkerRequest.maxRequestBody, 64 * 1024)
        XCTAssertEqual(WorkerRequest.maxResponseBody, 1024 * 1024)
    }

    // Redirect refusal and the 1 MiB response cap are TRANSPORT behaviour (`WorkerHTTP`), proven
    // against a real server in `e2e/app-worker-request-check.mjs`'s transport arm, not here.
}

extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f }; return nil }
}
