import XCTest
@testable import RightClickCore

final class AcquisitionTests: XCTestCase {
    func testServiceAppearsAndDisappearsWithTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-test-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Example.service")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "dev.example.dynamic",
            "CFBundleName": "Example",
            "NSServices": [[
                "NSMenuItem": ["default": "Example Sidecar"],
                "NSMessage": "makeSidecar",
                "NSSendFileTypes": ["public.image"],
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let image = ContentItem(kind: "image", display: "x", path: "/tmp/x.jpg", typeIdentifier: "public.jpeg")
        let found = ServiceCatalog.capabilities(for: image, records: ServiceCatalog.records(roots: [root]))
        XCTAssertEqual(found.map(\.id), ["service:dev.example.dynamic:makeSidecar"])
        try FileManager.default.removeItem(at: app)
        let gone = ServiceCatalog.capabilities(for: image, records: ServiceCatalog.records(roots: [root]))
        XCTAssertTrue(gone.isEmpty)
    }

    func testWebURLPayloadUsesDeclaredURLType() {
        let address = "https://example.com/rightclick-test"
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(ServiceCatalog.prepareWebURLPasteboard(pasteboard, url: address, declaredSendTypes: ["public.url"]))
        XCTAssertEqual(pasteboard.string(forType: NSPasteboard.PasteboardType("public.url")), address)
        pasteboard.releaseGlobally()
    }

    func testWebURLPayloadUsesDeclaredPlainTextType() {
        let address = "https://example.com/rightclick-test"
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(ServiceCatalog.prepareWebURLPasteboard(
            pasteboard,
            url: address,
            declaredSendTypes: ["public.utf8-plain-text", "NSStringPboardType", "public.plain-text"]
        ))
        for raw in ["public.utf8-plain-text", "NSStringPboardType", "public.plain-text"] {
            XCTAssertEqual(pasteboard.string(forType: NSPasteboard.PasteboardType(raw)), address, raw)
        }
        pasteboard.releaseGlobally()
    }

    func testWebURLPayloadAbstainsForFileURLOnly() {
        let address = "https://example.com/rightclick-test"
        let record = InstalledServiceRecord(
            menuTitle: "Open File",
            message: "openFile",
            bundleIdentifier: "dev.example.files",
            bundleName: "Files",
            bundlePath: "/tmp/Files.app",
            sendTypes: ["public.file-url"],
            sendFileTypes: [],
            returnTypes: [],
            requiredContext: nil
        )
        let item = ContentItem(kind: "web_url", display: address, url: address, typeIdentifier: "public.url")
        XCTAssertFalse(ServiceCatalog.accepts(record, item: item))
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertFalse(ServiceCatalog.prepareWebURLPasteboard(pasteboard, url: address, declaredSendTypes: ["public.file-url"]))
        pasteboard.releaseGlobally()
    }

    func testProofURLPayloadRoundTrip() {
        let address = "https://example.com/rightclick-yojam-proof"
        let declared = ["public.url", "public.rtf", "public.utf8-plain-text", "NSStringPboardType", "public.plain-text"]
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(ServiceCatalog.prepareWebURLPasteboard(pasteboard, url: address, declaredSendTypes: declared))
        for raw in ["public.url", "public.utf8-plain-text", "NSStringPboardType", "public.plain-text"] {
            XCTAssertEqual(pasteboard.string(forType: NSPasteboard.PasteboardType(raw)), address, raw)
        }
        let rtf = pasteboard.data(forType: NSPasteboard.PasteboardType("public.rtf"))
        XCTAssertGreaterThan(rtf?.count ?? 0, 0)
        pasteboard.releaseGlobally()
    }

    func testTextPasteboardTypesFollowDeclaredSendTypes() {
        let types = ServiceCatalog.pasteboardTypesForText(declaredSendTypes: [
            "NSStringPboardType",
            "public.plain-text",
        ]).map(\.rawValue)
        XCTAssertEqual(types, ["NSStringPboardType", "public.plain-text"])
    }

    func testDeclaredTextRepresentationsRoundTripOnThePasteboard() {
        let fixture = "RIGHTCLICK BBEdit payload proof 84721"
        let record = InstalledServiceRecord(
            menuTitle: "Example Text",
            message: "openSelection",
            bundleIdentifier: "dev.example.text",
            bundleName: "Example",
            bundlePath: "/tmp/Example.app",
            sendTypes: ["NSStringPboardType", "public.plain-text"],
            sendFileTypes: [],
            returnTypes: [],
            requiredContext: nil
        )
        let pasteboard = NSPasteboard.withUniqueName()
        ServiceCatalog.prepareTextPasteboard(pasteboard, text: fixture, declaredSendTypes: record.sendTypes)
        let written = (pasteboard.types ?? []).map(\.rawValue)
        XCTAssertTrue(written.contains("NSStringPboardType"))
        XCTAssertTrue(written.contains("public.plain-text"))
        for raw in ["NSStringPboardType", "public.plain-text"] {
            XCTAssertEqual(pasteboard.string(forType: NSPasteboard.PasteboardType(raw)), fixture, raw)
        }
        pasteboard.releaseGlobally()
    }

    func testImageServiceDoesNotApplyToPlainText() throws {
        let record = InstalledServiceRecord(
            menuTitle: "Example Sidecar",
            message: "makeSidecar",
            bundleIdentifier: "dev.example.dynamic",
            bundleName: "Example",
            bundlePath: "/tmp/Example.service",
            sendTypes: [],
            sendFileTypes: ["public.image"],
            returnTypes: [],
            requiredContext: nil
        )
        let image = ContentItem(kind: "image", display: "x", path: "/tmp/x.jpg", typeIdentifier: "public.jpeg")
        let text = ContentItem(kind: "text", display: "hello", text: "hello", typeIdentifier: "public.plain-text")
        XCTAssertTrue(ServiceCatalog.accepts(record, item: image))
        XCTAssertFalse(ServiceCatalog.accepts(record, item: text))
    }

    func testDuplicateIDsCollapse() {
        let capability = Capability(
            id: "service:dev.example:one",
            title: "One",
            source: .service,
            safety: .unknown,
            invocation: .interactive,
            supportLevel: .publicSupported,
            requiresConfirmation: true
        )
        XCTAssertEqual(dedupeCapabilities([capability, capability]).count, 1)
    }

    func testUnknownRequiresConfirmation() {
        let policy = SafetyPolicy.classify(title: "Do Something", source: .service)
        XCTAssertEqual(policy.safety, .unknown)
        XCTAssertTrue(policy.requiresConfirmation)
    }

    func testFinancialRequiresConfirmation() {
        let policy = SafetyPolicy.classify(title: "Checkout", source: .service, publicName: "purchase")
        XCTAssertEqual(policy.safety, .financial)
        XCTAssertTrue(policy.requiresConfirmation)
    }

    func testStaleServiceIDFails() {
        let item = ContentItem(kind: "text", display: "hello", text: "hello", typeIdentifier: "public.plain-text")
        let result = ServiceCatalog.perform(capabilityID: "service:missing.provider:nope", item: item)
        XCTAssertEqual(result.status, .failed)
    }

    func testDirectoryAndURLClassification() throws {
        let directory = FileManager.default.temporaryDirectory
        let parsed = try ContentParser.parse(directory.path)
        XCTAssertTrue(parsed.isDirectory || parsed.kind == "directory")
        let url = try ContentParser.parse("https://example.com/rightclick")
        XCTAssertEqual(url.kind, "web_url")
    }

    func testMalformedPathIsAnError() {
        XCTAssertThrowsError(try ContentParser.parse("/tmp/rightclick-missing-\(UUID().uuidString).jpg"))
    }
}
