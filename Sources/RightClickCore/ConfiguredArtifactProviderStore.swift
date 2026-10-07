import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Durable acquisition references, separate from operator credentials and
/// executable artifacts. A remote declaration can never select a local process.
public enum ConfiguredArtifactProviderStore {
    public static let maximumBytes = 262_144
    public static let supportedKinds: Set<String> = ["openapi", "graphql", "grpc", "mcp"]

    public static func defaultFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        RuntimePlatform.supportDirectory(home: home).appendingPathComponent("Connections", isDirectory: true)
            .appendingPathComponent("capability-providers.json")
    }

    public static func canonicalURL(_ raw: String, grpc: Bool = false) throws -> URL {
        guard raw.utf8.count <= 4096, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.rangeOfCharacter(from: .controlCharacters) == nil,
              var parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else {
            throw RightClickError("Connection URLs must be absolute, bounded and contain no credentials, query or fragment.")
        }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(normalizedHost)
        guard grpc ? ((scheme == "grpcs" || (scheme == "grpc" && loopback)) && parts.port != nil && (parts.path.isEmpty || parts.path == "/"))
                   : (scheme == "https" || (scheme == "http" && loopback)) else {
            throw RightClickError("Connection requires HTTPS (or explicit loopback HTTP); gRPC requires grpcs and an explicit port.")
        }
        parts.scheme = scheme; parts.host = host
        if !grpc && ((scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80)) { parts.port = nil }
        guard let url = parts.url else { throw RightClickError("Connection URL could not be canonicalized.") }
        return url
    }

    public static func sameOrigin(_ left: URL, _ right: URL) -> Bool { OriginPinnedHTTP.sameOrigin(left, right) }

    public static func validate(_ descriptor: CapabilityArtifactDescriptor) throws {
        guard supportedKinds.contains(descriptor.kind), !descriptor.id.isEmpty, descriptor.id.utf8.count <= 64,
              descriptor.id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }),
              descriptor.inlineData == nil else {
            throw RightClickError("Connected provider must use a supported remote declaration and a bounded identifier; inline data and executables are not accepted.")
        }
        if let authority = descriptor.authorityScheme {
            guard !authority.isEmpty, authority.utf8.count <= 128,
                  authority == authority.trimmingCharacters(in: .whitespacesAndNewlines),
                  !authority.contains("|"), authority.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw RightClickError("Authority must name an operator-managed scheme; do not pass a credential.")
            }
        }
        switch descriptor.kind {
        case "openapi":
            guard let spec = descriptor.specificationURL, let base = descriptor.baseURL, descriptor.endpointURL == nil,
                  sameOrigin(try canonicalURL(spec), try canonicalURL(base)) else {
                throw RightClickError("OpenAPI declaration and server must belong to the selected origin.")
            }
        case "graphql":
            guard let endpoint = descriptor.endpointURL, descriptor.baseURL == nil else { throw RightClickError("GraphQL requires an endpoint.") }
            let url = try canonicalURL(endpoint)
            if let spec = descriptor.specificationURL {
                guard sameOrigin(url, try canonicalURL(spec)) else { throw RightClickError("GraphQL schema escaped the selected origin.") }
            }
        case "mcp":
            guard let endpoint = descriptor.endpointURL, descriptor.baseURL == nil, descriptor.specificationURL == nil else { throw RightClickError("MCP requires only a remote endpoint.") }
            _ = try canonicalURL(endpoint)
        case "grpc":
            guard let endpoint = descriptor.endpointURL, descriptor.baseURL == nil, descriptor.specificationURL == nil,
                  descriptor.authorityScheme == nil else { throw RightClickError("gRPC requires only a TLS reflection endpoint; advertised authority is unsupported.") }
            _ = try canonicalURL(endpoint, grpc: true)
        default: throw RightClickError("Unsupported connection substrate.")
        }
    }

    public static func decode(_ data: Data) throws -> [CapabilityArtifactDescriptor] {
        guard data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "providers"], let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let rows = root["providers"] as? [[String: Any]], rows.count <= 64 else {
            throw RightClickError("Connected provider registry has an invalid schema or exceeds its bound.")
        }
        let permitted: Set<String> = ["id", "kind", "specificationURL", "baseURL", "endpointURL", "authorityScheme"]
        for row in rows {
            guard Set(row.keys).isSubset(of: permitted), row["id"] is String, row["kind"] is String,
                  row.values.allSatisfy({ $0 is String }) else { throw RightClickError("Connected provider registry contains unknown fields or credentials.") }
        }
        let providers = try JSONDecoder().decode([CapabilityArtifactDescriptor].self,
            from: JSONSerialization.data(withJSONObject: rows))
        guard Set(providers.map(\.id)).count == providers.count else { throw RightClickError("Connected provider identifiers must be unique.") }
        for provider in providers { try validate(provider) }
        return providers.sorted { $0.id < $1.id }
    }

    public static func read(from file: URL = defaultFile()) throws -> [CapabilityArtifactDescriptor] {
#if canImport(Darwin) || canImport(Glibc)
        guard let directory = try openDirectory(file.deletingLastPathComponent(), create: false) else { return [] }
        defer { close(directory) }
        return try readData(file.lastPathComponent, directory: directory).map(decode) ?? []
#else
        throw RightClickError("Protected connection registry is unavailable on this host; no plaintext fallback was used.")
#endif
    }

    /// One serialized read/modify/atomic-publication transaction. Validation and
    /// provider acquisition must complete before calling this boundary.
    @discardableResult
    public static func upsert(_ provider: CapabilityArtifactDescriptor, in file: URL = defaultFile()) throws -> [CapabilityArtifactDescriptor] {
        try validate(provider)
        return try update(in: file) { original in
            var providers = original
            providers.removeAll { $0.id == provider.id }; providers.append(provider)
            return providers
        }
    }

    @discardableResult
    public static func remove(id: String, from file: URL = defaultFile()) throws -> Bool {
        try validate(CapabilityArtifactDescriptor(id: id, kind: "mcp", endpointURL: "https://example.invalid/mcp"))
        var removed = false
        _ = try update(in: file) { original in
            removed = original.contains { $0.id == id }
            return original.filter { $0.id != id }
        }
        return removed
    }

    private static func update(in file: URL, transform: ([CapabilityArtifactDescriptor]) throws -> [CapabilityArtifactDescriptor]) throws -> [CapabilityArtifactDescriptor] {
#if canImport(Darwin) || canImport(Glibc)
        guard let directory = try openDirectory(file.deletingLastPathComponent(), create: true) else { throw RightClickError("Could not open connection registry.") }
        defer { close(directory) }
        guard flock(directory, LOCK_EX | LOCK_NB) == 0 else { throw RightClickError("Another connection transaction is active; retry after it finishes.") }
        defer { _ = flock(directory, LOCK_UN) }
        let original = try readData(file.lastPathComponent, directory: directory)
        var providers = try transform(original.map(decode) ?? [])
        providers.sort { $0.id < $1.id }
        guard providers.count <= 64 else { throw RightClickError("Connected provider registry is full (maximum 64).") }
        let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode(providers))
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "providers": rows], options: [.sortedKeys])
        _ = try decode(data)
        let temporary = ".capability-providers-" + UUID().uuidString
        let handle = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard handle >= 0 else { throw RightClickError("Could not stage the connection registry.") }
        defer { close(handle); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var count = 0
            while count < bytes.count {
                let next = write(handle, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                guard next > 0 else { throw RightClickError("Could not stage the complete connection registry.") }
                count += next
            }
        }
        guard fsync(handle) == 0 else { throw RightClickError("Could not synchronize the staged connection registry.") }
        guard try readData(file.lastPathComponent, directory: directory) == original else { throw RightClickError("Connection registry changed during the transaction; no update was published.") }
        guard renameat(directory, temporary, directory, file.lastPathComponent) == 0 else { throw RightClickError("Could not atomically publish the connection registry.") }
        _ = fsync(directory)
        // Publication uses the exact already-validated bytes and never exposes
        // a partial descriptor. The directory handle pins the path incarnation.
        return providers
#else
        throw RightClickError("Protected connection transactions are unavailable on this host; no configuration was changed.")
#endif
    }

#if canImport(Darwin) || canImport(Glibc)
    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32? {
        guard url.isFileURL, RuntimePlatform.isAbsolutePath(url.path) else { throw RightClickError("Connection registry needs an absolute local path.") }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw RightClickError("Could not open the registry directory.") }
        var transferred = false
        defer { if !transferred { close(current) } }
        for component in url.path.split(separator: "/").map(String.init) {
            guard component != ".", component != ".." else { throw RightClickError("Connection registry path cannot traverse directories.") }
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                if !create { return nil }
                guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else { throw RightClickError("Could not create a private registry directory.") }
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw RightClickError("Connection registry directories must not be symlinks.") }
            close(current); current = next
        }
        var info = stat()
        guard fstat(current, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw RightClickError("Connection registry directory must be private and owned by the current user.")
        }
        transferred = true
        return current
    }

    private static func readData(_ name: String, directory: Int32) throws -> Data? {
        let handle = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if handle < 0 && errno == ENOENT { return nil }
        guard handle >= 0 else { throw RightClickError("Connection registry must not be a symlink.") }
        defer { close(handle) }
        var info = stat()
        guard fstat(handle, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw RightClickError("Connection registry must be a bounded, private, singly-linked file owned by the current user.")
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
#if canImport(Darwin)
                Darwin.read(handle, bytes.baseAddress!, min(bytes.count, maximumBytes + 1 - data.count))
#else
                Glibc.read(handle, bytes.baseAddress!, min(bytes.count, maximumBytes + 1 - data.count))
#endif
            }
            guard count >= 0 else { throw RightClickError("Could not read the connection registry.") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw RightClickError("Connection registry exceeded its bound.") }
        }
        return data
    }
#endif
}

/// The connector uses the existing provider transport with an ephemeral,
/// credential-free session. No redirect, cookie, keychain or cache authority is
/// inherited when acquiring a declaration selected by the operator.
public enum ConnectedProviderAcquisition {
    public struct Document { public let data: Data; public let status: Int }
    public static func registry() -> CapabilityArtifactResolverRegistry {
        var resolvers = CapabilityArtifactResolverDefaults.all().filter { !["openapi", "graphql"].contains($0.kind) }
        let load: (URL) throws -> Data = { url in
            let response = try fetch(url)
            guard (200...299).contains(response.status) else { throw RightClickError("Connected provider declaration returned an unsuccessful HTTP status.") }
            return response.data
        }
        resolvers.append(OpenAPICapabilityArtifactResolver(specificationLoader: load, session: URLSession(configuration: privateConfiguration())))
        resolvers.append(GraphQLCapabilityArtifactResolver(schemaLoader: load, introspectionLoader: { url, token in
            _ = try ConfiguredArtifactProviderStore.canonicalURL(url.absoluteString)
            var request = URLRequest(url: url); request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": GraphQLIntrospection.query,
                "operationName": "RightClickIntrospection", "variables": [String: Any]()], options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/graphql-response+json, application/json", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            let response = try OriginPinnedHTTP.exchange(request, maximumBytes: GraphQLHTTP.maximumSchemaBytes,
                deadline: GraphQLHTTP.introspectionDeadline, credentialFree: true)
            guard GraphQLHTTP.isSupportedGraphQLMediaType(response.1) else {
                throw RightClickError("GraphQL introspection returned an unsupported content type.")
            }
            return response.0
        }, session: URLSession(configuration: privateConfiguration())))
        return CapabilityArtifactResolverRegistry(resolvers: resolvers)
    }
    private static func privateConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        return configuration
    }
    public static func fetch(_ url: URL) throws -> Document {
        _ = try ConfiguredArtifactProviderStore.canonicalURL(url.absoluteString)
        let session = URLSession(configuration: privateConfiguration())
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try OriginPinnedHTTP.exchange(request, template: session, successfulStatusRequired: false)
        guard !(300...399).contains(response.1.statusCode) else { throw RightClickError("Connection declaration redirected; select its exact trusted origin explicitly.") }
        return Document(data: response.0, status: response.1.statusCode)
    }
}

/// Reloads durable descriptors without restarting MCP. Removed/malformed
/// configuration withdraws its graph; refresh withdraws compiled evidence.
public final class ConfiguredArtifactProviderSource: CapabilityReflectorSource {
    public let id = "connected.capability-artifacts"
    private let file: URL
    private let registry: CapabilityArtifactResolverRegistry
    private let lock = NSLock()
    private var descriptors: [CapabilityArtifactDescriptor] = []
    private var source: ConfiguredCapabilityArtifactSource?
    public init(configurationFile: URL = ConfiguredArtifactProviderStore.defaultFile(),
                registry: CapabilityArtifactResolverRegistry = ConnectedProviderAcquisition.registry()) {
        file = configurationFile; self.registry = registry
    }
    public func reflectors() -> [any CapabilityReflector] {
        lock.lock(); defer { lock.unlock() }
        guard let current = try? ConfiguredArtifactProviderStore.read(from: file) else {
            source = nil; descriptors = []; return []
        }
        if source == nil || current != descriptors {
            descriptors = current
            source = ConfiguredCapabilityArtifactSource(descriptors: current, registry: registry)
        }
        return source?.reflectors() ?? []
    }
    public func invalidateSnapshot() {
        lock.lock(); defer { lock.unlock() }
        source?.invalidateSnapshot()
    }
}
