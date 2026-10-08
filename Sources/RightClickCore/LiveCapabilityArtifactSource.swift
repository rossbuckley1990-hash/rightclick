import Foundation

/// Session-scoped acquisition through ordinary capabilities, not new MCP tools.
/// This source owns descriptors; existing resolvers still own protocol handling.
public final class LiveCapabilityArtifactSource: CapabilityReflectorSource, CapabilityReflector {
    public static let acquireID = "system:acquire-capability-contract"
    public static let statusID = "system:capability-acquisition-status"
    public static let forgetID = "system:forget-capability-contract"
    public static let statusItem = "rightclick:acquisition"
    public let id = "live.capability-artifacts"

    public struct Diagnostic: Codable, Equatable {
        public let artifactID: String
        public let kind: String
        public let status: String
        public let capabilityCount: Int
    }

    private struct Entry {
        let descriptor: CapabilityArtifactDescriptor
        var reflector: (any CapabilityReflector)?
        var expiresAt: TimeInterval = 0
        var diagnostic: Diagnostic
    }

    private struct Failure: Error { let code: String }
    private let lock = NSLock()
    private let registry: CapabilityArtifactResolverRegistry
    private let clock: () -> TimeInterval
    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]
    private var configurationDiagnostics: [Diagnostic] = []
    private static let maximumEntries = 64

    public init(
        registry: CapabilityArtifactResolverRegistry = CapabilityArtifactResolverRegistry(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        lifetime: TimeInterval = 5,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.registry = registry
        self.clock = clock
        self.lifetime = max(0, min(lifetime, 300))
        // Preserve environment acquisition, but do not turn malformed input into
        // an indistinguishable empty graph. No network operation occurs here.
        if let raw = environment[ConfiguredCapabilityArtifactSource.environmentKey] {
            do {
                guard raw.utf8.count <= 262_144 else { throw Failure(code: "invalid_configuration") }
                let descriptors = try JSONDecoder().decode(
                    [CapabilityArtifactDescriptor].self, from: Data(raw.utf8)
                )
                guard descriptors.count <= Self.maximumEntries else { throw Failure(code: "invalid_configuration") }
                let groups = Dictionary(grouping: descriptors, by: \.id)
                for (key, values) in groups {
                    guard values.count == 1 else {
                        configurationDiagnostics.append(Self.diagnostic(key, "", "duplicate_id"))
                        continue
                    }
                    let descriptor = values[0]
                    entries[key] = Entry(descriptor: descriptor,
                        diagnostic: Self.diagnostic(key, descriptor.kind, "not_acquired"))
                }
            } catch {
                configurationDiagnostics = [Self.diagnostic("configuration", "", "invalid_configuration")]
            }
        }
    }

    public func reflectors() -> [any CapabilityReflector] {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        for key in entries.keys.sorted() {
            guard var entry = entries[key] else { continue }
            let invalidated = (entry.reflector as? any CapabilityContractRefreshingReflector)?
                .requiresContractRefresh == true
            if now >= entry.expiresAt || invalidated {
                resolve(&entry)
                entries[key] = entry
            }
        }
        // Match the engine's fail-closed duplicate-identity policy. Do not let
        // two descriptor aliases make a previously visible contract disappear
        // silently: retain the diagnostic for both aliases.
        let counts = Dictionary(grouping: entries.values.compactMap(\.reflector), by: \.id)
            .mapValues(\.count)
        var result: [any CapabilityReflector] = [self]
        for key in entries.keys.sorted() {
            guard var entry = entries[key], let reflector = entry.reflector else { continue }
            if counts[reflector.id] == 1 {
                result.append(reflector)
            } else {
                entry.reflector = nil
                entry.diagnostic = Self.diagnostic(key, entry.descriptor.kind, "identity_conflict")
                entries[key] = entry
            }
        }
        return result
    }

    public func invalidateSnapshot() {
        lock.lock()
        defer { lock.unlock() }
        for key in entries.keys.sorted() {
            entries[key]?.reflector = nil
            entries[key]?.expiresAt = 0
        }
    }

    public func capabilities(for item: ContentItem) throws -> [Capability] {
        let raw = item.text ?? item.url ?? ""
        if raw == Self.statusItem {
            return [capability(Self.statusID, "Inspect capability acquisition status", readOnly: true),
                    capability(Self.forgetID, "Forget capability contract")]
        }
        // Classification/explanation is network-free. HTTPS alone does NOT
        // imply GraphQL; context_run must supply a kind or a typed descriptor.
        guard Self.isCandidate(raw) else { return [] }
        return [capability(Self.acquireID, "Acquire capability contract")]
    }

    public func providers() -> [ProviderSummary] {
        [ProviderSummary(name: "RIGHTCLICK session contract acquisition", source: "capability_acquisition",
            capabilityTitles: ["Acquire capability contract", "Inspect capability acquisition status",
                               "Forget capability contract"])]
    }

    public func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        try begin(capability: capability, item: item, executionID: executionID, arguments: nil)
    }

    public func begin(capability: Capability, item: ContentItem, executionID: String,
                      arguments: CapabilityArguments?) throws -> ExecutionRecord {
        lock.lock()
        defer { lock.unlock() }
        do {
            let args = arguments ?? [:]
            guard try capabilities(for: item).contains(where: { $0.id == capability.id }) else {
                throw Failure(code: "inapplicable_item")
            }
            if capability.id == Self.statusID {
                guard args.isEmpty else { throw Failure(code: "unknown_arguments") }
                return record(executionID, capability, .accepted, "acquisition_status",
                    diagnostics: configurationDiagnostics + entries.values.map(\.diagnostic))
            }
            if capability.id == Self.forgetID {
                guard Set(args.keys) == ["id"], let key = args["id"] else {
                    throw Failure(code: "id_required")
                }
                guard entries.removeValue(forKey: key) != nil else { throw Failure(code: "not_found") }
                return record(executionID, capability, .accepted, "forgotten")
            }
            guard capability.id == Self.acquireID else { throw Failure(code: "unknown_action") }
            var descriptor = try descriptor(for: item, arguments: args)
            // Repeated URL acquisition reuses its session identity, never adds
            // duplicate reflectors. Explicit conflicting IDs are rejected.
            if let existing = entries.values.first(where: {
                Self.sameContract($0.descriptor, descriptor)
            }) {
                if !(item.text ?? item.url ?? "").hasPrefix("{") && args["id"] == nil {
                    descriptor = existing.descriptor
                } else if existing.descriptor.id != descriptor.id {
                    throw Failure(code: "duplicate_contract")
                }
            }
            if let old = entries[descriptor.id], old.descriptor != descriptor {
                throw Failure(code: "descriptor_conflict")
            }
            guard entries[descriptor.id] != nil || entries.count < Self.maximumEntries else {
                throw Failure(code: "capacity_reached")
            }
            var entry = Entry(descriptor: descriptor,
                diagnostic: Self.diagnostic(descriptor.id, descriptor.kind, "not_acquired"))
            resolve(&entry)
            entries[descriptor.id] = entry
            return record(executionID, capability, entry.reflector == nil ? .failed : .accepted,
                entry.diagnostic.status, diagnostics: [entry.diagnostic])
        } catch {
            return record(executionID, capability, .failed, Self.failureCode(error))
        }
    }

    private func resolve(_ entry: inout Entry) {
        // Withdraw the stale snapshot BEFORE attempting replacement. Resolution
        // failure must never leave an old capability executable indefinitely.
        entry.reflector = nil
        defer { entry.expiresAt = clock() + lifetime }
        do {
            let reflector = try registry.resolve(entry.descriptor)
            let probe = ContentItem(kind: "text", display: "contract acquisition", text: "contract acquisition",
                                    typeIdentifier: "public.plain-text")
            let count = try reflector.capabilities(for: probe).count
            guard count > 0 else { throw Failure(code: "no_capabilities") }
            entry.reflector = reflector
            entry.diagnostic = Self.diagnostic(entry.descriptor.id, entry.descriptor.kind, "acquired", count)
        } catch {
            entry.diagnostic = Self.diagnostic(entry.descriptor.id, entry.descriptor.kind, Self.failureCode(error))
        }
    }

    private func descriptor(for item: ContentItem, arguments: CapabilityArguments) throws -> CapabilityArtifactDescriptor {
        let raw = item.text ?? item.url ?? ""
        guard raw.utf8.count <= 65_536 else { throw Failure(code: "descriptor_too_large") }
        if raw.hasPrefix("{") {
            guard arguments.isEmpty else { throw Failure(code: "descriptor_overrides_forbidden") }
            let data = Data(raw.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["id", "kind", "endpointURL", "specificationURL", "baseURL", "authorityScheme"])
            else { throw Failure(code: "invalid_descriptor") }
            let result: CapabilityArtifactDescriptor
            do {
                result = try JSONDecoder().decode(CapabilityArtifactDescriptor.self, from: data)
            } catch {
                throw Failure(code: "invalid_descriptor")
            }
            try Self.validateURLs(result)
            return result
        }
        guard Set(arguments.keys).isSubset(of: ["id", "kind", "baseURL", "authorityScheme"]) else {
            throw Failure(code: "unknown_arguments")
        }
        let scheme = URLComponents(string: raw)?.scheme?.lowercased()
        let kind = arguments["kind"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? ((scheme == "grpc" || scheme == "grpcs") ? "grpc" : "")
        guard !kind.isEmpty else { throw Failure(code: "kind_required") }
        guard registry.supportedKinds.contains(kind) else { throw Failure(code: "unsupported_kind") }
        if scheme == "grpc" || scheme == "grpcs" {
            guard kind == "grpc" else { throw Failure(code: "protocol_mismatch") }
        }
        let result = CapabilityArtifactDescriptor(
            id: arguments["id"] ?? "session-" + UUID().uuidString,
            kind: kind,
            specificationURL: kind == "openapi" ? raw : nil,
            baseURL: arguments["baseURL"],
            endpointURL: kind == "openapi" ? nil : raw,
            authorityScheme: arguments["authorityScheme"]
        )
        try Self.validateURLs(result)
        return result
    }

    private static func validateURLs(_ descriptor: CapabilityArtifactDescriptor) throws {
        for raw in [descriptor.endpointURL, descriptor.specificationURL, descriptor.baseURL].compactMap({ $0 }) {
            guard let url = URLComponents(string: raw), url.scheme != nil, url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else {
                throw Failure(code: "unsafe_locator")
            }
        }
        // Concrete resolvers enforce their existing TLS/loopback/origin rules.
        // Credential VALUES are never accepted here: authorityScheme is a name.
    }

    private static func isCandidate(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 65_536 else { return false }
        if raw.hasPrefix("{") {
            guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return false }
            return value["kind"] is String && value["id"] is String
        }
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              ["https", "http", "grpc", "grpcs"].contains(scheme), parts.host != nil else { return false }
        return parts.user == nil && parts.password == nil && parts.query == nil && parts.fragment == nil
    }

    private static func sameContract(_ lhs: CapabilityArtifactDescriptor, _ rhs: CapabilityArtifactDescriptor) -> Bool {
        lhs.kind == rhs.kind && lhs.endpointURL == rhs.endpointURL && lhs.baseURL == rhs.baseURL
            && lhs.specificationURL == rhs.specificationURL && lhs.inlineData == rhs.inlineData
            && lhs.authorityScheme == rhs.authorityScheme
    }

    private func capability(_ actionID: String, _ title: String, readOnly: Bool = false) -> Capability {
        let schema: String
        switch actionID {
        case Self.acquireID:
            schema = #"{"type":"object","additionalProperties":false,"properties":{"id":{"type":"string"},"kind":{"type":"string"},"baseURL":{"type":"string"},"authorityScheme":{"type":"string"}}}"#
        case Self.forgetID:
            schema = #"{"type":"object","additionalProperties":false,"required":["id"],"properties":{"id":{"type":"string"}}}"#
        default:
            schema = #"{"type":"object","additionalProperties":false,"properties":{}}"#
        }
        return Capability(id: actionID, title: title, source: .system,
            provider: CapabilityProvider(name: "RIGHTCLICK session contract acquisition"),
            inputs: ["public.plain-text", "public.url"], output: ["public.json"],
            safety: readOnly ? .read : .unknown, invocation: .direct, supportLevel: .experimental,
            requiresConfirmation: !readOnly, metadata: [
                "argumentsSchema": schema,
                "supportedKinds": registry.supportedKinds.joined(separator: ","),
                "scope": "current runtime session only",
                "diagnosticsItem": Self.statusItem,
                "contract": "Only confirmed acquisition contacts an explicitly supplied new endpoint. No provider operation is invoked."
            ])
    }

    private static func diagnostic(_ id: String, _ kind: String, _ status: String, _ count: Int = 0) -> Diagnostic {
        Diagnostic(artifactID: String(id.prefix(1_024)), kind: String(kind.prefix(64)), status: status, capabilityCount: count)
    }

    private static func failureCode(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.code }
        if let failure = error as? CapabilityArtifactResolutionError {
            switch failure {
            case .invalidDescriptor: return "invalid_descriptor"
            case .unsupportedKind: return "unsupported_kind"
            }
        }
        // Do not echo arbitrary resolver/provider text, which can include a URL
        // query, credential, response body, or untrusted instructions. A generic
        // resolver error is NOT guessed to be a network/permission failure.
        return "resolution_failed"
    }

    private func record(_ executionID: String, _ capability: Capability, _ state: ExecutionState,
                        _ status: String, diagnostics: [Diagnostic] = []) -> ExecutionRecord {
        struct Output: Encodable {
            let status: String
            let scope: String
            let supportedKinds: [String]
            let diagnostics: [Diagnostic]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = Output(status: status, scope: "current runtime session only",
            supportedKinds: registry.supportedKinds,
            diagnostics: diagnostics.sorted { $0.artifactID < $1.artifactID })
        let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        return ExecutionRecord(executionId: executionID, actionId: capability.id, title: capability.title,
            state: state, message: "Capability acquisition: " + status,
            output: String(data: data, encoding: .utf8),
            evidence: OutcomeEvidence(type: "capability_acquisition",
                boundary: "This reports contract acquisition only. Independently read context_providers/context_actions; no remote operation or user outcome is claimed.",
                outcomeVerified: false))
    }
}
