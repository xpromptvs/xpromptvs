import CoreVideo
import XCTest
import RdevCore
import RdevTermCorpus
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

/// Decode the actual RZT1 transport into semantic records for the existing
/// lifecycle assertions. The start marker below is a test event, never wire input.
private func decodedTerminalMessages(_ messages: [[UInt8]]) -> [[UInt8]] {
    do {
        var decoder: TermZstdInflater?
        var sequence: UInt64 = 0
        var epoch: UInt64 = 0
        var out: [[UInt8]] = []
        for bytes in messages {
            switch try TermWireMessage.decode(Data(bytes)) {
            case let .start(e, compressed):
                XCTAssertGreaterThan(e, epoch); epoch = e; sequence = 0
                decoder = try TermZstdInflater()
                XCTAssertEqual(try decoder!.push(compressed, maximumOutput: 32), Data(0..<32))
                out.append([4, 0])
            case let .data(e, seq, count, compressed):
                XCTAssertEqual(e, epoch); XCTAssertEqual(seq, sequence); sequence += 1
                let raw = try XCTUnwrap(decoder).push(compressed, maximumOutput: Int(count))
                XCTAssertEqual(raw.count, Int(count)); out.append(Array(raw))
            }
        }
        return out
    } catch { XCTFail("Shared terminal decode failed: \(error)"); return [] }
}

/// A logically open test connection with a real media peer. A never-connected
/// PionPeer reports nil buffered; nil now correctly retires a terminal wire.
private final class OpenTestPeer: ClientConnection, @unchecked Sendable {
    let clientId: String
    let pion: PionPeer
    init(clientId: String) { self.clientId = clientId; pion = PionPeer(clientId: clientId, turn: nil) }
    var mediaPeer: PionPeer? { pion }
    func send(_ ch: PionChannel, _ data: Data) { pion.send(ch, data) }
    func close() { pion.close() }
}

/// Messages a terminal wire delivered, in order.
private final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var msgs: [[UInt8]] = []
    private let raw: Bool
    init(raw: Bool = false) { self.raw = raw }
    func add(_ d: Data) { lock.lock(); msgs.append([UInt8](d)); lock.unlock() }
    var wire: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return msgs }
    var all: [[UInt8]] { raw ? wire : decodedTerminalMessages(wire) }
}

/// ChannelHub's half of the live terminal: which client the terminal wire is bound to, and who may
/// pause it. Driven through the hub's REAL entry points (register / unregister / rebindPeer / the
/// PionPeerDelegate callbacks) with real, never-connected PionPeers — a send on a channel that never
/// opened is a no-op, so nothing here needs a network.
final class ChannelHubTerminalTests: XCTestCase {
    private var peers: [OpenTestPeer] = []
    private var terminals: TerminalManager!
    private var hub: ChannelHub!

    override func setUp() {
        terminals = TerminalManager(cols: 80, rows: 24)
        hub = ChannelHub(terminals: terminals, injector: nil, encoder: NullEncoder(),
                         terminalPauseHold: .milliseconds(50))
    }

    override func tearDown() {
        for p in peers { p.close() }
        peers = []
    }

    private func peer(_ id: String) -> OpenTestPeer {
        let p = OpenTestPeer(clientId: id)
        peers.append(p)
        return p
    }

    private func send(_ p: OpenTestPeer, _ json: String) {
        hub.connection(p, didReceive: wrapMessage(Data(json.utf8)), on: .control)
    }

    /// A raw driver with its terminal channel open, which is what binds a wire.
    private func rawTerminal(_ p: OpenTestPeer) {
        hub.connection(p, didOpen: .terminal)
        send(p, #"{"t":"term-mode","mode":"raw"}"#)
    }

    /// Past the hold, and everything the gate has queued since.
    private func settle() {
        hub.syncTerminalPause()
        Thread.sleep(forTimeInterval: 0.2)
        hub.syncTerminalPause()
    }

    func testAWireIsBoundOnlyForTheDriversOpenRawTerminalChannel() {
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        XCTAssertNil(hub.termWireClientId, "no terminal channel yet")
        hub.connection(a, didOpen: .terminal)
        XCTAssertNil(hub.termWireClientId, "open, but not declared: no wire (the channel carries nothing else)")
        send(a, #"{"t":"term-mode","mode":"frames"}"#)
        XCTAssertNil(hub.termWireClientId, "the cell-frame mode is gone: any mode but raw is malformed and binds nothing")
        send(a, #"{"t":"term-mode","mode":"raw"}"#)
        XCTAssertEqual(hub.termWireClientId, "a")
        send(a, #"{"t":"term-mode","mode":"frames"}"#)
        XCTAssertEqual(hub.termWireClientId, "a", "…and unbinds nothing")

        hub.register(clientId: "b", peer: b)                                   // passive
        rawTerminal(b)
        XCTAssertEqual(hub.termWireClientId, "a", "a passive client's raw terminal binds nothing")
        send(b, #"{"t":"claim-control"}"#)
        XCTAssertEqual(hub.termWireClientId, "b", "a claim moves the wire to the new driver")
    }

    /// Time the tests drive (`ManualClock`): a new wire's snapshot of a tab just resized waits for its redraw
    /// (`TerminalManager.snapshotAllSettled`), and these tests step through that wait.
    private func manualClock() -> ManualClock {
        let clock = ManualClock()
        terminals = TerminalManager(cols: 80, rows: 24, clock: { clock.now }, schedule: { clock.schedule(after: $0, $1) })
        hub = ChannelHub(terminals: terminals, injector: nil, encoder: NullEncoder(),
                         terminalPauseHold: .milliseconds(50))
        return clock
    }
    private func ms(_ clock: ManualClock, _ n: UInt64) { clock.advance(by: n * 1_000_000) }

    /// Each snapshot of `id` in `msgs`: its grid and its text, decoded as the client decodes the wire.
    private func snapshots(_ id: TermTabID, in msgs: [[UInt8]]) throws -> [(size: TermGridSize, text: String)] {
        var out: [(size: TermGridSize, text: String)] = []
        var accumulated = Data()
        var mid = false
        for m in msgs {
            guard let f = TermFrame.decode(Data(m)) else { continue }
            if f.kind == .wireStart { accumulated = Data(); mid = false; continue }
            guard f.tab == id.wire, f.kind == .snapshotChunk || f.kind == .snapshotEnd else { continue }
            if !mid { accumulated = Data(); out.append((try XCTUnwrap(f.size), "")) }
            mid = f.kind == .snapshotChunk
            accumulated.append(contentsOf: f.payload)
            out[out.count - 1].text = String(decoding: accumulated, as: UTF8.self)
        }
        return out
    }

    /// A CLAIM SAYS ITS GRID, and the new driver's wire snapshots every tab AT IT, once (docs/terminal.md, "A claim
    /// says its grid"). Before, the snapshots were at the PREVIOUS driver's grid and the claimer showed that layout
    /// reflowed to its own for a frame or more, until its `resize` brought a second set. The outgoing driver's wire
    /// gets nothing: the first frame after the claim is the new wire's start.
    func testAClaimsGridIsAppliedBeforeTheNewDriversSnapshots() throws {
        let clock = manualClock()
        let got = Delivered()
        hub.termWireTap = { got.add($0) }
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        let one = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        let two = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        defer { terminals.close(one); terminals.close(two) }
        send(a, #"{"t":"resize","cols":120,"rows":40}"#)
        ms(clock, 200)
        hub.register(clientId: "b", peer: b)
        rawTerminal(b)
        let mark = got.all.count
        send(b, #"{"t":"claim-control","cols":45,"rows":30}"#)
        XCTAssertEqual(hub.termWireClientId, "b")
        ms(clock, 200)                                                          // no redraw comes: taken at 60 ms
        let after = Array(got.all.dropFirst(mark))
        XCTAssertEqual(after.first, [4, 0], "nothing for the outgoing driver: the new wire's start comes first")
        for id in [one, two] {
            XCTAssertEqual(try snapshots(id, in: after).map(\.size), [TermGridSize(cols: 45, rows: 30)],
                           "\(id.wire): ONE snapshot, at the claimer's 45×30")
        }
        send(b, #"{"t":"resize","cols":45,"rows":30}"#)                        // its activation's own report
        ms(clock, 200)
        for id in [one, two] {
            XCTAssertEqual(try snapshots(id, in: Array(got.all.dropFirst(mark))).count, 1, "the same grid again re-sends nothing")
        }
    }

    /// **THE NEW DRIVER'S SNAPSHOT CARRIES THE REDRAW ITS CLAIM BROUGHT** (`TerminalManager.snapshotAllSettled`,
    /// 2026-10-07, "still a glitch when moving active client between devices with old screen size blinking for one
    /// frame"): the claim resizes the tab, the program in it redraws for the new size a few ms later, and the
    /// snapshot taken before that redraw showed the PREVIOUS driver's picture for a frame or three. The new wire's
    /// start goes at once; the tab's snapshot only once the redraw has gone 16 ms quiet, with the redraw in it.
    func testANewDriversSnapshotCarriesTheRedrawItsClaimBrought() throws {
        let clock = manualClock()
        let got = Delivered()
        hub.termWireTap = { got.add($0) }
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        let one = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        defer { terminals.close(one) }
        send(a, #"{"t":"resize","cols":120,"rows":40}"#)
        terminals.feedForTests(one, Array("\u{1b}[H\u{1b}[2Jdrawn for 120x40".utf8))
        ms(clock, 200)
        hub.register(clientId: "b", peer: b)
        rawTerminal(b)
        let mark = got.all.count
        send(b, #"{"t":"claim-control","cols":45,"rows":30}"#)
        XCTAssertEqual(Array(got.all.dropFirst(mark)), [[4, 0]], "the wire's start, and no snapshot ahead of the redraw")
        ms(clock, 8)
        terminals.feedForTests(one, Array("\u{1b}[H\u{1b}[2Jdrawn for 45x30".utf8))   // the program answers its SIGWINCH
        ms(clock, 12)
        XCTAssertEqual(try snapshots(one, in: Array(got.all.dropFirst(mark))).count, 0, "12 ms of quiet is not 16")
        ms(clock, 8)
        let snaps = try snapshots(one, in: Array(got.all.dropFirst(mark)))
        XCTAssertEqual(snaps.map(\.size), [TermGridSize(cols: 45, rows: 30)], "ONE snapshot, at the claimer's grid")
        XCTAssertTrue(snaps.first?.text.contains("drawn for 45x30") ?? false, "with the redraw in it")
        XCTAssertFalse(snaps.first?.text.contains("drawn for 120x40") ?? true, "and not the previous driver's picture")
    }

    /// A claim with no grid (an older client, a phone whose terminal area cannot be measured) is as before: the
    /// previous driver's grid, until the new driver's `resize` — at once, nothing having been resized.
    func testAClaimWithoutAGridSnapshotsAtThePreviousDriversGrid() throws {
        let clock = manualClock()
        let got = Delivered()
        hub.termWireTap = { got.add($0) }
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        let one = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        defer { terminals.close(one) }
        send(a, #"{"t":"resize","cols":120,"rows":40}"#)
        ms(clock, 200)
        hub.register(clientId: "b", peer: b)
        rawTerminal(b)
        let mark = got.all.count
        send(b, #"{"t":"claim-control"}"#)
        XCTAssertEqual(try snapshots(one, in: Array(got.all.dropFirst(mark))).map(\.size), [TermGridSize(cols: 120, rows: 40)])
    }

    func testTerminalPauseAndResumeAreAcceptedFromTheDriverOnly() {
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        send(b, #"{"t":"terminal-pause"}"#)
        settle()
        XCTAssertFalse(terminals.forwardingIsPaused, "a passive client cannot pause the driver's terminal")
        send(a, #"{"t":"terminal-pause"}"#)
        settle()
        XCTAssertTrue(terminals.forwardingIsPaused)
        send(b, #"{"t":"terminal-resume"}"#)
        settle()
        XCTAssertTrue(terminals.forwardingIsPaused, "nor resume it")
        send(a, #"{"t":"terminal-resume"}"#)
        settle()
        XCTAssertFalse(terminals.forwardingIsPaused)
    }

    /// The host answers a tmux tab's unreached colour queries as the DRIVER's xterm.js would: the
    /// driver's `term-palette` is used at once; a passive client's is kept and used once it claims; a
    /// driver that never sent one leaves xterm.js's defaults, not its predecessor's.
    func testTheTerminalPaletteIsTheDrivers() {
        let a = peer("a"), b = peer("b"), c = peer("c")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        hub.register(clientId: "c", peer: c)
        let ansi = (0..<16).map { _ in "\"#010203\"" }.joined(separator: ",")
        func palette(_ fg: String) -> String {
            "{\"t\":\"term-palette\",\"fg\":\"\(fg)\",\"bg\":\"#000000\",\"cursor\":\"#ffffff\",\"ansi\":[\(ansi)]}"
        }
        send(b, palette("#bbbbbb"))
        XCTAssertEqual(terminals.termPaletteForTests, .xtermDefault, "a passive client's is not in use")
        send(a, palette("#aaaaaa"))
        XCTAssertEqual(terminals.termPaletteForTests.foreground, .init(r: 0xaa, g: 0xaa, b: 0xaa))
        send(b, #"{"t":"claim-control"}"#)
        XCTAssertEqual(terminals.termPaletteForTests.foreground, .init(r: 0xbb, g: 0xbb, b: 0xbb), "kept for its claim")
        send(c, #"{"t":"claim-control"}"#)
        XCTAssertEqual(terminals.termPaletteForTests, .xtermDefault, "c never sent one")
    }

    /// M3: the hub decides each hand-off UNDER its lock and stamps it; the manager keeps only the newest.
    /// A hand-off computed before a claim but delivered after it (the old driver's palette) is stale and
    /// cannot overwrite the new driver's.
    func testAStalePaletteHandOffCannotOverwriteANewerOne() {
        var newer = TermPalette.xtermDefault
        newer.foreground = .init(r: 1, g: 2, b: 3)
        terminals.setTermPalette(newer, seq: 2)
        terminals.setTermPalette(.xtermDefault, seq: 1)
        XCTAssertEqual(terminals.termPaletteForTests, newer)
    }

    /// A pause belonged to the outgoing driver's hidden page: applied or still pending, a change of
    /// driver voids it.
    func testADriverChangeResetsThePause() {
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        send(a, #"{"t":"terminal-pause"}"#)
        settle()
        XCTAssertTrue(terminals.forwardingIsPaused, "precondition: applied")
        send(b, #"{"t":"claim-control"}"#)
        XCTAssertFalse(terminals.forwardingIsPaused, "an applied pause is cleared on the claim")

        send(b, #"{"t":"terminal-pause"}"#)                                    // pending: inside the hold
        hub.unregister(clientId: "b")                                         // a is promoted
        settle()
        XCTAssertFalse(terminals.forwardingIsPaused, "a pending pause does not land on the new driver")
    }

    /// Final review C1: the phone path. The driver's page was hidden past the hold (the pause APPLIED),
    /// its connection died meanwhile, and it came back by REBUILD — so its `terminal-resume` went into
    /// a dead channel and never arrived. The rebuilt connection is a new page lifetime: its first wire
    /// must carry a snapshot of every tab, and output must flow after it. Before the fix every snapshot
    /// hit the pause and the new wire carried the start alone — a terminal frozen at the moment the
    /// page left, still taking keystrokes.
    func testARebuildWhileThePauseIsAppliedSnapshotsEveryTabAndStreams() {
        let got = Delivered()
        hub.termWireTap = { got.add($0) }
        let a = peer("a"), a2 = peer("a")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        XCTAssertTrue(terminals.open(cols: 80, rows: 24))
        XCTAssertTrue(terminals.open(cols: 80, rows: 24))
        defer { terminals.close(.pty(1)); terminals.close(.pty(2)) }
        send(a, #"{"t":"terminal-pause"}"#)
        settle()
        XCTAssertTrue(terminals.forwardingIsPaused, "precondition: the pause applied")

        let mark = got.all.count
        hub.rebindPeer(clientId: "a", peer: a2)
        rawTerminal(a2)
        func frames(_ kind: UInt8, _ tab: String) -> Int {
            let head = [kind, UInt8(tab.utf8.count)] + Array(tab.utf8)
            return got.all.dropFirst(mark).filter { $0.starts(with: head) }.count
        }
        XCTAssertEqual(frames(2, "pty:1"), 1, "the rebuilt wire snapshots tab 1")
        XCTAssertEqual(frames(2, "pty:2"), 1, "the rebuilt wire snapshots tab 2")
        terminals.write(Data("echo AFTER''MARK\r".utf8), toTerminal: .pty(2))
        let deadline = Date().addingTimeInterval(10)
        while frames(0, "pty:2") == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertGreaterThan(frames(0, "pty:2"), 0, "and the active tab's output flows on it")
    }

    /// Final review I1(b): a new wire is installed while the active tab is still live from the OLD one.
    /// Its output then reaches a wire with no context for it (the encoder drops it), so the driver's
    /// xterm.js never sees a device query in it — and the host must answer. Held at the point the new
    /// wire becomes reachable, before anything else about it is written.
    func testADeviceQueryOnANewWireBeforeItsSnapshotIsAnsweredByTheHost() {
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        XCTAssertTrue(terminals.open(cols: 80, rows: 24))
        defer { terminals.close(.pty(1)) }
        let tm = terminals!
        waitForPrompt(tm, .pty(1))
        var answered: String?
        hub.afterTermWireInstalledForTests = { [hub] in
            hub!.afterTermWireInstalledForTests = nil
            answered = askDSR(tm, .pty(1))
        }
        send(a, #"{"t":"term-mode","mode":"raw"}"#)                            // a fresh wire
        XCTAssertEqual(answered, "R=3", "nobody else can answer it: the host must")
    }

    /// The mirror image, at FIRST bind: the new wire is reachable before the manager hears of it, and a
    /// snapshot landing in that moment (a tab opening, a resume) makes a tab live ON the new wire. Its
    /// query then reaches the driver's xterm.js — so the host must stay silent, whatever it has not yet
    /// been told about the wire. Only the emission's own result may decide (the flag beside it said "no
    /// wire" here, and the host answered too: two answers in the shell).
    func testAQueryReachingANewWireBeforeTheManagerHearsOfItIsNotAnsweredByTheHost() throws {
        let answers = Delivered(raw: true)
        terminals.hostAnswerForTests = { _, b in answers.add(Data(b)) }
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        hub.connection(a, didOpen: .terminal)                                   // not declared: no wire yet
        let id = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        let tm = terminals!
        hub.afterTermWireInstalledForTests = { [hub] in
            hub!.afterTermWireInstalledForTests = nil
            tm.snapshot(id)                                                   // live on the NEW wire
            tm.feedForTests(id, Array("\u{1b}[5n".utf8))                      // DSR 5n reaches it
        }
        send(a, #"{"t":"term-mode","mode":"raw"}"#)                            // the first bind
        XCTAssertEqual(answers.all, [], "the driver's xterm.js answers it; the host must not answer too")
    }

    /// Two rebinds racing (a re-declaration and a claim, say): each used to `snapshotAll`, and whichever
    /// ran second snapshotted every tab AGAIN into the wire that was current by then — one more
    /// transient instance per tab on the client. An older rebind's snapshots are a no-op once a newer
    /// one has superseded it. R1 is held (a barrier) right after its wire became reachable; R2 runs,
    /// and R1 is released either after R2 has run to the end (`r1After: .end`), or while R2 is held at
    /// the same point — its wire reachable, the manager not yet told (`.install`).
    ///
    /// Before R1 is released under `.end`, the tab prints bytes the send buffer HOLDS on R2's context:
    /// they must still reach R2's wire. (Without the generation check R1's snapshot took them as its
    /// boundary and sent them into its own retired wire — lost.)
    enum R1Resumes { case end, install }
    private func twoRebindsRacing(_ when: R1Resumes) throws -> (snapshots: Int, outputs: Int) {
        let clock = ManualClock()
        terminals = TerminalManager(cols: 80, rows: 24, clock: { clock.now }, schedule: { clock.schedule(after: $0, $1) })
        hub = ChannelHub(terminals: terminals, injector: nil, encoder: NullEncoder(), terminalPauseHold: .milliseconds(50))
        let got = Delivered()
        hub.termWireTap = { got.add($0) }
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        let id = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        let r1Held = DispatchSemaphore(value: 0), resumeR1 = DispatchSemaphore(value: 0)
        let r1Done = DispatchSemaphore(value: 0)
        let calls = Delivered(raw: true)                                               // the hook's calls, counted
        hub.afterTermWireInstalledForTests = {
            calls.add(Data())
            if calls.all.count == 1 { r1Held.signal(); resumeR1.wait() }       // R1: held
            else if when == .install { resumeR1.signal(); r1Done.wait() }     // R2: R1 runs to its end now
        }
        DispatchQueue.global().async { [self] in
            send(a, #"{"t":"term-mode","mode":"raw"}"#)                        // R1
            r1Done.signal()
        }
        r1Held.wait()
        send(a, #"{"t":"term-mode","mode":"raw"}"#)                            // R2
        if when == .end {
            terminals.feedForTests(id, Array("held on R2's context".utf8))
            resumeR1.signal(); r1Done.wait()
        }
        hub.afterTermWireInstalledForTests = nil
        clock.advance(by: TermSendBuffer.hold)                                 // whatever is held goes out now
        let start: [UInt8] = [4, 0]
        let lastStart = try XCTUnwrap(got.all.lastIndex(of: start))
        func frames(_ kind: UInt8) -> Int {
            let head = [kind, 5] + Array("pty:1".utf8)
            return got.all[(lastStart + 1)...].filter { $0.starts(with: head) }.count
        }
        return (frames(2), frames(0))
    }

    func testAnOlderRebindReleasedAfterANewerOneSnapshotsNothing() throws {
        let r = try twoRebindsRacing(.end)
        XCTAssertEqual(r.snapshots, 1, "one snapshot of the tab on the current wire")
        XCTAssertEqual(r.outputs, 1, "the bytes held on the current wire's context reach it")
    }

    func testAnOlderRebindReleasedInsideANewerOneSnapshotsNothingIntoIt() throws {
        XCTAssertEqual(try twoRebindsRacing(.install).snapshots, 1, "one snapshot of the tab on the current wire")
    }

    /// `term-reply` reaches the tab it names from the DRIVER only (a passive client decodes no wire, so
    /// it has no query to answer), and spends what that tab is owed — a tab that is not active included.
    func testATermReplyIsTheDriversAndReachesTheTabThatAsked() throws {
        let got = Delivered(raw: true)
        terminals.ptyInputForTests = { id, b in got.add(Data(id.wire.utf8 + [0x3d] + b)) }
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)
        rawTerminal(a)
        let one = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        _ = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))   // active
        terminals.feedForTests(one, Array("\u{1b}[5n".utf8))                    // reaches a's wire
        let reply = Data(#"{"t":"term-reply","data":"\u001b[0n","term":"pty:1"}"#.utf8)
        hub.connection(b, didReceive: wrapMessage(reply), on: .input)
        XCTAssertEqual(got.all, [], "a passive client's reply is ignored")
        hub.connection(a, didReceive: wrapMessage(reply), on: .input)
        XCTAssertEqual(got.all, [Array("pty:1=\u{1b}[0n".utf8)])
    }

    /// A departing driver with nobody to promote produces NO activate/deactivate effect, and its wire
    /// must not outlive it.
    func testADepartingDriversWireIsUnbound() {
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        XCTAssertEqual(hub.termWireClientId, "a")
        hub.unregister(clientId: "a")
        XCTAssertNil(hub.termWireClientId)
    }

    /// A resume by rebuild replaces the driver's peer: the old wire (to the dead peer) goes at once,
    /// and the new peer binds its own when its terminal channel opens raw.
    func testARebuiltPeerDropsTheWireUntilItsTerminalReopens() {
        let a = peer("a"), a2 = peer("a")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        XCTAssertEqual(hub.termWireClientId, "a")
        hub.rebindPeer(clientId: "a", peer: a2)
        XCTAssertNil(hub.termWireClientId, "no wire to the replaced peer")
        rawTerminal(a2)
        XCTAssertEqual(hub.termWireClientId, "a")
    }

    /// A claim that binds a new driver's wire WHILE the old driver's rebuild is dropping its wire: the
    /// flag that tells the host whether xterm.js answers the active tab's device queries must end up
    /// describing the wire that is BOUND (the claimer's), not the one the rebuild dropped. Held at a
    /// barrier so the late write is certain, not likely.
    func testAClaimRacingARebuildLeavesTheDeviceQueryOwnerTrue() {
        let x = peer("x"), x2 = peer("x"), y = peer("y")
        hub.register(clientId: "x", peer: x)
        rawTerminal(x)
        hub.register(clientId: "y", peer: y)
        rawTerminal(y)
        XCTAssertEqual(hub.termWireClientId, "x")
        XCTAssertTrue(terminals.driverDecodesWireForTests)
        hub.afterWireDroppedForRebuildForTests = { [hub] in
            // The rebuild has dropped x's wire and released the hub lock; y claims NOW.
            hub!.connection(y, didReceive: wrapMessage(Data(#"{"t":"claim-control"}"#.utf8)), on: .control)
        }
        hub.rebindPeer(clientId: "x", peer: x2)
        hub.afterWireDroppedForRebuildForTests = nil
        XCTAssertEqual(hub.termWireClientId, "y", "the claim bound y's wire")
        XCTAssertTrue(terminals.driverDecodesWireForTests,
                      "y's xterm.js answers its device queries; a stale write from the rebuild must not undo that")
    }

    /// The wire start (`[4, 0]`) leads EVERY wire and appears once, even when something reaches the
    /// wire before its binder's `begin()` does — a client resyncing after an undecodable stream drops
    /// everything until it, so a frame ahead of it would be lost and one behind a second start would
    /// be decoded as the new wire's.
    func testATermWireOpensWithTheWireStartExactlyOnce() {
        let got = Delivered()
        let w = TermWire { got.add($0) }
        w.emit(.closed(.pty(1)))
        w.begin()
        w.emit(.closed(.pty(2)))
        XCTAssertEqual(got.all, [[4, 0], [3, 5] + Array("pty:1".utf8), [3, 5] + Array("pty:2".utf8)])
    }

    /// Every wire the hub binds — the first, and the fresh one a repeated `term-mode raw` (the client's
    /// resync request) builds — starts with the wire start, before any snapshot.
    func testEveryBoundWireOpensWithTheWireStart() {
        let got = Delivered()
        hub.termWireTap = { got.add($0) }
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        XCTAssertEqual(got.all, [[4, 0]], "no tabs: the start alone")
        send(a, #"{"t":"term-mode","mode":"raw"}"#)
        XCTAssertEqual(got.all, [[4, 0], [4, 0]], "a resync request builds a fresh wire, which starts again")
    }

    /// Review M2: a tab's serial path may already hold the OLD wire when a rebind installs the new one.
    /// A retired wire sends nothing, so no old-wire frame can follow the new wire's start.
    func testARetiredWireSendsNothing() {
        let got = Delivered()
        let w = TermWire { got.add($0) }
        w.begin()
        w.retire()
        w.emit(.closed(.pty(1)))
        w.begin()
        XCTAssertEqual(got.all, [[4, 0]])
    }

    /// A connection whose terminal channel reports what pion would hold, recording what reached it — the PACED path
    /// (docs/terminal.md, "A slow link gets the terminal paced"), which a never-connected PionPeer (nothing buffered:
    /// nil) and a socket (0) never take. The tap above sees frames as the wire MAKES them; this sees the channel.
    func testOverloadReportsOnceOnlyToItsDriverAndVoidsQueryOwnership() throws {
        let c = PacedConnection("driver"), passive = PacedConnection("passive")
        hub.register(clientId: c.clientId, peer: c)
        hub.register(clientId: passive.clientId, peer: passive)
        hub.connection(c, didOpen: .terminal)
        let raw = wrapMessage(Data(#"{"t":"term-mode","mode":"raw"}"#.utf8))
        hub.connection(c, didReceive: raw, on: .control)
        let wire = try XCTUnwrap(hub.termWireForTests)
        XCTAssertTrue(terminals.driverDecodesWireForTests)
        XCTAssertFalse(wire.emit(.snapshot(.pty(1), .init(cols: 80, rows: 24), Array(repeating: 65, count: 64 * 1024 * 1024))))
        XCTAssertFalse(wire.emit(.output(.pty(1), [65])))
        let deadline = Date().addingTimeInterval(2)
        while c.errors.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(c.errors.count, 1)
        XCTAssertEqual(c.errors.first?["reason"] as? String, "overloaded")
        XCTAssertEqual(c.errors.first?["epoch"] as? String, String(wire.epoch))
        XCTAssertTrue(passive.errors.isEmpty)
        XCTAssertFalse(terminals.driverDecodesWireForTests)
        XCTAssertNil(hub.termWireForTests)
    }

    func testAnOldFailureCannotRetireItsReplacementWire() throws {
        let c = PacedConnection("driver")
        hub.register(clientId: c.clientId, peer: c)
        hub.connection(c, didOpen: .terminal)
        let raw = wrapMessage(Data(#"{"t":"term-mode","mode":"raw"}"#.utf8))
        hub.connection(c, didReceive: raw, on: .control)
        let old = try XCTUnwrap(hub.termWireForTests)
        hub.connection(c, didReceive: raw, on: .control)
        let current = try XCTUnwrap(hub.termWireForTests)
        XCTAssertGreaterThan(current.epoch, old.epoch)
        hub.terminalStreamFailed(c, epoch: old.epoch, reason: .overloaded)
        XCTAssertTrue(hub.termWireForTests === current)
        XCTAssertTrue(terminals.driverDecodesWireForTests)
        XCTAssertTrue(c.errors.isEmpty)
    }

    private final class PacedConnection: ClientConnection, @unchecked Sendable {
        let clientId: String
        private let lock = NSLock()
        private var terminal: [[UInt8]] = []
        private var control: [Data] = []
        private var held = 0
        init(_ id: String) { clientId = id }
        var mediaPeer: PionPeer? { nil }
        func send(_ ch: PionChannel, _ data: Data) {
            lock.lock(); defer { lock.unlock() }
            if ch == .terminal { terminal.append([UInt8](data)) }
            if ch == .control { control.append(data) }
        }
        var errors: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return control.compactMap { data in
                guard let raw = unwrapMessage(data), let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      obj["t"] as? String == "term-stream-error" else { return nil }
                return obj
            }
        }
        func bufferedAmount(_ ch: PionChannel) -> Int? { lock.lock(); defer { lock.unlock() }; return ch == .terminal ? held : 0 }
        func setHeld(_ n: Int) { lock.lock(); held = n; lock.unlock() }
        var wire: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return terminal }
        var sent: [[UInt8]] { decodedTerminalMessages(wire) }
    }

    func testFastTerminalFramesLeaveFrequentPacingBoundaries() throws {
        let c = FastClientConnection(clientId: "fast-chunks", generation: Data(repeating: 1, count: 16), onOpen: { _ in }, onMessage: { _, _ in }, onFailure: { _ in })
        defer { c.close() }
        c.setWebSocketSender { _ in true }; c.markReady()
        let delivered = Delivered()
        hub.termWireTap = { delivered.add($0) }
        hub.register(clientId: c.clientId, peer: c)
        hub.connection(c, didOpen: .terminal)
        hub.connection(c, didReceive: wrapMessage(Data(#"{"t":"term-mode","mode":"raw"}"#.utf8)), on: .control)
        let wire = try XCTUnwrap(hub.termWireForTests)
        var seed: UInt64 = 1
        let bytes: [UInt8] = (0..<30000).map { _ in seed = seed &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded: seed >> 56) }
        XCTAssertTrue(wire.emit(.snapshot(.pty(1), TermGridSize(cols: 80, rows: 24), bytes)))
        XCTAssertGreaterThan(delivered.all.count, 2)
        XCTAssertLessThanOrEqual(delivered.wire.map(\.count).max()!, 2048)
    }

    /// ON THE CHANNEL, not only at the encoder: a rebind while the old wire's frames wait in its pacer DROPS them, and the
    /// new wire's start is the next thing the channel carries once pion has room — nothing of the old wire after it.
    func testAPacedRebindDropsTheOldWiresQueueAndItsStartLeadsTheChannel() throws {
        let c = PacedConnection("sock:paced")
        let raw = wrapMessage(Data(#"{"t":"term-mode","mode":"raw"}"#.utf8))
        hub.register(clientId: c.clientId, peer: c)
        hub.connection(c, didOpen: .terminal); hub.connection(c, didOpen: .control)
        hub.connection(c, didReceive: raw, on: .control)
        XCTAssertEqual(c.sent, [[4, 0]], "an empty channel: the start goes at once")
        let old = try XCTUnwrap(hub.termWireForTests)
        c.setHeld(10_000_000)                                              // pion full: nothing more fits
        XCTAssertTrue(old.emit(.snapshot(.pty(1), TermGridSize(cols: 80, rows: 24), Array("hello".utf8))))
        XCTAssertTrue(old.emit(.output(.pty(1), Array(" world".utf8))))
        XCTAssertEqual(c.sent.count, 1, "the old wire's frames wait in its pacer, not in pion")
        hub.connection(c, didReceive: raw, on: .control)                   // a re-declaration: a fresh wire
        c.setHeld(0)                                                       // pion drains
        let deadline = Date().addingTimeInterval(2)
        while c.sent.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        Thread.sleep(forTimeInterval: 0.05)                                // anything late would land now
        XCTAssertEqual(c.sent, [[4, 0], [4, 0]], "the old wire's queue was dropped and the new start leads the channel")
    }

    func testARebindRetiresTheOldWireBeforeTheNewStart() {
        let got = Delivered()
        hub.termWireTap = { got.add($0) }
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        let old = try! XCTUnwrap(hub.termWireForTests)
        send(a, #"{"t":"term-mode","mode":"raw"}"#)
        old.emit(.closed(.pty(7)))                                             // a serial path still holding it
        XCTAssertEqual(got.all, [[4, 0], [4, 0]], "nothing of the old wire after the new start")
    }

    /// Review N3: the race itself. Emitters on OTHER tabs' serial paths run concurrently with a rebind:
    /// one picks the NEW wire up the moment it is reachable (sending its start lazily), and one still
    /// holds the OLD wire. The barrier holds the rebind exactly there; the old wire must already be
    /// retired, or its frame lands after the new wire's start.
    func testAnOldWireEmitterRacingTheRebindSendsNothingAfterTheNewStart() {
        let got = Delivered()
        hub.termWireTap = { got.add($0) }
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        rawTerminal(a)
        let old = try! XCTUnwrap(hub.termWireForTests)
        hub.afterTermWireInstalledForTests = { [hub] in
            hub!.afterTermWireInstalledForTests = nil
            hub!.termWireForTests?.emit(.closed(.pty(1)))                      // tab 1's path: the new wire
            old.emit(.closed(.pty(7)))                                         // tab 7's path: still the old one
        }
        send(a, #"{"t":"term-mode","mode":"raw"}"#)
        let closed1: [UInt8] = [3, 5] + Array("pty:1".utf8)
        XCTAssertEqual(got.all, [[4, 0], [4, 0], closed1], "no old-wire frame after the new wire's start")
    }

    // MARK: the bar (docs/superpowers/specs/2026-10-01-tab-menu-and-order-design.md, §3)

    private func order() -> [TermTabID] { terminals.descriptors().tabs.map(\.id) }

    /// Three detached `pty:` tabs, announced as a real open announces them — through the HUB's own
    /// `onTabsChanged`, which syncs the session's order and then broadcasts `term-list`.
    private func threeTabs() throws {
        for _ in 0..<3 { _ = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24)) }
        terminals.onTabsChanged?()
    }

    /// A real SimManager behind the hub — the session state the order lives in — with no capture.
    private func sessionState() -> SimManager {
        let sim = SimManager(makeEncoder: { _, _, _, _ in NullEncoder() }, channelHub: hub,
                             defaultPrefs: VideoPrefs(fps: 60, scale: 1, bitrateBps: 2_000_000),
                             bitrateCap: 8_000_000, throttleFps: 1, throttleBitrateBps: 100_000, graceSeconds: 60)
        sim.attachesCaptureForTests = false
        sim.windowOwnerPID = { _ in 4242 }
        sim.existingWindowIDs = { [] }
        hub.simDelegate = sim
        return sim
    }

    private func viewSet(_ sim: SimManager) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: sim.viewSetPayload(forClient: "a"))) as? [String: Any] ?? [:]
    }
    private func tabOrder(_ sim: SimManager) -> [String] { viewSet(sim)["tabOrder"] as? [String] ?? [] }

    /// THE POINT: a driver's move of a TERMINAL reorders the session's bar AND the pool — so the
    /// `term-list` order and `TabPool.close`'s "previous neighbour" are the bar the person sees. A move of
    /// a WINDOW reorders the bar and leaves the pool alone.
    func testADriversMoveOfATerminalReordersTheBarAndArrangesThePool() throws {
        let sim = sessionState()
        defer { hub.simDelegate = nil }
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        try threeTabs()
        XCTAssertTrue(sim.openWindow(sourceID: "win:11", requestedBy: "a"))
        XCTAssertEqual(tabOrder(sim), ["pty:1", "pty:2", "pty:3", "win:11"], "precondition: the bar nobody dragged")
        send(a, #"{"t":"move-tab","tab":"pty:3","before":"pty:1"}"#)
        XCTAssertEqual(tabOrder(sim), ["pty:3", "pty:1", "pty:2", "win:11"])
        XCTAssertEqual(order(), [.pty(3), .pty(1), .pty(2)], "the pool follows the bar")
        send(a, #"{"t":"move-tab","tab":"win:11","before":"pty:1"}"#)
        XCTAssertEqual(tabOrder(sim), ["pty:3", "win:11", "pty:1", "pty:2"])
        XCTAssertEqual(order(), [.pty(3), .pty(1), .pty(2)], "a window's move leaves the terminals' order")
        send(a, #"{"t":"move-tab","tab":"pty:3","before":null}"#)
        XCTAssertEqual(tabOrder(sim), ["win:11", "pty:1", "pty:2", "pty:3"])
        XCTAssertEqual(order(), [.pty(1), .pty(2), .pty(3)])
    }

    /// A bar of three terminal tabs and two windows, dragged to `pty:2 pty:3 win:11 pty:1 win:12`, on the
    /// windows surface with `win:12` focused, `pty:3` the active terminal, the driver `a` and a passive
    /// window-less client watching the broadcasts. Returns that watcher.
    private func interleavedBar(_ sim: SimManager, _ a: OpenTestPeer) throws -> WindowlessConnection {
        hub.register(clientId: "a", peer: a)                                    // the driver
        let w = WindowlessConnection("sock:w")
        hub.register(clientId: w.clientId, peer: w)                             // passive
        hub.connection(w, didOpen: .control)
        try threeTabs()
        XCTAssertTrue(sim.openWindow(sourceID: "win:11", requestedBy: "a"))
        XCTAssertTrue(sim.openWindow(sourceID: "win:12", requestedBy: "a"))
        send(a, #"{"t":"move-tab","tab":"pty:1","before":"win:12"}"#)
        send(a, #"{"t":"set-view","surface":"windows"}"#)
        XCTAssertEqual(tabOrder(sim), ["pty:2", "pty:3", "win:11", "pty:1", "win:12"], "precondition: the bar")
        XCTAssertEqual(terminals.descriptors().activeId, .pty(3), "precondition: the active terminal")
        XCTAssertEqual(viewSet(sim)["focused"] as? String, "win:12", "precondition: the focus")
        return w
    }

    /// What `w` was sent after `mark`: each `term-list` as its active tab, each `view-set` as its surface and
    /// focus — the two messages a landing is made of, in the order they arrived.
    private func landingMessages(_ w: WindowlessConnection, after mark: Int) -> [String] {
        w.controlMessages.dropFirst(mark).compactMap { m in
            guard let o = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any],
                  let t = o["t"] as? String else { return nil }
            if t == "term-list" { return "term-list \(o["activeId"] as? String ?? "-")" }
            guard t == "view-set" else { return nil }
            let surface = (o["view"] as? [String: Any])?["surface"] as? String ?? "-"
            return "view-set \(surface) \(o["focused"] as? String ?? "-")"
        }
    }

    /// A landing as a client hears it: the `term-list` naming the tab FIRST — before ANY `view-set` (the host
    /// sends more than one for a close: the audio election's, the caller's), each of which shows the terminal
    /// surface — and nothing after it but `then`.
    private func assertLanded(_ got: [String], on tab: String, then viewSet: String, line: UInt = #line) {
        XCTAssertEqual(got.first, "term-list \(tab)", "the tab is named before any view-set: \(got)", line: line)
        XCTAssertEqual(Set(got.dropFirst()), [viewSet], "then only the landed view-set: \(got)", line: line)
    }

    /// CLOSING THE WINDOW THE PERSON WAS AT LANDS ON THE TAB TO ITS LEFT — here a TERMINAL tab (asked
    /// 2026-10-01; `SessionState.landing`). The client says they were at it (`land: true`): the pool makes the
    /// tab active, the surface is the terminal's, the window focus falls back to `win:11`, and every client
    /// hears the `term-list` naming the tab BEFORE any `view-set` that shows the surface — so a phone never
    /// shows the terminal on the tab it was not on.
    func testClosingTheWindowThePersonWasAtLandsOnTheTerminalTabToItsLeft() throws {
        let sim = sessionState()
        defer { hub.simDelegate = nil }
        let a = peer("a")
        let w = try interleavedBar(sim, a)
        let mark = w.controlMessages.count
        send(a, #"{"t":"unsubscribe","source":"win:12","land":true}"#)
        XCTAssertEqual(terminals.descriptors().activeId, .pty(1), "the tab to its left is active")
        assertLanded(landingMessages(w, after: mark), on: "pty:1", then: "view-set terminal win:11")
    }

    /// THE REVIEW'S DESKTOP CASE (2026-10-02): a close that does NOT say the person was at the window — on a
    /// desktop they were typing in the terminal and clicked the window's `×` — lands NOWHERE, whatever the
    /// surface says (a palette pick leaves it "windows"): the terminal stays on the tab being typed in, no
    /// `term-list`, and only the window focus falls back. A park likewise.
    func testACloseThatDoesNotSayLandLeavesTheTerminalAlone() throws {
        let sim = sessionState()
        defer { hub.simDelegate = nil }
        let a = peer("a")
        let w = try interleavedBar(sim, a)
        var mark = w.controlMessages.count
        send(a, #"{"t":"unsubscribe","source":"win:12"}"#)
        XCTAssertEqual(terminals.descriptors().activeId, .pty(3), "the shell being typed into stays active")
        XCTAssertEqual(Set(landingMessages(w, after: mark)), ["view-set windows win:11"], "no term-list, no surface change")

        XCTAssertTrue(sim.openWindow(sourceID: "win:13", requestedBy: "a"))     // after win:11, focused
        send(a, #"{"t":"move-tab","tab":"pty:2","before":"win:13"}"#)            // a terminal to its left
        mark = w.controlMessages.count
        send(a, #"{"t":"minimize-window","source":"win:13","land":false}"#)
        XCTAssertEqual(terminals.descriptors().activeId, .pty(3))
        XCTAssertEqual(Set(landingMessages(w, after: mark)), ["view-set windows win:11"])
    }

    /// Parking (`−`) with `land` lands the same way. An APP QUITTING NEVER LANDS: it is discovered on any
    /// client's listing, possibly long after the person moved on.
    func testMinimizingLandsAndAnAppQuittingNeverDoes() throws {
        let sim = sessionState()
        defer { hub.simDelegate = nil }
        let a = peer("a")
        let w = try interleavedBar(sim, a)
        var mark = w.controlMessages.count
        send(a, #"{"t":"minimize-window","source":"win:12","land":true}"#)
        XCTAssertEqual(terminals.descriptors().activeId, .pty(1))
        assertLanded(landingMessages(w, after: mark), on: "pty:1", then: "view-set terminal win:11")

        send(a, #"{"t":"switch-terminal","id":"pty:3"}"#)
        send(a, #"{"t":"set-view","surface":"windows"}"#)
        send(a, #"{"t":"move-tab","tab":"pty:2","before":"win:11"}"#)              // pty:3 pty:2 win:11 pty:1 win:12
        mark = w.controlMessages.count
        sim.applyListing(sourceIDs: [], authorized: true)                       // win:11's app quit (win:12 is parked)
        XCTAssertEqual(terminals.descriptors().activeId, .pty(3), "a quit moves no terminal")
        XCTAssertEqual(Set(landingMessages(w, after: mark)), ["view-set windows -"], "nor the surface")
    }

    /// THE POOL SWITCHES BEFORE THE STATE CHANGES (review, 2026-10-02): the landing is read, the pool switched
    /// — its `term-list` sent — and only then the close committed. Committing first left a gap in which a
    /// `view-set` from another thread could carry the terminal surface ahead of the `term-list`. Seen from
    /// inside the pool's announcement: the window is still in the state and the surface still the windows'.
    func testThePoolSwitchesBeforeTheCloseIsCommitted() throws {
        let sim = sessionState()
        defer { hub.simDelegate = nil; hub.terminalTabsReadForTests = nil }
        let a = peer("a")
        _ = try interleavedBar(sim, a)
        var seen: [String] = []
        hub.terminalTabsReadForTests = { [unowned self] in
            let vs = self.viewSet(sim)
            let windows = (vs["windows"] as? [[String: Any]] ?? []).compactMap { $0["source"] as? String }
            seen.append("\(windows.joined(separator: ",")) \((vs["view"] as? [String: Any])?["surface"] as? String ?? "-")")
        }
        send(a, #"{"t":"unsubscribe","source":"win:12","land":true}"#)
        XCTAssertEqual(seen.first, "win:11,win:12 windows", "the pool announced before the state changed: \(seen)")
        XCTAssertEqual(terminals.descriptors().activeId, .pty(1))
    }

    /// A window to its LEFT is landed on as a window: the pool is not touched, the surface stays.
    func testAWindowToTheLeftIsTheWindowRule() throws {
        let sim = sessionState()
        defer { hub.simDelegate = nil }
        let a = peer("a")
        let w = try interleavedBar(sim, a)
        XCTAssertTrue(sim.openWindow(sourceID: "win:13", requestedBy: "a"))      // after win:12: a window to its left
        let mark = w.controlMessages.count
        send(a, #"{"t":"unsubscribe","source":"win:13","land":true}"#)
        XCTAssertEqual(terminals.descriptors().activeId, .pty(3), "a window to its left: the pool is not touched")
        XCTAssertEqual(Set(landingMessages(w, after: mark)), ["view-set windows win:12"], "no term-list")
    }

    /// A PASSIVE client's `move-tab` and `rename-tab` change nothing — not the bar, not the pool, not a
    /// name — and the driver's do (the control arm).
    func testAPassiveClientsMoveAndRenameChangeNothing() throws {
        let sim = sessionState()
        defer { hub.simDelegate = nil }
        let a = peer("a"), b = peer("b")
        hub.register(clientId: "a", peer: a)
        hub.register(clientId: "b", peer: b)                                   // passive
        try threeTabs()
        sim.openWindow(sourceID: "win:11", requestedBy: "a")
        let bar = tabOrder(sim)
        send(b, #"{"t":"move-tab","tab":"pty:3","before":"pty:1"}"#)
        send(b, #"{"t":"move-tab","tab":"win:11","before":"pty:1"}"#)
        send(b, #"{"t":"rename-tab","tab":"pty:1","name":"mine"}"#)
        send(b, #"{"t":"rename-tab","tab":"win:11","name":"mine"}"#)
        XCTAssertEqual(tabOrder(sim), bar)
        XCTAssertEqual(order(), [.pty(1), .pty(2), .pty(3)])
        XCTAssertNil(terminals.descriptors().tabs[0].name)
        XCTAssertNil((viewSet(sim)["windows"] as? [[String: Any]])?.first?["name"])
        send(a, #"{"t":"move-tab","tab":"pty:3","before":"pty:1"}"#)
        send(a, #"{"t":"rename-tab","tab":"pty:1","name":"build"}"#)
        send(a, #"{"t":"rename-tab","tab":"win:11","name":"mail"}"#)
        XCTAssertEqual(order(), [.pty(3), .pty(1), .pty(2)])
        XCTAssertEqual(terminals.descriptors().tabs.first { $0.id == .pty(1) }?.name, "build")
        XCTAssertEqual((viewSet(sim)["windows"] as? [[String: Any]])?.first?["name"] as? String, "mail")
    }

    /// WITHOUT A SimManager (the test-pattern harness) only terminals exist: the driver's `move-tab`
    /// moves one within the pool, `before` a terminal or the end. A window `before` names nothing there.
    func testWithoutASessionStateAMoveTabMovesTheTerminalInThePool() throws {
        let a = peer("a")
        hub.register(clientId: "a", peer: a)
        try threeTabs()
        send(a, #"{"t":"move-tab","tab":"pty:3","before":"pty:1"}"#)
        XCTAssertEqual(order(), [.pty(3), .pty(1), .pty(2)])
        send(a, #"{"t":"move-tab","tab":"pty:3","before":null}"#)
        XCTAssertEqual(order(), [.pty(1), .pty(2), .pty(3)])
        send(a, #"{"t":"move-tab","tab":"pty:1","before":"win:5"}"#)
        send(a, #"{"t":"move-tab","tab":"win:5","before":null}"#)
        XCTAssertEqual(order(), [.pty(1), .pty(2), .pty(3)], "no windows here: nothing to move or move before")
        send(a, #"{"t":"rename-tab","tab":"pty:2","name":"build"}"#)
        XCTAssertEqual(terminals.descriptors().tabs[1].name, "build", "a pty: rename needs no session state")
    }

    /// The TERMINAL HALF of the bar follows the pool through the hub's `onTabsChanged` — a tab that
    /// opens enters it, one that closes leaves it — and every change reaches every control client as a
    /// `view-set` BEFORE its `term-list`; a re-announcement that changes no tab (a title) sends a
    /// `term-list` and no `view-set`. A WINDOW-LESS client is among them, and drives the bar.
    func testTheBarsTerminalHalfFollowsThePoolAndReachesAWindowlessClient() throws {
        let sim = sessionState()
        defer { hub.simDelegate = nil }
        let w = WindowlessConnection("sock:w")
        hub.register(clientId: w.clientId, peer: w)                             // the first client drives
        hub.connection(w, didOpen: .control)
        func kinds() -> [String] {
            w.controlMessages.compactMap { m in
                guard let o = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any],
                      let t = o["t"] as? String, t == "view-set" || t == "term-list" else { return nil }
                return t == "view-set" ? "view-set \((o["tabOrder"] as? [String] ?? []).joined(separator: ","))" : t
            }
        }
        let mark = kinds().count
        _ = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        terminals.onTabsChanged?()
        XCTAssertEqual(Array(kinds().dropFirst(mark)), ["view-set pty:1", "term-list"], "the order first")
        terminals.onTabsChanged?()                                              // a title changed
        XCTAssertEqual(Array(kinds().dropFirst(mark)), ["view-set pty:1", "term-list", "term-list"],
                       "no tab changed: no view-set")
        _ = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        terminals.onTabsChanged?()
        XCTAssertEqual(tabOrder(sim), ["pty:1", "pty:2"])
        send(w, #"{"t":"move-tab","tab":"pty:2","before":"pty:1"}"#)          // permitted to a window-less driver
        XCTAssertEqual(order(), [.pty(2), .pty(1)])
        XCTAssertEqual(tabOrder(sim), ["pty:2", "pty:1"])
        XCTAssertTrue(terminals.close(.pty(2)))
        XCTAssertEqual(tabOrder(sim), ["pty:1"], "a closed tab leaves the bar")
        XCTAssertEqual(kinds().last, "term-list")
    }

    /// THE HOST'S BELL reaches the DRIVER (docs/terminal.md, "The bell"): its page hidden, its terminal-pause
    /// applied, a tab's bell reaches no xterm.js — the driver hears `term-bell`, once; a passive client never.
    func testABellWhileTheDriverIsPausedReachesItAsATermBell() throws {
        let w = WindowlessConnection("sock:w")
        hub.register(clientId: w.clientId, peer: w)                             // the first client drives
        hub.connection(w, didOpen: .control)
        let id = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        let bells = { w.controlMessages.filter { $0.contains(#""t":"term-bell""#) } }
        send(w, #"{"t":"terminal-pause"}"#)
        let deadline = Date().addingTimeInterval(5)
        while !terminals.forwardingIsPaused && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(terminals.forwardingIsPaused, "precondition: the pause applied after its hold")
        terminals.feedForTests(id, Array("build finished\u{07}".utf8))
        terminals.feedForTests(id, Array("\u{07}".utf8))
        let got = bells().compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
        XCTAssertEqual(got, [["t": "term-bell", "term": id.wire]])
    }

    /// REVIEW M9 (2026-10-01): `onTabsChanged` runs on several threads — the hub's message path, the title
    /// debounce, tmux's callbacks, a shell's exit. A read of the pool that loses the race to a fresher one
    /// must not be SYNCED after it: a closed tab came back into the bar's order (and the last `term-list`)
    /// as a ghost until the next tab change. The read, the sync and the broadcast are one step.
    func testAStaleReadOfThePoolNeverLandsAfterAFresherOne() throws {
        let sim = sessionState()
        defer { hub.simDelegate = nil; hub.terminalTabsReadForTests = nil }
        _ = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        _ = try XCTUnwrap(terminals.openDetachedForTests(cols: 80, rows: 24))
        terminals.onTabsChanged?()
        XCTAssertEqual(tabOrder(sim), ["pty:1", "pty:2"], "precondition")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let once = NSLock()
        var armed = true
        hub.terminalTabsReadForTests = {
            let first: Bool = once.withLock { defer { armed = false }; return armed }
            guard first else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        let tm = terminals!
        let staleDone = DispatchSemaphore(value: 0), closeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { tm.onTabsChanged?(); staleDone.signal() }    // a title changed: reads both tabs
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the stale read is held")
        DispatchQueue.global().async { _ = tm.close(.pty(2)); closeDone.signal() }   // the fresher read: pty:1 alone
        let closedFirst = closeDone.wait(timeout: .now() + 0.3) == .success        // unserialised, it lands FIRST
        release.signal()
        XCTAssertEqual(staleDone.wait(timeout: .now() + 5), .success)
        if !closedFirst { XCTAssertEqual(closeDone.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(tabOrder(sim), ["pty:1"], "the closed tab is no ghost in the bar")
    }

    private func send(_ c: ClientConnection, _ json: String) {
        hub.connection(c, didReceive: wrapMessage(Data(json.utf8)), on: .control)
    }
}

/// The tab's shell is up (its prompt is on the host's screen).
func waitForPrompt(_ tm: TerminalManager, _ id: TermTabID) {
    let deadline = Date().addingTimeInterval(10)
    while !(tm.hostText(id).contains("$") || tm.hostText(id).contains("%") || tm.hostText(id).contains("#"))
            && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    Thread.sleep(forTimeInterval: 0.3)
}

/// Ask the tab's shell to send DSR 5n and report how much of an answer it read within 2 s: "R=3" when
/// someone answered `ESC[0n` into the pty, "R=0" when nobody did. Only the HOST's answer reaches the
/// pty in these tests (no xterm.js is attached), so "R=3" means the host answered. Waits for the line.
@discardableResult
func askDSR(_ tm: TerminalManager, _ id: TermTabID) -> String? {
    func count(_ k: String) -> Int { tm.hostText(id).components(separatedBy: k).count - 1 }
    let before0 = count("R=0"), before3 = count("R=3")
    tm.write(Data("bash -c 'printf \"\\033[5n\"; IFS= read -rs -t 2 -d n r; echo \"R\"=\"${#r}\"'\r".utf8), toTerminal: id)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if count("R=3") > before3 { return "R=3" }
        if count("R=0") > before0 { return "R=0" }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return nil
}
