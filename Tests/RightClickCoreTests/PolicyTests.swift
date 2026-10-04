import XCTest
@testable import RightClickCore

final class PolicyTests: XCTestCase {
    func testSharingIdentifierUsesPublicName() {
        let id = CapabilityID.sharing(title: "AirDrop", publicName: "com.apple.share.AirDrop.send")
        XCTAssertEqual(id, "sharing:com.apple.share.AirDrop.send")
        XCTAssertEqual(CapabilityID.sharing(title: "AirDrop", publicName: "com.apple.share.AirDrop.send"), id)
    }

    func testSharingIdentifierFallsBackToTitleSlug() {
        XCTAssertEqual(CapabilityID.sharing(title: "Add to Notes", publicName: nil), "sharing:title:add-to-notes")
    }

    func testServiceIdentifierPrefersMessage() {
        XCTAssertEqual(
            CapabilityID.service(bundleIdentifier: "com.apple.ChineseTextConverterService", message: "convertTextToFullWidth", menuTitle: "Convert Text to Full Width"),
            "service:com.apple.ChineseTextConverterService:convertTextToFullWidth"
        )
    }

    func testExternalShareRequiresConfirmation() {
        let policy = SafetyPolicy.classify(title: "AirDrop", source: .sharingService, publicName: "com.apple.share.AirDrop.send")
        XCTAssertEqual(policy.safety, .externalShare)
        XCTAssertTrue(policy.requiresConfirmation)
    }

    func testTextTransformDoesNotRequireConfirmation() {
        let policy = SafetyPolicy.classify(
            title: "Convert Text to Full Width",
            source: .service,
            sendTypes: ["public.utf8-plain-text"],
            returnTypes: ["public.utf8-plain-text"]
        )
        XCTAssertEqual(policy.safety, .read)
        XCTAssertEqual(policy.invocation, .direct)
        XCTAssertFalse(policy.requiresConfirmation)
    }

    func testDestructiveRequiresConfirmation() {
        let policy = SafetyPolicy.classify(title: "Move to Trash", source: .service)
        XCTAssertEqual(policy.safety, .destructive)
        XCTAssertTrue(policy.requiresConfirmation)
    }

    func testActionExtensionIsNotInvokable() {
        let policy = SafetyPolicy.classify(title: "Markup", source: .actionExtension)
        XCTAssertEqual(policy.invocation, .unsupported)
        XCTAssertTrue(policy.requiresConfirmation)
    }

    func testDedupeKeepsFirstIdentifier() {
        let first = Capability(
            id: "sharing:example",
            title: "Example",
            source: .sharingService,
            safety: .unknown,
            invocation: .interactive,
            supportLevel: .publicDeprecated,
            requiresConfirmation: true
        )
        var second = first
        second.title = "Other"
        XCTAssertEqual(dedupeCapabilities([first, second]).map(\.title), ["Example"])
    }

    func testContentClassification() throws {
        let text = try ContentParser.parse("hello rightclick")
        XCTAssertEqual(text.kind, "text")
        XCTAssertEqual(text.typeIdentifier, "public.plain-text")

        let url = try ContentParser.parse("https://example.com/rightclick")
        XCTAssertEqual(url.kind, "web_url")
        XCTAssertEqual(url.typeIdentifier, "public.url")

        let missing = "/tmp/rightclick-does-not-exist-\(UUID().uuidString).jpg"
        XCTAssertThrowsError(try ContentParser.parse(missing))
    }
}
