import AppKit
import XCTest
@testable import RightClickCore

final class ServiceRTFUnicodeTests: XCTestCase {
    private let vectors = [
        "", "RIGHTCLICK", "Caf\u{00e9}", "\u{ff32}\u{ff23}",
        "\u{1f680}", "\u{4e2d}\u{6587}", "e\u{0301}",
        "\\{braces}", "tab\tline\nnext", "\u{05e9}\u{0645}",
        "\u{20ac}\u{00a3}", "\u{2028}\u{2029}"
    ]

    private func decode(_ data: Data) throws -> String {
        try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ).string
    }

    func testUnicodeRoundTripThroughRTFEncoder() throws {
        for (index, text) in vectors.enumerated() {
            let data = ServiceRTFEncoder.encode(text)
            XCTAssertTrue(data.allSatisfy { $0 < 128 }, "vector \(index): RTF wire must be ASCII")
            let decoded = try decode(data)
            // Swift String equality ignores canonical normalization. Compare
            // UTF-16 units as well so a combining-mark regression is visible.
            XCTAssertEqual(Array(decoded.utf16), Array(text.utf16), "vector \(index)")
        }
    }

    func testSupplementaryScalarsUseSignedSurrogateEscapes() {
        let wire = String(decoding: ServiceRTFEncoder.encode("\u{1f680}"), as: UTF8.self)
        XCTAssertTrue(wire.contains("\\u-10179?\\u-8576?"))
    }

    func testRTFMetacharactersAreNotInterpretedAsInstructions() throws {
        let text = "{\\rtf1\\ansi injected} \\u65? \\par"
        XCTAssertEqual(try decode(ServiceRTFEncoder.encode(text)), text)
    }

    func testDeclaredRTFPasteboardUsesUnicodeEncoder() throws {
        for type in ["public.rtf", "NSRTFPboardType"] {
            for text in vectors {
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                ServiceCatalog.prepareTextPasteboard(board, text: text, declaredSendTypes: [type])
                let data = try XCTUnwrap(board.data(forType: .rtf))
                XCTAssertEqual(Array(try decode(data).utf16), Array(text.utf16))
            }
        }
    }

    func testPlainTextRepresentationRemainsUnchanged() throws {
        let text = "Caf\u{00e9} \u{1f680}"
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        ServiceCatalog.prepareTextPasteboard(
            board, text: text, declaredSendTypes: ["public.rtf", "public.utf8-plain-text"]
        )
        XCTAssertEqual(board.string(forType: .string), text)
        XCTAssertEqual(try decode(XCTUnwrap(board.data(forType: .rtf))), text)
    }

    func testUnicodeURLUsesSameRTFEncoder() throws {
        let url = "https://example.com/Caf\u{00e9}/\u{4e2d}\u{6587}"
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(ServiceCatalog.prepareWebURLPasteboard(board, url: url, declaredSendTypes: ["public.rtf"]))
        XCTAssertEqual(try decode(XCTUnwrap(board.data(forType: .rtf))), url)
    }
}
