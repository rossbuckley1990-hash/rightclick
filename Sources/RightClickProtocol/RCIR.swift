import Foundation

/// RCIR-001: portable semantic foundation, not an additional AI tool or transport.
public enum RCIRError: Error, Equatable {
    case invalidContract, invalidIdentity, invalidLimit, invalidTime
    case unavailable, staleBinding, unknownEffects, unsupportedTaskShape
    case authorityDenied, policyDenied, leaseExpired, leaseUsed, leaseMismatch
    case invalidTransition, invalidSequence, bufferFull, unverified, observerMismatch
}

public enum RCIREffect: String, Sendable, Codable, CaseIterable {
    case read, write, delete, execute, publish, subscribe, securityChange, unknown
}

/// Exact resource names only. This model intentionally has no implicit wildcard,
/// prefix, URL-decoding, case folding, or Unicode-normalising scope matching.
public struct RCIRScope: Sendable, Hashable {
    public let resource: String
    public let effect: RCIREffect
    public init(_ resource: String, _ effect: RCIREffect) {
        self.resource = resource; self.effect = effect
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.effect == rhs.effect && lhs.resource.utf8.elementsEqual(rhs.resource.utf8)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(Data(resource.utf8)); hasher.combine(effect.rawValue)
    }
    fileprivate var value: CapabilityValue {
        .object(["resource": .string(resource), "effect": .string(effect.rawValue)])
    }
}

public enum RCIRTaskShape: String, Sendable, Hashable {
    case unary, deferred, serverStream, clientStream, duplex
}

public struct RCIRTaskModel: Sendable {
    public let shape: RCIRTaskShape
    public let element: CapabilitySchema?
    public let cancellable: Bool
    public let maxEvents: Int
    public let maxBytes: Int
    public init(shape: RCIRTaskShape = .unary, element: CapabilitySchema? = nil,
                cancellable: Bool = false, maxEvents: Int = 256, maxBytes: Int = 262_144) {
        self.shape = shape; self.element = element; self.cancellable = cancellable
        self.maxEvents = maxEvents; self.maxBytes = maxBytes
    }
    fileprivate func canonicalValue() throws -> CapabilityValue {
        .object([
            "shape": .string(shape.rawValue),
            "element": try element.map { .bytes(try $0.canonicalData()) } ?? .null,
            "cancellable": .boolean(cancellable),
            "maxEvents": .integer(Int64(maxEvents)), "maxBytes": .integer(Int64(maxBytes))
        ])
    }
}

/// Host-generated invocation identity handed to a trusted substrate compiler at
/// dispatch. Provider acknowledgements never choose this marker or expectation.
public struct RCIRInvocationBinding: Sendable {
    public let id: String
    public init(taskID: String) throws {
        guard let uuid = UUID(uuidString: taskID), uuid.uuidString.utf8.elementsEqual(taskID.utf8) else {
            throw RCIRError.invalidIdentity
        }
        id = taskID
    }
    fileprivate func matches(_ value: CapabilityValue) -> Bool {
        guard case let .string(observed) = value else { return false }
        return observed.utf8.elementsEqual(id.utf8)
    }
}

/// Exact host-declared projections allow unknown effect metadata (such as an
/// assigned offset or resource UID) to remain in signed observation evidence
/// while comparing only pre-bound desired fields. No wildcard or coercion.
public struct RCIRObservationProjection: Sendable {
    public let schema: CapabilitySchema
    public let fields: [String: [String]]
    public init(schema: CapabilitySchema, fields: [String: [String]]) {
        self.schema = schema; self.fields = fields
    }
    func canonicalValue(expected: CapabilityValue) throws -> CapabilityValue {
        guard !fields.isEmpty, fields.count <= 64,
              case let .object(values) = expected, Set(values.keys) == Set(fields.keys) else { throw RCIRError.invalidContract }
        for (name, path) in fields {
            guard !name.isEmpty, name.utf8.count <= 4096, !name.contains("*"),
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  !path.isEmpty, path.count <= 32,
                  path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("*") && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else { throw RCIRError.invalidContract }
        }
        return .object(["schema": .bytes(try schema.canonicalData()),
            "fields": .object(fields.mapValues { .array($0.map { .string($0) }) })])
    }
    func project(_ observation: CapabilityValue) throws -> CapabilityValue {
        try schema.validate(observation)
        var result: [String: CapabilityValue] = [:]
        for (name, path) in fields {
            var current = observation
            for component in path {
                guard case let .object(object) = current, let next = object[component] else { throw RCIRError.unverified }
                current = next
            }
            result[name] = current
        }
        return .object(result)
    }
}

/// The runtime/operator supplies the observer binding and expected postcondition.
/// A provider response or description must never choose its own verifier.
public struct RCIRVerificationContract: Sendable {
    public let observerID: String
    public let schema: CapabilitySchema
    public let expected: CapabilityValue
    public let projection: RCIRObservationProjection?
    public let invocationBindingPath: [String]?
    public init(observerID: String, schema: CapabilitySchema, expected: CapabilityValue,
                projection: RCIRObservationProjection? = nil, invocationBindingPath: [String]? = nil) {
        self.observerID = observerID; self.schema = schema; self.expected = expected
        self.projection = projection
        self.invocationBindingPath = invocationBindingPath
    }
}

public struct RCIRContract: Sendable {
    public let abi: CapabilityContract
    public let scopes: Set<RCIRScope>?
    public let task: RCIRTaskModel
    public let verification: RCIRVerificationContract?
    public init(abi: CapabilityContract, scopes: Set<RCIRScope>?,
                task: RCIRTaskModel = .init(), verification: RCIRVerificationContract? = nil) {
        self.abi = abi; self.scopes = scopes; self.task = task; self.verification = verification
    }
    public func canonicalData() throws -> Data {
        guard (1...1024).contains(task.maxEvents), (1...262_144).contains(task.maxBytes)
        else { throw RCIRError.invalidLimit }
        if task.shape == .serverStream || task.shape == .clientStream || task.shape == .duplex {
            guard task.element != nil else { throw RCIRError.invalidContract }
        } else if task.element != nil { throw RCIRError.invalidContract }
        let effects = try scopes.map { try rcirScopes($0) } ?? .null
        var check: CapabilityValue = .null
        if let verification {
            try rcirIdentity(verification.observerID)
            try verification.schema.validate(verification.expected)
            var fields: [String: CapabilityValue] = [
                "observer": .string(verification.observerID),
                "schema": .bytes(try verification.schema.canonicalData()),
                "expected": verification.expected
            ]
            if let projection = verification.projection {
                fields["projection"] = try projection.canonicalValue(expected: verification.expected)
            }
            if let path = verification.invocationBindingPath {
                guard !path.isEmpty, path.count <= 32,
                      path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("*") && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
                    throw RCIRError.invalidContract
                }
                fields["invocationBinding"] = .array(path.map { .string($0) })
            }
            check = .object(fields)
        }
        return try rcirEnvelope("CONTRACT", .object([
            "abi": .bytes(try abi.canonicalData()), "effects": effects,
            "task": try task.canonicalValue(), "verification": check
        ]), limit: 65_536)
    }
}

public struct RCIRBinding: Sendable {
    public let contract: RCIRContract
    public let principal: String
    public let generation: Int64
    public let bytes: Data
    let graphDeclaration: Data
    fileprivate init(contract: RCIRContract, principal: String, generation: Int64, bytes: Data,
                     graphDeclaration: Data) {
        self.contract = contract; self.principal = principal; self.generation = generation; self.bytes = bytes
        self.graphDeclaration = graphDeclaration
    }
}

public struct RCIRPolicy: Sendable {
    public let revision: String
    public let principals: Set<String>
    public let scopes: Set<RCIRScope>
    public init(revision: String, principals: Set<String>, scopes: Set<RCIRScope>) {
        self.revision = revision; self.principals = principals; self.scopes = scopes
    }
}

public struct RCIRLease: Sendable {
    public let id: UUID
    public let binding: RCIRBinding
    public let scopes: Set<RCIRScope>
    public let issuedAt: Int64
    public let expiresAt: Int64
    public let arguments: CapabilityValue
    public let requestBytes: Data
    /// Host-local canonical grant ancestry; nil for the trusted legacy scope API.
    public let authorityBytes: Data?
    fileprivate init(binding: RCIRBinding, scopes: Set<RCIRScope>, issuedAt: Int64,
                     expiresAt: Int64, arguments: CapabilityValue, requestBytes: Data, authorityBytes: Data? = nil) {
        self.id = UUID(); self.binding = binding; self.scopes = scopes
        self.issuedAt = issuedAt; self.expiresAt = expiresAt
        self.arguments = arguments; self.requestBytes = requestBytes; self.authorityBytes = authorityBytes
    }
}

/// Host-only admission ledger. Leases are opaque in-process handles, not signed
/// bearer credentials. Persisted/distributed leases require a later gate.
/// A single lock serializes graph updates and lease admission. Transport handoff
/// remains a host responsibility; this does not promise remote atomic execution.
public final class RCIRAdmission: @unchecked Sendable {
    private struct Entry { let lease: RCIRLease; let issuedAt: Int64; let policy: Data; let grant: RCIRAuthorityGrant? }
    private let lock = NSLock()
    private var entries: [Data: RCIRBinding] = [:]
    private var leases: [UUID: Entry] = [:]
    private var generation: Int64 = 0
    private var authorityLedger = RCIRAuthorityLedger()
    public init() {}

    public func publish(_ contract: RCIRContract, authenticatedPrincipal: String) throws -> RCIRBinding {
        try publish(contract, authenticatedPrincipal: authenticatedPrincipal,
                    graphDeclaration: contract.canonicalData())
    }

    /// A trusted substrate compiler separates the stable discovered ABI from
    /// its invocation-specific resource, request body and verifier. Those values
    /// remain in the immutable lease binding; they do not replace the provider.
    /// This is host-only lowering, never provider metadata or model authority.
    public func publishInvocation(_ contract: RCIRContract, discovery: CapabilityContract,
                                  authenticatedPrincipal: String) throws -> RCIRBinding {
        let invocation = contract.abi
        guard Data(invocation.capabilityID.utf8) == Data(discovery.capabilityID.utf8),
              Data(invocation.reflectorID.utf8) == Data(discovery.reflectorID.utf8),
              Data(invocation.providerID.utf8) == Data(discovery.providerID.utf8),
              try invocation.arguments?.canonicalData() == discovery.arguments?.canonicalData(),
              try invocation.result?.canonicalData() == discovery.result?.canonicalData() else {
            throw RCIRError.invalidContract
        }
        // Resource instantiation and expected observations vary per request.
        // Effect kinds, task shape/budgets and the compiler's full discovered
        // declaration (including endpoint/schema) define graph freshness.
        let effects: CapabilityValue = contract.scopes.map {
            .array(Set($0.map { $0.effect.rawValue }).sorted().map { .string($0) })
        } ?? .null
        let declaration = try rcirEnvelope("GRAPH-DECLARATION", .object([
            "abi": .bytes(try discovery.canonicalData()),
            "effects": effects, "task": try contract.task.canonicalValue()
        ]), limit: 65_536)
        return try publish(contract, authenticatedPrincipal: authenticatedPrincipal, graphDeclaration: declaration)
    }

    private func publish(_ contract: RCIRContract, authenticatedPrincipal: String,
                         graphDeclaration: Data) throws -> RCIRBinding {
        try rcirIdentity(authenticatedPrincipal)
        let declaration = try contract.canonicalData()
        let key = Data(contract.abi.capabilityID.utf8)
        lock.lock(); defer { lock.unlock() }
        let old = entries[key]
        let sameGeneration = old?.principal.utf8.elementsEqual(authenticatedPrincipal.utf8) == true
            && old?.graphDeclaration == graphDeclaration
        if sameGeneration, let old, try old.contract.canonicalData() == declaration { return old }
        guard entries[key] != nil || entries.count < 4096 else { throw RCIRError.invalidLimit }
        guard sameGeneration || generation < Int64.max else { throw RCIRError.invalidLimit }
        let next = sameGeneration ? old!.generation : generation + 1
        let bytes = try rcirEnvelope("BINDING", .object([
            "contract": .bytes(declaration), "principal": .string(authenticatedPrincipal),
            "generation": .integer(next), "discovery": .bytes(graphDeclaration)
        ]), limit: 140_000)
        let binding = RCIRBinding(contract: contract, principal: authenticatedPrincipal,
                                  generation: next, bytes: bytes, graphDeclaration: graphDeclaration)
        if !sameGeneration { generation = next }
        entries[key] = binding
        // Invalidate outstanding approvals to a different incarnation immediately.
        if !sameGeneration {
            leases = leases.filter { !Data($0.value.lease.binding.contract.abi.capabilityID.utf8).elementsEqual(key) }
        }
        return binding
    }

    public func withdraw(providerID: String) {
        lock.lock(); defer { lock.unlock() }
        let provider = Data(providerID.utf8)
        entries = entries.filter { Data($0.value.contract.abi.providerID.utf8) != provider }
        leases = leases.filter { Data($0.value.lease.binding.contract.abi.providerID.utf8) != provider }
    }

    /// Withdraw one engine-assigned acquisition owner without invalidating a
    /// separately configured route to the same underlying provider.
    public func withdraw(reflectorID: String) {
        lock.lock(); defer { lock.unlock() }
        let owner = Data(reflectorID.utf8)
        entries = entries.filter { Data($0.value.contract.abi.reflectorID.utf8) != owner }
        leases = leases.filter { Data($0.value.lease.binding.contract.abi.reflectorID.utf8) != owner }
    }

    public func discover() -> [RCIRBinding] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.contract.abi.capabilityID.utf8.lexicographicallyPrecedes($1.contract.abi.capabilityID.utf8) }
    }

    private func current(_ binding: RCIRBinding) throws {
        guard let active = entries[Data(binding.contract.abi.capabilityID.utf8)] else { throw RCIRError.unavailable }
        guard active.generation == binding.generation,
              active.principal.utf8.elementsEqual(binding.principal.utf8),
              active.graphDeclaration == binding.graphDeclaration else { throw RCIRError.staleBinding }
    }

    private func allowed(_ binding: RCIRBinding, arguments: CapabilityValue,
                         authority: Set<RCIRScope>, policy: RCIRPolicy) throws -> Set<RCIRScope> {
        guard let required = binding.contract.scopes, !required.contains(where: { $0.effect == .unknown })
        else { throw RCIRError.unknownEffects }
        guard binding.contract.task.shape != .clientStream, binding.contract.task.shape != .duplex
        else { throw RCIRError.unsupportedTaskShape }
        try binding.contract.abi.validateArguments(arguments)
        guard required.isSubset(of: authority) else { throw RCIRError.authorityDenied }
        guard policy.principals.contains(where: { $0.utf8.elementsEqual(binding.principal.utf8) }),
              required.isSubset(of: policy.scopes) else { throw RCIRError.policyDenied }
        return required
    }

    /// Trusted host credential-source registration. The reference stores no secret
    /// and grants no authority by itself; issuer enforcement remains external.
    public func registerCredentialReference(issuer: RCIRAuthorityIdentity,
                                            audience: RCIRAuthorityIdentity) throws -> RCIRCredentialReference {
        lock.lock(); defer { lock.unlock() }
        return try authorityLedger.reference(issuer: issuer, audience: audience)
    }

    public func revokeCredentialReference(_ reference: RCIRCredentialReference) throws {
        lock.lock(); defer { lock.unlock() }
        try authorityLedger.revokeReference(reference)
    }

    /// Root grants may only be requested by a trusted host authorization broker.
    /// No model-visible operation calls this method. Provider credentials never
    /// enter this ledger, and a local grant is not issuer-enforced downscoping.
    public func issueAuthority(_ request: RCIRAuthorityRequest, issuer: RCIRAuthorityIdentity,
                               credentialReferences: Set<RCIRCredentialReference> = [], now: Int64) throws -> RCIRAuthorityGrant {
        lock.lock(); defer { lock.unlock() }
        try currentTargets(request.targets)
        return try authorityLedger.issue(request, issuer: issuer, references: credentialReferences,
                                         parent: nil, context: nil, now: now)
    }

    public func attenuate(_ parent: RCIRAuthorityGrant, request: RCIRAuthorityRequest,
                          authenticated context: RCIRAuthorityContext,
                          credentialReferences: Set<RCIRCredentialReference> = [], now: Int64) throws -> RCIRAuthorityGrant {
        lock.lock(); defer { lock.unlock() }
        try currentTargets(request.targets)
        return try authorityLedger.issue(request, issuer: parent.issuer, references: credentialReferences,
                                         parent: parent, context: context, now: now)
    }

    /// Revocation is trusted-host control, not possession of a model token.
    /// Descendants are rejected by ancestry checks without a separate traversal.
    public func revokeAuthority(_ grant: RCIRAuthorityGrant) throws {
        lock.lock(); defer { lock.unlock() }
        try authorityLedger.revoke(grant)
    }

    /// Revalidate ongoing work or independent observation after an admitted start.
    /// Already consumed invocation budget is not a new invocation; identity,
    /// ancestry revocation, expiry, target and arguments are still required.
    public func validateAuthority(_ grant: RCIRAuthorityGrant, authenticated context: RCIRAuthorityContext,
                                  binding: RCIRBinding, arguments: CapabilityValue, now: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try current(binding)
        try authorityLedger.check(grant, context: context, binding: binding,
                                  arguments: arguments, now: now, consume: false, enforceBudget: false)
    }

    private func currentTargets(_ targets: Set<RCIRAuthorityTarget>) throws {
        for target in targets {
            guard let binding = entries[Data(target.capability.value.utf8)],
                  try RCIRAuthorityTarget(binding) == target else { throw RCIRError.staleBinding }
        }
    }

    /// Compatibility entry point for trusted host scope callbacks. This API has
    /// no invoking-agent authentication and must not represent delegated agency.
    public func issue(_ binding: RCIRBinding, arguments: CapabilityValue,
                      authority: Set<RCIRScope>, policy: RCIRPolicy, now: Int64,
                      ttl: Int64 = 30_000) throws -> RCIRLease {
        let policyData = try rcirPolicy(policy)
        lock.lock(); defer { lock.unlock() }
        return try issueLocked(binding, arguments: arguments, authority: authority, policy: policy,
                               policyData: policyData, grant: nil, now: now, ttl: ttl)
    }

    public func issue(_ binding: RCIRBinding, arguments: CapabilityValue,
                      grant: RCIRAuthorityGrant, authenticated context: RCIRAuthorityContext,
                      policy: RCIRPolicy, now: Int64, ttl: Int64 = 30_000) throws -> RCIRLease {
        let policyData = try rcirPolicy(policy)
        lock.lock(); defer { lock.unlock() }
        try current(binding)
        try authorityLedger.check(grant, context: context, binding: binding, arguments: arguments, now: now, consume: false)
        guard now >= 0, (1...60_000).contains(ttl), now <= Int64.max - ttl else { throw RCIRError.invalidTime }
        return try issueLocked(binding, arguments: arguments, authority: grant.request.scopes, policy: policy,
                               policyData: policyData, grant: grant, now: now,
                               ttl: min(ttl, grant.request.expiresAt - now))
    }

    private func requestBytes(binding: RCIRBinding, arguments: CapabilityValue,
                              scopes: Set<RCIRScope>, policy: Data, issuedAt: Int64,
                              expiresAt: Int64, grant: RCIRAuthorityGrant?) throws -> Data {
        var value: [String: CapabilityValue] = [
            "binding": .bytes(binding.bytes), "arguments": .bytes(try arguments.canonicalData()),
            "scopes": try rcirScopes(scopes), "policy": .bytes(policy),
            "issuedAt": .integer(issuedAt), "expiresAt": .integer(expiresAt)
        ]
        if let grant { value["authority"] = .bytes(grant.bytes) }
        return try rcirEnvelope("REQUEST", .object(value), limit: 131_072)
    }

    private func issueLocked(_ binding: RCIRBinding, arguments: CapabilityValue,
                             authority: Set<RCIRScope>, policy: RCIRPolicy, policyData: Data,
                             grant: RCIRAuthorityGrant?, now: Int64, ttl: Int64) throws -> RCIRLease {
        guard now >= 0, (1...60_000).contains(ttl), now <= Int64.max - ttl else { throw RCIRError.invalidTime }
        try current(binding)
        let required = try allowed(binding, arguments: arguments, authority: authority, policy: policy)
        let bytes = try requestBytes(binding: binding, arguments: arguments, scopes: required, policy: policyData,
                                     issuedAt: now, expiresAt: now + ttl, grant: grant)
        leases = leases.filter { $0.value.lease.expiresAt > now }
        let retainedBytes = leases.values.reduce(0) { $0 + $1.lease.requestBytes.count }
        guard leases.count < 4096, bytes.count <= 16_777_216 - retainedBytes else { throw RCIRError.invalidLimit }
        let lease = RCIRLease(binding: binding, scopes: required, issuedAt: now,
                              expiresAt: now + ttl, arguments: arguments, requestBytes: bytes, authorityBytes: grant?.bytes)
        leases[lease.id] = Entry(lease: lease, issuedAt: now, policy: policyData, grant: grant)
        return lease
    }

    /// Consume immediately before dispatch; never retry an effectful request after
    /// uncertain transport failure. Revocation and policy are checked again here.
    public func consume(_ lease: RCIRLease, arguments: CapabilityValue,
                        authority: Set<RCIRScope>, policy: RCIRPolicy, now: Int64) throws {
        let policyData = try rcirPolicy(policy)
        lock.lock(); defer { lock.unlock() }
        try consumeLocked(lease, arguments: arguments, authority: authority,
                          policy: policy, policyData: policyData, grant: nil, context: nil, now: now)
    }

    public func consume(_ lease: RCIRLease, arguments: CapabilityValue,
                        grant: RCIRAuthorityGrant, authenticated context: RCIRAuthorityContext,
                        policy: RCIRPolicy, now: Int64) throws {
        try consumeAndStart(lease, arguments: arguments, grant: grant, authenticated: context,
                            policy: policy, now: now) {}
    }

    /// Serialize lease consumption, ancestor budget debit and synchronous enqueue
    /// with graph withdrawal and authority revocation. Start must never wait.
    public func consumeAndStart(_ lease: RCIRLease, arguments: CapabilityValue,
                               authority: Set<RCIRScope>, policy: RCIRPolicy, now: Int64,
                               start: () -> Void) throws {
        let policyData = try rcirPolicy(policy)
        lock.lock(); defer { lock.unlock() }
        try consumeLocked(lease, arguments: arguments, authority: authority,
                          policy: policy, policyData: policyData, grant: nil, context: nil, now: now)
        start()
    }

    public func consumeAndStart(_ lease: RCIRLease, arguments: CapabilityValue,
                               grant: RCIRAuthorityGrant, authenticated context: RCIRAuthorityContext,
                               policy: RCIRPolicy, now: Int64, start: () -> Void) throws {
        let policyData = try rcirPolicy(policy)
        lock.lock(); defer { lock.unlock() }
        try consumeLocked(lease, arguments: arguments, authority: grant.request.scopes,
                          policy: policy, policyData: policyData, grant: grant, context: context, now: now)
        start()
    }

    /// Host-only clock sampling at atomic admission, after external refreshes.
    /// The clock must be a local time source and must not reenter this ledger.
    package func consumeAndStart(_ lease: RCIRLease, arguments: CapabilityValue,
                                 authority: Set<RCIRScope>, policy: RCIRPolicy,
                                 clock: () throws -> Int64, start: () -> Void) throws {
        let policyData = try rcirPolicy(policy)
        lock.lock(); defer { lock.unlock() }
        try consumeLocked(lease, arguments: arguments, authority: authority,
            policy: policy, policyData: policyData, grant: nil, context: nil, now: clock())
        start()
    }

    package func consumeAndStart(_ lease: RCIRLease, arguments: CapabilityValue,
                                 grant: RCIRAuthorityGrant, authenticated context: RCIRAuthorityContext,
                                 policy: RCIRPolicy, clock: () throws -> Int64, start: () -> Void) throws {
        let policyData = try rcirPolicy(policy)
        lock.lock(); defer { lock.unlock() }
        try consumeLocked(lease, arguments: arguments, authority: grant.request.scopes,
            policy: policy, policyData: policyData, grant: grant, context: context, now: clock())
        start()
    }

    private func consumeLocked(_ lease: RCIRLease, arguments: CapabilityValue,
                               authority: Set<RCIRScope>, policy: RCIRPolicy,
                               policyData: Data, grant: RCIRAuthorityGrant?, context: RCIRAuthorityContext?, now: Int64) throws {
        guard let entry = leases[lease.id] else { throw RCIRError.leaseUsed }
        guard now >= entry.issuedAt else { throw RCIRError.invalidTime }
        guard now < entry.lease.expiresAt else { leases.removeValue(forKey: lease.id); throw RCIRError.leaseExpired }
        try current(entry.lease.binding)
        if let issuedGrant = entry.grant {
            guard let grant, let context, grant.bytes == issuedGrant.bytes else { throw RCIRError.authorityDenied }
            try authorityLedger.check(grant, context: context, binding: entry.lease.binding,
                                      arguments: arguments, now: now, consume: false)
        } else if grant != nil || context != nil { throw RCIRError.authorityDenied }
        let required = try allowed(entry.lease.binding, arguments: arguments, authority: authority, policy: policy)
        guard policyData == entry.policy else { throw RCIRError.policyDenied }
        let bytes = try requestBytes(binding: entry.lease.binding, arguments: arguments, scopes: required,
                                     policy: policyData, issuedAt: entry.issuedAt,
                                     expiresAt: entry.lease.expiresAt, grant: entry.grant)
        guard bytes == entry.lease.requestBytes, lease.requestBytes == bytes,
              lease.binding.bytes == entry.lease.binding.bytes else { throw RCIRError.leaseMismatch }
        if let grant, let context {
            try authorityLedger.check(grant, context: context, binding: entry.lease.binding,
                                      arguments: arguments, now: now, consume: true)
        }
        leases.removeValue(forKey: lease.id)
    }

}

public enum RCIRTaskPhase: String, Sendable { case started, accepted, working, inputRequired, cancelRequested, completed, failed, cancelled, unknown }
public enum RCIRSemanticOutcome: String, Sendable { case unverified, succeeded, failed, unknown }
public enum RCIRTaskEvent: Sendable {
    case accepted, working, inputRequired, chunk(CapabilityValue), completed(CapabilityValue), completedWithoutOutput, failed, cancelled
}

/// An independent observer is selected by trusted runtime configuration, not by
/// the provider or AI. Its observation is bound to these exact invocation inputs.
public struct RCIRObservationRequest: Sendable {
    public let taskID: UUID
    public let leaseID: UUID
    public let binding: RCIRBinding
    public let arguments: CapabilityValue
    /// Untrusted provider bytes may locate an observation, but never determine
    /// the expected postcondition or expand the observer's authority.
    public let providerResult: CapabilityValue?
    public init(taskID: UUID, leaseID: UUID, binding: RCIRBinding, arguments: CapabilityValue,
                providerResult: CapabilityValue? = nil) {
        self.taskID = taskID; self.leaseID = leaseID; self.binding = binding
        self.arguments = arguments; self.providerResult = providerResult
    }
}

public protocol RCIRObserver {
    var observerID: String { get }
    func observe(_ request: RCIRObservationRequest) throws -> CapabilityValue
}

/// Bounded pages for a host to expose through context_run_status. These are exact
/// canonical event bytes, not a new model-facing operation or transport stream.
public struct RCIREventPage: Sendable {
    public let events: [Data]
    public let nextCursor: Int64
    public let hasMore: Bool
    public let terminal: Bool
}

/// Host-owned task state. Serial value semantics; a host sharing a task across
/// threads must put it in an actor/lock. Constructing a task does not execute an
/// action and is not evidence that its lease was consumed. The host must enforce
/// admission at its actual dispatch boundary before it creates/updates this log.
public struct RCIRTask: Sendable {
    public let id: UUID
    public let lease: RCIRLease
    public let startedAt: Int64
    public let deadline: Int64
    public private(set) var phase: RCIRTaskPhase = .started
    public private(set) var outcome: RCIRSemanticOutcome = .unverified
    public private(set) var sequence: Int64 = 0
    public private(set) var eventCount: Int = 0
    private var events: [Data] = []
    private var usedBytes = 0
    private var lastTime: Int64
    private var finishedAt: Int64?
    private var cancellationRequestedAt: Int64?
    private var observation: Data?
    private var observedAt: Int64?
    private var providerResult: CapabilityValue?

    public var observationRequest: RCIRObservationRequest {
        .init(taskID: id, leaseID: lease.id, binding: lease.binding, arguments: lease.arguments,
              providerResult: providerResult)
    }

    public init(lease: RCIRLease, startedAt: Int64, deadline: Int64) throws {
        guard startedAt >= lease.issuedAt, startedAt < lease.expiresAt,
              deadline > startedAt, deadline - startedAt <= 86_400_000 else { throw RCIRError.invalidTime }
        _ = try lease.binding.contract.canonicalData()
        self.id = UUID(); self.lease = lease; self.startedAt = startedAt; self.deadline = deadline
        self.lastTime = startedAt
    }

    private var terminal: Bool { [.completed, .failed, .cancelled, .unknown].contains(phase) }
    private func time(_ now: Int64) throws {
        guard now >= lastTime else { throw RCIRError.invalidTime }
    }

    public mutating func record(_ event: RCIRTaskEvent, sequence: Int64, now: Int64) throws {
        guard !terminal else { throw RCIRError.invalidTransition }
        try time(now)
        if now >= deadline {
            phase = .unknown; outcome = .unknown; lastTime = now; finishedAt = now
            throw RCIRError.invalidTime
        }
        guard self.sequence < Int64.max, sequence == self.sequence + 1 else { throw RCIRError.invalidSequence }
        var next = phase
        var value: CapabilityValue = .null
        let kind: String
        let model = lease.binding.contract.task
        switch event {
        case .accepted:
            guard phase == .started else { throw RCIRError.invalidTransition }
            next = .accepted; kind = "accepted"
        case .working:
            guard [.started, .accepted, .inputRequired].contains(phase) else { throw RCIRError.invalidTransition }
            next = .working; kind = "working"
        case .inputRequired:
            guard model.shape != .unary, [.accepted, .working].contains(phase) else { throw RCIRError.invalidTransition }
            next = .inputRequired; kind = "inputRequired"
        case let .chunk(element):
            guard model.shape == .serverStream, phase == .working, let schema = model.element
            else { throw RCIRError.invalidTransition }
            try schema.validate(element)
            value = element; kind = "chunk"
        case let .completed(result):
            guard phase != .inputRequired else { throw RCIRError.invalidTransition }
            guard let schema = lease.binding.contract.abi.result else { throw CapabilityABIError.unknownSchema }
            try schema.validate(result)
            next = .completed; value = result; kind = "completed"
        case .completedWithoutOutput:
            guard phase != .inputRequired, case .unit? = lease.binding.contract.abi.result else {
                throw RCIRError.invalidContract
            }
            next = .completed; kind = "completedWithoutOutput"
        case .failed: next = .failed; kind = "failed"
        case .cancelled: next = .cancelled; kind = "cancelled"
        }
        let data = try CapabilityValue.object([
            "sequence": .integer(sequence), "time": .integer(now),
            "kind": .string(kind), "value": value
        ]).canonicalData()
        guard eventCount < model.maxEvents, data.count <= model.maxBytes - usedBytes else { throw RCIRError.bufferFull }
        // Commit only after every shape, transition, sequence and budget check.
        events.append(data); usedBytes += data.count; eventCount += 1
        if case let .completed(result) = event { providerResult = result }
        self.sequence = sequence; phase = next; lastTime = now
        if terminal { finishedAt = now }
        // No provider event can promote semantic outcome to succeeded.
    }

    public mutating func requestCancellation(now: Int64) throws {
        guard lease.binding.contract.task.cancellable, !terminal, phase != .cancelRequested
        else { throw RCIRError.invalidTransition }
        try time(now)
        guard now < deadline else { throw RCIRError.invalidTime }
        phase = .cancelRequested; lastTime = now; cancellationRequestedAt = now
    }

    public mutating func checkDeadline(now: Int64) throws {
        try time(now)
        if !terminal, now >= deadline {
            phase = .unknown; outcome = .unknown; finishedAt = now
        }
        lastTime = now
    }

    public mutating func providerDisappeared(now: Int64) throws {
        try time(now)
        if !terminal {
            phase = .unknown; outcome = .unknown; finishedAt = now
        }
        lastTime = now
    }

    /// Only the host invokes this with an independently configured observer.
    /// The observer receives the task/binding, NOT the provider's claimed result.
    /// This closure is an explicit trusted boundary, not remote attestation.
    public mutating func verify(observerID: String, now: Int64,
                               observe: (UUID, RCIRBinding) throws -> CapabilityValue) throws {
        guard phase == .completed, outcome == .unverified else { throw RCIRError.invalidTransition }
        try time(now)
        guard now < deadline else { throw RCIRError.invalidTime }
        guard let contract = lease.binding.contract.verification else { throw RCIRError.unverified }
        guard observerID.utf8.elementsEqual(contract.observerID.utf8) else { throw RCIRError.observerMismatch }
        let value = try observe(id, lease.binding)
        let matchingValue = try contract.projection?.project(value) ?? value
        try contract.schema.validate(matchingValue)
        let data = try value.canonicalData()
        guard data.count <= 131_072 else { throw RCIRError.invalidLimit }
        var markerMatches = true
        if let path = contract.invocationBindingPath {
            var marker = value
            for component in path {
                guard case let .object(fields) = marker, let next = fields[component] else { throw RCIRError.unverified }
                marker = next
            }
            markerMatches = try RCIRInvocationBinding(taskID: id.uuidString).matches(marker)
        }
        let matched = try markerMatches && matchingValue.canonicalData() == contract.expected.canonicalData()
        observation = data; observedAt = now; lastTime = now
        outcome = matched ? .succeeded : .failed
    }

    public mutating func verify(using observer: any RCIRObserver, now: Int64) throws {
        let request = observationRequest
        try verify(observerID: observer.observerID, now: now) { _, _ in
            try observer.observe(request)
        }
    }

    public func eventPage(after cursor: Int64 = 0, limit: Int = 64) throws -> RCIREventPage {
        guard cursor >= 0, cursor <= sequence else { throw RCIRError.invalidSequence }
        guard (1...256).contains(limit) else { throw RCIRError.invalidLimit }
        // sequence is bounded by maxEvents, so this conversion cannot overflow.
        let start = Int(cursor)
        let end = min(events.count, start + limit)
        return RCIREventPage(events: Array(events[start..<end]), nextCursor: Int64(end),
                             hasMore: end < events.count, terminal: terminal)
    }

    /// Canonical bytes to sign; a checksum is NOT a signature. This is a runtime
    /// observation receipt, not proof that a provider or observer was truthful.
    public func receiptData() throws -> Data {
        guard terminal, let finishedAt else { throw RCIRError.invalidTransition }
        return try rcirEnvelope("RECEIPT", .object([
            "taskID": .string(id.uuidString), "leaseID": .string(lease.id.uuidString),
            "request": .bytes(lease.requestBytes),
            "startedAt": .integer(startedAt), "deadline": .integer(deadline),
            "finishedAt": .integer(finishedAt), "lastObservationTime": .integer(lastTime),
            "phase": .string(phase.rawValue), "semanticOutcome": .string(outcome.rawValue),
            "events": .array(events.map { .bytes($0) }), "lastSequence": .integer(sequence),
            "cancellationRequestedAt": cancellationRequestedAt.map { .integer($0) } ?? .null,
            "observation": observation.map { .bytes($0) } ?? .null,
            "observedAt": observedAt.map { .integer($0) } ?? .null
        ]), limit: 1_048_576)
    }
}

private func rcirIdentity(_ text: String) throws {
    guard !text.isEmpty, text.utf8.count <= 4096,
          text.rangeOfCharacter(from: .controlCharacters) == nil, !text.contains("*")
    else { throw RCIRError.invalidIdentity }
}

private func rcirScopes(_ scopes: Set<RCIRScope>) throws -> CapabilityValue {
    guard scopes.count <= 512 else { throw RCIRError.invalidLimit }
    var entries: [(Data, CapabilityValue)] = []
    for scope in scopes {
        try rcirIdentity(scope.resource)
        entries.append((try scope.value.canonicalData(), scope.value))
    }
    return .array(entries.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map { $0.1 })
}

private func rcirPolicy(_ policy: RCIRPolicy) throws -> Data {
    try rcirIdentity(policy.revision)
    guard policy.principals.count <= 512 else { throw RCIRError.invalidLimit }
    for principal in policy.principals { try rcirIdentity(principal) }
    return try rcirEnvelope("POLICY", .object([
        "revision": .string(policy.revision),
        "principals": .array(policy.principals.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { .string($0) }),
        "scopes": try rcirScopes(policy.scopes)
    ]), limit: 32_768)
}

private func rcirEnvelope(_ domain: String, _ value: CapabilityValue, limit: Int) throws -> Data {
    var bytes = Data(("RIGHTCLICK-RCIR-" + domain + "-1\0").utf8)
    bytes.append(try value.canonicalData())
    guard bytes.count <= limit else { throw RCIRError.invalidLimit }
    return bytes
}
