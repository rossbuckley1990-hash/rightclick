import Foundation

public struct ProviderSummary: Codable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var source: String
    public var capabilityTitles: [String]

    public init(
        name: String,
        bundleIdentifier: String? = nil,
        source: String,
        capabilityTitles: [String]
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.source = source
        self.capabilityTitles = capabilityTitles
    }
}

public struct DoctorReport: Codable, Sendable {
    public var platform: String = RuntimePlatform.name
    public var operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    public var macosVersion: String
    public var macosBuild: String
    public var sharingDiscovery: String
    public var sharingExecution: String
    public var sharingSupportLevel: String
    public var servicesDiscovery: String
    public var servicesExecution: String
    public var servicesSupportLevel: String
    public var quickActionDiscovery: String
    public var quickActionExecution: String
    public var quickActionSupportLevel: String
    public var serviceRegistrationCount: Int
    public var actionExtensionCount: Int
    public var notes: [String]
    public init(macosVersion: String, macosBuild: String, sharingDiscovery: String, sharingExecution: String, sharingSupportLevel: String, servicesDiscovery: String, servicesExecution: String, servicesSupportLevel: String, quickActionDiscovery: String, quickActionExecution: String, quickActionSupportLevel: String, serviceRegistrationCount: Int, actionExtensionCount: Int, notes: [String]) {
        self.macosVersion = macosVersion
        self.macosBuild = macosBuild
        self.sharingDiscovery = sharingDiscovery
        self.sharingExecution = sharingExecution
        self.sharingSupportLevel = sharingSupportLevel
        self.servicesDiscovery = servicesDiscovery
        self.servicesExecution = servicesExecution
        self.servicesSupportLevel = servicesSupportLevel
        self.quickActionDiscovery = quickActionDiscovery
        self.quickActionExecution = quickActionExecution
        self.quickActionSupportLevel = quickActionSupportLevel
        self.serviceRegistrationCount = serviceRegistrationCount
        self.actionExtensionCount = actionExtensionCount
        self.notes = notes
    }
    private enum CodingKeys: String, CodingKey {
        case platform, operatingSystemVersion, macosVersion, macosBuild
        case sharingDiscovery, sharingExecution, sharingSupportLevel
        case servicesDiscovery, servicesExecution, servicesSupportLevel
        case quickActionDiscovery, quickActionExecution, quickActionSupportLevel
        case serviceRegistrationCount, actionExtensionCount, notes
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            macosVersion: try fields.decode(String.self, forKey: .macosVersion),
            macosBuild: try fields.decode(String.self, forKey: .macosBuild),
            sharingDiscovery: try fields.decode(String.self, forKey: .sharingDiscovery),
            sharingExecution: try fields.decode(String.self, forKey: .sharingExecution),
            sharingSupportLevel: try fields.decode(String.self, forKey: .sharingSupportLevel),
            servicesDiscovery: try fields.decode(String.self, forKey: .servicesDiscovery),
            servicesExecution: try fields.decode(String.self, forKey: .servicesExecution),
            servicesSupportLevel: try fields.decode(String.self, forKey: .servicesSupportLevel),
            quickActionDiscovery: try fields.decode(String.self, forKey: .quickActionDiscovery),
            quickActionExecution: try fields.decode(String.self, forKey: .quickActionExecution),
            quickActionSupportLevel: try fields.decode(String.self, forKey: .quickActionSupportLevel),
            serviceRegistrationCount: try fields.decode(Int.self, forKey: .serviceRegistrationCount),
            actionExtensionCount: try fields.decode(Int.self, forKey: .actionExtensionCount),
            notes: try fields.decode([String].self, forKey: .notes))
        // Older reports contain no portable host facts. Decoding must not fill
        // that absence with this reader's platform or operating-system version.
        platform = try fields.decodeIfPresent(String.self, forKey: .platform) ?? "unknown"
        operatingSystemVersion = try fields.decodeIfPresent(String.self, forKey: .operatingSystemVersion) ?? "unknown"
    }

}
