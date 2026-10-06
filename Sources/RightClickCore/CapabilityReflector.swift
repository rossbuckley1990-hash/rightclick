import AppKit
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
        verification: VerificationSpec
    ) throws -> ExecutionRecord
}

enum CapabilityReflectorID {
    static let macOSService = "macos.service"
    static let macOSSharing = "macos.sharing"
    static let macOSActionExtension = "macos.action-extension"
}

enum CapabilityReflectorDefaults {
    static func all() -> [any CapabilityReflector] {
        [
            MacOSServiceReflector(),
            MacOSSharingReflector(),
            MacOSActionExtensionReflector(),
        ]
    }
}

private final class MacOSServiceReflector: CapabilityReflector {
    let id = CapabilityReflectorID.macOSService

    func capabilities(
        for item: ContentItem
    ) throws -> [Capability] {
        ServiceCatalog.capabilities(for: item)
    }

    func providers() -> [ProviderSummary] {
        var grouped: [String: ProviderSummary] = [:]

        for record in ServiceCatalog.records() {
            let key =
                "service:\(record.bundleIdentifier ?? record.bundlePath)"

            var summary =
                grouped[key]
                ?? ProviderSummary(
                    name:
                        record.bundleName
                        ?? record.bundleIdentifier
                        ?? record.bundlePath,
                    bundleIdentifier: record.bundleIdentifier,
                    source: CapabilitySource.service.rawValue,
                    capabilityTitles: []
                )

            summary.capabilityTitles.append(
                record.menuTitle
            )

            grouped[key] = summary
        }

        return grouped.values.sorted {
            $0.name.localizedCaseInsensitiveCompare(
                $1.name
            ) == .orderedAscending
        }
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws -> ExecutionRecord {
        let result = ServiceCatalog.perform(
            capabilityID: capability.id,
            item: item,
            expectedOutput: nil
        )

        return reflectorRecord(
            from: result,
            executionID: executionID
        )
    }
}

private final class MacOSSharingReflector: CapabilityReflector {
    let id = CapabilityReflectorID.macOSSharing

    var completionWaitSeconds: TimeInterval {
        SharingExecutionModel.deadline + 2
    }

    func capabilities(
        for item: ContentItem
    ) throws -> [Capability] {
        SharingCatalog.capabilities(for: item)
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws -> ExecutionRecord {
        if ExecutionStore.shared.get(executionID) == nil {
            ExecutionStore.shared.put(
                ExecutionRecord(
                    executionId: executionID,
                    actionId: capability.id,
                    title: capability.title,
                    state: .started,
                    message: "Sharing is in progress.",
                    events: ["execution created"]
                )
            )
        }

        let launch = {
            SharingCatalog.launch(
                executionId: executionID,
                capabilityID: capability.id,
                item: item
            )
        }

        if pthread_main_np() != 0 {
            launch()
        } else {
            DispatchQueue.main.async(
                execute: launch
            )
        }

        return ExecutionStore.shared.get(
            executionID
        ) ?? ExecutionRecord(
            executionId: executionID,
            actionId: capability.id,
            title: capability.title,
            state: .started,
            message: "Sharing is in progress.",
            events: ["execution created"]
        )
    }
}

private final class MacOSActionExtensionReflector:
    CapabilityReflector
{
    let id =
        CapabilityReflectorID.macOSActionExtension

    func capabilities(
        for item: ContentItem
    ) throws -> [Capability] {
        ActionExtensionCatalog.capabilities(
            for: item
        )
    }

    func providers() -> [ProviderSummary] {
        ActionExtensionCatalog.records().map {
            record in

            ProviderSummary(
                name:
                    record.name
                    ?? record.bundleIdentifier
                    ?? record.bundlePath,
                bundleIdentifier:
                    record.bundleIdentifier,
                source:
                    CapabilitySource
                        .actionExtension
                        .rawValue,
                capabilityTitles: [
                    record.name ?? "Action"
                ]
            )
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare(
                $1.name
            ) == .orderedAscending
        }
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws -> ExecutionRecord {
        ExecutionRecord(
            executionId: executionID,
            actionId: capability.id,
            title: capability.title,
            state: .unsupported,
            message:
                "No supported public invocation API for \(capability.title)."
        )
    }
}

private func reflectorExecutionState(
    for status: RunStatus
) -> ExecutionState {
    switch status {
    case .accepted:
        return .accepted
    case .verified:
        return .succeeded
    case .confirmationRequired:
        return .awaitingUser
    case .unsupported:
        return .unsupported
    case .unavailable:
        return .unavailable
    case .rejected:
        return .rejected
    case .failed:
        return .failed
    case .unknown:
        return .unknown
    }
}

private func reflectorRecord(
    from result: RunResult,
    executionID: String
) -> ExecutionRecord {
    ExecutionRecord(
        executionId: executionID,
        actionId: result.actionID,
        title: result.title,
        state: reflectorExecutionState(
            for: result.status
        ),
        message: result.message,
        output: result.output,
        events: [],
        evidence: result.evidence,
        verification: result.verification
    )
}
