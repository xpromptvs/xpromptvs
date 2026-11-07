public struct RealtimeVideoDimensions: Equatable, Sendable {
    public static let minimumWidth = 72
    public static let maximumWidth = 3_840
    public static let minimumHeight = 64
    public static let maximumHeight = 2_160

    public static let captureDefault = RealtimeVideoDimensions(
        validatedWidth: 1_920,
        validatedHeight: 1_080
    )

    public let width: Int
    public let height: Int

    public init?(width: Int, height: Int) {
        guard (Self.minimumWidth...Self.maximumWidth).contains(width),
              (Self.minimumHeight...Self.maximumHeight).contains(height),
              width.isMultiple(of: 2),
              height.isMultiple(of: 2) else {
            return nil
        }
        self.init(validatedWidth: width, validatedHeight: height)
    }

    private init(validatedWidth: Int, validatedHeight: Int) {
        width = validatedWidth
        height = validatedHeight
    }
}
