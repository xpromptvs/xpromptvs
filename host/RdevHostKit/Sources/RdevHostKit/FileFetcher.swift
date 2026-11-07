import Foundation
import ImageIO
import RdevCore
import UniformTypeIdentifiers

/// **THE HOST'S HALF OF AN IMAGE PATH OPENING ON THE CLIENT** (`FileFetch`; docs/terminal.md, "An image path opens on
/// the client"): resolves the path against its tab's directory, checks it is an image file within the cap, reads it —
/// converting HEIC and TIFF to JPEG — and sends it in pieces, on its OWN queue: a tmux directory runs a process and a
/// file is read whole, and neither may hold the message path.
///
/// READ, NEVER MAPPED: a mapping of a file on a network volume dies with SIGBUS when the volume goes (the paste
/// archives learned it, docs/desktop-app.md).
///
/// PACED: a piece waits while the channel holds more than `paceBytes` unsent — pion queues whatever it is handed, and
/// 27 MB of base64 handed over at once held every control message (and the terminal's output, one SCTP queue) behind
/// it for as long as the link took. The same 256 KiB the client keeps to under its own paste upload.
final class FileFetcher: @unchecked Sendable {
    /// Unsent bytes above which the next piece waits.
    static let paceBytes = 256 * 1024
    /// Waiting this long for the channel to drain abandons the transfer (the client gave up at its 15 s).
    static let stallSeconds: TimeInterval = 30
    static let pollSeconds: TimeInterval = 0.008

    private let queue = DispatchQueue(label: "rdev.file-fetch", qos: .userInitiated)
    private let directory: @Sendable (TermTabID) -> String?
    private let home: String
    private let maxBytes: Int
    private let sleep: @Sendable (TimeInterval) -> Void
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    /// Each client's LAST request: the client keeps only its newest (a second tap drops the first), so an older
    /// transfer stops at its next piece rather than finishing for nobody.
    private var latest: [String: String] = [:]

    init(directory: @escaping @Sendable (TermTabID) -> String?, home: String, maxBytes: Int = FileFetch.maxBytes,
         sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.directory = directory; self.home = home; self.maxBytes = maxBytes; self.sleep = sleep; self.now = now
    }

    /// Answer `client`'s `request` through `send`, every message in order, on this fetcher's queue, each piece paced
    /// on `buffered` (`ClientConnection.bufferedAmount` of `bulk`; nil — the channel closed — stops it).
    func fetch(_ request: FileGet, client: String = "", send: @escaping @Sendable (Data) -> Void,
               buffered: @escaping @Sendable () -> Int? = { 0 }) {
        lock.withLock { latest[client] = request.id }
        queue.async { [self] in
            defer { lock.withLock { if latest[client] == request.id { latest[client] = nil } } }
            guard isLatest(request.id, of: client) else { return }
            switch load(request) {
            case .failure(let reason): send(FileFetch.errorJSON(id: request.id, reason: reason))
            case .success(let file):
                send(FileFetch.beginJSON(id: request.id, name: file.name, mime: file.mime, size: file.bytes.count, path: file.path))
                var seq = 0, at = 0
                while at < file.bytes.count {
                    guard drained(request.id, of: client, buffered) else { return }
                    let end = min(at + FileFetch.chunkBytes, file.bytes.count)
                    send(FileFetch.dataJSON(id: request.id, seq: seq, bytes: file.bytes.subdata(in: at..<end)))
                    seq += 1; at = end
                }
                send(FileFetch.endJSON(id: request.id))
            }
        }
    }

    private func isLatest(_ id: String, of client: String) -> Bool { lock.withLock { latest[client] == id } }

    /// Wait until the channel holds at most `paceBytes`: true to send the next piece, false to stop — a newer
    /// request from the same client, the channel closed, or `stallSeconds` without it draining.
    private func drained(_ id: String, of client: String, _ buffered: () -> Int?) -> Bool {
        var since: TimeInterval?
        while true {
            guard isLatest(id, of: client), let held = buffered() else { return false }
            if held <= Self.paceBytes { return true }
            let t = now()
            if let since { if t - since > Self.stallSeconds { return false } } else { since = t }
            sleep(Self.pollSeconds)
        }
    }

    struct Loaded { let name: String; let mime: String; let path: String; let bytes: Data }

    func load(_ request: FileGet) -> Result<Loaded, FileFetchError> {
        let dir = request.path.hasPrefix("/") || request.path.hasPrefix("~") ? nil : directory(request.term)
        guard let path = FileFetch.resolve(request.path, directory: dir, home: home) else { return .failure(.notFound) }
        let kind = FileFetch.kind(ofPath: path)
        if kind == .none { return .failure(.notImage) }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular else { return .failure(.notFound) }
        if let size = attrs[.size] as? Int, size > maxBytes { return .failure(.tooLarge) }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return .failure(.unreadable) }
        if bytes.count > maxBytes { return .failure(.tooLarge) }
        let name = (path as NSString).lastPathComponent
        switch kind {
        case .shown(let mime): return .success(Loaded(name: name, mime: mime, path: path, bytes: bytes))
        case .converted:
            guard let jpeg = Self.jpeg(from: bytes) else { return .failure(.unreadable) }
            return .success(Loaded(name: name, mime: "image/jpeg", path: path, bytes: jpeg))
        case .none: return .failure(.notImage)
        }
    }

    /// The largest side a converted image keeps: a photo's 6000+ pixels are more than any screen shows.
    static let convertedMaxPixels = 4096

    /// A HEIC or TIFF as a JPEG — UPRIGHT (its EXIF orientation applied: an iPhone photo is stored sideways) and no
    /// larger than `convertedMaxPixels`. Nil when ImageIO cannot read it.
    static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: convertedMaxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
