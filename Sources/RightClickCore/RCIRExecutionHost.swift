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

public struct RCIRExecutionEvidence: Codable, Sendable {
    public let version: Int
    public let taskID: String
    public let leaseID: String
    public let generation: Int64
    public let leaseConsumed: Bool
    public let phase: String
    public let outcome: String
    public let receipt: String?
    public let signedReceipt: RCIRReceiptEnvelope?
    public let observationBoundary: String
    public let taskEvents: [String]?

    public init(version: Int, taskID: String, leaseID: String, generation: Int64,
                leaseConsumed: Bool, phase: String, outcome: String, receipt: String?,
                signedReceipt: RCIRReceiptEnvelope?, observationBoundary: String,
                taskEvents: [String]? = nil) {
        self.version = version; self.taskID = taskID; self.leaseID = leaseID; self.generation = generation
        self.leaseConsumed = leaseConsumed; self.phase = phase; self.outcome = outcome; self.receipt = receipt
        self.signedReceipt = signedReceipt; self.observationBoundary = observationBoundary; self.taskEvents = taskEvents
    }
}

public struct RCIRReceiptEnvelope: Codable, Sendable {
    public let version: Int
    public let algorithm: String
    public let payload: String
    public let signature: String
    public let publicKey: String
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

    static func load() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["RIGHTCLICK_RCIR_CONFIG"] else { return Self() }
        let data = try protectedRead(path, maximum: 65_536)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "revision", "deniedCapabilities", "observers", "signingKeyFile"]) else { throw RCIRError.invalidContract }
        if let observers = object["observers"] as? [String: [String: Any]] {
            for value in observers.values {
                guard Set(value.keys).isSubset(of: ["urlTemplate", "expectedArgument", "trustedOrigin", "credentialFile", "jsonObservation"]) else { throw RCIRError.invalidContract }
                if let json = value["jsonObservation"] as? [String: Any] {
                    guard Set(json.keys) == ["schemaJSON", "fields"], let fields = json["fields"] as? [String: [String: Any]] else { throw RCIRError.invalidContract }
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

/// One common in-process admission boundary; no alternate provider dispatcher.
/// The owner checks the graph and current host policy/authority immediately
/// before consumption. A consumed lease never causes an automatic HTTP retry.
public final class RCIRExecutionHost {
    let admission = RCIRAdmission()
    private let sessionLock = NSLock()
    private var sessions: [String: RCIRDeferredSession] = [:]
    private var reservations: Set<String> = []
    private let observerFactories: [String: RCIRHostObserverFactory]
    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    var configuration: () throws -> RCIRHostConfiguration = RCIRHostConfiguration.load
    // Internal fault hook for native transport adversarial controls. Not exposed
    // in environment configuration, MCP schemas or release command line.
    var consumptionArguments: (CapabilityValue) -> CapabilityValue = { $0 }
    var beforeConsume: ((RCIRLease) throws -> Void)?
    var beforeStart: ((RCIRLease, (_ enqueue: () -> Void) throws -> Void, () -> Void) throws -> Void)?

    public init(observerFactories: [String: RCIRHostObserverFactory] = [:]) {
        self.observerFactories = observerFactories
    }

    /// Refresh a retained task through the existing context_run_status path.
    /// A status read never replays the original provider mutation.
    func status(_ executionID: String) -> ExecutionRecord? {
        sessionLock.lock(); let session = sessions[executionID]; sessionLock.unlock()
        guard let session else { return nil }
        let record = session.status()
        ExecutionStore.shared.put(record)
        if session.canRelease() {
            sessionLock.lock(); sessions.removeValue(forKey: executionID); sessionLock.unlock()
        }
        return record
    }

    private func reserveSession(_ executionID: String) throws {
        sessionLock.lock(); let snapshot = sessions; sessionLock.unlock()
        for (id, session) in snapshot where session.canRelease() {
            ExecutionStore.shared.put(session.status(refresh: false))
            sessionLock.lock()
            if sessions[id] === session { sessions.removeValue(forKey: id) }
            sessionLock.unlock()
        }
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard sessions[executionID] == nil, !reservations.contains(executionID),
              sessions.count + reservations.count < 256 else { throw RCIRError.invalidLimit }
        reservations.insert(executionID)
    }

    func synchronize(owners: Set<String>) {
        for binding in admission.discover() where !owners.contains(binding.contract.abi.reflectorID) {
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
                 dispatch: (String, (_ start: () -> Void) throws -> Void) throws -> ExecutionRecord,
                 resultValue: (ExecutionRecord) throws -> CapabilityValue) throws -> ExecutionRecord {
        var dispatched = false
        var reserved = false
        defer {
            if reserved { sessionLock.lock(); reservations.remove(executionID); sessionLock.unlock() }
        }
        do {
            let config = try configuration()
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
            let signer = try config.signingKeyFile.map {
                try RCIREd25519Signer(rawPrivateKey: RCIRHostConfiguration.protectedRead($0, maximum: 32))
            }
            let lease = try admission.issue(binding, arguments: arguments, authority: authority(),
                                            policy: policy(config), now: now())
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
                        try self.admission.consumeAndStart(lease, arguments: self.consumptionArguments(arguments), authority: authority(),
                            policy: policy(self.configuration()), now: self.now()) {
                            dispatched = true
                            enqueue()
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
                return record
            }
            if !revalidate() || !currentContract() {
                admission.withdraw(reflectorID: abi.reflectorID)
                record.state = .unknown
                record.message = "Provider disappeared or changed after dispatch; the external outcome is unknown. Do not retry blindly."
                record.evidence = OutcomeEvidence(type: "rcir_provider_disappeared",
                    boundary: "Dispatch occurred, but the current provider binding is no longer available.")
                try task.providerDisappeared(now: now())
            } else if deferred, record.state == .started || record.state == .accepted || record.state == .succeeded {
                let boundary = structured?.boundary ?? observation?.boundary ?? "No host-selected independent observer; remote completion remains unverified."
                let initialPolicy = try policy(config).revision
                let session = try RCIRDeferredSession(task: task, record: record, lifecycle: lifecycle,
                    now: now, revalidate: {
                        guard let current = try? policy(self.configuration()), current.revision == initialPolicy else { return false }
                        return revalidate() && currentContract()
                    }, authority: authority, signer: signer, boundary: boundary,
                    observe: { task, record in
                        if let structured {
                            let value = try structured.observer.observe(task.observationRequest)
                            try task.verify(observerID: structured.observer.observerID, now: self.now()) { _, _ in value }
                            return
                        }
                        guard let observation,
                              let text = try? self.readBack(observation.url, taskID: task.id.uuidString) else { return }
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
                sessionLock.unlock()
                return session.status(refresh: false)
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
                    let mayObserve = revalidate() && currentContract() && lease.scopes.isSubset(of: authority()) &&
                        (try? policy(self.configuration()).revision) == (try? policy(config).revision)
                    if mayObserve, let value = try? structured.observer.observe(task.observationRequest) {
                        // Missing/malformed/out-of-bound observations abstain;
                        // they must not discard known completion or its receipt.
                        try? task.verify(observerID: structured.observer.observerID, now: now()) { _, _ in value }
                    }
                    record.state = task.outcome == .succeeded ? .succeeded : (task.outcome == .failed ? .failed : .accepted)
                    record.message = task.outcome == .unverified ? "Provider completed; independent structured observation is unavailable." : "Independent structured observation determined the exact requested outcome."
                    record.evidence = OutcomeEvidence(type: "rcir_structured_observation", boundary: structured.boundary,
                        outcomeVerified: task.outcome == .succeeded)
                } else if task.phase == .completed, let observation {
                    // Observe through a separate bounded GET. It is independent
                    // of invocation output, but the same server remains a trust source.
                    let mayObserve = revalidate() && currentContract() && lease.scopes.isSubset(of: authority()) &&
                        (try? policy(self.configuration()).revision) == (try? policy(config).revision)
                    if mayObserve, let text = try? readBack(observation.url, taskID: task.id.uuidString) {
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
                                boundary: observation.boundary, outcomeVerified: true)
                        } else if task.outcome == .failed {
                            record.state = .failed
                            record.message = "Provider accepted, but the required host read-back or caller postcondition failed."
                            record.evidence = OutcomeEvidence(type: "rcir_http_readback_mismatch",
                                boundary: observation.boundary, outcomeVerified: false)
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
                observationBoundary: structured?.boundary ?? (observation == nil
                    ? (returnedPostcondition == nil ? "No host observer configured; provider completion is unverified."
                        : "Caller-declared returned-value postcondition; no independent external effect observation.")
                    : observation!.boundary), taskEvents: nil)
            record.events.append(contentsOf: ["RCIR admitted generation=\(binding.generation)",
                "RCIR consumed lease=\(lease.id.uuidString)", "RCIR task=\(task.id.uuidString) outcome=\(task.outcome.rawValue)"])
            return record
        } catch {
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
