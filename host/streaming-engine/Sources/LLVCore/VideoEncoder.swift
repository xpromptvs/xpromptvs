import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import VideoToolbox

public enum VideoCodec: String, Codable, Equatable, Sendable {
    case av1
    case h264
    case hevc
    case rawLuma = "raw-luma"

    fileprivate var mediaType: CMVideoCodecType {
        switch self {
        case .av1: preconditionFailure("AV1 uses libaom instead of VideoToolbox encoding")
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .rawLuma: preconditionFailure("raw luma does not use VideoToolbox")
        }
    }
}

public enum AV1ScalabilityMode: String, Codable, CaseIterable, Sendable {
    case l1t1 = "L1T1"
    case l1t2 = "L1T2"
    case l1t3 = "L1T3"

    public var temporalLayerCount: Int {
        switch self {
        case .l1t1: 1
        case .l1t2: 2
        case .l1t3: 3
        }
    }

    public var cumulativeBitratePermille: [Int] {
        switch self {
        case .l1t1: [1_000]
        case .l1t2: [645, 1_000]
        case .l1t3: [540, 703, 1_000]
        }
    }
}

public enum AV1DecodeTargetIndication: String, Codable, Equatable, Sendable {
    case notPresent = "-"
    case discardable = "D"
    case `switch` = "S"
    case required = "R"
}

public enum AV1FrameDependencyError: Error, Equatable, Sendable {
    case invalidTemplateID(mode: AV1ScalabilityMode, templateID: UInt8)
    case invalidTemporalID(
        mode: AV1ScalabilityMode,
        templateID: UInt8,
        expected: UInt8,
        actual: UInt8
    )
}

public struct AV1FrameDependency: Codable, Equatable, Sendable {
    public let scalabilityMode: AV1ScalabilityMode
    public let temporalID: UInt8
    public let templateID: UInt8

    public init(
        scalabilityMode: AV1ScalabilityMode,
        temporalID: UInt8,
        templateID: UInt8
    ) throws {
        guard let template = Self.template(mode: scalabilityMode, templateID: templateID) else {
            throw AV1FrameDependencyError.invalidTemplateID(
                mode: scalabilityMode,
                templateID: templateID
            )
        }
        guard temporalID == template.temporalID else {
            throw AV1FrameDependencyError.invalidTemporalID(
                mode: scalabilityMode,
                templateID: templateID,
                expected: template.temporalID,
                actual: temporalID
            )
        }
        self.scalabilityMode = scalabilityMode
        self.temporalID = temporalID
        self.templateID = templateID
    }

    public var decodeTargetIndications: [AV1DecodeTargetIndication] {
        Self.validatedTemplate(mode: scalabilityMode, templateID: templateID).decodeTargetIndications
    }

    public var frameDiffs: [UInt8] {
        Self.validatedTemplate(mode: scalabilityMode, templateID: templateID).frameDiffs
    }

    public var chainDiff: UInt8 {
        Self.validatedTemplate(mode: scalabilityMode, templateID: templateID).chainDiff
    }

    public var isKeyframeTemplate: Bool { templateID == 0 }

    private enum CodingKeys: String, CodingKey {
        case scalabilityMode
        case temporalID
        case templateID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scalabilityMode: container.decode(AV1ScalabilityMode.self, forKey: .scalabilityMode),
            temporalID: container.decode(UInt8.self, forKey: .temporalID),
            templateID: container.decode(UInt8.self, forKey: .templateID)
        )
    }

    private struct Template {
        let temporalID: UInt8
        let decodeTargetIndications: [AV1DecodeTargetIndication]
        let frameDiffs: [UInt8]
        let chainDiff: UInt8
    }

    private static func validatedTemplate(
        mode: AV1ScalabilityMode,
        templateID: UInt8
    ) -> Template {
        guard let template = template(mode: mode, templateID: templateID) else {
            preconditionFailure("validated AV1 dependency contains an invalid template")
        }
        return template
    }

    private static func template(
        mode: AV1ScalabilityMode,
        templateID: UInt8
    ) -> Template? {
        switch (mode, templateID) {
        case (.l1t1, 0): Template(
            temporalID: 0,
            decodeTargetIndications: [.switch],
            frameDiffs: [],
            chainDiff: 0
        )
        case (.l1t1, 1): Template(
            temporalID: 0,
            decodeTargetIndications: [.switch],
            frameDiffs: [1],
            chainDiff: 1
        )
        case (.l1t2, 0): Template(
            temporalID: 0,
            decodeTargetIndications: [.switch, .switch],
            frameDiffs: [],
            chainDiff: 0
        )
        case (.l1t2, 1): Template(
            temporalID: 0,
            decodeTargetIndications: [.switch, .switch],
            frameDiffs: [2],
            chainDiff: 2
        )
        case (.l1t2, 2): Template(
            temporalID: 1,
            decodeTargetIndications: [.notPresent, .discardable],
            frameDiffs: [1],
            chainDiff: 1
        )
        case (.l1t3, 0): Template(
            temporalID: 0,
            decodeTargetIndications: [.switch, .switch, .switch],
            frameDiffs: [],
            chainDiff: 0
        )
        case (.l1t3, 1): Template(
            temporalID: 0,
            decodeTargetIndications: [.switch, .switch, .switch],
            frameDiffs: [4],
            chainDiff: 4
        )
        case (.l1t3, 2): Template(
            temporalID: 1,
            decodeTargetIndications: [.notPresent, .discardable, .switch],
            frameDiffs: [2],
            chainDiff: 2
        )
        case (.l1t3, 3): Template(
            temporalID: 2,
            decodeTargetIndications: [.notPresent, .notPresent, .discardable],
            frameDiffs: [1],
            chainDiff: 1
        )
        case (.l1t3, 4): Template(
            temporalID: 2,
            decodeTargetIndications: [.notPresent, .notPresent, .discardable],
            frameDiffs: [1],
            chainDiff: 3
        )
        default: nil
        }
    }
}

public struct EncoderAcceptedSettings: Codable, Equatable, Sendable {
    public let implementation: String
    public let hardwareAccelerated: Bool
    public let lowLatencyRateControl: Bool
    public let realTime: Bool
    public let frameReordering: Bool
    public let temporalCompression: Bool
    public let maxFrameDelayCount: Int?
    public let prioritizeEncodingSpeedOverQuality: Bool?
    public let suggestedLookAheadFrameCount: Int?
    public let cpuUsed: Int?
    public let threads: Int?
    public let tileColumns: Int?
    public let tileRows: Int?
    public let lagInFrames: Int?
    public let keyframeInterval: Int?
    /// The DURATION limit, in seconds, alongside `keyframeInterval`'s frame limit. VideoToolbox
    /// enforces whichever comes first, so an infinite frame interval alone does not give an
    /// infinite GOP. 0 means no duration limit. Nil on a backend that does not set it.
    public let maxKeyFrameIntervalDuration: Double?
    public let screenDetectionMode: AV1ScreenDetectionMode?
    public let scalabilityMode: AV1ScalabilityMode?
    /// The colour tags actually applied to the session. Nil on a backend that does not set them
    /// (libaom carries colour as CICP in the sequence header instead).
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?

    public init(
        hardwareAccelerated: Bool,
        lowLatencyRateControl: Bool,
        realTime: Bool,
        frameReordering: Bool,
        temporalCompression: Bool,
        maxFrameDelayCount: Int?,
        prioritizeEncodingSpeedOverQuality: Bool?,
        suggestedLookAheadFrameCount: Int?,
        implementation: String = "VideoToolbox",
        cpuUsed: Int? = nil,
        threads: Int? = nil,
        tileColumns: Int? = nil,
        tileRows: Int? = nil,
        lagInFrames: Int? = nil,
        keyframeInterval: Int? = nil,
        maxKeyFrameIntervalDuration: Double? = nil,
        screenDetectionMode: AV1ScreenDetectionMode? = nil,
        scalabilityMode: AV1ScalabilityMode? = nil,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        yCbCrMatrix: String? = nil
    ) {
        self.implementation = implementation
        self.hardwareAccelerated = hardwareAccelerated
        self.lowLatencyRateControl = lowLatencyRateControl
        self.realTime = realTime
        self.frameReordering = frameReordering
        self.temporalCompression = temporalCompression
        self.maxFrameDelayCount = maxFrameDelayCount
        self.prioritizeEncodingSpeedOverQuality = prioritizeEncodingSpeedOverQuality
        self.suggestedLookAheadFrameCount = suggestedLookAheadFrameCount
        self.cpuUsed = cpuUsed
        self.threads = threads
        self.tileColumns = tileColumns
        self.tileRows = tileRows
        self.lagInFrames = lagInFrames
        self.keyframeInterval = keyframeInterval
        self.maxKeyFrameIntervalDuration = maxKeyFrameIntervalDuration
        self.screenDetectionMode = screenDetectionMode
        self.scalabilityMode = scalabilityMode
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
    }

    private enum CodingKeys: String, CodingKey {
        case implementation
        case hardwareAccelerated
        case lowLatencyRateControl
        case realTime
        case frameReordering
        case temporalCompression
        case maxFrameDelayCount
        case prioritizeEncodingSpeedOverQuality
        case suggestedLookAheadFrameCount
        case cpuUsed
        case threads
        case tileColumns
        case tileRows
        case lagInFrames
        case keyframeInterval
        case maxKeyFrameIntervalDuration
        case screenDetectionMode
        case scalabilityMode
        case colorPrimaries
        case transferFunction
        case yCbCrMatrix
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(implementation, forKey: .implementation)
        try container.encode(hardwareAccelerated, forKey: .hardwareAccelerated)
        try container.encode(lowLatencyRateControl, forKey: .lowLatencyRateControl)
        try container.encode(realTime, forKey: .realTime)
        try container.encode(frameReordering, forKey: .frameReordering)
        try container.encode(temporalCompression, forKey: .temporalCompression)
        try container.encodeIfPresent(maxFrameDelayCount, forKey: .maxFrameDelayCount)
        try container.encodeIfPresent(
            prioritizeEncodingSpeedOverQuality,
            forKey: .prioritizeEncodingSpeedOverQuality
        )
        try container.encodeIfPresent(
            suggestedLookAheadFrameCount,
            forKey: .suggestedLookAheadFrameCount
        )
        try container.encodeIfPresent(cpuUsed, forKey: .cpuUsed)
        try container.encodeIfPresent(threads, forKey: .threads)
        try container.encodeIfPresent(tileColumns, forKey: .tileColumns)
        try container.encodeIfPresent(tileRows, forKey: .tileRows)
        try container.encodeIfPresent(lagInFrames, forKey: .lagInFrames)
        if let keyframeInterval {
            try container.encode(keyframeInterval, forKey: .keyframeInterval)
        } else {
            try container.encodeNil(forKey: .keyframeInterval)
        }
        try container.encodeIfPresent(
            maxKeyFrameIntervalDuration,
            forKey: .maxKeyFrameIntervalDuration
        )
        try container.encodeIfPresent(screenDetectionMode, forKey: .screenDetectionMode)
        try container.encodeIfPresent(scalabilityMode, forKey: .scalabilityMode)
        try container.encodeIfPresent(colorPrimaries, forKey: .colorPrimaries)
        try container.encodeIfPresent(transferFunction, forKey: .transferFunction)
        try container.encodeIfPresent(yCbCrMatrix, forKey: .yCbCrMatrix)
    }
}

public struct EncodedAccessUnit: Equatable, Sendable {
    public let frameID: UInt64
    public let inputSequence: UInt64
    public let isKeyframe: Bool
    public let encodeNanoseconds: UInt64
    public let data: Data
    public let av1Dependency: AV1FrameDependency?

    public init(
        frameID: UInt64,
        inputSequence: UInt64,
        isKeyframe: Bool,
        encodeNanoseconds: UInt64,
        data: Data
    ) {
        self.init(
            frameID: frameID,
            inputSequence: inputSequence,
            isKeyframe: isKeyframe,
            encodeNanoseconds: encodeNanoseconds,
            data: data,
            av1Dependency: nil
        )
    }

    public init(
        frameID: UInt64,
        inputSequence: UInt64,
        isKeyframe: Bool,
        encodeNanoseconds: UInt64,
        data: Data,
        av1Dependency: AV1FrameDependency?
    ) {
        self.frameID = frameID
        self.inputSequence = inputSequence
        self.isKeyframe = isKeyframe
        self.encodeNanoseconds = encodeNanoseconds
        self.data = data
        self.av1Dependency = av1Dependency
    }
}

public enum VideoEncoderError: Error, Equatable, Sendable {
    case videoToolbox(operation: String, status: OSStatus)
    case missingSampleBuffer
    case missingBlockBuffer
    case missingFormatDescription
    case unsupportedParameterSets
    case unsupportedCodec
}

public final class VideoEncoder: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (Result<EncodedAccessUnit, Error>) -> Void

    public private(set) var acceptedSettings = EncoderAcceptedSettings(
        hardwareAccelerated: false,
        lowLatencyRateControl: false,
        realTime: false,
        frameReordering: true,
        temporalCompression: true,
        maxFrameDelayCount: nil,
        prioritizeEncodingSpeedOverQuality: nil,
        suggestedLookAheadFrameCount: nil
    )

    private let codec: VideoCodec
    private let fps: Int32
    private let outputHandler: OutputHandler
    private var session: VTCompressionSession!

    public init(
        codec: VideoCodec,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        temporalCompression: Bool = true,
        outputHandler: @escaping OutputHandler
    ) throws {
        guard codec == .h264 || codec == .hevc else {
            throw VideoEncoderError.unsupportedCodec
        }
        self.codec = codec
        self.fps = Int32(fps)
        self.outputHandler = outputHandler

        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var createdSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.mediaType,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &createdSession
        )
        guard status == noErr, let createdSession else {
            throw VideoEncoderError.videoToolbox(operation: "VTCompressionSessionCreate", status: status)
        }
        session = createdSession

        do {
            try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            try set(
                kVTCompressionPropertyKey_AllowTemporalCompression,
                value: temporalCompression ? kCFBooleanTrue : kCFBooleanFalse
            )
            let acceptedMaxFrameDelay = try setOptional(
                kVTCompressionPropertyKey_MaxFrameDelayCount,
                value: NSNumber(value: 0)
            )
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
            let acceptedSpeedPriority = try setOptional(
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                value: kCFBooleanTrue
            )
            let acceptedLookAhead = try setOptional(
                kVTCompressionPropertyKey_SuggestedLookAheadFrameCount,
                value: NSNumber(value: 0)
            )
            // INFINITE GOP, AND BOTH PROPERTIES ARE REQUIRED.
            //
            // This was `temporalCompression ? fps : 1` — one IDR per second at 60fps. Measured on a
            // real iPad session at 1.9 Mbit/s: 26-54% of the wire spent on keyframes, the rate
            // controller starved, and frames dropped to pay for them. rdev forces a keyframe on
            // connect and on every PLI, so a timer-driven one buys nothing and costs the picture.
            // rdev's own VTEncoder always set both of these; this encoder set one and defaulted the
            // other.
            //
            // THE DURATION IS NOT REDUNDANT. Apple's default is unlimited, so setting it is
            // belt-and-braces today — but VideoToolbox enforces whichever limit comes first, and a
            // duration-based IDR would reproduce the exact symptom while the frame interval read as
            // infinite. That is a bad afternoon to leave available.
            //
            // THE TERNARY IS KEPT, AND THE DESIGN NOTE THAT SAID IT WAS REDUNDANT WAS WRONG.
            // Measured 2026-08-20: `AllowTemporalCompression = false` above does NOT by itself make
            // every frame intra on this platform — the `: 1` arm is what does it, and the frozen
            // test "intra-only HEVC emits only keyframes" (Tests/LLVCoreTests/VideoEncoderTests.swift)
            // fails without it. The claim that nothing in this repository passes
            // `temporalCompression: false` was wrong too; that test does.
            //
            // So only the TRUE arm changes: infinite GOP for the streaming path, all-intra
            // preserved byte-for-byte for the caller that asks for it.
            try set(
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(value: temporalCompression ? Int32.max : 1)
            )
            try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 0))
            try set(kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
            if codec == .h264 {
                try set(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            }
            // COLOUR MUST BE TAGGED, and this is a decoder-side trap rather than a nicety. Untagged,
            // the encoder still converts with BT.709 but writes "unspecified" into the VUI, so the
            // DECODER falls back to a RESOLUTION-KEYED heuristic. Measured on rdev's earlier
            // VideoToolbox path: worst-channel error 24/255 at 640x360 untagged against 2/255
            // tagged, and correct above ~720px wide — so it is invisible on a large window and
            // wrong on a small one. rdev varies the streamed size continuously (Auto resolution),
            // which turns that into colour SHIFTING mid-session.
            //
            // BT.709 is not a guess: it is what the caller's BGRA->NV12 conversion uses, what the
            // staging buffer is tagged with, and what the AV1 path writes as CICP 1/1/1. All four
            // have to agree.
            //
            // Status-checked through `set` like everything else: a REFUSED property encodes
            // perfectly and is indistinguishable from an applied one.
            try set(kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            try set(kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
            try set(kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)

            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepareStatus == noErr else {
                throw VideoEncoderError.videoToolbox(
                    operation: "VTCompressionSessionPrepareToEncodeFrames",
                    status: prepareStatus
                )
            }
            acceptedSettings = EncoderAcceptedSettings(
                hardwareAccelerated: true,
                lowLatencyRateControl: true,
                realTime: true,
                frameReordering: false,
                temporalCompression: temporalCompression,
                maxFrameDelayCount: acceptedMaxFrameDelay ? 0 : nil,
                prioritizeEncodingSpeedOverQuality: acceptedSpeedPriority ? true : nil,
                suggestedLookAheadFrameCount: acceptedLookAhead ? 0 : nil,
                keyframeInterval: copyNumberProperty(
                    kVTCompressionPropertyKey_MaxKeyFrameInterval
                )?.intValue,
                maxKeyFrameIntervalDuration: copyNumberProperty(
                    kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration
                )?.doubleValue,
                colorPrimaries: copyStringProperty(kVTCompressionPropertyKey_ColorPrimaries),
                transferFunction: copyStringProperty(kVTCompressionPropertyKey_TransferFunction),
                yCbCrMatrix: copyStringProperty(kVTCompressionPropertyKey_YCbCrMatrix)
            )
            guard acceptedSettings.hardwareAccelerated,
                  acceptedSettings.lowLatencyRateControl,
                  acceptedSettings.realTime,
                  !acceptedSettings.frameReordering else {
                throw VideoEncoderError.videoToolbox(operation: "low-delay-invariants", status: kVTPropertyNotSupportedErr)
            }
        } catch {
            VTCompressionSessionInvalidate(session)
            session = nil
            throw error
        }
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    public func encode(
        pixelBuffer: CVPixelBuffer,
        frameID: UInt64,
        inputSequence: UInt64,
        forceKeyframe: Bool
    ) throws {
        let context = FrameContext(
            frameID: frameID,
            inputSequence: inputSequence,
            submittedNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: Int64(frameID), timescale: fps),
            duration: CMTime(value: 1, timescale: fps),
            frameProperties: properties,
            sourceFrameRefcon: contextPointer,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            Unmanaged<FrameContext>.fromOpaque(contextPointer).release()
            throw VideoEncoderError.videoToolbox(operation: "VTCompressionSessionEncodeFrame", status: status)
        }
    }

    public func completeFrames() throws {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else {
            throw VideoEncoderError.videoToolbox(operation: "VTCompressionSessionCompleteFrames", status: status)
        }
    }

    /// READ THE PROPERTY BACK OFF THE SESSION. `set` already throws on a refusal, so this is not
    /// the primary guard — it is what stops `acceptedSettings` from being a restatement of the
    /// request. This codebase has a recorded instance of exactly that mistake: the libaom path's
    /// `acceptedSettings` is derived from the validated REQUEST, and a check built on believing it
    /// was a readback turned out to be unreachable. Colour is one of the few VideoToolbox
    /// properties that can genuinely be read back, so it is read back.
    private func copyStringProperty(_ key: CFString) -> String? {
        var value: CFTypeRef?
        guard VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value) == noErr else {
            return nil
        }
        return value as? String
    }

    /// Numeric sibling of `copyStringProperty`, and it exists for the same reason that one does: a
    /// property that is SET but never read back cannot be told apart from one VideoToolbox refused,
    /// and `acceptedSettings` is otherwise a restatement of the request. The keyframe interval is
    /// the case that motivated it — wrong for months while every state read healthy.
    private func copyNumberProperty(_ key: CFString) -> NSNumber? {
        var value: CFTypeRef?
        guard VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value) == noErr else {
            return nil
        }
        return value as? NSNumber
    }

    /// A live CBR retarget. VideoToolbox accepts AverageBitRate on a running session — this backend
    /// simply never implemented it, so every client bitrate change and every FlexFEC media/FEC
    /// split was silently refused on H.264/H.265.
    ///
    /// STATUS-CHECKED via `set`, which throws on refusal. A refused property encodes perfectly and
    /// is indistinguishable from an applied one; that is how the dead MaxFrameDelayCount survived.
    ///
    /// THREAD CONFINEMENT IS THE CALLER'S, and it is already correct: LLVEncoderAdapter sets
    /// `pendingBitrate` under `lock` and applies it under `encLock` from inside the encode path, so
    /// the session is only ever touched from the encode thread. Do not add locking here.
    public func setBitrate(_ bitsPerSecond: Int) throws {
        try set(kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitsPerSecond))
    }

    /// The bitrate the SESSION currently holds. Distinct from `acceptedSettings`, which is captured
    /// at init and cannot describe a later retarget — which is the whole question a retarget poses.
    public var appliedBitrate: Int? {
        copyNumberProperty(kVTCompressionPropertyKey_AverageBitRate)?.intValue
    }

    private func set(_ key: CFString, value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw VideoEncoderError.videoToolbox(operation: "VTSessionSetProperty(\(key))", status: status)
        }
    }

    private func setOptional(_ key: CFString, value: CFTypeRef) throws -> Bool {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status == kVTPropertyNotSupportedErr {
            return false
        }
        guard status == noErr else {
            throw VideoEncoderError.videoToolbox(operation: "VTSessionSetProperty(\(key))", status: status)
        }
        return true
    }

    private func handleCallback(
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?,
        context: FrameContext
    ) {
        guard status == noErr else {
            outputHandler(.failure(VideoEncoderError.videoToolbox(operation: "compressionCallback", status: status)))
            return
        }
        guard let sampleBuffer else {
            outputHandler(.failure(VideoEncoderError.missingSampleBuffer))
            return
        }
        do {
            let keyframe = Self.isKeyframe(sampleBuffer)
            let data = try Self.annexBData(sampleBuffer: sampleBuffer, codec: codec, keyframe: keyframe)
            outputHandler(.success(EncodedAccessUnit(
                frameID: context.frameID,
                inputSequence: context.inputSequence,
                isKeyframe: keyframe,
                encodeNanoseconds: DispatchTime.now().uptimeNanoseconds - context.submittedNanoseconds,
                data: data
            )))
        } catch {
            outputHandler(.failure(error))
        }
    }

    private static let compressionCallback: VTCompressionOutputCallback = {
        outputCallbackRefCon,
        sourceFrameRefCon,
        status,
        _,
        sampleBuffer in
        guard let outputCallbackRefCon, let sourceFrameRefCon else { return }
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
        let context = Unmanaged<FrameContext>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
        encoder.handleCallback(status: status, sampleBuffer: sampleBuffer, context: context)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]], let first = attachments.first else {
            return true
        }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func annexBData(
        sampleBuffer: CMSampleBuffer,
        codec: VideoCodec,
        keyframe: Bool
    ) throws -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw VideoEncoderError.missingBlockBuffer
        }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = Data(count: byteCount)
        let copyStatus = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: bytes.baseAddress!
            )
        }
        guard copyStatus == noErr else {
            throw VideoEncoderError.videoToolbox(operation: "CMBlockBufferCopyDataBytes", status: copyStatus)
        }

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw VideoEncoderError.missingFormatDescription
        }
        var nalLength: Int32 = 4
        var output = Data()
        if keyframe {
            switch codec {
            case .av1:
                throw VideoEncoderError.unsupportedCodec
            case .h264:
                output.append(try h264ParameterSets(format: format, nalLength: &nalLength))
            case .hevc:
                output.append(try hevcParameterSets(format: format, nalLength: &nalLength))
            case .rawLuma:
                throw VideoEncoderError.unsupportedCodec
            }
        } else {
            switch codec {
            case .av1:
                throw VideoEncoderError.unsupportedCodec
            case .h264:
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &nalLength
                )
                guard status == noErr else { throw VideoEncoderError.unsupportedParameterSets }
            case .hevc:
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &nalLength
                )
                guard status == noErr else { throw VideoEncoderError.unsupportedParameterSets }
            case .rawLuma:
                throw VideoEncoderError.unsupportedCodec
            }
        }
        output.append(try AnnexB.convertAVCC(avcc, nalLengthBytes: Int(nalLength)))
        return output
    }

    private static func h264ParameterSets(
        format: CMFormatDescription,
        nalLength: inout Int32
    ) throws -> Data {
        var output = Data()
        var count = 0
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalLength
            )
            guard status == noErr, let pointer else { throw VideoEncoderError.unsupportedParameterSets }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(pointer, count: size)
        }
        return output
    }

    private static func hevcParameterSets(
        format: CMFormatDescription,
        nalLength: inout Int32
    ) throws -> Data {
        var output = Data()
        var count = 0
        for index in 0..<3 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalLength
            )
            guard status == noErr, let pointer else { throw VideoEncoderError.unsupportedParameterSets }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(pointer, count: size)
        }
        return output
    }
}

private final class FrameContext: @unchecked Sendable {
    let frameID: UInt64
    let inputSequence: UInt64
    let submittedNanoseconds: UInt64

    init(frameID: UInt64, inputSequence: UInt64, submittedNanoseconds: UInt64) {
        self.frameID = frameID
        self.inputSequence = inputSequence
        self.submittedNanoseconds = submittedNanoseconds
    }
}
