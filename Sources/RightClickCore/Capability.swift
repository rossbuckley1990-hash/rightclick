import Foundation

public enum CapabilitySource: String, Codable, Sendable {
    case sharingService = "sharing_service"
    case service = "service"
    case actionExtension = "action_extension"
    case system = "system"
}

public enum CapabilitySafety: String, Codable, Sendable {
    case read
    case localWrite = "local_write"
    case externalShare = "external_share"
    case destructive
    case unknown
}

public enum CapabilityInvocation: String, Codable, Sendable {
    case direct
    case interactive
    case unsupported
}

public enum SupportLevel: String, Codable, Sendable {
    case publicSupported = "public_supported"
    case publicDeprecated = "public_deprecated"
    case undocumentedReadOnly = "undocumented_read_only"
    case experimental
}

public struct CapabilityProvider: Codable, Sendable, Equatable {
    public var name: String?
    public var bundleIdentifier: String?

    public init(name: String? = nil, bundleIdentifier: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct Capability: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var source: CapabilitySource
    public var provider: CapabilityProvider?
    public var inputs: [String]
    public var output: [String]
    public var safety: CapabilitySafety
    public var invocation: CapabilityInvocation
    public var supportLevel: SupportLevel
    public var requiresConfirmation: Bool
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        source: CapabilitySource,
        provider: CapabilityProvider? = nil,
        inputs: [String] = [],
        output: [String] = [],
        safety: CapabilitySafety,
        invocation: CapabilityInvocation,
        supportLevel: SupportLevel,
        requiresConfirmation: Bool,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.provider = provider
        self.inputs = inputs
        self.output = output
        self.safety = safety
        self.invocation = invocation
        self.supportLevel = supportLevel
        self.requiresConfirmation = requiresConfirmation
        self.metadata = metadata
    }
}

public enum CapabilityID {
    public static func sharing(title: String, publicName: String?) -> String {
        if let publicName, !publicName.isEmpty {
            return "sharing:\(publicName)"
        }
        return "sharing:title:\(slug(title))"
    }

    public static func service(bundleIdentifier: String?, message: String?, menuTitle: String) -> String {
        let provider = bundleIdentifier?.isEmpty == false ? bundleIdentifier! : "unknown"
        let action = (message?.isEmpty == false ? message! : slug(menuTitle))
        return "service:\(provider):\(action)"
    }

    public static func actionExtension(bundleIdentifier: String?, path: String) -> String {
        let provider = bundleIdentifier?.isEmpty == false ? bundleIdentifier! : slug(path)
        return "action:\(provider)"
    }

    public static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "untitled" : collapsed
    }
}

public enum RunStatus: String, Codable, Sendable {
    case executed = "EXECUTED"
    case confirmationRequired = "CONFIRMATION_REQUIRED"
    case unsupported = "UNSUPPORTED"
    case failed = "FAILED"
}

public struct RunResult: Codable, Sendable {
    public var status: RunStatus
    public var actionID: String
    public var title: String?
    public var message: String
    public var output: String?
    public var requiresConfirmation: Bool
    public var supportLevel: SupportLevel?

    public init(
        status: RunStatus,
        actionID: String,
        title: String? = nil,
        message: String,
        output: String? = nil,
        requiresConfirmation: Bool = false,
        supportLevel: SupportLevel? = nil
    ) {
        self.status = status
        self.actionID = actionID
        self.title = title
        self.message = message
        self.output = output
        self.requiresConfirmation = requiresConfirmation
        self.supportLevel = supportLevel
    }
}

public func dedupeCapabilities(_ capabilities: [Capability]) -> [Capability] {
    var seen = Set<String>()
    var result: [Capability] = []
    for capability in capabilities {
        if seen.insert(capability.id).inserted {
            result.append(capability)
        }
    }
    return result
}
