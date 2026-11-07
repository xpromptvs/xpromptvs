import Foundation

/// Renders a QR module matrix as terminal text by coloring the cell BACKGROUND (spaces on a black
/// or white background), one module per text row. Two earlier approaches failed to scan:
///   - half-blocks (▀▄) don't tile cleanly in many fonts → wandering module edges;
///   - a foreground full-block glyph (█) only fills the font's block extent, so the terminal's
///     line spacing (leading) shows as thin gaps BETWEEN rows, breaking vertical module runs.
/// The background color, by contrast, is painted across the whole cell INCLUDING the leading, so
/// vertical runs are gapless. (This is how `qrencode -t ANSI` renders.)
///
/// Modules are drawn `moduleWidth` cells wide. A terminal cell is ~twice as tall as it is wide, so
/// `moduleWidth: 2` yields near-square modules (robust to scan); `moduleWidth: 1` is ~1:2 tall
/// (borderline but still decodes) and half the width, for terminals too narrow for 2-wide.
///
/// True black/white 24-bit backgrounds keep contrast independent of the terminal theme (an ANSI
/// palette can remap `40`/`47` to low-contrast grays a phone won't scan).
public enum QRTerminalRenderer {
    static let darkCellSGR = "\u{1b}[48;2;0;0;0m"       // background = pure black  (dark module)
    static let lightCellSGR = "\u{1b}[48;2;255;255;255m" // background = pure white  (light module)
    static let resetSGR = "\u{1b}[0m"

    /// - Parameters:
    ///   - matrix: row-major module grid; `true` = dark module.
    ///   - quietZone: light-module margin added on all four sides (QR spec minimum is 4).
    ///   - moduleWidth: character cells per module horizontally (1 or 2). Clamped to ≥ 1.
    public static func render(_ matrix: [[Bool]], quietZone: Int = 4, moduleWidth: Int = 2) -> String {
        guard let first = matrix.first else { return "" }
        let n = first.count
        let q = max(0, quietZone)
        let mw = max(1, moduleWidth)
        let total = n + 2 * q

        // One text row. Run-length the modules so each contiguous same-color span is a single
        // background-color escape + a block of spaces (fewer escapes, gapless fill).
        func emit(_ cells: [Bool]) -> String {
            var s = ""
            var i = 0
            while i < cells.count {
                let v = cells[i]
                var j = i
                while j < cells.count && cells[j] == v { j += 1 }
                s += (v ? darkCellSGR : lightCellSGR)
                s += String(repeating: " ", count: (j - i) * mw)
                i = j
            }
            return s + resetSGR + "\n"
        }

        let lightRow = [Bool](repeating: false, count: total)
        let pad = [Bool](repeating: false, count: q)
        var out = ""
        for _ in 0..<q { out += emit(lightRow) }
        for row in matrix { out += emit(pad + row + pad) }
        for _ in 0..<q { out += emit(lightRow) }
        return out
    }

    /// Renders at the widest module (2 then 1) that fits `maxColumns`, keeping modules as square as
    /// possible without wrapping (a wrapped QR is unscannable). Prefer this over a fixed width.
    public static func render(_ matrix: [[Bool]], quietZone: Int = 4, maxColumns: Int) -> String {
        guard let first = matrix.first else { return "" }
        let totalModules = first.count + 2 * max(0, quietZone)
        let mw = (totalModules * 2 <= maxColumns) ? 2 : 1
        return render(matrix, quietZone: quietZone, moduleWidth: mw)
    }
}
