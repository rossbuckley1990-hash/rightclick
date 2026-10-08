import RightClickProviders
import RightClickProtocol
import Foundation

public final class CapabilityEngine {
    private let hostExecutionLock = NSRecursiveLock()
    /// Entry points sharing an engine must share this executor. Native callers
    /// still preserve their main-thread requirement.
    public func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        hostExecutionLock.lock(); defer { hostExecutionLock.unlock() }
        return try body()
    }
    public let runtimeEnvironment: RuntimeEnvironment
    private let rcirHost: RCIRExecutionHost
    private var statusReflectors: [String: any CapabilityExecutionStatusReflector] = [:]
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
            [String: Int] = [:]

        for reflector in candidates {
            counts[reflector.id, default: 0] += 1
        }

        let current = candidates.filter { counts[$0.id] == 1 }
        rcirHost.synchronize(owners: Set(current.map { $0.id }))
        return current
    }

    public func inspect(_ raw: String, allowFileInputs: Bool = true) throws -> ContentItem {
        try ContentParser.parse(raw, allowFileInputs: allowFileInputs)
    }

    public func capabilities(for raw: String, allowFileInputs: Bool = true) throws -> (item: ContentItem, capabilities: [Capability]) {
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
            }

            reflected.append(
                contentsOf: capabilities
            )
        }

        let fresh = dedupeCapabilities(reflected).map(CapabilityExperience.withoutExperience)
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
        return try NativeRuntimeDefaults.describe(id: id)

    }

    public func run(
        id: String,
        item raw: String,
        confirmed: Bool,
        arguments: CapabilityArguments? = nil,
        expectedOutput: String? = nil,
        verification: VerificationSpec? = nil
    ) throws -> RunResult {
        let executionId = UUID().uuidString
        let (item, capabilities) =
            try capabilities(for: raw)

        guard let capability =
            capabilities.first(where: {
                $0.id == id || $0.title == id
            })
        else {
            return RunResult(
                status: .unavailable,
                actionID: id,
                message:
                    "No discovered capability matches \(id) for this item."
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

        ExecutionStore.shared.put(initial)

        if let statusOwner = reflector as? any CapabilityExecutionStatusReflector {
            statusReflectors[executionId] = statusOwner
        }

        let startedRecord: ExecutionRecord

        if let admitted = reflector as? any RCIRExecutionReflector {
            startedRecord = try admitted.admittedBegin(capability: capability, admissionOwner: capability, item: item,
                executionID: executionId, arguments: arguments, verification: verification,
                expectedOutput: expectedOutput, host: rcirHost,
                revalidate: { self.reflector(for: capability, item: item) != nil })
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

        var started = startedRecord

        // The engine owns execution identity even if a reflector
        // returns malformed bookkeeping.
        started.executionId = executionId
        started.actionId = capability.id

        if started.title == nil {
            started.title = capability.title
        }

        ExecutionStore.shared.put(started)
        started = ExecutionStore.shared.get(executionId) ?? started

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
        expectedCapability: Capability? = nil,
        admissionCheck: (() throws -> Void)? = nil,
        allowFileInputs: Bool = true
    ) throws -> ExecutionRecord {
        try admissionCheck?()
        let executionId = UUID().uuidString
        let (item, capabilities) =
            try capabilities(for: raw, allowFileInputs: allowFileInputs)

        guard let capability =
            capabilities.first(where: {
                $0.id == id || $0.title == id
            })
        else {
            let record = ExecutionRecord(
                executionId: executionId,
                actionId: id,
                state: .unavailable,
                message:
                    "No discovered capability matches \(id) for this item."
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

        ExecutionStore.shared.put(initial)

        if let statusOwner = reflector as? any CapabilityExecutionStatusReflector {
            statusReflectors[executionId] = statusOwner
        }

        var providerRecord: ExecutionRecord

        try admissionCheck?()

        if let admitted = reflector as? any RCIRExecutionReflector {
            providerRecord = try admitted.admittedBegin(capability: capability, admissionOwner: capability, item: item,
                executionID: executionId, arguments: arguments, verification: verification,
                expectedOutput: expectedOutput, host: rcirHost,
                revalidate: {
                    do { try admissionCheck?(); return self.reflector(for: capability, item: item) != nil }
                    catch { return false }
                })
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
        providerRecord = ExecutionStore.shared.get(executionId) ?? providerRecord

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
            result: providerRecord.result,
            events: providerRecord.events,
            evidence: result.evidence,
            verification:
                result.verification,
            rcir: result.rcir,
            rcirEvents: providerRecord.rcirEvents,
            rcirEventPage: providerRecord.rcirEventPage,
            lifecycle: providerRecord.lifecycle
        )

        ExecutionStore.shared.put(final)
        experience?.observe(capability: capability, executionID: executionId, result: result)

        return ExecutionStore.shared.get(executionId) ?? final
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
        guard let expected = try? encoder.encode(CapabilityExperience.withoutExperience(capability)) else { return nil }

        for var candidate in matches {
            // As in discovery, only the engine assigns reflector ownership.
            candidate.reflectorID = reflector.id
            guard let actual = try? encoder.encode(CapabilityExperience.withoutExperience(candidate)), actual == expected else {
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
            result: record.result,
            evidence: record.evidence,
            verification: record.verification,
            rcir: record.rcir,
            rcirEvents: record.rcirEvents,
            rcirEventPage: record.rcirEventPage,
            lifecycle: record.lifecycle
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
                returnedText: providerResult.output,
                returnedResult: providerResult.result
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

    public func executionStatus(_ executionId: String) -> ExecutionRecord {
        let live = rcirHost.activeExecutionStatus(executionID: executionId)
        let stored = ExecutionStore.shared.get(executionId)
        if stored?.lifecycle?.terminal == true { return stored! }
        return live ?? stored ?? ExecutionRecord(
            executionId: executionId,
            actionId: "",
            state: .unknown,
            message: "No execution with that id."
        )
    }

    /// The same bounded history applies to local and routed execution.
    public func executionStatus(_ executionId: String, cursor: Int64, limit: Int,
                                maximumBytes: Int = 262_144) throws -> ExecutionRecord {
        guard cursor >= 0 else { throw RCIRError.invalidSequence }
        guard (1...256).contains(limit), (1...262_144).contains(maximumBytes) else { throw RCIRError.invalidLimit }
        let live = rcirHost.activeExecutionStatus(executionID: executionId)
        var record = executionStatus(executionId)
        if record.lifecycle?.terminal != true, let live { record = live }
        // Re-read terminal storage after the live lookup: publication can race
        // either lookup, but retained history is installed before live removal.
        if let terminal = ExecutionStore.shared.get(executionId), terminal.lifecycle?.terminal == true {
            record = terminal
        }
        if let page = try ExecutionStore.shared.rcirEventPage(executionId: executionId,
            after: cursor, limit: limit, maximumBytes: maximumBytes) {
            record.rcirEventPage = page
        } else if let page = try rcirHost.activeEventPage(executionID: executionId,
            after: cursor, limit: limit, maximumBytes: maximumBytes) {
            record.rcirEventPage = page
        } else if cursor != 0 {
            record.rcirEventPage = nil
        }
        // Event history is exposed only through the bounded page in status.
        record.rcirEvents = nil
        return record
    }

    /// Captured before dispatch, so later discovery cannot change execution's owner.
    public func executionStatusReflector(_ executionId: String) -> (any CapabilityExecutionStatusReflector)? {
        withExclusiveAccess { statusReflectors[executionId] }
    }

    /// Transport waits happen outside the engine lock and never redispatch.
    public func refreshedExecutionStatus(_ executionId: String, cursor: Int64 = 0,
        limit: Int = 64, maximumBytes: Int = 262_144) async throws -> ExecutionRecord {
        guard cursor >= 0 else { throw RCIRError.invalidSequence }
        guard (1...256).contains(limit), (1...262_144).contains(maximumBytes) else { throw RCIRError.invalidLimit }
        if let owner = executionStatusReflector(executionId),
           let refreshed = try await owner.executionStatus(executionID: executionId, cursor: cursor,
               limit: limit, maximumBytes: maximumBytes) {
            ExecutionStore.shared.put(refreshed)
            return refreshed
        }
        return try withExclusiveAccess {
            try executionStatus(executionId, cursor: cursor, limit: limit, maximumBytes: maximumBytes)
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
