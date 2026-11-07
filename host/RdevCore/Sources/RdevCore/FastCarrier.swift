import Foundation
public enum FastCarrierKind: String, Sendable { case webSocket, webRTC }
public final class FastCarrierPolicy {
    public enum Effect: Equatable { case sendProbe(FastCarrierKind, UInt8, UInt64), select(FastCarrierKind) }
    private final class Path {
        var open = [false, false, false], heard = [Double](repeating: -.infinity, count: 3)
        var lastProbe = -Double.infinity
        var challenges: [[UInt64: Double]] = [[:], [:], [:]]
    }
    private let ws = Path(), rtc = Path()
    public private(set) var selected: FastCarrierKind = .webSocket
    private var retryAt = 0.0
    private var progress = [0.0, 0.0, 0.0]
    private var pending = [false, false, false]
    private let nonce: () -> UInt64
    public init(nonce: @escaping () -> UInt64 = { UInt64.random(in: .min ... .max) }) { self.nonce = nonce }
    private func path(_ c: FastCarrierKind) -> Path { c == .webSocket ? ws : rtc }
    public func channelState(_ c: FastCarrierKind, stream: UInt8, open: Bool, nowMs: Double) -> [Effect] {
        guard stream <= 2 else { return [] }; let p = path(c), s = Int(stream); p.open[s] = open
        if !open { p.heard[s] = -.infinity; p.challenges[s].removeAll() }
        return evaluate(nowMs)
    }
    public func setOutstanding(_ value: Bool, stream: UInt8, nowMs: Double) {
        guard stream <= 2 else { return }; let s = Int(stream)
        if value && !pending[s] { progress[s] = nowMs }; pending[s] = value
    }
    /// Only advancing, validated delivery ACKs reach this method. After migration they also
    /// prove carrier liveness; each stream still has its independent outstanding-data deadline.
    public func dataProgress(_ c: FastCarrierKind, stream: UInt8, nowMs: Double) {
        guard stream <= 2 else { return }; if c == selected { progress[Int(stream)] = nowMs; if c == .webRTC { rtc.heard[2] = nowMs } }
    }
    public func probeReply(_ c: FastCarrierKind, stream: UInt8, nonce: UInt64, nowMs: Double) -> [Effect] {
        guard stream <= 2 else { return [] }; let p = path(c), s = Int(stream)
        guard p.open[s], let sent = p.challenges[s][nonce], nowMs - sent <= 3000 else { return [] }
        p.challenges[s][nonce] = nil; p.heard[s] = nowMs; return evaluate(nowMs)
    }
    public func tick(nowMs: Double) -> [Effect] {
        var effects = evaluate(nowMs)
        for c in [FastCarrierKind.webSocket, .webRTC] {
            let p = path(c); guard nowMs - p.lastProbe >= 1000, !(c == .webRTC && selected == .webRTC && nowMs - p.heard[2] < 1000) else { continue }; p.lastProbe = nowMs
            for s in 0...2 {
                p.challenges[s] = p.challenges[s].filter { nowMs - $0.value < 3000 }
                guard p.open[s], !(c == .webRTC && selected == .webRTC && s != 2) else { continue }; let n = nonce(); p.challenges[s][n] = nowMs
                effects.append(.sendProbe(c, UInt8(s), n))
            }
        }; return effects
    }
    private func healthy(_ c: FastCarrierKind, _ now: Double) -> Bool {
        let p = path(c)
        let proven = c == .webRTC && selected == .webRTC ? now - p.heard[2] < 3000 : p.heard.allSatisfy { now - $0 < 3000 }
        return p.open.allSatisfy { $0 } && proven
    }
    private func evaluate(_ now: Double) -> [Effect] {
        if selected == .webRTC {
            let closed = !rtc.open.allSatisfy { $0 }, stalled = (0...2).contains { pending[$0] && now - progress[$0] >= 5000 }
            if (closed && ws.open.allSatisfy { $0 }) || ((stalled || !healthy(.webRTC, now)) && healthy(.webSocket, now)) {
                selected = .webSocket; retryAt = now + 5000; progress = [Double](repeating: now, count: 3)
                rtc.heard = [Double](repeating: -.infinity, count: 3); rtc.challenges = [[:], [:], [:]]
                return [.select(.webSocket)]
            }
        } else if now >= retryAt && healthy(.webRTC, now) {
            selected = .webRTC; progress = [Double](repeating: now, count: 3); return [.select(.webRTC)]
        }; return []
    }
}
