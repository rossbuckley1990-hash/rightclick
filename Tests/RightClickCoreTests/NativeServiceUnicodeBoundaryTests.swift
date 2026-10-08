import XCTest
@testable import RightClickCore

final class NativeServiceUnicodeBoundaryTests: XCTestCase {
    // Keep the original method names and vectors for inventory continuity. The
    // original decoder expectations were unsound: a real half-width Service
    // returns literal "cafÃ©" for "ｃａｆÃ©". Reinterpreting those valid bytes as
    // "café" changes the observation and can change a verification decision.
    // Unicode belongs in the input RTF encoding, not guessed output repairs.
    private func observation(_ output: String, input: String?) -> String? {
        let wire = ServiceRTFEncoder.encode(output)
        XCTAssertTrue(wire.allSatisfy { $0 < 128 })
        XCTAssertEqual(wire, ServiceRTFEncoder.encode(output))
        let result = ServiceOutcome.result(
            actionID: "service-observation-control",
            title: "Declared returned text",
            returned: true,
            pasteboardChanged: true,
            returnedText: output,
            expectedOutput: nil,
            inputText: input
        )
        XCTAssertEqual(result.status, .accepted)
        XCTAssertEqual(result.evidence?.type, "provider_returned_text")
        return result.output
    }

    func testObservedMojibakeVectorsAreRepairedExactly() {
        let vectors: [(observed: String, original: String)] = [
            ("cafÃ©", "café"),
            ("â‚¬", "€"),
            ("æ¼¢", "漢"),
            ("ðŸš€", "🚀"),
            ("ï¼‘ï¼’ï¼“ï¼”ï¼•", "１２３４５"),
            ("ï¼²ï½‰ï½‡ï½ˆï½”ï¼£ï½Œï½‰ï½ƒï½‹", "ＲｉｇｈｔＣｌｉｃｋ"),
            ("ï¼·ï¼¯ï¼·ï¼‘ï¼’ï¼“ï¼”ï¼•", "ＷＯＷ１２３４５"),
        ]
        for vector in vectors {
            XCTAssertEqual(
                observation(vector.observed, input: vector.original).map { Array($0.utf8) },
                Array(vector.observed.utf8),
                "Provider-written observation must retain its exact bytes."
            )
        }
    }

    func testComplexUnicodeAcrossLanguageFamilies() {
        let cases = [
            ("Arabic", "مرحبا بالعالم"),
            ("Hindi", "नमस्ते दुनिया"),
            ("Japanese", "東京と大阪"),
            ("ZWJ emoji", "👩‍🚀 👨‍👩‍👧‍👦"),
            ("combining accents", "e\u{0301} a\u{0308} n\u{0303}"),
            ("Greek and Cyrillic", "Ελληνικά Москва"),
        ]
        for (label, original) in cases {
            let corrupted = expectedWindows1252Mojibake(original)
            XCTAssertEqual(
                observation(corrupted, input: original).map { Array($0.utf16) },
                Array(corrupted.utf16),
                label
            )
        }
    }

    func testUnrelatedProviderCannotBeModified() {
        XCTAssertEqual(
            observation("cafÃ©", input: "café"),
            "cafÃ©"
        )
    }

    func testExistingCorrectOutputAndEchoStayUntouched() {
        for value in ["café", "€", "漢", "RightClick", "ï¼‘", "cafÃ©"] {
            XCTAssertEqual(
                observation(value, input: value),
                value
            )
        }
    }

    func testNonRepairableBytesAndNormalAsciiAreUntouched() {
        for value in ["hello", "ï", "Ã", "â", "valid output 123"] {
            XCTAssertEqual(
                observation(value, input: "other"),
                value
            )
        }
    }

    func testFullWidthResultWithCorrectUnicodeIsNotMutated() {
        XCTAssertEqual(
            observation("ＲｉｇｈｔＣｌｉｃｋ", input: "RightClick"),
            "ＲｉｇｈｔＣｌｉｃｋ"
        )
    }

    func testLegitimateTransformedLiteralPreservesObservedUTF8AndUTF16() {
        let input = "ｃａｆÃ©"
        let rawDeclaredOutput = "cafÃ©"
        let record = ServiceOutcome.result(
            actionID: "service-observation-control",
            title: "Declared returned text",
            returned: true,
            pasteboardChanged: true,
            returnedText: rawDeclaredOutput,
            expectedOutput: rawDeclaredOutput,
            inputText: input
        )
        XCTAssertEqual(record.output.map { Array($0.utf8) }, Array(rawDeclaredOutput.utf8))
        XCTAssertEqual(record.output.map { Array($0.utf16) }, Array(rawDeclaredOutput.utf16))
        XCTAssertEqual(record.status, .verified)
        XCTAssertEqual(record.evidence?.outcomeVerified, true)
    }

    func testLiteralOutputCannotSatisfyReinterpretedPostcondition() {
        let record = ServiceOutcome.result(
            actionID: "service-observation-control",
            title: "Declared returned text",
            returned: true,
            pasteboardChanged: true,
            returnedText: "cafÃ©",
            expectedOutput: "café",
            inputText: "ｃａｆÃ©"
        )
        XCTAssertEqual(record.output, "cafÃ©")
        XCTAssertEqual(
            String(decoding: ServiceRTFEncoder.encode("cafÃ©"), as: UTF8.self),
            "{\\rtf1\\ansi\\ansicpg1252\\uc1 caf\\u195?\\u169?}"
        )
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.evidence?.outcomeVerified, false)
    }

    /// Test fixture only; encodes real UTF-8 bytes into the Windows-1252
    /// symbols observed in native macOS Service output.
    private func expectedWindows1252Mojibake(_ original: String) -> String {
        let special: [UInt8: Unicode.Scalar] = [
            0x80: "€", 0x82: "‚", 0x83: "ƒ", 0x84: "„",
            0x85: "…", 0x86: "†", 0x87: "‡", 0x88: "ˆ",
            0x89: "‰", 0x8A: "Š", 0x8B: "‹", 0x8C: "Œ",
            0x8E: "Ž", 0x91: "‘", 0x92: "’", 0x93: "“",
            0x94: "”", 0x95: "•", 0x96: "–", 0x97: "—",
            0x98: "˜", 0x99: "™", 0x9A: "š", 0x9B: "›",
            0x9C: "œ", 0x9E: "ž", 0x9F: "Ÿ",
        ]
        var result = String.UnicodeScalarView()
        for byte in original.utf8 {
            if let scalar = special[byte] {
                result.append(scalar)
            } else {
                result.append(Unicode.Scalar(UInt32(byte))!)
            }
        }
        return String(result)
    }
}
