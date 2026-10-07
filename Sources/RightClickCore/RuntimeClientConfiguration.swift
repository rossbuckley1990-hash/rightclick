import Foundation

/// Produces MCP client configuration without invoking a provider, installing
/// software, modifying another application's configuration or reading secrets.
public enum RuntimeClientConfiguration {
    private struct Server: Encodable {
        let command: String
        let args: [String]
        let env: [String: String]?
    }
    private struct Configuration: Encodable { let mcpServers: [String: Server] }
    public static func render(arguments: [String], executable: String = RightClickRuntime.executablePath()) throws -> String {
        guard !executable.isEmpty, !executable.contains("\0") else { throw RightClickError("Invalid executable path.") }
        let supported = Set(["--openapi", "--base-url", "--graphql", "--grpc", "--id", "--authority-scheme"])
        var flags: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--json" { index += 1; continue }
            guard supported.contains(flag), flags[flag] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].isEmpty else { throw RightClickError("Unknown, duplicate or incomplete configuration option.") }
            flags[flag] = arguments[index + 1]
            index += 2
        }
        let kinds = ["--openapi", "--graphql", "--grpc"].filter { flags[$0] != nil }
        guard kinds.count <= 1 else { throw RightClickError("Configure one provider per generated configuration.") }
        var environment: [String: String]?
        if let flag = kinds.first, let endpoint = flags[flag] {
            let id = flags["--id"] ?? "configured-provider"
            guard !id.isEmpty, id.utf8.count <= 1024, id.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw RightClickError("Invalid provider identifier.")
            }
            let authority = try flags["--authority-scheme"].map(OpenAPIAuthorityStore.canonicalBearerSchemeName)
            let descriptor: CapabilityArtifactDescriptor
            switch flag {
            case "--openapi":
                guard let base = flags["--base-url"], CapabilityArtifactURLPolicy.httpURL(endpoint) != nil,
                      CapabilityArtifactURLPolicy.httpURL(base) != nil else { throw RightClickError("OpenAPI needs a safe specification URL and --base-url.") }
                descriptor = .init(id: id, kind: "openapi", specificationURL: endpoint, baseURL: base, authorityScheme: authority)
            case "--graphql":
                guard flags["--base-url"] == nil, CapabilityArtifactURLPolicy.httpURL(endpoint) != nil else {
                    throw RightClickError("GraphQL needs a safe endpoint URL and no --base-url.")
                }
                descriptor = .init(id: id, kind: "graphql", endpointURL: endpoint, authorityScheme: authority)
            default:
#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
                guard flags["--base-url"] == nil, authority == nil, CapabilityArtifactURLPolicy.grpcEndpoint(endpoint) != nil else {
                    throw RightClickError("gRPC needs a safe endpoint; configured gRPC bearer authority is not supported.")
                }
                descriptor = .init(id: id, kind: "grpc", endpointURL: endpoint)
#else
                throw RightClickError("gRPC transport is not available in this build.")
#endif
            }
            let data = try JSONEncoder().encode([descriptor])
            environment = [ConfiguredCapabilityArtifactSource.environmentKey: String(decoding: data, as: UTF8.self)]
        } else if !flags.isEmpty {
            throw RightClickError("Provider options require --openapi, --graphql or --grpc.")
        }
        let config = Configuration(mcpServers: ["rightclick": Server(command: executable, args: ["mcp"], env: environment)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(config), as: UTF8.self)
    }
}

