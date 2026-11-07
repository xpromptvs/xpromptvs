import Foundation

/// The control plane and §10.1's ceremony origin. They DIFFER whenever `RDEV_E2E_ORIGIN` is set,
/// and a chain checked under the wrong one is refused for a reason naming neither.
public struct ShellEnvironment: Equatable, Sendable {
    /// The client's origin since 2026-10-06 — the apex is the landing page. The Worker answers its API on
    /// both, so a build pointing at the apex keeps working; links this app hands out (the share QR,
    /// "Add by code") now open the client directly. §10.1's policy is the product's on either
    /// (`E2EOrigin.product`).
    public static let deployed = "https://app.xpromptvs.ai"
    public let signalingBase: String
    public let e2eOrigin: String
    public let channel: String
    public init(env: [String: String], channel: String = "staging") {
        precondition(channel == "public" || channel == "staging")
        self.channel = channel
        func strip(_ s: String) -> String { var s = s; while s.hasSuffix("/") { s.removeLast() }; return s }
        signalingBase = strip(env["RDEV_SIGNALING"] ?? (channel == "public" ? Self.deployed : "https://staging.xpromptvs.ai"))
        e2eOrigin = strip(env["RDEV_E2E_ORIGIN"] ?? signalingBase)
    }
}
