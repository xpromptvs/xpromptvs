import Foundation

/// The §11 wire encodings of the E2E protocol specification — the prologue that binds a Noise
/// handshake to its mode and room, and the two authenticated transport messages that gate access.
///
/// PURE, so the whole layer is testable without a network, a peer or a handshake, and so both
/// implementations can be held to `protocol/fixtures/e2e-wire.json` — vectors a THIRD implementation
/// produced. Byte layouts are exactly where two implementations drift while both look correct.
///
/// **PARSING IS AS MUCH THE POINT AS ENCODING.** §7 requires rejecting wrong widths, unsupported
/// values and extra trailing bytes BEFORE verification, because a parser that is lenient about
/// framing hands an attacker the ability to make one byte string mean two things to two peers.
public enum E2EWire {

    /// §11.1's modes. The pattern differs (`pair` is XXpsk3, the rest XX) but the mode is ALSO
    /// carried in the prologue, so two peers that disagree about it cannot complete a handshake —
    /// which is what stops a `pair` transcript being replayed as an `auth`.
    public enum Mode: String, Sendable, CaseIterable {
        case pair, enroll, auth, resume
    }

    /// §12.2. Carried in `session-start` so the newcomer learns it from the endpoint that KNOWS,
    /// rather than inferring it from a directory listing that cannot answer the question.
    public enum PublicationStatus: UInt8, Sendable, CaseIterable {
        case confirmed = 0, unconfirmed = 1, rejected = 2
    }

    /// Field widths from §7. Hashes, operation IDs and raw public keys are 32 bytes; Ed25519
    /// signatures are 64.
    public static let idLength = 32
    public static let signatureLength = 64

    static let prologueLabel = "rdev-e2e/v3"
    static let proofLabel = "rdev-e2e/device-proof/v1"
    static let confirmLabel = "rdev-e2e/confirm/v3"
    static let sessionStartLabel = "rdev-e2e/session-start/v3"

    /// `LP(x) = uint16be(len(x)) || x`. Nil above 65,535 bytes rather than truncating — a silent
    /// truncation here would produce a well-formed message carrying the wrong content.
    public static func lengthPrefixed(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count <= 0xFFFF else { return nil }
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
    }

    static func lp(_ s: String) -> [UInt8] {
        // A label is ours and short; its length is a compile-time fact, not a runtime risk.
        lengthPrefixed(Array(s.utf8))!
    }

    // MARK: - §11.1 prologue

    /// `prologue = LP("rdev-e2e/v3") || LP(mode) || LP(room_code)`
    ///
    /// Noise mixes the prologue into the handshake hash before anything else, so a peer that
    /// disagrees about the mode or the room fails at the first authenticated message rather than
    /// completing a handshake in the wrong context.
    public static func prologue(mode: Mode, roomCode: String) -> [UInt8]? {
        guard let room = lengthPrefixed(Array(roomCode.utf8)) else { return nil }
        return lp(prologueLabel) + lp(mode.rawValue) + room
    }

    // MARK: - §11.1 handshake payloads

    /// §11.1: "Message 1 has an empty payload." Stated as a function because the check is the
    /// point — a payload here is carried before ANY authentication, so anything in it is bytes an
    /// unauthenticated stranger chose, arriving before the handshake can say who they are.
    public static func message1PayloadIsAcceptable(_ payload: [UInt8]) -> Bool { payload.isEmpty }

    /// Noise message 2's payload: `LP(responder_bundle) || LP(rcode) || LP(rtoken)`.
    ///
    /// **NO LABEL, and that is deliberate rather than an omission.** Its position in the handshake
    /// fixes its meaning: it can only ever be read as message 2 of a transcript whose prologue
    /// already bound the mode and the room, and Noise's hash covers everything before it. A label
    /// would add a second, weaker statement of something the transcript already settles.
    ///
    /// §9.2: the Issuer sends its DURABLE address here, "before the newcomer can request an
    /// enrollment that might commit" — so a lost acknowledgement can be resumed rather than
    /// stranding a half-finished enrollment.
    public static func responderHello(bundle: [UInt8], rcode: String, rtoken: String) -> [UInt8]? {
        guard let b = lengthPrefixed(bundle),
              let c = lengthPrefixed(Array(rcode.utf8)),
              let t = lengthPrefixed(Array(rtoken.utf8)) else { return nil }
        return b + c + t
    }

    public struct ResponderHello: Equatable, Sendable {
        public let bundle: [UInt8]
        public let rcode: String
        public let rtoken: String
    }

    public static func parseResponderHello(_ bytes: [UInt8]) -> ResponderHello? {
        var r = Reader(bytes)
        guard let bundle = r.lengthPrefixed(),
              let code = r.lengthPrefixed(), let rcode = String(bytes: code, encoding: .utf8),
              let token = r.lengthPrefixed(), let rtoken = String(bytes: token, encoding: .utf8),
              r.atEnd
        else { return nil }
        return ResponderHello(bundle: bundle, rcode: rcode, rtoken: rtoken)
    }

    /// Noise message 3's payload: `LP(initiator_device) || operation_id || LP(initiator_bundle)`.
    ///
    /// §11.1: "The descriptor's DH key must match the initiator's Noise static." That check is the
    /// responder's and cannot be made here — this layer only guarantees the descriptor ARRIVES, as
    /// its own bytes, so the responder compares a parsed key against the key Noise authenticated
    /// rather than against a key the same message asserted twice.
    public static func initiatorHello(device: [UInt8], operationID: [UInt8],
                                      bundle: [UInt8]) -> [UInt8]? {
        guard operationID.count == idLength,
              let d = lengthPrefixed(device), let b = lengthPrefixed(bundle) else { return nil }
        return d + operationID + b
    }

    public struct InitiatorHello: Equatable, Sendable {
        public let device: [UInt8]
        public let operationID: [UInt8]
        public let bundle: [UInt8]

        /// §11.1: "An ordinary `auth` uses an all-zero operation ID." Named rather than open-coded,
        /// because `operation_id == 0` is a MEANING here and not a missing value.
        public var isOrdinaryAuth: Bool { operationID.allSatisfy { $0 == 0 } }
    }

    public static func parseInitiatorHello(_ bytes: [UInt8]) -> InitiatorHello? {
        var r = Reader(bytes)
        guard let device = r.lengthPrefixed(),
              let operationID = r.take(idLength),
              let bundle = r.lengthPrefixed(),
              r.atEnd
        else { return nil }
        return InitiatorHello(device: device, operationID: operationID, bundle: bundle)
    }

    // MARK: - §11.2 device proof and confirmation

    /// `proof_body = LP("rdev-e2e/device-proof/v1") || LP(mode) || h || device_id
    ///             || responder_device_id || operation_id`
    ///
    /// Binds the request to BOTH peers, the mode, and the complete DH transcript (`h`). Without the
    /// responder's id a proof is replayable at a different Host; without `h` it is replayable in a
    /// different session.
    public static func deviceProofBody(mode: Mode, handshakeHash h: [UInt8], deviceID: [UInt8],
                                       responderDeviceID: [UInt8], operationID: [UInt8]) -> [UInt8]? {
        guard h.count == idLength, deviceID.count == idLength,
              responderDeviceID.count == idLength, operationID.count == idLength else { return nil }
        return lp(proofLabel) + lp(mode.rawValue) + h + deviceID + responderDeviceID + operationID
    }

    public struct ClientConfirm: Equatable, Sendable {
        public let proofBody: [UInt8]
        public let proof: [UInt8]
        public let newBundle: [UInt8]
        /// The APPLICATION's first words (`appHelloMax` bytes at most), opaque here — the client's terminal grid
        /// (`JoinHello`; docs/sources-and-focus.md, "The offer carries the tab bar"). Read only once the gate opens.
        public let appHello: [UInt8]
    }

    /// §11.2: "only BOUNDED authentication … messages may be processed" before the gate — so the one
    /// application field the gate's own message carries is capped, and a longer one is a rejection.
    public static let appHelloMax = 1024

    /// `client-confirm = LP("rdev-e2e/confirm/v3") || LP(proof_body) || proof || LP(new_bundle) || LP(app_hello)`
    public static func clientConfirm(proofBody: [UInt8], proof: [UInt8],
                                     newBundle: [UInt8], appHello: [UInt8] = []) -> [UInt8]? {
        guard proof.count == signatureLength, appHello.count <= appHelloMax,
              let body = lengthPrefixed(proofBody), let bundle = lengthPrefixed(newBundle),
              let hello = lengthPrefixed(appHello)
        else { return nil }
        return lp(confirmLabel) + body + proof + bundle + hello
    }

    public static func parseClientConfirm(_ bytes: [UInt8]) -> ClientConfirm? {
        var r = Reader(bytes)
        guard r.expectLabel(confirmLabel),
              let body = r.lengthPrefixed(),
              let proof = r.take(signatureLength),
              let bundle = r.lengthPrefixed(),
              let hello = r.lengthPrefixed(), hello.count <= appHelloMax,
              r.atEnd                                   // §7: extra trailing bytes are a rejection
        else { return nil }
        return ClientConfirm(proofBody: body, proof: proof, newBundle: bundle, appHello: hello)
    }

    public struct SessionStart: Equatable, Sendable {
        public let handshakeHash: [UInt8]
        public let operationID: [UInt8]
        public let publicationStatus: PublicationStatus
        public let acceptedBundle: [UInt8]
    }

    /// `session-start = LP("rdev-e2e/session-start/v3") || h || operation_id
    ///                || U8(publication_status) || LP(accepted_bundle)`
    public static func sessionStart(handshakeHash h: [UInt8], operationID: [UInt8],
                                    status: PublicationStatus,
                                    acceptedBundle: [UInt8]) -> [UInt8]? {
        guard h.count == idLength, operationID.count == idLength,
              let bundle = lengthPrefixed(acceptedBundle) else { return nil }
        return lp(sessionStartLabel) + h + operationID + [status.rawValue] + bundle
    }

    public static func parseSessionStart(_ bytes: [UInt8]) -> SessionStart? {
        var r = Reader(bytes)
        guard r.expectLabel(sessionStartLabel),
              let h = r.take(idLength),
              let operation = r.take(idLength),
              let raw = r.takeByte(),
              // §7: an unsupported enum value is REJECTED, never partially interpreted. A future
              // status this build does not know is not "probably fine".
              let status = PublicationStatus(rawValue: raw),
              let bundle = r.lengthPrefixed(),
              r.atEnd
        else { return nil }
        return SessionStart(handshakeHash: h, operationID: operation,
                            publicationStatus: status, acceptedBundle: bundle)
    }

    /// A cursor that refuses to read past the end. Every accessor returns nil rather than trapping,
    /// because this parses bytes an adversary chose.
    public struct Reader {
        private let b: [UInt8]
        private var i = 0
        public init(_ bytes: [UInt8]) { b = bytes }

        public var atEnd: Bool { i == b.count }

        public mutating func take(_ n: Int) -> [UInt8]? {
            guard n >= 0, b.count - i >= n else { return nil }
            defer { i += n }
            return Array(b[i ..< i + n])
        }

        public mutating func takeByte() -> UInt8? { take(1)?.first }

        public mutating func lengthPrefixed() -> [UInt8]? {
            guard let hdr = take(2) else { return nil }
            return take(Int(hdr[0]) << 8 | Int(hdr[1]))
        }

        /// A label must match EXACTLY, including its length prefix — it is the message's type tag,
        /// and accepting a prefix of it would let one encoding be read as another.
        public mutating func expectLabel(_ label: String) -> Bool {
            lengthPrefixed() == Array(label.utf8)
        }
    }
}
