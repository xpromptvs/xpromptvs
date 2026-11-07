import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
import RdevCore
@testable import RdevHostKit

/// THE HOST'S HALF OF AN IMAGE PATH OPENING ON THE CLIENT (docs/terminal.md, "An image path opens on the client"):
/// real files in a temporary folder — the path resolved against its tab's directory, the image sent whole in order, a
/// TIFF converted to JPEG, and every way it is refused — and the hub's gate: the driver's only.
final class FileFetcherTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-fetch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("shots"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A 3×2 image, written as `type`.
    private func image(_ name: String, _ type: UTType) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let img = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try (out as Data).write(to: dir.appendingPathComponent(name))
        return out as Data
    }

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String: Any]] = []
        func add(_ d: Data) { if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { lock.withLock { all.append(o) } } }
        var messages: [[String: Any]] { lock.withLock { all } }
    }
    /// What the fetcher sends for `path`, asked from tab `pty:1` whose directory is the temporary folder.
    private func fetch(_ path: String, maxBytes: Int = FileFetch.maxBytes, directory: String? = nil) -> [[String: Any]] {
        let d = directory ?? dir.path
        let f = FileFetcher(directory: { _ in d }, home: dir.path, maxBytes: maxBytes)
        let sent = Sent(), done = expectation(description: "answered")
        f.fetch(FileGet(id: "f1", term: .pty(1), path: path), send: { data in
            sent.add(data)
            if let t = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["t"] as? String,
               t == "file-end" || t == "file-error" { done.fulfill() }
        })
        wait(for: [done], timeout: 5)
        return sent.messages
    }
    private func bytes(_ m: [[String: Any]]) -> Data {
        m.filter { $0["t"] as? String == "file-data" }.sorted { ($0["seq"] as! Int) < ($1["seq"] as! Int) }
            .reduce(into: Data()) { $0.append(Data(base64Encoded: $1["data"] as! String)!) }
    }

    func testAnImageIsSentWholeInOrderUnderItsTabsDirectory() throws {
        let png = try image("shots/a.png", .png)
        for path in ["shots/a.png", "./shots/a.png", "~/shots/a.png", dir.appendingPathComponent("shots/a.png").path] {
            let m = fetch(path)
            XCTAssertEqual(m.first?["t"] as? String, "file-begin", path)
            XCTAssertEqual(m.first?["mime"] as? String, "image/png")
            XCTAssertEqual(m.first?["name"] as? String, "a.png")
            XCTAssertEqual(m.first?["size"] as? Int, png.count)
            XCTAssertEqual(m.last?["t"] as? String, "file-end")
            XCTAssertEqual(bytes(m), png, "the file, byte for byte")
        }
    }

    func testABigImageGoesInPiecesInOrder() throws {
        // Bytes that do not compress, named .png: a type shown as it is, which the host sends without decoding.
        var noise = Data(count: FileFetch.chunkBytes * 3 + 17)
        for i in noise.indices { noise[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        try noise.write(to: dir.appendingPathComponent("big.png"))
        let m = fetch("big.png")
        XCTAssertEqual(m.filter { $0["t"] as? String == "file-data" }.map { $0["seq"] as? Int }, [0, 1, 2, 3])
        XCTAssertEqual(bytes(m), noise)
    }

    func testATiffArrivesAsAnUprightJpeg() throws {
        _ = try image("scan.tiff", .tiff)
        let m = fetch("scan.tiff")
        XCTAssertEqual(m.first?["mime"] as? String, "image/jpeg")
        XCTAssertEqual(Array(bytes(m).prefix(3)), [0xFF, 0xD8, 0xFF], "a JPEG")
    }

    func testEveryWayItIsRefused() throws {
        _ = try image("shots/a.png", .png)
        try Data("text".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        func reason(_ m: [[String: Any]]) -> String? { m.count == 1 ? m[0]["reason"] as? String : "\(m.count) messages" }
        XCTAssertEqual(reason(fetch("missing.png")), "not-found")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
        XCTAssertEqual(reason(fetch("folder.png")), "not-found", "a directory is no image file")
        XCTAssertEqual(reason(fetch("notes.txt")), "not-image")
        XCTAssertEqual(reason(fetch("shots/a.png", maxBytes: 10)), "too-large")
        let f = FileFetcher(directory: { _ in nil }, home: dir.path)
        XCTAssertEqual(f.load(FileGet(id: "f1", term: .pty(1), path: "shots/a.png")).failureReason, .notFound,
                       "relative, in a tab whose directory is unknown")
    }

    // MARK: pacing

    /// A channel as pion's queue looks to the fetcher: every send adds its bytes, every poll's wait drains `drain` of
    /// them, and the clock moves only by those waits.
    private final class FakeChannel: @unchecked Sendable {
        private let lock = NSLock()
        private var held = 0, clock: TimeInterval = 0
        let drain: Int
        var closeAfterPieces: Int?
        private(set) var pieces = 0, waits = 0, heldAtPiece: [Int] = [], types: [String] = []
        init(drain: Int) { self.drain = drain }
        func send(_ d: Data) {
            lock.withLock {
                let t = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["t"] as? String ?? "?"
                types.append(t)
                if t == "file-data" { heldAtPiece.append(held); pieces += 1 }
                held += d.count
            }
        }
        func buffered() -> Int? { lock.withLock { closeAfterPieces.map { pieces >= $0 } == true ? nil : held } }
        func wait(_ s: TimeInterval) { lock.withLock { waits += 1; clock += s; held = max(0, held - drain) } }
        func now() -> TimeInterval { lock.withLock { clock } }
        var snapshot: (pieces: Int, waits: Int, heldAtPiece: [Int], types: [String]) { lock.withLock { (pieces, waits, heldAtPiece, types) } }
    }
    private func noise(_ name: String, _ count: Int) throws -> Data {
        var d = Data(count: count)
        for i in d.indices { d[i] = UInt8(truncatingIfNeeded: i &* 2654435761 >> 13) }
        try d.write(to: dir.appendingPathComponent(name))
        return d
    }
    /// Fetch `path` for client `a` over `ch`, and wait until the queue has run it.
    private func fetchPaced(_ path: String, _ ch: FakeChannel, id: String = "f1", on f: FileFetcher? = nil) -> FileFetcher {
        let f = f ?? FileFetcher(directory: { [dir] _ in dir!.path }, home: dir.path, sleep: { ch.wait($0) }, now: { ch.now() })
        f.fetch(FileGet(id: id, term: .pty(1), path: path), client: "a", send: { ch.send($0) }, buffered: { ch.buffered() })
        return f
    }
    private func drainQueue(_ f: FileFetcher) {
        let done = expectation(description: "queue ran")
        f.fetch(FileGet(id: "probe", term: .pty(1), path: "/nonexistent.png"), client: "probe", send: { _ in done.fulfill() })
        wait(for: [done], timeout: 10)
    }

    func testAPieceWaitsWhileTheChannelHoldsMoreThanThePace() throws {
        let big = try noise("big.png", 2 * 1024 * 1024)
        let ch = FakeChannel(drain: 32 * 1024)
        drainQueue(fetchPaced("big.png", ch))
        let s = ch.snapshot
        XCTAssertEqual(s.types.last, "file-end")
        XCTAssertEqual(s.pieces, (big.count + FileFetch.chunkBytes - 1) / FileFetch.chunkBytes)
        XCTAssertGreaterThan(s.waits, 0, "2 MiB handed over at once would hold everything behind it")
        XCTAssertLessThanOrEqual(s.heldAtPiece.max() ?? .max, FileFetcher.paceBytes, "no piece sent while over the pace")
    }

    func testAClosedChannelANewerTapAndAStallEachStopATransfer() throws {
        _ = try noise("big.png", 2 * 1024 * 1024)
        let closing = FakeChannel(drain: 1024 * 1024)
        closing.closeAfterPieces = 3
        drainQueue(fetchPaced("big.png", closing))
        XCTAssertEqual(closing.snapshot.pieces, 3, "the channel closed: nothing more is sent")
        XCTAssertFalse(closing.snapshot.types.contains("file-end"))

        let stalled = FakeChannel(drain: 0)
        drainQueue(fetchPaced("big.png", stalled))
        XCTAssertFalse(stalled.snapshot.types.contains("file-end"), "a channel that never drains is given up on")
        XCTAssertLessThanOrEqual(Double(stalled.snapshot.waits) * FileFetcher.pollSeconds, FileFetcher.stallSeconds + 1)

        // A first transfer stuck on a full channel; the same client's next tap supersedes it, and the second runs.
        let png = try image("a.png", .png)
        let stuck = FakeChannel(drain: 0), next = FakeChannel(drain: 1024 * 1024)
        // The fake clock runs as fast as the CPU, so the stuck transfer is HELD at its fifth wait until the newer
        // request is made — free-running, it reached the stall before the test thread got there (seen under load).
        let gate = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let f = FileFetcher(directory: { [dir] _ in dir!.path }, home: dir.path,
                            sleep: { s in stuck.wait(s); if stuck.snapshot.waits == 5 { gate.signal(); proceed.wait() } },
                            now: { stuck.now() })
        _ = fetchPaced("big.png", stuck, id: "f1", on: f)
        XCTAssertEqual(gate.wait(timeout: .now() + 10), .success, "the first transfer is waiting on its channel")
        _ = fetchPaced("a.png", next, id: "f2", on: f)
        proceed.signal()
        drainQueue(f)
        XCTAssertFalse(stuck.snapshot.types.contains("file-end"), "the superseded transfer stopped")
        XCTAssertLessThan(stuck.snapshot.waits, 100, "at once, not after the stall")
        XCTAssertEqual(next.snapshot.types, ["file-begin", "file-data", "file-end"])
        XCTAssertEqual(next.snapshot.pieces, 1)
        _ = png
    }

    // MARK: the hub's gate

    func testOnlyTheDriverIsAnswered() throws {
        let png = try image("a.png", .png)
        let hub = ChannelHub(terminals: TerminalManager(cols: 80, rows: 24), injector: nil, encoder: NullEncoder(),
                             terminalPauseHold: .milliseconds(50))
        let a = WindowlessConnection("a"), b = WindowlessConnection("b")
        for c in [a, b] { hub.register(clientId: c.clientId, peer: c); hub.connection(c, didOpen: .control) }
        let ask = #"{"t":"file-get","id":"f1","term":"pty:1","path":"\#(dir.appendingPathComponent("a.png").path)"}"#
        hub.connection(b, didReceive: wrapMessage(Data(ask.utf8)), on: .control)
        XCTAssertTrue(b.bulkMessages.contains { $0.contains(#""reason":"not-driver""#) }, "a passive client is told why")
        hub.connection(a, didReceive: wrapMessage(Data(ask.utf8)), on: .control)
        let deadline = Date().addingTimeInterval(5)
        while !a.bulkMessages.contains(where: { $0.contains(#""t":"file-end""#) }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let mine = a.bulkMessages.filter { $0.contains(#""id":"f1""#) }
        XCTAssertEqual(mine.compactMap { ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any])?["t"] as? String },
                       ["file-begin", "file-data", "file-end"])
        XCTAssertTrue(mine[0].contains("\"size\":\(png.count)"))
        XCTAssertFalse(b.bulkMessages.contains { $0.contains("file-begin") }, "and nothing reaches the passive one")
    }
}

private extension Result where Failure == FileFetchError {
    var failureReason: FileFetchError? { if case .failure(let f) = self { return f }; return nil }
}

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
