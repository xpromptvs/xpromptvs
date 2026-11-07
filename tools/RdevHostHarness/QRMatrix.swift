import Foundation
import CoreImage

/// Builds a QR module matrix from a string with CoreImage's CIQRCodeGenerator, which emits one
/// pixel per module at native resolution — so reading the rendered bitmap 1:1 gives the grid.
/// Platform code (macOS); verified by eyeballing the printed QR + the smokes, not a unit test.
enum QRMatrix {
    // Correction level L (7%) — the lowest — yields the FEWEST modules for a given payload, so
    // each module is physically larger in the terminal and easier for a phone to scan. A screen
    // QR has no print/scuff damage, so L's low recovery margin is fine (M/Q/H only inflate the grid).
    static func from(_ text: String, correctionLevel: String = "L") -> [[Bool]]? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }

        let extent = image.extent
        let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
        guard w > 0, h > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let bmp = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        bmp.interpolationQuality = .none
        let ciCtx = CIContext(options: [.useSoftwareRenderer: true])
        guard let cg = ciCtx.createCGImage(image, from: extent) else { return nil }
        bmp.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // CGContext.draw(_:in:) already lays the image out row-0-at-top in the backing buffer
        // (confirmed empirically: a y-flip here produces a vertically MIRRORED — unscannable — QR).
        // Read rows top-down directly. Dark module (luma < 128) = true.
        var matrix = [[Bool]]()
        matrix.reserveCapacity(h)
        for row in 0..<h {
            var line = [Bool](); line.reserveCapacity(w)
            for x in 0..<w { line.append(pixels[row * w + x] < 128) }
            matrix.append(line)
        }
        return matrix
    }
}
