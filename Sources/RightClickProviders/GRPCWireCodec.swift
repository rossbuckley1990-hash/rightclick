import RightClickProtocol
import Foundation

enum GRPCWireCodecError:
    Error,
    LocalizedError
{
    case malformedVarint
    case truncatedField
    case invalidFieldNumber
    case unsupportedWireType(Int)

    var errorDescription:
        String?
    {
        switch self {
        case .malformedVarint:
            return "Malformed protobuf varint."

        case .truncatedField:
            return "Truncated protobuf field."

        case .invalidFieldNumber:
            return "Invalid protobuf field number."

        case let .unsupportedWireType(value):
            return "Unsupported protobuf wire type: \(value)."
        }
    }
}

struct GRPCWireReader {
    private let bytes:
        [UInt8]

    private(set) var index =
        0

    init(_ data: Data) {
        bytes =
            Array(data)
    }

    var isAtEnd: Bool {
        index >= bytes.count
    }

    mutating func readKey()
        throws
        -> (
            fieldNumber: Int,
            wireType: Int
        )?
    {
        if isAtEnd {
            return nil
        }

        let raw =
            try readVarint()

        let fieldNumber =
            Int(raw >> 3)

        let wireType =
            Int(raw & 0x07)

        guard fieldNumber > 0 else {
            throw GRPCWireCodecError
                .invalidFieldNumber
        }

        return (
            fieldNumber,
            wireType
        )
    }

    mutating func readVarint()
        throws -> UInt64
    {
        var value:
            UInt64 = 0

        var shift:
            UInt64 = 0

        for offset in 0..<10 {
            guard
                index < bytes.count
            else {
                throw GRPCWireCodecError
                    .truncatedField
            }

            let byte =
                bytes[index]

            guard
                offset != 9 || byte <= 1
            else {
                throw GRPCWireCodecError
                    .malformedVarint
            }

            index += 1

            value |=
                UInt64(
                    byte & 0x7f
                )
                << shift

            if byte & 0x80 == 0 {
                return value
            }

            shift += 7
        }

        throw GRPCWireCodecError
            .malformedVarint
    }

    mutating func readFixed32()
        throws -> UInt32
    {
        let raw =
            try readBytes(
                count:
                    4
            )

        return
            UInt32(raw[0])
            | (
                UInt32(raw[1])
                << 8
            )
            | (
                UInt32(raw[2])
                << 16
            )
            | (
                UInt32(raw[3])
                << 24
            )
    }

    mutating func readFixed64()
        throws -> UInt64
    {
        let raw =
            try readBytes(
                count:
                    8
            )

        var value:
            UInt64 = 0

        for (
            offset,
            byte
        ) in raw.enumerated()
        {
            value |=
                UInt64(byte)
                << UInt64(
                    offset * 8
                )
        }

        return value
    }

    mutating func readLengthDelimited()
        throws -> Data
    {
        let length =
            try readVarint()

        guard
            length
                <= UInt64(Int.max)
        else {
            throw GRPCWireCodecError
                .truncatedField
        }

        return Data(
            try readBytes(
                count:
                    Int(length)
            )
        )
    }

    mutating func skip(
        wireType: Int
    ) throws {
        switch wireType {
        case 0:
            _ = try readVarint()

        case 1:
            _ = try readFixed64()

        case 2:
            _ = try readLengthDelimited()

        case 5:
            _ = try readFixed32()

        default:
            throw GRPCWireCodecError
                .unsupportedWireType(
                    wireType
                )
        }
    }

    private mutating func readBytes(
        count: Int
    ) throws -> [UInt8] {
        guard
            count >= 0,
            index <= bytes.count,
            count <= bytes.count - index
        else {
            throw GRPCWireCodecError
                .truncatedField
        }

        let result =
            Array(
                bytes[
                    index..<(index + count)
                ]
            )

        index +=
            count

        return result
    }
}

struct GRPCWireWriter {
    private(set) var bytes:
        [UInt8] = []

    var data: Data {
        Data(bytes)
    }

    mutating func writeVarintField(
        _ fieldNumber: Int,
        value: UInt64
    ) {
        writeKey(
            fieldNumber:
                fieldNumber,
            wireType:
                0
        )

        writeVarint(
            value
        )
    }

    mutating func writeFixed64Field(
        _ fieldNumber: Int,
        value: UInt64
    ) {
        writeKey(
            fieldNumber:
                fieldNumber,
            wireType:
                1
        )

        for offset in 0..<8 {
            bytes.append(
                UInt8(
                    truncatingIfNeeded:
                        value
                        >> UInt64(
                            offset * 8
                        )
                )
            )
        }
    }

    mutating func writeLengthDelimitedField(
        _ fieldNumber: Int,
        data: Data
    ) {
        writeKey(
            fieldNumber:
                fieldNumber,
            wireType:
                2
        )

        writeVarint(
            UInt64(
                data.count
            )
        )

        bytes.append(
            contentsOf:
                data
        )
    }

    mutating func writeStringField(
        _ fieldNumber: Int,
        value: String
    ) {
        writeLengthDelimitedField(
            fieldNumber,
            data:
                Data(
                    value.utf8
                )
        )
    }

    mutating func writeFixed32Field(
        _ fieldNumber: Int,
        value: UInt32
    ) {
        writeKey(
            fieldNumber:
                fieldNumber,
            wireType:
                5
        )

        for offset in 0..<4 {
            bytes.append(
                UInt8(
                    truncatingIfNeeded:
                        value
                        >> UInt32(
                            offset * 8
                        )
                )
            )
        }
    }

    private mutating func writeKey(
        fieldNumber: Int,
        wireType: Int
    ) {
        precondition(
            fieldNumber > 0
        )

        writeVarint(
            (
                UInt64(fieldNumber)
                << 3
            )
            | UInt64(wireType)
        )
    }

    private mutating func writeVarint(
        _ raw: UInt64
    ) {
        var value =
            raw

        while value >= 0x80 {
            bytes.append(
                UInt8(
                    truncatingIfNeeded:
                        value
                )
                | 0x80
            )

            value >>= 7
        }

        bytes.append(
            UInt8(
                truncatingIfNeeded:
                    value
            )
        )
    }
}
