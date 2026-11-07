import Foundation

/// WHAT WAS COPIED IN FINDER, FOR A PASTE INTO A CLIENT WINDOW (docs/client-web.md, "A folder"). A web page is
/// never told a file's path, and a FOLDER reaches it as a 0-byte `File` with no type — which the paste then
/// skipped as empty ("Nothing to paste"). So the app reads the pasteboard itself (`__rdevShell.pasteboardFiles`)
/// and, for a paste to ANOTHER Mac, makes what is sent (`preparePaste`): a folder ZIPPED as Finder's Compress
/// makes it, a file as it is — served to the page that asked, once, at `app://client/__paste/<token>/<name>`.
public struct LocalPasteFile: Equatable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool

    public init(path: String, name: String, isDirectory: Bool) {
        self.path = path; self.name = name; self.isDirectory = isDirectory
    }

    /// What the page receives.
    public var json: [String: Any] { ["path": path, "name": name, "dir": isDirectory] }
}

public enum LocalPastes {
    /// The file URLs among `urls`, in order, each still on disk. A PACKAGE (an `.app`, a `.pages`) is a directory,
    /// and is zipped as Finder zips it.
    public static func files(_ urls: [URL], fileManager: FileManager = .default) -> [LocalPasteFile] {
        urls.compactMap { u in
            guard u.isFileURL else { return nil }
            let path = u.standardizedFileURL.path
            var dir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &dir) else { return nil }
            return LocalPasteFile(path: path, name: (path as NSString).lastPathComponent, isDirectory: dir.boolValue)
        }
    }

    public enum ZipError: Error, Equatable {
        case failed(status: Int32, message: String)
        /// The archive passed `limit` and was stopped there.
        case tooLarge
        /// Its job was cancelled.
        case cancelled
    }

    /// `folder` zipped into `dir` as `archive.zip` — a FIXED name, because `<name>.zip` passes NAME_MAX for a
    /// folder name of 252 bytes or more; the name a page shows is the registry's — as Finder's Compress makes it:
    /// `ditto -c -k --sequesterRsrc --keepParent`, so the folder is the archive's one top-level entry and resource
    /// forks and extended attributes ride in `__MACOSX`, where any unzip finds them and none is confused by them.
    ///
    /// STOPPED, NEVER FINISHED FIRST: the archive is watched as it grows and `ditto` is killed once it passes
    /// `limit` (a 40 GB folder, or the boot volume, would otherwise write until done), or the moment `job` is
    /// cancelled (Stop sending, its window closing, the app quitting). Either leaves no archive. Blocks until
    /// `ditto` exits — call it off the main thread.
    public static func zip(folder: URL, into dir: URL, limit: Int64 = .max, job: ZipJob? = nil,
                           fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("archive.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, out.path]
        // stderr is drained as it comes: a child whose pipe fills (a permission error per file) would block
        // forever while this waits for it to exit. Only its head is kept, for the message.
        let err = Pipe(), said = NSMutableData(), saidLock = NSLock()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            saidLock.withLock { if said.length < 4096 { said.append(d) } }
        }
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        guard job?.attach(p) ?? true else { throw ZipError.cancelled }
        defer { job?.detach() }
        try p.run()
        var tooLarge = false
        while p.isRunning {
            // A cancel between `attach` and `run` found nothing running to kill: it is seen here.
            if job?.isCancelled == true { p.terminate(); break }
            if limit < .max, let size = (try? fileManager.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value,
               size > limit {
                tooLarge = true
                p.terminate()
                break
            }
            usleep(50_000)
        }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        // A zip done between two looks is measured whole.
        if !tooLarge, limit < .max, let size = (try? fileManager.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value,
           size > limit { tooLarge = true }
        let cancelled = job?.isCancelled ?? false
        guard !tooLarge, !cancelled, p.terminationStatus == 0 else {
            try? fileManager.removeItem(at: out)
            if tooLarge { throw ZipError.tooLarge }
            if cancelled { throw ZipError.cancelled }
            let message = saidLock.withLock { String(decoding: said as Data, as: UTF8.self) }
            throw ZipError.failed(status: p.terminationStatus, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }
}

/// ONE ZIP IN THE MAKING, and the way to stop it: `cancel` kills its `ditto` now (or keeps it from starting),
/// from any thread.
public final class ZipJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let p: Process? = lock.withLock { cancelled = true; return process }
        if let p, p.isRunning { p.terminate() }
    }

    /// False when already cancelled: the zip must not start.
    func attach(_ p: Process) -> Bool { lock.withLock { process = p; return !cancelled } }
    func detach() { lock.withLock { process = nil } }
}

/// THE FILES A PAGE ASKED FOR, until it fetches them: each under an unguessable token, for the web view that
/// asked and no other, and ONCE — the fetch takes it. A TEMPORARY one (a zip the app made) is deleted when it
/// is taken and served, discarded, or purged; a person's own file never is.
public final class PreparedPastes: @unchecked Sendable {
    public struct Entry: Equatable {
        public let file: URL
        public let name: String
        public let type: String
        public let temporary: Bool
        let owner: AnyHashable
    }

    public static let routePrefix = "/__paste/"

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    /// Registers `file` for `owner` and answers the URL the page fetches it at.
    public func add(file: URL, name: String, type: String, temporary: Bool, owner: AnyHashable) -> String {
        let token = UUID().uuidString.lowercased()
        lock.withLock { entries[token] = Entry(file: file, name: name, type: type, temporary: temporary, owner: owner) }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "file"
        return "app://client\(Self.routePrefix)\(token)/\(encoded)"
    }

    /// The token in a `/__paste/<token>/<name>` path, or nil when the path is not that route.
    public static func token(inPath path: String) -> String? {
        guard path.hasPrefix(routePrefix) else { return nil }
        let rest = path.dropFirst(routePrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let token = String(rest[..<slash])
        return token.isEmpty ? nil : token
    }

    /// The entry for `token`, removed — only for the web view that asked for it.
    public func take(_ token: String, owner: AnyHashable) -> Entry? {
        lock.withLock {
            guard let e = entries[token], e.owner == owner else { return nil }
            entries[token] = nil
            return e
        }
    }

    /// A taken entry has been served (or failed to be): a temporary file goes.
    public func finished(_ e: Entry) {
        if e.temporary { try? fileManager.removeItem(at: e.file.deletingLastPathComponent()) }
    }

    /// The page will not fetch these (the person cancelled): each goes, and a temporary file with it.
    public func discard(urls: [String], owner: AnyHashable) {
        for u in urls {
            guard let path = URL(string: u)?.path(percentEncoded: true), let t = Self.token(inPath: path),
                  let e = take(t, owner: owner) else { continue }
            finished(e)
        }
    }

    /// Everything still registered for `owner` (its window closed), or for everyone (`nil`).
    public func purge(owner: AnyHashable? = nil) {
        let gone: [Entry] = lock.withLock {
            let out = entries.filter { owner == nil || $0.value.owner == owner }
            for k in out.keys { entries[k] = nil }
            return Array(out.values)
        }
        gone.forEach(finished)
    }

    public var count: Int { lock.withLock { entries.count } }
}
