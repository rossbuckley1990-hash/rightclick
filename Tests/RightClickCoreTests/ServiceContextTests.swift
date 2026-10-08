@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import XCTest
@testable import RightClickCore

final class ServiceContextTests: XCTestCase {
    private func record(_ context: String?, types: [String] = ["NSStringPboardType"]) -> InstalledServiceRecord {
        InstalledServiceRecord(menuTitle: "Context Test", message: "consume", bundleIdentifier: "dev.example.context",
                               bundleName: "Example", bundlePath: "/tmp/Example.app", sendTypes: types,
                               sendFileTypes: [], returnTypes: [], requiredContext: context)
    }
    private func text(_ value: String) -> ContentItem {
        ContentItem(kind: "text", display: value, text: value, typeIdentifier: "public.plain-text")
    }

    func testFilePathRequirementDoesNotApplyToOrdinaryTextOrWebURL() {
        let service = record(#"{"NSTextContent":"FilePath"}"#)
        XCTAssertFalse(ServiceCatalog.accepts(service, item: text("ordinary selected text")))
        XCTAssertFalse(ServiceCatalog.accepts(service, item: ContentItem(kind: "web_url", display: "https://example.com", url: "https://example.com", typeIdentifier: "public.url")))
        XCTAssertTrue(ServiceCatalog.accepts(service, item: ContentItem(kind: "text_file", display: "/tmp/document.txt", path: "/tmp/document.txt", typeIdentifier: "public.plain-text")))
    }

    func testUnknownAndMalformedContextAbstain() {
        for context in [#"{"FutureConstraint":"unknown"}"#, #"{"NSTextContent":"FutureContent"}"#, "null", "[]", "[1]", "invalid", #"{"NSWordLimit":"two"}"#] {
            XCTAssertFalse(ServiceCatalog.accepts(record(context), item: text("hello")), context)
        }
    }

    func testContextDictionariesAreANDAndArrayIsOR() {
        XCTAssertFalse(ServiceCatalog.accepts(record(#"{"NSTextContent":"URL","NSWordLimit":1}"#), item: text("see https://example.com")))
        XCTAssertTrue(ServiceCatalog.accepts(record(#"[{"NSTextContent":"FilePath"},{"NSWordLimit":1}]"#), item: text("hello")))
        XCTAssertFalse(ServiceCatalog.accepts(record(#"[{"NSTextContent":"FilePath"},{"NSWordLimit":1}]"#), item: text("two words")))
        XCTAssertTrue(ServiceCatalog.accepts(record("{}"), item: text("hello")))
    }

    func testApplicationContextUsesActualHostAndDoesNotInventSelectionLanguage() {
        XCTAssertFalse(ServiceCatalog.accepts(record(#"{"NSApplicationIdentifier":"dev.example.unrelated-host"}"#), item: text("hello")))
        for context in [#"{"NSTextLanguage":"en"}"#, #"{"NSTextScript":"Latn"}"#] {
            XCTAssertFalse(ServiceCatalog.accepts(record(context), item: text("hello")))
        }
    }

    func testUndeclaredEncodingsCannotBecomeApplicableThroughSubstringMatching() {
        for unsupported in ["dev.example.fake-text", "public.html", "public.rtfd", "NSRTFDPboardType"] {
            XCTAssertFalse(ServiceCatalog.accepts(record(nil, types: [unsupported]), item: text("hello")), unsupported)
        }
    }

    func testFilePathContextEncodesPathRatherThanReadingFileContents() throws {
        let file = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("context-\(UUID().uuidString).txt").standardizedFileURL
        try Data("THE FILE CONTENTS MUST NOT BE THE PATH PAYLOAD".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = try ContentParser.parse(file.path)
        let service = record(#"{"NSTextContent":"FilePath"}"#, types: ["NSURLPboardType", "NSStringPboardType"])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(ServiceCatalog.preparePasteboard(board, item: item, record: service))
        XCTAssertEqual(board.string(forType: .init("NSStringPboardType")), file.path)
        XCTAssertEqual(board.string(forType: .init("NSURLPboardType")), file.absoluteString)
        XCTAssertFalse(board.types?.contains(.init("public.file-url")) ?? false)
    }

    func testDuplicateMenuNamesCannotChooseTheWrongProvider() {
        let first = record(nil)
        var second = first
        second.bundleIdentifier = "dev.example.other"
        second.bundlePath = "/tmp/Other.app"
        let actions = ServiceCatalog.capabilities(for: text("hello"), records: [first, second])
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions.allSatisfy { $0.invocation == .unsupported })
    }

    func testBundlelessWorkflowPathsPreventSharedMessageIdentityCollision() {
        var first = record(nil)
        first.menuTitle = "Workflow One"
        first.message = "runWorkflowAsService"
        first.bundleIdentifier = nil
        first.bundleName = nil
        first.bundlePath = "/tmp/Workflow One.workflow"

        var second = first
        second.menuTitle = "Workflow Two"
        second.bundlePath = "/tmp/Workflow Two.workflow"

        let actions = ServiceCatalog.capabilities(
            for: text("hello"),
            records: [first, second]
        )

        XCTAssertEqual(actions.count, 2)

        // Different installed providers must have different capability identities,
        // even when Automator gives both the same NSMessage.
        XCTAssertEqual(Set(actions.map(\.id)).count, 2)

        // Different titles + different provider paths are safely distinguishable.
        XCTAssertTrue(actions.allSatisfy { $0.invocation != .unsupported })
    }
}
