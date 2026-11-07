import XCTest
@testable import RdevCore

final class InboundTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - key

    func testKeyMessage() throws {
        // JSON "\r" is decoded by JSONSerialization as a real carriage-return character (U+000D).
        let result = parseInbound(data(#"{"t":"key","data":"ls\r","term":"pty:3"}"#))
        XCTAssertEqual(result, .key("ls\r", term: .pty(3)))
    }

    /// A device-query reply is its OWN message, not a keystroke: the host routes it by the tab it names
    /// (`TerminalInput.shouldDeliverReply`), where a keystroke is refused unless that tab is active.
    func testTermReplyMessage() {
        XCTAssertEqual(parseInbound(data(#"{"t":"term-reply","data":"\u001b[0n","term":"pty:3"}"#)),
                       .termReply("\u{1b}[0n", term: .pty(3)))
        XCTAssertNil(parseInbound(data(#"{"t":"term-reply","data":"x"}"#)), "unaddressed: malformed")
        XCTAssertNil(parseInbound(data(#"{"t":"term-reply","data":"x","term":3}"#)), "numeric id: malformed")
        XCTAssertNil(parseInbound(data(#"{"t":"term-reply","term":"pty:1"}"#)))
    }

    func testKeyMessageMissingDataReturnsNil() {
        let result = parseInbound(data(#"{"t":"key","term":"pty:1"}"#))
        XCTAssertNil(result)
    }

    /// An UNADDRESSED keystroke is malformed, not a keystroke for the active tab.
    ///
    /// This is the whole point of the field: the host cannot tell which tab the user was typing into,
    /// because `switch-terminal` and these bytes ride different SCTP streams. A default here would put
    /// the old behaviour back while every other test still passed.
    func testKeyMessageMissingTermReturnsNil() {
        XCTAssertNil(parseInbound(data(#"{"t":"key","data":"ls\r"}"#)))
    }

    /// Tab ids are prefixed strings. A bare number — the retired form — or a prefix-less string is a
    /// different client's idea of the wire and must not be coerced into a target.
    func testKeyMessageUnprefixedTermReturnsNil() {
        XCTAssertNil(parseInbound(data(#"{"t":"key","data":"x","term":"3"}"#)))
    }

    /// The retired numeric form is MALFORMED, not coerced: nothing is distributed, so a peer still
    /// sending numbers is a version skew that must fail loudly.
    func testNumericTabIdsAreRetired() {
        XCTAssertNil(parseInbound(data(#"{"t":"key","data":"x","term":3}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"close-terminal","id":3}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"switch-terminal","id":2}"#)))
    }

    func testTmuxTabIdsParse() {
        XCTAssertEqual(parseInbound(data(#"{"t":"switch-terminal","id":"tmux:$4"}"#)), .switchTerminal(id: .tmux("$4")))
        XCTAssertEqual(parseInbound(data(#"{"t":"key","data":"x","term":"tmux:$4"}"#)), .key("x", term: .tmux("$4")))
    }

    // MARK: - touch

    func testTouchMessage() throws {
        let json = #"{"t":"touch","phase":"down","id":0,"x":0.5,"y":0.5,"ts":1}"#
        XCTAssertEqual(parseInbound(data(json)), .touch(x: 0.5, y: 0.5, phase: "down", button: .left, ts: 1))
    }

    func testTouchMessageIntegerCoords() throws {
        // x:0, y:1 are integer-valued in JSON; NSNumber bridge must produce Double
        let json = #"{"t":"touch","phase":"up","id":1,"x":0,"y":1,"ts":2}"#
        XCTAssertEqual(parseInbound(data(json)), .touch(x: 0.0, y: 1.0, phase: "up", button: .left, ts: 2))
    }

    func testTouchMessageMovePhase() {
        let json = #"{"t":"touch","phase":"move","id":0,"x":0.25,"y":0.75,"ts":5}"#
        XCTAssertEqual(parseInbound(data(json)), .touch(x: 0.25, y: 0.75, phase: "move", button: .left, ts: 5))
    }

    func testTouchMessageWithoutTsIsNil() {
        let json = #"{"t":"touch","phase":"down","x":0.5,"y":0.5}"#
        XCTAssertEqual(parseInbound(data(json)), .touch(x: 0.5, y: 0.5, phase: "down", button: .left, ts: nil))
    }

    // MARK: - retired legacy terminal messages

    func testLegacyTerminalMessagesAreGone() {
        XCTAssertNil(parseInbound(data(#"{"t":"snapshot-request"}"#)), "the cell-frame terminal is gone; a snapshot request is malformed")
        XCTAssertNil(parseInbound(data(#"{"t":"wheel","delta":3}"#)), "the cell-frame terminal's scrollback wheel is gone")
    }

    // MARK: - unknown / bad input

    func testUnknownTReturnsNil() {
        XCTAssertNil(parseInbound(data(#"{"t":"unknown"}"#)))
    }

    func testMissingTReturnsNil() {
        XCTAssertNil(parseInbound(data(#"{"type":"key","data":"x"}"#)))
    }

    func testBadJSONReturnsNil() {
        XCTAssertNil(parseInbound(data("not json")))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(parseInbound(Data()))
    }

    // MARK: - legacy wrong-field names return nil (regression guard)

    func testOldActionEnvelopeReturnsNil() {
        // Old client sent {"type":"control","action":"snapshot-request"} — must NOT parse
        XCTAssertNil(parseInbound(data(#"{"type":"control","action":"snapshot-request"}"#)))
    }

    func testOldKeyFieldReturnsNil() {
        // Old routing read obj["key"] instead of obj["data"]
        XCTAssertNil(parseInbound(data(#"{"t":"key","key":"ls\r","term":"pty:3"}"#)))
    }

    // MARK: - claim-control

    func testClaimControl() {
        XCTAssertEqual(parseInbound(data(#"{"t":"claim-control"}"#)), .claimControl(grid: nil))
        XCTAssertEqual(parseInbound(data(#"{"t":"claim-control","cols":45,"rows":30}"#)),
                       .claimControl(grid: TermGridSize(cols: 45, rows: 30)), "the claimer's grid")
        for bad in [#""cols":0,"rows":30"#, #""cols":45,"rows":501"#, #""cols":45.5,"rows":30"#, #""cols":45"#, #""cols":true,"rows":30"#] {
            XCTAssertEqual(parseInbound(data("{\"t\":\"claim-control\",\(bad)}")), .claimControl(grid: nil),
                           "a grid the driver could not report is no grid — the claim still stands: \(bad)")
        }
    }

    // MARK: - resize

    func testResize() {
        XCTAssertEqual(parseInbound(data(#"{"t":"resize","cols":120,"rows":40}"#)), .resize(cols: 120, rows: 40))
    }

    func testResizeMissingFieldsReturnsNil() {
        XCTAssertNil(parseInbound(data(#"{"t":"resize","cols":120}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"resize"}"#)))
    }

    // MARK: - term-mode / term-replay

    func testParsesTermModeRaw() {
        XCTAssertEqual(parseInbound(data(#"{"t":"term-mode","mode":"raw"}"#)), .termWire)
    }

    func testTermModeOtherThanRawIsGone() {
        XCTAssertNil(parseInbound(data(#"{"t":"term-mode","mode":"frames"}"#)), "the cell-frame terminal is gone; raw is the only mode")
    }

    func testTermModeRequiresModeField() {
        XCTAssertNil(parseInbound(data(#"{"t":"term-mode"}"#)))
    }

    func testTermReplayIsGone() {
        XCTAssertNil(parseInbound(data(#"{"t":"term-replay"}"#)), "restores are snapshots now; a replay request is malformed")
    }

    func testParsesTerminalPauseAndResume() {
        XCTAssertEqual(parseInbound(data(#"{"t":"terminal-pause"}"#)), .terminalPause)
        XCTAssertEqual(parseInbound(data(#"{"t":"terminal-resume"}"#)), .terminalResume)
    }

    /// The driver's xterm.js palette (`term-palette`): the host answers a tmux tab's colour queries from
    /// it when their bytes reach no client. Malformed — a missing colour, 15 ANSI — is nil.
    func testParsesTheTerminalPalette() {
        let ansi = (0..<16).map { "\"#0000\(String(format: "%02x", $0))\"" }.joined(separator: ",")
        func msg(_ fields: String) -> InboundMessage? { parseInbound(data("{\"t\":\"term-palette\",\(fields)}")) }
        let whole = msg("\"fg\":\"#ececec\",\"bg\":\"#000000\",\"cursor\":\"#ececec\",\"ansi\":[\(ansi)]")
        guard case .termPalette(let p)? = whole else { return XCTFail("\(String(describing: whole))") }
        XCTAssertEqual(p.foreground, .init(r: 0xec, g: 0xec, b: 0xec))
        XCTAssertEqual(p.color(15), .init(r: 0, g: 0, b: 15))
        XCTAssertNil(msg("\"fg\":\"#ececec\",\"bg\":\"#000000\",\"ansi\":[\(ansi)]"))
        XCTAssertNil(msg("\"fg\":\"#ececec\",\"bg\":\"#000000\",\"cursor\":\"#ececec\",\"ansi\":[\"#000000\"]"))
    }

    // MARK: - terminal tabs

    func testListTerminals() {
        XCTAssertEqual(parseInbound(data(#"{"t":"list-terminals"}"#)), .listTerminals)
    }

    func testOpenTerminal() {
        XCTAssertEqual(parseInbound(data(#"{"t":"open-terminal"}"#)), .openTerminal)
        XCTAssertEqual(parseInbound(data(#"{"t":"reopen-terminal"}"#)), .reopenTerminal)
    }

    func testCloseTerminal() {
        XCTAssertEqual(parseInbound(data(#"{"t":"close-terminal","id":"pty:3"}"#)), .closeTerminal(id: .pty(3)))
    }

    func testCloseTerminalMissingIdIsNil() {
        XCTAssertNil(parseInbound(data(#"{"t":"close-terminal"}"#)))
    }

    func testSwitchTerminal() {
        XCTAssertEqual(parseInbound(data(#"{"t":"switch-terminal","id":"pty:2"}"#)), .switchTerminal(id: .pty(2)))
    }

    func testSwitchTerminalMissingIdIsNil() {
        XCTAssertNil(parseInbound(data(#"{"t":"switch-terminal"}"#)))
    }

    // MARK: - source subscriptions

    func testListSources() {
        XCTAssertEqual(parseInbound(data(#"{"t":"list-sources"}"#)), .listSources)
    }

    func testParseRequestThumbs() {
        XCTAssertEqual(parseInbound(data(#"{"t":"request-thumbs"}"#)), .requestThumbs)

        // request-keyframe is SOURCE-SCOPED: rdev keyframes each window independently, and a
        // session-wide request would let a busy window starve a quiet one of its first IDR.
        XCTAssertEqual(parseInbound(data(#"{"t":"request-keyframe","source":"win:7"}"#)),
                       .requestKeyframe(source: "win:7"))
        // A request naming no source is REFUSED rather than defaulted to the focused one: the client
        // that needs an IDR knows which decoder stalled, and guessing would keyframe the wrong window
        // while the stalled one stayed broken.
        XCTAssertNil(parseInbound(data(#"{"t":"request-keyframe"}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"request-keyframe","source":""}"#)))
    }

    // The receiver's own counters, rendered by the client because only the client has them. Parsed
    // through the sanitiser, so a forged newline cannot reach the host's stdout.
    func testReceiverReportParsesAndIsSanitised() {
        XCTAssertEqual(
            parseInbound(data(#"{"t":"rx-stats","line":"ssrc=1 lost=0"}"#)),
            .receiverReport(line: "ssrc=1 lost=0"))
        XCTAssertEqual(
            parseInbound(data(#"{"t":"rx-stats","line":"a\nb"}"#)),
            .receiverReport(line: "ab"))
        // Nothing to print is not a message: a blank line must not produce an empty `[rx]` line.
        XCTAssertNil(parseInbound(data(#"{"t":"rx-stats","line":"   "}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"rx-stats"}"#)))
    }

    /// fps, scale and bitrate NO LONGER RIDE A SUBSCRIBE — they are the device's (`client-hello`). A stale
    /// sender's copies are IGNORED rather than refused: the window must still open.
    func testSubscribeIgnoresTheVideoFieldsItNoLongerCarries() {
        XCTAssertEqual(parseInbound(data(#"{"t":"subscribe","source":"sim:ABC","fps":60,"scale":0.5,"bitrateBps":2000000}"#)),
                       .subscribe(source: "sim:ABC", delivery: .rtp))
    }

    func testSubscribeMinimal() {
        XCTAssertEqual(parseInbound(data(#"{"t":"subscribe","source":"win:42"}"#)),
                       .subscribe(source: "win:42", delivery: .rtp))
    }

    func testSubscribeMissingSourceIsNil() {
        XCTAssertNil(parseInbound(data(#"{"t":"subscribe"}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"subscribe","source":""}"#)))
    }

    func testUnsubscribe() {
        XCTAssertEqual(parseInbound(data(#"{"t":"unsubscribe","source":"sim:ABC"}"#)), .unsubscribe(source: "sim:ABC"))
    }

    func testUnsubscribeMissingSourceIsNil() {
        XCTAssertNil(parseInbound(data(#"{"t":"unsubscribe"}"#)))
    }

    func testSetSourcePrefs() {
        XCTAssertEqual(parseInbound(data(#"{"t":"set-source-prefs","source":"sim:ABC","scale":0.75}"#)),
                       .setSourcePrefs(source: "sim:ABC", scale: 0.75, crop: nil))
    }

    func testFocusSource() {
        XCTAssertEqual(parseInbound(data(#"{"t":"focus-source","source":"sim:ABC"}"#)), .focusSource(source: "sim:ABC"))
    }

    func testFocusSourceMissingSourceIsNil() {
        XCTAssertNil(parseInbound(data(#"{"t":"focus-source"}"#)))
    }

    // MARK: - scroll

    func testScrollMessage() {
        let json = #"{"t":"scroll","x":0.5,"y":0.25,"dx":0,"dy":-3,"unit":"line"}"#
        XCTAssertEqual(parseInbound(data(json)),
                       .scroll(x: 0.5, y: 0.25, dx: 0.0, dy: -3.0, unit: .line, mods: .none))
    }
    func testScrollMessageMissingDeltasDefaultZero() {
        let json = #"{"t":"scroll","x":0.5,"y":0.5}"#
        XCTAssertEqual(parseInbound(data(json)),
                       .scroll(x: 0.5, y: 0.5, dx: 0.0, dy: 0.0, unit: .line, mods: .none))
    }

    func testScrollParsesPixelUnitAndModifiers() {
        let json = #"{"t":"scroll","x":0.5,"y":0.5,"dx":0,"dy":-14.5,"unit":"px","mods":12}"#
        XCTAssertEqual(parseInbound(data(json)),
                       .scroll(x: 0.5, y: 0.5, dx: 0.0, dy: -14.5, unit: .pixel,
                               mods: InputModifiers(raw: InputModifiers.commandBit | InputModifiers.optionBit)))
    }

    /// A client that predates `unit` must keep its old behaviour rather than acquire a new one.
    func testScrollWithoutAUnitIsTreatedAsLines() {
        let json = #"{"t":"scroll","x":0.5,"y":0.5,"dx":0,"dy":3}"#
        guard case .scroll(_, _, _, _, let unit, _) = parseInbound(data(json)) else {
            return XCTFail("expected a scroll message")
        }
        XCTAssertEqual(unit, .line)
    }

    // MARK: - scroll-fling

    func testScrollFlingParsesItsVelocityAndModifiers() {
        let json = #"{"t":"scroll-fling","x":0.5,"y":0.25,"vx":-40.5,"vy":1800,"mods":8}"#
        XCTAssertEqual(parseInbound(data(json)),
                       .scrollFling(x: 0.5, y: 0.25, vx: -40.5, vy: 1800,
                                    mods: InputModifiers(raw: InputModifiers.commandBit)))
    }

    /// A MISSING VELOCITY IS A STOP, not a refusal: zero is the "finger back on the glass" message,
    /// so a garbled fling halts a glide rather than leaving one running that nothing can reach.
    func testScrollFlingWithoutAVelocityIsAStop() {
        XCTAssertEqual(parseInbound(data(#"{"t":"scroll-fling","x":0.5,"y":0.5}"#)),
                       .scrollFling(x: 0.5, y: 0.5, vx: 0, vy: 0, mods: .none))
    }

    /// It is its OWN message, not a `scroll` with extra fields — a scroll carries a distance and a
    /// fling carries a rate, and overloading one field with both units is how a stale client's
    /// meaning silently changes.
    func testAScrollIsNotAFling() {
        guard case .scroll = parseInbound(data(#"{"t":"scroll","x":0,"y":0,"dx":0,"dy":9}"#)) else {
            return XCTFail("expected a scroll message")
        }
    }

    // MARK: - win-key

    func testWinKeyParsesAllFields() {
        let json = #"{"t":"win-key","down":true,"code":"KeyC","key":"c","repeat":false,"mods":8}"#
        XCTAssertEqual(parseInbound(data(json)),
                       .winKey(down: true, code: "KeyC", key: "c", repeat: false,
                               mods: InputModifiers(raw: InputModifiers.commandBit)))
    }

    func testWinKeyDefaultsRepeatAndModsButRequiresTheRest() {
        let json = #"{"t":"win-key","down":false,"code":"KeyA","key":"a"}"#
        XCTAssertEqual(parseInbound(data(json)),
                       .winKey(down: false, code: "KeyA", key: "a", repeat: false, mods: .none))
    }

    /// `down` is the whole meaning of the message. A missing flag must be REJECTED, not defaulted —
    /// defaulting it to false turns every keystroke into a keyUp for a key that was never pressed.
    func testWinKeyWithoutADownFlagIsRejected() {
        XCTAssertNil(parseInbound(data(#"{"t":"win-key","code":"KeyA","key":"a"}"#)))
    }

    func testWinKeyWithoutACodeIsRejected() {
        XCTAssertNil(parseInbound(data(#"{"t":"win-key","down":true,"key":"a"}"#)))
    }

    /// `key` may legitimately be absent for a key that produces no character.
    func testWinKeyWithoutAKeyDefaultsToTheEmptyString() {
        XCTAssertEqual(parseInbound(data(#"{"t":"win-key","down":true,"code":"F5"}"#)),
                       .winKey(down: true, code: "F5", key: "", repeat: false, mods: .none))
    }

    func testWinKeysReleaseParses() {
        XCTAssertEqual(parseInbound(data(#"{"t":"win-keys-release"}"#)), .winKeysRelease)
    }

    // MARK: - set-source-size

    func testParseSetSourceSize() {
        XCTAssertEqual(parseInbound(data(#"{"t":"set-source-size","source":"win:7","w":800,"h":600}"#)),
                       .setSourceSize(source: "win:7", w: 800, h: 600))
    }

    func testParseSetSourceSizeRejectsMissingOrNonPositiveDims() {
        XCTAssertNil(parseInbound(data(#"{"t":"set-source-size","source":"win:7","w":800}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"set-source-size","source":"win:7","w":0,"h":600}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"set-source-size","source":"","w":800,"h":600}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"set-source-size","w":800,"h":600}"#)))
    }

    // MARK: - hover

    func testParseHover() {
        XCTAssertEqual(parseInbound(data(#"{"t":"hover","x":0.25,"y":0.5}"#)), .hover(x: 0.25, y: 0.5))
    }

    func testParseHoverRejectsMissingOrNonNumericCoords() {
        XCTAssertNil(parseInbound(data(#"{"t":"hover","x":0.25}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"hover","x":"0.25","y":0.5}"#)))
    }
}

extension InboundTests {
    /// fps, bitrate and codec are the DEVICE's now (`set-prefs`; the codec's absent-not-auto rule moved
    /// with it, `ClientPrefsTests`). On a `set-source-prefs` they are ignored, and the per-window values
    /// it still carries parse as before.
    func testSetSourcePrefsIgnoresTheDevicesFields() {
        let json = #"{"t":"set-source-prefs","source":"win:1","fps":30,"bitrateBps":1000,"codec":"h265","scale":0.5}"#
        XCTAssertEqual(parseInbound(Data(json.utf8)), .setSourcePrefs(source: "win:1", scale: 0.5, crop: nil))
    }

    // MARK: - set-recovery (session-scoped, unlike every other pref here)

    func testParsesSetRecovery() {
        guard case .setRecovery(let bp)? = parseInbound(
            data(#"{"t":"set-recovery","overrideBp":2000}"#)) else {
            return XCTFail("set-recovery did not parse")
        }
        XCTAssertEqual(bp, 2000)
    }

    func testParsesSetRecoveryAuto() {
        guard case .setRecovery(let bp)? = parseInbound(
            data(#"{"t":"set-recovery","overrideBp":null}"#)) else {
            return XCTFail("set-recovery with a null override did not parse")
        }
        XCTAssertNil(bp, "null is Auto, not zero — zero is a forced no-FEC setting")
    }

    // A version skew or a typo must not silently disable a pin the operator set. Same rule as
    // CodecPref(wire:), which returns nil rather than resetting to .auto.
    func testSetRecoveryRejectsANonNumericOverride() {
        XCTAssertNil(parseInbound(data(#"{"t":"set-recovery","overrideBp":"lots"}"#)))
    }

    func testSetRecoveryRequiresTheKeyToBePresent() {
        XCTAssertNil(parseInbound(data(#"{"t":"set-recovery"}"#)),
                     "absent is malformed; present-and-null is Auto")
    }

    func testClampRecoveryOverride() {
        XCTAssertNil(clampRecoveryOverrideBp(nil))
        XCTAssertEqual(clampRecoveryOverrideBp(0), 0)
        XCTAssertEqual(clampRecoveryOverrideBp(2000), 2000)
        XCTAssertEqual(clampRecoveryOverrideBp(5000), 5000)
        XCTAssertEqual(clampRecoveryOverrideBp(7000), 5000, "above the maximum clamps, never refuses")
        XCTAssertEqual(clampRecoveryOverrideBp(-5), 0, "below zero clamps to a forced zero")
    }

    func testParsesSetVisibilityHidden() {
        let d = #"{"t":"set-visibility","hidden":true}"#.data(using: .utf8)!
        guard case .setVisibility(let hidden)? = parseInbound(d) else {
            return XCTFail("expected setVisibility")
        }
        XCTAssertTrue(hidden)
    }
    func testParsesSetVisibilityVisible() {
        let d = #"{"t":"set-visibility","hidden":false}"#.data(using: .utf8)!
        guard case .setVisibility(let hidden)? = parseInbound(d) else {
            return XCTFail("expected setVisibility")
        }
        XCTAssertFalse(hidden)
    }
    // A missing flag is NOT "visible": a message that cannot say which way it means must be rejected,
    // or a malformed client would silently un-pause every source.
    func testRejectsSetVisibilityWithoutFlag() {
        let d = #"{"t":"set-visibility"}"#.data(using: .utf8)!
        XCTAssertNil(parseInbound(d))
    }

    // MARK: - subscribe delivery

    // ABSENT MEANS RTP, which is what keeps every existing client working unchanged.
    func testSubscribeDefaultsToRTPWhenDeliveryIsAbsent() {
        let d = data(#"{"t":"subscribe","source":"win:1"}"#)
        guard case .subscribe(_, let delivery)? = parseInbound(d) else {
            return XCTFail("expected subscribe")
        }
        XCTAssertEqual(delivery, .rtp)
    }

    func testSubscribeAcceptsAnExplicitDeliveryRequest() {
        let d = data(#"{"t":"subscribe","source":"win:1","delivery":"dc"}"#)
        guard case .subscribe(_, let delivery)? = parseInbound(d) else {
            return XCTFail("expected subscribe")
        }
        XCTAssertEqual(delivery, .dc)
    }

    // A version skew must degrade to the default, never refuse the subscribe — the same rule
    // codec_pref follows across the ABI. Losing the source entirely is far worse than losing the
    // optimisation, and a client from the future must not be able to make a window unwatchable.
    func testSubscribeDegradesAnUnknownDeliveryToRTPRatherThanRefusing() {
        let d = data(#"{"t":"subscribe","source":"win:1","delivery":"quic"}"#)
        guard case .subscribe(_, let delivery)? = parseInbound(d) else {
            return XCTFail("expected subscribe")
        }
        XCTAssertEqual(delivery, .rtp)
    }

    // MARK: - the ABI's packed delivery result

    func testDecodeVideoDeliveryResultReadsIndexAndFlag() {
        XCTAssertEqual(decodeVideoDeliveryResult(0).delivery, .rtp)
        XCTAssertNil(decodeVideoDeliveryResult(0).dcIndex)
        // Index 0 delivered over the channel is (0 << 1) | 1 == 1 — the case an `encoded > 1` guard
        // would silently turn into RTP, binding nothing while reporting cleanly.
        XCTAssertEqual(decodeVideoDeliveryResult(1).delivery, .dc)
        XCTAssertEqual(decodeVideoDeliveryResult(1).dcIndex, 0)
        XCTAssertEqual(decodeVideoDeliveryResult(7).dcIndex, 3)
        XCTAssertEqual(decodeVideoDeliveryResult(9).dcIndex, 4)
    }

    func testDecodeVideoDeliveryResultTreatsFailureAndEvenValuesAsRTP() {
        // -1 is an unknown handle; an even value is the bridge saying "routed to RTP". Both must
        // report RTP rather than an index a caller would bind symbols to.
        XCTAssertEqual(decodeVideoDeliveryResult(-1).delivery, .rtp)
        XCTAssertNil(decodeVideoDeliveryResult(-1).dcIndex)
        XCTAssertEqual(decodeVideoDeliveryResult(8).delivery, .rtp)
        XCTAssertNil(decodeVideoDeliveryResult(8).dcIndex)
    }

    func testParsesCurtain() {
        XCTAssertEqual(parseInbound(#"{"t":"curtain","on":true}"#.data(using: .utf8)!), .curtain(on: true))
        XCTAssertEqual(parseInbound(#"{"t":"curtain","on":false}"#.data(using: .utf8)!), .curtain(on: false))
    }

    func testRejectsCurtainWithNoFlag() {
        // A MISSING flag is rejected rather than defaulted — the same rule set-visibility follows, and
        // for a sharper reason: defaulting would let a malformed message black someone's screen.
        XCTAssertNil(parseInbound(#"{"t":"curtain"}"#.data(using: .utf8)!))
        XCTAssertNil(parseInbound(#"{"t":"curtain","on":"yes"}"#.data(using: .utf8)!))
    }
}

// ── the viewer's crop ────────────────────────────────────────────────────────────────────────────
extension InboundTests {
    func testSetSourcePrefsParsesACrop() {
        let json = #"{"t":"set-source-prefs","source":"win:1","crop":{"x":0.25,"y":0.5,"w":0.25,"h":0.5}}"#
        guard case .setSourcePrefs(_, _, let crop)? = parseInbound(data(json)) else {
            return XCTFail("expected setSourcePrefs")
        }
        XCTAssertEqual(crop, CropRect(x: 0.25, y: 0.5, w: 0.25, h: 0.5))
    }

    /// A MALFORMED CROP YIELDS NIL — "no patch" — rather than a default rect. Silently resetting the
    /// crop to full on a typo is the same class of bug as a codec typo resetting the pin to auto,
    /// which the codec parse already guards against.
    func testAMalformedCropIsNoPatchRatherThanAReset() {
        for body in [#""crop":{"x":0.25,"y":0.5,"w":0.25}"#,      // missing h
                     #""crop":"all""#,                             // wrong type
                     #""crop":{}"#] {
            let json = #"{"t":"set-source-prefs","source":"win:1",\#(body)}"#
            guard case .setSourcePrefs(_, _, let crop)? = parseInbound(data(json)) else {
                return XCTFail("expected setSourcePrefs for \(body)")
            }
            XCTAssertNil(crop, "\(body) should be no patch")
        }
    }

    /// The existing shape still parses, with the crop absent.
    func testSetSourcePrefsWithoutACropStillParses() {
        guard case .setSourcePrefs(_, let scale, let crop)? =
            parseInbound(data(#"{"t":"set-source-prefs","source":"sim:ABC","scale":0.75}"#)) else {
            return XCTFail("expected setSourcePrefs")
        }
        XCTAssertEqual(scale, 0.75)
        XCTAssertNil(crop)
    }
}

final class InboundTmuxTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testTmuxMessages() {
        XCTAssertEqual(parseInbound(data(#"{"t":"list-tmux"}"#)), .listTmux)
        XCTAssertEqual(parseInbound(data(#"{"t":"new-tmux"}"#)), .newTmux)
        XCTAssertEqual(parseInbound(data(#"{"t":"open-tmux","session":"$3"}"#)), .openTmux(session: "$3"))
        XCTAssertEqual(parseInbound(data(#"{"t":"kill-tmux","session":"$3"}"#)), .killTmux(session: "$3"))
    }

    /// A session id is interpolated into tmux commands, so anything but `$<digits>` is refused here —
    /// `-t` with an attacker-chosen string would be a target injection.
    func testTmuxSessionIdsAreValidated() {
        for bad in [#""3""#, #""alpha""#, #""$3; kill-server""#, #""""#, "3"] {
            XCTAssertNil(parseInbound(data(#"{"t":"open-tmux","session":\#(bad)}"#)), bad)
            XCTAssertNil(parseInbound(data(#"{"t":"kill-tmux","session":\#(bad)}"#)), bad)
        }
        XCTAssertNil(parseInbound(data(#"{"t":"open-tmux"}"#)))
    }

    // MARK: - simulators

    func testSimTouch() {
        XCTAssertEqual(parseInbound(data(#"{"t":"sim-touch","phase":"down","points":[{"x":0.25,"y":0.5}]}"#)),
                       .simTouch(phase: "down", points: [SimPoint(x: 0.25, y: 0.5)]))
        XCTAssertEqual(parseInbound(data(#"{"t":"sim-touch","phase":"move","points":[{"x":0.1,"y":0.2},{"x":0.9,"y":0.8}]}"#)),
                       .simTouch(phase: "move", points: [SimPoint(x: 0.1, y: 0.2), SimPoint(x: 0.9, y: 0.8)]))
        XCTAssertEqual(parseInbound(data(#"{"t":"sim-touch","phase":"up","points":[{"x":1.5,"y":-0.5}]}"#)),
                       .simTouch(phase: "up", points: [SimPoint(x: 1, y: 0)]), "clamped onto the picture")
    }

    func testSimTouchMalformed() {
        XCTAssertNil(parseInbound(data(#"{"t":"sim-touch","phase":"hover","points":[{"x":0,"y":0}]}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"sim-touch","phase":"down","points":[]}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"sim-touch","phase":"down","points":[{"x":0,"y":0},{"x":0,"y":0},{"x":0,"y":0}]}"#)),
                     "DTUHID carries two contacts")
        XCTAssertNil(parseInbound(data(#"{"t":"sim-touch","phase":"down","points":[{"x":0}]}"#)))
    }

    func testSimText() {
        XCTAssertEqual(parseInbound(data(#"{"t":"sim-text","text":"héllo"}"#)), .simText("héllo"))
        XCTAssertNil(parseInbound(data(#"{"t":"sim-text","text":""}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"sim-text"}"#)))
    }

    func testSimulatorKeyboardActionIsAccepted() {
        let message = parseInbound(data(#"{"t":"sim-action","source":"sim:9B45C574-451C-475D-8498-66BD68AEE17D","action":"keyboard"}"#))
        XCTAssertNotNil(message)
    }

    func testSimAction() {
        let src = "sim:9B45C574-451C-475D-8498-66BD68AEE17D"
        for raw in ["home", "app-switcher", "lock", "siri", "volume-up", "volume-down", "shake",
                    "rotate-left", "rotate-right", "boot", "shutdown"] {
            XCTAssertEqual(parseInbound(data(#"{"t":"sim-action","source":"\#(src)","action":"\#(raw)"}"#)),
                           .simAction(source: src, action: SimAction(rawValue: raw)!), raw)
        }
        XCTAssertNil(parseInbound(data(#"{"t":"sim-action","source":"\#(src)","action":"explode"}"#)))
        XCTAssertNil(parseInbound(data(#"{"t":"sim-action","source":"win:12","action":"home"}"#)), "a window has no home button")
    }
}
