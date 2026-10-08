import Foundation
import XCTest
@testable import RightClickCore

final class PortableResultVerificationTests: XCTestCase {
    private func verifyReturnedResult(
        _ returnedResult: CapabilityValue?,
        expected: String
    ) throws -> OutcomeVerification {
        let item = ContentItem(
            kind: "text",
            display: "typed-result-fixture",
            text: "typed-result-fixture",
            typeIdentifier: "public.plain-text"
        )

        let before = try OutcomeVerifier.snapshot(
            item: item
        )

        return try OutcomeVerifier.verify(
            spec: VerificationSpec(
                predicates: [
                    VerificationPredicate(
                        type: .resultPathEquals,
                        key: "value",
                        value: expected
                    )
                ]
            ),
            item: item,
            before: before,
            returnedText: nil,
            returnedResult: returnedResult
        )
    }

    func testResultPathEqualsVerifiesExactReturnedString() throws {
        let verification = try verifyReturnedResult(
            .object([
                "value": .string("requested")
            ]),
            expected: "requested"
        )

        XCTAssertEqual(
            verification.status,
            .verifiedSuccess
        )

        XCTAssertEqual(
            verification.predicates.first?.evaluated,
            true
        )

        XCTAssertEqual(
            verification.predicates.first?.passed,
            true
        )

        XCTAssertEqual(
            verification.predicates.first?.actual,
            "requested"
        )
    }

    func testResultPathEqualsDetectsReturnedStringMismatch() throws {
        let verification = try verifyReturnedResult(
            .object([
                "value": .string("different")
            ]),
            expected: "requested"
        )

        XCTAssertEqual(
            verification.status,
            .verifiedFailure
        )

        XCTAssertEqual(
            verification.predicates.first?.evaluated,
            true
        )

        XCTAssertEqual(
            verification.predicates.first?.passed,
            false
        )

        XCTAssertEqual(
            verification.predicates.first?.actual,
            "different"
        )
    }

    func testResultPathEqualsMissingPathRemainsUnverified() throws {
        let verification = try verifyReturnedResult(
            .object([
                "other": .string("requested")
            ]),
            expected: "requested"
        )

        XCTAssertEqual(
            verification.status,
            .unverified
        )

        XCTAssertEqual(
            verification.predicates.first?.evaluated,
            false
        )

        XCTAssertEqual(
            verification.predicates.first?.passed,
            false
        )

        XCTAssertNil(
            verification.predicates.first?.actual
        )
    }
}
