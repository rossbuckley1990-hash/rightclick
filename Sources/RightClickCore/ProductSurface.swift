#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum RightClickVersion {
    public static let current = "0.2.2"
}

/// Versioned substrate-independent agent contract. Profiles are advertised by
/// the runtime; no extra negotiation tool or provider operation is introduced.
public struct RightClickAgentABIProfile: Codable, Sendable {
    public let id: String
    public let version: Int
    public let operations: [String]

    public static let core = Self(id: "core", version: 1, operations: [
        "context_runtime", "context_providers", "context_inspect", "context_actions",
        "context_explain", "context_run", "context_run_status",
    ])
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
    public var agentABIProfiles: [RightClickAgentABIProfile]?
    public var channel: String = "unverified"
    public var gitCommit: String?
    public var sourceRepository: String?
    public var sourceDirty: Bool?
    public var buildSHA256: String?
    public var capabilityABIVersion: Int?
    public var contractSchemaVersion: Int?
    public var mcpSchemaVersion: Int?
    public var executableMeasurement: String?

    public init(
        product: String,
        version: String,
        executablePath: String,
        executableRealPath: String,
        executableSHA256: String,
        pid: Int,
        transport: String,
        agentABIProfiles: [RightClickAgentABIProfile]? = nil
    ) {
        self.product = product
        self.version = version
        self.executablePath = executablePath
        self.executableRealPath = executableRealPath
        self.executableSHA256 = executableSHA256
        self.pid = pid
        self.transport = transport
        self.agentABIProfiles = agentABIProfiles
    }

    private enum CodingKeys: String, CodingKey {
        case platform, product, version, executablePath, executableRealPath
        case executableSHA256, pid, transport, agentABIProfiles
        case channel, gitCommit, sourceRepository, sourceDirty, buildSHA256
        case capabilityABIVersion, contractSchemaVersion, mcpSchemaVersion, executableMeasurement
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        // A legacy remote did not attest its platform or ABI profile. Preserve
        // compatibility without filling that absence with local host facts.
        platform = try fields.decodeIfPresent(String.self, forKey: .platform) ?? "unknown"
        product = try fields.decode(String.self, forKey: .product)
        version = try fields.decode(String.self, forKey: .version)
        executablePath = try fields.decode(String.self, forKey: .executablePath)
        executableRealPath = try fields.decode(String.self, forKey: .executableRealPath)
        executableSHA256 = try fields.decode(String.self, forKey: .executableSHA256)
        pid = try fields.decode(Int.self, forKey: .pid)
        transport = try fields.decode(String.self, forKey: .transport)
        agentABIProfiles = try fields.decodeIfPresent([RightClickAgentABIProfile].self, forKey: .agentABIProfiles)
        channel = try fields.decodeIfPresent(String.self, forKey: .channel) ?? "unverified"
        gitCommit = try fields.decodeIfPresent(String.self, forKey: .gitCommit)
        sourceRepository = try fields.decodeIfPresent(String.self, forKey: .sourceRepository)
        sourceDirty = try fields.decodeIfPresent(Bool.self, forKey: .sourceDirty)
        buildSHA256 = try fields.decodeIfPresent(String.self, forKey: .buildSHA256)
        capabilityABIVersion = try fields.decodeIfPresent(Int.self, forKey: .capabilityABIVersion)
        contractSchemaVersion = try fields.decodeIfPresent(Int.self, forKey: .contractSchemaVersion)
        mcpSchemaVersion = try fields.decodeIfPresent(Int.self, forKey: .mcpSchemaVersion)
        executableMeasurement = try fields.decodeIfPresent(String.self, forKey: .executableMeasurement)
    }
}

public enum RightClickRuntime {
    // Capture once before serving. A later launcher symlink change must not
    // make an existing process report another executable's identity.
    private static let startupIdentity = measuredIdentity(
        transport: "unknown", executablePath: executablePath(),
        pid: Int(ProcessInfo.processInfo.processIdentifier)
    )

    public static func captureStartupIdentity() { _ = startupIdentity }

    public static func identity(
        transport: String,
        executablePath: String? = nil,
        pid: Int? = nil
    ) -> RightClickRuntimeIdentity {
        if executablePath == nil && pid == nil {
            var result = startupIdentity
            result.transport = transport
            return result
        }
        return measuredIdentity(transport: transport,
            executablePath: executablePath ?? self.executablePath(),
            pid: pid ?? Int(ProcessInfo.processInfo.processIdentifier))
    }

    private static func measuredIdentity(transport: String, executablePath: String,
                                         pid: Int) -> RightClickRuntimeIdentity {
        let invokedPath = executablePath
        let standardPath = URL(fileURLWithPath: invokedPath).standardizedFileURL.path
        let realPath = URL(fileURLWithPath: standardPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        var identity = RightClickRuntimeIdentity(
            product: "RIGHTCLICK",
            version: RightClickVersion.current,
            executablePath: standardPath,
            executableRealPath: realPath,
            executableSHA256: sha256File(realPath),
            pid: pid,
            transport: transport,
            agentABIProfiles: [.core]
        )
        identity.channel = RightClickBuildProvenance.channel
        identity.gitCommit = RightClickBuildProvenance.gitCommit
        identity.sourceRepository = RightClickBuildProvenance.sourceRepository
        identity.sourceDirty = RightClickBuildProvenance.sourceDirty
        identity.buildSHA256 = identity.executableSHA256
        identity.capabilityABIVersion = 1
        identity.contractSchemaVersion = CapabilityContract.version
        identity.mcpSchemaVersion = 1
        identity.executableMeasurement = "startup-file-bytes"
        return identity
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
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "unreadable" }
        defer { try? handle.close() }
        do {
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return "unreadable" }
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
