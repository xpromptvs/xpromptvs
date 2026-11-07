import Foundation
import Testing
@testable import RdevCore

/// AUTO AND A FORCED ZERO ARE DIFFERENT SETTINGS, and the wire has to keep them apart even while they
/// behave alike — otherwise an adaptive mode later cannot be introduced without a protocol change,
/// and an older client would read an adaptive session as "forced to zero".
@Suite struct PlayoutDelayControlTests {
    @Test("set-playout-delay carries null as Auto and a number as a floor")
    func parsesBothForms() {
        func parse(_ json: String) -> InboundMessage? {
            parseInbound(Data(json.utf8))
        }
        guard case .setPlayoutDelay(let auto, let autoMax)? = parse(#"{"t":"set-playout-delay","minMs":null}"#) else {
            Issue.record("null did not parse as set-playout-delay"); return
        }
        #expect(auto == nil)
        #expect(autoMax == nil)
        guard case .setPlayoutDelay(let forced, let forcedMax)? = parse(#"{"t":"set-playout-delay","minMs":40}"#) else {
            Issue.record("40 did not parse as set-playout-delay"); return
        }
        #expect(forced == 40)
        #expect(forcedMax == nil)   // absent maxMs is the configured ceiling — an older client's form
        // ABSENT IS MALFORMED, not Auto: a client that forgot the key is a bug, and silently reading
        // it as a setting change would apply something nobody asked for.
        #expect(parse(#"{"t":"set-playout-delay"}"#) == nil)
        // Out of range clamps rather than refusing — the control's own list cannot produce these, so
        // this only bounds a hand-written message.
        guard case .setPlayoutDelay(let high, _)? = parse(#"{"t":"set-playout-delay","minMs":99999}"#) else {
            Issue.record("a large value did not parse"); return
        }
        #expect(high == maximumPlayoutDelayMinMs)
    }

    // A WINDOW IS A SETTING OF ITS OWN. min = max = 10 is what a Chromium receiver on a clean path
    // measured best on (27 ms glass-to-glass against 57 under the permissive ceiling, every frame in
    // phase — docs/latency-campaign/2026-09-04-report.md), and it is neither "floor 10" (which keeps
    // the 500 ms ceiling) nor the gaming mode. The ceiling therefore travels beside the floor.
    @Test("set-playout-delay carries an explicit ceiling beside the floor")
    func parsesWindow() {
        func parse(_ json: String) -> InboundMessage? { parseInbound(Data(json.utf8)) }
        guard case .setPlayoutDelay(let minMs, let maxMs)? = parse(#"{"t":"set-playout-delay","minMs":10,"maxMs":10}"#) else {
            Issue.record("a window did not parse"); return
        }
        #expect(minMs == 10)
        #expect(maxMs == 10)
        // Null maxMs is the configured ceiling, exactly like absent.
        guard case .setPlayoutDelay(_, let nullMax)? = parse(#"{"t":"set-playout-delay","minMs":10,"maxMs":null}"#) else {
            Issue.record("null maxMs did not parse"); return
        }
        #expect(nullMax == nil)
        // The gaming MODE is expressible.
        guard case .setPlayoutDelay(let zeroMin, let zeroMax)? = parse(#"{"t":"set-playout-delay","minMs":0,"maxMs":0}"#) else {
            Issue.record("0/0 did not parse"); return
        }
        #expect(zeroMin == 0)
        #expect(zeroMax == 0)
        // A ceiling below the floor is a contradiction on the wire, and a ceiling with no floor names
        // no window: both are malformed rather than silently reinterpreted.
        #expect(parse(#"{"t":"set-playout-delay","minMs":40,"maxMs":20}"#) == nil)
        #expect(parse(#"{"t":"set-playout-delay","minMs":null,"maxMs":20}"#) == nil)
        // Out of range clamps, like the floor.
        guard case .setPlayoutDelay(_, let highMax)? = parse(#"{"t":"set-playout-delay","minMs":10,"maxMs":99999}"#) else {
            Issue.record("a large ceiling did not parse"); return
        }
        #expect(highMax == maximumPlayoutDelayMinMs)
    }

    @Test("view-set carries the explicit ceiling only when one was asked for")
    func viewSetCarriesCeiling() throws {
        func field(_ maxMs: Int?) throws -> Any? {
            let data = viewSetJSON(subs: [], focused: nil, playoutDelayMinMs: 10, playoutDelayMaxMs: maxMs)
            let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return obj["playoutDelayMaxMs"]
        }
        #expect(try field(nil) == nil)
        #expect(try field(10) as? Int == 10)
        #expect(try field(0) as? Int == 0)
    }

    @Test("view-set omits the floor entirely when Auto")
    func viewSetOmitsAuto() throws {
        func field(_ ms: Int?) throws -> Any? {
            let data = viewSetJSON(subs: [], focused: nil, playoutDelayMinMs: ms)
            let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return obj["playoutDelayMinMs"]
        }
        #expect(try field(nil) == nil)
        #expect(try field(40) as? Int == 40)
        // A FORCED ZERO IS STILL PRESENT ON THE WIRE. Omitting it would make it indistinguishable
        // from Auto, which is the one distinction this field exists to carry.
        #expect(try field(0) as? Int == 0)
    }
}
