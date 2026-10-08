import Foundation

/// Discovers the CapabilityReflector instances that are currently present
/// in one environment-level discovery substrate.
///
/// A source discovers reflectors. It does not grant authority, invoke
/// capabilities, or establish semantic success.
public protocol CapabilityReflectorSource:
    AnyObject
{
    /// Stable identity of this discovery source.
    var id: String { get }

    /// Return the reflectors currently available from this source.
    ///
    /// The snapshot may change between calls as the environment changes.
    func reflectors()
        -> [any CapabilityReflector]

    /// Withdraw cached acquisition evidence before the next graph observation.
    /// This is a discovery lifecycle operation, never an authority grant.
    func invalidateSnapshot()
}

public extension CapabilityReflectorSource {
    func invalidateSnapshot() {}
}

/// Discovery sources such as ARD registries may depend on the current task
/// or object. The engine passes the already-parsed ContentItem into these
/// sources while preserving the ordinary source contract for non-contextual
/// environment discovery.
public protocol ContextualCapabilityReflectorSource:
    CapabilityReflectorSource
{
    func reflectors(
        for item: ContentItem
    ) -> [any CapabilityReflector]
}
