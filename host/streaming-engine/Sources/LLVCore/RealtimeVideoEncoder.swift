import CoreVideo

public final class RealtimeVideoEncoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (Result<EncodedAccessUnit, Error>) -> Void

    public let acceptedSettings: EncoderAcceptedSettings

    private enum Backend {
        case videoToolbox(VideoEncoder)
        case libaom(AV1Encoder)
    }

    private let backend: Backend
    private let startupBitrate: Int

    /// THE VIDEOTOOLBOX ARM USED TO RETURN `startupBitrate` UNCONDITIONALLY, which was coherent
    /// only while `setBitrate` refused that backend: with retargets landing, a fixed startup value
    /// would report the wrong bitrate forever, and the caller could not tell a retarget that was
    /// applied from one that was not. It reads the live session now, falling back to the startup
    /// value only if the property cannot be read at all.
    public var currentBitrate: Int {
        switch backend {
        case .videoToolbox(let encoder): encoder.appliedBitrate ?? startupBitrate
        case .libaom(let encoder): encoder.currentBitrate
        }
    }

    public convenience init(
        codec: VideoCodec,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        temporalCompression: Bool = true,
        outputHandler: @escaping OutputHandler
    ) throws {
        try self.init(
            codec: codec,
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            temporalCompression: temporalCompression,
            scalabilityMode: .l1t1,
            outputHandler: outputHandler
        )
    }

    public convenience init(
        codec: VideoCodec,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        temporalCompression: Bool = true,
        scalabilityMode: AV1ScalabilityMode,
        screenDetectionMode: AV1ScreenDetectionMode = .standard,
        outputHandler: @escaping OutputHandler
    ) throws {
        try self.init(
            codec: codec,
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            temporalCompression: temporalCompression,
            scalabilityMode: scalabilityMode,
            screenDetectionMode: screenDetectionMode,
            av1ObservationHandler: { _ in },
            outputHandler: outputHandler
        )
    }

    public convenience init(
        codec: VideoCodec,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        temporalCompression: Bool = true,
        av1ObservationHandler: @escaping AV1Encoder.ObservationHandler,
        outputHandler: @escaping OutputHandler
    ) throws {
        try self.init(
            codec: codec,
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            temporalCompression: temporalCompression,
            scalabilityMode: .l1t1,
            av1ObservationHandler: av1ObservationHandler,
            outputHandler: outputHandler
        )
    }

    /// libaom's `cpu-used`, 0 (slowest, best quality per bit) to 12 (fastest). **A PARAMETER, NOT
    /// A LADDER.** It defaults to `LibaomTuningProfile.currentControl.cpuUsed` — one place, so the
    /// default cannot drift from the profile — and is threaded down to `AOME_SET_CPUUSED` so the
    /// speed/quality trade can be measured and changed by a caller rather than by editing the
    /// engine. Choosing a value per resolution (as the retired SVT preset ladder did) is separate,
    /// measured work; this only makes the knob reachable.
    public static let defaultCpuUsed = LibaomTuningProfile.currentControl.cpuUsed

    public init(
        codec: VideoCodec,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        temporalCompression: Bool = true,
        scalabilityMode: AV1ScalabilityMode,
        screenDetectionMode: AV1ScreenDetectionMode = .standard,
        cpuUsed: Int = RealtimeVideoEncoder.defaultCpuUsed,
        colorConfiguration: AV1ColorConfiguration = .bt709,
        av1ObservationHandler: @escaping AV1Encoder.ObservationHandler,
        outputHandler: @escaping OutputHandler
    ) throws {
        startupBitrate = bitrate
        if codec == .av1 {
            let tuningProfile = LibaomTuningProfile.currentControl.replacing(
                cpuUsed: cpuUsed,
                screenDetectionMode: screenDetectionMode.libaomValue
            )
            let encoder = try AV1Encoder(
                width: width,
                height: height,
                fps: fps,
                bitrate: bitrate,
                temporalCompression: temporalCompression,
                scalabilityMode: scalabilityMode,
                tuningProfile: tuningProfile,
                colorConfiguration: colorConfiguration,
                observationHandler: av1ObservationHandler,
                outputHandler: outputHandler
            )
            let settings = encoder.acceptedSettings
            acceptedSettings = EncoderAcceptedSettings(
                hardwareAccelerated: false,
                lowLatencyRateControl: true,
                realTime: true,
                frameReordering: false,
                temporalCompression: settings.temporalCompression,
                maxFrameDelayCount: 0,
                prioritizeEncodingSpeedOverQuality: true,
                suggestedLookAheadFrameCount: 0,
                implementation: settings.implementation,
                cpuUsed: settings.cpuUsed,
                threads: settings.threads,
                tileColumns: settings.tileColumns,
                tileRows: settings.tileRows,
                lagInFrames: settings.lagInFrames,
                keyframeInterval: settings.keyframeInterval,
                screenDetectionMode: settings.screenDetectionMode,
                scalabilityMode: settings.scalabilityMode
            )
            backend = .libaom(encoder)
        } else {
            let encoder = try VideoEncoder(
                codec: codec,
                width: width,
                height: height,
                fps: fps,
                bitrate: bitrate,
                temporalCompression: temporalCompression,
                outputHandler: outputHandler
            )
            acceptedSettings = encoder.acceptedSettings
            backend = .videoToolbox(encoder)
        }
    }

    public func encode(
        pixelBuffer: CVPixelBuffer,
        frameID: UInt64,
        inputSequence: UInt64,
        forceKeyframe: Bool,
        referenceControl: AV1ReferenceControl? = nil
    ) throws {
        switch backend {
        case .videoToolbox(let encoder):
            guard referenceControl == nil else { throw VideoEncoderError.unsupportedCodec }
            try encoder.encode(
                pixelBuffer: pixelBuffer,
                frameID: frameID,
                inputSequence: inputSequence,
                forceKeyframe: forceKeyframe
            )
        case .libaom(let encoder):
            try encoder.encode(
                pixelBuffer: pixelBuffer,
                frameID: frameID,
                inputSequence: inputSequence,
                forceKeyframe: forceKeyframe,
                referenceControl: referenceControl
            )
        }
    }

    public func repeatLastFrame(
        frameID: UInt64,
        inputSequence: UInt64,
        forceKeyframe: Bool,
        referenceControl: AV1ReferenceControl? = nil
    ) throws {
        switch backend {
        case .videoToolbox:
            throw VideoEncoderError.unsupportedCodec
        case .libaom(let encoder):
            try encoder.repeatLastFrame(
                frameID: frameID,
                inputSequence: inputSequence,
                forceKeyframe: forceKeyframe,
                referenceControl: referenceControl
            )
        }
    }

    public func completeFrames() throws {
        switch backend {
        case .videoToolbox(let encoder): try encoder.completeFrames()
        case .libaom(let encoder): try encoder.completeFrames()
        }
    }

    public func setBitrate(_ bitsPerSecond: Int) throws {
        switch backend {
        case .videoToolbox(let encoder):
            try encoder.setBitrate(bitsPerSecond)
        case .libaom(let encoder):
            try encoder.setBitrate(bitsPerSecond)
        }
    }
}
