import CRdevNoise
import Foundation

/// One Noise session — the encrypted signalling channel of
/// `docs/superpowers/specs/2026-09-10-e2e-protocol-specification.md` §11.
///
/// A CLASS, so `deinit` owns the Rust allocation. The C ABI hands back a pointer that must be freed
/// exactly once; making that a value type would either copy the pointer or need a manual `close()`
/// that some path forgets on an error return.
///
/// NOT THREAD-SAFE, and it must not be made so by adding a lock here. Noise is inherently ordered:
/// every message advances a nonce counter, so two concurrent writes are a protocol error rather than
/// a data race to be papered over. The caller serializes, the same way `ChannelHub` already does.
public final class NoiseSession {

    /// The modes §11.1 names. Not a protocol string: a caller cannot ask for something the
    /// specification does not define, so that table stays the single source of truth.
    public enum Mode {
        /// `enroll`, `auth`, `resume` — `Noise_XX_25519_ChaChaPoly_SHA256`.
        case xx
        /// `pair` — `Noise_XXpsk3_25519_ChaChaPoly_SHA256`, authenticated by the pairing seed's
        /// derived `psk` (`PairingSeed`, §9.1).
        case pair

        var raw: Int32 { self == .xx ? Int32(RDEV_NOISE_XX) : Int32(RDEV_NOISE_PAIR) }
    }

    public enum Failure: Error, Equatable {
        case arguments
        case bufferTooSmall
        /// Decryption or handshake failure. **§11.3: this terminates the signalling session.** Never
        /// retry the message; a peer that can make this happen at will is the adversary, and a retry
        /// loop is what turns one forged frame into an oracle.
        case noise
    }

    /// §7: a Noise message is at most 65,535 bytes. Sizing every buffer to the maximum costs one
    /// allocation per message and removes the class of bug where a caller guesses the framing
    /// overhead — which is exactly what the first version of this boundary asked of them.
    private static let maxMessage = 65_535

    private let session: OpaquePointer

    /// Returns nil when the arguments are incoherent: a PSK on `xx`, `pair` without one, or a key of
    /// the wrong width. Those are programming errors at the call site, not runtime conditions.
    public init?(mode: Mode, initiator: Bool, prologue: [UInt8],
                 staticPrivateKey: [UInt8], psk: [UInt8]? = nil) {
        guard staticPrivateKey.count == 32 else { return nil }
        if let psk, psk.count != 32 { return nil }
        let created: OpaquePointer? = prologue.withUnsafeBufferPointer { pro in
            staticPrivateKey.withUnsafeBufferPointer { sk in
                func build(_ pskPtr: UnsafePointer<UInt8>?) -> OpaquePointer? {
                    rdev_noise_new(mode.raw, initiator, pro.baseAddress, pro.count, sk.baseAddress, pskPtr)
                }
                if let psk { return psk.withUnsafeBufferPointer { build($0.baseAddress) } }
                return build(nil)
            }
        }
        guard let created else { return nil }
        session = created
    }

    deinit { rdev_noise_free(session) }

    /// True once the handshake has completed. The handshake-to-transport transition happens inside
    /// the ABI, so nothing here has to model it.
    public var isTransport: Bool { rdev_noise_is_transport(session) }

    /// The handshake hash `h`. §11.2 binds `client-confirm` and the device proof to it, so it is
    /// protocol input; it remains available after the transition.
    public var handshakeHash: [UInt8]? { fetch32(rdev_noise_handshake_hash) }

    /// The peer's static public key. §11.1 requires this be checked against the certified chain
    /// before anything is activated — completing Noise authenticates a KEY, never an identity.
    public var remoteStaticKey: [UInt8]? { fetch32(rdev_noise_remote_static) }

    public func write(_ payload: [UInt8]) throws -> [UInt8] {
        try transfer(payload) { p, n, out, cap, len in
            rdev_noise_write(session, p, n, out, cap, len)
        }
    }

    public func read(_ message: [UInt8]) throws -> [UInt8] {
        try transfer(message) { p, n, out, cap, len in
            rdev_noise_read(session, p, n, out, cap, len)
        }
    }

    private func fetch32(_ call: (OpaquePointer?, UnsafeMutablePointer<UInt8>?) -> Int32) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 32)
        let rc = out.withUnsafeMutableBufferPointer { call(session, $0.baseAddress) }
        return rc == RDEV_NOISE_OK ? out : nil
    }

    private func transfer(_ input: [UInt8],
                          _ call: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?,
                                   Int, UnsafeMutablePointer<Int>?) -> Int32) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.maxMessage)
        var produced = 0
        let rc = input.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                call(inp.baseAddress, inp.count, o.baseAddress, o.count, &produced)
            }
        }
        switch rc {
        case RDEV_NOISE_OK: return Array(out[0 ..< produced])
        case RDEV_NOISE_ERR_BUFFER: throw Failure.bufferTooSmall
        case RDEV_NOISE_ERR_ARGS: throw Failure.arguments
        default: throw Failure.noise
        }
    }
}
