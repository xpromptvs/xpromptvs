import XCTest
@testable import ShellstormCore

final class NativeSourceDocumentTests: XCTestCase {
    private let ticket = "B64E009A-2FA9-47A1-AD6A-AFBC838746DE"
    func testOnlyTheActualRemoteOwnerMainDocumentCanPrepareSources() {
        let owner = URL(string: "app://client/index.html?motionDebug=1#pairing")!
        XCTAssertTrue(NativeSourceDocument.permitsOwner(url: owner, mainFrame: true, remoteOwner: true))
        XCTAssertFalse(NativeSourceDocument.permitsOwner(url: owner, mainFrame: false, remoteOwner: true))
        XCTAssertFalse(NativeSourceDocument.permitsOwner(url: owner, mainFrame: true, remoteOwner: false))
        for raw in ["app://ui/index.html", "https://client/index.html", "app://client/source-window.html",
                    "app://client/host.html", "app://client:42/index.html", "app://user@client/index.html",
                    "app://client/%69ndex.html", "about:blank"] {
            XCTAssertFalse(NativeSourceDocument.permitsOwner(url: URL(string: raw), mainFrame: true, remoteOwner: true), raw)
        }
        XCTAssertFalse(NativeSourceDocument.permitsOwner(url: nil, mainFrame: true, remoteOwner: true))
    }

    func testInternalPopupURLContainsOnlyItsOpaqueTicket() throws {
        let url = try XCTUnwrap(NativeSourceDocument.url(ticket: ticket))
        XCTAssertEqual(url.absoluteString, "app://client/source-window.html?ticket=\(ticket)")
        XCTAssertEqual(NativeSourceDocument.ticket(url: url), ticket)
        XCTAssertNil(NativeSourceDocument.url(ticket: "win:42"))
        XCTAssertNil(NativeSourceDocument.url(ticket: ""))
    }

    func testPopupParserRejectsAliasedOriginsPathsAndExtraAuthority() {
        for raw in [
            "https://client/source-window.html?ticket=\(ticket)",
            "app://ui/source-window.html?ticket=\(ticket)",
            "app://client:42/source-window.html?ticket=\(ticket)",
            "app://user@client/source-window.html?ticket=\(ticket)",
            "app://client/%73ource-window.html?ticket=\(ticket)",
            "app://client/source-window.html?ticket=\(ticket)#extra",
            "app://client/source-window.html?ticket=\(ticket)&source=win:42",
            "app://client/source-window.html?ticket=\(ticket)&ticket=\(ticket)",
            "app://client/source-window.html?ticket=not-a-uuid",
            "app://client/source-window.html?ticket=",
            "app://client/source-window.html"
        ] { XCTAssertNil(NativeSourceDocument.ticket(url: URL(string: raw)), raw) }
        XCTAssertNil(NativeSourceDocument.ticket(url: nil))
    }

    func testInvalidPopupDoesNotConsumeTheRealOwnersPendingTicket() throws {
        var tickets = NativeSourceWindowTickets()
        let key = try XCTUnwrap(tickets.prepare(owner: 2, generation: 8, source: "sim:fixture", ticket: ticket))
        let invalid = URL(string: "app://client/source-window.html?ticket=\(ticket)&source=win:42")!
        XCTAssertNil(NativeSourceDocument.ticket(url: invalid))
        XCTAssertEqual(tickets.consume(ticket: ticket, owner: 2, generation: 8), key)
        XCTAssertNil(tickets.consume(ticket: ticket, owner: 2, generation: 8))
    }
}
