import Foundation

/// Built-in environment-level capability discovery sources.
///
/// This registry is product composition, not capability-engine routing.
/// Individual sources remain ordinary CapabilityReflectorSource values.
public enum CapabilityReflectorSourceDefaults {
    public static func all(
        startBrowsing: Bool = true
    ) -> [any CapabilityReflectorSource] {
        [
            ConfiguredOpenAPISource(),

            BonjourOpenAPISource(
                startBrowsing:
                    startBrowsing
            ),
        ]
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
