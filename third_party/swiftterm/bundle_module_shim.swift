import Foundation

// Stands in for the `Bundle.module` accessor SwiftPM synthesizes for any target that
// declares resources. SwiftTerm's macOS target declares
// `resources: [.process("Apple/Metal/Shaders.metal")]`, and
// Apple/Metal/MetalTerminalRenderer.swift references Bundle.module inside
// `#if os(macOS) || os(iOS) || os(visionOS)` — active here. Without this the library does
// not compile at all under a plain swift_library.
//
// SAFE FOR RDEV, and worth stating why rather than assuming it: rdev uses SwiftTerm
// strictly headlessly. RdevCore/Terminal.swift is the only importer and references exactly
// three symbols — Terminal, TerminalDelegate, TerminalOptions — none of which touch the
// Metal renderer. The shader this bundle would locate is never loaded, so the accessor is
// compiled and never meaningfully exercised.
//
// Do NOT "fix" this by excluding Apple/, Mac/ and iOS/ (what SwiftTerm's own Linux and
// Windows configuration does). That was measured and does not compile on macOS: the core
// depends on the view layer via TerminalViewSearch.swift (`extension TerminalView`) and
// CharData.swift (`TTImage`).
extension Bundle {
    static let module = Bundle(for: BundleToken.self)
}

private final class BundleToken {}
