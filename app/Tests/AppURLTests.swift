import XCTest
@testable import ShellstormCore

final class AppURLTests: XCTestCase {
    let roots = ["ui": URL(fileURLWithPath: "/opt/app/ui"), "client": URL(fileURLWithPath: "/opt/app/web")]
    func r(_ s: String) -> String? { AppURL.resolve(s, roots: roots)?.path }

    func testABareRootServesIndex() {
        XCTAssertEqual(r("app://ui/"), "/opt/app/ui/index.html")
        XCTAssertEqual(r("app://client/"), "/opt/app/web/index.html")
    }
    func testTheHostSelectsTheRoot() {
        XCTAssertEqual(r("app://client/assets/client-abc.js"), "/opt/app/web/assets/client-abc.js")
        XCTAssertEqual(r("app://ui/main.js"), "/opt/app/ui/main.js")
    }
    func testAQueryIsIgnored() { XCTAssertEqual(r("app://client/?code=abc&token=def"), "/opt/app/web/index.html") }
    func testUnknownRootAndSchemeAreRefused() {
        XCTAssertNil(r("app://nope/x")); XCTAssertNil(r("https://example.com/")); XCTAssertNil(r("not a url"))
    }
    /// Foundation does not collapse `..` the way WHATWG URL does, so the CONTAINMENT CHECK is what
    /// refuses this — stricter than the Electron port, which landed it inside the root.
    func testPlainDotDotCannotEscape() { XCTAssertNil(r("app://ui/../../etc/passwd")) }
    func testPercentEncodedTraversalIsRefused() { XCTAssertNil(r("app://ui/%2e%2e%2f%2e%2e%2fetc/passwd")) }
    func testASiblingSharingAPrefixIsNotInside() { XCTAssertNil(r("app://ui/%2e%2e%2fui-evil/x")) }
    func testMimeTypes() {
        XCTAssertEqual(AppURL.mimeType(for: URL(fileURLWithPath: "/a/x.js")), "text/javascript")
        XCTAssertEqual(AppURL.mimeType(for: URL(fileURLWithPath: "/a/x.html")), "text/html")
        XCTAssertEqual(AppURL.mimeType(for: URL(fileURLWithPath: "/a/x.woff2")), "font/woff2")
        XCTAssertEqual(AppURL.mimeType(for: URL(fileURLWithPath: "/a/x.bin")), "application/octet-stream")
    }
}
