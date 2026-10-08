#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Optional generic execution edge. Substrate compilers retain their existing
/// transports; the engine supplies the common admission owner and live graph.
public protocol RCIRExecutionReflector: CapabilityReflector {
    func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem, executionID: String,
                       arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?,
                       host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord
}

/// Host/operator configuration. Never read from provider metadata or tool inputs.
/// A deny list is local policy containment, not issuer credential downscoping.
struct RCIRHostConfiguration: Codable {
    struct Observer: Codable {
        let urlTemplate: String
        let expectedArgument: String
    }
    var version = 1
    var revision = "local-confirmation-1"
    var deniedCapabilities: [String] = []
    var observers: [String: Observer]? = nil
    var signingKeyFile: String? = nil

    static func load() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["RIGHTCLICK_RCIR_CONFIG"] else { return Self() }
        let data = try protectedRead(path, maximum: 65_536)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "revision", "deniedCapabilities", "observers", "signingKeyFile"]) else { throw RCIRError.invalidContract }
        if let observers = object["observers"] as? [String: [String: Any]] {
            for value in observers.values where Set(value.keys) != ["urlTemplate", "expectedArgument"] {
                throw RCIRError.invalidContract
            }
        }
        let config = try JSONDecoder().decode(Self.self, from: data)
        guard config.version == 1 else { throw RCIRError.invalidContract }
        return config
    }

    fileprivate static func protectedRead(_ path: String, maximum: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RCIRError.authorityDenied }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximum else { throw RCIRError.authorityDenied }
        var bytes = [UInt8](repeating: 0, count: maximum + 1)
        var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let n = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!.advanced(by: count), remaining) }
            guard n >= 0 else { throw RCIRError.authorityDenied }
            if n == 0 { break }
            count += n
        }
        guard count <= maximum else { throw RCIRError.invalidLimit }
        return Data(bytes.prefix(count))
    }
}

/// One common in-process admission boundary; no alternate provider dispatcher.
/// The owner checks the graph and current host policy/authority immediately
/// before consumption. A consumed lease never causes an automatic HTTP retry.
public final class RCIRExecutionHost {
    let admission = RCIRAdmission()
    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    var configuration: () throws -> RCIRHostConfiguration = RCIRHostConfiguration.load
    // Internal fault hook for native transport adversarial controls. Not exposed
    // in environment configuration, MCP schemas or release command line.
    var consumptionArguments: (CapabilityValue) -> CapabilityValue = { $0 }
    var beforeConsume: ((RCIRLease) throws -> Void)?
    var beforeStart: ((RCIRLease, (_ enqueue: () -> Void) throws -> Void, () -> Void) throws -> Void)?

    private struct DeferredVerificationPolicy {
        let observation: (url: URL, expected: String)?
        let postcondition: VerificationSpec?
        let item: ContentItem
        let before: OutcomeSnapshot
    }
    private struct ActiveTask {
        var task: RCIRTask
        let generation: Int64
        let signer: (any RCIRReceiptSigning)?
        let observationBoundary: String
        let title: String?
        var verificationPolicy: DeferredVerificationPolicy? = nil
        var pendingTerminal: RCIRTask? = nil
        var verificationResult: OutcomeVerification? = nil
        var verifiedBoundary: OutcomeObservationBoundary = .none
    }
    private let activeTaskLock = NSLock()
    private var activeTasks: [String: ActiveTask] = [:]
    // Process-owned replay containment. Consequential identities are never
    // evicted or reset to make an old invocation executable again.
    private var reservedExecutionIDs: Set<String> = []
    private let maximumExecutionReservations = 1_024
    private let maximumActiveTasks = 1_024

    public init() {}

    private func reserveExecutionID(_ executionID: String) throws {
        guard !executionID.isEmpty, executionID.utf8.count <= 4096,
              executionID.rangeOfCharacter(from: .controlCharacters) == nil,
              !executionID.contains("*") else { throw RCIRError.invalidIdentity }
        activeTaskLock.lock(); defer { activeTaskLock.unlock() }
        guard !reservedExecutionIDs.contains(executionID),
              ExecutionStore.shared.get(executionID)?.lifecycle?.terminal != true else { throw RCIRError.leaseUsed }
        guard reservedExecutionIDs.count < maximumExecutionReservations else { throw RCIRError.invalidLimit }
        reservedExecutionIDs.insert(executionID)
    }

    private func releaseUnstartedExecutionID(_ executionID: String) {
        activeTaskLock.lock(); reservedExecutionIDs.remove(executionID); activeTaskLock.unlock()
    }

    /// Called only after admission succeeds, before any provider callback.
    func registerActiveTask(_ task: RCIRTask, executionID: String,
                                   generation: Int64? = nil,
                                   signer: (any RCIRReceiptSigning)? = nil,
                                   observationBoundary: String? = nil) throws {
        guard !executionID.isEmpty, executionID.utf8.count <= 4096,
              executionID.rangeOfCharacter(from: .controlCharacters) == nil,
              !executionID.contains("*") else { throw RCIRError.invalidIdentity }
        guard task.lease.binding.contract.task.shape != .unary else { throw RCIRError.unsupportedTaskShape }
        guard !task.terminal else { throw RCIRError.invalidTransition }
        activeTaskLock.lock(); defer { activeTaskLock.unlock() }
        guard activeTasks[executionID] == nil, ExecutionStore.shared.get(executionID)?.lifecycle?.terminal != true else {
            throw RCIRError.invalidTransition
        }
        guard activeTasks.count < maximumActiveTasks else { throw RCIRError.invalidLimit }
        activeTasks[executionID] = ActiveTask(task: task, generation: generation ?? task.lease.binding.generation,
            signer: signer, observationBoundary: observationBoundary ?? "No host observer configured; provider completion is unverified.", title: nil)
    }

    public func activeExecutionStatus(executionID: String) -> ExecutionRecord? {
        activeTaskLock.lock(); defer { activeTaskLock.unlock() }
        guard var active = activeTasks[executionID] else { return nil }
        do {
            let stamp = max(now(), active.pendingTerminal?.lastObservationTime ?? active.task.lastObservationTime)
            if let pending = active.pendingTerminal, stamp >= pending.deadline {
                active.task = pending
                try active.task.finalizationFailed(now: stamp)
                active.pendingTerminal = nil
            } else if active.pendingTerminal == nil {
                try active.task.checkDeadline(now: stamp)
            }
            if active.task.terminal {
                let record = try terminalRecord(active, executionID: executionID)
                try ExecutionStore.shared.putTerminal(record, events: active.task.typedEvents)
                activeTasks[executionID] = nil
                return record
            }
            activeTasks[executionID] = active
            var record = try snapshot(active, executionID: executionID)
            if active.pendingTerminal != nil { record.message = "Provider completion received; host verification is pending." }
            return record
        } catch { return nil }
    }

    public func activeEventPage(executionID: String, after cursor: Int64 = 0, limit: Int = 64,
                                maximumBytes: Int = 262_144) throws -> RCIRExecutionEventPage? {
        activeTaskLock.lock(); let task = activeTasks[executionID]?.task; activeTaskLock.unlock()
        guard let task else { return nil }
        return try task.statusEventPage(after: cursor, limit: limit, maximumBytes: maximumBytes)
    }

    @discardableResult
    public func recordActiveTaskEvent(executionID: String, event: RCIRTaskEvent, now: Int64) throws -> RCIRTask? {
        activeTaskLock.lock()
        guard var active = activeTasks[executionID] else { activeTaskLock.unlock(); throw RCIRError.unavailable }
        guard active.pendingTerminal == nil else { activeTaskLock.unlock(); throw RCIRError.invalidTransition }
        var next = active.task
        do { try next.record(event, sequence: next.sequence + 1, now: now) }
        catch {
            if error as? RCIRError == .bufferFull || error as? CapabilityABIError == .limitExceeded || next.terminal {
                do {
                    try next.providerDisappeared(now: now)
                    active.task = next
                    let record = try terminalRecord(active, executionID: executionID)
                    try ExecutionStore.shared.putTerminal(record, events: active.task.typedEvents)
                    activeTasks[executionID] = nil
                } catch { activeTaskLock.unlock(); throw error }
            }
            activeTaskLock.unlock(); throw error
        }
        if next.phase == .completed, active.verificationPolicy != nil {
            // Keep the prior nonterminal snapshot visible while the captured
            // host policy adjudicates the pending completion. No terminal view
            // may later change verification, and no observer runs under the
            // admission or live-registry lock, including synchronous callbacks.
            active.pendingTerminal = next
            activeTasks[executionID] = active
            activeTaskLock.unlock()
            let pendingTaskID = next.id
            DispatchQueue.global(qos: .utility).async { [self] in
                finalizeDeferredExecution(executionID: executionID, taskID: pendingTaskID)
            }
            return nil
        }
        active.task = next
        if next.terminal {
            do {
                let record = try terminalRecord(active, executionID: executionID)
                try ExecutionStore.shared.putTerminal(record, events: next.typedEvents)
                activeTasks[executionID] = nil
                activeTaskLock.unlock()
                return next
            } catch { activeTaskLock.unlock(); throw error }
        }
        activeTasks[executionID] = active
        activeTaskLock.unlock()
        return nil
    }

    @discardableResult
    public func markActiveTaskUnknown(executionID: String, now: Int64) throws -> RCIRTask? {
        activeTaskLock.lock(); defer { activeTaskLock.unlock() }
        guard var active = activeTasks[executionID] else { return nil }
        if let pending = active.pendingTerminal {
            active.task = pending
            try active.task.finalizationFailed(now: max(now, pending.lastObservationTime))
            active.pendingTerminal = nil
        } else { try active.task.providerDisappeared(now: max(now, active.task.lastObservationTime)) }
        let record = try terminalRecord(active, executionID: executionID)
        try ExecutionStore.shared.putTerminal(record, events: active.task.typedEvents)
        activeTasks[executionID] = nil
        return active.task
    }

    private func hasPendingFinalization(executionID: String) -> Bool {
        activeTaskLock.lock(); defer { activeTaskLock.unlock() }
        return activeTasks[executionID]?.pendingTerminal != nil
    }

    private func installDeferredVerification(_ policy: DeferredVerificationPolicy?, executionID: String) {
        activeTaskLock.lock(); defer { activeTaskLock.unlock() }
        activeTasks[executionID]?.verificationPolicy = policy
    }

    private func finalizeDeferredExecution(executionID: String, taskID: UUID) {
        activeTaskLock.lock()
        guard var active = activeTasks[executionID], let pending = active.pendingTerminal,
              pending.id == taskID, let policy = active.verificationPolicy else { activeTaskLock.unlock(); return }
        activeTaskLock.unlock()
        active.task = pending
        active.pendingTerminal = nil
        do {
            let stamp = max(now(), pending.lastObservationTime)
            if stamp >= pending.deadline { try active.task.finalizationFailed(now: stamp) }
            else { try adjudicateDeferred(&active, policy: policy) }
        } catch {
            try? active.task.finalizationFailed(now: max(now(), active.task.lastObservationTime))
            active.verificationResult = nil
            active.verifiedBoundary = .none
        }
        activeTaskLock.lock(); defer { activeTaskLock.unlock() }
        // Disappearance/deadline may have won while observation was in flight.
        // A late verifier cannot replace that immutable UNKNOWN publication.
        guard activeTasks[executionID]?.pendingTerminal?.id == taskID else { return }
        do {
            let record = try terminalRecord(active, executionID: executionID)
            try ExecutionStore.shared.putTerminal(record, events: active.task.typedEvents)
            activeTasks[executionID] = nil
        } catch {
            // The registry retains the complete pending copy for a safe status
            // finalization attempt rather than recreating nonterminal work.
            try? active.task.finalizationFailed(now: max(now(), active.task.lastObservationTime))
            activeTasks[executionID] = active
        }
    }

    private func adjudicateDeferred(_ active: inout ActiveTask, policy: DeferredVerificationPolicy) throws {
        let returnedText: String?
        switch active.task.result {
        case let .string(text)?: returnedText = text
        case let .bytes(bytes)?: returnedText = String(data: bytes, encoding: .utf8)
        default: returnedText = nil
        }
        var returned: OutcomeVerification?
        if var specification = policy.postcondition {
            let remaining = max(0, active.task.deadline - max(now(), active.task.lastObservationTime))
            specification.timeoutMilliseconds = min(specification.timeoutMilliseconds ?? 0, Int(remaining))
            returned = try OutcomeVerifier.verifyEventually(spec: specification, item: policy.item, before: policy.before,
                returnedText: returnedText, returnedResult: active.task.result)
        }
        let observation = policy.observation.flatMap { try? readBack($0.url, taskID: active.task.id.uuidString) }
        let stamp = max(now(), active.task.lastObservationTime)
        guard stamp < active.task.deadline else { try active.task.finalizationFailed(now: stamp); return }
        let returnedComplete = returned == nil || returned?.status == .verifiedSuccess || returned?.status == .verifiedFailure
        if let observer = policy.observation, let observation, returnedComplete {
            let value: CapabilityValue = returned == nil ? .string(observation)
                : .object(["external": .string(observation), "returned": .boolean(returned?.status == .verifiedSuccess)])
            try active.task.verify(observerID: observer.url.absoluteString, now: stamp) { _, _ in value }
            active.verifiedBoundary = .externalState
        } else if policy.observation == nil, let returned, returnedComplete {
            try active.task.verify(observerID: "host:returned-value-postcondition-1", now: stamp) { _, _ in
                .boolean(returned.status == .verifiedSuccess)
            }
            active.verifiedBoundary = policy.postcondition?.predicates.allSatisfy {
                $0.type == .textEquals || $0.type == .resultPathEquals
            } == true ? .returnedValue : .externalState
        }
        let aggregate: OutcomeVerificationStatus = active.task.outcome == .succeeded ? .verifiedSuccess
            : (active.task.outcome == .failed ? .verifiedFailure : .unverified)
        active.verificationResult = .init(status: aggregate, predicates: returned?.predicates ?? [])
    }

    public func requestActiveTaskCancellation(executionID: String, now: Int64) throws {
        activeTaskLock.lock(); defer { activeTaskLock.unlock() }
        guard var active = activeTasks[executionID] else { throw RCIRError.unavailable }
        guard active.pendingTerminal == nil else { throw RCIRError.invalidTransition }
        try active.task.requestCancellation(now: now)
        activeTasks[executionID] = active
    }

    public func retainTerminalHistory(_ task: RCIRTask, executionID: String) {
        guard task.terminal else { return }
        try? ExecutionStore.shared.putRCIRHistory(task.typedEvents, executionId: executionID)
    }

    public func synchronize(owners: Set<String>) {
        for binding in admission.discover() where !owners.contains(binding.contract.abi.reflectorID) {
            admission.withdraw(reflectorID: binding.contract.abi.reflectorID)
        }
        activeTaskLock.lock()
        let removed = activeTasks.filter { !owners.contains($0.value.task.lease.binding.contract.abi.reflectorID) }.map(\.key)
        activeTaskLock.unlock()
        for executionID in removed { _ = try? markActiveTaskUnknown(executionID: executionID, now: now()) }
    }

    private func lifecycle(_ active: ActiveTask, executionID: String, receipt: Bool, signed: Bool) -> ExecutionLifecycle {
        let task = active.task
        let acceptance: ExecutionProviderAcceptance
        if task.typedEvents.contains(where: { $0.kind == "accepted" || $0.kind == "completed" }) { acceptance = .accepted }
        else if task.phase == .unknown { acceptance = .unknown }
        else if task.phase == .failed { acceptance = .rejected }
        else { acceptance = .unknown }
        return .init(executionID: executionID, originatingRequestID: executionID, taskID: task.id.uuidString,
            generation: active.generation, taskShape: task.lease.binding.contract.task.shape,
            phase: task.phase, semanticOutcome: task.outcome, sequence: task.sequence, terminal: task.terminal,
            providerAcceptance: acceptance, verification: task.outcome == .succeeded ? .verifiedSuccess : (task.outcome == .failed ? .verifiedFailure : .unverified),
            observationBoundary: active.verifiedBoundary, evidenceID: task.terminal ? task.id.uuidString : nil,
            receiptAvailable: receipt, signedReceiptAvailable: signed)
    }

    private func snapshot(_ active: ActiveTask, executionID: String) throws -> ExecutionRecord {
        let task = active.task
        let state: ExecutionState
        switch task.phase {
        case .completed: state = task.outcome == .succeeded ? .succeeded : (task.outcome == .failed ? .failed : .accepted)
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        case .unknown: state = .unknown
        case .inputRequired: state = .awaitingUser
        default: state = .started
        }
        return .init(executionId: executionID, actionId: task.lease.binding.contract.abi.capabilityID,
            title: active.title, state: state, message: task.terminal ? "Provider lifecycle ended; semantic outcome remains independently adjudicated." : "Provider execution is live.",
            result: task.result, events: ["RCIR task=\(task.id.uuidString) phase=\(task.phase.rawValue)"],
            evidence: .init(type: task.terminal ? "rcir_terminal" : "rcir_live", boundary: active.observationBoundary,
                outcomeVerified: task.outcome == .succeeded, observationBoundary: active.verifiedBoundary),
            verification: active.verificationResult, rcirEvents: task.typedEvents, rcirEventPage: try task.statusEventPage(),
            lifecycle: lifecycle(active, executionID: executionID, receipt: false, signed: false))
    }

    private func terminalRecord(_ original: ActiveTask, executionID: String) throws -> ExecutionRecord {
        var active = original
        var signed: RCIRSignedReceipt?
        var signingFailed = false
        do { signed = try active.signer.map { try RCIRSignedReceipt.sign(active.task, using: $0) } }
        catch {
            // Receipt-signing failure occurs after an effect may exist. Keep
            // all accepted events, terminalize UNKNOWN, and retain safe unsigned
            // evidence without rereading or rotating the admitted signer.
            try active.task.finalizationFailed(now: max(now(), active.task.lastObservationTime))
            active.verificationResult = nil
            active.verifiedBoundary = .none
            signingFailed = true
        }
        let task = active.task
        var record = try snapshot(active, executionID: executionID)
        let payload = try task.receiptData()
        let envelope = try signed.map { try JSONDecoder().decode(RCIRReceiptEnvelope.self, from: $0.wireData()) }
        let boundary = signingFailed ? "Admission-time receipt signing failed; retained unsigned history cannot attest the external outcome. Do not retry blindly." : active.observationBoundary
        record.rcir = .init(version: 1, taskID: task.id.uuidString, leaseID: task.lease.id.uuidString,
            generation: active.generation, leaseConsumed: true, phase: task.phase.rawValue,
            outcome: task.outcome.rawValue, receipt: payload.base64EncodedString(), signedReceipt: envelope,
            observationBoundary: boundary)
        if signingFailed {
            record.message = "Receipt finalization failed after provider dispatch; the outcome is unknown."
            record.evidence = .init(type: "rcir_signing_failed", boundary: boundary)
        }
        record.lifecycle = lifecycle(active, executionID: executionID, receipt: true, signed: envelope != nil)
        return record
    }

    public func execute(abi: CapabilityContract, discovery: CapabilityContract, arguments: CapabilityValue,
                 scope: RCIRScope, taskModel: RCIRTaskModel = .init(),
                 capability: Capability, executionID: String,
                 argumentStrings: CapabilityArguments?, item: ContentItem,
                 verification: VerificationSpec?, expectedOutput: String?, target: URL,
                 authority: @escaping () -> Set<RCIRScope>, revalidate: @escaping () -> Bool,
                 currentContract: @escaping () -> Bool,
                 dispatch: (String, (_ start: () -> Void) throws -> Void) throws -> ExecutionRecord,
                 resultValue: (ExecutionRecord) throws -> CapabilityValue) throws -> ExecutionRecord {
        do { try reserveExecutionID(executionID) }
        catch {
            return .init(executionId: executionID, actionId: capability.id, title: capability.title,
                state: .rejected, message: "RCIR execution identity was already reserved or its reservation limit was reached; no provider dispatch was authorized.",
                evidence: .init(type: "rcir_execution_identity_denied", boundary: "Identity reservation rejected before provider invocation."))
        }
        var dispatched = false
        defer { if !dispatched { releaseUnstartedExecutionID(executionID) } }
        do {
            let config = try configuration()
            let observation = try observer(config, capabilityID: capability.id,
                                           arguments: argumentStrings, target: target)
            let returnedPostcondition = verification ?? expectedOutput.map {
                VerificationSpec(predicates: [.init(type: .textEquals, value: $0)])
            }
            // Legacy returned-value postconditions remain supported, with their
            // limited trust boundary explicit. They prove returned bytes only.
            let observerContract = observation.map {
                RCIRVerificationContract(observerID: $0.url.absoluteString, schema: .string, expected: .string($0.expected))
            } ?? returnedPostcondition.map { _ in
                RCIRVerificationContract(observerID: "host:returned-value-postcondition-1", schema: .boolean, expected: .boolean(true))
            }
            let combinedObserverContract: RCIRVerificationContract?
            if let observation, returnedPostcondition != nil {
                combinedObserverContract = RCIRVerificationContract(observerID: observation.url.absoluteString,
                    schema: .object(properties: ["external": .string, "returned": .boolean], required: ["external", "returned"]),
                    expected: .object(["external": .string(observation.expected), "returned": .boolean(true)]))
            } else { combinedObserverContract = observerContract }
            let contract = RCIRContract(
                abi: abi,
                scopes: [scope],
                task: taskModel,
                verification: combinedObserverContract
            )
            let principal = "local-owner:" + abi.reflectorID
            let binding = try admission.publishInvocation(contract, discovery: discovery, authenticatedPrincipal: principal)
            func policy(_ config: RCIRHostConfiguration) throws -> RCIRPolicy {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let encoded = try encoder.encode(config)
                let fingerprint = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
                return RCIRPolicy(revision: config.revision + ":" + fingerprint,
                                  principals: [principal],
                                  scopes: config.deniedCapabilities.contains(capability.id) ? [] : [scope])
            }
            // Key errors are discovered before the provider can have an effect.
            let signer = try config.signingKeyFile.map {
                try RCIREd25519Signer(rawPrivateKey: RCIRHostConfiguration.protectedRead($0, maximum: 32))
            }

            let deferredObservationBoundary =
                observation == nil
                    ? (
                        returnedPostcondition == nil
                            ? "No host observer configured; provider completion is unverified."
                            : "Caller-declared returned-value postcondition; no independent external effect observation."
                    )
                    : "Separate same-origin read-back, same service trust source; missing observation remains unverified."

            let deferredVerificationPolicy: DeferredVerificationPolicy?
            if taskModel.shape != .unary, observation != nil || returnedPostcondition != nil {
                deferredVerificationPolicy = .init(observation: observation, postcondition: returnedPostcondition,
                    item: item, before: try OutcomeVerifier.snapshot(item: item))
            } else { deferredVerificationPolicy = nil }

            let lease = try admission.issue(binding, arguments: arguments, authority: authority(),
                                            policy: policy(config), now: now())
            var task = try RCIRTask(lease: lease, startedAt: now(), deadline: now() + 30_000)
            try beforeConsume?(lease)
            guard revalidate() else {
                admission.withdraw(reflectorID: abi.reflectorID)
                throw RCIRError.staleBinding
            }
            var record: ExecutionRecord
            do {
                record = try dispatch(task.id.uuidString) { start in
                    let admit: (_ enqueue: () -> Void) throws -> Void = { enqueue in
                        // Refresh at the transport boundary too: transport setup
                        // may outlive the earlier graph check. Refresh outside
                        // the admission lock because it can withdraw bindings.
                        guard revalidate(), currentContract(), revalidate() else {
                            self.admission.withdraw(reflectorID: abi.reflectorID)
                            throw RCIRError.staleBinding
                        }
                        var deferredRegistrationError: Error?

                        try self.admission.consumeAndStart(
                            lease,
                            arguments:
                                self.consumptionArguments(
                                    arguments
                                ),
                            authority:
                                authority(),
                            policy:
                                policy(
                                    self.configuration()
                                ),
                            now:
                                self.now()
                        ) {
                            if taskModel.shape != .unary {
                                do {
                                    try self.registerActiveTask(
                                        task,
                                        executionID:
                                            executionID,
                                        generation:
                                            binding.generation,
                                        signer:
                                            signer,
                                        observationBoundary:
                                            deferredObservationBoundary
                                    )
                                    self.installDeferredVerification(deferredVerificationPolicy, executionID: executionID)
                                } catch {
                                    deferredRegistrationError =
                                        error

                                    // Lease consumption has succeeded, but no
                                    // provider code may run without a live RCIR
                                    // task available for synchronous callbacks.
                                    return
                                }
                            }

                            dispatched = true
                            enqueue()
                        }

                        if let deferredRegistrationError {
                            throw deferredRegistrationError
                        }
                    }
                    if let hook = self.beforeStart { try hook(lease, admit, start) }
                    else { try admit(start) }
                }
            } catch {
                if !dispatched {
                    throw error
                }

                // A transport error after dispatch can hide a completed effect.
                // Deferred execution was already registered before provider
                // start, so terminate that live task UNKNOWN rather than leave
                // an orphan in the active registry.
                if
                    taskModel.shape != .unary,
                    let unknownTask =
                        try? markActiveTaskUnknown(
                            executionID:
                                executionID,
                            now:
                                now()
                        )
                {
                    task = unknownTask
                }

                record = ExecutionRecord(
                    executionId:
                        executionID,
                    actionId:
                        capability.id,
                    state:
                        .unknown,
                    message:
                        "Dispatch failed after admission; the external outcome is unknown."
                )
            }
            guard dispatched else { throw RCIRError.authorityDenied }
            if taskModel.shape != .unary {
                // A synchronous callback can finish before dispatch returns.
                // Its immutable publication takes precedence over that late
                // initial record, and is already receipt-bearing.
                if let terminal = ExecutionStore.shared.get(executionID), terminal.lifecycle?.terminal == true {
                    return terminal
                }
                if !revalidate() || !currentContract() {
                    admission.withdraw(reflectorID: abi.reflectorID)
                    _ = try markActiveTaskUnknown(executionID: executionID, now: now())
                } else {
                    // A synchronous terminal callback owns its pending typed
                    // completion. A late acceptance/success return is not a
                    // second callback and must not destroy host adjudication.
                    // Explicit post-effect uncertainty still wins UNKNOWN.
                    if hasPendingFinalization(executionID: executionID) {
                        if [.started, .awaitingUser, .accepted, .succeeded].contains(record.state) {
                            if let live = activeExecutionStatus(executionID: executionID) { return live }
                            if let terminal = ExecutionStore.shared.get(executionID), terminal.lifecycle?.terminal == true { return terminal }
                        } else {
                            // Completion and a contradictory negative provider
                            // return cannot establish a reliable effect outcome.
                            _ = try markActiveTaskUnknown(executionID: executionID, now: now())
                            if let terminal = ExecutionStore.shared.get(executionID) { return terminal }
                        }
                    }
                    switch record.state {
                    case .started, .awaitingUser:
                        if var live = activeExecutionStatus(executionID: executionID) {
                            live.title = record.title ?? capability.title
                            live.message = record.message
                            live.output = record.output
                            live.events.append(contentsOf: record.events)
                            return live
                        }
                    case .accepted, .succeeded:
                        do { _ = try recordActiveTaskEvent(executionID: executionID, event: .completed(resultValue(record)), now: now()) }
                        catch { _ = try? markActiveTaskUnknown(executionID: executionID, now: now()) }
                    case .unknown:
                        _ = try markActiveTaskUnknown(executionID: executionID, now: now())
                    case .cancelled:
                        _ = try recordActiveTaskEvent(executionID: executionID, event: .cancelled, now: now())
                    default:
                        _ = try recordActiveTaskEvent(executionID: executionID, event: .failed, now: now())
                    }
                }
                if let terminal = ExecutionStore.shared.get(executionID), terminal.lifecycle?.terminal == true { return terminal }
                if let live = activeExecutionStatus(executionID: executionID) { return live }
                throw RCIRError.unavailable
            }
            if !revalidate() || !currentContract() {
                admission.withdraw(reflectorID: abi.reflectorID)
                record.state = .unknown
                record.message = "Provider disappeared or changed after dispatch; the external outcome is unknown. Do not retry blindly."
                record.evidence = OutcomeEvidence(type: "rcir_provider_disappeared",
                    boundary: "Dispatch occurred, but the current provider binding is no longer available.")
                try task.providerDisappeared(now: now())
            } else if record.state == .accepted || record.state == .succeeded {
                do {
                    let completedResult = try resultValue(record)
                    try task.record(.completed(completedResult), sequence: 1, now: now())
                    record.result = completedResult
                } catch {
                    record.state = .unknown
                    try task.providerDisappeared(now: now())
                }
                if task.phase == .completed, let observation {
                    // Observe through a separate bounded GET. It is independent
                    // of invocation output, but the same server remains a trust source.
                    if let text = try? readBack(observation.url, taskID: task.id.uuidString) {
                        var observed: CapabilityValue = .string(text)
                        var complete = true
                        if let returnedPostcondition {
                            let result = try OutcomeVerifier.verify(spec: returnedPostcondition, item: item,
                                before: OutcomeVerifier.snapshot(item: item), returnedText: record.output, returnedResult: record.result)
                            record.verification = result
                            complete = result.status == .verifiedSuccess || result.status == .verifiedFailure
                            observed = .object(["external": .string(text), "returned": .boolean(result.status == .verifiedSuccess)])
                        }
                        if complete {
                            try task.verify(observerID: observation.url.absoluteString, now: now()) { _, _ in observed }
                        }
                        if task.outcome == .succeeded {
                            record.state = .succeeded
                            record.message = "The host independently read back the exact requested result."
                            record.evidence = OutcomeEvidence(type: "rcir_http_readback",
                                boundary: "Host-selected same-origin GET; exact invocation resource and argument postcondition. Same service trust source.", outcomeVerified: true)
                        } else if task.outcome == .failed {
                            record.state = .failed
                            record.message = "Provider accepted, but the required host read-back or caller postcondition failed."
                            record.evidence = OutcomeEvidence(type: "rcir_http_readback_mismatch",
                                boundary: "Separate host-selected read-back proved an exact argument-bound mismatch.", outcomeVerified: false)
                        }
                    }
                } else if task.phase == .completed, let returnedPostcondition {
                    let result = try OutcomeVerifier.verify(spec: returnedPostcondition, item: item,
                        before: OutcomeVerifier.snapshot(item: item), returnedText: record.output, returnedResult: record.result)
                    record.verification = result
                    if result.status == .verifiedSuccess || result.status == .verifiedFailure {
                        try task.verify(observerID: "host:returned-value-postcondition-1", now: now()) { _, _ in
                            .boolean(result.status == .verifiedSuccess)
                        }
                        record.state = task.outcome == .succeeded ? .succeeded : .failed
                        record.evidence = OutcomeEvidence(type: "generic_postcondition",
                            boundary: "Caller-declared returned-value postcondition; verifies ABI-validated returned value, not external effects.",
                            outcomeVerified: task.outcome == .succeeded)
                    }
                }
            } else if record.state == .unknown {
                try task.providerDisappeared(now: now())
            } else {
                try task.record(.failed, sequence: 1, now: now())
            }
            let payload = try task.receiptData()
            let signed = try signer.map { try RCIRSignedReceipt.sign(task, using: $0) }
            let envelope = try signed.map { try JSONDecoder().decode(RCIRReceiptEnvelope.self, from: $0.wireData()) }
            record.rcir = RCIRExecutionEvidence(version: 1, taskID: task.id.uuidString,
                leaseID: lease.id.uuidString, generation: binding.generation,
                leaseConsumed: true, phase: task.phase.rawValue, outcome: task.outcome.rawValue,
                receipt: payload.base64EncodedString(), signedReceipt: envelope,
                observationBoundary: observation == nil
                    ? (returnedPostcondition == nil ? "No host observer configured; provider completion is unverified."
                        : "Caller-declared returned-value postcondition; no independent external effect observation.")
                    : "Separate same-origin read-back, same service trust source; missing observation remains unverified.")
            record.events.append(contentsOf: ["RCIR admitted generation=\(binding.generation)",
                "RCIR consumed lease=\(lease.id.uuidString)", "RCIR task=\(task.id.uuidString) outcome=\(task.outcome.rawValue)"])
            record.rcirEvents = task.typedEvents
            record.rcirEventPage = try task.statusEventPage()
            if task.phase == .completed, task.outcome == .unverified { record.state = .accepted }
            let boundary: OutcomeObservationBoundary = observation != nil && task.outcome != .unverified ? .externalState
                : (returnedPostcondition != nil && task.outcome != .unverified ? .returnedValue : .none)
            record.lifecycle = .init(executionID: executionID, originatingRequestID: executionID,
                taskID: task.id.uuidString, generation: binding.generation, taskShape: taskModel.shape,
                phase: task.phase, semanticOutcome: task.outcome, sequence: task.sequence, terminal: task.terminal,
                providerAcceptance: task.phase == .unknown ? .unknown : (task.phase == .completed ? .accepted : .rejected),
                verification: task.outcome == .succeeded ? .verifiedSuccess : (task.outcome == .failed ? .verifiedFailure : .unverified),
                observationBoundary: boundary, evidenceID: task.id.uuidString,
                receiptAvailable: true, signedReceiptAvailable: envelope != nil)
            try ExecutionStore.shared.putTerminal(record, events: task.typedEvents)

            return record
        } catch {
            if dispatched {
                _ = try? markActiveTaskUnknown(executionID: executionID, now: now())
                if let terminal = ExecutionStore.shared.get(executionID), terminal.lifecycle?.terminal == true { return terminal }
            }
            return ExecutionRecord(executionId: executionID, actionId: capability.id, title: capability.title,
                state: dispatched ? .unknown : .rejected,
                message: dispatched ? "RCIR bookkeeping failed after dispatch; the external outcome is unknown. Do not retry blindly." : "RCIR admission failed: \(error)",
                evidence: OutcomeEvidence(type: dispatched ? "rcir_post_dispatch_unknown" : "rcir_admission_denied",
                    boundary: dispatched ? "A consumed invocation may have caused an external effect." : "No provider dispatch was authorised by this invocation."))
        }
    }

    private func observer(_ config: RCIRHostConfiguration, capabilityID: String,
                          arguments: CapabilityArguments?, target: URL) throws -> (url: URL, expected: String)? {
        guard let observer = config.observers?[capabilityID] else { return nil }
        guard let expected = arguments?[observer.expectedArgument] else { throw RCIRError.invalidContract }
        var template = observer.urlTemplate
        // Only path segments can be substituted. Disallow path/query/origin
        // injection, traversal, and unresolved placeholders.
        let segmentCharacters = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for (key, value) in arguments ?? [:] where template.contains("{" + key + "}") {
            guard !value.isEmpty, value != ".", value != "..",
                  value.unicodeScalars.allSatisfy({ segmentCharacters.contains($0) }),
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: segmentCharacters) else { throw RCIRError.invalidContract }
            template = template.replacingOccurrences(of: "{" + key + "}", with: encoded)
        }
        guard !template.contains("{"), !template.contains("}"),
              let url = URL(string: template), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              OriginPinnedHTTP.sameOrigin(target, url) else { throw RCIRError.invalidContract }
        return (url, expected)
    }

    private func readBack(_ url: URL, taskID: String) throws -> String {
        // Existing bounded, redirect-rejecting acquisition transport; no arbitrary
        // HTTP executor is exposed to the agent. Read-back is host configured.
        var request = URLRequest(url: url)
        request.setValue(taskID, forHTTPHeaderField: "X-RightClick-Invocation")
        let data = try OriginPinnedHTTP.loadObservation(request, maximumBytes: 131_072)
        guard data.count <= 131_072, let text = String(data: data, encoding: .utf8) else { throw RCIRError.unverified }
        return text
    }
}
