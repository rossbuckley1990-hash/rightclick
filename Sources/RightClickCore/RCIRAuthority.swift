import Foundation

/// Exact, host-authenticated identity. Construction does not authenticate anyone:
/// only the trusted host may derive the invocation context from its session.
public struct RCIRAuthorityIdentity: Sendable, Hashable {
    public let value: String
    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.contains("*"), value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RCIRError.invalidIdentity
        }
        self.value = value
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.value.utf8.elementsEqual(rhs.value.utf8) }
    public func hash(into hasher: inout Hasher) { hasher.combine(Data(value.utf8)) }
}

public struct RCIRAuthorityContext: Sendable {
    public let subject: RCIRAuthorityIdentity
    public let audience: RCIRAuthorityIdentity
    public init(authenticatedSubject: RCIRAuthorityIdentity, audience: RCIRAuthorityIdentity) {
        subject = authenticatedSubject; self.audience = audience
    }
}

/// Binds one discovered provider incarnation, never a wildcard provider name.
/// Discovery bytes are exact canonical fingerprint material, not a hash claim.
public struct RCIRAuthorityTarget: Sendable, Hashable {
    public let provider: RCIRAuthorityIdentity
    public let capability: RCIRAuthorityIdentity
    public let providerPrincipal: RCIRAuthorityIdentity
    public let generation: Int64
    let discoveryBytes: Data
    public init(_ binding: RCIRBinding) throws {
        provider = try .init(binding.contract.abi.providerID)
        capability = try .init(binding.contract.abi.capabilityID)
        providerPrincipal = try .init(binding.principal)
        generation = binding.generation; discoveryBytes = binding.graphDeclaration
    }
    var value: CapabilityValue {
        .object(["provider": .string(provider.value), "capability": .string(capability.value),
                 "providerPrincipal": .string(providerPrincipal.value), "generation": .integer(generation),
                 "discovery": .bytes(discoveryBytes)])
    }
}

/// Deliberately small constraint language: any ABI-valid arguments, or an exact
/// finite set of typed canonical values. No implicit ranges, prefixes or coercion.
public enum RCIRArgumentConstraint: Sendable {
    case unrestricted
    case exact(Set<Data>)
    public static func oneOf(_ arguments: [CapabilityValue]) throws -> Self {
        .exact(try Set(arguments.map { try $0.canonicalData() }))
    }
    func permits(_ arguments: CapabilityValue) throws -> Bool {
        switch self {
        case .unrestricted: return true
        case let .exact(values): return values.contains(try arguments.canonicalData())
        }
    }
    func isSubset(of parent: Self) -> Bool {
        switch (self, parent) {
        case (_, .unrestricted): return true
        case (.unrestricted, .exact): return false
        case let (.exact(child), .exact(parent)): return child.isSubset(of: parent)
        }
    }
    func canonicalValue() throws -> CapabilityValue {
        switch self {
        case .unrestricted: return .null
        case let .exact(values):
            guard !values.isEmpty, values.count <= 256,
                  values.allSatisfy({ $0.starts(with: Data("RIGHTCLICK-VALUE-1\0".utf8)) && $0.count <= 1_048_576 }) else {
                throw RCIRError.invalidLimit
            }
            return .array(values.sorted { $0.lexicographicallyPrecedes($1) }.map { .bytes($0) })
        }
    }
}

/// No bearer material, file path, token resolver or credential serialization.
/// The host's separate credential broker may associate this random handle with
/// an issuer source. A reference alone proves no issuer-enforced downscoping.
public struct RCIRCredentialReference: Sendable, Hashable {
    public let id: UUID
    public let issuer: RCIRAuthorityIdentity
    public let audience: RCIRAuthorityIdentity
    fileprivate init(issuer: RCIRAuthorityIdentity, audience: RCIRAuthorityIdentity) {
        id = UUID(); self.issuer = issuer; self.audience = audience
    }
    var value: CapabilityValue {
        .object(["id": .string(id.uuidString), "issuer": .string(issuer.value), "audience": .string(audience.value)])
    }
}

public struct RCIRAuthorityRequest: Sendable {
    public let subject: RCIRAuthorityIdentity
    public let audiences: Set<RCIRAuthorityIdentity>
    public let targets: Set<RCIRAuthorityTarget>
    public let scopes: Set<RCIRScope>
    public let arguments: RCIRArgumentConstraint
    /// Task shapes admitted for starting execution; task-control permission is
    /// not represented here and must not be inferred from these shapes.
    public let taskShapes: Set<RCIRTaskShape>
    public let expiresAt: Int64
    public let invocationLimit: Int
    public let delegationDepth: Int
    public init(subject: RCIRAuthorityIdentity, audiences: Set<RCIRAuthorityIdentity>,
                targets: Set<RCIRAuthorityTarget>, scopes: Set<RCIRScope>,
                arguments: RCIRArgumentConstraint = .unrestricted,
                taskShapes: Set<RCIRTaskShape> = [.unary], expiresAt: Int64,
                invocationLimit: Int = 1, delegationDepth: Int = 0) {
        self.subject = subject; self.audiences = audiences; self.targets = targets; self.scopes = scopes
        self.arguments = arguments; self.taskShapes = taskShapes; self.expiresAt = expiresAt
        self.invocationLimit = invocationLimit; self.delegationDepth = delegationDepth
    }
    func validate(now: Int64) throws {
        guard now >= 0, expiresAt > now, expiresAt - now <= 60_000 else { throw RCIRError.invalidTime }
        guard !audiences.isEmpty, audiences.count <= 64, !targets.isEmpty, targets.count <= 64,
              scopes.count <= 512, !taskShapes.isEmpty, (1...4096).contains(invocationLimit),
              (0...16).contains(delegationDepth) else { throw RCIRError.invalidLimit }
        guard !scopes.contains(where: { $0.effect == .unknown }) else { throw RCIRError.unknownEffects }
        for scope in scopes { _ = try RCIRAuthorityIdentity(scope.resource) }
        _ = try arguments.canonicalValue()
    }
    func isSubset(of parent: Self) -> Bool {
        audiences.isSubset(of: parent.audiences) && targets.isSubset(of: parent.targets)
        && scopes.isSubset(of: parent.scopes) && arguments.isSubset(of: parent.arguments)
        && taskShapes.isSubset(of: parent.taskShapes) && expiresAt <= parent.expiresAt
        && invocationLimit <= parent.invocationLimit && delegationDepth < parent.delegationDepth
    }
    func value() throws -> CapabilityValue {
        func ordered(_ values: [CapabilityValue]) throws -> CapabilityValue {
            let pairs = try values.map { (try $0.canonicalData(), $0) }
            return .array(pairs.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map { $0.1 })
        }
        return .object(["subject": .string(subject.value),
            "audiences": try ordered(audiences.map { .string($0.value) }),
            "targets": try ordered(targets.map { $0.value }),
            "scopes": try ordered(scopes.map { .object(["resource": .string($0.resource), "effect": .string($0.effect.rawValue)]) }),
            "arguments": try arguments.canonicalValue(),
            "taskShapes": .array(taskShapes.map { $0.rawValue }.sorted().map { .string($0) }),
            "expiresAt": .integer(expiresAt), "invocationLimit": .integer(Int64(invocationLimit)),
            "delegationDepth": .integer(Int64(delegationDepth))])
    }
}

/// Immutable, unforgeable through public constructors, host-local grant handle.
/// Canonical bytes are evidence, never a remotely redeemable bearer credential.
public struct RCIRAuthorityGrant: Sendable {
    public let id: UUID
    public let request: RCIRAuthorityRequest
    public let issuer: RCIRAuthorityIdentity
    public let credentialReferences: Set<RCIRCredentialReference>
    public let issuedAt: Int64
    public let parentID: UUID?
    public let bytes: Data
    fileprivate init(request: RCIRAuthorityRequest, issuer: RCIRAuthorityIdentity,
                     references: Set<RCIRCredentialReference>, now: Int64, parent: Self?) throws {
        id = UUID(); self.request = request; self.issuer = issuer; credentialReferences = references
        issuedAt = now; parentID = parent?.id
        let refs = try references.map { (try $0.value.canonicalData(), $0.value) }
        let value = CapabilityValue.object(["id": .string(id.uuidString), "issuer": .string(issuer.value),
            "request": try request.value(), "issuedAt": .integer(now),
            "parent": parent.map { .bytes($0.bytes) } ?? .null,
            "credentialReferences": .array(refs.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map { $0.1 })])
        var encoded = Data("RIGHTCLICK-RCIR-AUTHORITY-1\0".utf8)
        encoded.append(try value.canonicalData()); bytes = encoded
    }
}

/// Owned by RCIRAdmission and always accessed under its existing graph/lease
/// lock. This is neither another execution engine nor an independent broker.
struct RCIRAuthorityLedger {
    struct Entry { let grant: RCIRAuthorityGrant; var used = 0; var revoked = false }
    private var grants: [UUID: Entry] = [:]
    private var references: Set<RCIRCredentialReference> = []
    private var lastTime: Int64 = 0
    private let maximumGrantBytes = 8_388_608
    private let maximumReferenceBytes = 1_048_576
    mutating func reference(issuer: RCIRAuthorityIdentity, audience: RCIRAuthorityIdentity) throws -> RCIRCredentialReference {
        guard references.count < 4096 else { throw RCIRError.invalidLimit }
        let reference = RCIRCredentialReference(issuer: issuer, audience: audience)
        let size = try reference.value.canonicalData().count
        let retained = try references.reduce(0) { try $0 + $1.value.canonicalData().count }
        guard size <= maximumReferenceBytes - retained else { throw RCIRError.invalidLimit }
        references.insert(reference); return reference
    }
    mutating func revokeReference(_ reference: RCIRCredentialReference) throws {
        guard references.remove(reference) != nil else { throw RCIRError.authorityDenied }
    }
    private mutating func time(_ now: Int64) throws {
        guard now >= lastTime else { throw RCIRError.invalidTime }; lastTime = now
    }
    private func chain(_ grant: RCIRAuthorityGrant, now: Int64) throws -> [UUID] {
        var ids: [UUID] = [], current: RCIRAuthorityGrant? = grant
        while let value = current {
            guard ids.count <= 16, let entry = grants[value.id], entry.grant.bytes == value.bytes,
                  !entry.revoked, entry.grant.credentialReferences.isSubset(of: references) else { throw RCIRError.authorityDenied }
            guard now >= entry.grant.issuedAt, now < entry.grant.request.expiresAt else { throw RCIRError.leaseExpired }
            ids.append(value.id)
            if let parent = entry.grant.parentID {
                guard let ancestor = grants[parent] else { throw RCIRError.authorityDenied }
                current = ancestor.grant
            } else { current = nil }
        }
        return ids
    }
    mutating func issue(_ request: RCIRAuthorityRequest, issuer: RCIRAuthorityIdentity,
                        references supplied: Set<RCIRCredentialReference>, parent: RCIRAuthorityGrant?,
                        context: RCIRAuthorityContext?, now: Int64) throws -> RCIRAuthorityGrant {
        try time(now); try request.validate(now: now)
        grants = grants.filter { $0.value.grant.request.expiresAt > now }
        guard grants.count < 4096, supplied.count <= 64, supplied.isSubset(of: references),
              supplied.allSatisfy({ request.audiences.contains($0.audience) }) else { throw RCIRError.authorityDenied }
        if let parent {
            _ = try chain(parent, now: now)
            guard let context, context.subject == parent.request.subject,
                  parent.request.audiences.contains(context.audience), request.isSubset(of: parent.request),
                  supplied.isSubset(of: parent.credentialReferences) else { throw RCIRError.authorityDenied }
        }
        let grant = try RCIRAuthorityGrant(request: request, issuer: issuer, references: supplied, now: now, parent: parent)
        let retained = grants.values.reduce(0) { $0 + $1.grant.bytes.count }
        guard grant.bytes.count <= maximumGrantBytes - retained else { throw RCIRError.invalidLimit }
        grants[grant.id] = Entry(grant: grant); return grant
    }
    mutating func check(_ grant: RCIRAuthorityGrant, context: RCIRAuthorityContext, binding: RCIRBinding,
                        arguments: CapabilityValue, now: Int64, consume: Bool, enforceBudget: Bool = true) throws {
        try time(now)
        let ids = try chain(grant, now: now)
        guard context.subject == grant.request.subject, grant.request.audiences.contains(context.audience),
              grant.request.targets.contains(try RCIRAuthorityTarget(binding)),
              let scopes = binding.contract.scopes, scopes.isSubset(of: grant.request.scopes),
              grant.request.taskShapes.contains(binding.contract.task.shape),
              try grant.request.arguments.permits(arguments) else { throw RCIRError.authorityDenied }
        if enforceBudget {
            for id in ids {
                guard let entry = grants[id], entry.used < entry.grant.request.invocationLimit else { throw RCIRError.authorityDenied }
            }
        }
        if consume { for id in ids { grants[id]!.used += 1 } }
    }
    mutating func revoke(_ grant: RCIRAuthorityGrant) throws {
        guard let entry = grants[grant.id], entry.grant.bytes == grant.bytes else { throw RCIRError.authorityDenied }
        grants[grant.id]!.revoked = true
    }
}
