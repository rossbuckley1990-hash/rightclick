import AppKit
import Foundation
import RightClickProtocol
import RightClickProviders

public enum CapabilityReflectorID {
    public static let macOSService = "macos.service"
    public static let macOSSharing = "macos.sharing"
    public static let macOSActionExtension = "macos.action-extension"
}

public enum CapabilityReflectorDefaults {
    public static func all() -> [any CapabilityReflector] {
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
