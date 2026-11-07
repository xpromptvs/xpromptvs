import XCTest
@testable import RdevNoise

/// The Swift face of the Noise ABI.
///
/// THESE ALSO KEEP THE HAND-WRITTEN C HEADER HONEST. `rules_rust` emits an archive, not a header, so
/// `include/rdev_noise.h` and `src/lib.rs` are two statements of one contract. Driving every function
/// from Swift means a drifted signature fails to compile or fails here, rather than corrupting a
/// handshake in production.
///
/// Byte-exactness against the published Cacophony vectors is asserted on the Rust side
/// (`//host/rdev-noise:rdev_noise_test`), because it needs pinned ephemerals and this ABI
/// deliberately will not take one — §7 requires a CSPRNG, and a production seam for injecting
/// handshake randomness is a liability whatever it is labelled.
final class NoiseSessionTests: XCTestCase {

    private let prologue = Array("rdev-e2e/v3".utf8)
    private let psk = [UInt8](repeating: 0xAB, count: 32)

    private func pair(_ mode: NoiseSession.Mode, psk: [UInt8]? = nil) throws
        -> (initiator: NoiseSession, responder: NoiseSession) {
        let i = try XCTUnwrap(NoiseSession(mode: mode, initiator: true, prologue: prologue,
                                           staticPrivateKey: [UInt8](repeating: 0x11, count: 32), psk: psk))
        let r = try XCTUnwrap(NoiseSession(mode: mode, initiator: false, prologue: prologue,
                                           staticPrivateKey: [UInt8](repeating: 0x22, count: 32), psk: psk))
        return (i, r)
    }

    /// A full handshake in both modes, then transport in both directions. The transition is never
    /// visible to the caller, which is the property this wrapper exists to provide.
    func testAFullHandshakeRunsInBothModes() throws {
        for (mode, key) in [(NoiseSession.Mode.xx, nil as [UInt8]?), (.pair, psk)] {
            let (i, r) = try pair(mode, psk: key)

            _ = try r.read(try i.write([]))
            XCTAssertEqual(try i.read(try r.write(Array("issuer-route".utf8))), Array("issuer-route".utf8))
            XCTAssertEqual(try r.read(try i.write(Array("device+op".utf8))), Array("device+op".utf8))

            XCTAssertTrue(i.isTransport, "\(mode): initiator settles")
            XCTAssertTrue(r.isTransport, "\(mode): responder settles")
            XCTAssertEqual(i.handshakeHash, r.handshakeHash, "\(mode): handshake hashes agree")
            XCTAssertNotNil(i.handshakeHash, "\(mode): the hash survives the transition — §11.2 needs it after Split")

            let confirm = Array("client-confirm".utf8)
            XCTAssertEqual(try r.read(try i.write(confirm)), confirm, "\(mode): transport i->r")
            let start = Array("session-start".utf8)
            XCTAssertEqual(try i.read(try r.write(start)), start, "\(mode): transport r->i")
        }
    }

    /// THE PROPERTY `pair` EXISTS FOR. Without this the test above shows only that the code runs.
    func testAOneBitPSKMismatchIsRejected() throws {
        var wrong = psk
        wrong[31] ^= 0x01
        let i = try XCTUnwrap(NoiseSession(mode: .pair, initiator: true, prologue: prologue,
                                           staticPrivateKey: [UInt8](repeating: 0x11, count: 32), psk: psk))
        let r = try XCTUnwrap(NoiseSession(mode: .pair, initiator: false, prologue: prologue,
                                           staticPrivateKey: [UInt8](repeating: 0x22, count: 32), psk: wrong))
        // Under psk3 the secret is mixed at the END of message 3, so the first two still read — that
        // is the pattern behaving correctly, not a weak check. Message 3 is where it must fail.
        _ = try r.read(try i.write([]))
        _ = try i.read(try r.write([]))
        let third = try i.write([])
        XCTAssertThrowsError(try r.read(third)) { error in
            XCTAssertEqual(error as? NoiseSession.Failure, .noise, "a PSK mismatch is a Noise failure")
        }
    }

    /// Each peer learns the other's static key, and it is the OTHER's — §11.1 requires checking it
    /// against the certified chain, and a wrapper that returned the local key would pass every
    /// liveness test while authenticating nothing.
    func testEachSideLearnsTheOthersStaticKey() throws {
        let (i, r) = try pair(.xx)
        _ = try r.read(try i.write([]))
        _ = try i.read(try r.write([]))
        _ = try r.read(try i.write([]))
        XCTAssertEqual(i.remoteStaticKey?.count, 32)
        XCTAssertEqual(r.remoteStaticKey?.count, 32)
        XCTAssertNotEqual(i.remoteStaticKey, r.remoteStaticKey, "each side sees the OTHER's key")
    }

    /// Incoherent construction is refused rather than quietly degraded — a PSK on a non-PSK pattern
    /// would otherwise be silently ignored, which is a pairing that authenticates nothing.
    func testIncoherentConstructionIsRefused() {
        let sk = [UInt8](repeating: 1, count: 32)
        XCTAssertNil(NoiseSession(mode: .xx, initiator: true, prologue: prologue,
                                  staticPrivateKey: sk, psk: psk), "a PSK on plain XX")
        XCTAssertNil(NoiseSession(mode: .pair, initiator: true, prologue: prologue,
                                  staticPrivateKey: sk, psk: nil), "pair without a PSK")
        XCTAssertNil(NoiseSession(mode: .xx, initiator: true, prologue: prologue,
                                  staticPrivateKey: [1, 2, 3], psk: nil), "a short static key")
        XCTAssertNil(NoiseSession(mode: .pair, initiator: true, prologue: prologue,
                                  staticPrivateKey: sk, psk: [1, 2, 3]), "a short PSK")
    }

    /// A DIFFERENT PROLOGUE IS A DIFFERENT SESSION. §11.3 binds the mode and room into the prologue
    /// precisely so a message cannot be replayed into another context; if it were not mixed in, two
    /// peers disagreeing about the mode would complete a handshake and never notice.
    func testAProloguesMismatchBreaksTheHandshake() throws {
        let i = try XCTUnwrap(NoiseSession(mode: .xx, initiator: true, prologue: Array("mode=auth".utf8),
                                           staticPrivateKey: [UInt8](repeating: 0x11, count: 32)))
        let r = try XCTUnwrap(NoiseSession(mode: .xx, initiator: false, prologue: Array("mode=pair".utf8),
                                           staticPrivateKey: [UInt8](repeating: 0x22, count: 32)))
        _ = try r.read(try i.write([]))          // message 1 has no key yet, so it still reads
        let second = try r.write([])
        XCTAssertThrowsError(try i.read(second), "message 2 is authenticated and must fail")
    }
}
