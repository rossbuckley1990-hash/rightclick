import Foundation
import RightClickProtocol
import RightClickProviders

/// The executing node's enrolled lease subject is installed by its host. Link
/// separately authenticates incoming clients against local caller grants. This
/// identity is not Codable or selectable in contextual arguments or metadata.
public struct EnvironmentCallerIdentity {
    public let publicKey: Data
    public let runtimeID: String
    public let environmentID: String
    public let leaseID: UUID
    public init(publicKey: Data, runtimeID: String, environmentID: String, leaseID: UUID) throws {
        guard publicKey.count == 32, EnvironmentIdentity.isRuntimeID(runtimeID),
              EnvironmentIdentity.isCanonicalID(environmentID) else { throw EnvironmentFabricError.invalidRequest }
        self.publicKey = publicKey; self.runtimeID = runtimeID; self.environmentID = environmentID; self.leaseID = leaseID
    }
}

/// Additive contextual source; normal startup remains unchanged until a host
/// explicitly installs a provider, protected journal, profiles and caller pins.
public final class EnvironmentCapabilitySource: ContextualCapabilityReflectorSource, CapabilityExecutionStatusAccessSource, CapabilityExecutionNodeBoundSource {
    public let id: String
    private let owner: EnvironmentCapabilityReflector
    public var executionNodePublicKey: Data? { owner.caller?.publicKey }
    public var executionNodeRuntimeID: String? { owner.caller?.runtimeID }
    public func permitsRetainedStatus(executionID: String) throws -> Bool? {
        guard try owner.coordinator.executionRecord(executionID) != nil else { return nil }
        return try owner.ownsExecution(executionID: executionID)
    }
    public init(coordinator: EnvironmentCoordinator, spec: EnvironmentSpec,
                caller: EnvironmentCallerIdentity? = nil,
                prerequisites: [String: [ExecutionDependency]] = [:],
                afterBootstrap: ((EnvironmentRecord) throws -> Void)? = nil,
                afterWorkload: ((String) throws -> Void)? = nil) throws {
        guard let ceiling = coordinator.profileCeilings[spec.profileID], spec.isWithin(ceiling) else {
            throw EnvironmentFabricError.invalidProfile
        }
        guard prerequisites.count <= 6, prerequisites.values.allSatisfy({ $0.count <= 8 }),
              Set(prerequisites.keys).isSubset(of: ["environment:create", "environment:create-child", "environment:bootstrap", "environment:execute", "environment:destroy", "environment:observe"]) else {
            throw EnvironmentFabricError.invalidRequest
        }
        id = "environment.fabric." + (caller?.environmentID ?? "operator")
        owner = EnvironmentCapabilityReflector(id: id, coordinator: coordinator, spec: spec,
            caller: caller, prerequisites: prerequisites, afterBootstrap: afterBootstrap, afterWorkload: afterWorkload)
    }
    public func reflectors() -> [any CapabilityReflector] { [owner] }
    public func reflectors(for item: ContentItem) -> [any CapabilityReflector] { item.kind == "environment" ? [owner] : [] }
}

private final class EnvironmentCapabilityReflector: RCIRExecutionReflector, CapabilityExecutionRecoveryReflector {
    let id: String
    let coordinator: EnvironmentCoordinator
    let spec: EnvironmentSpec
    let caller: EnvironmentCallerIdentity?
    let prerequisites: [String: [ExecutionDependency]]
    let afterBootstrap: ((EnvironmentRecord) throws -> Void)?
    let afterWorkload: ((String) throws -> Void)?
    init(id: String, coordinator: EnvironmentCoordinator, spec: EnvironmentSpec, caller: EnvironmentCallerIdentity?,
         prerequisites: [String: [ExecutionDependency]],
         afterBootstrap: ((EnvironmentRecord) throws -> Void)?, afterWorkload: ((String) throws -> Void)?) {
        self.id = id; self.coordinator = coordinator; self.spec = spec; self.caller = caller
        self.prerequisites = prerequisites
        self.afterBootstrap = afterBootstrap; self.afterWorkload = afterWorkload
    }
    func providers() -> [ProviderSummary] {
        [.init(name: "Ephemeral execution fabric", source: "environment", capabilityTitles: ["Create environment", "Observe environment", "Bootstrap runtime", "Execute approved challenge", "Create child environment", "Destroy environment hierarchy"])]
    }
    func capabilities(for item: ContentItem) throws -> [Capability] {
        guard item.kind == "environment", let uri = item.url else { return [] }
        let target: String?
        if uri == EnvironmentIdentity.factoryURI { guard caller == nil else { return [] }; target = nil }
        else { target = try EnvironmentIdentity.environmentID(from: uri); if let caller, target != caller.environmentID { return [] } }
        let choices: [(String, String, CapabilitySafety)] = target == nil
            ? [("environment:create", "Create environment", .financial)]
            : [("environment:observe", "Observe environment", .read), ("environment:bootstrap", "Bootstrap runtime", .codeExecution),
               ("environment:execute", "Execute approved challenge", .codeExecution), ("environment:create-child", "Create child environment", .financial),
               ("environment:destroy", "Destroy environment hierarchy", .destructive)]
        return try choices.compactMap { action, title, safety in
            guard try coordinator.canSatisfyDependencies(prerequisites[action] ?? []) else { return nil }
            guard try coordinator.canDiscover(capabilityID: action, environmentID: target,
                subjectPublicKey: caller?.publicKey, runtimeID: caller?.runtimeID, leaseID: caller?.leaseID) else { return nil }
            return Capability(id: action, title: title, source: .system, reflectorID: id,
                safety: safety, invocation: .direct, supportLevel: .publicSupported, requiresConfirmation: safety != .read,
                metadata: ["environmentProfile": spec.profileID, "authority": "Host-installed identity, signed lease and current policy",
                    "verification": "Provider acceptance is separate from independent observation"])
        }
    }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        throw EnvironmentError.unsupported // All effects enter the ordinary RCIR host.
    }
    private func argumentKeys(_ action: String) -> Set<String> {
        switch action {
        case "environment:create", "environment:create-child": return ["correlationID"]
        case "environment:execute": return ["challenge"]
        default: return []
        }
    }
    func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem, executionID: String,
        arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?,
        host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        let supplied = arguments ?? [:], keys = argumentKeys(capability.id)
        guard Set(supplied.keys).isSubset(of: keys) else { throw EnvironmentFabricError.invalidRequest }
        if capability.id == "environment:execute" { guard supplied["challenge"] != nil else { throw EnvironmentFabricError.invalidRequest } }
        let target = item.url == EnvironmentIdentity.factoryURI ? nil : try EnvironmentIdentity.environmentID(from: item.url ?? "")
        let requestDigest = try EnvironmentContextualInvocation.digest(executionID: executionID, capabilityID: capability.id,
            item: item.display, arguments: supplied, verification: verification, expectedOutput: expectedOutput,
            dependencies: prerequisites[capability.id] ?? [])
        let identityAdmission = try caller.map { try coordinator.authenticatedAdmission(executionID: executionID, requestDigest: requestDigest,
            subjectPublicKey: $0.publicKey, runtimeID: $0.runtimeID, environmentID: $0.environmentID, leaseID: $0.leaseID) }
            ?? coordinator.rootAdmission(executionID: executionID, requestDigest: requestDigest)
        let schema = CapabilitySchema.object(properties: Dictionary(uniqueKeysWithValues: keys.map { ($0, CapabilitySchema.string) }), required: capability.id == "environment:execute" ? ["challenge"] : [])
        let abi = try admissionOwner.abiContract(arguments: schema, result: .string)
        let scope = RCIRScope(item.display, capability.id == "environment:observe" ? .read : .execute)
        var createdID: String? = target
        let observer: RCIRIndependentObserver?
        if capability.id == "environment:observe" { observer = nil }
        else {
            let expected: CapabilityValue = capability.id == "environment:execute" ? .string(supplied["challenge"]!) : .boolean(true)
            observer = .init(contract: .init(observerID: "host:environment:" + executionID,
                schema: capability.id == "environment:execute" ? .string : .boolean, expected: expected),
                boundary: "Configured parent provider observation, separate from acceptance and child assertion.") {
                if capability.id == "environment:execute" {
                    guard let observed = try self.coordinator.observeChallenge(executionID: executionID) else { throw EnvironmentError.unavailable }
                    return observed
                }
                guard let identifier = createdID else { throw EnvironmentError.unavailable }
                let observed = try self.coordinator.observe(environmentID: identifier)
                guard observed.observation?.presence != .unknown else { throw EnvironmentError.unavailable }
                switch capability.id {
                case "environment:create", "environment:create-child": return .boolean(observed.observation?.presence == .present)
                case "environment:bootstrap": return .boolean(observed.runtime != nil && observed.enrollmentConsumed && observed.state == .ready)
                case "environment:destroy": return .boolean(observed.state == .destroyed && observed.observation?.presence == .absent)
                default: throw EnvironmentError.unsupported
                }
            }
        }
        let providerID = coordinator.provider.id, support = coordinator.provider.support
        let record = try host.execute(abi: abi, discovery: abi, arguments: .object(supplied.mapValues(CapabilityValue.string)),
            scope: scope, capability: capability, executionID: executionID, argumentStrings: arguments, item: item,
            verification: verification, expectedOutput: expectedOutput, target: URL(string: item.display)!, independentObserver: observer,
            afterDispatchRevalidate: {
                // Capability removal caused by this admitted state transition is
                // expected. Provider ownership, support and durable dispatch
                // identity must remain available; admission checks are unchanged.
                self.coordinator.provider.id == providerID && self.coordinator.provider.support == support &&
                    (capability.id == "environment:observe" || (try? self.coordinator.executionRecord(executionID)?.actionId) == capability.id)
            },
            authority: { [scope] }, revalidate: revalidate, currentContract: { true },
            dispatch: { _, start in
                var result: ExecutionRecord?, failure: Error?
                try start {
                    do {
                        // Consume one-use predecessors after ordinary RCIR
                        // confirmation/policy admission, immediately before the
                        // effect. Current discovery must remain available for
                        // that admission's initial graph checks.
                        let admission = try self.coordinator.requiringDependencies(
                            self.prerequisites[capability.id] ?? [], admission: identityAdmission)
                        switch capability.id {
                        case "environment:create", "environment:create-child":
                            let resource = try self.coordinator.create(spec: self.spec, correlationID: supplied["correlationID"] ?? UUID().uuidString, admission: admission, confirmed: true)
                            createdID = resource.environmentID
                            result = try self.coordinator.executionRecord(executionID)
                            result?.output = resource.handle?.uri
                        case "environment:bootstrap":
                            guard let target else { throw EnvironmentFabricError.invalidRequest }
                            let resource = try self.coordinator.bootstrap(environmentID: target, admission: admission, confirmed: true)
                            try self.afterBootstrap?(resource)
                            result = try self.coordinator.executionRecord(executionID)
                            result?.output = resource.handle?.uri
                        case "environment:execute":
                            guard let target else { throw EnvironmentFabricError.invalidRequest }
                            result = try self.coordinator.executeChallenge(environmentID: target, challenge: supplied["challenge"]!, admission: admission, confirmed: true)
                            result?.output = supplied["challenge"]
                        case "environment:destroy":
                            guard let target else { throw EnvironmentFabricError.invalidRequest }
                            let resource = try self.coordinator.destroy(environmentID: target, admission: admission, confirmed: true)
                            result = try self.coordinator.executionRecord(executionID); result?.output = resource.handle?.uri
                        case "environment:observe":
                            guard let target else { throw EnvironmentFabricError.invalidRequest }
                            let resource = try self.coordinator.observe(environmentID: target)
                            result = .init(executionId: executionID, actionId: capability.id, state: .accepted,
                                message: "Current independent resource observation.", output: RightClickJSON.encode(resource))
                        default: throw EnvironmentError.unsupported
                        }
                    } catch { failure = error }
                }
                if let failure { throw failure }
                guard var result else { throw EnvironmentError.unavailable }
                // RCIR host decides semantic outcome using its separate observer.
                if result.state == .succeeded { result.state = .accepted }
                return result
            }, resultValue: { .string($0.output ?? "") })
        if capability.id != "environment:observe", (try coordinator.executionRecord(executionID)) != nil {
            try coordinator.storeExecutionRecord(record)
        }
        if capability.id == "environment:execute", record.state == .succeeded {
            // Sign dependency authority only after the complete RCIR invocation,
            // including any caller predicate, is irrevocably finalized. Missing
            // evidence keeps dependencies unavailable without changing reality.
            do { try afterWorkload?(executionID) } catch { /* No certificate authority is granted on failure. */ }
        }
        return try evidenceView(record)
    }
    func ownsExecution(executionID: String) throws -> Bool {
        try coordinator.canReadExecution(executionID: executionID, subjectPublicKey: caller?.publicKey,
            runtimeID: caller?.runtimeID, environmentID: caller?.environmentID)
    }
    func executionStatus(executionID: String, cursor: Int64, limit: Int, maximumBytes: Int) async throws -> ExecutionRecord? {
        guard try ownsExecution(executionID: executionID) else { return nil }
        guard var record = try coordinator.executionRecord(executionID) else { return nil }
        guard cursor >= 0 else { throw RCIRError.invalidSequence }
        guard (1...256).contains(limit), (1...262_144).contains(maximumBytes) else { throw RCIRError.invalidLimit }
        if let history = record.rcirEvents {
            record.rcirEventPage = try rcirExecutionEventPage(history, after: cursor, limit: limit,
                maximumBytes: maximumBytes, terminal: record.lifecycle?.terminal ?? true)
        } else if cursor != 0 { throw RCIRError.invalidSequence }
        record.rcirEvents = nil
        return try evidenceView(record)
    }
    private func evidenceView(_ record: ExecutionRecord) throws -> ExecutionRecord {
        var view = record
        if let environmentID = try coordinator.executionEnvironmentID(record.executionId),
           let resource = try coordinator.record(environmentID: environmentID) {
            let evidence = try coordinator.evidence(executionID: record.executionId)
            view.environmentEvidence = try .init(environmentID: environmentID, runtimeEnrollment: resource.enrollmentCertificate,
                signedProof: evidence.0, verificationCertificate: evidence.1)
        }
        return view
    }
}
