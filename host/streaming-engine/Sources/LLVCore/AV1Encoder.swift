import CAOMBridge
import CoreVideo
import Darwin
import Dispatch
import Foundation

public struct AV1EncoderAcceptedSettings: Codable, Equatable, Sendable {
    public let implementation: String
    public let bitrate: Int
    public let fps: Int
    public let cpuUsed: Int
    public let threads: Int
    public let tileColumns: Int
    public let tileRows: Int
    public let lagInFrames: Int
    public let keyframeInterval: Int?
    public let temporalCompression: Bool
    public let screenDetectionMode: AV1ScreenDetectionMode
    public let scalabilityMode: AV1ScalabilityMode

    public init(
        implementation: String,
        bitrate: Int,
        fps: Int,
        cpuUsed: Int,
        threads: Int,
        tileColumns: Int,
        tileRows: Int,
        lagInFrames: Int,
        keyframeInterval: Int?,
        temporalCompression: Bool,
        screenDetectionMode: AV1ScreenDetectionMode = .standard,
        scalabilityMode: AV1ScalabilityMode = .l1t1
    ) {
        self.implementation = implementation
        self.bitrate = bitrate
        self.fps = fps
        self.cpuUsed = cpuUsed
        self.threads = threads
        self.tileColumns = tileColumns
        self.tileRows = tileRows
        self.lagInFrames = lagInFrames
        self.keyframeInterval = keyframeInterval
        self.temporalCompression = temporalCompression
        self.screenDetectionMode = screenDetectionMode
        self.scalabilityMode = scalabilityMode
    }

    private enum CodingKeys: String, CodingKey {
        case implementation
        case bitrate
        case fps
        case cpuUsed
        case threads
        case tileColumns
        case tileRows
        case lagInFrames
        case keyframeInterval
        case temporalCompression
        case screenDetectionMode
        case scalabilityMode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(implementation, forKey: .implementation)
        try container.encode(bitrate, forKey: .bitrate)
        try container.encode(fps, forKey: .fps)
        try container.encode(cpuUsed, forKey: .cpuUsed)
        try container.encode(threads, forKey: .threads)
        try container.encode(tileColumns, forKey: .tileColumns)
        try container.encode(tileRows, forKey: .tileRows)
        try container.encode(lagInFrames, forKey: .lagInFrames)
        if let keyframeInterval {
            try container.encode(keyframeInterval, forKey: .keyframeInterval)
        } else {
            try container.encodeNil(forKey: .keyframeInterval)
        }
        try container.encode(temporalCompression, forKey: .temporalCompression)
        try container.encode(screenDetectionMode, forKey: .screenDetectionMode)
        try container.encode(scalabilityMode, forKey: .scalabilityMode)
    }
}

/// The colour description the AV1 sequence header carries, as ITU-T H.273 CICP code points.
///
/// **UNTAGGED IS A BUG, NOT A DEFAULT.** libaom leaves all three fields at 2 = "unspecified"
/// unless told otherwise, and a decoder handed "unspecified" guesses. VideoToolbox's guess is
/// keyed on RESOLUTION, so an untagged stream decodes with the wrong matrix on a small frame and
/// the right one on a large frame — colour that SHIFTS as the streamed resolution changes, and
/// that looks perfect on any large window.
///
/// A `nil` field leaves libaom's own default alone rather than writing 0: CICP 0 is "reserved"
/// for primaries and transfer, and "identity" (i.e. RGB, not YUV) for the matrix — never "unset".
public struct AV1ColorConfiguration: Codable, Equatable, Sendable {
    public let colorPrimaries: Int?
    public let transferCharacteristics: Int?
    public let matrixCoefficients: Int?
    /// `false` = studio/limited range (Y 16..235), `true` = full range. `nil` leaves libaom's
    /// default, which is studio.
    public let fullRange: Bool?

    public init(
        colorPrimaries: Int?,
        transferCharacteristics: Int?,
        matrixCoefficients: Int?,
        fullRange: Bool?
    ) {
        self.colorPrimaries = colorPrimaries
        self.transferCharacteristics = transferCharacteristics
        self.matrixCoefficients = matrixCoefficients
        self.fullRange = fullRange
    }

    /// CICP 1/1/1, studio range — what both of this engine's frame sources actually produce.
    /// ScreenCaptureKit hands back BT.709 video-range NV12, and rdev's `ColorConvert` converts
    /// BGRA with `kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2` at video range.
    public static let bt709 = AV1ColorConfiguration(
        colorPrimaries: 1,
        transferCharacteristics: 1,
        matrixCoefficients: 1,
        fullRange: false
    )

    /// Every field left to libaom. Present so the plumbing has a way to say "write nothing" —
    /// which is what this encoder did before the colour description was threaded through, and is
    /// therefore what a test asserting the bug's signature has to be able to ask for.
    public static let unspecified = AV1ColorConfiguration(
        colorPrimaries: nil,
        transferCharacteristics: nil,
        matrixCoefficients: nil,
        fullRange: nil
    )
}

public struct AV1EncodeObservation: Codable, Equatable, Sendable {
    public let frameID: UInt64
    public let isRepeated: Bool
    public let forceKeyframe: Bool
    public let surfaceCopyNanoseconds: UInt64
    public let codecNanoseconds: UInt64
    public let totalNanoseconds: UInt64
    public let highMotionScreenRTC: Bool

    public init(
        frameID: UInt64,
        isRepeated: Bool,
        forceKeyframe: Bool,
        surfaceCopyNanoseconds: UInt64,
        codecNanoseconds: UInt64,
        totalNanoseconds: UInt64,
        highMotionScreenRTC: Bool
    ) {
        self.frameID = frameID
        self.isRepeated = isRepeated
        self.forceKeyframe = forceKeyframe
        self.surfaceCopyNanoseconds = surfaceCopyNanoseconds
        self.codecNanoseconds = codecNanoseconds
        self.totalNanoseconds = totalNanoseconds
        self.highMotionScreenRTC = highMotionScreenRTC
    }
}

public enum AV1EncoderError: Error, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case invalidBitrate(Int)
    case temporalCompressionRequired
    case unexpectedPixelLayout
    case missingCachedFrame
    case invalidActiveMap(expectedCells: Int, actualCells: Int)
    case invalidActiveMapValue(index: Int, value: UInt8)
    case bridge(status: Int32, message: String)
}

public final class AV1Encoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (Result<EncodedAccessUnit, Error>) -> Void
    public typealias ObservationHandler = @Sendable (AV1EncodeObservation) -> Void

    public let acceptedSettings: AV1EncoderAcceptedSettings
    public let appliedTuningProfile: LibaomTuningProfile
    /// The colour description this encoder ASKED libaom for and libaom ACCEPTED — accepted
    /// transitively, since `llv_aom_encoder_set_color_config` status-checks every control and
    /// `init` throws when one is refused. Deliberately not folded into `acceptedSettings`, whose
    /// `Codable` shape is a recorded report schema.
    ///
    /// libaom exposes no GET for these, so this is a record of the request, not a readback. The
    /// only true readback is the encoded sequence header itself, which is what the colour test
    /// parses.
    public let appliedColorConfiguration: AV1ColorConfiguration

    private let outputHandler: OutputHandler
    private let observationHandler: ObservationHandler
    private let width: Int
    private let height: Int
    private let lock = NSLock()
    private var encoder: OpaquePointer?
    private var cachedLuma: Data
    private var cachedChroma: Data
    private var hasCachedFrame = false
    private var liveBitrate: Int

    public var currentBitrate: Int {
        lock.withLock { liveBitrate }
    }

    public convenience init(
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        temporalCompression: Bool = true,
        tuningProfile: LibaomTuningProfile = .currentControl,
        outputHandler: @escaping OutputHandler
    ) throws {
        try self.init(
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            temporalCompression: temporalCompression,
            scalabilityMode: .l1t1,
            tuningProfile: tuningProfile,
            outputHandler: outputHandler
        )
    }

    public convenience init(
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        temporalCompression: Bool = true,
        scalabilityMode: AV1ScalabilityMode,
        tuningProfile: LibaomTuningProfile = .currentControl,
        outputHandler: @escaping OutputHandler
    ) throws {
        try self.init(
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            temporalCompression: temporalCompression,
            scalabilityMode: scalabilityMode,
            tuningProfile: tuningProfile,
            observationHandler: { _ in },
            outputHandler: outputHandler
        )
    }

    public convenience init(
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        temporalCompression: Bool = true,
        tuningProfile: LibaomTuningProfile = .currentControl,
        observationHandler: @escaping ObservationHandler,
        outputHandler: @escaping OutputHandler
    ) throws {
        try self.init(
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            temporalCompression: temporalCompression,
            scalabilityMode: .l1t1,
            tuningProfile: tuningProfile,
            observationHandler: observationHandler,
            outputHandler: outputHandler
        )
    }

    public init(
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        temporalCompression: Bool = true,
        scalabilityMode: AV1ScalabilityMode,
        tuningProfile: LibaomTuningProfile = .currentControl,
        colorConfiguration: AV1ColorConfiguration = .bt709,
        observationHandler: @escaping ObservationHandler,
        outputHandler: @escaping OutputHandler
    ) throws {
        guard RealtimeVideoDimensions(width: width, height: height) != nil else {
            throw AV1EncoderError.invalidDimensions(width: width, height: height)
        }
        guard temporalCompression else {
            throw AV1EncoderError.temporalCompressionRequired
        }
        guard let bridgeBitrate = UInt32(exactly: bitrate), bridgeBitrate >= 1_000 else {
            throw AV1EncoderError.invalidBitrate(bitrate)
        }
        let validatedProfile = try tuningProfile.validated()
        guard let screenDetectionMode = AV1ScreenDetectionMode(
            libaomValue: validatedProfile.screenDetectionMode
        ) else {
            preconditionFailure(
                "validated libaom profile has an unsupported screen-detection mode"
            )
        }
        self.outputHandler = outputHandler
        self.observationHandler = observationHandler
        self.width = width
        self.height = height
        cachedLuma = Data(count: width * height)
        cachedChroma = Data(count: width * height / 2)
        liveBitrate = bitrate
        appliedTuningProfile = validatedProfile
        appliedColorConfiguration = colorConfiguration

        acceptedSettings = AV1EncoderAcceptedSettings(
            implementation: "libaom-v3.14.1",
            bitrate: bitrate,
            fps: fps,
            cpuUsed: validatedProfile.cpuUsed,
            threads: validatedProfile.threads,
            tileColumns: validatedProfile.tileColumnsLog2,
            tileRows: validatedProfile.tileRowsLog2,
            lagInFrames: 0,
            keyframeInterval: nil,
            temporalCompression: true,
            screenDetectionMode: screenDetectionMode,
            scalabilityMode: scalabilityMode
        )
        var configuration = llv_aom_encoder_configuration(
            width: UInt32(width),
            height: UInt32(height),
            fps: UInt32(fps),
            bitrate: bridgeBitrate,
            threads: UInt32(acceptedSettings.threads),
            cpu_used: UInt32(acceptedSettings.cpuUsed),
            tile_columns: UInt32(acceptedSettings.tileColumns),
            tile_rows: UInt32(acceptedSettings.tileRows),
            rc_buffer_milliseconds: UInt32(validatedProfile.rcBufferMilliseconds),
            rc_initial_buffer_milliseconds: UInt32(validatedProfile.rcInitialBufferMilliseconds),
            rc_optimal_buffer_milliseconds: UInt32(validatedProfile.rcOptimalBufferMilliseconds),
            auto_tiles: Self.bridgeOptional(validatedProfile.autoTiles),
            screen_detection_mode: Self.bridgeOptional(validatedProfile.screenDetectionMode),
            aq_mode: Self.bridgeOptional(validatedProfile.aqMode),
            sharpness: Self.bridgeOptional(validatedProfile.sharpness),
            adaptive_sharpness: Self.bridgeOptional(validatedProfile.adaptiveSharpness),
            cdef_mode: Self.bridgeOptional(validatedProfile.cdefMode),
            loopfilter_mode: Self.bridgeOptional(validatedProfile.loopfilterMode),
            scalability_mode: Self.bridgeScalabilityMode(scalabilityMode)
        )
        var created: OpaquePointer?
        var error = [CChar](repeating: 0, count: 1_024)
        let status = llv_aom_encoder_create(
            &configuration, &created, &error, error.count
        )
        guard status == LLV_AOM_RUNTIME_OK, let created else {
            throw AV1EncoderError.bridge(
                status: status,
                message: Self.errorString(error)
            )
        }
        // BEFORE THE FIRST FRAME, which is the whole requirement: the sequence header is written
        // with the first keyframe, so a colour description applied later cannot retag what has
        // already been emitted. Destroying `created` by hand rather than leaving it to `deinit`
        // keeps the failure path independent of whether a throwing class initialiser that has
        // finished its stored properties gets one.
        var colorError = [CChar](repeating: 0, count: 1_024)
        let colorStatus = llv_aom_encoder_set_color_config(
            created,
            Self.bridgeOptional(colorConfiguration.colorPrimaries),
            Self.bridgeOptional(colorConfiguration.transferCharacteristics),
            Self.bridgeOptional(colorConfiguration.matrixCoefficients),
            Self.bridgeOptional(colorConfiguration.fullRange),
            &colorError,
            colorError.count
        )
        guard colorStatus == LLV_AOM_RUNTIME_OK else {
            llv_aom_encoder_destroy(created)
            throw AV1EncoderError.bridge(
                status: colorStatus,
                message: Self.errorString(colorError)
            )
        }
        encoder = created
    }

    deinit {
        if let encoder {
            llv_aom_encoder_destroy(encoder)
        }
    }

    public func encode(
        pixelBuffer: CVPixelBuffer,
        frameID: UInt64,
        inputSequence: UInt64,
        forceKeyframe: Bool,
        referenceControl: AV1ReferenceControl? = nil
    ) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw AV1EncoderError.unexpectedPixelLayout
        }
        let startedNanoseconds = DispatchTime.now().uptimeNanoseconds
        var surfaceCopyNanoseconds: UInt64 = 0
        var codecNanoseconds: UInt64 = 0
        var highMotionScreenRTC = false
        let accessUnit: EncodedAccessUnit = try lock.withLock {
            let copyStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
            try cache(pixelBuffer: pixelBuffer)
            surfaceCopyNanoseconds = DispatchTime.now().uptimeNanoseconds
                - copyStartedNanoseconds
            let codecStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
            let encoded = try encodeCachedFrame(
                frameID: frameID,
                inputSequence: inputSequence,
                forceKeyframe: forceKeyframe,
                startedNanoseconds: startedNanoseconds,
                referenceControl: referenceControl
            )
            codecNanoseconds = DispatchTime.now().uptimeNanoseconds
                - codecStartedNanoseconds
            highMotionScreenRTC = encoded.highMotionScreenRTC
            return encoded.accessUnit
        }
        observationHandler(AV1EncodeObservation(
            frameID: frameID,
            isRepeated: false,
            forceKeyframe: forceKeyframe,
            surfaceCopyNanoseconds: surfaceCopyNanoseconds,
            codecNanoseconds: codecNanoseconds,
            totalNanoseconds: DispatchTime.now().uptimeNanoseconds - startedNanoseconds,
            highMotionScreenRTC: highMotionScreenRTC
        ))
        outputHandler(.success(accessUnit))
    }

    public func repeatLastFrame(
        frameID: UInt64,
        inputSequence: UInt64,
        forceKeyframe: Bool,
        referenceControl: AV1ReferenceControl? = nil
    ) throws {
        let startedNanoseconds = DispatchTime.now().uptimeNanoseconds
        var codecNanoseconds: UInt64 = 0
        var highMotionScreenRTC = false
        let accessUnit: EncodedAccessUnit = try lock.withLock {
            guard hasCachedFrame else {
                throw AV1EncoderError.missingCachedFrame
            }
            let codecStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
            let encoded = try encodeCachedFrame(
                frameID: frameID,
                inputSequence: inputSequence,
                forceKeyframe: forceKeyframe,
                startedNanoseconds: startedNanoseconds,
                referenceControl: referenceControl
            )
            codecNanoseconds = DispatchTime.now().uptimeNanoseconds
                - codecStartedNanoseconds
            highMotionScreenRTC = encoded.highMotionScreenRTC
            return encoded.accessUnit
        }
        observationHandler(AV1EncodeObservation(
            frameID: frameID,
            isRepeated: true,
            forceKeyframe: forceKeyframe,
            surfaceCopyNanoseconds: 0,
            codecNanoseconds: codecNanoseconds,
            totalNanoseconds: DispatchTime.now().uptimeNanoseconds - startedNanoseconds,
            highMotionScreenRTC: highMotionScreenRTC
        ))
        outputHandler(.success(accessUnit))
    }

    public func completeFrames() throws {
        try lock.withLock {
            guard let encoder else { return }
            var error = [CChar](repeating: 0, count: 1_024)
            let status = llv_aom_encoder_complete(
                encoder, &error, error.count
            )
            guard status == LLV_AOM_RUNTIME_OK else {
                throw AV1EncoderError.bridge(
                    status: status,
                    message: Self.errorString(error)
                )
            }
        }
    }

    public func setBitrate(_ bitsPerSecond: Int) throws {
        guard let bridgeBitrate = UInt32(exactly: bitsPerSecond), bridgeBitrate >= 1_000 else {
            throw AV1EncoderError.invalidBitrate(bitsPerSecond)
        }
        try lock.withLock {
            guard let encoder else {
                throw AV1EncoderError.unexpectedPixelLayout
            }
            var error = [CChar](repeating: 0, count: 1_024)
            let status = llv_aom_encoder_set_bitrate(
                encoder, bridgeBitrate, &error, error.count
            )
            guard status == LLV_AOM_RUNTIME_OK else {
                throw AV1EncoderError.bridge(
                    status: status,
                    message: Self.errorString(error)
                )
            }
            liveBitrate = bitsPerSecond
        }
    }

    public func setActiveMap(_ cells: [UInt8]?) throws {
        let rows = (height + 15) / 16
        let columns = (width + 15) / 16
        let expectedCells = rows * columns
        if let cells {
            guard cells.count == expectedCells else {
                throw AV1EncoderError.invalidActiveMap(
                    expectedCells: expectedCells,
                    actualCells: cells.count
                )
            }
            if let invalid = cells.enumerated().first(where: { $0.element > 1 }) {
                throw AV1EncoderError.invalidActiveMapValue(
                    index: invalid.offset,
                    value: invalid.element
                )
            }
        }
        try lock.withLock {
            guard let encoder else { throw AV1EncoderError.unexpectedPixelLayout }
            var error = [CChar](repeating: 0, count: 1_024)
            let status: Int32
            if let cells {
                status = cells.withUnsafeBufferPointer { bytes in
                    llv_aom_encoder_set_active_map(
                        encoder,
                        bytes.baseAddress,
                        UInt32(rows),
                        UInt32(columns),
                        &error,
                        error.count
                    )
                }
            } else {
                status = llv_aom_encoder_set_active_map(
                    encoder,
                    nil,
                    UInt32(rows),
                    UInt32(columns),
                    &error,
                    error.count
                )
            }
            guard status == LLV_AOM_RUNTIME_OK else {
                throw AV1EncoderError.bridge(
                    status: status,
                    message: Self.errorString(error)
                )
            }
        }
    }

    private func cache(pixelBuffer: CVPixelBuffer) throws {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw AV1EncoderError.unexpectedPixelLayout
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw AV1EncoderError.unexpectedPixelLayout
        }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        cachedLuma.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                memcpy(
                    destination.baseAddress!.advanced(by: row * width),
                    luma.advanced(by: row * lumaStride),
                    width
                )
            }
        }
        cachedChroma.withUnsafeMutableBytes { destination in
            for row in 0..<(height / 2) {
                memcpy(
                    destination.baseAddress!.advanced(by: row * width),
                    chroma.advanced(by: row * chromaStride),
                    width
                )
            }
        }
        hasCachedFrame = true
    }

    private func encodeCachedFrame(
        frameID: UInt64,
        inputSequence: UInt64,
        forceKeyframe: Bool,
        startedNanoseconds: UInt64,
        referenceControl: AV1ReferenceControl?
    ) throws -> (accessUnit: EncodedAccessUnit, highMotionScreenRTC: Bool) {
        guard let encoder else { throw AV1EncoderError.unexpectedPixelLayout }
        var packet = llv_aom_encoded_packet()
        var error = [CChar](repeating: 0, count: 1_024)
        if let referenceControl {
            var plan = referenceControl.bridge
            let status = llv_aom_encoder_set_reference_plan(encoder, &plan, &error, error.count)
            guard status == LLV_AOM_RUNTIME_OK else {
                throw AV1EncoderError.bridge(status: status, message: Self.errorString(error))
            }
        }
        let status = cachedLuma.withUnsafeBytes { luma in
            cachedChroma.withUnsafeBytes { chroma in
                llv_aom_encoder_encode_nv12(
                    encoder,
                    luma.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    width,
                    chroma.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    width,
                    frameID,
                    forceKeyframe ? 1 : 0,
                    &packet,
                    &error,
                    error.count
                )
            }
        }
        guard status == LLV_AOM_RUNTIME_OK, let bytes = packet.data else {
            throw AV1EncoderError.bridge(
                status: status,
                message: Self.errorString(error)
            )
        }
        let completedNanoseconds = DispatchTime.now().uptimeNanoseconds
        let dependency = try AV1FrameDependency(
            scalabilityMode: acceptedSettings.scalabilityMode,
            temporalID: packet.temporal_id,
            templateID: packet.template_id
        )
        return (EncodedAccessUnit(
            frameID: frameID,
            inputSequence: inputSequence,
            isKeyframe: packet.is_keyframe != 0,
            encodeNanoseconds: completedNanoseconds - startedNanoseconds,
            data: Data(bytes: bytes, count: packet.size),
            av1Dependency: dependency
        ), packet.high_motion_screen_rtc == 1)
    }

    private static func bridgeScalabilityMode(_ mode: AV1ScalabilityMode) -> Int32 {
        switch mode {
        case .l1t1: Int32(LLV_AOM_SCALABILITY_L1T1)
        case .l1t2: Int32(LLV_AOM_SCALABILITY_L1T2)
        case .l1t3: Int32(LLV_AOM_SCALABILITY_L1T3)
        }
    }

    private static func bridgeOptional(_ value: Int?) -> Int32 {
        value.map(Int32.init) ?? Int32(LLV_AOM_USE_DEFAULT)
    }

    private static func bridgeOptional(_ value: Bool?) -> Int32 {
        value.map { $0 ? 1 : 0 } ?? Int32(LLV_AOM_USE_DEFAULT)
    }

    private static func errorString(_ bytes: [CChar]) -> String {
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return "" }
            return String(cString: baseAddress)
        }
    }
}
