import Foundation
import CoreFoundation
import RightClickCore

enum RightClickConnectCLI {
    static let usage = "rightclick connect <https-url|grpcs-url> [--kind openapi|graphql|grpc|mcp] [--id name] [--base-url url] [--auth-scheme name] [--json]"
    typealias DocumentLoader = (URL) throws -> (data: Data, status: Int)
    struct Result: Encodable {
        let status = "CONNECTED"
        let id: String
        let kind: String
        let configuration: String
        let reflectorID: String
        let capabilityCount: Int
        let credentialStored = false
        let execution = "NOT_RUN"
        let outcomeVerification = "NOT_RUN"
    }
    private struct Options {
        let target: String
        var kind: String?
        var identifier: String?
        var base: String?
        var authority: String?
        var json = false
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ args: [String], file: URL = ConfiguredArtifactProviderStore.defaultFile(),
                    registry: CapabilityArtifactResolverRegistry = ConnectedProviderAcquisition.registry(),
                    documentLoader: @escaping DocumentLoader = { url in
                        let response = try ConnectedProviderAcquisition.fetch(url)
                        return (response.data, response.status)
                    }, output: (String) -> Void = { print($0) },
                    errorOutput: (String) -> Void = { fputs($0 + "\n", stderr) }) -> Int {
        let json = args.contains("--json")
        do {
            let options = try parse(args)
            let (descriptor, compiledDescriptor) = try discover(options, registry: registry, loader: documentLoader)
            let reflector: any CapabilityReflector
            let capabilities: [Capability]
            do {
                reflector = try registry.resolve(compiledDescriptor)
                capabilities = try reflector.capabilities(for: ContentItem(kind: "text", display: "RIGHTCLICK connection discovery", text: "RIGHTCLICK connection discovery", typeIdentifier: "public.plain-text"))
            } catch {
                throw Failure(message: "The provider declaration could not be acquired or compiled. Check its public schema, supported transport and operator-managed authority; no configuration was changed.")
            }
            guard !capabilities.isEmpty else { throw Failure(message: "The current provider declaration exposed no supported capabilities; no configuration was changed.") }
            do { _ = try ConfiguredArtifactProviderStore.upsert(descriptor, in: file) }
            catch { throw Failure(message: "The connection registry could not be updated safely. Check that its directory and file are private, owned by you, and free of links; retry if another connection is active.") }
            let result = Result(id: descriptor.id, kind: descriptor.kind, configuration: file.path,
                                reflectorID: reflector.id, capabilityCount: capabilities.count)
            output(json ? RightClickJSON.encode(result) : "Connected \(descriptor.id) (\(descriptor.kind)): \(capabilities.count) discovered capabilities.\nNo credential was stored. Execution and effects were not tested.")
            return 0
        } catch {
            // Only locally-authored diagnostics are rendered. Provider response
            // bytes, arbitrary URLSession errors and credential-bearing targets
            // never enter the agent-visible output.
            let message = (error as? Failure)?.message ?? "Connection target was rejected by the URL or authority policy; no configuration was changed."
            if json { output(RightClickJSON.encode(["status": "FAILED", "error": message, "credentialStored": "false", "execution": "NOT_RUN"])) }
            else { errorOutput(message) }
            return 2
        }
    }

    private static func parse(_ args: [String]) throws -> Options {
        guard let target = args.first, !target.hasPrefix("--") else { throw Failure(message: usage) }
        var options = Options(target: target)
        var seen: Set<String> = []; var index = 1
        while index < args.count {
            let flag = args[index]
            guard seen.insert(flag).inserted else { throw Failure(message: "Connection flags must not be repeated.\n" + usage) }
            if flag == "--json" { options.json = true; index += 1; continue }
            guard ["--kind", "--id", "--base-url", "--auth-scheme"].contains(flag), index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw Failure(message: usage) }
            let value = args[index + 1]
            switch flag {
            case "--kind": options.kind = value.lowercased()
            case "--id": options.identifier = value
            case "--base-url": options.base = value
            case "--auth-scheme": options.authority = value
            default: break
            }
            index += 2
        }
        if let kind = options.kind, !ConfiguredArtifactProviderStore.supportedKinds.contains(kind) {
            throw Failure(message: "This connector supports remote OpenAPI, GraphQL introspection, gRPC reflection and the MCP JSON response profile. ARD registries, A2A cards and RIGHTCLICK federation require their existing explicit runtime configuration; automatic connection is not yet supported.")
        }
        return options
    }

    private static func discover(_ options: Options, registry: CapabilityArtifactResolverRegistry,
                                 loader: DocumentLoader) throws -> (CapabilityArtifactDescriptor, CapabilityArtifactDescriptor) {
        let isGRPC = options.kind == "grpc" || options.target.lowercased().hasPrefix("grpcs://") || options.target.lowercased().hasPrefix("grpc://")
        let target = try ConfiguredArtifactProviderStore.canonicalURL(options.target, grpc: isGRPC)
        // Every operator-supplied URL is checked before any request occurs.
        if let base = options.base {
            guard !isGRPC, ConfiguredArtifactProviderStore.sameOrigin(target, try ConfiguredArtifactProviderStore.canonicalURL(base)) else { throw Failure(message: "The selected base URL belongs to another origin; no network request was made.") }
        }
        let identity = options.identifier ?? "remote-" + String(CapabilityJSON.digest(Data(target.absoluteString.utf8)).prefix(24))
        let placeholder = CapabilityArtifactDescriptor(id: identity, kind: isGRPC ? "grpc" : "mcp", endpointURL: target.absoluteString, authorityScheme: options.authority)
        // Identifier and authority validation also precede acquisition.
        try ConfiguredArtifactProviderStore.validate(placeholder)
        let inferred = options.kind ?? (isGRPC ? "grpc" : target.lastPathComponent.lowercased() == "graphql" ? "graphql" : target.lastPathComponent.lowercased() == "mcp" ? "mcp" : nil)
        if let inferred, ["grpc", "graphql", "mcp"].contains(inferred) {
            guard options.base == nil else { throw Failure(message: "--base-url applies only to OpenAPI declarations.") }
            guard registry.supportedKinds.contains(inferred) else { throw Failure(message: "This build has no resolver for the selected substrate; no configuration was changed.") }
            let descriptor = CapabilityArtifactDescriptor(id: identity, kind: inferred, endpointURL: target.absoluteString, authorityScheme: options.authority)
            try ConfiguredArtifactProviderStore.validate(descriptor)
            return (descriptor, descriptor)
        }
        if target.path.isEmpty || target.path == "/" {
            let manifestURL = target.appendingPathComponent(".well-known/rightclick")
            let manifest = try fetch(manifestURL, loader: loader)
            if manifest.status == 200 { return try linkedDescriptor(manifest.data, source: manifestURL, identity: identity, options: options, registry: registry, loader: loader) }
            guard [404, 405].contains(manifest.status) else { throw Failure(message: "The discovery manifest returned an unexpected HTTP response; no alternate authority was attempted.") }
            let specificationURL = target.appendingPathComponent("openapi.json")
            let declaration = try fetch(specificationURL, loader: loader)
            guard declaration.status == 200 else { throw Failure(message: "No supported declaration was found. Supply its exact URL or --kind for a nonstandard GraphQL, MCP or gRPC endpoint.") }
            return try openAPIDescriptor(declaration.data, source: specificationURL, identity: identity, options: options)
        }
        let declaration = try fetch(target, loader: loader)
        guard declaration.status == 200 else { throw Failure(message: "The selected declaration returned an unsuccessful HTTP response; no configuration was changed.") }
        try requireUnambiguousJSON(declaration.data)
        if let document = try? JSONSerialization.jsonObject(with: declaration.data) as? [String: Any], document["links"] != nil {
            return try linkedDescriptor(declaration.data, source: target, identity: identity, options: options, registry: registry, loader: loader)
        }
        return try openAPIDescriptor(declaration.data, source: target, identity: identity, options: options)
    }

    private static func fetch(_ url: URL, loader: DocumentLoader) throws -> (data: Data, status: Int) {
        do {
            let response = try loader(url)
            guard response.data.count <= 1_048_576, !(300...399).contains(response.status) else { throw Failure(message: "Provider declaration exceeded its bound or redirected; no configuration was changed.") }
            return response
        } catch let error as Failure { throw error }
        catch { throw Failure(message: "Provider declaration acquisition failed within its bounded transport; no configuration was changed.") }
    }

    private static func openAPIDescriptor(_ data: Data, source: URL, identity: String, options: Options) throws -> (CapabilityArtifactDescriptor, CapabilityArtifactDescriptor) {
        try requireUnambiguousJSON(data)
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any], document["openapi"] is String else {
            throw Failure(message: "Expected a supported OpenAPI JSON declaration. YAML, A2A cards, ARD search results and executable manifests are not automatically imported.")
        }
        let base: URL
        if let explicit = options.base { base = try ConfiguredArtifactProviderStore.canonicalURL(explicit) }
        else {
            guard let servers = document["servers"] as? [[String: Any]], servers.count == 1,
                  let raw = servers[0]["url"] as? String, servers[0]["variables"] == nil,
                  !raw.contains("{"), !raw.contains("}"),
                  let resolved = URL(string: raw, relativeTo: source)?.absoluteURL else {
                throw Failure(message: "OpenAPI must declare exactly one literal server, or select one with --base-url.")
            }
            base = try ConfiguredArtifactProviderStore.canonicalURL(resolved.absoluteString)
        }
        guard ConfiguredArtifactProviderStore.sameOrigin(source, base) else { throw Failure(message: "The declaration advertised a server outside the selected origin; no configuration was changed.") }
        let persisted = CapabilityArtifactDescriptor(id: identity, kind: "openapi", specificationURL: source.absoluteString, baseURL: base.absoluteString, authorityScheme: options.authority)
        try ConfiguredArtifactProviderStore.validate(persisted)
        return (persisted, CapabilityArtifactDescriptor(id: identity, kind: "openapi", baseURL: base.absoluteString, inlineData: data, authorityScheme: options.authority))
    }

    /// Minimal optional envelope: {"schemaVersion":1,"links":[{"kind":
    /// "openapi","url":"/openapi.json"}]}. It only links existing standards.
    /// One explicit declaration is required; remote metadata selects no authority.
    private static func linkedDescriptor(_ data: Data, source: URL, identity: String, options: Options,
                                         registry: CapabilityArtifactResolverRegistry, loader: DocumentLoader) throws -> (CapabilityArtifactDescriptor, CapabilityArtifactDescriptor) {
        try requireUnambiguousJSON(data)
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(manifest.keys) == ["schemaVersion", "links"], let version = manifest["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let links = manifest["links"] as? [[String: Any]], links.count == 1,
              Set(links[0].keys) == ["kind", "url"], let kind = links[0]["kind"] as? String,
              let raw = links[0]["url"] as? String,
              let url = URL(string: raw, relativeTo: source)?.absoluteURL else {
            throw Failure(message: "The optional discovery manifest must contain one standard declaration link and no authority, credentials or executable fields.")
        }
        guard ConfiguredArtifactProviderStore.supportedKinds.contains(kind) else { throw Failure(message: "The manifest links an acquisition standard not yet supported by this connector; no configuration was changed.") }
        _ = try ConfiguredArtifactProviderStore.canonicalURL(url.absoluteString, grpc: kind == "grpc")
        // A scheme change into gRPC is an additional authority selection. The
        // operator must explicitly select it, rather than inherit a HTTPS grant.
        guard kind != "grpc", ConfiguredArtifactProviderStore.sameOrigin(source, url) else { throw Failure(message: "A manifest link cannot change the selected origin or transport; select that endpoint explicitly.") }
        guard options.kind == nil || options.kind == kind else { throw Failure(message: "The manifest declaration does not match --kind.") }
        if kind == "openapi" {
            let declaration = try fetch(url, loader: loader)
            guard declaration.status == 200 else { throw Failure(message: "The linked declaration could not be acquired; no configuration was changed.") }
            return try openAPIDescriptor(declaration.data, source: url, identity: identity, options: options)
        }
        guard options.base == nil, registry.supportedKinds.contains(kind) else { throw Failure(message: "The linked substrate or its supplied flags are unsupported by this build.") }
        let descriptor = CapabilityArtifactDescriptor(id: identity, kind: kind, endpointURL: url.absoluteString, authorityScheme: options.authority)
        try ConfiguredArtifactProviderStore.validate(descriptor)
        return (descriptor, descriptor)
    }

    private static func requireUnambiguousJSON(_ data: Data) throws {
        do { try RightClickJSONConfigBackend.rejectDuplicateJSONKeys(data) }
        catch { throw Failure(message: "Provider declaration contains ambiguous or malformed JSON object keys; no configuration was changed.") }
    }
}
