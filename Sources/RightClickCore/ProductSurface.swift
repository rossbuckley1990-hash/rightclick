#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum RightClickVersion {
    public static let current = "0.2.2"
}


public struct RightClickRuntimeIdentity: Codable, Sendable {
    public var platform: String = RuntimePlatform.name
    public var product: String
    public var version: String
    public var executablePath: String
    public var executableRealPath: String
    public var executableSHA256: String
    public var pid: Int
    public var transport: String

    public init(
        product: String,
        version: String,
        executablePath: String,
        executableRealPath: String,
        executableSHA256: String,
        pid: Int,
        transport: String
    ) {
        self.product = product
        self.version = version
        self.executablePath = executablePath
        self.executableRealPath = executableRealPath
        self.executableSHA256 = executableSHA256
        self.pid = pid
        self.transport = transport
    }
}

public enum RightClickRuntime {
    public static func identity(
        transport: String,
        executablePath: String? = nil,
        pid: Int? = nil
    ) -> RightClickRuntimeIdentity {
        let invokedPath = executablePath ?? self.executablePath()
        let standardPath = URL(fileURLWithPath: invokedPath).standardizedFileURL.path
        let realPath = URL(fileURLWithPath: standardPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        return RightClickRuntimeIdentity(
            product: "RIGHTCLICK",
            version: RightClickVersion.current,
            executablePath: standardPath,
            executableRealPath: realPath,
            executableSHA256: sha256File(realPath),
            pid: pid ?? Int(ProcessInfo.processInfo.processIdentifier),
            transport: transport
        )
    }

    public static func executablePath() -> String {
        let raw = CommandLine.arguments[0]

        if RuntimePlatform.isAbsolutePath(raw) {
            return URL(fileURLWithPath: raw).standardizedFileURL.path
        }

        let directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        )

        if !raw.contains("/") && !raw.contains("\\") {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""

            for component in path.split(
                separator: RuntimePlatform.pathSeparator,
                omittingEmptySubsequences: false
            ) {
                let base = component.isEmpty
                    ? directory
                    : URL(
                        fileURLWithPath: String(component),
                        relativeTo: directory
                    )

                let candidate = base
                    .appendingPathComponent(raw)
                    .standardizedFileURL
                    .path

                var isDirectory: ObjCBool = false

                if FileManager.default.fileExists(
                    atPath: candidate,
                    isDirectory: &isDirectory
                ),
                   !isDirectory.boolValue,
                   FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }

            if let executable = Bundle.main.executableURL {
                return executable.standardizedFileURL.path
            }
        }

        return directory
            .appendingPathComponent(raw)
            .standardizedFileURL
            .path
    }

    private static func sha256File(_ path: String) -> String {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: path)
        ) else {
            return "unreadable"
        }

        let digest = SHA256.hash(data: data)

        return digest
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum RightClickPaths {
    public static var supportDirectory: URL {
        RuntimePlatform.supportDirectory()
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
