import XCTest
@testable import RdevCore
final class FastCarrierTests: XCTestCase {
    func testOnlyRepliesOnEveryRTCStreamEarnMigration() {
        let p = FastCarrierPolicy(); for s in UInt8(0)...2 { _ = p.channelState(.webRTC, stream: s, open: true, nowMs: 0) }
        let probes = p.tick(nowMs: 0); XCTAssertEqual(probes.count, 3)
        for e in probes { if case .sendProbe(_, let s, let n) = e { _ = p.probeReply(.webSocket, stream: s, nonce: n, nowMs: 1) } }
        XCTAssertEqual(p.selected, .webSocket)
        for e in probes { if case .sendProbe(_, let s, let n) = e { _ = p.probeReply(.webRTC, stream: s, nonce: n, nowMs: 2) } }
        XCTAssertEqual(p.selected, .webRTC)
    }
    func testCloseFallsBackAndLongSleepDoesNotBurst() {
        let p = FastCarrierPolicy()
        for c in [FastCarrierKind.webSocket, .webRTC] { for s in UInt8(0)...2 { _ = p.channelState(c, stream: s, open: true, nowMs: 0) } }
        for e in p.tick(nowMs: 0) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: 1) } }
        XCTAssertEqual(p.selected, .webRTC)
        XCTAssertEqual(p.channelState(.webRTC, stream: 0, open: false, nowMs: 10), [.select(.webSocket)])
        XCTAssertLessThanOrEqual(p.tick(nowMs: 60000).count, 6)
    }
    func testBlackholeFallbackNeedsRecentAlternativeProof() {
        let p = FastCarrierPolicy()
        for c in [FastCarrierKind.webSocket, .webRTC] { for s in UInt8(0)...2 { _ = p.channelState(c, stream: s, open: true, nowMs: 0) } }
        for e in p.tick(nowMs: 0) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: 0) } }
        _ = p.tick(nowMs: 1000)
        for e in p.tick(nowMs: 2000) { if case .sendProbe(.webSocket, let s, let n) = e { _ = p.probeReply(.webSocket, stream: s, nonce: n, nowMs: 2999) } }
        XCTAssertEqual(p.selected, .webRTC)
        XCTAssertTrue(p.tick(nowMs: 3000).contains(.select(.webSocket)))
    }
    func testStalledDataFallsBackDespiteProbeRepliesAndCannotImmediatelyReturn() {
        let p = FastCarrierPolicy()
        for c in [FastCarrierKind.webSocket, .webRTC] { for s in UInt8(0)...2 { _ = p.channelState(c, stream: s, open: true, nowMs: 0) } }
        for e in p.tick(nowMs: 0) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: 0) } }
        p.setOutstanding(true, stream: 0, nowMs: 0)
        for t in stride(from: 1000.0, to: 5000.0, by: 1000) {
            for e in p.tick(nowMs: t) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: t) } }
        }
        XCTAssertEqual(p.selected, .webRTC)
        XCTAssertTrue(p.tick(nowMs: 5000).contains(.select(.webSocket)))
        for e in p.tick(nowMs: 6000) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: 6000) } }
        XCTAssertEqual(p.selected, .webSocket)
    }
    func testControlACKsCannotMaskStalledTerminal() {
        let p = FastCarrierPolicy()
        for c in [FastCarrierKind.webSocket, .webRTC] { for s in UInt8(0)...2 { _ = p.channelState(c, stream: s, open: true, nowMs: 0) } }
        for e in p.tick(nowMs: 0) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: 0) } }
        p.setOutstanding(true, stream: 0, nowMs: 0)
        for t in stride(from: 1000.0, to: 5000.0, by: 1000) {
            p.dataProgress(.webRTC, stream: 2, nowMs: t)
            for e in p.tick(nowMs: t) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: t) } }
        }
        XCTAssertTrue(p.tick(nowMs: 5000).contains(.select(.webSocket)))
    }

    func testProvenRTCUsesOneHeartbeatAndRetainsDataStallChecks() {
        let p = FastCarrierPolicy()
        for c in [FastCarrierKind.webSocket, .webRTC] { for s in UInt8(0)...2 { _ = p.channelState(c, stream: s, open: true, nowMs: 0) } }
        for e in p.tick(nowMs: 0) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: 0) } }
        XCTAssertEqual(p.selected, .webRTC)
        XCTAssertEqual(p.tick(nowMs: 1000).filter { if case .sendProbe(.webRTC, _, _) = $0 { return true }; return false }.count, 1)
        for t in stride(from: 2000.0, through: 10000.0, by: 1000) {
            for e in p.tick(nowMs: t) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: t) } }
        }
        XCTAssertEqual(p.selected, .webRTC)
    }

    func testAdvancingDataACKAvoidsRedundantHeartbeat() {
        let p = FastCarrierPolicy()
        for c in [FastCarrierKind.webSocket, .webRTC] { for s in UInt8(0)...2 { _ = p.channelState(c, stream: s, open: true, nowMs: 0) } }
        for e in p.tick(nowMs: 0) { if case .sendProbe(let c, let s, let n) = e { _ = p.probeReply(c, stream: s, nonce: n, nowMs: 0) } }
        p.dataProgress(.webRTC, stream: 0, nowMs: 999)
        XCTAssertEqual(p.tick(nowMs: 1000).filter { if case .sendProbe(.webRTC, _, _) = $0 { return true }; return false }.count, 0)
        XCTAssertEqual(p.tick(nowMs: 1999).filter { if case .sendProbe(.webRTC, _, _) = $0 { return true }; return false }.count, 1)
    }
}
