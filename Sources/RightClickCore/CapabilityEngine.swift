import AppKit
import Darwin
import Foundation

public struct ProviderSummary: Codable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var source: String
    public var capabilityTitles: [String]
}

public struct DoctorReport: Codable, Sendable {
    public var macosVersion: String
    public var macosBuild: String
    public var sharingDiscovery: String
    public var sharingExecution: String
    public var sharingSupportLevel: String
    public var servicesDiscovery: String
    public var servicesExecution: String
    public var servicesSupportLevel: String
    public var quickActionDiscovery: String
    public var quickActionExecution: String
    public var quickActionSupportLevel: String
    public var serviceRegistrationCount: Int
    public var actionExtensionCount: Int
    public var notes: [String]
}

public final class CapabilityEngine {
    public init() {
        let app = NSApplication.shared
        if app.activationPolicy() == .prohibited {
            app.setActivationPolicy(.accessory)
        }
    }

    public func inspect(_ raw: String) throws -> ContentItem {
        try ContentParser.parse(raw)
    }

    public func capabilities(for raw: String) throws -> (item: ContentItem, capabilities: [Capability]) {
        let item = try ContentParser.parse(raw)
        let combined = dedupeCapabilities(
            SharingCatalog.capabilities(for: item)
                + ServiceCatalog.capabilities(for: item)
                + ActionExtensionCatalog.capabilities(for: item)
        )
        let order: [CapabilitySource: Int] = [.service: 0, .sharingService: 1, .actionExtension: 2, .system: 3]
        return (item, combined.sorted { lhs, rhs in
            let left = order[lhs.source] ?? 9
            let right = order[rhs.source] ?? 9
            if left == right { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
            return left < right
        })
    }

    public func describe(id: String, item raw: String?) throws -> Capability {
        if let raw {
            let (_, capabilities) = try capabilities(for: raw)
            if let match = capabilities.first(where: { $0.id == id || $0.title == id }) {
                return match
            }
            throw RightClickError("No capability \(id) applies to this item.")
        }
        let services = ServiceCatalog.capabilities(for: ContentItem(kind: "text", display: "", text: " ", typeIdentifier: "public.plain-text"))
        let actions = ActionExtensionCatalog.records()
        if let match = services.first(where: { $0.id == id }) {
            return match
        }
        if let record = actions.first(where: { CapabilityID.actionExtension(bundleIdentifier: $0.bundleIdentifier, path: $0.bundlePath) == id }) {
            return Capability(
                id: id,
                title: record.name ?? id,
                source: .actionExtension,
                provider: CapabilityProvider(name: record.name, bundleIdentifier: record.bundleIdentifier),
                safety: .unknown,
                invocation: .unsupported,
                supportLevel: .publicSupported,
                requiresConfirmation: true,
                metadata: ["bundlePath": record.bundlePath, "note": "Pass an item to evaluate applicability."]
            )
        }
        throw RightClickError("Capability \(id) was not found. Sharing capabilities only exist in the context of an item.")
    }

    public func run(
        id: String,
        item raw: String,
        confirmed: Bool,
        expectedOutput: String? = nil,
        verification: VerificationSpec? = nil
    ) throws -> RunResult {
        let (item, capabilities) = try capabilities(for: raw)
        guard let capability = capabilities.first(where: { $0.id == id || $0.title == id }) else {
            return RunResult(status: .unavailable, actionID: id, message: "No discovered capability matches \(id) for this item.")
        }
        if capability.invocation == .unsupported {
            return RunResult(
                status: .unsupported,
                actionID: capability.id,
                title: capability.title,
                message: capability.metadata["invocationLimitation"] ?? "No supported public invocation is available for \(capability.title).",
                requiresConfirmation: true,
                supportLevel: capability.supportLevel
            )
        }
        if capability.requiresConfirmation && !confirmed {
            return RunResult(
                status: .confirmationRequired,
                actionID: capability.id,
                title: capability.title,
                message: "CONFIRMATION_REQUIRED. \(capability.title) is classified as \(capability.safety.rawValue). Re-run with confirmation to invoke it.",
                requiresConfirmation: true,
                supportLevel: capability.supportLevel
            )
        }
        switch capability.source {
        case .sharingService:
            let started = try begin(id: capability.id, item: raw, confirmed: confirmed)
            if pthread_main_np() != 0 {
                let deadline = Date().addingTimeInterval(SharingExecutionModel.deadline + 2)
                while Date() < deadline {
                    let current = ExecutionStore.shared.get(started.executionId)
                    if let current, current.state != .started, current.state != .awaitingUser {
                        break
                    }
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
            }
            let final = ExecutionStore.shared.get(started.executionId) ?? started
            return runResult(from: final)
        case .service:
            let before = try verification.map {
                _ in try OutcomeVerifier.snapshot(
                    item: item
                )
            }

            // Generic verification is authoritative when supplied.
            // Preserve the legacy exact-output path only when no
            // VerificationSpec was supplied.
            let providerResult = ServiceCatalog.perform(
                capabilityID: capability.id,
                item: item,
                expectedOutput:
                    verification == nil
                    ? expectedOutput
                    : nil
            )

            guard
                let verification,
                let before
            else {
                return providerResult
            }

            return try applyingVerification(
                verification,
                before: before,
                item: item,
                to: providerResult
            )
        case .actionExtension, .system:
            return RunResult(
                status: .unsupported,
                actionID: capability.id,
                title: capability.title,
                message: "Invocation is not supported for \(capability.source.rawValue).",
                supportLevel: capability.supportLevel
            )
        }
    }

    /// Starts an execution and returns without waiting for an asynchronous share callback.
    /// `NSPerformService` is synchronous, so its Boolean result is stored before return.
    public func begin(
        id: String,
        item raw: String,
        confirmed: Bool,
        expectedOutput: String? = nil,
        verification: VerificationSpec? = nil
    ) throws -> ExecutionRecord {
        let executionId = UUID().uuidString
        let (item, capabilities) = try capabilities(for: raw)
        guard let capability = capabilities.first(where: { $0.id == id || $0.title == id }) else {
            let record = ExecutionRecord(executionId: executionId, actionId: id, state: .unavailable, message: "No discovered capability matches \(id) for this item.")
            ExecutionStore.shared.put(record)
            return record
        }
        if capability.invocation == .unsupported {
            let record = ExecutionRecord(executionId: executionId, actionId: capability.id, title: capability.title, state: .unsupported, message: "No public invocation API for \(capability.title).")
            ExecutionStore.shared.put(record)
            return record
        }
        if capability.requiresConfirmation && !confirmed {
            let record = ExecutionRecord(executionId: executionId, actionId: capability.id, title: capability.title, state: .awaitingUser, message: "CONFIRMATION_REQUIRED. \(capability.title) is \(capability.safety.rawValue).")
            ExecutionStore.shared.put(record)
            return record
        }
        switch capability.source {
        case .sharingService:
            let record = ExecutionRecord(
                executionId: executionId,
                actionId: capability.id,
                title: capability.title,
                state: .started,
                message: "Sharing is in progress.",
                events: ["execution created"]
            )
            ExecutionStore.shared.put(record)
            let actionId = capability.id
            let launch = {
                SharingCatalog.launch(executionId: executionId, capabilityID: actionId, item: item)
            }
            if pthread_main_np() != 0 {
                launch()
            } else {
                DispatchQueue.main.async(execute: launch)
            }
            return ExecutionStore.shared.get(executionId) ?? record
        case .service:
            let before = try verification.map {
                _ in try OutcomeVerifier.snapshot(
                    item: item
                )
            }

            let providerResult = ServiceCatalog.perform(
                capabilityID: capability.id,
                item: item,
                expectedOutput:
                    verification == nil
                    ? expectedOutput
                    : nil
            )

            let result: RunResult

            if let verification,
               let before
            {
                result = try applyingVerification(
                    verification,
                    before: before,
                    item: item,
                    to: providerResult
                )
            } else {
                result = providerResult
            }

            let record = ExecutionRecord(
                executionId: executionId,
                actionId: capability.id,
                title: result.title,
                state: executionState(for: result.status),
                message: result.message,
                output: result.output,
                evidence: result.evidence,
                verification: result.verification
            )
            ExecutionStore.shared.put(record)
            return record
        case .actionExtension, .system:
            let record = ExecutionRecord(executionId: executionId, actionId: capability.id, title: capability.title, state: .unsupported, message: "Invocation is not supported.")
            ExecutionStore.shared.put(record)
            return record
        }
    }

    private func executionState(for status: RunStatus) -> ExecutionState {
        switch status {
        case .accepted: return .accepted
        case .verified: return .succeeded
        case .confirmationRequired: return .awaitingUser
        case .unsupported: return .unsupported
        case .unavailable: return .unavailable
        case .rejected: return .rejected
        case .failed: return .failed
        case .unknown: return .unknown
        }
    }

    private func runResult(from record: ExecutionRecord) -> RunResult {
        let status: RunStatus
        switch record.state {
        case .succeeded:
            status = .verified
        case .accepted: status = .accepted
        case .unsupported: status = .unsupported
        case .unavailable: status = .unavailable
        case .rejected: status = .rejected
        case .awaitingUser:
            status = .confirmationRequired
        case .failed:
            status = .failed
        case .started, .cancelled, .unknown:
            status = .unknown
        }
        return RunResult(
            status: status,
            actionID: record.actionId,
            title: record.title,
            message: record.message,
            output: record.output,
            evidence: record.evidence,
            verification: record.verification
        )
    }

    private func applyingVerification(
        _ spec: VerificationSpec,
        before: OutcomeSnapshot,
        item: ContentItem,
        to providerResult: RunResult
    ) throws -> RunResult {
        // A postcondition can only adjudicate semantic outcome after
        // the invocation itself reached an accepted/verified boundary.
        guard
            providerResult.status == .accepted
            || providerResult.status == .verified
        else {
            return providerResult
        }

        let verification =
            try OutcomeVerifier.verifyEventually(
                spec: spec,
                item: item,
                before: before,
                returnedText: providerResult.output
            )

        var result = providerResult
        result.verification = verification

        switch verification.status {
        case .verifiedSuccess:
            result.status = .verified
            result.message =
                "Caller-declared generic postconditions verified."

            result.evidence = OutcomeEvidence(
                type: "generic_postcondition",
                boundary:
                    "Evaluated provider-independent caller-declared postconditions against observable state after invocation.",
                outcomeVerified: true
            )

        case .verifiedFailure:
            result.status = .failed
            result.message =
                "Caller-declared generic postconditions were evaluated and at least one required predicate failed."

            result.evidence = OutcomeEvidence(
                type: "generic_postcondition",
                boundary:
                    "Evaluated provider-independent caller-declared postconditions against observable state after invocation. The intended outcome was not established.",
                outcomeVerified: false
            )

        case .unverified:
            result.status = .accepted
            result.message =
                "Provider accepted the request, but the caller-declared generic postconditions could not be fully verified."

        case .abstained:
            result.status = .accepted
            result.message =
                "Provider accepted the request; outcome verification abstained."
        }

        return result
    }

    public func refresh() {
        NSUpdateDynamicServices()
    }

    public func executionStatus(_ executionId: String) -> ExecutionRecord {
        ExecutionStore.shared.get(executionId) ?? ExecutionRecord(
            executionId: executionId,
            actionId: "",
            state: .unknown,
            message: "No execution with that id."
        )
    }

    public func providers() -> [ProviderSummary] {
        var grouped: [String: ProviderSummary] = [:]
        for record in ServiceCatalog.records() {
            let key = "service:\(record.bundleIdentifier ?? record.bundlePath)"
            var summary = grouped[key] ?? ProviderSummary(
                name: record.bundleName ?? record.bundleIdentifier ?? record.bundlePath,
                bundleIdentifier: record.bundleIdentifier,
                source: CapabilitySource.service.rawValue,
                capabilityTitles: []
            )
            summary.capabilityTitles.append(record.menuTitle)
            grouped[key] = summary
        }
        for record in ActionExtensionCatalog.records() {
            let key = "action:\(record.bundleIdentifier ?? record.bundlePath)"
            grouped[key] = ProviderSummary(
                name: record.name ?? record.bundleIdentifier ?? record.bundlePath,
                bundleIdentifier: record.bundleIdentifier,
                source: CapabilitySource.actionExtension.rawValue,
                capabilityTitles: [record.name ?? "Action"]
            )
        }
        return grouped.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func doctor() -> DoctorReport {
        let version = macosVersion()
        let services = ServiceCatalog.records()
        let actions = ActionExtensionCatalog.records()
        let sample = ContentItem(kind: "text", display: "doctor", text: "RightClick", typeIdentifier: "public.plain-text")
        let shares = SharingCatalog.capabilities(for: sample)
        return DoctorReport(
            macosVersion: version.product,
            macosBuild: version.build,
            sharingDiscovery: shares.isEmpty ? "FAIL" : "PASS",
            sharingExecution: "API_PRESENT",
            sharingSupportLevel: "public_deprecated",
            servicesDiscovery: services.isEmpty ? "FAIL" : "PASS",
            servicesExecution: "API_PRESENT",
            servicesSupportLevel: "public_supported",
            quickActionDiscovery: actions.isEmpty ? "FAIL" : "PASS",
            quickActionExecution: "UNAVAILABLE",
            quickActionSupportLevel: "public_supported discovery, execution unavailable",
            serviceRegistrationCount: services.count,
            actionExtensionCount: actions.count,
            notes: [
                "Sharing discovery uses NSSharingService.sharingServices(forItems:), which is deprecated in macOS 13 and still returns the context-filtered catalog on this Mac.",
                "NSSharingServicePicker.standardShareMenuItem does not enumerate services. It is a single Share menu item.",
                "Services are read from the documented NSServices Info.plist key and invoked with NSPerformService.",
                "Finder Action extensions are discovered from NSExtension metadata. Direct invocation is unsupported because NSExtension is not in the public SDK.",
                "Private NSExtension runtime matching was probed and is not used by this product.",
            ]
        )
    }
}

private func macosVersion() -> (product: String, build: String) {
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return ("unknown", "unknown") }
    return (plist["ProductVersion"] as? String ?? "unknown", plist["ProductBuildVersion"] as? String ?? "unknown")
}

public enum RightClickJSON {
    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
