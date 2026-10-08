import Foundation
import XCTest

@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

final class GRPCWireCodecBoundsTests: XCTestCase {
    func testFullWidthVarintsRemainValid() throws {
        for value in [UInt64(0), 1, 127, 128, UInt64(Int64.max), UInt64.max] {
            var writer = GRPCWireWriter()
            writer.writeVarintField(1, value: value)
            var reader = GRPCWireReader(writer.data)
            let key = try XCTUnwrap(reader.readKey())
            XCTAssertEqual(key.fieldNumber, 1)
            XCTAssertEqual(key.wireType, 0)
            XCTAssertEqual(try reader.readVarint(), value)
            XCTAssertTrue(reader.isAtEnd)
        }
    }

    func testEveryOverflowingTenthByteIsRejected() {
        for byte in UInt8(2)...UInt8.max {
            var reader = GRPCWireReader(Data(Array(repeating: UInt8(0xff), count: 9) + [byte]))
            XCTAssertThrowsError(try reader.readVarint()) { error in
                guard case GRPCWireCodecError.malformedVarint = error else {
                    return XCTFail("Expected malformed varint for tenth byte \(byte), got \(error).")
                }
            }
        }
    }

    func testMaximumRepresentableLengthIsRejectedWithoutArithmeticTrap() {
        var writer = GRPCWireWriter()
        writer.writeVarintField(1, value: UInt64(Int.max))
        var reader = GRPCWireReader(Data(writer.data.dropFirst()))
        XCTAssertThrowsError(try reader.readLengthDelimited()) { error in
            guard case GRPCWireCodecError.truncatedField = error else {
                return XCTFail("Expected bounded length rejection, got \(error).")
            }
        }
    }

    func testLengthsLargerThanHostIntegerAreRejected() {
        var writer = GRPCWireWriter()
        writer.writeVarintField(1, value: UInt64.max)
        var reader = GRPCWireReader(Data(writer.data.dropFirst()))
        XCTAssertThrowsError(try reader.readLengthDelimited()) { error in
            guard case GRPCWireCodecError.truncatedField = error else {
                return XCTFail("Expected bounded length rejection, got \(error).")
            }
        }
    }

    func testValidFieldsPreserveFollowingWireData() throws {
        var reader = GRPCWireReader(Data([0, 3, 65, 66, 67, 150, 1]))
        XCTAssertEqual(try reader.readLengthDelimited(), Data())
        XCTAssertEqual(try reader.readLengthDelimited(), Data("ABC".utf8))
        XCTAssertEqual(try reader.readVarint(), 150)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testTruncatedLengthAndPayloadAreRejected() {
        for data in [Data([0x80]), Data([4, 65, 66, 67])] {
            var reader = GRPCWireReader(data)
            XCTAssertThrowsError(try reader.readLengthDelimited()) { error in
                guard case GRPCWireCodecError.truncatedField = error else {
                    return XCTFail("Expected truncated field, got \(error).")
                }
            }
        }
    }
}
