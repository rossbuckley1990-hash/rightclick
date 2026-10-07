import CryptoKit
import Darwin
import Foundation

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
    public let receipt: String
    public let signedReceipt: RCIRReceiptEnvelope?
    public let observationBoundary: String
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

    public init() {}

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
                 dispatch: (String, (_ start: () -> Void) throws -> Void) throws -> ExecutionRecord,
                 resultValue: (ExecutionRecord) throws -> CapabilityValue) throws -> ExecutionRecord {
        var dispatched = false
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
            let contract = RCIRContract(abi: abi, scopes: [scope], verification: combinedObserverContract)
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
                        guard revalidate() else { throw RCIRError.staleBinding }
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
            if !revalidate() {
                record.state = .unknown
                record.message = "Provider disappeared or changed after dispatch; the external outcome is unknown. Do not retry blindly."
                record.evidence = OutcomeEvidence(type: "rcir_provider_disappeared",
                    boundary: "Dispatch occurred, but the current provider binding is no longer available.")
                try task.providerDisappeared(now: now())
            } else if record.state == .accepted || record.state == .succeeded {
                do {
                    try task.record(.completed(resultValue(record)), sequence: 1, now: now())
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
                observationBoundary: observation == nil
                    ? (returnedPostcondition == nil ? "No host observer configured; provider completion is unverified."
                        : "Caller-declared returned-value postcondition; no independent external effect observation.")
                    : "Separate same-origin read-back, same service trust source; missing observation remains unverified.")
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
                          arguments: CapabilityArguments?, target: URL) throws -> (url: URL, expected: String)? {
        guard let observer = config.observers?[capabilityID] else { return nil }
        guard let expected = arguments?[observer.expectedArgument] else { throw RCIRError.invalidContract }
        var template = observer.urlTemplate
        // Only path segments can be substituted. Disallow path/query/origin
        // injection, traversal, and unresolved placeholders.
        for (key, value) in arguments ?? [:] where template.contains("{" + key + "}") {
            guard !value.isEmpty, value != ".", value != "..",
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw RCIRError.invalidContract }
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
