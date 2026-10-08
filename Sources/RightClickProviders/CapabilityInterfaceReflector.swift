import Foundation
import RightClickProtocol
public final class CapabilityInterfaceReflector: RCIRExecutionReflector {
    public typealias Invocation = (String, CapabilityValue, (_ start: () -> Void) throws -> Void) throws -> CapabilityValue
    public typealias BoundInvocation = (String, CapabilityValue, RCIRInvocationBinding, (_ start: () -> Void) throws -> Void) throws -> CapabilityValue
    public let id: String
    private let target: URL
    private let operations: [String: CapabilityInterfaceOperation]
    private let capabilitiesByID: [String: Capability]
    private let invoke: Invocation
    private let boundInvoke: BoundInvocation?
    private let available: () -> Bool
    private let standaloneHost = RCIRExecutionHost()
    private let observerFactory: ((String) -> RCIRHostObserverFactory?)?
    private let argumentEncoding: CapabilityCoreArgumentEncoding

    public init(id: String, provider: String, target: URL, substrate: String,
                descriptorDigest: String, operations: [CapabilityInterfaceOperation],
                provenance: [String: String] = [:], observerFactory: ((String) -> RCIRHostObserverFactory?)? = nil,
                argumentEncoding: CapabilityCoreArgumentEncoding = .literalStrings,
                runtimeRequirements: RuntimeRequirements? = nil,
                available: @escaping () -> Bool,
                boundInvoke: BoundInvocation? = nil,
                invoke: @escaping Invocation) throws {
        guard !id.isEmpty, !operations.isEmpty, operations.count <= 256,
              Set(operations.map(\.name)).count == operations.count else { throw CapabilityABIError.invalidIdentity }
        self.id = id; self.target = target; self.invoke = invoke; self.available = available
        self.boundInvoke = boundInvoke
        self.observerFactory = observerFactory
        self.argumentEncoding = argumentEncoding
        var indexed: [String: CapabilityInterfaceOperation] = [:]
        var capabilities: [String: Capability] = [:]
        for operation in operations {
            guard !operation.name.isEmpty, operation.name.utf8.count <= 256,
                  operation.name.rangeOfCharacter(from: .controlCharacters) == nil else { throw CapabilityABIError.invalidIdentity }
            _ = try operation.arguments.canonicalData(); _ = try operation.result.canonicalData()
            let actionID = id + ":" + operation.name
            var metadata = provenance
            metadata.merge(["providerIdentity": provider, "interfaceKind": substrate,
                            "descriptorSHA256": descriptorDigest, "descriptorSource": target.absoluteString,
                            "operationName": operation.name, "executionMode": "unary",
                            "coreArgumentEncoding": argumentEncoding.rawValue,
                            "effect": operation.effect.rawValue,
                            "argumentSchema": try operation.arguments.canonicalData().base64EncodedString(),
                            "resultSchema": try operation.result.canonicalData().base64EncodedString(),
                            "verificationBoundary": "Provider completion is unverified until the host establishes a postcondition."]) { _, value in value }
            if case let .object(properties, required) = operation.arguments {
                metadata["argumentNames"] = properties.keys.sorted().joined(separator: ",")
                metadata["requiredArguments"] = required.sorted().joined(separator: ",")
            }
            let capability = Capability(id: actionID, title: operation.title, source: .system,
                reflectorID: id, provider: CapabilityProvider(name: provider), inputs: ["text"], output: ["typed_value"],
                safety: .unknown, invocation: .direct, supportLevel: .publicSupported,
                requiresConfirmation: true, metadata: metadata, runtimeRequirements: runtimeRequirements)
            indexed[actionID] = operation; capabilities[actionID] = capability
        }
        self.operations = indexed; self.capabilitiesByID = capabilities
    }

    public func capabilities(for item: ContentItem) throws -> [Capability] {
        guard available() else { return [] }
        return capabilitiesByID.values.sorted { $0.id < $1.id }
    }
    public func providers() -> [ProviderSummary] {
        guard available(), let first = capabilitiesByID.values.first else { return [] }
        return [.init(name: first.provider?.name ?? id, source: "interface", capabilityTitles: capabilitiesByID.values.map(\.title).sorted())]
    }
    public func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        try begin(capability: capability, item: item, executionID: executionID, arguments: nil)
    }
    public func begin(capability: Capability, item: ContentItem, executionID: String,
                      arguments: CapabilityArguments?) throws -> ExecutionRecord {
        try admittedBegin(capability: capability, admissionOwner: capability, item: item, executionID: executionID,
                          arguments: arguments, verification: nil, expectedOutput: nil, host: standaloneHost, revalidate: available)
    }
    public func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem, executionID: String,
                              arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?,
                              host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        guard let operation = operations[capability.id], available() else { throw RCIRError.unavailable }
        let input = try argumentEncoding.decode(arguments, schema: operation.arguments)
        var owner = CapabilityDispatchContract.withoutExperience(admissionOwner)
        if owner.reflectorID == "unowned" { owner.reflectorID = id }
        let discovery = try owner.abiContract(arguments: operation.arguments, result: operation.result)
        let abi = CapabilityContract(capabilityID: discovery.capabilityID, reflectorID: discovery.reflectorID,
            providerID: discovery.providerID, arguments: operation.arguments, result: operation.result,
            declaration: .object(["capability": discovery.declaration, "interface": operation.declaration,
                "verification": try verification.map { .bytes(try JSONEncoder().encode($0)) } ?? .null,
                "expectedOutput": expectedOutput.map { .string($0) } ?? .null]))
        let scope = RCIRScope(target.absoluteString + "#" + operation.name, operation.effect)
        var returned: CapabilityValue?
        return try host.execute(abi: abi, discovery: discovery, arguments: input, scope: scope,
            capability: admissionOwner, executionID: executionID, argumentStrings: arguments, item: item,
            verification: verification, expectedOutput: expectedOutput, target: target,
            authority: { self.available() ? [scope] : [] }, revalidate: { self.available() && revalidate() },
            observerFactory: observerFactory?(operation.name),
            dispatch: { taskID, admit in
                let value = try self.boundInvoke.map { try $0(operation.name, input, RCIRInvocationBinding(taskID: taskID), admit) }
                    ?? self.invoke(operation.name, input, admit)
                if case .unit = operation.result {
                    guard case .null = value else { throw CapabilityABIError.schemaMismatch }
                } else { try operation.result.validate(value) }
                returned = value
                return ExecutionRecord(executionId: executionID, actionId: capability.id, title: capability.title,
                    state: .accepted, message: "The provider returned a schema-valid value; semantic success requires host verification.",
                    output: try { if case .unit = operation.result { return nil }; return try CapabilityJSON.display(value) }(),
                    evidence: .init(type: "interface_provider_result", boundary: "Provider result only; not independent verification."))
            }, resultValue: { _ in guard let returned else { throw RCIRError.unverified }; return returned })
    }
}
