import Foundation

public enum RightClickVersion {
    public static let current = "0.1.1"
}

public enum RightClickPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RIGHTCLICK", isDirectory: true)
    }

    public static var tokenFile: URL {
        supportDirectory.appendingPathComponent("token")
    }

    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}

public struct CapabilityView: Codable, Sendable {
    public var id: String
    public var title: String
    public var source: String
    public var provider: CapabilityProvider?
    public var inputTypes: [String]
    public var invocation: String
    public var safety: String
    public var requiresConfirmation: Bool
    public var supportLevel: String
    public var explanation: String

    public init(_ capability: Capability) {
        id = capability.id
        title = capability.title
        source = capability.source.rawValue
        provider = capability.provider
        inputTypes = capability.inputs
        invocation = capability.invocation.rawValue
        safety = capability.safety.rawValue
        requiresConfirmation = capability.requiresConfirmation
        supportLevel = capability.supportLevel.rawValue
        explanation = CapabilityExplanation.text(for: capability)
    }
}

public enum CapabilityExplanation {
    public static func text(for capability: Capability) -> String {
        switch capability.source {
        case .service:
            return "macOS Service “\(capability.title)”. NSPerformService reports whether the service was accepted. That Boolean is not a separate outcome check."
        case .sharingService:
            return "Sharing service “\(capability.title)”. perform(withItems:) is asynchronous. willShareItems is not completion. didShareItems reports provider completion as accepted, with external outcome unverified. didFailToShareItems means failed; no callback before the deadline means unknown."
        case .actionExtension:
            return "Action extension “\(capability.title)” was discovered from installed extension metadata. This Mac does not expose a public call to run it."
        case .system:
            return capability.title
        }
    }
}

public struct ActionList: Codable, Sendable {
    public var item: ContentItem
    public var actions: [CapabilityView]

    public init(item: ContentItem, actions: [Capability]) {
        self.item = item
        self.actions = actions.map(CapabilityView.init)
    }
}
