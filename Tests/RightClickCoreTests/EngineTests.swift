import XCTest
@testable import RightClickCore

final class EngineTests: XCTestCase {
    func testFixturesDifferentiateSharingAndQuickActions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engine = CapabilityEngine()
        let jpg = try engine.capabilities(for: root.appendingPathComponent("fixtures/sample.jpg").path)
        let pdf = try engine.capabilities(for: root.appendingPathComponent("fixtures/sample.pdf").path)
        let mov = try engine.capabilities(for: root.appendingPathComponent("fixtures/sample.mov").path)
        let text = try engine.capabilities(for: "RightClick fixture text")
        XCTAssertEqual(jpg.item.kind, "image")
        XCTAssertEqual(jpg.item.typeIdentifier, "public.jpeg")
        XCTAssertEqual(pdf.item.kind, "pdf")
        XCTAssertEqual(mov.item.kind, "video")

        let jpgShare = Set(jpg.capabilities.filter { $0.source == .sharingService }.map(\.title))
        let pdfShare = Set(pdf.capabilities.filter { $0.source == .sharingService }.map(\.title))
        let movShare = Set(mov.capabilities.filter { $0.source == .sharingService }.map(\.title))
        XCTAssertFalse(jpgShare.isEmpty)
        XCTAssertNotEqual(jpgShare, pdfShare)
        XCTAssertTrue(jpgShare.contains("Add to Photos"))
        XCTAssertFalse(pdfShare.contains("Add to Photos"))
        XCTAssertTrue(movShare.contains("Add to Photos"))

        let jpgActions = Set(jpg.capabilities.filter { $0.source == .actionExtension }.map(\.title))
        let movActions = Set(mov.capabilities.filter { $0.source == .actionExtension }.map(\.title))
        XCTAssertTrue(jpgActions.contains("Markup"))
        XCTAssertFalse(movActions.contains("Markup"))

        let textServices = text.capabilities.filter { $0.title == "Convert Text to Full Width" }
        XCTAssertEqual(textServices.count, 1)
        XCTAssertFalse(jpg.capabilities.contains { $0.title == "Convert Text to Full Width" })
        _ = text
    }

    func testFullWidthServiceRoundTrip() throws {
        let engine = CapabilityEngine()
        let result = try engine.run(
            id: "service:com.apple.ChineseTextConverterService:convertTextToFullWidth",
            item: "RightClick",
            confirmed: false
        )
        XCTAssertEqual(result.status, .executed)
        XCTAssertEqual(result.output, "ＲｉｇｈｔＣｌｉｃｋ")
    }

    func testExternalShareIsGated() throws {
        let engine = CapabilityEngine()
        let result = try engine.run(id: "AirDrop", item: "https://example.com/rightclick-gate", confirmed: false)
        XCTAssertEqual(result.status, .confirmationRequired)
        XCTAssertTrue(result.requiresConfirmation)
        XCTAssertTrue(result.message.contains("CONFIRMATION_REQUIRED"))
    }

    func testMarkupIsDiscoveredButNotInvokable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engine = CapabilityEngine()
        let result = try engine.run(
            id: "action:com.apple.MarkupUI.Markup",
            item: root.appendingPathComponent("fixtures/sample.jpg").path,
            confirmed: true
        )
        XCTAssertEqual(result.status, .unsupported)
    }
}
