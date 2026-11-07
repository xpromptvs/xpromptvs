import Foundation
import RdevCore

/// A file being received: written under a PARTIAL name nobody will type, renamed when whole.
final class PasteFile {
    let partial: URL
    let finalURL: URL
    private let handle: FileHandle
    init(partial: URL, finalURL: URL, handle: FileHandle) { self.partial = partial; self.finalURL = finalURL; self.handle = handle }
    func append(_ data: Data) throws { try handle.write(contentsOf: data) }
    func close() { try? handle.close() }
}

/// THE PASTE FOLDER (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §6): `0700`, every file
/// `0600`, written as `.<name>.partial` and renamed when whole; emptied at launch (a run that ended cleanly
/// left nothing, so anything there is a crash's) and at quit; swept by `PasteSweep`'s rule.
final class PasteStore: @unchecked Sendable {
    let directory: URL
    private let now: () -> Date
    private let lock = NSLock()
    /// Final names handed out and not yet committed or discarded — so two files opened in one second
    /// never pick the same name before either exists on disk. KEYED IGNORING CASE (`key`), as the volume
    /// compares them.
    private var reserved: Set<String> = []
    private let fm = FileManager.default

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    /// `~/Library/Caches/<bundleID>/Pastes` — no space anywhere (`Application Support` has one, and the
    /// path is TYPED).
    static func defaultDirectory(bundleID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID).appendingPathComponent("Pastes")
    }

    func prepareAtLaunch() {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        emptyAll()
    }

    func emptyAll() {
        lock.withLock { reserved.removeAll() }
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// A name as the volume compares it. APFS — the default — is case-INSENSITIVE: `…-Photo.png` and
    /// `…-photo.png` are ONE file there, so two items of one delivery named so shared one partial, the first
    /// commit took the second's bytes and the second threw (`disk`, the whole delivery deleted). Lowercasing is
    /// the whole fold: a saved name is ASCII by construction (`PasteNames`).
    private static func key(_ name: String) -> String { name.lowercased() }

    /// Whether `name` is handed out or on disk. Call with `lock` held. (The disk's own answer already ignores
    /// case on APFS; a case-sensitive volume is served by the reservation's.)
    private func taken(_ name: String) -> Bool {
        reserved.contains(Self.key(name)) || fm.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func open(name: String, type: String) throws -> PasteFile {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let final: String = lock.withLock {
            let n = PasteNames.savedName(original: name, type: type, at: now()) { taken($0) }
            reserved.insert(Self.key(n))
            return n
        }
        let partial = directory.appendingPathComponent(".\(final).partial")
        guard fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = FileHandle(forWritingAtPath: partial.path) else {
            lock.withLock { _ = reserved.remove(Self.key(final)) }
            throw CocoaError(.fileWriteUnknown)
        }
        return PasteFile(partial: partial, finalURL: directory.appendingPathComponent(final), handle: h)
    }

    func commit(_ f: PasteFile) throws -> URL {
        f.close()
        defer { lock.withLock { _ = reserved.remove(Self.key(f.finalURL.lastPathComponent)) } }
        try fm.moveItem(at: f.partial, to: f.finalURL)
        return f.finalURL
    }

    func discard(_ f: PasteFile) {
        f.close()
        try? fm.removeItem(at: f.partial)
        lock.withLock { _ = reserved.remove(Self.key(f.finalURL.lastPathComponent)) }
    }

    func delete(_ urls: [URL]) { for u in urls { try? fm.removeItem(at: u) } }

    /// A file the host wrote into the folder ITSELF rather than through `open` — a HEIC's JPEG, which ImageIO
    /// creates with the process umask (0644): made `0600` like every other file here. false when it could not
    /// be, and the caller does not use the file.
    func makePrivate(_ url: URL) -> Bool {
        (try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil
    }

    /// A free name in the folder for a file the host DERIVES from a saved one — a HEIC's JPEG (§4.1):
    /// `<stem>.<ext>`, else `<stem>-2.<ext>`, … as `PasteNames.savedName` resolves a collision. Free of what is
    /// on disk AND of every name handed out to a file still arriving, which exists only as its partial; the
    /// caller writes it at once (the paste queue is the folder's only writer).
    func sibling(of url: URL, ext: String) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let name: String = lock.withLock {
            if !taken("\(stem).\(ext)") { return "\(stem).\(ext)" }
            for n in 2...999 where !taken("\(stem)-\(n).\(ext)") { return "\(stem)-\(n).\(ext)" }
            return "\(stem)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        }
        return directory.appendingPathComponent(name)
    }

    /// §6's sweep over the COMMITTED files (a partial is a delivery in flight, its own to clean).
    func sweep(keep: URL?) {
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }
        let infos: [PasteFileInfo] = names.compactMap { n in
            guard let a = try? fm.attributesOfItem(atPath: directory.appendingPathComponent(n).path) else { return nil }
            return PasteFileInfo(name: n, bytes: (a[.size] as? NSNumber)?.int64Value ?? 0,
                                 modified: (a[.modificationDate] as? Date) ?? .distantPast)
        }
        for n in PasteSweep.victims(infos, now: now(), keep: keep?.lastPathComponent) {
            try? fm.removeItem(at: directory.appendingPathComponent(n))
        }
    }
}
