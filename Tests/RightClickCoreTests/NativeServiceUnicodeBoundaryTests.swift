@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import XCTest
@testable import RightClickCore

final class NativeServiceUnicodeBoundaryTests: XCTestCase {
    private let targetProvider = "com.apple.ChineseTextConverterService"

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
                NativeServiceUnicodeBoundary.repaired(
                    vector.observed,
                    input: vector.original,
                    bundleIdentifier: targetProvider
                ),
                vector.original,
                "Mismatch repairing observed text: \(vector.observed)"
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
                NativeServiceUnicodeBoundary.repaired(
                    corrupted,
                    input: original,
                    bundleIdentifier: targetProvider
                ),
                original,
                label
            )
        }
    }

    func testUnrelatedProviderCannotBeModified() {
        XCTAssertEqual(
            NativeServiceUnicodeBoundary.repaired(
                "cafÃ©", input: "café",
                bundleIdentifier: "com.thirdparty.SomeService"
            ),
            "cafÃ©"
        )
    }

    func testExistingCorrectOutputAndEchoStayUntouched() {
        for value in ["café", "€", "漢", "RightClick", "ï¼‘", "cafÃ©"] {
            XCTAssertEqual(
                NativeServiceUnicodeBoundary.repaired(
                    value, input: value, bundleIdentifier: targetProvider
                ),
                value
            )
        }
    }

    func testNonRepairableBytesAndNormalAsciiAreUntouched() {
        for value in ["hello", "ï", "Ã", "â", "valid output 123"] {
            XCTAssertEqual(
                NativeServiceUnicodeBoundary.repaired(
                    value, input: "other", bundleIdentifier: targetProvider
                ),
                value
            )
        }
    }

    func testFullWidthResultWithCorrectUnicodeIsNotMutated() {
        XCTAssertEqual(
            NativeServiceUnicodeBoundary.repaired(
                "ＲｉｇｈｔＣｌｉｃｋ",
                input: "RightClick",
                bundleIdentifier: targetProvider
            ),
            "ＲｉｇｈｔＣｌｉｃｋ"
        )
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
