import XCTest
@testable import ShellstormCore

/// What a page's `window.open` may hand the default browser: http and https, nothing else.
final class ExternalLinkTests: XCTestCase {
    func testHttpAndHttpsOpen() {
        XCTAssertEqual(ExternalLink.openable(URL(string: "https://example.com/a?b=1#c"))?.absoluteString, "https://example.com/a?b=1#c")
        XCTAssertEqual(ExternalLink.openable(URL(string: "http://localhost:5173/"))?.absoluteString, "http://localhost:5173/")
        XCTAssertNotNil(ExternalLink.openable(URL(string: "HTTPS://EXAMPLE.COM")), "the scheme ignores case")
    }

    func testEverythingElseIsRefused() {
        for s in ["javascript:alert(1)", "file:///etc/passwd", "app://client/index.html", "mailto:a@b.c",
                  "ssh://host", "x-apple.systempreferences:com.apple.preference.security", "https:///nohost"] {
            XCTAssertNil(ExternalLink.openable(URL(string: s)), s)
        }
        XCTAssertNil(ExternalLink.openable(nil))
    }
}
