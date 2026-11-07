import AppKit
import Foundation

/// What a window paste or drop puts on a pasteboard (§4.2, §5).
enum PasteboardContent: Equatable {
    case text(String)
    case files([URL])
}

/// THE MAC'S CLIPBOARD for a window paste (docs/superpowers/specs/2026-10-01-paste-and-drop-design.md §4.2).
/// A string; or one item per file carrying its FILE URL — and, for an image, PNG and TIFF on the SAME item,
/// so Finder takes the file and Notes or Slack the picture.
///
/// IN TWO HALVES, BY THREAD. The BYTES are made where the caller is — the paste queue, OFF main, because a large
/// photo's PNG and TIFF encodes are the slow part (ImageIO, `PasteImages`); the `NSPasteboardItem`s are AppKit
/// objects and are made on MAIN, in the same turn that writes the pasteboard — AppKit from another thread is not
/// safe, and the pasteboard write itself silently does nothing there (docs/gotchas.md). Reached with `async`,
/// never `.sync`.
enum WindowPasteboard {
    /// One pasteboard item, as plain values — what crosses from the paste queue to main.
    struct Item: Equatable, Sendable {
        var string: String?
        var fileURL: String?
        var png: Data?
        var tiff: Data?
    }

    /// The bytes, OFF main.
    static func payload(for content: PasteboardContent) -> [Item] {
        switch content {
        case .text(let s):
            return [Item(string: s)]
        case .files(let urls):
            return urls.map { url in
                let image = PasteImages.isImage(url)
                return Item(fileURL: url.absoluteString,
                            png: image ? PasteImages.png(url) : nil, tiff: image ? PasteImages.tiff(url) : nil)
            }
        }
    }

    /// The AppKit objects, ON main.
    @MainActor
    static func items(for payload: [Item]) -> [NSPasteboardItem] {
        payload.map { p in
            let item = NSPasteboardItem()
            if let s = p.string { item.setString(s, forType: .string) }
            if let u = p.fileURL { item.setString(u, forType: .fileURL) }
            if let png = p.png { item.setData(png, forType: .png) }
            if let tiff = p.tiff { item.setData(tiff, forType: .tiff) }
            return item
        }
    }

    /// `completion` runs on MAIN, after the write.
    static func write(_ content: PasteboardContent, to pasteboard: NSPasteboard = .general,
                      completion: @escaping (Bool) -> Void) {
        let payload = payload(for: content)     // the image work stays OFF main
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let items = items(for: payload)
                pasteboard.clearContents()
                completion(pasteboard.writeObjects(items))
            }
        }
    }
}
