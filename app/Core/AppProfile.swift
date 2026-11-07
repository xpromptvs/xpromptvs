import CryptoKit
import Foundation

/// Where this run keeps its settings and its web storage. `RDEV_APP_PROFILE=<name>` isolates a
/// test run (the Electron `--user-data-dir`); unset is the person's own profile.
public struct AppProfile: Equatable, Sendable {
    public let name: String
    public let directory: URL
    /// A `WKWebsiteDataStore(forIdentifier:)` id derived from the name, so a name maps to the same
    /// store on every launch.
    public let dataStoreID: UUID
    /// FileRecordStore expects a name relative to Application Support, not an absolute URL.
    public let identityStoreName: String?

    /// THE APP'S OWN FOLDER under `Application Support` and `Caches`, named as its bundle id (`app/BUILD.bazel`),
    /// so a person finds them by the app's name — `dev.rdev.app` until the bundle id changed (2026-10-06, asked
    /// for; nothing moved over). §10.1's keys are NOT here: they live under `dev.rdev.host` (`FileRecordStore`),
    /// which no bundle id names, so changing this unenrols nothing.
    public static let folder = AppDistribution.official ? "ai.xpromptvs.app" : "ai.xpromptvs.development"

    /// THE PROFILE'S PASTE FOLDER (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §6):
    /// `<caches>/<folder>/<name>/Pastes`. Per profile, because a launch EMPTIES it and must never empty
    /// another running profile's; under Caches, because the path is TYPED into a terminal and
    /// `Application Support` has a space in it.
    public func pasteDirectory(caches: URL) -> URL {
        caches.appendingPathComponent(Self.folder).appendingPathComponent(name).appendingPathComponent("Pastes")
    }

    public var pasteDirectory: URL {
        pasteDirectory(caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    }

    /// THE ZIPS A FOLDER PASTE MAKES (`LocalPastes`, docs/client-web.md, "A folder"): beside the paste folder and
    /// per profile for the same reason — the app empties it at launch and at quit, and never another running
    /// profile's. Each is deleted the moment its page has read it.
    public func archiveDirectory(caches: URL) -> URL {
        caches.appendingPathComponent(Self.folder).appendingPathComponent(name).appendingPathComponent("PasteArchives")
    }

    public var archiveDirectory: URL {
        archiveDirectory(caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    }

    public static func resolve(env: [String: String], appSupport: URL, channel: String = "public") -> AppProfile? {
        guard channel == "public" || channel == "staging" else { return nil }
        let prefix = channel == "public" ? "" : "staging:"
        let publicBase = appSupport.appendingPathComponent(folder)
        let base = channel == "public" ? publicBase : publicBase.appendingPathComponent("channels/staging")
        guard let name = env["RDEV_APP_PROFILE"] else {
            return AppProfile(name: prefix + "default", directory: base, dataStoreID: uuid(prefix + "default"), identityStoreName: channel == "staging" ? folder + "/channels/staging/HostIdentity" : (AppDistribution.official ? nil : folder + "/HostIdentity"))
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...64).contains(name.count), name != ".", name != "..",
              name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return AppProfile(name: prefix + name, directory: base.appendingPathComponent("profiles").appendingPathComponent(name),
                          dataStoreID: uuid(prefix + name), identityStoreName: channel == "staging" ? folder + "/channels/staging/profiles/" + name + "/HostIdentity" : (AppDistribution.official ? nil : folder + "/profiles/" + name + "/HostIdentity"))
    }

    private static func uuid(_ name: String) -> UUID {
        var b = Array(SHA256.hash(data: Data("\(folder)/profile/\(name)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
