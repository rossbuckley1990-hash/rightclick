// TEST DOUBLES ONLY. Never compiled by the product's SwiftPM target.
// This lets the original engine's selection and admission paths run on Linux.
// Native macOS integrations, Keychain and verification are NOT implemented.
import Foundation

public struct RightClickError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct ContentItem: Codable, Sendable {
    public var kind: String
    public var display: String
    public var text: String?
    public var typeIdentifier: String?
    public init(kind: String, display: String, text: String? = nil, typeIdentifier: String? = nil) {
        self.kind = kind; self.display = display; self.text = text; self.typeIdentifier = typeIdentifier
    }
}
enum ContentParser {
    static func parse(_ text: String) throws -> ContentItem {
        .init(kind: "text", display: text, text: text, typeIdentifier: "public.plain-text")
    }
}
final class NSApplication: @unchecked Sendable {
    enum Policy { case prohibited, accessory }
    static let shared = NSApplication()
    func activationPolicy() -> Policy { .accessory }
    func setActivationPolicy(_ policy: Policy) {}
}
func NSUpdateDynamicServices() {}
func pthread_main_np() -> Int32 { 0 }
public typealias CapabilityArguments = [String: String]
public protocol CapabilityReflector: AnyObject {
    var id: String { get }
    var completionWaitSeconds: TimeInterval { get }
    func capabilities(for item: ContentItem) throws -> [Capability]
    func providers() -> [ProviderSummary]
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord
    func begin(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?) throws -> ExecutionRecord
}
public extension CapabilityReflector {
    var completionWaitSeconds: TimeInterval { 0 }
    func providers() -> [ProviderSummary] { [] }
    func begin(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?) throws -> ExecutionRecord {
        try begin(capability: capability, item: item, executionID: executionID)
    }
}
public protocol CapabilityVerificationReflector: CapabilityReflector {
    func begin(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?, verification: VerificationSpec) throws -> ExecutionRecord
}
public protocol CapabilityReflectorSource { func reflectors() -> [any CapabilityReflector] }
public protocol ContextualCapabilityReflectorSource: CapabilityReflectorSource {
    func reflectors(for item: ContentItem) -> [any CapabilityReflector]
}
enum CapabilityReflectorDefaults { static func all() -> [any CapabilityReflector] { [] } }
enum CapabilityReflectorID {
    static let macOSService = "macos.service"
    static let macOSActionExtension = "macos.action-extension"
}
public enum CapabilityID {
    public static func actionExtension(bundleIdentifier: String?, path: String) -> String { "stub:" + (bundleIdentifier ?? path) }
}
enum ServiceCatalog {
    static func records() -> [Int] { [] }
    static func capabilities(for item: ContentItem) -> [Capability] { [] }
}
struct StubAction { var bundleIdentifier: String?; var bundlePath: String; var name: String? }
enum ActionExtensionCatalog { static func records() -> [StubAction] { [] } }
enum SharingCatalog { static func capabilities(for item: ContentItem) -> [Capability] { [] } }
public struct VerificationSpec: Codable, Sendable {}
public struct OutcomeSnapshot: Codable, Sendable {}
public struct OutcomeVerification: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case verifiedSuccess, verifiedFailure, unverified, abstained }
    public var status: Status
}
enum OutcomeVerifier {
    static func snapshot(item: ContentItem) throws -> OutcomeSnapshot {
        throw RightClickError("OS snapshot is outside this source-slice harness")
    }
    static func verifyEventually(spec: VerificationSpec, item: ContentItem, before: OutcomeSnapshot, returnedText: String?) throws -> OutcomeVerification {
        throw RightClickError("Outcome verification is outside this source-slice harness")
    }
}
