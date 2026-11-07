import Foundation

public enum AnnexBError: Error, Equatable, Sendable {
    case malformedLength
}

public enum AnnexB {
    public static func convertAVCC(_ data: Data, nalLengthBytes: Int = 4) throws -> Data {
        guard (1...4).contains(nalLengthBytes) else {
            throw AnnexBError.malformedLength
        }

        var output = Data()
        output.reserveCapacity(data.count + 16)
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= nalLengthBytes else {
                throw AnnexBError.malformedLength
            }
            var length = 0
            for byte in data[offset..<(offset + nalLengthBytes)] {
                length = (length << 8) | Int(byte)
            }
            offset += nalLengthBytes
            guard length > 0, length <= data.count - offset else {
                throw AnnexBError.malformedLength
            }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(data[offset..<(offset + length)])
            offset += length
        }
        return output
    }

    public static func splitNALUnits(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, prefix: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty, starts[0].offset == 0 else {
            throw AnnexBError.malformedLength
        }

        var units: [Data] = []
        for position in starts.indices {
            let start = starts[position].offset + starts[position].prefix
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard end > start else { throw AnnexBError.malformedLength }
            units.append(Data(bytes[start..<end]))
        }
        return units
    }

    public static func makeAVCC(_ nalUnits: [Data]) throws -> Data {
        var output = Data()
        for unit in nalUnits {
            guard !unit.isEmpty, unit.count <= Int(UInt32.max) else {
                throw AnnexBError.malformedLength
            }
            let length = UInt32(unit.count)
            output.append(UInt8(truncatingIfNeeded: length >> 24))
            output.append(UInt8(truncatingIfNeeded: length >> 16))
            output.append(UInt8(truncatingIfNeeded: length >> 8))
            output.append(UInt8(truncatingIfNeeded: length))
            output.append(unit)
        }
        return output
    }
}
