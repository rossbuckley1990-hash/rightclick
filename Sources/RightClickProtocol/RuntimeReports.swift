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
}
