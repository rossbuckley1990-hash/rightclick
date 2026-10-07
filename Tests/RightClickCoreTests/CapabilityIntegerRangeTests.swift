import XCTest
@testable import RightClickCore

final class CapabilityIntegerRangeTests: XCTestCase {
    func testInclusiveNarrowRangeRejectsOverflowAndOtherValueKinds() throws {
        let schema = CapabilitySchema.integerRange(minimum: -2_147_483_648, maximum: 2_147_483_647)
        for value: Int64 in [-2_147_483_648, 0, 2_147_483_647] { XCTAssertNoThrow(try schema.validate(.integer(value))) }
        for value: Int64 in [Int64.min, -2_147_483_649, 2_147_483_648, Int64.max] { XCTAssertThrowsError(try schema.validate(.integer(value))) }
        for value: CapabilityValue in [.number(1), .boolean(true), .string("1"), .null] { XCTAssertThrowsError(try schema.validate(value)) }
    }
    func testRangeIsPartOfCanonicalContractAndExistingIntegerBytesRemainStable() throws {
        XCTAssertEqual(try CapabilitySchema.integer.canonicalData(), try CapabilityValue.string("integer").canonicalData())
        XCTAssertNotEqual(try CapabilitySchema.integerRange(minimum: 0, maximum: 1).canonicalData(),
                          try CapabilitySchema.integerRange(minimum: 0, maximum: 2).canonicalData())
        XCTAssertThrowsError(try CapabilitySchema.integerRange(minimum: 1, maximum: 0).canonicalData())
        XCTAssertNoThrow(try CapabilitySchema.integerRange(minimum: Int64.min, maximum: Int64.max).validate(.integer(Int64.max)))
    }
}
