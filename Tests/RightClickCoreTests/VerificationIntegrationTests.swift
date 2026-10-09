@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
import XCTest
@testable import RightClickCore

final class VerificationIntegrationTests: XCTestCase {
    private let fullWidthID =
        "service:com.apple.ChineseTextConverterService:convertTextToFullWidth"

    #if os(macOS)
    func testRunPromotesAcceptedInvocationToVerifiedSuccess() throws {
        let engine = CapabilityEngine()

        let spec = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .textEquals,
                    value: "ＲｉｇｈｔＣｌｉｃｋ"
                )
            ],
            timeoutMilliseconds: 0
        )

        let result = try engine.run(
            id: fullWidthID,
            item: "RightClick",
            confirmed: true,
            verification: spec
        )

        XCTAssertEqual(
            result.status,
            .verified
        )

        XCTAssertEqual(
            result.verification?.status,
            .verifiedSuccess
        )

        XCTAssertEqual(
            result.verification?.predicates.first?.passed,
            true
        )

        XCTAssertTrue(
            result.evidence.outcomeVerified
        )
    }

    func testRunCanReportVerifiedSemanticFailureAfterAcceptedInvocation() throws {
        let engine = CapabilityEngine()

        let spec = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .textEquals,
                    value: "THIS IS DELIBERATELY WRONG"
                )
            ],
            timeoutMilliseconds: 0
        )

        let result = try engine.run(
            id: fullWidthID,
            item: "RightClick",
            confirmed: true,
            verification: spec
        )

        XCTAssertEqual(
            result.status,
            .failed
        )

        XCTAssertEqual(
            result.verification?.status,
            .verifiedFailure
        )

        XCTAssertEqual(
            result.verification?.predicates.first?.passed,
            false
        )

        // A verified failure is still a verified semantic observation.
        XCTAssertEqual(
            result.evidence.type,
            "generic_postcondition"
        )
    }

    func testNoVerificationSpecPreservesAcceptedUnverifiedBehaviour() throws {
        let engine = CapabilityEngine()

        let result = try engine.run(
            id: fullWidthID,
            item: "RightClick",
            confirmed: true
        )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertNil(
            result.verification
        )

        XCTAssertFalse(
            result.evidence.outcomeVerified
        )
    }

    func testBeginStoresGenericVerificationInExecutionRecord() throws {
        let engine = CapabilityEngine()

        let spec = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .textEquals,
                    value: "ＲｉｇｈｔＣｌｉｃｋ"
                )
            ],
            timeoutMilliseconds: 0
        )

        let record = try engine.begin(
            id: fullWidthID,
            item: "RightClick",
            confirmed: true,
            verification: spec
        )

        XCTAssertEqual(
            record.state,
            .succeeded
        )

        XCTAssertEqual(
            record.verification?.status,
            .verifiedSuccess
        )

        XCTAssertTrue(
            record.evidence.outcomeVerified
        )
    }

    func testVerificationReceiptIsMachineReadableJSON() throws {
        let engine = CapabilityEngine()

        let spec = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .textEquals,
                    value: "ＲｉｇｈｔＣｌｉｃｋ"
                )
            ],
            timeoutMilliseconds: 0
        )

        let result = try engine.run(
            id: fullWidthID,
            item: "RightClick",
            confirmed: true,
            verification: spec
        )

        let data = try JSONEncoder().encode(result)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any]
        )

        let verification = try XCTUnwrap(
            object["verification"]
                as? [String: Any]
        )

        XCTAssertEqual(
            verification["status"] as? String,
            "VERIFIED_SUCCESS"
        )

        let predicates = try XCTUnwrap(
            verification["predicates"]
                as? [[String: Any]]
        )

        XCTAssertEqual(
            predicates.count,
            1
        )
    }

    #endif

    func testVerificationSpecTimeoutRoundTripsThroughJSON() throws {
        let original = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .fileReadable
                )
            ],
            timeoutMilliseconds: 15_000
        )

        let encoded =
            try JSONEncoder().encode(original)

        let decoded =
            try JSONDecoder().decode(
                VerificationSpec.self,
                from: encoded
            )

        XCTAssertEqual(
            decoded,
            original
        )

        XCTAssertEqual(
            decoded.timeoutMilliseconds,
            15_000
        )
    }
}
