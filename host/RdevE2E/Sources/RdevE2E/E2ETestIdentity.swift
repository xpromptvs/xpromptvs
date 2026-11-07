import Foundation
import RdevCore

/// **A PREPARED IDENTITY, FOR TESTS ONLY** — `RDEV_E2E_TEST_IDENTITY=<path>` with
/// `RDEV_E2E_TEST_ROLE=host|client`.
///
/// Once signalling is E2E-only every gate needs both ends enrolled, and driving a real §12.1
/// ceremony per gate would put a browser, a virtual authenticator and a Worker in front of checks
/// that are about codecs, audio or input. This installs an identity instead, from a file
/// `scripts/gen_e2e_test_identities.py` mints.
///
/// **IT REMOVES NO SECURITY PROPERTY FROM WHAT IS UNDER TEST.** The §11 handshake still runs for
/// real, against real chains, with real signatures — what is skipped is the ceremony that produced
/// them, which §12.1's own checks cover. It is the same kind of affordance as `RDEV_TEST_PATTERN`:
/// a stand-in for one input, not a weakening of the path.
///
/// **THE FILE IS MINTED PER ORIGIN, AND THAT IS WHY THERE IS NO POLICY OVERRIDE HERE.**
/// `protocol/fixtures/e2e-session.json` carries devices whose root assertions name
/// `https://rdev.example`, so a host on `http://localhost:8787` would fail `verifyBundle`'s origin
/// check against its own policy. The way out is NOT to let a test override §10.1's policy — the one
/// thing that must come from trusted application code — but to mint chains whose assertions name
/// the origin the test actually uses.
///
/// **IN MEMORY, NEVER IN THE KEYCHAIN.** A test identity that persisted would outlive the run that
/// made it and could be picked up by a later one that meant to be unenrolled.
public enum E2ETestIdentity {

    private struct Half: Decodable {
        let signing_private_key: String
        let noise_private_key: String
        let rendezvous_seed: String
        let bundle: String
    }

    private struct File: Decodable {
        let root: String
        let host: Half
        let client: Half
    }

    /// Nil when the variable is unset, which is the ordinary case; also nil when it is set and the
    /// file is unusable — a test that asked for a prepared identity and did not get one must not
    /// quietly become a device with none.
    public static func stores(processEnvironment: [String: String])
        -> (installations: InstallationStore.Backend, trust: InstallationStore.Backend)? {
        guard let path = processEnvironment["RDEV_E2E_TEST_IDENTITY"]?
                .trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            print("[e2e] RDEV_E2E_TEST_IDENTITY=\(path) could not be read")
            return nil
        }
        let role = processEnvironment["RDEV_E2E_TEST_ROLE"] ?? "host"
        let half = role == "client" ? file.client : file.host

        guard let keys = DeviceIdentity.Keys(signingPrivateKey: hex(half.signing_private_key),
                                             noisePrivateKey: hex(half.noise_private_key)),
              let installation = DeviceIdentity.Installation(
                keys: keys, rendezvousSeed: hex(half.rendezvous_seed)),
              case let encodedInstallation = DeviceIdentity.encode(installation),
              !encodedInstallation.isEmpty else {
            print("[e2e] RDEV_E2E_TEST_IDENTITY names keys this build cannot use")
            return nil
        }

        var record = E2ETrustStore.Record()
        record.root = hex(file.root)
        record.bundle = hex(half.bundle)
        // §12.2: nothing has been published, and saying otherwise would hide a real failure behind
        // a fixture. A gate that wants `confirmed` has to actually publish.
        record.publicationStatus = .unconfirmed
        guard let encodedRecord = E2ETrustStore.encode(record) else { return nil }

        print("[e2e] RDEV_E2E_TEST_IDENTITY: installed the \(role) identity from \(path)")
        return (InstallationStore.Memory(encodedInstallation), InstallationStore.Memory(encodedRecord))
    }

    private static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count / 2)
        var index = s.startIndex
        while index < s.endIndex, s.index(after: index) < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index ..< next], radix: 16) else { return [] }
            out.append(byte)
            index = next
        }
        return out
    }
}
