import Foundation
#if canImport(AppKit)
import AppKit
#endif
import XCTest
@testable import RightClickCore

final class ServiceRTFUnicodeTests: XCTestCase {
    private let vectors = [
        "", "RIGHTCLICK", "Caf\u{00e9}", "\u{ff32}\u{ff23}",
        "\u{1f680}", "\u{4e2d}\u{6587}", "e\u{0301}",
        "\\{braces}", "tab\tline\nnext", "\u{05e9}\u{0645}",
        "\u{20ac}\u{00a3}", "\u{2028}\u{2029}"
    ]

    #if canImport(AppKit)
    private func decode(_ data: Data) throws -> String {
        try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ).string
    }
    #endif

    func testUnicodeRoundTripThroughRTFEncoder() throws {
        for (index, text) in vectors.enumerated() {
            let data = ServiceRTFEncoder.encode(text)
            XCTAssertTrue(data.allSatisfy { $0 < 128 }, "vector \(index): RTF wire must be ASCII")
            #if canImport(AppKit)
            let decoded = try decode(data)
            // Swift String equality ignores canonical normalization. Compare
            // UTF-16 units as well so a combining-mark regression is visible.
            XCTAssertEqual(Array(decoded.utf16), Array(text.utf16), "vector \(index)")
            #endif
        }
    }

    func testSupplementaryScalarsUseSignedSurrogateEscapes() {
        let wire = String(decoding: ServiceRTFEncoder.encode("\u{1f680}"), as: UTF8.self)
        XCTAssertTrue(wire.contains("\\u-10179?\\u-8576?"))
    }

    func testRTFMetacharactersAreNotInterpretedAsInstructions() throws {
        let text = "{\\rtf1\\ansi injected} \\u65? \\par"
        XCTAssertEqual(
            String(decoding: ServiceRTFEncoder.encode(text), as: UTF8.self),
            "{\\rtf1\\ansi\\ansicpg1252\\uc1 \\{\\\\rtf1\\\\ansi injected\\} \\\\u65? \\\\par}"
        )
        #if canImport(AppKit)
        XCTAssertEqual(try decode(ServiceRTFEncoder.encode(text)), text)
        #endif
    }

    #if canImport(AppKit)
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
    #endif

    func testSeededMixedUnicodeRoundTrips() throws {
        let pieces = [
            "A", "z", "0", " ", "{", "}", "\\", "\u{00e9}",
            "e\u{0301}", "\u{1f680}", "\u{1f600}", "\u{20000}",
            "\u{4e2d}", "\u{6587}", "\u{03a9}", "\u{05e9}",
            "\u{0645}", "\u{0930}", "\u{20ac}", "\u{00a3}",
            "\u{ff32}", "\u{ff23}", "\u{00a0}", "\u{202f}"
        ]
        var state: UInt64 = 20261008
        for index in 0..<512 {
            var text = ""
            for _ in 0..<(1 + index % 64) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                text += pieces[Int(state % UInt64(pieces.count))]
            }
            let data = ServiceRTFEncoder.encode(text)
            XCTAssertEqual(data, ServiceRTFEncoder.encode(text), "non-deterministic vector \(index)")
            XCTAssertTrue(data.allSatisfy { $0 < 128 })
            #if canImport(AppKit)
            XCTAssertEqual(Array(try decode(data).utf16), Array(text.utf16), "seeded vector \(index)")
            #endif
        }
    }
}
