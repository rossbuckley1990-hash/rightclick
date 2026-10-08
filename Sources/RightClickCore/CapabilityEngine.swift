import RightClickProviders
import RightClickProtocol
import Foundation

public final class CapabilityEngine {
    private let hostExecutionLock = NSRecursiveLock()
    private struct StatusOwner {
        let reflector: (any CapabilityExecutionStatusReflector)?
        let capability: Capability
        let item: ContentItem
        let verification: VerificationSpec?
        let delegatesVerification: Bool
    }
    private let statusOwnerLock = NSLock()
    private var statusOwners: [String: StatusOwner] = [:]
    /// Entry points sharing an engine must share this executor. Native callers
    /// still preserve their main-thread requirement.
    public func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        hostExecutionLock.lock(); defer { hostExecutionLock.unlock() }
        return try body()
    }
    public let runtimeEnvironment: RuntimeEnvironment
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
        rcirHost: RCIRExecutionHost = RCIRExecutionHost(),
        runtimeEnvironment: RuntimeEnvironment = .current
    ) {
        self.fixedReflectors =
            reflectors
            ?? CapabilityReflectorDefaults.all()

        self.reflectorSources = []

        self.experience = experience
        self.rcirHost = rcirHost
        self.runtimeEnvironment = runtimeEnvironment

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
        rcirHost: RCIRExecutionHost = RCIRExecutionHost(),
        runtimeEnvironment: RuntimeEnvironment = .current
    ) {
        self.fixedReflectors =
            reflectors

        self.reflectorSources =
            reflectorSources

        self.experience = experience
        self.rcirHost = rcirHost
        self.runtimeEnvironment = runtimeEnvironment

        Self.prepareApplication()
    }

    private static func prepareApplication() {
        PlatformHostDefaults.host.prepareApplication()
    }

    private func supports(_ capability: Capability, item: ContentItem) -> Bool {
        if runtimeEnvironment.supports(capability) { return true }
        // A configured routing adapter owns the selected execution environment.
        // Complete-contract revalidation still precedes invocation.
        guard let owner = currentReflectors(for: item).first(where: { $0.id == capability.reflectorID }),
              let route = owner as? any CapabilityRoutingReflector else { return false }
        return route.executionEnvironment.supports(capability)
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
            [Data: Int] = [:]

        for reflector in candidates {
            counts[Data(reflector.id.utf8), default: 0] += 1
        }

        let current = candidates.filter { counts[Data($0.id.utf8)] == 1 }
        rcirHost.synchronize(ownerBytes: Set(current.map { Data($0.id.utf8) }))
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

    public func inspect(_ raw: String, allowFileInputs: Bool = true) throws -> ContentItem {
        try ContentParser.parse(raw, allowFileInputs: allowFileInputs)
    }

    public func capabilities(for raw: String, allowFileInputs: Bool = true) throws -> (item: ContentItem, capabilities: [Capability]) {
        let snapshot = try discoverySnapshot(for: raw, allowFileInputs: allowFileInputs)
        return (snapshot.item, snapshot.capabilities)
    }

    private func discoverySnapshot(for raw: String, allowFileInputs: Bool = true) throws -> (item: ContentItem, capabilities: [Capability], quarantinedIDs: Set<Data>) {
        let item = try ContentParser.parse(raw, allowFileInputs: allowFileInputs)
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
                capabilities[index].routingOrigin = (reflector as? any CapabilityRemoteRoutingReflector)?.routingOrigin
            }

            reflected.append(
                contentsOf: capabilities
            )
        }

        let catalog = CapabilitySelection.catalog(reflected)
        let fresh = catalog.capabilities.map { capability in
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
        }, catalog.quarantinedIDs)
    }

    public func describe(id: String, item raw: String?) throws -> Capability {
        if let raw {
            let (_, capabilities, quarantinedIDs) = try discoverySnapshot(for: raw)
            return try CapabilitySelection.resolve(id, from: capabilities, quarantinedIDs: quarantinedIDs)
        }
        return try NativeRuntimeDefaults.describe(id: id)

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
        let (item, capabilities, quarantinedIDs) =
            try discoverySnapshot(for: raw)

        let capability: Capability
        do {
            capability = try selectedCapability(id: id, contractSHA256: contractSHA256, from: capabilities, quarantinedIDs: quarantinedIDs)
        } catch {
            return RunResult(
                status: .unavailable,
                actionID: id,
                message:
                    error.localizedDescription
            )
        }

        guard supports(capability, item: item) else {
            return RunResult(status: .unavailable, actionID: capability.id,
                message: "This runtime does not satisfy the capability requirements.")
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

        if let issue = CapabilityArgumentPreflight.issue(for: capability, arguments: arguments) {
            return RunResult(status: .failed, actionID: capability.id, title: capability.title,
                message: issue.message, requiresConfirmation: capability.requiresConfirmation,
                supportLevel: capability.supportLevel, evidence: issue.evidence)
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
        if !(reflector is any RCIRExecutionReflector) { started.locallyAdmittedRCIR = false }
        started = validatedReceivedRCIR(started, expected: verification)

        // The engine owns execution identity even if a reflector
        // returns malformed bookkeeping.
        started.executionId = executionId
        started.actionId = capability.id

        if started.title == nil {
            started.title = capability.title
        }

        retainStatusOwner(reflector: reflector, capability: capability, item: item, verification: verification, executionID: executionId)
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

        let retained = ExecutionStore.shared.get(executionId) ?? started
        statusOwnerLock.lock(); let retainedOwner = statusOwners[executionId]; statusOwnerLock.unlock()
        let final = validatedRetainedStatus(retained, owner: retainedOwner)

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

        if (reflector is any RCIRExecutionReflector && final.locallyAdmittedRCIR) || final.authenticatedNodeVerification {
            experience?.observe(capability: capability, executionID: executionId, result: providerResult)
            return providerResult
        }
        if verificationReflector != nil
        {
            let result = validatedDelegatedVerification(providerResult, expected: verification)
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
        expectedCapability: Capability? = nil,
        admissionCheck: (() throws -> Void)? = nil,
        continuingAdmissionCheck: (() throws -> Void)? = nil,
        allowFileInputs: Bool = true,
        contractSHA256: String? = nil
    ) throws -> ExecutionRecord {
        try beginExecution(executionId: UUID().uuidString, id: id, item: raw, confirmed: confirmed, arguments: arguments,
            expectedOutput: expectedOutput, verification: verification, expectedCapability: expectedCapability,
            admissionCheck: admissionCheck, continuingAdmissionCheck: continuingAdmissionCheck,
            allowFileInputs: allowFileInputs, contractSHA256: contractSHA256)
    }

    /// Link's durable host reservation assigns the identity before effects. This
    /// seam is package-only; an untrusted request cannot select an execution ID.
    package func beginReserved(
        executionID: UUID,
        id: String,
        item raw: String,
        confirmed: Bool,
        arguments: CapabilityArguments? = nil,
        expectedOutput: String? = nil,
        verification: VerificationSpec? = nil,
        expectedCapability: Capability? = nil,
        admissionCheck: (() throws -> Void)? = nil,
        continuingAdmissionCheck: (() throws -> Void)? = nil,
        allowFileInputs: Bool = true,
        contractSHA256: String? = nil
    ) throws -> ExecutionRecord {
        try beginExecution(executionId: executionID.uuidString, id: id, item: raw, confirmed: confirmed, arguments: arguments,
            expectedOutput: expectedOutput, verification: verification, expectedCapability: expectedCapability,
            admissionCheck: admissionCheck, continuingAdmissionCheck: continuingAdmissionCheck,
            allowFileInputs: allowFileInputs, contractSHA256: contractSHA256)
    }

    private func beginExecution(
        executionId: String,
        id: String,
        item raw: String,
        confirmed: Bool,
        arguments: CapabilityArguments? = nil,
        expectedOutput: String? = nil,
        verification: VerificationSpec? = nil,
        expectedCapability: Capability? = nil,
        admissionCheck: (() throws -> Void)? = nil,
        continuingAdmissionCheck: (() throws -> Void)? = nil,
        allowFileInputs: Bool = true,
        contractSHA256: String? = nil
    ) throws -> ExecutionRecord {
        try admissionCheck?()
        guard ExecutionStore.shared.get(executionId) == nil else {
            throw RightClickError("Execution identity is already retained; do not dispatch it again.")
        }
        if let contractSHA256, !CapabilityContract.isValidSHA256(contractSHA256) {
            let record = ExecutionRecord(executionId: executionId, actionId: id, state: .rejected,
                message: "Invalid contractSHA256. Supply the exact lowercase SHA-256 returned by discovery.")
            ExecutionStore.shared.put(record)
            return record
        }
        let (item, capabilities, quarantinedIDs) =
            try discoverySnapshot(for: raw, allowFileInputs: allowFileInputs)

        let capability: Capability
        do {
            capability = try selectedCapability(id: id, contractSHA256: contractSHA256, from: capabilities, quarantinedIDs: quarantinedIDs)
        } catch {
            let record = ExecutionRecord(
                executionId: executionId,
                actionId: id,
                state: .unavailable,
                message:
                    error.localizedDescription
            )

            ExecutionStore.shared.put(
                record
            )

            return record
        }

        // Link callers bind the exact current declaration, including owner,
        // policy and requirements. Local callers retain the legacy API default.
        guard supports(capability, item: item),
              try expectedCapability.map({ try CapabilityDispatchContract.canonicalData($0) == CapabilityDispatchContract.canonicalData(capability) }) ?? true else {
            let record = ExecutionRecord(executionId: executionId, actionId: id, state: .unavailable,
                message: "The capability contract or runtime requirements changed.")
            ExecutionStore.shared.put(record)
            return record
        }
        try admissionCheck?()

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

        if let issue = CapabilityArgumentPreflight.issue(for: capability, arguments: arguments) {
            let record = ExecutionRecord(executionId: executionId, actionId: capability.id,
                title: capability.title, state: .failed, message: issue.message, evidence: issue.evidence)
            ExecutionStore.shared.put(record)
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

        try admissionCheck?()
        do {
            if let admitted = reflector as? any RCIRExecutionReflector {
                providerRecord = try rcirHost.withExecutionAuthorization(executionID: executionId,
                    start: admissionCheck, continuing: continuingAdmissionCheck) {
                    try admitted.admittedBegin(capability: capability, admissionOwner: capability, item: item,
                    executionID: executionId, arguments: arguments, verification: verification,
                    expectedOutput: expectedOutput, host: rcirHost,
                    revalidate: { [weak self] in
                        guard let self else { return false }
                        return self.reflector(for: capability, item: item) != nil
                    })
                }
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

        if !(reflector is any RCIRExecutionReflector) { providerRecord.locallyAdmittedRCIR = false }
        providerRecord = validatedReceivedRCIR(providerRecord, expected: verification)
        retainStatusOwner(reflector: reflector, capability: capability, item: item, verification: verification, executionID: executionId)

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

        if (reflector is any RCIRExecutionReflector && providerRecord.locallyAdmittedRCIR) || providerRecord.authenticatedNodeVerification {
            // Host-selected RCIR observation already adjudicated the outcome.
        } else if verificationReflector != nil
        {
            result =
                validatedDelegatedVerification(
                    result, expected: verification
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

        var final = ExecutionRecord(
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

        final.locallyAdmittedRCIR = providerRecord.locallyAdmittedRCIR && reflector is any RCIRExecutionReflector
        final.authenticatedNodeVerification = providerRecord.authenticatedNodeVerification
        ExecutionStore.shared.put(final)
        experience?.observe(capability: capability, executionID: executionId, result: result)

        return final
    }

    /// Identity selection precedes pin comparison. Neither an optional pin nor
    /// a title collision may silently choose among conflicting declarations.
    private func selectedCapability(id: String, contractSHA256: String?, from capabilities: [Capability], quarantinedIDs: Set<Data>) throws -> Capability {
        let capability = try CapabilitySelection.resolve(id, from: capabilities, quarantinedIDs: quarantinedIDs)
        if let contractSHA256, capability.contractSHA256 != contractSHA256 {
            throw CapabilitySelectionError.contractMismatch
        }
        return capability
    }

    private func reflector(
        for capability: Capability,
        item: ContentItem
    ) -> (any CapabilityReflector)? {
        let owners = currentReflectors(for: item).filter {
            $0.id.utf8.elementsEqual(capability.reflectorID.utf8)
        }
        guard owners.count == 1, let reflector = owners.first,
              let current = try? reflector.capabilities(for: item) else {
            return nil
        }

        // The execution edge must independently still declare the contract
        // selected during this invocation. A stable reflector ID alone is
        // not authority to dispatch a changed endpoint, schema or safety rule.
        // Check only the selected owner's catalog, not every provider again.
        let matches = current.filter { $0.id.utf8.elementsEqual(capability.id.utf8) }
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
            candidate.routingOrigin = (reflector as? any CapabilityRemoteRoutingReflector)?.routingOrigin
            guard let actual = try? encoder.encode(candidate.withoutDiscoveryAdvice()), actual == expected else {
                return nil
            }
        }
        return reflector
    }

    /// Received RCIR models do not prove admission by this process. A receipt
    /// remains available for separately provisioned trust validation; its mere
    /// presence cannot elevate a provider acknowledgement or forged host claim.
    private func validatedReceivedRCIR(_ input: ExecutionRecord, expected: VerificationSpec?) -> ExecutionRecord {
        guard input.rcir != nil, !input.locallyAdmittedRCIR,
              input.state == .succeeded || (input.state == .failed && input.verification != nil) else { return input }
        let result = validatedDelegatedVerification(runResult(from: input), expected: expected)
        var record = input
        record.state = executionState(for: result.status)
        record.evidence = result.evidence
        record.verification = result.verification
        record.message = result.message
        return record
    }

    private func validatedDelegatedVerification(
        _ providerResult: RunResult, expected: VerificationSpec?
    ) -> RunResult {
        guard
            providerResult.status == .verified ||
                (providerResult.status == .failed && providerResult.verification != nil)
        else {
            return providerResult
        }

        guard
            (providerResult.status == .verified
                ? providerResult.verification?.validatesSuccess(expected: expected) == true && providerResult.evidence.outcomeVerified
                : providerResult.verification?.validatesFailure(expected: expected) == true)
        else {
            var result =
                providerResult

            result.status =
                .accepted
            result.verification = nil

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
        PlatformHostDefaults.host.refreshNativeServices()
    }

    private func retainStatusOwner(reflector: any CapabilityReflector, capability: Capability,
                                   item: ContentItem, verification: VerificationSpec?, executionID: String) {
        statusOwnerLock.lock(); defer { statusOwnerLock.unlock() }
        statusOwners = statusOwners.filter { ExecutionStore.shared.get($0.key) != nil }
        statusOwners[executionID] = StatusOwner(reflector: reflector as? any CapabilityExecutionStatusReflector,
            capability: capability, item: item, verification: verification,
            delegatesVerification: reflector is any CapabilityVerificationReflector && !(reflector is any RCIRExecutionReflector))
    }

    private func validatedRetainedStatus(_ record: ExecutionRecord, owner: StatusOwner?) -> ExecutionRecord {
        if record.authenticatedNodeVerification { return record }
        if owner == nil, !record.locallyAdmittedRCIR,
           record.state == .succeeded || (record.state == .failed && record.verification != nil) {
            var result = record
            result.state = .accepted; result.verification = nil
            result.evidence = OutcomeEvidence(type: "original_verification_unavailable",
                boundary: "Original invocation verification context is unavailable; received status cannot establish verified completion.")
            return result
        }
        if !record.locallyAdmittedRCIR, owner?.delegatesVerification == true,
           record.state == .succeeded || (record.state == .failed && record.verification != nil) {
            let checked = validatedDelegatedVerification(runResult(from: record), expected: owner?.verification)
            var result = record
            result.state = executionState(for: checked.status); result.evidence = checked.evidence
            result.verification = checked.verification; result.message = checked.message
            return result
        }
        return validatedReceivedRCIR(record, expected: owner?.verification)
    }

    public func executionStatus(_ executionId: String) -> ExecutionRecord {
        withExclusiveAccess {
            statusOwnerLock.lock()
            let owner = statusOwners[executionId]
            statusOwnerLock.unlock()
            if let owner, let retained = ExecutionStore.shared.get(executionId),
               [.started, .accepted, .awaitingUser, .unknown].contains(retained.state) {
                // Retained status belongs to the original routing adapter, not
                // a newly selected catalog entry. A discovery TTL cannot revoke
                // already admitted work; the adapter and execution node recheck
                // current enrollment, ownership, contract, policy and authority.
                if let refreshed = owner.reflector?.executionStatus(executionId) { return validatedRetainedStatus(refreshed, owner: owner) }
            }
            if let record = rcirHost.status(executionId) ?? ExecutionStore.shared.get(executionId) ?? rcirHost.recoveredStatus(executionId) {
                return validatedRetainedStatus(record, owner: owner)
            }
            return ExecutionRecord(
                executionId: executionId, actionId: "", state: .unknown, message: "No execution with that id.")
        }
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

    public func doctor() -> DoctorReport { NativeRuntimeDefaults.doctor() }

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
