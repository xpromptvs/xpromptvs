import XCTest
@testable import RdevCore

/// Where the ceremony runs, resolved from `RDEV_SIGNALING` alone — and the rules that keep the
/// resolved string equal to what a browser would call `location.origin`, since that is the value
/// WebAuthn compares an assertion against.
final class E2EOriginTests: XCTestCase {

    private func resolved(_ base: String, file: StaticString = #filePath,
                          line: UInt = #line) throws -> E2EOrigin.Resolved {
        switch E2EOrigin.resolve(base) {
        case .success(let r): return r
        case .failure(let f):
            XCTFail("expected \(base) to resolve, got \(f.rawValue)", file: file, line: line)
            throw f
        }
    }

    private func failure(_ base: String, file: StaticString = #filePath,
                         line: UInt = #line) -> E2EOrigin.Failure? {
        switch E2EOrigin.resolve(base) {
        case .success(let r):
            XCTFail("expected \(base) to be refused, got \(r.origin)", file: file, line: line)
            return nil
        case .failure(let f): return f
        }
    }

    // MARK: - the origin string

    func testTheOriginIsSpelledTheWayABrowserSpellsIt() throws {
        XCTAssertEqual(try resolved("https://cp.example").origin, "https://cp.example")
        XCTAssertEqual(try resolved("http://localhost:8787").origin, "http://localhost:8787")
        XCTAssertEqual(try resolved("https://cp.example:8443").origin, "https://cp.example:8443")
    }

    /// `https://x:443` and `https://x` are ONE origin to a browser and two strings to the comparison
    /// `verifyAssertion` makes, so a host configured with the explicit port would have every
    /// assertion rejected for a reason nothing in the error would name.
    func testADefaultPortIsAbsentRatherThanSpelledOut() throws {
        XCTAssertEqual(try resolved("https://cp.example:443").origin, "https://cp.example")
        XCTAssertEqual(try resolved("http://localhost:80").origin, "http://localhost")
        XCTAssertEqual(try resolved("http://localhost:8080").origin, "http://localhost:8080",
                       "a non-default port stays")
    }

    func testSchemeAndHostAreLowercased() throws {
        let r = try resolved("HTTPS://CP.Example")
        XCTAssertEqual(r.origin, "https://cp.example")
        XCTAssertEqual(r.rpID, "cp.example")
    }

    /// `URLComponents` strips the brackets an IPv6 literal wears in a URL. Putting them back is what
    /// keeps the origin parseable and equal to the browser's.
    func testAnIPv6LiteralKeepsItsBrackets() throws {
        let r = try resolved("http://[::1]:8787")
        XCTAssertEqual(r.origin, "http://[::1]:8787")
        XCTAssertEqual(r.rpID, "::1")
        XCTAssertEqual(r.url.absoluteString, "http://[::1]:8787")
    }

    func testTheRelyingPartyIsTheHostThePageWouldReport() throws {
        XCTAssertEqual(try resolved("https://cp.example:8443").rpID, "cp.example",
                       "location.hostname carries no port")
    }

    // MARK: - §10.1's policy

    func testThePolicyAcceptsExactlyTheConfiguredOrigin() throws {
        let r = try resolved("https://cp.example")
        XCTAssertEqual(r.policy.rpID, "cp.example")
        XCTAssertEqual(r.policy.allowedOrigins, ["https://cp.example"],
                       "one configured origin, not a list a server can grow")
    }

    // MARK: - the secure-context rule

    /// A browser exposes `navigator.credentials` only in a secure context, so a plaintext LAN origin
    /// cannot run the ceremony at all. Refusing here names the real problem; opening a browser there
    /// would report "unsupported" from inside the page.
    func testPlaintextIsRefusedAnywhereABrowserWouldRefuseIt() {
        XCTAssertEqual(failure("http://192.168.1.5:8787"), .insecure)
        XCTAssertEqual(failure("http://cp.example"), .insecure)
        XCTAssertEqual(failure("http://localhost.evil.example"), .insecure,
                       "a host that merely CONTAINS localhost is not loopback")
        XCTAssertEqual(failure("http://127.0.0.1.evil.example"), .insecure)
    }

    func testEveryLoopbackFormABrowserTrustsIsAccepted() throws {
        for base in ["http://localhost:8787", "http://127.0.0.1:8787", "http://127.1.2.3:8787",
                     "http://[::1]:8787", "http://cp.localhost:8787"] {
            XCTAssertNoThrow(try resolved(base), base)
        }
    }

    /// A browser NORMALISES an abbreviated IPv4 literal — `127.0.0` becomes `127.0.0.0`, and its
    /// `location.origin` says so. This side cannot reproduce that normalisation, so accepting the
    /// short form would produce an origin string the assertion could never match. Refusing it fails
    /// at configuration time instead of at the end of a ceremony.
    func testAnAbbreviatedIPv4LiteralIsRefused() {
        XCTAssertEqual(failure("http://127.0.0:8787"), .insecure)
        XCTAssertEqual(failure("http://127.1:8787"), .insecure)
    }

    func testHTTPSNeedsNoLoopbackExemption() throws {
        XCTAssertNoThrow(try resolved("https://cp.example"))
    }

    // MARK: - what is refused outright

    func testAPathIsRefusedRatherThanDropped() {
        XCTAssertEqual(failure("https://cp.example/control"), .unsupportedPath)
        XCTAssertEqual(failure("https://cp.example?x=1"), .unsupportedPath)
        XCTAssertEqual(failure("https://cp.example#f"), .unsupportedPath)
    }

    func testATrailingSlashIsNotAPath() throws {
        XCTAssertEqual(try resolved("https://cp.example/").origin, "https://cp.example")
    }

    func testMalformedConfigurationIsRefused() {
        XCTAssertEqual(failure(""), .malformed)
        XCTAssertEqual(failure("cp.example"), .malformed, "a bare host names no scheme")
        XCTAssertEqual(failure("ws://cp.example"), .malformed, "the signalling scheme is derived, not configured")
        XCTAssertEqual(failure("file:///etc/passwd"), .malformed)
        XCTAssertEqual(failure("https://user:pw@cp.example"), .malformed,
                       "credentials in the origin would travel into a browser")
    }

    // MARK: - the seam with the rest of the identity

    /// The whole reason the path is refused rather than dropped: the Worker's routes are absolute, and
    /// they agree with the resolved URL only if it has no prefix of its own.
    func testTheResolvedURLCarriesNoPrefixForTheWorkersAbsoluteRoutes() throws {
        let r = try resolved("http://127.0.0.1:8787")
        XCTAssertEqual(r.url.appendingPathComponent("credential").appendingPathComponent("AQ").absoluteString,
                       "http://127.0.0.1:8787/credential/AQ")
    }

    // MARK: - the product's domain

    private struct ProductCase: Decodable {
        let origin: String, rp_id: String, allowed_origins: [String], app_origin: String
    }
    private struct ProductFixture: Decodable {
        let rp_id: String, origins: [String], app_origin: String
        let cases: [ProductCase]
    }

    /// **ONE fixture with the browser** (`web/test/product-origin.test.ts`): a Mac and a browser that
    /// disagreed about which origins a grant may carry would each refuse the other's chain.
    func testTheProductPolicyIsTheSharedFixtures() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/e2e-product-origins.json")
        let f = try JSONDecoder().decode(ProductFixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(E2EOrigin.product.rpID, f.rp_id)
        XCTAssertEqual(E2EOrigin.product.origins, f.origins)
        XCTAssertEqual(E2EOrigin.product.appOrigin, f.app_origin)
        XCTAssertFalse(f.cases.isEmpty)
        for c in f.cases {
            let p = try resolved(c.origin).policy
            XCTAssertEqual(p.rpID, c.rp_id, c.origin)
            XCTAssertEqual(p.allowedOrigins, c.allowed_origins, c.origin)
        }
    }
}
