import RightClickProtocol
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// MCP is an internal acquisition/invocation substrate. Upstream tool names
/// become capability data; they never enter RIGHTCLICK's AI tool registry.
public final class MCPCapabilityArtifactResolver: CapabilityArtifactResolver {
    public let kind = "mcp"
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector {
        guard descriptor.kind == kind, descriptor.specificationURL == nil, descriptor.inlineData == nil,
              descriptor.baseURL == nil, let raw = descriptor.endpointURL,
              let endpoint = CapabilityArtifactURLPolicy.httpURL(raw) else {
            throw CapabilityArtifactResolutionError.invalidDescriptor("MCP requires only a safe endpointURL.")
        }
        let sessionTemplate = self.session
        let session = try MCPDescriptorSession(endpoint: endpoint, authorityScheme: descriptor.authorityScheme, session: sessionTemplate)
        let catalog = try session.catalog()
        let declarationData = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
        let digest = CapabilityJSON.digest(declarationData)
        let operations = try catalog.map { tool -> CapabilityInterfaceOperation in
            guard let name = tool["name"] as? String, let input = tool["inputSchema"],
                  let output = tool["outputSchema"] else { throw CapabilityABIError.unknownSchema }
            return .init(name: name, title: tool["title"] as? String ?? name,
                arguments: try CapabilityJSON.schema(input), result: try CapabilityJSON.schema(output),
                declaration: try CapabilityJSON.value(tool))
        }
        return try CapabilityInterfaceReflector(id: "mcp:" + descriptor.id, provider: descriptor.id,
            target: endpoint, substrate: kind, descriptorDigest: digest, operations: operations,
            provenance: ["protocolVersion": session.protocolVersion, "transport": "mcp-streamable-http-json",
                         "authorityScheme": descriptor.authorityScheme ?? "none"],
            available: {
                guard session.authorityAvailable(),
                      let current = try? MCPDescriptorSession(endpoint: endpoint, authorityScheme: descriptor.authorityScheme, session: sessionTemplate),
                      let catalog = try? current.catalog(),
                      let bytes = try? JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]),
                      current.authorityAvailable(), session.authorityAvailable() else { return false }
                return CapabilityJSON.digest(bytes) == digest
            }, invoke: { name, input, admit in
                // Reacquire the true provider interface immediately before use.
                // Descriptor drift cannot reuse the old action or lease.
                let current = try MCPDescriptorSession(endpoint: endpoint, authorityScheme: descriptor.authorityScheme, session: sessionTemplate)
                let latest = try JSONSerialization.data(withJSONObject: current.catalog(), options: [.sortedKeys])
                guard CapabilityJSON.digest(latest) == digest else { throw RCIRError.staleBinding }
                return try current.call(name: name, input: input, admit: admit)
            })
    }
}

/// Supported public MCP Streamable HTTP JSON-response profile. SSE-only servers
/// are rejected explicitly. Session negotiation and bounded pagination are real
/// protocol exchanges against the provider, not an OpenAPI imitation.
private final class MCPDescriptorSession {
    let endpoint: URL
    let authorityScheme: String?
    private(set) var protocolVersion = "2025-11-25"
    private var sessionID: String?
    private var sequence = 0
    private let origin: String
    private let selectedToken: String?
    private let session: URLSession

    init(endpoint: URL, authorityScheme: String?, session: URLSession) throws {
        self.endpoint = endpoint; self.authorityScheme = authorityScheme
        self.session = session
        let canonicalOrigin = try GraphQLHTTP.canonicalOrigin(endpoint)
        self.origin = canonicalOrigin
        self.selectedToken = authorityScheme.flatMap { GraphQLHTTP.bearerToken(origin: canonicalOrigin, schemeName: $0) }
        guard authorityScheme == nil || selectedToken != nil else { throw RCIRError.authorityDenied }
        let initialized = try request("initialize", parameters: ["protocolVersion": protocolVersion,
            "capabilities": [:], "clientInfo": ["name": "RIGHTCLICK-interface-acquisition", "version": "1"]])
        guard let negotiated = initialized["protocolVersion"] as? String,
              ["2025-11-25", "2025-06-18", "2025-03-26"].contains(negotiated),
              let capabilities = initialized["capabilities"] as? [String: Any], capabilities["tools"] != nil else {
            throw CapabilityArtifactResolutionError.invalidDescriptor("MCP server did not negotiate a supported tools interface.")
        }
        protocolVersion = negotiated
        try notify("notifications/initialized")
    }
    func authorityAvailable() -> Bool {
        guard authorityScheme != nil else { return true }
        guard let current = token(), let selectedToken else { return false }
        return current.utf8.elementsEqual(selectedToken.utf8)
    }
    private func token() -> String? {
        guard let authorityScheme else { return nil }
        return GraphQLHTTP.bearerToken(origin: origin, schemeName: authorityScheme)
    }
    private func exchange(_ object: [String: Any], admit: ((_ start: () -> Void) throws -> Void)? = nil) throws -> Data {
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        if authorityScheme != nil {
            guard authorityAvailable(), let selectedToken else { throw RCIRError.authorityDenied }
            request.setValue("Bearer " + selectedToken, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let (data, response) = try OriginPinnedHTTP.exchange(request, template: session, credentialIsolated: true, admitStart: admit)
        if let identifier = response.value(forHTTPHeaderField: "MCP-Session-Id") {
            guard identifier.utf8.count <= 256, identifier.rangeOfCharacter(from: .controlCharacters) == nil else { throw CapabilityABIError.invalidWire }
            sessionID = identifier
        }
        if !data.isEmpty {
            guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true else {
                throw CapabilityArtifactResolutionError.invalidDescriptor("Only the MCP JSON-response transport profile is supported.")
            }
        }
        return data
    }
    private func request(_ method: String, parameters: [String: Any],
                         admit: ((_ start: () -> Void) throws -> Void)? = nil) throws -> [String: Any] {
        sequence += 1; let identifier = sequence
        let data = try exchange(["jsonrpc": "2.0", "id": identifier, "method": method, "params": parameters], admit: admit)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["jsonrpc"] as? String == "2.0", object["id"] as? Int == identifier,
              object["error"] == nil, let result = object["result"] as? [String: Any] else { throw CapabilityABIError.invalidWire }
        return result
    }
    private func notify(_ method: String) throws {
        _ = try exchange(["jsonrpc": "2.0", "method": method])
    }
    func catalog() throws -> [[String: Any]] {
        var tools: [[String: Any]] = []; var cursor: String?; var seen: Set<String> = []
        repeat {
            guard seen.count < 16 else { throw CapabilityABIError.limitExceeded }
            let page = try request("tools/list", parameters: cursor.map { ["cursor": $0] } ?? [:])
            guard let next = page["tools"] as? [[String: Any]], tools.count + next.count <= 256 else { throw CapabilityABIError.invalidWire }
            tools.append(contentsOf: next)
            cursor = page["nextCursor"] as? String
            if let cursor { guard cursor.utf8.count <= 1024, seen.insert(cursor).inserted else { throw CapabilityABIError.invalidWire } }
        } while cursor != nil
        let names = tools.compactMap { $0["name"] as? String }
        guard names.count == tools.count, Set(names).count == names.count else { throw CapabilityABIError.invalidIdentity }
        return tools.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }
    func call(name: String, input: CapabilityValue, admit: (_ start: () -> Void) throws -> Void) throws -> CapabilityValue {
        guard let arguments = try CapabilityJSON.object(input) as? [String: Any] else { throw CapabilityABIError.schemaMismatch }
        let result = try withoutActuallyEscaping(admit) { gate in
            try request("tools/call", parameters: ["name": name, "arguments": arguments], admit: gate)
        }
        guard result["isError"] as? Bool != true, let structured = result["structuredContent"] else {
            throw CapabilityABIError.invalidWire
        }
        let value = try CapabilityJSON.value(structured); _ = try value.canonicalData(); return value
    }
}
