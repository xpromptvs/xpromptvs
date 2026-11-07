import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// A QR as a `data:image/png` URL — the ONLY shape the renderer accepts for `qrDataUrl`
/// (`e2e-row.ts` filters anything else). CoreImage replaces `qrcode-generator`; level M as before.
enum QRImage {
    static func dataURL(_ text: String) -> String {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let image = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return "" }
        let rep = NSBitmapImageRep(ciImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
