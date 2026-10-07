import Foundation

/// Host facts, not provider authority. Paths are computed without creating files.
public enum RuntimeOperatingSystem: String, Codable, Sendable {
    case macOS = "macos", linux, windows, other
}
public enum RuntimePlatform {
    public static var operatingSystem: RuntimeOperatingSystem {
#if os(macOS)
        .macOS
#elseif os(Linux)
        .linux
#elseif os(Windows)
        .windows
#else
        .other
#endif
    }
    public static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "other"
#endif
    }
    public static func supportDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: RuntimeOperatingSystem = operatingSystem
    ) -> URL {
        switch platform {
        case .macOS:
            return home.appendingPathComponent("Library/Application Support/RIGHTCLICK", isDirectory: true)
        case .windows:
            return absoluteDirectory(environment["APPDATA"], platform: platform,
                fallback: home.appendingPathComponent("AppData/Roaming", isDirectory: true))
                .appendingPathComponent("RIGHTCLICK", isDirectory: true)
        case .linux, .other:
            return absoluteDirectory(environment["XDG_CONFIG_HOME"], platform: platform,
                fallback: home.appendingPathComponent(".config", isDirectory: true))
                .appendingPathComponent("rightclick", isDirectory: true)
        }
    }
    public static func logDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: RuntimeOperatingSystem = operatingSystem
    ) -> URL {
        switch platform {
        case .macOS:
            return home.appendingPathComponent("Library/Logs/RIGHTCLICK", isDirectory: true)
        case .windows:
            return absoluteDirectory(environment["LOCALAPPDATA"], platform: platform,
                fallback: home.appendingPathComponent("AppData/Local", isDirectory: true))
                .appendingPathComponent("RIGHTCLICK/Logs", isDirectory: true)
        case .linux, .other:
            return absoluteDirectory(environment["XDG_STATE_HOME"], platform: platform,
                fallback: home.appendingPathComponent(".local/state", isDirectory: true))
                .appendingPathComponent("rightclick/logs", isDirectory: true)
        }
    }
    private static func absoluteDirectory(_ raw: String?, platform: RuntimeOperatingSystem, fallback: URL) -> URL {
        guard let raw, !raw.isEmpty, !raw.contains("\0"),
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else { return fallback }
        let absolute: Bool
        if platform == .windows {
            absolute = raw.range(of: #"^[A-Za-z]:[\\/]|^\\\\[^\\]+\\[^\\]+"#, options: .regularExpression) != nil
        } else {
            absolute = raw.hasPrefix("/")
        }
        return absolute ? URL(fileURLWithPath: raw, isDirectory: true) : fallback
    }
    public static func report() -> RuntimePlatformReport {
        RuntimePlatformReport(platform: operatingSystem.rawValue, architecture: architecture,
            networkCapabilityKinds: CapabilityArtifactResolverRegistry().supportedKinds,
            nativeDesktopServices: operatingSystem == .macOS,
            bonjourDiscovery: operatingSystem == .macOS,
            nativeCredentialStore: operatingSystem == .macOS,
            httpListener: operatingSystem == .macOS || operatingSystem == .linux,
            imageMetadataVerification: operatingSystem == .macOS,
            fileAndTextVerification: true,
            note: "Build feature inventory, not proof of provider availability or a security attestation.")
    }
}
public struct RuntimePlatformReport: Codable, Sendable {
    public let platform: String
    public let architecture: String
    public let networkCapabilityKinds: [String]
    public let nativeDesktopServices: Bool
    public let bonjourDiscovery: Bool
    public let nativeCredentialStore: Bool
    public let httpListener: Bool
    public let imageMetadataVerification: Bool
    public let fileAndTextVerification: Bool
    public let note: String
}
#if !os(macOS)
// A headless machine has no native macOS capability catalog. Do not invent one.
enum CapabilityReflectorDefaults {
    static func all() -> [any CapabilityReflector] { [] }
}
#endif

