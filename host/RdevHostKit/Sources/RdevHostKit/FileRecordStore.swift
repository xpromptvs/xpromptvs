import Foundation
import RdevCore

/// A file behind `InstallationStore.Backend`, for the durable state that is **not secret**.
///
/// §10.2 puts only the KEYS in the keychain: "Native private keys use local keychain storage." The
/// §10.2 trust record — the root descriptor, this device's own chain, revocation tombstones, a
/// pending operation — is all public by construction. A root descriptor is published to the
/// directory; a bundle is presented to every peer. Putting it in the keychain would buy nothing and
/// cost a prompt on a value nobody needs protected.
///
/// **THE WRITE IS ATOMIC, AND THAT IS THE WHOLE REASON THIS IS NOT THREE LINES.** A torn write
/// produces bytes that are not a record, and `E2EIdentityManager` answers that with `blocked` —
/// correctly, because it cannot tell a truncated file from a corrupted one, and overwriting either
/// would silently abandon an identity. So the failure this class exists to prevent is a device
/// bricked by a power cut mid-save. Write to a temporary file in the SAME directory, then
/// `replaceItemAt`, which is a rename: the old bytes are there or the new ones are, never half.
public struct FileRecordStore: InstallationStore.Backend {

    /// `~/Library/Application Support/dev.rdev.host/` — `dev.rdev.host`, not the app's bundle id,
    /// `dev.rdev.host`, not the app's bundle id: `docs/desktop-app.md` keeps that identifier with
    /// the harness and `ai.xpromptvs.app` with the packaged app, and a device's identity must not depend
    /// on which of them is running.
    public static let defaultDirectory = "dev.rdev.host"
    public static let defaultName = "e2e-trust-v1"
    /// The device's own keys, which used to live in the login keychain.
    ///
    /// **The login keychain bought these bytes nothing**, measured before it was removed — see
    /// `git log -p -- host/RdevHostKit/Sources/RdevHostKit/KeychainInstallation.swift`: an item written by a binary signed
    /// `rdev Self-Signed` was read by a separate ad-hoc-signed binary with NO prompt and NO error.
    /// It never protected these bytes from another process running as this user, which is the only
    /// realistic reader — §2 already assumes installed native code is honest, and a same-user
    /// process can read `~/Library`, attach a debugger or read the keychain file in any case.
    ///
    /// What it cost was real: a keychain ACL binds to the code signature that created the item, so
    /// every re-signed build prompts the person — and, measured, a rebuilt binary reading an earlier
    /// build's item can sit inside `SecItemCopyMatching` INDEFINITELY with nothing to see. A hang is
    /// worse than a crash.
    ///
    /// Beside the trust record on purpose. `RDEV_E2E_STORE` exists so the two move
    /// together — "two runs sharing a trust file while holding different keys would be a device
    /// presenting a chain for keys it does not have" — and one directory makes that structural
    /// rather than a rule someone has to keep. `write` sets 0600 before the file is visible under
    /// its real name, which is what these bytes need and all the keychain was giving them.
    public static let installationName = "e2e-installation-v1"
    /// **A passkey this Mac created and never finished** — its root descriptor, retained the moment the
    /// registration returns, because WebAuthn hands out a public key only then (`E2EHostIdentity
    /// .createPasskey`). The browser's IndexedDB `pending-v1`. Public bytes; kept beside the keys so
    /// `RDEV_E2E_STORE` moves it with them.
    public static let pendingRootName = "e2e-pending-root-v1"

    private let url: URL

    /// Nil when the support directory cannot be located or created — a device with nowhere durable
    /// to write has no identity to speak of, and a caller must hear that rather than get a store
    /// that silently forgets.
    /// A nil `directory` means the default. Spelled that way rather than with an overload so a
    /// caller threading an OPTIONAL override — which is what `RDEV_E2E_STORE` is — cannot
    /// accidentally pass an empty string and land in `~/Library/Application Support/`.
    public init?(directory: String? = nil, name: String = FileRecordStore.defaultName) {
        let directory = directory.flatMap { $0.isEmpty ? nil : $0 } ?? FileRecordStore.defaultDirectory
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let folder = support.appendingPathComponent(directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        url = folder.appendingPathComponent(name, isDirectory: false)
    }

    /// For tests, and for a caller that has its own directory.
    public init(url: URL) { self.url = url }

    public func read() -> [UInt8]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return [UInt8](data)
    }

    public func write(_ bytes: [UInt8]) -> Bool {
        let directory = url.deletingLastPathComponent()
        // The temporary file must be in the SAME directory: `replaceItemAt` across volumes is a copy
        // rather than a rename, and a copy is not atomic.
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            try Data(bytes).write(to: temporary, options: .atomic)
            // 0600 before it is visible under its real name, not after.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    public func delete() -> Bool {
        // Already absent is the outcome the caller asked for.
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
