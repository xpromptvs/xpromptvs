import Foundation

/// `RDEV_INSTRUMENTS=1` turns the cursor overlay and the latency probe on; OFF by default, and a
/// narrower explicit choice wins (`??=`). Returns the variables to SET — main applies them before
/// anything reads the environment. Reasoning: docs/desktop-app.md.
public enum Instruments {
    public static func overrides(env: [String: String]) -> [String: String] {
        guard env["RDEV_INSTRUMENTS"] == "1" else { return [:] }
        var out: [String: String] = [:]
        for key in ["RDEV_CURSOR_OVERLAY", "RDEV_LATENCY_PROBE"] where env[key] == nil { out[key] = "1" }
        return out
    }
}
