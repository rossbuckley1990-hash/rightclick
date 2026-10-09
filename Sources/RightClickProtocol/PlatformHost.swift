import Foundation

public struct PlatformImageObservation {
    public let width: Int?
    public let height: Int?
    public let metadataValues: [String]?
    public init(width: Int? = nil, height: Int? = nil, metadataValues: [String]? = nil) {
        self.width = width; self.height = height; self.metadataValues = metadataValues
    }
}
public enum PlatformSecretError: Error { case unavailable, store(Int32) }

/// Host effects are below generic providers. Missing observations are unknown,
/// and unavailable secret persistence can never grant authority.
public protocol PlatformHost {
    var requiresMainThread: Bool { get }
    var plainTextDescription: String? { get }
    var urlDescription: String? { get }
    func prepareApplication()
    func refreshNativeServices()
    func fileItem(url: URL, isDirectory: Bool) -> ContentItem
    func imageObservation(path: String) -> PlatformImageObservation
    func hasXattr(path: String, key: String) -> Bool?
    func readSecret(service: String, account: String) throws -> Data?
    func containsSecret(service: String, account: String) throws -> Bool
    func writeSecret(_ data: Data, service: String, account: String) throws
    func deleteSecret(service: String, account: String) throws -> Bool
    func secretErrorDescription(_ status: Int32) -> String
}

public enum RuntimeOperatingSystem: String, Codable, Sendable { case macOS = "macos", linux, windows, other }
public enum RuntimePlatform {
    public static var operatingSystem: RuntimeOperatingSystem {
        #if os(macOS)
        return .macOS
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #else
        return .other
        #endif
    }
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "other"
        #endif
    }
    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if operatingSystem == .macOS { return home.appendingPathComponent("Library/Application Support/RIGHTCLICK", isDirectory: true) }
        let raw = environment["XDG_CONFIG_HOME"]
        let base = raw?.hasPrefix("/") == true ? URL(fileURLWithPath: raw!) : home.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("rightclick", isDirectory: true)
    }
    public static var logDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if operatingSystem == .macOS { return home.appendingPathComponent("Library/Logs/RIGHTCLICK", isDirectory: true) }
        let raw = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        let base = raw?.hasPrefix("/") == true ? URL(fileURLWithPath: raw!) : home.appendingPathComponent(".local/state", isDirectory: true)
        return base.appendingPathComponent("rightclick/logs", isDirectory: true)
    }
}

/// Compatibility requirements are never credentials or authorization grants.
public struct RuntimeRequirements: Codable, Sendable, Equatable {
    public var operatingSystems: [RuntimeOperatingSystem]
    public var architectures: [String]
    public init(operatingSystems: [RuntimeOperatingSystem] = [], architectures: [String] = []) {
        self.operatingSystems = operatingSystems; self.architectures = architectures
    }
    public func permits(os: RuntimeOperatingSystem, architecture: String) -> Bool {
        (operatingSystems.isEmpty || operatingSystems.contains(os)) &&
        (architectures.isEmpty || architectures.contains(architecture))
    }
}

public struct RuntimeEnvironment: Sendable, Equatable {
    public let operatingSystem: RuntimeOperatingSystem
    public let architecture: String
    public init(operatingSystem: RuntimeOperatingSystem, architecture: String) {
        self.operatingSystem = operatingSystem; self.architecture = architecture
    }
    public static var current: Self { .init(operatingSystem: RuntimePlatform.operatingSystem, architecture: RuntimePlatform.architecture) }
    public func supports(_ capability: Capability) -> Bool {
        capability.runtimeRequirements?.permits(os: operatingSystem, architecture: architecture) ?? true
    }
}

/// Exact authoritative snapshot bytes shared by local and remote admission.
public enum CapabilityDispatchContract {
    public static func withoutExperience(_ capability: Capability) -> Capability {
        var clean = capability; clean.metadata = clean.metadata.filter { !$0.key.hasPrefix("experience.") }; return clean
    }
    public static func canonicalData(_ capability: Capability) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(withoutExperience(capability))
    }
}
