import XCTest
@testable import RightClickCore

final class ServiceOutcomeTests: XCTestCase {
    private func result(_ returned: Bool? = true, changed: Bool = true,
                        output: String? = "result", expected: String? = nil) -> RunResult {
        ServiceOutcome.result(actionID: "service:fixture:message", title: "Fixture",
                              returned: returned, pasteboardChanged: changed,
                              returnedText: output, expectedOutput: expected, inputText: "input")
    }

    func testUnchangedInputIsNotReturnedOrVerified() {
        let value = result(changed: false, output: "input", expected: "input")
        XCTAssertEqual(value.status, .accepted)
        XCTAssertNil(value.output)
        XCTAssertFalse(value.evidence.outcomeVerified)
        let echo = ServiceOutcome.result(actionID: "fixture", title: "Fixture", returned: true,
                                         pasteboardChanged: true, returnedText: "input", expectedOutput: "input", inputText: "input")
        XCTAssertEqual(echo.status, .accepted)
        XCTAssertFalse(echo.evidence.outcomeVerified)
        XCTAssertEqual(value.evidence.type, "provider_acceptance")
    }

    func testChangedCounterWithoutDeclaredOutputIsNotVerification() {
        let value = result(output: nil, expected: "result")
        XCTAssertEqual(value.status, .accepted)
        XCTAssertNil(value.output)
        XCTAssertFalse(value.evidence.outcomeVerified)
    }

    func testReturnedOutputWithoutPostconditionIsNotSemanticSuccess() {
        let value = result()
        XCTAssertEqual(value.status, .accepted)
        XCTAssertEqual(value.output, "result")
        XCTAssertFalse(value.evidence.outcomeVerified)
        XCTAssertEqual(value.evidence.type, "provider_returned_text")
    }

    func testEchoedInputWithChangedCounterIsNotSemanticProof() {
        let value = ServiceOutcome.result(actionID: "fixture", title: "Fixture", returned: true,
                                          pasteboardChanged: true, returnedText: "input", expectedOutput: "input")
        // The pure model has no independent input observation, so it must not
        // establish verified success merely from a counter and a matching string.
        XCTAssertEqual(value.status, .accepted)
        XCTAssertFalse(value.evidence.outcomeVerified)
    }

    func testExactPostconditionChecksEmptyUnicodeAndWhitespaceWithoutNormalization() {
        for expected in ["", "𝄞 café\n", " trailing "] {
            let match = result(output: expected, expected: expected)
            XCTAssertEqual(match.status, .verified)
            XCTAssertTrue(match.evidence.outcomeVerified)
            XCTAssertEqual(match.evidence.type, "returned_text_postcondition")
            let mismatch = result(output: expected + "!", expected: expected)
            XCTAssertEqual(mismatch.status, .failed)
            XCTAssertFalse(mismatch.evidence.outcomeVerified)
        }
    }

    func testRejectionAndDeadlineCannotSucceedOrLeakEchoedInput() {
        let rejected = result(false, output: "input", expected: "input")
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertNil(rejected.output)
        XCTAssertFalse(rejected.evidence.outcomeVerified)
        let timeout = result(nil, output: "input", expected: "input")
        XCTAssertEqual(timeout.status, .unknown)
        XCTAssertNil(timeout.output)
        XCTAssertTrue(timeout.message.contains("may still act"))
    }
}
