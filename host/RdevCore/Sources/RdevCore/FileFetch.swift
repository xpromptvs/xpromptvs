import Foundation

/// **AN IMAGE PATH IN THE TERMINAL OPENS ON THE CLIENT** (2026-10-05, asked for: "add image preview functionality.
/// when tapping a path (highlight it), it should open on the client if exists"; docs/terminal.md, "An image path
/// opens on the client"). The client asks for the file a path printed in a tab names (`file-get`); the host answers
/// with the image in pieces on `bulk` — `file-begin`, `file-data`…, `file-end` — or one `file-error`.
///
/// The DRIVER only, as the terminal is: it already has a shell, so reading a file grants nothing new. Images only,
/// by extension: this is a preview, and a path to anything else stays plain text on the client (`term-paths.ts`).
public struct FileGet: Equatable, Sendable {
    /// The client's name for this request (a paste id's shape, `PasteWire.isValidID`).
    public let id: String
    /// The tab the path was printed in: a relative path is relative to ITS current directory.
    public let term: TermTabID
    /// The path as printed — `~`, relative or absolute — unquoted and unescaped by the client.
    public let path: String
    public init(id: String, term: TermTabID, path: String) { self.id = id; self.term = term; self.path = path }
}

public enum FileFetchError: String, Error, Sendable {
    /// No such file — or not a regular one (a directory), or a relative path in a tab whose directory is unknown.
    case notFound = "not-found"
    /// Not an image this preview shows.
    case notImage = "not-image"
    /// Over `FileFetch.maxBytes`.
    case tooLarge = "too-large"
    /// It exists and could not be read or converted.
    case unreadable
    /// A passive client asked: the terminal is the driver's.
    case notDriver = "not-driver"
}

public enum FileFetch {
    public static let pathMaxBytes = 4096
    /// The largest image sent: a screenshot is a few MB, a photo rarely over 10. Over it is `too-large`, never a
    /// stall of `bulk`.
    public static let maxBytes = 20 * 1024 * 1024
    /// Raw bytes per `file-data` (base64 in the JSON: 64 KiB on the wire).
    public static let chunkBytes = 48 * 1024

    /// How a file is shown: as it is, with its MIME type; converted to JPEG by the host first (HEIC — an iPhone's
    /// photos — and TIFF: no browser shows them reliably); or not at all.
    public enum Kind: Equatable, Sendable { case shown(mime: String), converted, none }

    /// The extensions a path is an image by — the client's list too (`term-paths.ts`, `IMAGE_EXTENSIONS`).
    public static let shown: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "bmp": "image/bmp", "svg": "image/svg+xml", "avif": "image/avif", "ico": "image/x-icon",
    ]
    public static let converted: Set<String> = ["heic", "heif", "tif", "tiff"]

    public static func kind(ofPath path: String) -> Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        if let mime = shown[ext] { return .shown(mime: mime) }
        return converted.contains(ext) ? .converted : .none
    }

    public static func parse(_ obj: [String: Any]) -> FileGet? {
        guard let id = obj["id"] as? String, PasteWire.isValidID(id),
              let term = (obj["term"] as? String).flatMap(TermTabID.init(wire:)),
              let path = obj["path"] as? String, !path.isEmpty, path.utf8.count <= pathMaxBytes,
              !path.contains("\0") else { return nil }
        return FileGet(id: id, term: term, path: path)
    }

    /// The absolute path `path` names: `~` and `~/…` under `home`, a relative path under `directory` (the tab's
    /// current directory), `.` and `..` resolved. Nil for a relative path with no directory to be relative to.
    public static func resolve(_ path: String, directory: String?, home: String) -> String? {
        var p = path
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        if !p.hasPrefix("/") {
            guard let directory, directory.hasPrefix("/") else { return nil }
            p = directory + "/" + p
        }
        return (p as NSString).standardizingPath
    }

    public static func beginJSON(id: String, name: String, mime: String, size: Int, path: String) -> Data {
        json(["t": "file-begin", "id": id, "name": name, "mime": mime, "size": size, "path": path])
    }
    public static func dataJSON(id: String, seq: Int, bytes: Data) -> Data {
        json(["t": "file-data", "id": id, "seq": seq, "data": bytes.base64EncodedString()])
    }
    public static func endJSON(id: String) -> Data { json(["t": "file-end", "id": id]) }
    public static func errorJSON(id: String, reason: FileFetchError) -> Data {
        json(["t": "file-error", "id": id, "reason": reason.rawValue])
    }

    private static func json(_ obj: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }
}
