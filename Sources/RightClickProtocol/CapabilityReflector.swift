import Foundation

/// A substrate reflector converts provider-specific capability contracts into
/// RIGHTCLICK's normalized capability model and performs provider invocation.
///
/// Semantic verification deliberately remains above this boundary.
public typealias CapabilityArguments =
    [String: String]

public protocol CapabilityReflector: AnyObject {
    /// Stable identity for this reflector instance.
    var id: String { get }

    /// Maximum period CapabilityEngine.run may wait for an asynchronous
    /// execution started by this reflector.
    var completionWaitSeconds: TimeInterval { get }

    /// Return the capabilities from this substrate that apply to this item.
    func capabilities(for item: ContentItem) throws -> [Capability]

    /// Return provider summaries exposed by this reflector.
    func providers() -> [ProviderSummary]

    /// Begin provider invocation.
    ///
    /// The returned record describes the provider boundary only.
    /// Provider acceptance must not be treated as semantic success.
    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws -> ExecutionRecord

    /// Begin invocation with provider-independent structured
    /// arguments.
    ///
    /// Reflectors that do not consume structured arguments inherit
    /// the default implementation, which preserves their existing
    /// behaviour.
    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments: CapabilityArguments?
    ) throws -> ExecutionRecord
}

/// Acquisition caches may retain a compiled snapshot. A compiler marks it stale
/// when an execution-boundary check observes changed or unavailable source bytes.
/// Reacquisition changes discovery only; it never grants execution authority.
public protocol CapabilityContractRefreshingReflector: CapabilityReflector {
    var requiresContractRefresh: Bool { get }
    func refreshContract() throws -> any CapabilityReflector
}

public extension CapabilityReflector {
    var completionWaitSeconds: TimeInterval { 0 }

    func providers() -> [ProviderSummary] {
        []
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments: CapabilityArguments?
    ) throws -> ExecutionRecord {
        try begin(
            capability: capability,
            item: item,
            executionID: executionID
        )
    }
}

/// A reflector can implement this protocol when semantic verification must
/// occur at the execution boundary rather than on the caller runtime.
///
/// The CapabilityEngine still validates any claimed verified success before
/// exposing it as VERIFIED. Ordinary reflectors continue to use the local
/// OutcomeVerifier and do not need to implement this protocol.
public protocol CapabilityVerificationReflector:
    CapabilityReflector
{
    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments: CapabilityArguments?,
        arguments: CapabilityArguments?,
        verification: VerificationSpec
    ) throws -> ExecutionRecord
}
