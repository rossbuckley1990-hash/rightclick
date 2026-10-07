import Foundation
import XCTest
@testable import RightClickCore

final class CapabilityABIBoundaryTests: XCTestCase {
    func testLimitsCannotBeRaisedAboveReviewedCeilings() {
        for limits in [CapabilityABILimits(maxDepth: 33), .init(maxNodes: 4097), .init(maxBytes: 1_048_577)] {
            XCTAssertThrowsError(try CapabilityValue.null.canonicalData(limits: limits))
        }
    }

    func testSchemaRequiredKeysMustMatchExactUTF8() {
        let schema = CapabilitySchema.object(properties: ["é": .string], required: ["e\u{0301}"])
        XCTAssertThrowsError(try schema.canonicalData())
    }

    func testSchemaDoesNotAcceptUnicodeEquivalentButDifferentKeyBytes() {
        let schema = CapabilitySchema.object(properties: ["é": .string], required: [])
        XCTAssertThrowsError(try schema.validate(.object(["e\u{0301}": .string("x")])))
    }

    func testVeryDeepSchemaAndVeryWideValuesReject() {
        var schema = CapabilitySchema.string
        for _ in 0..<40 { schema = .array(schema) }
        XCTAssertThrowsError(try schema.canonicalData())
        XCTAssertThrowsError(try CapabilityValue.array(Array(repeating: .null, count: 4096)).canonicalData())
    }

    func testNestedCodableWrapperCannotBypassValueValidation() {
        struct Box: Codable { let value: CapabilityValue }
        var deep = CapabilityValue.null
        for _ in 0..<40 { deep = .array([deep]) }
        XCTAssertThrowsError(try JSONEncoder().encode(Box(value: deep)))
        let wire = "{\"value\":" + String(repeating: "[\"array\",[", count: 40) + "[\"null\"]" + String(repeating: "]]", count: 40) + "}"
        XCTAssertThrowsError(try JSONDecoder().decode(Box.self, from: Data(wire.utf8)))
    }

    func testResultSchemaIsBoundIntoContract() throws {
        let a = CapabilityContract(capabilityID: "c", reflectorID: "r", providerID: "p",
                                   arguments: .string, result: .string, declaration: .null)
        let b = CapabilityContract(capabilityID: "c", reflectorID: "r", providerID: "p",
                                   arguments: .string, result: .integer, declaration: .null)
        XCTAssertNotEqual(try a.canonicalData(), try b.canonicalData())
    }

    func testDeterministicGeneratedRoundTrips() throws {
        var state: UInt64 = 0xC0FFEE
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1; return state }
        func value(_ depth: Int) -> CapabilityValue {
            switch next() % (depth > 0 ? 8 : 6) {
            case 0: return .null
            case 1: return .boolean(next() & 1 == 0)
            case 2: return .integer(Int64(bitPattern: next()))
            case 3: return .number(Double(Int64(bitPattern: next())) / 1024)
            case 4: return .string("value-\(next())-é")
            case 5: return .bytes(Data([UInt8(truncatingIfNeeded: next()), 0, 255]))
            case 6: return .array([value(depth - 1), value(depth - 1)])
            default: return .object(["a": value(depth - 1), "z": value(depth - 1)])
            }
        }
        for _ in 0..<512 {
            let original = value(4)
            let restored = try CapabilityValue.decodeWire(original.wireData())
            XCTAssertEqual(try original.canonicalData(), try restored.canonicalData())
        }
    }
}
