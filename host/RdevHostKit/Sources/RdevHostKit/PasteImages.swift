import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The image work a paste needs (§4.1, §4.2): a HEIC for a TERMINAL becomes a JPEG (Claude cannot read
/// HEIC), and an image for a WINDOW goes on the clipboard as PNG and TIFF beside its file URL.
enum PasteImages {
    static func isHEIC(type: String, name: String) -> Bool {
        let t = type.lowercased()
        if t == "image/heic" || t == "image/heif" { return true }
        let e = (name as NSString).pathExtension.lowercased()
        return e == "heic" || e == "heif"
    }

    static func jpeg(fromHEIC src: URL, to dst: URL) -> Bool {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(s, 0, nil),
              let d = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil)   // keeps the orientation
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        if let props { CGImageDestinationSetProperties(d, props) }
        return CGImageDestinationFinalize(d)
    }

    static func isImage(_ url: URL) -> Bool {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let t = CGImageSourceGetType(s) else { return false }
        return UTType(t as String)?.conforms(to: .image) ?? false
    }

    static func png(_ url: URL) -> Data? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, image, nil)
        return CGImageDestinationFinalize(d) ? out as Data : nil
    }

    // ImageIO, not NSImage: this runs OFF the main thread (`WindowPasteboard.payload`), where AppKit is not safe.
    static func tiff(_ url: URL) -> Data? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(d, image, nil)
        return CGImageDestinationFinalize(d) ? out as Data : nil
    }
}
