import RightClickProviders
import RightClickProtocol
import Foundation
#if os(Linux)
import RightClickLinux
#endif

/// Built-in environment-level capability discovery sources.
///
/// This registry is product composition, not capability-engine routing.
/// Individual sources remain ordinary CapabilityReflectorSource values.
/// Callable registrations are the runtime composition and the inventory seam.
/// Unconfigured optional sources remain implemented, never fake live providers.
public struct CapabilitySourceRegistration {
    public let family: String
    public let role: String
    private let construct: ([String: String], Bool) -> (any CapabilityReflectorSource)?
    public init(family: String, role: String,
        construct: @escaping ([String: String], Bool) -> (any CapabilityReflectorSource)?) {
        self.family = family; self.role = role; self.construct = construct
    }
    public func make(environment: [String: String], startBrowsing: Bool) -> (any CapabilityReflectorSource)? {
        construct(environment, startBrowsing)
    }
}

public enum CapabilityArtifactResolverRuntimeDefaults {
    public static func all(environment: [String: String] = ProcessInfo.processInfo.environment) -> [any CapabilityArtifactResolver] {
        var resolvers = CapabilityArtifactResolverDefaults.all()
#if os(Linux)
        resolvers.append(DBusCapabilityArtifactResolver(environment: environment))
#endif
        return resolvers
    }
}

public enum CapabilityReflectorSourceDefaults {
    public static func registrations(
        registry: CapabilityArtifactResolverRegistry = CapabilityArtifactResolverRegistry(resolvers: CapabilityArtifactResolverRuntimeDefaults.all())
    ) -> [CapabilitySourceRegistration] {
        var entries = [
            CapabilitySourceRegistration(family: "openapi", role: "configured_source") { _, _ in ConfiguredOpenAPISource() },
            CapabilitySourceRegistration(family: "generic_artifacts", role: "configured_source") { environment, _ in
                ConfiguredCapabilityArtifactSource.fromEnvironment(environment, registry: registry)
            },
            CapabilitySourceRegistration(family: "a2a", role: "configured_source") { environment, _ in
                ConfiguredA2ASource.fromEnvironment(environment)
            },
            CapabilitySourceRegistration(family: "ard", role: "configured_source") { environment, _ in
                ARDRegistrySource.fromEnvironment(environment)
            },
        ]
#if os(macOS)
        entries += [
            CapabilitySourceRegistration(family: "openapi", role: "bonjour_source") { _, browsing in BonjourOpenAPISource(startBrowsing: browsing) },
            CapabilitySourceRegistration(family: "graphql", role: "bonjour_source") { _, browsing in BonjourGraphQLSource(startBrowsing: browsing) },
            CapabilitySourceRegistration(family: "grpc", role: "bonjour_source") { _, browsing in BonjourGRPCSource(startBrowsing: browsing) },
        ]
#endif
#if os(Linux)
        entries.append(CapabilitySourceRegistration(family: "dbus", role: "native_session_source") { _, _ in
            guard let resolver = registry.registeredResolver(kind: "dbus") as? DBusCapabilityArtifactResolver else { return nil }
            return DBusSessionSource(resolver: resolver)
        })
#endif
        return entries
    }

    public static func all(startBrowsing: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any CapabilityReflectorSource] {
        // These exact factories are audited by the substrate inventory gate.
        let registry = CapabilityArtifactResolverRegistry(resolvers: CapabilityArtifactResolverRuntimeDefaults.all(environment: environment))
        return registrations(registry: registry).compactMap { $0.make(environment: environment, startBrowsing: startBrowsing) }
    }
}

/// Composition root for RIGHTCLICK's ordinary long-lived runtime.
///
/// CapabilityEngine remains unaware of which concrete reflectors or
/// environment discovery mechanisms are enabled by the product.
public enum CapabilityRuntimeDefaults {
    public static func makeEngine(
        reflectors:
            [any CapabilityReflector]? = nil,
        reflectorSources:
            [any CapabilityReflectorSource]? = nil,
        startBrowsing: Bool = true
    ) -> CapabilityEngine {
        let resolvedReflectors =
            reflectors
            ?? CapabilityReflectorDefaults
                .all()

        let resolvedSources =
            reflectorSources
            ?? CapabilityReflectorSourceDefaults
                .all(
                    startBrowsing:
                        startBrowsing
                )

        return CapabilityEngine(
            reflectors:
                resolvedReflectors,
            reflectorSources:
                resolvedSources
        )
    }
}
