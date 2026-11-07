/// One in-flight render and one replaceable pending frame. No frame queue grows behind the GPU.
public struct SimulatorRenderSchedule {
    private var busy = false
    private var visible = true
    private var stopped = false
    private var pending: UInt64?
    public init() {}
    public mutating func offer(sequence: UInt64) -> Bool {
        guard visible, !stopped else { return false }
        if busy { pending = sequence; return false }
        busy = true
        return true
    }
    public mutating func completed() -> UInt64? {
        guard !stopped, visible, let next = pending else { busy = false; pending = nil; return nil }
        pending = nil
        return next
    }
    public mutating func setVisible(_ value: Bool) { visible = value; if !value { pending = nil } }
    public mutating func stop() { stopped = true; pending = nil }
}
