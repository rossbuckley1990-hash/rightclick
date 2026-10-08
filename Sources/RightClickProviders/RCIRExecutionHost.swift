#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
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
        var expectedArgument: String? = nil
        var trustedOrigin: String? = nil
        var credentialFile: String? = nil
        var jsonObservation: RCIRJSONObservationConfiguration? = nil
    }
    var version = 1
    var revision = "local-confirmation-1"
    var deniedCapabilities: [String] = []
    var observers: [String: Observer]? = nil
    var signingKeyFile: String? = nil
    var receiptTrustPolicyFile: String? = nil

    static func load() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["RIGHTCLICK_RCIR_CONFIG"] else { return Self() }
        let data = try protectedRead(path, maximum: 65_536)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw RCIRError.invalidLimit }
        do { try RCIRReceiptTrustJSON.validateUniqueKeys(data) }
        catch { throw RCIRError.invalidContract }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "revision", "deniedCapabilities", "observers", "signingKeyFile", "receiptTrustPolicyFile"]) else { throw RCIRError.invalidContract }
        if let observers = object["observers"] as? [String: [String: Any]] {
            for value in observers.values {
                guard Set(value.keys).isSubset(of: ["urlTemplate", "expectedArgument", "trustedOrigin", "credentialFile", "jsonObservation"]) else { throw RCIRError.invalidContract }
                if let json = value["jsonObservation"] as? [String: Any] {
                    guard Set(json.keys).isSubset(of: ["schemaJSON", "fields", "invocationBindingPath"]),
                          let fields = json["fields"] as? [String: [String: Any]] else { throw RCIRError.invalidContract }
                    for field in fields.values {
                        guard Set(field.keys).isSubset(of: ["path", "argument", "expectedOutput"]) else { throw RCIRError.invalidContract }
                    }
                }
            }
        }
        let config = try JSONDecoder().decode(Self.self, from: data)
        guard config.version == 1 else { throw RCIRError.invalidContract }
        return config
    }

    static func protectedRead(_ path: String, maximum: Int) throws -> Data {
        try CapabilityProtectedReference.read(path, maximum: maximum)
    }

}

/// Trusted host attachment for one invocation. The grant is immutable; context
/// comes from an authenticated host session, never model/provider metadata. This
/// seam does not itself authenticate MCP clients, operating-system users or peers.
public struct RCIRHostAuthority {
    public let grant: RCIRAuthorityGrant
    private let authenticate: () throws -> RCIRAuthorityContext
    public init(grant: RCIRAuthorityGrant, authenticatedContext: @escaping () throws -> RCIRAuthorityContext) {
        self.grant = grant; authenticate = authenticatedContext
    }
    fileprivate func authenticatedContext() throws -> RCIRAuthorityContext {
        do { return try authenticate() }
        catch { throw RCIRError.authorityDenied }
    }
}

/// One common in-process admission boundary; no alternate provider dispatcher.
/// The owner checks the graph and current host policy/authority immediately
/// before consumption. A consumed lease never causes an automatic HTTP retry.
public final class RCIRExecutionHost {
    private struct ExecutionAuthorization {
        let start: (() throws -> Void)?
        let continuing: (() throws -> Void)?
    }
    private let authorizationLock = NSLock()
    private var executionAuthorizations: [String: ExecutionAuthorization] = [:]

    /// Core supplies authenticated delivery checks separately from provider
    /// authority. Deferred sessions capture ongoing checks, never a new start.
    package func withExecutionAuthorization<T>(executionID: String,
        start: (() throws -> Void)?, continuing: (() throws -> Void)?,
        _ body: () throws -> T) rethrows -> T {
        authorizationLock.lock()
        executionAuthorizations[executionID] = ExecutionAuthorization(start: start,
            continuing: continuing ?? start)
        authorizationLock.unlock()
        defer {
            authorizationLock.lock()
            executionAuthorizations.removeValue(forKey: executionID)
            authorizationLock.unlock()
        }
        return try body()
    }
    let admission = RCIRAdmission()
    private let sessionLock = NSLock()
    private var sessions: [String: RCIRDeferredSession] = [:]
    private var journalSessions: [String: (RCIRInvocationJournal, RCIRInvocationJournal.Ticket)] = [:]
    private var reservations: Set<String> = []
    private let receiptTrustLock = NSLock()
    private var receiptTrustReference: String?
    private var provisionedReceiptTrust: RCIRProvisionedReceiptTrust?
    private let observerFactories: [String: RCIRHostObserverFactory]
    // Trusted, non-mutating time source. Read again at consumption after any
    // protected/configuration callback that may take time.
    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    var configuration: () throws -> RCIRHostConfiguration = RCIRHostConfiguration.load
    var invocationJournal: () throws -> RCIRInvocationJournal? = RCIRJournalConfiguration.load
    // Internal fault hook for native transport adversarial controls. Not exposed
    // in environment configuration, MCP schemas or release command line.
    var consumptionArguments: (CapabilityValue) -> CapabilityValue = { $0 }
    var beforeConsume: ((RCIRLease) throws -> Void)?
    var beforeStart: ((RCIRLease, (_ enqueue: () -> Void) throws -> Void, () -> Void) throws -> Void)?

    public init(observerFactories: [String: RCIRHostObserverFactory] = [:]) {
        self.observerFactories = observerFactories
    }

    /// One retained issuer policy per host, rather than a fresh policy per task.
    /// A changed/removed reference cannot erase revocations or enable fallback.
    private func receiptTrust(_ config: RCIRHostConfiguration) throws -> RCIRProvisionedReceiptTrust? {
        receiptTrustLock.lock(); defer { receiptTrustLock.unlock() }
        guard let path = config.receiptTrustPolicyFile else {
            guard receiptTrustReference == nil else { throw RCIRError.authorityDenied }
            return nil
        }
        guard config.signingKeyFile != nil else { throw RCIRError.authorityDenied }
        if let reference = receiptTrustReference {
            guard reference.utf8.elementsEqual(path.utf8) else { throw RCIRError.authorityDenied }
        } else { receiptTrustReference = path }
        if let provisionedReceiptTrust { return provisionedReceiptTrust }
        let loader = try RCIRProvisionedReceiptTrust(path: path, currentReference: { [weak self] in
            guard let self else { return nil }
            return (try? self.configuration())?.receiptTrustPolicyFile
        }, clock: { [weak self] in self?.now() ?? Int64.max })
        provisionedReceiptTrust = loader
        return loader
    }

    private func currentReceiptTrustMatches(_ expected: String?) -> Bool {
        guard let current = try? configuration() else { return false }
        receiptTrustLock.lock(); defer { receiptTrustLock.unlock() }
        if let expected {
            return current.receiptTrustPolicyFile?.utf8.elementsEqual(expected.utf8) == true &&
                receiptTrustReference?.utf8.elementsEqual(expected.utf8) == true
        }
        // A retained legacy task cannot bypass policy armed by a later task,
        // even if the host reference is subsequently removed again.
        return current.receiptTrustPolicyFile == nil && receiptTrustReference == nil
    }

    /// Refresh a retained task through the existing context_run_status path.
    /// A status read never replays the original provider mutation.
    package func status(_ executionID: String) -> ExecutionRecord? {
        sessionLock.lock(); let session = sessions[executionID]; let journal = journalSessions[executionID]; sessionLock.unlock()
        guard let session else { return nil }
        var record = session.status()
        if let (journal, ticket) = journal { record = session.checkpoint(journal, ticket: ticket) }
        ExecutionStore.shared.put(record)
        if session.canRelease() {
            sessionLock.lock(); sessions.removeValue(forKey: executionID); journalSessions.removeValue(forKey: executionID); sessionLock.unlock()
        }
        return record
    }

    /// Status falls back to durable identity only after live session and volatile
    /// evidence lookup. This path never rehydrates authority or executes a task.
    package func recoveredStatus(_ executionID: String) -> ExecutionRecord? {
        do { return try invocationJournal()?.status(executionID, now: now()) }
        catch {
            return ExecutionRecord(executionId: executionID, actionId: "", state: .unknown,
                message: "Durable execution history is unavailable. The external outcome is unknown. Do not retry blindly.",
                evidence: OutcomeEvidence(type: "rcir_journal_unavailable",
                    boundary: "History could not be read safely; no identity, receipt or zero-effect claim is established. No work was resumed."))
        }
    }

    private func reserveSession(_ executionID: String) throws {
        sessionLock.lock(); let snapshot = sessions; let journals = journalSessions; sessionLock.unlock()
        for (id, session) in snapshot where session.canRelease() {
            var record = session.status(refresh: false)
            if let (journal, ticket) = journals[id] { record = session.checkpoint(journal, ticket: ticket) }
            ExecutionStore.shared.put(record)
            sessionLock.lock()
            if sessions[id] === session { sessions.removeValue(forKey: id); journalSessions.removeValue(forKey: id) }
            sessionLock.unlock()
        }
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard sessions[executionID] == nil, !reservations.contains(executionID),
              sessions.count + reservations.count < 256 else { throw RCIRError.invalidLimit }
        reservations.insert(executionID)
    }

    public func synchronize(owners: Set<String>) {
        synchronize(ownerBytes: Set(owners.map { Data($0.utf8) }))
    }
    package func synchronize(ownerBytes: Set<Data>) {
        for binding in admission.discover() where !ownerBytes.contains(Data(binding.contract.abi.reflectorID.utf8)) {
            admission.withdraw(reflectorID: binding.contract.abi.reflectorID)
        }
    }

    func execute(abi: CapabilityContract, discovery: CapabilityContract, arguments: CapabilityValue,
                 scope: RCIRScope, capability: Capability, executionID: String,
                 argumentStrings: CapabilityArguments?, item: ContentItem,
                 verification: VerificationSpec?, expectedOutput: String?, target: URL,
                 authority: @escaping () -> Set<RCIRScope>, revalidate: @escaping () -> Bool,
                 lifecycle: RCIRDeferredLifecycle? = nil, observerFactory: RCIRHostObserverFactory? = nil,
                 currentContract: @escaping () -> Bool = { true },
                 invocationAuthority: RCIRHostAuthority? = nil,
                 dispatch: (String, (_ start: () -> Void) throws -> Void) throws -> ExecutionRecord,
                 resultValue: (ExecutionRecord) throws -> CapabilityValue) throws -> ExecutionRecord {
        authorizationLock.lock()
        let authorization = executionAuthorizations[executionID]
        authorizationLock.unlock()
        func ongoingAuthorization() -> Bool {
            do { try authorization?.continuing?(); return true }
            catch { return false }
        }
        var dispatched = false
        var reserved = false
        var journalReference: RCIRInvocationJournal?
        var journalTicket: RCIRInvocationJournal.Ticket?
        defer {
            if reserved { sessionLock.lock(); reservations.remove(executionID); sessionLock.unlock() }
        }
        do {
            try authorization?.start?()
            let config = try configuration()
            let journal = try invocationJournal()
            journalReference = journal
            let deferred = lifecycle != nil || capability.metadata["executionMode"] == "deferred"
            let timeout = lifecycle?.timeoutMilliseconds ?? 30_000
            guard timeout > 0, timeout <= 86_400_000 else { throw RCIRError.invalidTime }
            if deferred {
                try reserveSession(executionID); reserved = true
            }
            let configuredJSON = try config.observers?[capability.id]?.structuredObservation(arguments: argumentStrings,
                expectedOutput: expectedOutput, target: target)
            let observation = configuredJSON == nil ? try observer(config, capabilityID: capability.id,
                                           arguments: argumentStrings, target: target) : nil
            guard observerFactory == nil || observerFactories[capability.id] == nil,
                  configuredJSON == nil || (observerFactory == nil && observerFactories[capability.id] == nil) else { throw RCIRError.invalidContract }
            let structured = try configuredJSON ?? (observerFactory ?? observerFactories[capability.id])?(arguments)
            if let structured {
                guard structured.contract.observerID.utf8.elementsEqual(structured.observer.observerID.utf8) else { throw RCIRError.observerMismatch }
            }
            let remainingExpectedOutput = config.observers?[capability.id]?.jsonObservation?.bindsExpectedOutput == true ? nil : expectedOutput
            let returnedPostcondition = verification ?? remainingExpectedOutput.map {
                VerificationSpec(predicates: [.init(type: .textEquals, value: $0)])
            }
            // Multiple observer authorities are ambiguous. A caller postcondition
            // must not be silently discarded when structured observation is used.
            guard structured == nil || (observation == nil && returnedPostcondition == nil) else { throw RCIRError.invalidContract }
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
            } else { combinedObserverContract = structured?.contract ?? observerContract }
            let contract = RCIRContract(abi: abi, scopes: [scope],
                task: RCIRTaskModel(shape: deferred ? .deferred : .unary), verification: combinedObserverContract)
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
            let receiptTrust = try self.receiptTrust(config)
            let signer = try config.signingKeyFile.map {
                try RCIRProvisionedSigner(path: $0, currentReference: { [weak self] in
                    guard let self else { return nil }
                    return (try? self.configuration())?.signingKeyFile
                }, receiptTrust: receiptTrust, currentReceiptTrust: { [weak self] in
                    self?.currentReceiptTrustMatches(config.receiptTrustPolicyFile) == true
                })
            }
            guard contract.scopes?.isSubset(of: authority()) == true else { throw RCIRError.authorityDenied }
            let lease: RCIRLease
            if let attachment = invocationAuthority {
                lease = try admission.issue(binding, arguments: arguments, grant: attachment.grant,
                    authenticated: attachment.authenticatedContext(), policy: policy(config), now: now())
            } else {
                lease = try admission.issue(binding, arguments: arguments, authority: authority(),
                    policy: policy(config), now: now())
            }
            func currentInvocationAuthority() -> Bool {
                guard let attachment = invocationAuthority else { return true }
                do {
                    try self.admission.validateAuthority(attachment.grant, authenticated: attachment.authenticatedContext(),
                        binding: binding, arguments: arguments, now: self.now())
                    return true
                } catch { return false }
            }
            var task = try RCIRTask(lease: lease, startedAt: now(), deadline: now() + timeout)
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
                        // Disk I/O and journal callbacks finish before freezing
                        // consumption inputs. A crash after intent is UNKNOWN.
                        if let journal {
                            journalTicket = try journal.reserveDispatch(
                                RCIRInvocationJournal.Identity(executionID: executionID, task: task), now: self.now())
                        }
                        guard revalidate(), currentContract(), revalidate(), currentInvocationAuthority(),
                              lease.scopes.isSubset(of: authority()) else { throw RCIRError.staleBinding }
                        // Input, authority and configuration refreshes are host
                        // callbacks that may revoke issuer policy. Finish every
                        // consumption input before the final signing check.
                        let currentArguments = self.consumptionArguments(arguments)
                        let currentAuthenticated = try invocationAuthority?.authenticatedContext()
                        let currentPolicy = try policy(self.configuration())
                        try authorization?.start?()
                        try signer?.validateCurrentAuthority()
                        try authorization?.start?()
                        let currentTime = self.now()
                        // Credential ownership can change during configuration,
                        // signer or clock callbacks. Refresh the provider authority
                        // after those callbacks, before the final graph/grant check.
                        let currentAuthority = authority()
                        guard lease.scopes.isSubset(of: currentAuthority) else { throw RCIRError.authorityDenied }
                        // Configuration, credential, signer and clock callbacks
                        // can withdraw the graph. Finish them before this final
                        // contract check and fresh delivery/grant authorization.
                        guard revalidate(), currentContract(), currentInvocationAuthority(), revalidate() else {
                            self.admission.withdraw(reflectorID: abi.reflectorID)
                            throw RCIRError.staleBinding
                        }
                        try authorization?.start?()
                        let start = { dispatched = true; enqueue() }
                        if let attachment = invocationAuthority {
                            guard let currentAuthenticated else { throw RCIRError.authorityDenied }
                            try self.admission.consumeAndStart(lease, arguments: currentArguments,
                                grant: attachment.grant, authenticated: currentAuthenticated,
                                policy: currentPolicy, now: currentTime, start: start)
                        } else {
                            try self.admission.consumeAndStart(lease, arguments: currentArguments, authority: currentAuthority,
                                policy: currentPolicy, now: currentTime, start: start)
                        }
                    }
                    if let hook = self.beforeStart { try hook(lease, admit, start) }
                    else { try admit(start) }
                }
            } catch {
                if !dispatched { throw error }
                // A transport error after dispatch can hide a completed effect.
                record = ExecutionRecord(executionId: executionID, actionId: capability.id,
                    state: .unknown, message: "Dispatch failed after admission; the external outcome is unknown.")
            }
            record.executionId = executionID
            record.actionId = capability.id
            if !dispatched {
                // A compiler/transport may return a preflight error without ever
                // using its admitted start gate. Never manufacture consumption,
                // completion or successful verification from that return value.
                let claimedEffect = [.accepted, .succeeded, .started, .awaitingUser].contains(record.state)
                if claimedEffect {
                    record.state = .unknown
                    record.message = "Provider callback claimed progress without using the admitted start gate; the external outcome is unknown."
                }
                record.verification = nil
                if claimedEffect {
                    record.evidence = OutcomeEvidence(type: "rcir_transport_not_started",
                        boundary: "No admitted provider start was witnessed; callback claims cannot prove whether an external effect occurred.", outcomeVerified: false)
                } else {
                    if record.evidence.type == "none" { record.evidence.type = "rcir_transport_not_started" }
                    record.evidence.boundary += " Preflight returned before an admitted provider start; no provider effect was authorised by this invocation."
                    record.evidence.outcomeVerified = false
                }
                record.rcir = RCIRExecutionEvidence(version: 1, taskID: task.id.uuidString,
                    leaseID: lease.id.uuidString, generation: binding.generation, leaseConsumed: false,
                    phase: task.phase.rawValue, outcome: task.outcome.rawValue, receipt: nil, signedReceipt: nil,
                    observationBoundary: "Independent observation withheld because no admitted start was witnessed.", taskEvents: nil)
                record.events.append("RCIR admitted generation=\(binding.generation); provider start gate was not used.")
                if journal == nil { record.events.append(RCIRJournalConfiguration.volatileBoundary) }
                return record
            }
            if !ongoingAuthorization() || !revalidate() || !currentContract() || !currentInvocationAuthority() || !ongoingAuthorization() {
                admission.withdraw(reflectorID: abi.reflectorID)
                record.state = .unknown
                record.message = "Provider disappeared or changed after dispatch; the external outcome is unknown. Do not retry blindly."
                record.evidence = OutcomeEvidence(type: "rcir_provider_disappeared",
                    boundary: "Dispatch occurred, but the current provider binding is no longer available.")
                try task.providerDisappeared(now: now())
            } else if deferred, record.state == .started || record.state == .accepted || record.state == .succeeded {
                if journal == nil { record.events.append(RCIRJournalConfiguration.volatileBoundary) }
                let boundary = structured?.boundary ?? observation?.boundary ?? "No host-selected independent observer; remote completion remains unverified."
                let initialPolicy = try policy(config).revision
                let session = try RCIRDeferredSession(task: task, record: record, lifecycle: lifecycle,
                    now: now, revalidate: {
                        guard let current = try? policy(self.configuration()), current.revision == initialPolicy else { return false }
                        return ongoingAuthorization() && revalidate() && currentContract() && currentInvocationAuthority() && ongoingAuthorization()
                    }, authority: authority, signer: signer, boundary: boundary,
                    observationBoundary: structured != nil || observation != nil ? .externalState : .none,
                    observe: { task, record in
                        if let structured {
                            let value = try structured.observer.observe(task.observationRequest)
                            guard (try? policy(self.configuration()).revision) == initialPolicy,
                                  revalidate(), currentContract(), currentInvocationAuthority(),
                                  lease.scopes.isSubset(of: authority()), revalidate(), ongoingAuthorization() else { return }
                            try task.verify(observerID: structured.observer.observerID, now: self.now()) { _, _ in value }
                            return
                        }
                        guard let observation,
                              let text = try? self.readBack(observation.url, taskID: task.id.uuidString) else { return }
                        guard (try? policy(self.configuration()).revision) == initialPolicy,
                              revalidate(), currentContract(), currentInvocationAuthority(),
                              lease.scopes.isSubset(of: authority()), revalidate(), ongoingAuthorization() else { return }
                        var observed: CapabilityValue = .string(text)
                        if let returnedPostcondition {
                            let result = try OutcomeVerifier.verify(spec: returnedPostcondition, item: item,
                                before: OutcomeVerifier.snapshot(item: item), returnedText: record.output)
                            record.verification = result
                            guard result.status == .verifiedSuccess || result.status == .verifiedFailure else { return }
                            observed = .object(["external": .string(text), "returned": .boolean(result.status == .verifiedSuccess)])
                        }
                        try task.verify(observerID: observation.url.absoluteString, now: self.now()) { _, _ in observed }
                    })
                sessionLock.lock()
                sessions[executionID] = session; reservations.remove(executionID); reserved = false
                if let journal, let ticket = journalTicket { journalSessions[executionID] = (journal, ticket) }
                sessionLock.unlock()
                var snapshot = session.status(refresh: false)
                if let journal, let ticket = journalTicket { snapshot = session.checkpoint(journal, ticket: ticket) }
                return snapshot
            } else if record.state == .accepted || record.state == .succeeded {
                do {
                    if case .unit? = abi.result {
                        // An acknowledgement with no declared output supplies
                        // no typed result. Only host observation may verify it.
                        record.output = nil
                        try task.record(.completedWithoutOutput, sequence: 1, now: now())
                    } else {
                        try task.record(.completed(resultValue(record)), sequence: 1, now: now())
                    }
                } catch {
                    record.state = .unknown
                    try task.providerDisappeared(now: now())
                }
                if task.phase == .completed, let structured {
                    // An exact host-selected observer reads actual state. Provider
                    // result coordinates are explicitly untrusted locators only.
                    let mayObserve = (try? policy(self.configuration()).revision) == (try? policy(config).revision) &&
                        revalidate() && currentContract() && currentInvocationAuthority() && lease.scopes.isSubset(of: authority()) &&
                        revalidate() && currentContract() && ongoingAuthorization()
                    if mayObserve, let value = try? structured.observer.observe(task.observationRequest),
                       (try? policy(self.configuration()).revision) == (try? policy(config).revision) &&
                       revalidate() && currentContract() && currentInvocationAuthority() && lease.scopes.isSubset(of: authority()) &&
                       revalidate() && ongoingAuthorization() {
                        // Missing/malformed/out-of-bound observations abstain;
                        // they must not discard known completion or its receipt.
                        try? task.verify(observerID: structured.observer.observerID, now: now()) { _, _ in value }
                    }
                    record.state = task.outcome == .succeeded ? .succeeded : (task.outcome == .failed ? .failed : .accepted)
                    switch task.outcome {
                    case .unverified: record.message = "Provider completed; independent structured observation is unavailable."
                    case .succeeded:
                        record.message = structured.contract.invocationBindingPath == nil
                            ? "Independent observation matched the host-declared state predicate; this does not establish current mutation causality."
                            : "Independent observation matched the exact requested state and the host invocation marker."
                    case .failed: record.message = "Independent observation did not match the required state or invocation binding."
                    case .unknown: record.message = "The external outcome is unknown."
                    }
                    record.evidence = OutcomeEvidence(type: "rcir_structured_observation", boundary: structured.boundary,
                        outcomeVerified: task.outcome == .succeeded, observationBoundary: .externalState)
                } else if task.phase == .completed, let observation {
                    // Observe through a separate bounded GET. It is independent
                    // of invocation output, but the same server remains a trust source.
                    let mayObserve = (try? policy(self.configuration()).revision) == (try? policy(config).revision) &&
                        revalidate() && currentContract() && currentInvocationAuthority() && lease.scopes.isSubset(of: authority()) &&
                        revalidate() && currentContract() && ongoingAuthorization()
                    if mayObserve, let text = try? readBack(observation.url, taskID: task.id.uuidString),
                       (try? policy(self.configuration()).revision) == (try? policy(config).revision) &&
                       revalidate() && currentContract() && currentInvocationAuthority() && lease.scopes.isSubset(of: authority()) &&
                       revalidate() && ongoingAuthorization() {
                        var observed: CapabilityValue = .string(text)
                        var complete = true
                        if let returnedPostcondition {
                            let result = try OutcomeVerifier.verify(spec: returnedPostcondition, item: item,
                                before: OutcomeVerifier.snapshot(item: item), returnedText: record.output)
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
                                boundary: observation.boundary, outcomeVerified: true, observationBoundary: .externalState)
                        } else if task.outcome == .failed {
                            record.state = .failed
                            record.message = "Provider accepted, but the required host read-back or caller postcondition failed."
                            record.evidence = OutcomeEvidence(type: "rcir_http_readback_mismatch",
                                boundary: observation.boundary, outcomeVerified: false, observationBoundary: .externalState)
                        }
                    }
                } else if task.phase == .completed, let returnedPostcondition {
                    let result = try OutcomeVerifier.verify(spec: returnedPostcondition, item: item,
                        before: OutcomeVerifier.snapshot(item: item), returnedText: record.output)
                    record.verification = result
                    if result.status == .verifiedSuccess || result.status == .verifiedFailure {
                        try task.verify(observerID: "host:returned-value-postcondition-1", now: now()) { _, _ in
                            .boolean(result.status == .verifiedSuccess)
                        }
                        record.state = task.outcome == .succeeded ? .succeeded : .failed
                        record.evidence = OutcomeEvidence(type: "generic_postcondition",
                            boundary: "Caller-declared returned-value postcondition; verifies returned bytes, not external effects.",
                            outcomeVerified: task.outcome == .succeeded, observationBoundary: .returnedValue)
                    }
                }
            } else if record.state == .unknown {
                try task.providerDisappeared(now: now())
            } else {
                try task.record(.failed, sequence: 1, now: now())
            }
            let emission = try RCIRReceiptEmission(task: task, signer: signer)
            let envelope = try emission.signed.map { try JSONDecoder().decode(RCIRReceiptEnvelope.self, from: $0.wireData()) }
            if emission.signatureWithheld { record.events.append(RCIRReceiptEmission.withheldEvent) }
            record.rcir = RCIRExecutionEvidence(version: 1, taskID: task.id.uuidString,
                leaseID: lease.id.uuidString, generation: binding.generation,
                leaseConsumed: true, phase: task.phase.rawValue, outcome: task.outcome.rawValue,
                receipt: emission.payload.base64EncodedString(), signedReceipt: envelope,
                observationBoundary: structured?.boundary ?? (observation == nil
                    ? (returnedPostcondition == nil ? "No host observer configured; provider completion is unverified."
                        : "Caller-declared returned-value postcondition; no independent external effect observation.")
                    : observation!.boundary), taskEvents: nil)
            record.events.append(contentsOf: ["RCIR admitted generation=\(binding.generation)",
                "RCIR consumed lease=\(lease.id.uuidString)", "RCIR task=\(task.id.uuidString) outcome=\(task.outcome.rawValue)"])
            if let journal, let ticket = journalTicket {
                do { try journal.checkpoint(ticket, task: task, record: record, now: now()) }
                catch { record.events.append(RCIRJournalConfiguration.checkpointFailure) }
            } else { record.events.append(RCIRJournalConfiguration.volatileBoundary) }
            return record
        } catch {
            if !dispatched, let journal = journalReference, let ticket = journalTicket {
                try? journal.notDispatched(ticket, now: now())
            }
            return ExecutionRecord(executionId: executionID, actionId: capability.id, title: capability.title,
                state: dispatched ? .unknown : .rejected,
                message: dispatched ? "RCIR bookkeeping failed after dispatch; the external outcome is unknown. Do not retry blindly." : "RCIR admission failed: \(error)",
                evidence: OutcomeEvidence(type: dispatched ? "rcir_post_dispatch_unknown" : "rcir_admission_denied",
                    boundary: dispatched ? "A consumed invocation may have caused an external effect." : "No provider dispatch was authorised by this invocation."))
        }
    }

    private func observer(_ config: RCIRHostConfiguration, capabilityID: String,
                          arguments: CapabilityArguments?, target: URL) throws -> (url: URL, expected: String, boundary: String)? {
        guard let observer = config.observers?[capabilityID] else { return nil }
        guard observer.jsonObservation == nil, observer.credentialFile == nil,
              let argument = observer.expectedArgument, let expected = arguments?[argument] else { throw RCIRError.invalidContract }
        let template = try RCIRObserverPath.interpolate(observer.urlTemplate, arguments: arguments)
        let observerOrigin: URL
        if let pin = observer.trustedOrigin {
            guard let url = URL(string: pin), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/",
                  OriginPinnedHTTP.sameOrigin(url, url) else { throw RCIRError.invalidContract }
            observerOrigin = url
        } else { observerOrigin = target }
        guard !template.contains("{"), !template.contains("}"),
              let url = URL(string: template), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              OriginPinnedHTTP.sameOrigin(observerOrigin, url) else { throw RCIRError.invalidContract }
        let boundary = observer.trustedOrigin == nil
            ? "Separate same-origin read-back, same service trust source; missing observation remains unverified."
            : "Separate host-pinned observer origin; exact invocation argument postcondition, no provider-selected verification."
        return (url, expected, boundary)
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
