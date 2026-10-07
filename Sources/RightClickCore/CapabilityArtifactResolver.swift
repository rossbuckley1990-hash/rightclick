import Foundation

public struct CapabilityArtifactDescriptor:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let kind: String
    public let specificationURL: String?
    public let baseURL: String?
    public let endpointURL: String?
    public let authorityScheme: String?

    public init(
        id: String,
        kind: String,
        specificationURL: String? = nil,
        baseURL: String? = nil,
        endpointURL: String? = nil,
        authorityScheme: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.specificationURL = specificationURL
        self.baseURL = baseURL
        self.endpointURL = endpointURL
        self.authorityScheme = authorityScheme
    }
}

public enum CapabilityArtifactResolutionError:
    LocalizedError,
    Equatable
{
    case invalidDescriptor(String)
    case unsupportedKind(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidDescriptor(message):
            return "Invalid capability artifact descriptor: " + message
        case let .unsupportedKind(kind):
            return "Unsupported capability artifact kind: " + kind
        }
    }
}

/// Converts one provider-neutral capability artifact descriptor into an
/// ordinary RIGHTCLICK reflector.
///
/// Discovery mechanisms stay outside this boundary. ARD, Bonjour, a registry,
/// an enterprise catalog or a local configuration can all produce the same
/// descriptor without changing the execution engine.
public protocol CapabilityArtifactResolver:
    AnyObject
{
    var kind: String { get }

    func resolve(
        _ descriptor: CapabilityArtifactDescriptor
    ) throws -> any CapabilityReflector
}

public final class CapabilityArtifactResolverRegistry {
    private let resolvers:
        [String: any CapabilityArtifactResolver]

    public init(
        resolvers:
            [any CapabilityArtifactResolver] =
                CapabilityArtifactResolverDefaults.all()
    ) {
        var counts:
            [String: Int] = [:]

        for resolver in resolvers {
            counts[
                Self.normalizedKind(
                    resolver.kind
                ),
                default: 0
            ] += 1
        }

        var accepted:
            [String: any CapabilityArtifactResolver] = [:]

        for resolver in resolvers {
            let kind =
                Self.normalizedKind(
                    resolver.kind
                )

            guard
                !kind.isEmpty,
                counts[kind] == 1
            else {
                continue
            }

            accepted[kind] =
                resolver
        }

        self.resolvers =
            accepted
    }

    public var supportedKinds:
        [String]
    {
        resolvers.keys.sorted()
    }

    public func resolve(
        _ raw:
            CapabilityArtifactDescriptor
    ) throws -> any CapabilityReflector {
        let descriptor =
            try Self.canonicalDescriptor(
                raw
            )

        guard
            let resolver =
                resolvers[
                    descriptor.kind
                ]
        else {
            throw CapabilityArtifactResolutionError
                .unsupportedKind(
                    descriptor.kind
                )
        }

        return try resolver.resolve(
            descriptor
        )
    }

    private static func canonicalDescriptor(
        _ raw:
            CapabilityArtifactDescriptor
    ) throws -> CapabilityArtifactDescriptor {
        guard
            validIdentifier(
                raw.id
            )
        else {
            throw CapabilityArtifactResolutionError
                .invalidDescriptor(
                    "id must be 1...128 characters using A-Z, a-z, 0-9, dot, dash or underscore"
                )
        }

        let kind =
            normalizedKind(
                raw.kind
            )

        guard
            !kind.isEmpty,
            kind.count <= 64
        else {
            throw CapabilityArtifactResolutionError
                .invalidDescriptor(
                    "kind is empty or too long"
                )
        }

        let authority =
            try canonicalAuthorityScheme(
                raw.authorityScheme
            )

        return CapabilityArtifactDescriptor(
            id:
                raw.id,
            kind:
                kind,
            specificationURL:
                raw.specificationURL,
            baseURL:
                raw.baseURL,
            endpointURL:
                raw.endpointURL,
            authorityScheme:
                authority
        )
    }

    private static func normalizedKind(
        _ raw: String
    ) -> String {
        raw
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )
            .lowercased()
    }

    private static func validIdentifier(
        _ raw: String
    ) -> Bool {
        guard
            !raw.isEmpty,
            raw.count <= 128,
            raw ==
                raw.trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
        else {
            return false
        }

        return raw.unicodeScalars
            .allSatisfy {
                scalar in

                let value =
                    scalar.value

                return
                    (value >= 48 && value <= 57)
                    || (value >= 65 && value <= 90)
                    || (value >= 97 && value <= 122)
                    || value == 45
                    || value == 46
                    || value == 95
            }
    }

    private static func canonicalAuthorityScheme(
        _ raw: String?
    ) throws -> String? {
        guard
            let raw
        else {
            return nil
        }

        guard
            !raw.isEmpty,
            raw.count <= 128,
            raw ==
                raw.trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                ),
            !raw.contains("|"),
            raw.rangeOfCharacter(
                from:
                    .controlCharacters
            ) == nil
        else {
            throw CapabilityArtifactResolutionError
                .invalidDescriptor(
                    "authorityScheme is invalid"
                )
        }

        return raw
    }
}

public enum CapabilityArtifactResolverDefaults {
    public static func all()
        -> [any CapabilityArtifactResolver]
    {
        var result:
            [any CapabilityArtifactResolver] = [
                OpenAPICapabilityArtifactResolver(),
                GraphQLCapabilityArtifactResolver(),
            ]

#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
        result.append(
            GRPCCapabilityArtifactResolver()
        )
#endif

        return result
    }
}

public final class OpenAPICapabilityArtifactResolver:
    CapabilityArtifactResolver
{
    public let kind =
        "openapi"

    public typealias SpecificationLoader =
        (URL) throws -> Data

    private let specificationLoader:
        SpecificationLoader

    public init(
        specificationLoader:
            @escaping SpecificationLoader = {
                try OriginPinnedHTTP
                    .loadOpenAPISpecification(
                        $0
                    )
            }
    ) {
        self.specificationLoader =
            specificationLoader
    }

    public func resolve(
        _ descriptor:
            CapabilityArtifactDescriptor
    ) throws -> any CapabilityReflector {
        guard
            descriptor.kind == kind,
            let rawSpecification =
                descriptor.specificationURL,
            let rawBase =
                descriptor.baseURL,
            let specificationURL =
                CapabilityArtifactURLPolicy
                    .httpURL(
                        rawSpecification
                    ),
            let baseURL =
                CapabilityArtifactURLPolicy
                    .httpURL(
                        rawBase
                    )
        else {
            throw CapabilityArtifactResolutionError
                .invalidDescriptor(
                    "OpenAPI requires safe specificationURL and baseURL"
                )
        }

        let specification =
            try specificationLoader(
                specificationURL
            )

        return try OpenAPIReflector(
            specificationData:
                specification,
            baseURL:
                baseURL,
            externalBearerSchemeName:
                descriptor.authorityScheme
        )
    }
}

public final class GraphQLCapabilityArtifactResolver:
    CapabilityArtifactResolver
{
    public let kind =
        "graphql"

    public typealias SchemaLoader =
        (URL) throws -> Data

    public typealias IntrospectionLoader =
        (
            URL,
            String?
        ) throws -> Data

    private let schemaLoader:
        SchemaLoader

    private let introspectionLoader:
        IntrospectionLoader

    public init(
        schemaLoader:
            @escaping SchemaLoader = {
                try OriginPinnedHTTP
                    .loadOpenAPISpecification(
                        $0
                    )
            },
        introspectionLoader:
            @escaping IntrospectionLoader = {
                endpoint,
                token in

                try GraphQLIntrospection
                    .load(
                        endpointURL:
                            endpoint,
                        bearerToken:
                            token
                    )
            }
    ) {
        self.schemaLoader =
            schemaLoader

        self.introspectionLoader =
            introspectionLoader
    }

    public func resolve(
        _ descriptor:
            CapabilityArtifactDescriptor
    ) throws -> any CapabilityReflector {
        guard
            descriptor.kind == kind,
            let rawEndpoint =
                descriptor.endpointURL,
            let endpoint =
                CapabilityArtifactURLPolicy
                    .httpURL(
                        rawEndpoint
                    ),
            descriptor.baseURL == nil
        else {
            throw CapabilityArtifactResolutionError
                .invalidDescriptor(
                    "GraphQL requires endpointURL and does not use baseURL"
                )
        }

        let schema:
            Data

        if
            let rawSchema =
                descriptor.specificationURL
        {
            guard
                let schemaURL =
                    CapabilityArtifactURLPolicy
                        .httpURL(
                            rawSchema
                        )
            else {
                throw CapabilityArtifactResolutionError
                    .invalidDescriptor(
                        "GraphQL specificationURL is unsafe"
                    )
            }

            schema =
                try schemaLoader(
                    schemaURL
                )
        } else {
            let bearerToken:
                String?

            if
                let scheme =
                    descriptor.authorityScheme
            {
                let origin =
                    try GraphQLHTTP
                        .canonicalOrigin(
                            endpoint
                        )

                guard
                    let token =
                        GraphQLHTTP
                            .bearerToken(
                                origin:
                                    origin,
                                schemeName:
                                    scheme
                            )
                else {
                    throw RightClickError(
                        "GraphQL capability artifact authority is unavailable."
                    )
                }

                bearerToken =
                    token
            } else {
                bearerToken =
                    nil
            }

            schema =
                try introspectionLoader(
                    endpoint,
                    bearerToken
                )
        }

        return try GraphQLReflector(
            schemaData:
                schema,
            endpointURL:
                endpoint,
            externalBearerSchemeName:
                descriptor.authorityScheme
        )
    }
}

#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
public final class GRPCCapabilityArtifactResolver:
    CapabilityArtifactResolver
{
    public let kind =
        "grpc"

    public typealias DescriptorLoader =
        (GRPCEndpoint) throws -> [Data]

    private let descriptorLoader:
        DescriptorLoader

    public init(
        descriptorLoader:
            @escaping DescriptorLoader = {
                try GRPCReflectionTransport
                    .discover(
                        endpoint:
                            $0
                    )
            }
    ) {
        self.descriptorLoader =
            descriptorLoader
    }

    public func resolve(
        _ descriptor:
            CapabilityArtifactDescriptor
    ) throws -> any CapabilityReflector {
        guard
            descriptor.kind == kind,
            descriptor.specificationURL == nil,
            descriptor.baseURL == nil,
            descriptor.authorityScheme == nil,
            let rawEndpoint =
                descriptor.endpointURL,
            let endpoint =
                CapabilityArtifactURLPolicy
                    .grpcEndpoint(
                        rawEndpoint
                    )
        else {
            throw CapabilityArtifactResolutionError
                .invalidDescriptor(
                    "gRPC requires a safe grpc/grpcs endpointURL and currently rejects advertised authority"
                )
        }

        let files =
            try descriptorLoader(
                endpoint
            )

        return try GRPCReflector(
            descriptorData:
                files,
            endpoint:
                endpoint
        )
    }
}
#endif

enum CapabilityArtifactURLPolicy {
    static func httpURL(
        _ raw: String
    ) -> URL? {
        guard
            !raw.isEmpty,
            raw ==
                raw.trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                ),
            var components =
                URLComponents(
                    string:
                        raw
                ),
            let rawScheme =
                components.scheme,
            let rawHost =
                components.host,
            components.user == nil,
            components.password == nil,
            components.fragment == nil
        else {
            return nil
        }

        let scheme =
            rawScheme.lowercased()

        let host =
            canonicalHost(
                rawHost
            )

        guard
            scheme == "https"
            || (
                scheme == "http"
                && isLoopback(
                    host
                )
            )
        else {
            return nil
        }

        components.scheme =
            scheme

        components.host =
            host

        if
            (
                scheme == "http"
                && components.port == 80
            )
            || (
                scheme == "https"
                && components.port == 443
            )
        {
            components.port =
                nil
        }

        return components.url
    }

#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
    static func grpcEndpoint(
        _ raw: String
    ) -> GRPCEndpoint? {
        guard
            raw ==
                raw.trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                ),
            let components =
                URLComponents(
                    string:
                        raw
                ),
            let rawScheme =
                components.scheme,
            let rawHost =
                components.host,
            let port =
                components.port,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty
                || components.path == "/"
        else {
            return nil
        }

        let scheme =
            rawScheme.lowercased()

        let host =
            canonicalHost(
                rawHost
            )

        guard
            scheme == "grpcs"
            || (
                scheme == "grpc"
                && isLoopback(
                    host
                )
            )
        else {
            return nil
        }

        return try? GRPCEndpoint(
            scheme:
                scheme,
            host:
                host,
            port:
                port
        )
    }
#endif

    private static func canonicalHost(
        _ raw: String
    ) -> String {
        var host =
            raw.lowercased()

        if
            host.hasPrefix("["),
            host.hasSuffix("]"),
            host.count >= 2
        {
            host =
                String(
                    host
                        .dropFirst()
                        .dropLast()
                )
        }

        if host.hasSuffix(".") {
            host.removeLast()
        }

        return host
    }

    private static func isLoopback(
        _ host: String
    ) -> Bool {
        [
            "localhost",
            "127.0.0.1",
            "::1",
        ].contains(
            host
        )
    }
}

/// A provider-neutral configured source.
///
/// This deliberately uses a single generic descriptor envelope. New discovery
/// systems should produce descriptors for the resolver registry rather than
/// adding provider-specific branches to CapabilityEngine.
public final class ConfiguredCapabilityArtifactSource:
    CapabilityReflectorSource
{
    public static let environmentKey =
        "RIGHTCLICK_CAPABILITY_ARTIFACTS"

    public let id =
        "configured.capability-artifacts"

    private let descriptors:
        [CapabilityArtifactDescriptor]

    private let registry:
        CapabilityArtifactResolverRegistry

    public init(
        descriptors:
            [CapabilityArtifactDescriptor],
        registry:
            CapabilityArtifactResolverRegistry =
                CapabilityArtifactResolverRegistry()
    ) {
        self.descriptors =
            Array(
                descriptors.prefix(
                    64
                )
            )

        self.registry =
            registry
    }

    public static func fromEnvironment(
        _ environment:
            [String: String] =
                ProcessInfo
                    .processInfo
                    .environment
    ) -> ConfiguredCapabilityArtifactSource? {
        guard
            let raw =
                environment[
                    environmentKey
                ],
            raw.utf8.count
                <= 262_144,
            let data =
                raw.data(
                    using:
                        .utf8
                ),
            let descriptors =
                try? JSONDecoder()
                    .decode(
                        [CapabilityArtifactDescriptor].self,
                        from:
                            data
                    ),
            !descriptors.isEmpty,
            descriptors.count <= 64
        else {
            return nil
        }

        return ConfiguredCapabilityArtifactSource(
            descriptors:
                descriptors
        )
    }

    public func reflectors()
        -> [any CapabilityReflector]
    {
        var next:
            [any CapabilityReflector] = []

        var descriptorIDs =
            Set<String>()

        for descriptor
            in descriptors
        {
            guard
                descriptorIDs.insert(
                    descriptor.id
                )
                .inserted,
                let reflector =
                    try? registry.resolve(
                        descriptor
                    )
            else {
                continue
            }

            next.append(
                reflector
            )
        }

        var counts:
            [String: Int] = [:]

        for reflector
            in next
        {
            counts[
                reflector.id,
                default: 0
            ] += 1
        }

        return next
            .filter {
                counts[
                    $0.id
                ] == 1
            }
            .sorted {
                $0.id < $1.id
            }
    }
}
