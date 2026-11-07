import Foundation
import RdevCore

/// **Opening a pairing window: generate, derive, register.** §9.1's inversion, host-side.
///
/// The Issuer generates one 16-byte seed and derives `code`, `token` and `psk` from it. Only the two
/// public values are registered with the Control Plane; the seed is rendered on the local pairing
/// surface — that display IS the out-of-band channel — and **`psk` is never transmitted, never
/// logged, and never permitted into captured output.**
///
/// The mirror of `openPairingWindow` in `protocol/src/pairing-seed.ts`, deliberately the same shape:
/// three front ends open pairing windows (this one, the native app, the browser dev harness) and
/// three answers to "what does the Worker learn" is three chances to get it wrong.
///
/// In `RdevHostKit` rather than `RdevCore` because it makes a network request, and RdevCore is pure
/// portable logic whose suite must keep running in a third of a second.
public enum PairingWindowOpener {

    /// §9.2's retry budget: "A temporary pairing-route conflict can be retried with fresh material,
    /// at most four times." Bounded, because a Control Plane answering `conflict` forever would
    /// otherwise hold an Issuer in a loop — which is the denial of service the cap exists to stop.
    public static let conflictAttempts = 4

    public struct Opened: Sendable {
        public let seed: [UInt8]
        /// `b64u(seed)`, the 22 characters a person carries — bare, since 2026-09-15.
        public let carrier: String
        public let material: PairingMaterial
        public let sessionURL: String
    }

    public enum Failure: String, Error, Equatable, Sendable {
        /// Four fresh windows, four seizures. §9.2 calls this denial of service, and it is.
        case conflict
        /// The Control Plane could not be reached at all.
        case unreachable
        /// It answered, and said no. Not retried: the answer will not change with fresh material.
        case refused
        /// The derivation itself failed — a programming error at the call site, not a runtime state.
        case malformed
    }

    /// `random` and `transport` are injected so the whole path is testable without a network, and so
    /// a test can pin the seed — a test that cannot pin it cannot assert the code it produces.
    public static func open(
        signalingBase: String,
        restoringCarrier: String? = nil,
        random: (Int) -> [UInt8] = DeviceIdentity.systemRandom,
        transport: ((URL, Data) async -> (status: Int, body: Data)?)? = nil
    ) async -> Result<Opened, Failure> {
        // **AN ABSOLUTE http(s) URL, checked rather than assumed.** `URL(string:)` alone is not a
        // validation on Apple's Foundation: it percent-encodes spaces and happily returns a RELATIVE
        // url for `"" + "/pair"`, so a bare non-nil check passes for every string a caller could get
        // wrong. Measured while writing the test for it.
        guard let url = URL(string: "\(signalingBase)/pair"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return .failure(.malformed) }
        // A default argument cannot name a non-public member, and making the live transport public
        // would put a bare HTTP POST on this type's surface. Nil means "the real one".
        let send = transport ?? Self.post

        for _ in 0 ..< conflictAttempts {
            let seed: [UInt8]
            if let restoringCarrier {
                guard let restored = PairingSeed.decode(restoringCarrier) else { return .failure(.malformed) }
                seed = restored
            } else { seed = random(PairingSeed.seedByteCount) }
            guard let material = PairingSeed.derive(seed: seed),
                  let carrier = PairingSeed.encode(seed: seed) else { return .failure(.malformed) }

            // **ONLY THE TWO PUBLIC VALUES.** Adding the seed here — or printing this body — would
            // hand the Control Plane everything it needs to derive `psk` and complete the handshake.
            let body = try? JSONSerialization.data(
                withJSONObject: ["code": material.code, "token": material.token])
            guard let body else { return .failure(.malformed) }

            guard let answer = await send(url, body) else { return .failure(.unreachable) }
            if answer.status == 409 { if restoringCarrier != nil { return .failure(.conflict) }; continue }
            guard answer.status == 200 else { return .failure(.refused) }

            let parsed = try? JSONSerialization.jsonObject(with: answer.body) as? [String: Any]
            let sessionURL = (parsed?["sessionUrl"] as? String)
                ?? "\(signalingBase)/session/\(material.code)"
            return .success(Opened(seed: seed, carrier: carrier, material: material,
                                   sessionURL: sessionURL))
        }
        return .failure(.conflict)
    }

    private static func post(_ url: URL, _ body: Data) async -> (status: Int, body: Data)? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }
}
