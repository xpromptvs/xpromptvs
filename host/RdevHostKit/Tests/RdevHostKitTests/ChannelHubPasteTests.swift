import CoreVideo
import XCTest
import RdevCore
@testable import RdevHostKit

private final class NullEncoder: VideoEncoding, @unchecked Sendable {
    var codec: NegotiatedCodec { .av1 }
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {}
    func addSink(_ s: any VideoTrackSink) {}
    func removeSink(_ s: any VideoTrackSink) {}
    func removeAllSinks() {}
    func requestKeyframe() {}
    func setFps(_ v: Int) {}
    func setBitrate(_ v: Int) {}
    func setCrop(_ v: CropRect) {}
    func invalidate() {}
}

/// **WHO MAY PASTE** (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §3, §7): the driver only, on
/// its CURRENT connection; a delivery is abandoned when its client loses control (told `not-driver`), leaves,
/// or has its connection rebuilt. The hub's REAL entry points with window-less connections (a terminal paste is
/// permitted to one), a real `PasteReceiver` on a temporary folder, and a terminal destination that records.
final class ChannelHubPasteTests: XCTestCase {
    private final class Typed: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [([String], TermTabID)] = []
        func add(_ p: [String], _ t: TermTabID) { lock.withLock { all.append((p, t)) } }
        var count: Int { lock.withLock { all.count } }
    }

    private var dir: URL!
    private var hub: ChannelHub!
    private var rx: PasteReceiver!
    private var typed: Typed!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-paste-\(UUID().uuidString)")
        hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullEncoder(),
                         terminalPauseHold: .milliseconds(50))
        let store = PasteStore(directory: dir); store.prepareAtLaunch()
        let t = Typed(); typed = t
        rx = PasteReceiver(store: store, destinations: .init(
            typeIntoTerminal: { pieces, tab in t.add(pieces, tab); return true },
            windowTarget: { _ in nil },
            writePasteboard: { _, done in done(false) },
            drop: { _, _, _, _, done in done(false) }),
            reply: { [weak hub] data, id in hub?.sendBulk(data, to: id) })
        hub.paste = rx
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func join(_ id: String, claim: Bool = false) -> WindowlessConnection {
        let c = WindowlessConnection(id)
        hub.register(clientId: id, peer: c, claim: claim)
        hub.connection(c, didOpen: .control)
        return c
    }
    private func send(_ c: ClientConnection, _ json: String) {
        hub.connection(c, didReceive: wrapMessage(Data(json.utf8)), on: .bulk)
    }
    private func begin(_ c: ClientConnection, _ id: String, size: Int = 3) {
        send(c, #"{"t":"paste-begin","id":"\#(id)","to":{"term":"pty:1"},"items":[{"kind":"file","name":"a.txt","type":"text/plain","size":\#(size)}]}"#)
    }
    private func data(_ c: ClientConnection, _ id: String, _ bytes: String = "YWJj") {
        send(c, #"{"t":"paste-data","id":"\#(id)","item":0,"seq":0,"data":"\#(bytes)"}"#)
    }
    private func end(_ c: ClientConnection, _ id: String) { send(c, #"{"t":"paste-end","id":"\#(id)"}"#) }
    /// What the hub sent `c` about pastes, as `"<t> <id>"` and its `reason` or `how` when it has one.
    private func pasteReplies(_ c: WindowlessConnection) -> [String] {
        c.bulkMessages.compactMap { m in
            guard let o = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: String],
                  let t = o["t"], t.hasPrefix("paste-") else { return nil }
            return [t, o["id"] ?? "", o["reason"] ?? o["how"]].compactMap { $0 }.joined(separator: " ")
        }
    }
    private func files() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] }

    /// THE PASTE PROTOCOL RIDES `bulk`, replies included — never `control`, which the lane carries
    /// (docs/superpowers/specs/2026-10-12-terminal-lane-design.md, "Decisions" 2).
    func testPasteRepliesGoOnBulkNotControl() {
        let a = join("sock:a", claim: true)
        begin(a, "p1"); rx.drain()
        XCTAssertTrue(pasteReplies(a).contains("paste-accepted p1"))
        XCTAssertFalse(a.controlMessages.contains { $0.contains("paste-") }, "a paste reply went out on control")
    }

    func testTheDriverPastesIntoATerminal() {
        let a = join("sock:a")
        begin(a, "p1"); data(a, "p1"); end(a, "p1"); rx.drain()
        XCTAssertEqual(pasteReplies(a), ["paste-accepted p1", "paste-done p1 paste"])
        XCTAssertEqual(typed.count, 1)
    }

    /// A passive client's `paste-begin` and `paste-end` are answered `not-driver`; its data reaches nothing.
    func testAPassiveClientIsNotTheDriver() {
        _ = join("sock:a")
        let b = join("sock:b")
        begin(b, "p1"); data(b, "p1"); end(b, "p1"); rx.drain()
        XCTAssertEqual(pasteReplies(b), ["paste-error p1 not-driver", "paste-error p1 not-driver"])
        XCTAssertEqual(files(), [], "nothing was opened for it")
        XCTAssertEqual(typed.count, 0)
    }

    /// A CLAIM BY ANOTHER CLIENT abandons the old driver's open delivery — its partial deleted — and tells it
    /// `not-driver`; what it sends after is a passive client's.
    func testAClaimAbandonsTheOldDriversDeliveryWithNotDriver() {
        let a = join("sock:a")
        let b = join("sock:b")
        begin(a, "p1", size: 6); data(a, "p1"); rx.drain()
        XCTAssertEqual(files().count, 1, "precondition: a partial on disk")
        send(b, #"{"t":"claim-control"}"#)
        rx.drain()
        XCTAssertEqual(pasteReplies(a), ["paste-accepted p1", "paste-error p1 not-driver"])
        XCTAssertEqual(files(), [])
        end(a, "p1"); rx.drain()
        XCTAssertEqual(pasteReplies(a), ["paste-accepted p1", "paste-error p1 not-driver", "paste-error p1 not-driver"])
        XCTAssertEqual(typed.count, 0)
        begin(b, "p2"); data(b, "p2"); end(b, "p2"); rx.drain()
        XCTAssertEqual(pasteReplies(b), ["paste-accepted p2", "paste-done p2 paste"], "the new driver pastes")
    }

    /// A client that LEAVES takes its delivery with it, in silence (there is nobody to tell).
    func testLeavingAbandonsInSilence() {
        let a = join("sock:a")
        begin(a, "p1", size: 6); data(a, "p1"); rx.drain()
        hub.unregister(clientId: a.clientId)
        rx.drain()
        XCTAssertEqual(files(), [])
        XCTAssertEqual(pasteReplies(a), ["paste-accepted p1"], "nothing after its acceptance")
    }

    /// A REBUILT CONNECTION abandons its client's delivery — the uploader failed with the old channel and must
    /// not find itself `busy` on the new one — and the connection it replaced speaks for nobody: a straggler
    /// from it opens nothing and gets no answer (which could only reach the NEW connection).
    func testARebuildAbandonsAndTheReplacedConnectionSpeaksForNobody() {
        let old = join("sock:a")
        begin(old, "p1", size: 6); data(old, "p1"); rx.drain()
        let new = WindowlessConnection("sock:a")
        hub.rebindPeer(clientId: "sock:a", peer: new)
        hub.connection(new, didOpen: .control)
        rx.drain()
        XCTAssertEqual(files(), [], "the old delivery is gone")
        begin(old, "p2"); data(old, "p2"); end(old, "p2"); rx.drain()
        XCTAssertEqual(pasteReplies(old), ["paste-accepted p1"], "only p1's acceptance, from before the rebuild")
        XCTAssertEqual(pasteReplies(new), [])
        XCTAssertEqual(files(), [])
        begin(new, "p3"); data(new, "p3"); end(new, "p3"); rx.drain()
        XCTAssertEqual(pasteReplies(new), ["paste-accepted p3", "paste-done p3 paste"], "not busy: the new connection pastes at once")
        XCTAssertEqual(typed.count, 1)
    }
}
