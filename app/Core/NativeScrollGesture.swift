import Foundation

/// AppKit's direct-contact phase and local momentum phase must not be conflated. The presenter
/// maps these outputs into source coordinates; no clock or delivery timing is read here.
public struct NativeScrollGesture {
    public enum Phase { case none, mayBegin, began, changed, ended, cancelled }
    public struct Sample {
        public let time: Double, dx: Double, dy: Double
        public let phase: Phase
        public let momentum: Bool, precise: Bool
        public init(time: Double, dx: Double, dy: Double, phase: Phase = .none,
                    momentum: Bool = false, precise: Bool = true) {
            self.time = time; self.dx = dx; self.dy = dy; self.phase = phase
            self.momentum = momentum; self.precise = precise
        }
    }
    public enum Output: Equatable {
        case begin
        case scroll(dx: Double, dy: Double, precise: Bool)
        case end(vx: Double, vy: Double)
        case cancel
    }
    private var active = false
    private var trail: [(time: Double, x: Double, y: Double)] = []
    private var travel = (x: 0.0, y: 0.0)
    public init() {}
    public mutating func handle(_ sample: Sample) -> [Output] {
        guard sample.time.isFinite, sample.dx.isFinite, sample.dy.isFinite else { return [] }
        guard !sample.momentum else { return [] }
        if !sample.precise || sample.phase == .none {
            guard sample.dx != 0 || sample.dy != 0 else { return [] }
            return cancel() + [.scroll(dx: -sample.dx, dy: -sample.dy, precise: sample.precise)]
        }
        if sample.phase == .cancelled { return cancel() }
        var out: [Output] = []
        if !active && sample.phase != .ended {
            active = true; trail = []; travel = (0, 0); out.append(.begin)
        }
        guard active else { return [] }
        if sample.dx != 0 || sample.dy != 0 {
            travel.x -= sample.dx; travel.y -= sample.dy
            if let last = trail.last, sample.time < last.time { trail = [] }
            trail.append((sample.time, travel.x, travel.y))
            // Retain one baseline older than the60ms window, matching touch FlingTracker.
            while trail.count > 2 && trail[1].time < sample.time - 0.060 { trail.removeFirst() }
            out.append(.scroll(dx: -sample.dx, dy: -sample.dy, precise: true))
        }
        if sample.phase == .ended {
            var vx = 0.0, vy = 0.0
            if let first = trail.first, let last = trail.last,
               sample.time - last.time <= 0.080, last.time > first.time {
                vx = (last.x - first.x) / (last.time - first.time)
                vy = (last.y - first.y) / (last.time - first.time)
                if hypot(vx, vy) < 200 { vx = 0; vy = 0 }
            }
            _ = cancel(); out.append(.end(vx: vx, vy: vy))
        }
        return out
    }
    public mutating func cancel() -> [Output] {
        let wasActive = active; active = false; trail = []; travel = (0, 0)
        return wasActive ? [.cancel] : []
    }
}
