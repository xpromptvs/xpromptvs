import XCTest
import RdevCore
@testable import RdevHostKit

final class TmuxClipboardTests: XCTestCase {
    private var runner: TmuxRunner!
    private var socket = ""
    override func setUpWithError() throws {
        socket = "rdev-clip-\(getpid())-\(UUID().uuidString.prefix(8))"
        let env = ProcessInfo.processInfo.environment.merging(["RDEV_TMUX_SOCKET":socket]) { $1 }
        guard let found = TmuxRunner.locate(environment:env) else { throw XCTSkip("tmux unavailable") }
        runner = found.withConfigFile("/dev/null")
        XCTAssertEqual(runner.run(["new-session","-d","-s","clip","sleep","600"]).status,0)
    }
    override func tearDown() { if let runner { _ = runner.run(["kill-server"]); TmuxTestSocket.remove(socket) } }
    private func session() -> String { runner.run(["display-message","-p","-t","clip","#{session_id}"]).stdout.trimmingCharacters(in:.whitespacesAndNewlines) }
    private func setBuffer(_ name: String, _ bytes: Data) throws {
        // Foundation Process argv uses filesystem normalization on macOS. Load exact test bytes from a file;
        // otherwise an NFC é in the test itself becomes NFD before tmux ever stores it.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rdev-clip-\(UUID().uuidString)")
        try bytes.write(to:file);defer { try? FileManager.default.removeItem(at:file) }
        XCTAssertEqual(runner.run(["load-buffer","-b",name,file.path]).status,0)
    }
    func testBufferReadPreservesNewlinesAndIsBounded() throws {
        let text = "clipboard é🙂\n\n"
        try setBuffer("odd ; $ name",Data(text.utf8))
        XCTAssertEqual(runner.readPasteBuffer("odd ; $ name",limit:100).map(Array.init),Array(text.utf8))
        XCTAssertNil(runner.readPasteBuffer("odd ; $ name",limit:3))
        XCTAssertNil(runner.readPasteBuffer("missing",limit:100))
        let ceiling = Data(repeating:65,count:TermClipboard.maxBytes)
        try setBuffer("ceiling",ceiling)
        XCTAssertEqual(runner.readPasteBuffer("ceiling"),ceiling)
        try setBuffer("oversize",ceiling + Data([65]))
        XCTAssertNil(runner.readPasteBuffer("oversize"))
        try setBuffer("binary",Data([0xff,0x00]))
        XCTAssertNil(runner.readPasteBuffer("binary"))
    }
    func testNFCBufferNameIsReadWithoutArgumentNormalization() throws {
        let p = runner.process(["source-file", "-"]), input = Pipe()
        p.standardInput = input; p.standardOutput = FileHandle.nullDevice
        try p.run()
        // tmux parses octal bytes itself: the buffer name is NFC, unlike Foundation's argv.
        try input.fileHandleForWriting.write(contentsOf: Data("set-buffer -b \"\\303\\251\" exact\n".utf8))
        try input.fileHandleForWriting.close(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(runner.readPasteBuffer("é"), Data("exact".utf8))
    }
    func testCopiesReachOnlyTheSelectedTmuxClientAndDoNotReplayExistingBuffers() throws {
        _ = runner.run(["set-buffer","-b","before","old"])
        let sid = session(), manager = TerminalManager(cols:80,rows:24)
        manager.tmux = runner; manager.onEmit = { _ in true }; manager.setDriverDecodesWire(true,generation:7)
        defer { manager.closeAll() }
        let lock = NSLock(); var copies: [(TermTabID,UInt64,Data)] = []
        let copied = expectation(description:"new tmux copy")
        manager.onClipboard = { id,epoch,data in lock.withLock { copies.append((id,epoch,data)) }; copied.fulfill() }
        XCTAssertNoThrow(try manager.openTmux(sid).get())
        manager.syncTmuxQueueForTests(sid)
        XCTAssertEqual(runner.run(["new-session","-d","-s","other","sleep","600"]).status,0)
        let other = runner.run(["display-message","-p","-t","other","#{session_id}"]).stdout.trimmingCharacters(in:.whitespacesAndNewlines)
        XCTAssertNoThrow(try manager.openTmux(other).get()); manager.syncTmuxQueueForTests(other)
        XCTAssertTrue(manager.switchTo(.tmux(sid))); manager.syncTmuxQueueForTests(sid)
        XCTAssertTrue(lock.withLock { copies.isEmpty })
        try setBuffer("copy",Data("new é\n".utf8))
        wait(for:[copied],timeout:5)
        XCTAssertEqual(lock.withLock { copies.count },1)
        XCTAssertEqual(lock.withLock { copies.first?.0 },.tmux(sid))
        XCTAssertEqual(lock.withLock { copies.first?.1 },7)
        XCTAssertEqual(lock.withLock { copies.first?.2 }.map(Array.init),Array("new é\n".utf8))
    }
    func testBufferReadFinishingAfterWireChangeIsDiscarded() throws {
        let sid = session(), manager = TerminalManager(cols:80,rows:24)
        manager.tmux = runner;manager.onEmit = { _ in true };manager.setDriverDecodesWire(true,generation:7)
        defer { manager.closeAll() }
        let began = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
        manager.readClipboardForTests = { _,_ in began.signal();resume.wait();return Data("old".utf8) }
        let lock=NSLock();var count=0
        manager.onClipboard = { _,_,_ in lock.withLock { count += 1 } }
        XCTAssertNoThrow(try manager.openTmux(sid).get());manager.syncTmuxQueueForTests(sid)
        manager.injectTmuxEventsForTests(sid,[.pasteBufferChanged(name:"copy")])
        XCTAssertEqual(began.wait(timeout:.now()+2),.success)
        manager.setDriverDecodesWire(true,generation:8);resume.signal();manager.drainClipboardForTests();manager.syncTmuxQueueForTests(sid)
        XCTAssertEqual(lock.withLock { count },0)
    }
    func testBlockedCallbacksRetainOnlyOneCompletedCopy() throws {
        let sid = session(), manager = TerminalManager(cols:80,rows:24)
        manager.tmux = runner; manager.onEmit = { _ in true }; manager.setDriverDecodesWire(true,generation:7)
        let entered = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0), read = DispatchSemaphore(value:0)
        defer { resume.signal(); manager.closeAll() }
        manager.readClipboardForTests = { _,_ in read.signal(); return Data(repeating:65,count:TermClipboard.maxBytes) }
        let copied = expectation(description:"latest copy only")
        manager.onClipboard = { _,_,_ in copied.fulfill() }
        XCTAssertNoThrow(try manager.openTmux(sid).get()); manager.syncTmuxQueueForTests(sid)
        manager.blockClipboardCallbackForTests(sid) { entered.signal(); resume.wait() }
        XCTAssertEqual(entered.wait(timeout:.now()+2),.success)
        for i in 0..<12 {
            try setBuffer("copy",Data("\(i)".utf8))
            XCTAssertEqual(read.wait(timeout:.now()+2),.success)
            manager.drainClipboardForTests()
        }
        XCTAssertEqual(manager.clipboardDeliveryCountForTests,1)
        resume.signal(); manager.syncTmuxQueueForTests(sid)
        wait(for:[copied],timeout:2)
    }
    func testBufferReadFinishingAfterTabSwitchAwayAndBackIsDiscarded() throws {
        let sid = session(), manager = TerminalManager(cols:80,rows:24)
        manager.tmux = runner; manager.onEmit = { _ in true }; manager.setDriverDecodesWire(true,generation:7)
        XCTAssertEqual(runner.run(["new-session","-d","-s","other","sleep","600"]).status,0)
        let other = runner.run(["display-message","-p","-t","other","#{session_id}"]).stdout.trimmingCharacters(in:.whitespacesAndNewlines)
        XCTAssertNoThrow(try manager.openTmux(other).get()); manager.syncTmuxQueueForTests(other)
        let began = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0)
        defer { resume.signal(); manager.closeAll() }
        manager.readClipboardForTests = { _,_ in began.signal(); resume.wait(); return Data("old".utf8) }
        let lock = NSLock(); var count = 0
        manager.onClipboard = { _,_,_ in lock.withLock { count += 1 } }
        XCTAssertNoThrow(try manager.openTmux(sid).get()); manager.syncTmuxQueueForTests(sid)
        manager.injectTmuxEventsForTests(sid,[.pasteBufferChanged(name:"copy")])
        XCTAssertEqual(began.wait(timeout:.now()+2),.success)
        XCTAssertTrue(manager.switchTo(.tmux(other))); XCTAssertTrue(manager.switchTo(.tmux(sid)))
        resume.signal(); manager.drainClipboardForTests(); manager.syncTmuxQueueForTests(sid)
        XCTAssertEqual(lock.withLock { count },0)
    }
}
