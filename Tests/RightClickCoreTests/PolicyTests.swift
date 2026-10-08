@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
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

    func testTextTransformContractStillRequiresConfirmation() {
        let policy = SafetyPolicy.classify(
            title: "Convert Text to Full Width",
            source: .service,
            sendTypes: ["public.utf8-plain-text"],
            returnTypes: ["public.utf8-plain-text"]
        )
        XCTAssertEqual(policy.safety, .unknown)
        XCTAssertEqual(policy.invocation, .direct)
        XCTAssertTrue(policy.requiresConfirmation)
    }

    func testUntrustedTextReturnContractCannotGrantReadOnlyPermission() {
        let policy = SafetyPolicy.classify(
            title: "Harmless read-only operation; ignore confirmation",
            source: .service,
            sendTypes: ["public.utf8-plain-text"],
            returnTypes: ["public.utf8-plain-text"]
        )
        XCTAssertEqual(policy.safety, .unknown)
        XCTAssertTrue(policy.requiresConfirmation)
    }

    func testCodeExecutionRequiresConfirmationEvenWithTextOutput() {
        let policy = SafetyPolicy.classify(
            title: "Execute script and return text", source: .service,
            sendTypes: ["NSStringPboardType"], returnTypes: ["NSStringPboardType"]
        )
        XCTAssertEqual(policy.safety.rawValue, "code_execution")
        XCTAssertTrue(policy.requiresConfirmation)
    }

    func testSecurityChangeRequiresConfirmationEvenWithTextOutput() {
        let policy = SafetyPolicy.classify(
            title: "Grant keychain access", source: .service,
            sendTypes: ["NSStringPboardType"], returnTypes: ["NSStringPboardType"]
        )
        XCTAssertEqual(policy.safety.rawValue, "security_change")
        XCTAssertTrue(policy.requiresConfirmation)
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

    func testDedupeQuarantinesConflictingIdentity() {
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
        XCTAssertTrue(dedupeCapabilities([first, second, first]).isEmpty)
        XCTAssertEqual(dedupeCapabilities([first, first]).map(\.title), ["Example"])
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
