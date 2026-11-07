import Foundation
public enum NativeSimulatorPointer {
    public static func normalized(_ point: CGPoint, in rect: CGRect, dragging: Bool) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, dragging || rect.contains(point) else { return nil }
        return clamp(CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height))
    }
    public static func fingers(at point: CGPoint, press: CGPoint, option: Bool, shift: Bool) -> [CGPoint] {
        guard option else { return [clamp(point)] }
        let second = shift ? CGPoint(x: 1 - press.x + point.x - press.x, y: 1 - press.y + point.y - press.y)
                           : CGPoint(x: 1 - point.x, y: 1 - point.y)
        return [clamp(point), clamp(second)]
    }
    private static func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y))) }
}
