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

/// Clients over a MESSAGE SOCKET (docs/sources-and-focus.md, "Window-less clients"): the hello admits
/// one under `sock:<id>`, its channels open with it, it gets the terminal, and anything malformed or a
/// closed socket takes it away — through the hub's REAL entry points.
final class SocketClientsTests: XCTestCase {
    private var terminals: TerminalManager!
    private var hub: ChannelHub!
    private var clients: SocketClients!

    override func setUp() {
        terminals = TerminalManager(cols: 80, rows: 24)
        hub = ChannelHub(terminals: terminals, injector: nil, encoder: NullEncoder(),
                         terminalPauseHold: .milliseconds(50))
        clients = SocketClients(hub: hub)
    }

    override func tearDown() {
        clients.closeAll(reason: "the test is over")
        clients.drainForTests()
        terminals.closeAll()
    }

    private func socket() -> MemorySocket { let s = MemorySocket(); clients.accept(s); return s }

    func testAHelloAdmitsTheClientWithItsControlStateAndTerminalList() {
        let s = socket()
        s.hello("tab-1")
        clients.drainForTests()
        XCTAssertNil(s.closedReason)
        XCTAssertEqual(s.controlState?.active, true, "the first client drives: \(s.controlMessages)")
        XCTAssertEqual(s.controlState?.clients, 1)
        XCTAssertTrue(s.controlMessages.contains { $0.contains(#""t":"term-list""#) }, "\(s.controlMessages)")
    }

    func testTheTerminalReachesASocketClient() async {
        let s = socket()
        s.hello("tab-1")
        s.sends(.control, #"{"t":"term-mode","mode":"raw"}"#)
        s.sends(.control, #"{"t":"open-terminal"}"#)
        clients.drainForTests()
        XCTAssertEqual(hub.termWireClientId, "sock:tab-1", "a socket client's id is prefixed")
        await waitUntil({ s.terminalFrames.count >= 2 }, "the wire start and the new tab's snapshot")
        guard let bytes = s.terminalFrames.first,
              case let .start(epoch, compressed)? = try? TermWireMessage.decode(bytes) else { return XCTFail("every wire opens with RZT1 START") }
        XCTAssertGreaterThan(epoch, 0)
        XCTAssertFalse(compressed.isEmpty)
    }

    func testAConnectClaimsAndAReconnectKeepsItsPlace() {
        let a = socket(); a.hello("tab-a")
        let b = socket(); b.hello("tab-b", "reconnect")
        clients.drainForTests()
        XCTAssertEqual(b.controlState?.active, false, "a reconnect does not take control")
        let c = socket(); c.hello("tab-c", "connect")
        clients.drainForTests()
        XCTAssertEqual(c.controlState?.active, true, "a connect does")
        XCTAssertEqual(a.controlState?.active, false)
    }

    /// "Move here" from a page the host already has as the driver (it missed the `control-state` that said so): the
    /// host moves nothing and SAYS so again, so the page stops showing itself passive (ActiveClientTracker.claim).
    func testAClaimFromTheDriverReStatesItsControl() {
        let a = socket(); a.hello("tab-a")
        let b = socket(); b.hello("tab-b", "reconnect")
        clients.drainForTests()
        let states = { (s: MemorySocket) in s.controlMessages.filter { $0.contains(#""t":"control-state""#) }.count }
        let before = (a: states(a), b: states(b))
        a.sends(.control, #"{"t":"claim-control"}"#)
        clients.drainForTests()
        XCTAssertEqual(states(a), before.a + 1, "the driver hears it drives, again: \(a.controlMessages)")
        XCTAssertEqual(a.controlState?.active, true)
        XCTAssertEqual(b.controlState?.active, false, "nothing moved")
    }

    func testAFirstFrameThatIsNotAHelloClosesTheSocketAndAdmitsNothing() {
        let s = socket()
        s.sends(.control, #"{"t":"list-terminals"}"#)
        clients.drainForTests()
        XCTAssertEqual(s.closedReason, "expected a hello")
        let t = socket(); t.hello("tab-2")
        clients.drainForTests()
        XCTAssertEqual(t.controlState?.clients, 1, "nothing was registered for the refused socket")
    }

    func testASecondHelloClosesTheSocketAndUnregistersIt() {
        let s = socket()
        s.hello("tab-1"); s.hello("tab-1")
        clients.drainForTests()
        XCTAssertEqual(s.closedReason, "a second hello")
        let t = socket(); t.hello("tab-2", "reconnect")
        clients.drainForTests()
        XCTAssertEqual(t.controlState?.clients, 1, "the closed socket's client left")
        XCTAssertEqual(t.controlState?.active, true, "so the newcomer is the only one, and drives")
    }

    func testAMalformedFrameClosesTheSocket() {
        let s = socket()
        s.hello("tab-1")
        s.deliver(Data([0x09, 0x00]))
        clients.drainForTests()
        XCTAssertEqual(s.closedReason, "malformed frame")
    }

    func testAClosedSocketUnregistersItsClient() {
        let a = socket(); a.hello("tab-a")
        let b = socket(); b.hello("tab-b")                          // connect: b drives, a is passive
        clients.drainForTests()
        b.clientClose()
        clients.drainForTests()
        XCTAssertEqual(a.controlState?.active, true, "the one client left is promoted")
        XCTAssertEqual(a.controlState?.clients, 1)
    }

    /// The SAME client on a new socket replaces the old one — closed, never left half-registered — and
    /// the old socket's close must not take the new one down.
    func testTheSameClientOnANewSocketReplacesTheOldOne() {
        let old = socket(); old.hello("tab-1")
        clients.drainForTests()
        let new = socket(); new.hello("tab-1", "reconnect")
        clients.drainForTests()
        XCTAssertEqual(old.closedReason, "replaced by a new socket")
        let other = socket(); other.hello("tab-2", "reconnect")
        clients.drainForTests()
        XCTAssertEqual(other.controlState?.clients, 2, "tab-1 is still registered, on its new socket")
        XCTAssertEqual(other.controlState?.active, false)
        new.sends(.control, #"{"t":"list-terminals"}"#)
        clients.drainForTests()
        XCTAssertTrue(new.controlMessages.contains { $0.contains(#""t":"control-state","active":true"#) },
                      "the replacement kept tab-1's place as the driver: \(new.controlMessages)")
    }

    /// The `admission.closed` guard: a frame a refused socket delivers AFTER its close must not admit it.
    func testALateHelloOnARefusedSocketAdmitsNothing() {
        let ghost = socket()
        ghost.sends(.control, #"{"t":"list-terminals"}"#)           // refused: not a hello
        clients.drainForTests()
        XCTAssertEqual(ghost.closedReason, "expected a hello")
        ghost.deliverEvenAfterClose(SocketFrame.encode(.meta, Data(#"{"t":"hello","v":1,"client":"ghost","intent":"connect"}"#.utf8)))
        let t = socket(); t.hello("tab-2", "reconnect")
        clients.drainForTests()
        XCTAssertEqual(t.controlState?.clients, 1, "the ghost was not admitted: \(t.controlMessages)")
        XCTAssertEqual(t.controlState?.active, true)
    }

    /// A REFUSAL TAKES EFFECT AT ONCE (final review F1): frames the socket delivered BEFORE the refusal
    /// ran, queued behind it, must not act. While the teardown waited for the close's own hop — appended
    /// to the queue AFTER them — [a malformed frame, then `hello(connect)`] admitted the client and took
    /// control from the driver, then unregistered it.
    func testAHelloQueuedBehindARefusalAdmitsNothing() {
        let a = socket(); a.hello("tab-a")
        clients.drainForTests()
        XCTAssertEqual(a.controlState?.active, true, "a drives: \(a.controlMessages)")
        let seen = a.controlMessages.count
        let b = socket()
        clients.suspendForTests()
        b.deliver(Data([0x09, 0x00]))                              // malformed: refused
        b.hello("tab-b", "connect")                                // already queued behind the refusal
        clients.resumeForTests()
        clients.drainForTests()
        XCTAssertEqual(b.closedReason, "malformed frame")
        let later = Array(a.controlMessages.dropFirst(seen))
        for json in later where json.contains(#""t":"control-state""#) {
            XCTAssertTrue(json.contains(#""active":true"#) && json.contains(#""clients":1"#),
                          "the refused socket's queued hello moved control or joined: \(later)")
        }
        XCTAssertEqual(a.controlState?.active, true, "a still drives")
        XCTAssertEqual(a.controlState?.clients, 1, "and the client count is unchanged")
    }

    /// The same for an ADMITTED socket refused for a second hello: what it queued behind it (a key, an
    /// `open-terminal`) must not reach the hub.
    func testAnOpenTerminalQueuedBehindASecondHelloOpensNothing() {
        let s = socket()
        clients.suspendForTests()
        s.hello("tab-1")
        s.hello("tab-1")                                           // refused: a second hello
        s.sends(.control, #"{"t":"open-terminal"}"#)               // already queued behind the refusal
        clients.resumeForTests()
        clients.drainForTests()
        XCTAssertEqual(s.closedReason, "a second hello")
        XCTAssertTrue(terminals.isEmpty, "the refused socket's queued open-terminal opened a shell")
    }

    /// The current-connection guard: a socket REPLACED for the same client, whose close is still in
    /// flight, speaks for nobody.
    func testAReplacedSocketSpeaksForNobody() {
        let old = socket(); old.holdsClose = true
        old.hello("tab-1")
        let new = socket(); new.hello("tab-1", "reconnect")
        clients.drainForTests()
        XCTAssertEqual(old.closedReason, "replaced by a new socket")
        old.sends(.control, #"{"t":"term-mode","mode":"raw"}"#)      // the new connection never declared raw
        clients.drainForTests()
        XCTAssertNil(hub.termWireClientId, "the old socket declared raw for the shared id")
    }

    /// A close racing a fresh hello for the SAME id. With one queue per socket this order was a race (the
    /// old close's `unregister` could land after the new `register`, leaving a half-registered client);
    /// on the shared queue it is deterministic.
    func testACloseThenANewHelloForTheSameIdLeavesTheNewClientDriving() {
        let s1 = socket(); s1.hello("tab-1")
        s1.clientClose()
        let s2 = socket(); s2.hello("tab-1", "connect")
        clients.drainForTests()
        XCTAssertEqual(s2.controlState?.active, true, "\(s2.controlMessages)")
        XCTAssertEqual(s2.controlState?.clients, 1)
    }

    /// **THE SESSION ENDING STOPS ACCEPTING** (`HostSession.end`): `closeAll` closes the sockets open at
    /// that moment, and one arriving after it is closed at once — never started, never admitted.
    func testASocketAcceptedAfterCloseAllIsRefused() {
        let s = socket(); s.hello("tab-1")
        clients.drainForTests()
        clients.closeAll(reason: "the session ended")
        clients.drainForTests()
        XCTAssertEqual(s.closedReason, "the session ended")
        let late = socket()
        XCTAssertEqual(late.closedReason, "the session ended", "a socket after the end is refused at accept")
        late.hello("tab-2")
        clients.drainForTests()
        XCTAssertNil(late.controlState, "and nothing admitted it: \(late.controlMessages)")
    }

    /// **A RELOAD OF THE LOCAL WINDOW** — the same per-tab id on a new socket, saying `connect` — with a
    /// SECOND client present, which is what tells `rebindPeer` from unregister-then-register: the driver
    /// unregistered would promote the other client, however briefly.
    func testTheSameClientReconnectingWithConnectKeepsItsPlaceAndDrives() {
        let other = socket(); other.hello("tab-other")
        let old = socket(); old.hello("tab-1")                     // connect: tab-1 drives
        clients.drainForTests()
        XCTAssertEqual(old.controlState?.active, true, "precondition: \(old.controlMessages)")
        let seen = other.controlMessages.count
        let new = socket(); new.hello("tab-1", "connect")
        clients.drainForTests()
        XCTAssertEqual(old.closedReason, "replaced by a new socket")
        XCTAssertEqual(new.controlState?.active, true, "the reload drives: \(new.controlMessages)")
        XCTAssertEqual(new.controlState?.clients, 2)
        for json in other.controlMessages.dropFirst(seen) where json.contains(#""t":"control-state""#) {
            XCTAssertTrue(json.contains(#""active":false"#) && json.contains(#""clients":2"#),
                          "the other client was promoted or saw tab-1 leave: \(json)")
        }
    }
}
