#if os(macOS)
import Foundation
import XCTest
@testable import RightClickCore

/// Opt-in real macOS Service test. It must run on a host where the Apple text
/// converter is installed, rather than pretending a pure unit test exercised
/// NSPerformService. It never writes files or invokes an external network.
final class NativeServiceUnicodeLiveAcceptanceTests: XCTestCase {
    func testInstalledHalfWidthServicePreservesNonASCIIText() throws {
        guard ProcessInfo.processInfo.environment["RIGHTCLICK_LIVE_UNICODE_SERVICE"] == "1" else {
            throw XCTSkip("Set RIGHTCLICK_LIVE_UNICODE_SERVICE=1 on a macOS host with the system text converter.")
        }

        let engine = CapabilityRuntimeDefaults.makeEngine(startBrowsing: false)
        let input = "café € 漢字 🚀 ＲｉｇｈｔＣｌｉｃｋ"
        // Half-width conversion must transform the full-width letters while
        // preserving the other Unicode scalars, including the emoji.
        let expected = "café € 漢字 🚀 RightClick"
        let capabilities = try engine.capabilities(for: input).capabilities
        guard let selected = capabilities.first(where: {
            $0.title == "Convert Text to Half Width"
                && $0.provider?.bundleIdentifier == "com.apple.ChineseTextConverterService"
        }) else {
            throw XCTSkip("Apple full/half-width macOS Service unavailable")
        }

        let output = try engine.begin(
            id: selected.id,
            item: input,
            confirmed: true
        )

        XCTAssertEqual(
            output.output,
            expected,
            "Installed text converter introduced or retained Unicode mojibake."
        )
        XCTAssertEqual(Array(try XCTUnwrap(output.output).utf16), Array(expected.utf16))
        XCTAssertTrue(
            output.state == .accepted || output.state == .succeeded,
            "Native converter invocation was not accepted."
        )
    }

    func testInstalledFullWidthServiceTransformsASCIIWithoutCorruption() throws {
        guard ProcessInfo.processInfo.environment["RIGHTCLICK_LIVE_UNICODE_SERVICE"] == "1" else {
            throw XCTSkip("Set RIGHTCLICK_LIVE_UNICODE_SERVICE=1 on a macOS host.")
        }
        let engine = CapabilityRuntimeDefaults.makeEngine(startBrowsing: false)
        let input = "RightClick"
        let selected = try XCTUnwrap(engine.capabilities(for: input).capabilities.first {
            $0.title == "Convert Text to Full Width"
                && $0.provider?.bundleIdentifier == "com.apple.ChineseTextConverterService"
        })
        let record = try engine.begin(id: selected.id, item: input, confirmed: true)
        XCTAssertEqual(record.output, "ＲｉｇｈｔＣｌｉｃｋ")
        XCTAssertTrue(record.state == .accepted || record.state == .succeeded)
    }
}
#endif
