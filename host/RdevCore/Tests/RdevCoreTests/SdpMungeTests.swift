// host/RdevCore/Tests/RdevCoreTests/SdpMungeTests.swift
import XCTest
@testable import RdevCore

final class SdpMungeTests: XCTestCase {
    // A minimal offer m=video block with FEC + color-space + an H264 fmtp.
    private let sdp = [
        "v=0",
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99",
        "a=extmap:3 urn:ietf:params:rtp-hdrext:toffset",
        "a=extmap:5 http://www.webrtc.org/experiments/rtp-hdrext/color-space",
        "a=rtpmap:96 H264/90000",
        "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f",
        "a=rtpmap:97 rtx/90000",
        "a=fmtp:97 apt=96",
        "a=rtpmap:98 red/90000",
        "a=rtpmap:99 ulpfec/90000",
        "",
    ].joined(separator: "\r\n")

    func testAddPlayoutDelayInsertsExtmapOnce() {
        let out = SdpMunge.addPlayoutDelay(sdp)
        XCTAssertTrue(out.contains("http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"))
        // idempotent
        XCTAssertEqual(
            SdpMunge.addPlayoutDelay(out)
                .components(separatedBy: "playout-delay").count, 2)
    }

    func testStripFecRemovesRedAndUlpfecPTsAndLines() {
        let out = SdpMunge.stripFec(sdp)
        XCTAssertFalse(out.contains("red/90000"))
        XCTAssertFalse(out.contains("ulpfec/90000"))
        let mLine = out.split(separator: "\r\n").first { $0.hasPrefix("m=video ") }!
        XCTAssertFalse(mLine.contains(" 98"))
        XCTAssertFalse(mLine.contains(" 99"))
        XCTAssertTrue(mLine.contains(" 96"))   // H264 kept
        XCTAssertTrue(mLine.contains(" 97"))   // RTX kept
    }

    func testStripColorSpaceRemovesItsExtmap() {
        let out = SdpMunge.stripColorSpace(sdp)
        XCTAssertFalse(out.contains("color-space"))
        XCTAssertTrue(out.contains("toffset"))  // other extmaps untouched
    }

    func testPinH264BaselineRewritesProfileLevelId() {
        let out = SdpMunge.pinH264Baseline(sdp)
        XCTAssertTrue(out.contains("profile-level-id=42e01f"))
        XCTAssertFalse(out.contains("profile-level-id=640c1f"))
        XCTAssertTrue(out.contains("packetization-mode=1"))
        XCTAssertTrue(out.contains("level-asymmetry-allowed=1"))
    }
}
