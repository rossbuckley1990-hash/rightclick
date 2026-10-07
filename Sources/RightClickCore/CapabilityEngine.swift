#if os(macOS)
import AppKit
#endif
import Foundation

public struct ProviderSummary: Codable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var source: String
    public var capabilityTitles: [String]

    public init(
        name: String,
        bundleIdentifier: String? = nil,
        source: String,
        capabilityTitles: [String]
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.source = source
        self.capabilityTitles = capabilityTitles
    }
}

public struct DoctorReport: Codable, Sendable {
    public var platform: String = RuntimePlatform.name
    public var operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
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
    private let rcirHost: RCIRExecutionHost
    private let experience: CapabilityExperience?
    private let fixedReflectors:
        [any CapabilityReflector]

    private let reflectorSources:
        [any CapabilityReflectorSource]

    /// Existing construction path.
    ///
    /// No argument preserves RIGHTCLICK's built-in macOS reflectors.
    /// Passing reflectors explicitly preserves the existing explicit
    /// reflector-injection model.
    public init(
        reflectors: [any CapabilityReflector]? = nil,
        experience: CapabilityExperience? = CapabilityExperience.fromEnvironment(),
        rcirHost: RCIRExecutionHost = RCIRExecutionHost()
    ) {
        self.fixedReflectors =
            reflectors
            ?? CapabilityReflectorDefaults.all()

        self.reflectorSources = []

        self.experience = experience
        self.rcirHost = rcirHost

        Self.prepareApplication()
    }

    /// Dynamic environment-source construction path.
    ///
    /// Sources are queried for their current reflector snapshot whenever
    /// RIGHTCLICK evaluates the live capability graph.
    public init(
        reflectors: [any CapabilityReflector] = [],
        reflectorSources:
            [any CapabilityReflectorSource],
        experience: CapabilityExperience? = CapabilityExperience.fromEnvironment(),
        rcirHost: RCIRExecutionHost = RCIRExecutionHost()
    ) {
        self.fixedReflectors =
            reflectors

        self.reflectorSources =
            reflectorSources

        self.experience = experience
        self.rcirHost = rcirHost

        Self.prepareApplication()
    }

    private static func prepareApplication() {
#if os(macOS)

        let app = NSApplication.shared

        if app.activationPolicy() == .prohibited {
            app.setActivationPolicy(.accessory)
        }

#else

#endif
}

    /// Produce the reflector snapshot for this observation.
    ///
    /// Fixed reflectors remain present. Source-owned reflectors are
    /// re-read every time, so the same CapabilityEngine instance can
    /// observe environment churn without being recreated.
    ///
    /// Duplicate reflector identities fail closed: if more than one
    /// currently visible reflector claims the same id, none of those
    /// ambiguous reflectors enter the live graph.
    private func currentReflectors(
        for item: ContentItem? = nil
    ) -> [any CapabilityReflector]
    {
        var candidates =
            fixedReflectors

        for source in reflectorSources {
            if
                let item,
                let contextual =
                    source
                        as? any ContextualCapabilityReflectorSource
            {
                candidates.append(
                    contentsOf:
                        contextual.reflectors(
                            for:
                                item
                        )
                )
            } else {
                candidates.append(
                    contentsOf:
                        source.reflectors()
                )
            }
        }

        var counts:
            [String: Int] = [:]

        for reflector in candidates {
            counts[reflector.id, default: 0] += 1
        }

        let current = candidates.filter { counts[$0.id] == 1 }
        rcirHost.synchronize(owners: Set(current.map { $0.id }))
        return current
    }

    /// An arbitrary reflector can throw before or after starting an effect.
    /// Release bookkeeping without converting an unobserved error into success
    /// or claiming that no dispatch happened.
    private func releaseReservationAfterThrow(_ executionID: String) {
        ExecutionStore.shared.update(executionID) { record in
            guard record.state == .started || record.state == .awaitingUser else { return }
            record.state = .unknown
            record.message = "The provider entry point threw; its effect was not independently established."
            record.events.append("execution reservation released after thrown provider entry point")
            record.evidence = OutcomeEvidence(type: "execution_error",
                boundary: "A thrown provider entry point leaves the effect unknown; active capacity was released.")
        }
    }

    public func inspect(_ raw: String) throws -> ContentItem {
        try ContentParser.parse(raw)
    }

    public func capabilities(for raw: String) throws -> (item: ContentItem, capabilities: [Capability]) {
        let item = try ContentParser.parse(raw)
        var reflected: [Capability] = []

        for reflector in currentReflectors(for: item) {
            var capabilities =
                try reflector.capabilities(
                    for: item
                )

            // Ownership is assigned by the engine, not trusted from
            // provider metadata. A reflector therefore cannot spoof
            // another reflector's execution route.
            for index in capabilities.indices {
                capabilities[index].reflectorID =
                    reflector.id
                // A provider cannot advertise its own accepted fingerprint.
                capabilities[index].contractSHA256 = nil
            }

            reflected.append(
                contentsOf: capabilities
            )
        }

        let fresh = dedupeCapabilities(reflected).map { capability in
            var owned = capability.withoutDiscoveryAdvice()
            owned.contractSHA256 = try? owned.discoveryContractSHA256()
            return owned
        }
        let combined = experience?.annotate(fresh) ?? fresh
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
#if os(macOS)
        var services = ServiceCatalog.capabilities(for: ContentItem(kind: "text", display: "", text: " ", typeIdentifier: "public.plain-text"))

        for index in services.indices {
            services[index].reflectorID =
                CapabilityReflectorID.macOSService
        }
        let actions = ActionExtensionCatalog.records()
        if let match = services.first(where: { $0.id == id }) {
            return match
        }
        if let record = actions.first(where: { CapabilityID.actionExtension(bundleIdentifier: $0.bundleIdentifier, path: $0.bundlePath) == id }) {
            return Capability(
                id: id,
                title: record.name ?? id,
                source: .actionExtension,
                reflectorID: CapabilityReflectorID.macOSActionExtension,
                provider: CapabilityProvider(name: record.name, bundleIdentifier: record.bundleIdentifier),
                safety: .unknown,
                invocation: .unsupported,
                supportLevel: .publicSupported,
                requiresConfirmation: true,
                metadata: ["bundlePath": record.bundlePath, "note": "Pass an item to evaluate applicability."]
            )
        }
#endif
        throw RightClickError("Capability \(id) was not found. Sharing capabilities only exist in the context of an item.")
    }

    public func run(
        id: String,
        item raw: String,
        confirmed: Bool,
        arguments: CapabilityArguments? = nil,
        expectedOutput: String? = nil,
        verification: VerificationSpec? = nil,
        contractSHA256: String? = nil
    ) throws -> RunResult {
        let executionId = UUID().uuidString
        if let contractSHA256, !CapabilityContract.isValidSHA256(contractSHA256) {
            return RunResult(status: .rejected, actionID: id,
                message: "Invalid contractSHA256. Supply the exact lowercase SHA-256 returned by discovery.")
        }
        let (item, capabilities) =
            try capabilities(for: raw)

        guard let capability =
            selectedCapability(id: id, contractSHA256: contractSHA256, from: capabilities)
        else {
            return RunResult(
                status: .unavailable,
                actionID: id,
                message:
                    contractSHA256 == nil ? "No discovered capability matches \(id) for this item." :
                    "CONTRACT_MISMATCH. The reviewed declaration changed or is unavailable. Discover and review it again; do not retry unpinned automatically."
            )
        }

        if capability.invocation == .unsupported {
            return RunResult(
                status: .unsupported,
                actionID: capability.id,
                title: capability.title,
                message:
                    capability.metadata[
                        "invocationLimitation"
                    ]
                    ?? "No supported public invocation is available for \(capability.title).",
                requiresConfirmation: true,
                supportLevel:
                    capability.supportLevel
            )
        }

        if capability.requiresConfirmation
            && !confirmed
        {
            return RunResult(
                status: .confirmationRequired,
                actionID: capability.id,
                title: capability.title,
                message:
                    "CONFIRMATION_REQUIRED. \(capability.title) is classified as \(capability.safety.rawValue). Re-run with confirmation to invoke it.",
                requiresConfirmation: true,
                supportLevel:
                    capability.supportLevel
            )
        }

        guard
            let reflector =
                reflector(for: capability, item: item)
        else {
            return RunResult(
                status: .unavailable,
                actionID: capability.id,
                title: capability.title,
                message:
                    "The capability or its execution contract changed or is no longer available. Discover and review it again.",
                supportLevel:
                    capability.supportLevel
            )
        }

        let verificationReflector =
            reflector as? any CapabilityVerificationReflector

        let before: OutcomeSnapshot?

        if verificationReflector == nil {
            before = try verification.map {
                _ in
                try OutcomeVerifier.snapshot(
                    item: item
                )
            }
        } else {
            before = nil
        }

        let initial = ExecutionRecord(
            executionId: executionId,
            actionId: capability.id,
            title: capability.title,
            state: .started,
            message: "Execution started.",
            events: [
                "execution created",
                "reflector \(reflector.id)"
            ]
        )

        guard ExecutionStore.shared.put(initial) else {
            return RunResult(status: .rejected, actionID: capability.id, title: capability.title,
                message: "Execution capacity is full; no provider was started.",
                evidence: OutcomeEvidence(type: "execution_capacity",
                    boundary: "Active execution bookkeeping could not be reserved before provider dispatch."))
        }

        let startedRecord: ExecutionRecord

        do {
            if let admitted = reflector as? any RCIRExecutionReflector {
                startedRecord = try admitted.admittedBegin(capability: capability, admissionOwner: capability, item: item,
                    executionID: executionId, arguments: arguments, verification: verification,
                    expectedOutput: expectedOutput, host: rcirHost,
                    revalidate: { [weak self] in self?.reflector(for: capability, item: item) != nil })
            } else if let verification,
               let verificationReflector
            {
                startedRecord =
                    try verificationReflector.begin(
                        capability: capability,
                        item: item,
                        executionID: executionId,
                        arguments: arguments,
                        verification: verification
                    )
            } else {
                startedRecord =
                    try reflector.begin(
                        capability: capability,
                        item: item,
                        executionID: executionId,
                        arguments: arguments
                    )
            }
        } catch {
            releaseReservationAfterThrow(executionId)
            throw error
        }

        var started = startedRecord

        // The engine owns execution identity even if a reflector
        // returns malformed bookkeeping.
        started.executionId = executionId
        started.actionId = capability.id

        if started.title == nil {
            started.title = capability.title
        }

        ExecutionStore.shared.put(started)

        if reflector.completionWaitSeconds > 0,
           Thread.isMainThread,
           started.state == .started
        {
            let deadline =
                Date().addingTimeInterval(
                    reflector
                        .completionWaitSeconds
                )

            while Date() < deadline {
                let current =
                    ExecutionStore.shared.get(
                        executionId
                    )

                if let current,
                   current.state != .started,
                   current.state
                    != .awaitingUser
                {
                    break
                }

                RunLoop.current.run(
                    mode: .default,
                    before:
                        Date()
                        .addingTimeInterval(
                            0.05
                        )
                )
            }
        }

        let final =
            ExecutionStore.shared.get(
                executionId
            ) ?? started

        var providerResult =
            runResult(from: final)

        providerResult.supportLevel =
            capability.supportLevel

        providerResult.requiresConfirmation =
            capability.requiresConfirmation

        if providerResult.title == nil {
            providerResult.title =
                capability.title
        }

        if providerResult.rcir != nil {
            experience?.observe(capability: capability, executionID: executionId, result: providerResult)
            return providerResult
        }
        if verification != nil,
           verificationReflector != nil
        {
            let result = validatedDelegatedVerification(providerResult)
            experience?.observe(capability: capability, executionID: executionId, result: result)
            return result
        }

        if let verification,
           let before
        {
            let result = try applyingVerification(
                verification,
                before: before,
                item: item,
                to: providerResult
            )
            experience?.observe(capability: capability, executionID: executionId, result: result)
            return result
        }

        if let expectedOutput {
            let result = applyingReturnedTextPostcondition(
                expectedOutput,
                item: item,
                to: providerResult
            )
            experience?.observe(capability: capability, executionID: executionId, result: result)
            return result
        }

        experience?.observe(capability: capability, executionID: executionId, result: providerResult)
        return providerResult
    }

    /// Starts an execution and returns without waiting for an asynchronous share callback.
    /// `NSPerformService` is synchronous, so its Boolean result is stored before return.
    public func begin(
        id: String,
        item raw: String,
        confirmed: Bool,
        arguments: CapabilityArguments? = nil,
        expectedOutput: String? = nil,
        verification: VerificationSpec? = nil,
        contractSHA256: String? = nil
    ) throws -> ExecutionRecord {
        let executionId = UUID().uuidString
        if let contractSHA256, !CapabilityContract.isValidSHA256(contractSHA256) {
            let record = ExecutionRecord(executionId: executionId, actionId: id, state: .rejected,
                message: "Invalid contractSHA256. Supply the exact lowercase SHA-256 returned by discovery.")
            ExecutionStore.shared.put(record)
            return record
        }
        let (item, capabilities) =
            try capabilities(for: raw)

        guard let capability =
            selectedCapability(id: id, contractSHA256: contractSHA256, from: capabilities)
        else {
            let record = ExecutionRecord(
                executionId: executionId,
                actionId: id,
                state: .unavailable,
                message:
                    contractSHA256 == nil ? "No discovered capability matches \(id) for this item." :
                    "CONTRACT_MISMATCH. The reviewed declaration changed or is unavailable. Discover and review it again; do not retry unpinned automatically."
            )

            ExecutionStore.shared.put(
                record
            )

            return record
        }

        if capability.invocation == .unsupported {
            let record = ExecutionRecord(
                executionId: executionId,
                actionId: capability.id,
                title: capability.title,
                state: .unsupported,
                message:
                    "No public invocation API for \(capability.title)."
            )

            ExecutionStore.shared.put(
                record
            )

            return record
        }

        if capability.requiresConfirmation
            && !confirmed
        {
            let record = ExecutionRecord(
                executionId: executionId,
                actionId: capability.id,
                title: capability.title,
                state: .awaitingUser,
                message:
                    "CONFIRMATION_REQUIRED. \(capability.title) is \(capability.safety.rawValue)."
            )

            ExecutionStore.shared.put(
                record
            )

            return record
        }

        guard
            let reflector =
                reflector(for: capability, item: item)
        else {
            let record = ExecutionRecord(
                executionId: executionId,
                actionId: capability.id,
                title: capability.title,
                state: .unavailable,
                message:
                    "The capability or its execution contract changed or is no longer available. Discover and review it again."
            )

            ExecutionStore.shared.put(
                record
            )

            return record
        }

        let verificationReflector =
            reflector as? any CapabilityVerificationReflector

        let before: OutcomeSnapshot?

        if verificationReflector == nil {
            before = try verification.map {
                _ in
                try OutcomeVerifier.snapshot(
                    item: item
                )
            }
        } else {
            before = nil
        }

        let initial = ExecutionRecord(
            executionId: executionId,
            actionId: capability.id,
            title: capability.title,
            state: .started,
            message: "Execution started.",
            events: [
                "execution created",
                "reflector \(reflector.id)"
            ]
        )

        guard ExecutionStore.shared.put(initial) else {
            return ExecutionRecord(executionId: executionId, actionId: capability.id, title: capability.title,
                state: .rejected, message: "Execution capacity is full; no provider was started.",
                evidence: OutcomeEvidence(type: "execution_capacity",
                    boundary: "Active execution bookkeeping could not be reserved before provider dispatch."))
        }

        var providerRecord: ExecutionRecord

        do {
            if let admitted = reflector as? any RCIRExecutionReflector {
                providerRecord = try admitted.admittedBegin(capability: capability, admissionOwner: capability, item: item,
                    executionID: executionId, arguments: arguments, verification: verification,
                    expectedOutput: expectedOutput, host: rcirHost,
                    revalidate: { [weak self] in self?.reflector(for: capability, item: item) != nil })
            } else if let verification,
               let verificationReflector
            {
                providerRecord =
                    try verificationReflector.begin(
                        capability: capability,
                        item: item,
                        executionID: executionId,
                        arguments: arguments,
                        verification: verification
                    )
            } else {
                providerRecord =
                    try reflector.begin(
                        capability: capability,
                        item: item,
                        executionID: executionId,
                        arguments: arguments
                    )
            }
        } catch {
            releaseReservationAfterThrow(executionId)
            throw error
        }

        providerRecord.executionId =
            executionId

        providerRecord.actionId =
            capability.id

        if providerRecord.title == nil {
            providerRecord.title =
                capability.title
        }

        ExecutionStore.shared.put(
            providerRecord
        )

        // Asynchronous reflectors remain started. Verification
        // cannot adjudicate an outcome that has not reached an
        // accepted/terminal provider boundary yet.
        if providerRecord.state == .started
            || providerRecord.state
                == .awaitingUser
        {
            return providerRecord
        }

        var result =
            runResult(
                from: providerRecord
            )

        result.supportLevel =
            capability.supportLevel

        result.requiresConfirmation =
            capability.requiresConfirmation

        if result.rcir != nil {
            // Host-selected RCIR observation already adjudicated the outcome.
        } else if verification != nil,
           verificationReflector != nil
        {
            result =
                validatedDelegatedVerification(
                    result
                )
        } else if let verification,
                  let before
        {
            result = try applyingVerification(
                verification,
                before: before,
                item: item,
                to: result
            )
        } else if let expectedOutput {
            result =
                applyingReturnedTextPostcondition(
                    expectedOutput,
                    item: item,
                    to: result
                )
        }

        let final = ExecutionRecord(
            executionId: executionId,
            actionId: capability.id,
            title:
                result.title
                ?? capability.title,
            state:
                executionState(
                    for: result.status
                ),
            message: result.message,
            output: result.output,
            events: providerRecord.events,
            evidence: result.evidence,
            verification:
                result.verification,
            rcir: result.rcir
        )

        ExecutionStore.shared.put(final)
        experience?.observe(capability: capability, executionID: executionId, result: result)

        return final
    }

    /// Legacy calls retain fresh ID/title resolution. A supplied pin never falls
    /// back to an unpinned selection or a conflicting title alias.
    private func selectedCapability(id: String, contractSHA256: String?, from capabilities: [Capability]) -> Capability? {
        let matches = capabilities.filter { $0.id == id || $0.title == id }
        guard let first = matches.first else { return nil }
        guard let contractSHA256 else { return first }
        guard matches.allSatisfy({ $0.contractSHA256 == contractSHA256 }) else { return nil }
        return first
    }

    private func reflector(
        for capability: Capability,
        item: ContentItem
    ) -> (any CapabilityReflector)? {
        guard let reflector = currentReflectors(for: item).first(where: {
            $0.id == capability.reflectorID
        }), let current = try? reflector.capabilities(for: item) else {
            return nil
        }

        // The execution edge must independently still declare the contract
        // selected during this invocation. A stable reflector ID alone is
        // not authority to dispatch a changed endpoint, schema or safety rule.
        // Check only the selected owner's catalog, not every provider again.
        let matches = current.filter { $0.id == capability.id }
        guard !matches.isEmpty else { return nil }

        // These are local, structured snapshots, not signed protocol proofs.
        // Compare encoded bytes rather than Swift String equality, which can
        // equate distinct Unicode spellings in authority-sensitive metadata.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Experience is engine-owned advisory output, not provider authority.
        // Normalize only its reserved namespace on both snapshots. Every
        // endpoint, schema, origin, policy and other metadata byte still binds.
        guard let expected = try? encoder.encode(capability.withoutDiscoveryAdvice()) else { return nil }

        for var candidate in matches {
            // As in discovery, only the engine assigns reflector ownership.
            candidate.reflectorID = reflector.id
            guard let actual = try? encoder.encode(candidate.withoutDiscoveryAdvice()), actual == expected else {
                return nil
            }
        }
        return reflector
    }

    private func validatedDelegatedVerification(
        _ providerResult: RunResult
    ) -> RunResult {
        guard
            providerResult.status
                == .verified
        else {
            return providerResult
        }

        guard
            providerResult
                .verification?
                .status
                == .verifiedSuccess,
            providerResult
                .evidence
                .outcomeVerified
        else {
            var result =
                providerResult

            result.status =
                .accepted

            result.message =
                "Execution substrate claimed verified success without complete delegated verification evidence; downgraded to accepted."

            result.evidence =
                OutcomeEvidence(
                    type:
                        "delegated_verification_incomplete",
                    boundary:
                        "Delegated semantic verification is trusted only when the execution substrate returns VERIFIED_SUCCESS and outcomeVerified=true.",
                    outcomeVerified:
                        false
                )

            return result
        }

        return providerResult
    }

    private func applyingReturnedTextPostcondition(
        _ expectedOutput: String,
        item: ContentItem,
        to providerResult: RunResult
    ) -> RunResult {
        guard
            providerResult.status == .accepted
                || providerResult.status
                    == .verified
        else {
            return providerResult
        }

        var result = providerResult

        guard
            let output = result.output,
            let inputText = item.text,
            output != inputText
        else {
            result.message =
                "Provider accepted the request but supplied no non-echoed declared text output with known input; the postcondition is unverified."

            return result
        }

        let matched =
            output == expectedOutput

        result.status =
            matched
            ? .verified
            : .failed

        result.evidence =
            OutcomeEvidence(
                type:
                    "returned_text_postcondition",
                boundary:
                    "Compared provider-written, declared text output with the caller's exact expected text. This verifies only that returned-text outcome, not external side effects.",
                outcomeVerified:
                    matched
            )

        result.message =
            matched
            ? "Returned text matches the explicit postcondition."
            : "Returned text does not match the explicit postcondition."

        return result
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
            verification: record.verification,
            rcir: record.rcir
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
        for source in reflectorSources {
            source.invalidateSnapshot()
        }
#if os(macOS)
        NSUpdateDynamicServices()

#else

#endif
}

    public func executionStatus(_ executionId: String) -> ExecutionRecord {
        rcirHost.status(executionId) ?? ExecutionStore.shared.get(executionId) ?? ExecutionRecord(
            executionId: executionId,
            actionId: "",
            state: .unknown,
            message: "No execution with that id."
        )
    }

    public func providers() -> [ProviderSummary] {
        var seen = Set<String>()
        var rows: [ProviderSummary] = []

        for reflector in currentReflectors() {
            for provider
                in reflector.providers()
            {
                let key =
                    "\(reflector.id)|\(provider.source)|\(provider.bundleIdentifier ?? "")|\(provider.name)"

                if seen.insert(key).inserted {
                    rows.append(provider)
                }
            }
        }

        return rows.sorted {
            $0.name.localizedCaseInsensitiveCompare(
                $1.name
            ) == .orderedAscending
        }
    }

    public func doctor() -> DoctorReport {
#if os(macOS)

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

#else
        return DoctorReport(
            macosVersion: "", macosBuild: "",
            sharingDiscovery: "UNAVAILABLE", sharingExecution: "UNAVAILABLE", sharingSupportLevel: "macOS adapter unavailable",
            servicesDiscovery: "UNAVAILABLE", servicesExecution: "UNAVAILABLE", servicesSupportLevel: "macOS adapter unavailable",
            quickActionDiscovery: "UNAVAILABLE", quickActionExecution: "UNAVAILABLE", quickActionSupportLevel: "macOS adapter unavailable",
            serviceRegistrationCount: 0, actionExtensionCount: 0,
            notes: ["Portable capability runtime: configured OpenAPI, GraphQL, gRPC, ARD and federation discovery.",
                    "Native macOS discovery, Keychain, ImageIO and launchd integrations require macOS."])

#endif
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
