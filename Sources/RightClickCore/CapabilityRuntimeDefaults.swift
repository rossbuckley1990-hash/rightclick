import Foundation

/// Built-in environment-level capability discovery sources.
///
/// This registry is product composition, not capability-engine routing.
/// Individual sources remain ordinary CapabilityReflectorSource values.
public enum CapabilityReflectorSourceDefaults {
    public static func all(
        startBrowsing: Bool = true
    ) -> [any CapabilityReflectorSource] {
        var sources:
            [any CapabilityReflectorSource] = [
                ConfiguredOpenAPISource(),
            ]
#if os(Linux)
        sources.append(DBusSessionSource())
#endif
#if os(macOS)
        sources += [
                BonjourOpenAPISource(
                    startBrowsing:
                        startBrowsing
                ),
                BonjourGraphQLSource(
                    startBrowsing:
                        startBrowsing
                ),
            ]
#endif

        if let configuredArtifacts =
            ConfiguredCapabilityArtifactSource
                .fromEnvironment()
        {
            sources.append(
                configuredArtifacts
            )
        }

        if let a2a = ConfiguredA2ASource.fromEnvironment() { sources.append(a2a) }

#if canImport(RightClickARD)
        if let ard =
            ARDRegistrySource
                .fromEnvironment()
        {
            sources.append(
                ard
            )
        }
#endif

#if os(macOS) && canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
        sources.append(
            BonjourGRPCSource(
                startBrowsing:
                    startBrowsing
            )
        )
#endif

        return sources
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
