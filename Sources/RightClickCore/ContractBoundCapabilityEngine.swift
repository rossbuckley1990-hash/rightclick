import CryptoKit
import Foundation

/// An engine-local immutable request, not an approval or a replay-protected lease.
public struct PreparedCapabilityInvocation {
    public let actionID: String
    public let contractSHA256: String
    public let invocationSHA256: String
    fileprivate let owner: UUID
    fileprivate let raw: String
    fileprivate let text: String
    fileprivate let arguments: CapabilityArguments?
    fileprivate let expectedOutput: String?
    fileprivate let verification: VerificationSpec?
    fileprivate let binding: CapabilityInvocationBinding

    fileprivate init(owner: UUID, capability: Capability, raw: String, text: String,
                     arguments: CapabilityArguments?, expectedOutput: String?, verification: VerificationSpec?) throws {
        self.owner = owner; self.raw = raw; self.text = text
        self.arguments = arguments; self.expectedOutput = expectedOutput; self.verification = verification
        actionID = capability.id
        let contract = try capability.abiContract()
        contractSHA256 = try contract.sha256()
        binding = try CapabilityInvocationBinding(contract: contract,
            context: .object(["raw": .string(raw), "text": .string(text)]),
            arguments: CapabilityValue.fromLegacyArguments(arguments),
            verification: Self.verificationValue(verification, expectedOutput))
        invocationSHA256 = SHA256.hash(data: binding.canonicalData()).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func verificationValue(_ spec: VerificationSpec?, _ expected: String?) -> CapabilityValue {
        .object([
            "expectedOutput": expected.map { .string($0) } ?? .null,
            "spec": spec.map { spec in .object([
                "timeout": spec.timeoutMilliseconds.map { .integer(Int64($0)) } ?? .null,
                "predicates": .array(spec.predicates.map { p in .object([
                    "type": .string(p.type.rawValue), "key": p.key.map { .string($0) } ?? .null,
                    "value": p.value.map { .string($0) } ?? .null,
                    "reference": p.reference.map { .string($0) } ?? .null,
                    "width": p.width.map { .integer(Int64($0)) } ?? .null,
                    "height": p.height.map { .integer(Int64($0)) } ?? .null,
                    "bytes": p.bytes.map { .integer(Int64($0)) } ?? .null
                ]) })
            ]) } ?? .null
        ])
    }
}

/// Opt-in core path. Uses existing execution/verification; MCP is unchanged.
/// Like CapabilityEngine, this type must be called on the runtime's serial lane.
public final class ContractBoundCapabilityEngine {
    private let owner = UUID()
    private let reflectors: [any CapabilityReflector]
    private let sources: [any CapabilityReflectorSource]
    private let discovery: CapabilityEngine

    public init(reflectors: [any CapabilityReflector] = [],
                reflectorSources: [any CapabilityReflectorSource] = []) {
        self.reflectors = reflectors; self.sources = reflectorSources
        discovery = CapabilityEngine(reflectors: reflectors, reflectorSources: reflectorSources)
    }

    public func prepare(id: String, item: String, arguments: CapabilityArguments? = nil,
                        expectedOutput: String? = nil, verification: VerificationSpec? = nil) throws -> PreparedCapabilityInvocation {
        let inspected = try discovery.inspect(item)
        guard inspected.kind == "text", inspected.text != nil else { throw CapabilityBindingError.unsupportedContext }
        let (parsed, capabilities) = try discovery.capabilities(for: item)
        guard parsed.kind == "text", let text = parsed.text else { throw CapabilityBindingError.unsupportedContext }
        let matches = capabilities.filter { $0.id.utf8.elementsEqual(id.utf8) }
        guard matches.count == 1, matches[0].invocation != .unsupported else { throw CapabilityBindingError.unknownCapability }
        return try PreparedCapabilityInvocation(owner: owner, capability: matches[0], raw: item, text: text,
            arguments: arguments, expectedOutput: expectedOutput, verification: verification)
    }

    public func begin(_ plan: PreparedCapabilityInvocation, confirmed: Bool = false) throws -> ExecutionRecord {
        guard plan.owner == owner else { throw CapabilityBindingError.foreignPlan }
        let engine = CapabilityEngine(reflectors: reflectors.map { bindingReflector($0, plan) },
                                      reflectorSources: sources.map { BindingSource($0, plan) })
        return try engine.begin(id: plan.actionID, item: plan.raw, confirmed: confirmed,
            arguments: plan.arguments, expectedOutput: plan.expectedOutput, verification: plan.verification)
    }

    public func executionStatus(_ id: String) -> ExecutionRecord { discovery.executionStatus(id) }
}

private func bindingReflector(_ inner: any CapabilityReflector, _ plan: PreparedCapabilityInvocation) -> any CapabilityReflector {
    if let verifier = inner as? any CapabilityVerificationReflector {
        return VerificationBindingReflector(verifier, plan)
    }
    return BindingReflector(inner, plan)
}

private final class BindingSource: ContextualCapabilityReflectorSource {
    let source: any CapabilityReflectorSource
    let plan: PreparedCapabilityInvocation
    var id: String { source.id }
    init(_ source: any CapabilityReflectorSource, _ plan: PreparedCapabilityInvocation) { self.source = source; self.plan = plan }
    func reflectors() -> [any CapabilityReflector] { source.reflectors().map { bindingReflector($0, plan) } }
    func reflectors(for item: ContentItem) -> [any CapabilityReflector] {
        guard item.kind == "text", item.text?.utf8.elementsEqual(plan.text.utf8) == true else { return [] }
        let values = (source as? any ContextualCapabilityReflectorSource)?.reflectors(for: item) ?? source.reflectors()
        return values.map { bindingReflector($0, plan) }
    }
}

private class BindingReflector: CapabilityReflector {
    let inner: any CapabilityReflector
    let plan: PreparedCapabilityInvocation
    var id: String { inner.id }
    var completionWaitSeconds: TimeInterval { inner.completionWaitSeconds }
    init(_ inner: any CapabilityReflector, _ plan: PreparedCapabilityInvocation) { self.inner = inner; self.plan = plan }
    func capabilities(for item: ContentItem) throws -> [Capability] {
        guard item.kind == "text", item.text?.utf8.elementsEqual(plan.text.utf8) == true else { return [] }
        return try inner.capabilities(for: item)
    }
    func providers() -> [ProviderSummary] { inner.providers() }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        try begin(capability: capability, item: item, executionID: executionID, arguments: nil)
    }
    func begin(capability: Capability, item: ContentItem, executionID: String,
               arguments: CapabilityArguments?) throws -> ExecutionRecord {
        do { try validate(capability, item, arguments, plan.verification) }
        catch { return rejection(executionID) }
        return try inner.begin(capability: capability, item: item, executionID: executionID, arguments: arguments)
    }
    func validate(_ capability: Capability, _ item: ContentItem, _ arguments: CapabilityArguments?,
                  _ verification: VerificationSpec?) throws {
        guard item.kind == "text", let text = item.text else { throw CapabilityBindingError.unsupportedContext }
        let context = CapabilityValue.object(["raw": .string(plan.raw), "text": .string(text)])
        let request = PreparedCapabilityInvocation.verificationValue(verification, plan.expectedOutput)
        try plan.binding.validate(contract: capability.abiContract(), context: context,
            arguments: CapabilityValue.fromLegacyArguments(arguments), verification: request)
        // Re-read the selected instance. Do not silently switch to another
        // declaration with the same ID between engine selection and invocation.
        let matches = try inner.capabilities(for: item).filter { $0.id.utf8.elementsEqual(plan.actionID.utf8) }
        guard matches.count == 1 else { throw CapabilityBindingError.unknownCapability }
        var current = matches[0]
        current.reflectorID = id // Ownership comes from the runtime, not metadata.
        try plan.binding.validate(contract: current.abiContract(), context: context,
            arguments: CapabilityValue.fromLegacyArguments(arguments), verification: request)
    }
    func rejection(_ executionID: String) -> ExecutionRecord {
        ExecutionRecord(executionId: executionID, actionId: plan.actionID, state: .rejected,
            message: "CONTRACT_BINDING_MISMATCH. Prepare a new request; no provider invocation occurred.",
            evidence: OutcomeEvidence(type: "contract_binding_rejected",
                boundary: "The guarded reflector rejected a changed or unavailable declaration before provider invocation."))
    }
}

private final class VerificationBindingReflector: BindingReflector, CapabilityVerificationReflector {
    private let verifier: any CapabilityVerificationReflector
    init(_ inner: any CapabilityVerificationReflector, _ plan: PreparedCapabilityInvocation) {
        verifier = inner
        super.init(inner, plan)
    }
    func begin(capability: Capability, item: ContentItem, executionID: String,
               arguments: CapabilityArguments?, verification: VerificationSpec) throws -> ExecutionRecord {
        do { try validate(capability, item, arguments, verification) }
        catch { return rejection(executionID) }
        return try verifier.begin(capability: capability, item: item, executionID: executionID,
                                  arguments: arguments, verification: verification)
    }
}
