import XCTest
@testable import RdevCore

// The arithmetic that converts the adaptive FlexFEC controller's decision into a bitrate for one
// source's encoder.
//
// WHAT THIS FILE CAN AND CANNOT COVER, stated because the load-bearing rule is NOT here. The rule is
// "the ratio is applied to the client's REQUEST, never to the last applied value" — and that is a
// property of the CALL SITE (SimManager), not of this function. A pure function returns the same
// answer for the same arguments by definition, so a test that called it twice and asserted a stable
// result could not fail whatever the caller does; the first draft of this file did exactly that.
// RdevHostKit has no test target, so the call site is held by construction and review instead:
// `fullPrefs` is the request, `applyRecoveryPolicy` reads it and never writes it, and no code path
// stores an applied bitrate back into prefs.
//
// What IS testable, and is below: the arithmetic, the clamps, and — so the rule has teeth rather
// than just a comment — a demonstration that compounding really does diverge, with the number it
// would produce.
final class FECBitrateTests: XCTestCase {

    func testTheRatioScalesTheRequest() {
        XCTAssertEqual(fecAppliedBitrate(requested: 2_000_000, ratio: 0.85), 1_700_000)
        XCTAssertEqual(fecAppliedBitrate(requested: 20_000_000, ratio: 0.5), 10_000_000)
    }

    // A ratio of 1.0 must be EXACTLY the request, or turning FlexFEC on would quietly move every
    // client's bitrate before the controller has said anything at all.
    func testRatioOfOneIsTheRequestUnchanged() {
        for requested in [100_000, 2_000_000, 20_000_000] {
            XCTAssertEqual(fecAppliedBitrate(requested: requested, ratio: 1.0), requested)
        }
    }

    // The controller's figure is absolute against the session budget, so a source requesting less
    // than the budget can legitimately produce a ratio above 1. Raising a client ABOVE what it asked
    // for would break the rule that the client owns the total wire cost.
    func testARatioAboveOneNeverRaisesAClientAboveItsRequest() {
        XCTAssertEqual(fecAppliedBitrate(requested: 2_000_000, ratio: 1.4), 2_000_000)
        XCTAssertEqual(fecAppliedBitrate(requested: 2_000_000, ratio: 87.0), 2_000_000)
    }

    // Zero would stop the encoder outright, and a stopped encoder is indistinguishable from a dead
    // capture from every other vantage point in this project.
    func testTheRatioHasAFloorSoTheEncoderNeverStops() {
        XCTAssertEqual(fecAppliedBitrate(requested: 2_000_000, ratio: 0.0), 100_000)
        XCTAssertEqual(fecAppliedBitrate(requested: 2_000_000, ratio: -3.0), 100_000)
        XCTAssertGreaterThan(fecAppliedBitrate(requested: 1, ratio: 0.0), 0)
    }

    // THE RATCHET, DEMONSTRATED. This is what the call-site rule exists to prevent: feeding the
    // applied value back in place of the request compounds the ratio on every policy update, and
    // every individual step looks correct. Pinning the diverged number here means the hazard is a
    // measured quantity rather than a warning in a comment — 1,445,000 is what a client that asked
    // for 2 Mbit/s would silently be encoding at after just two updates at a constant 0.85.
    func testCompoundingDivergesAndIsWhyTheRequestIsTheInput() {
        let once = fecAppliedBitrate(requested: 2_000_000, ratio: 0.85)
        let compounded = fecAppliedBitrate(requested: once, ratio: 0.85)
        XCTAssertEqual(once, 1_700_000)
        XCTAssertEqual(compounded, 1_445_000)
        XCTAssertNotEqual(compounded, once,
                          "if these are ever equal the ratchet is invisible and the call-site rule "
                          + "stops being checkable by inspection")
    }

    // Rounding, not truncation: a long-running session applying a ratio that truncates would drift
    // downward by a bit per update for no reason.
    func testItRoundsRatherThanTruncates() {
        XCTAssertEqual(fecAppliedBitrate(requested: 999, ratio: 0.5), 500)
    }
}
