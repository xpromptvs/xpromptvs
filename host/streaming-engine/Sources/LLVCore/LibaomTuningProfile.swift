import Foundation

public enum AV1ScreenDetectionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case standard
    case antialiasingAware = "antialiasing-aware"

    public var libaomValue: Int {
        switch self {
        case .standard: 1
        case .antialiasingAware: 2
        }
    }

    init?(libaomValue: Int?) {
        switch libaomValue {
        case nil, 1: self = .standard
        case 2: self = .antialiasingAware
        default: return nil
        }
    }
}

public enum LibaomActiveMapMode: String, Codable, Equatable, Sendable {
    case none
    case perfectDamageCeiling
}

public enum LibaomTuningProfileError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case valueOutOfRange(field: String, value: Int)
    case invalidBufferRelationship(field: String, value: Int, total: Int)
}

extension LibaomTuningProfileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(identifier):
            "invalid libaom tuning profile identifier: \(identifier.debugDescription)"
        case let .valueOutOfRange(field, value):
            "libaom tuning profile field \(field) has out-of-range value \(value)"
        case let .invalidBufferRelationship(field, value, total):
            "libaom tuning profile field \(field) value \(value) exceeds total buffer \(total)"
        }
    }
}

public struct LibaomTuningProfile: Codable, Equatable, Sendable {
    public let id: String
    public let cpuUsed: Int
    public let threads: Int
    public let tileColumnsLog2: Int
    public let tileRowsLog2: Int
    public let autoTiles: Bool?
    public let rcBufferMilliseconds: Int
    public let rcInitialBufferMilliseconds: Int
    public let rcOptimalBufferMilliseconds: Int
    public let screenDetectionMode: Int?
    public let aqMode: Int?
    public let sharpness: Int?
    public let adaptiveSharpness: Bool?
    public let cdefMode: Int?
    public let loopfilterMode: Int?
    public let activeMapMode: LibaomActiveMapMode

    public init(
        id: String,
        cpuUsed: Int,
        threads: Int,
        tileColumnsLog2: Int,
        tileRowsLog2: Int,
        autoTiles: Bool?,
        rcBufferMilliseconds: Int,
        rcInitialBufferMilliseconds: Int,
        rcOptimalBufferMilliseconds: Int,
        screenDetectionMode: Int?,
        aqMode: Int?,
        sharpness: Int?,
        adaptiveSharpness: Bool?,
        cdefMode: Int?,
        loopfilterMode: Int?,
        activeMapMode: LibaomActiveMapMode
    ) {
        self.id = id
        self.cpuUsed = cpuUsed
        self.threads = threads
        self.tileColumnsLog2 = tileColumnsLog2
        self.tileRowsLog2 = tileRowsLog2
        self.autoTiles = autoTiles
        self.rcBufferMilliseconds = rcBufferMilliseconds
        self.rcInitialBufferMilliseconds = rcInitialBufferMilliseconds
        self.rcOptimalBufferMilliseconds = rcOptimalBufferMilliseconds
        self.screenDetectionMode = screenDetectionMode
        self.aqMode = aqMode
        self.sharpness = sharpness
        self.adaptiveSharpness = adaptiveSharpness
        self.cdefMode = cdefMode
        self.loopfilterMode = loopfilterMode
        self.activeMapMode = activeMapMode
    }

    public static let currentControl = LibaomTuningProfile(
        id: "control",
        cpuUsed: 12,
        threads: 12,
        tileColumnsLog2: 1,
        tileRowsLog2: 1,
        autoTiles: nil,
        rcBufferMilliseconds: 100,
        rcInitialBufferMilliseconds: 50,
        rcOptimalBufferMilliseconds: 50,
        screenDetectionMode: nil,
        aqMode: nil,
        sharpness: nil,
        adaptiveSharpness: nil,
        cdefMode: nil,
        loopfilterMode: nil,
        activeMapMode: .none
    )

    @discardableResult
    public func validated() throws -> LibaomTuningProfile {
        let allowedIdentifierCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !id.isEmpty,
              id.unicodeScalars.allSatisfy({ $0.isASCII && allowedIdentifierCharacters.contains($0) })
        else {
            throw LibaomTuningProfileError.invalidIdentifier(id)
        }

        try Self.require(cpuUsed, in: 0 ... 12, field: "cpuUsed")
        try Self.require(threads, in: 1 ... 64, field: "threads")
        try Self.require(tileColumnsLog2, in: 0 ... 6, field: "tileColumnsLog2")
        try Self.require(tileRowsLog2, in: 0 ... 6, field: "tileRowsLog2")
        try Self.require(rcBufferMilliseconds, in: 1 ... 10_000, field: "rcBufferMilliseconds")
        try Self.require(rcInitialBufferMilliseconds, in: 1 ... 10_000, field: "rcInitialBufferMilliseconds")
        try Self.require(rcOptimalBufferMilliseconds, in: 1 ... 10_000, field: "rcOptimalBufferMilliseconds")
        try Self.requireOptional(screenDetectionMode, allowed: [1, 2], field: "screenDetectionMode")
        try Self.requireOptional(aqMode, allowed: [0, 3], field: "aqMode")
        try Self.requireOptional(sharpness, in: 0 ... 7, field: "sharpness")
        try Self.requireOptional(cdefMode, in: 0 ... 3, field: "cdefMode")
        try Self.requireOptional(loopfilterMode, in: 0 ... 3, field: "loopfilterMode")

        guard rcInitialBufferMilliseconds <= rcBufferMilliseconds else {
            throw LibaomTuningProfileError.invalidBufferRelationship(
                field: "rcInitialBufferMilliseconds",
                value: rcInitialBufferMilliseconds,
                total: rcBufferMilliseconds
            )
        }
        guard rcOptimalBufferMilliseconds <= rcBufferMilliseconds else {
            throw LibaomTuningProfileError.invalidBufferRelationship(
                field: "rcOptimalBufferMilliseconds",
                value: rcOptimalBufferMilliseconds,
                total: rcBufferMilliseconds
            )
        }
        return self
    }

    public func replacing(
        id: String? = nil,
        cpuUsed: Int? = nil,
        threads: Int? = nil,
        tileColumnsLog2: Int? = nil,
        tileRowsLog2: Int? = nil,
        autoTiles: Bool? = nil,
        rcBufferMilliseconds: Int? = nil,
        rcInitialBufferMilliseconds: Int? = nil,
        rcOptimalBufferMilliseconds: Int? = nil,
        screenDetectionMode: Int? = nil,
        aqMode: Int? = nil,
        sharpness: Int? = nil,
        adaptiveSharpness: Bool? = nil,
        cdefMode: Int? = nil,
        loopfilterMode: Int? = nil,
        activeMapMode: LibaomActiveMapMode? = nil
    ) -> LibaomTuningProfile {
        LibaomTuningProfile(
            id: id ?? self.id,
            cpuUsed: cpuUsed ?? self.cpuUsed,
            threads: threads ?? self.threads,
            tileColumnsLog2: tileColumnsLog2 ?? self.tileColumnsLog2,
            tileRowsLog2: tileRowsLog2 ?? self.tileRowsLog2,
            autoTiles: autoTiles ?? self.autoTiles,
            rcBufferMilliseconds: rcBufferMilliseconds ?? self.rcBufferMilliseconds,
            rcInitialBufferMilliseconds: rcInitialBufferMilliseconds ?? self.rcInitialBufferMilliseconds,
            rcOptimalBufferMilliseconds: rcOptimalBufferMilliseconds ?? self.rcOptimalBufferMilliseconds,
            screenDetectionMode: screenDetectionMode ?? self.screenDetectionMode,
            aqMode: aqMode ?? self.aqMode,
            sharpness: sharpness ?? self.sharpness,
            adaptiveSharpness: adaptiveSharpness ?? self.adaptiveSharpness,
            cdefMode: cdefMode ?? self.cdefMode,
            loopfilterMode: loopfilterMode ?? self.loopfilterMode,
            activeMapMode: activeMapMode ?? self.activeMapMode
        )
    }

    private static func require(_ value: Int, in range: ClosedRange<Int>, field: String) throws {
        guard range.contains(value) else {
            throw LibaomTuningProfileError.valueOutOfRange(field: field, value: value)
        }
    }

    private static func requireOptional(
        _ value: Int?,
        in range: ClosedRange<Int>,
        field: String
    ) throws {
        guard let value else { return }
        try require(value, in: range, field: field)
    }

    private static func requireOptional(_ value: Int?, allowed: Set<Int>, field: String) throws {
        guard let value else { return }
        guard allowed.contains(value) else {
            throw LibaomTuningProfileError.valueOutOfRange(field: field, value: value)
        }
    }
}
