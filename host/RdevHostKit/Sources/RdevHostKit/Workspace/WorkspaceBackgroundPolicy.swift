import CoreGraphics

/// Background ownership is separate from membership: arbitrary application layers remain visible.
/// Native desktop roles are never safe app content, even when their owner is unfamiliar.
enum WorkspaceBackgroundPolicy {
    static func excludes(bundleID: String, layer: Int, frame: CGRect, display: CGRect) -> Bool {
        if bundleID == "com.apple.dock" || bundleID == "com.apple.wallpaper" ||
            bundleID.hasPrefix("com.apple.wallpaper.") { return true }
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        if layer == desktop || layer == icons { return true }
        // Finder's desktop has used adjacent private levels as well as desktopIconWindow.
        // Require both its owner and display coverage; normal Finder windows stay eligible.
        let coversDisplay = frame.insetBy(dx: -1, dy: -1).contains(display)
        // WindowManager/WindowServer use adjacent desktop-plane levels for wallpaper and its
        // top shading band (observed -2147483624, -2147483626 and -2147483602). Require native
        // desktop-plane ordering AND background geometry; ordinary negative app levels survive.
        let minimum = Int(CGWindowLevelForKey(.minimumWindow))
        let inDesktopPlane = layer >= minimum && layer <= icons + 1
        let topBand = abs(frame.minX - display.minX) <= 1 &&
            abs(frame.minY - display.minY) <= 1 && abs(frame.width - display.width) <= 1 &&
            frame.height > 0 && frame.height <= 100
        if inDesktopPlane && (coversDisplay || topBand) { return true }
        return bundleID == "com.apple.finder" && layer < 0 && coversDisplay
    }
}
