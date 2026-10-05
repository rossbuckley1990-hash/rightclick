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
}
