import CryptoKit
import CoreFoundation
import Foundation

/// Shared lowering boundary for descriptor-acquired unary interfaces. Protocol
/// code acquires declarations and exchanges typed values; policy, exact scope,
/// one-use admission, lifecycle, verification and receipts stay in the host.
public struct CapabilityInterfaceOperation {
    public let name: String
    public let title: String
    public let arguments: CapabilitySchema
    public let result: CapabilitySchema
    public let declaration: CapabilityValue

    public init(name: String, title: String, arguments: CapabilitySchema,
                result: CapabilitySchema, declaration: CapabilityValue) {
        self.name = name; self.title = title; self.arguments = arguments
        self.result = result; self.declaration = declaration
    }
}

public final class CapabilityInterfaceReflector: RCIRExecutionReflector {
    public typealias Invocation = (String, CapabilityValue, (_ start: () -> Void) throws -> Void) throws -> CapabilityValue
    public let id: String
    private let target: URL
    private let operations: [String: CapabilityInterfaceOperation]
    private let capabilitiesByID: [String: Capability]
    private let invoke: Invocation
    private let available: () -> Bool
    private let standaloneHost = RCIRExecutionHost()

    public init(id: String, provider: String, target: URL, substrate: String,
                descriptorDigest: String, operations: [CapabilityInterfaceOperation],
                provenance: [String: String] = [:], available: @escaping () -> Bool,
                invoke: @escaping Invocation) throws {
        guard !id.isEmpty, !operations.isEmpty, operations.count <= 256,
              Set(operations.map(\.name)).count == operations.count else { throw CapabilityABIError.invalidIdentity }
        self.id = id; self.target = target; self.invoke = invoke; self.available = available
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
                requiresConfirmation: true, metadata: metadata)
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
        let input = CapabilityValue.fromLegacyArguments(arguments) ?? .object([:])
        // The seven-operation legacy surface is string-valued. Rich schemas are
        // retained faithfully, but incompatible inputs fail closed, never coerced.
        try operation.arguments.validate(input)
        var owner = CapabilityExperience.withoutExperience(admissionOwner)
        if owner.reflectorID == "unowned" { owner.reflectorID = id }
        let discovery = try owner.abiContract(arguments: operation.arguments, result: operation.result)
        let abi = CapabilityContract(capabilityID: discovery.capabilityID, reflectorID: discovery.reflectorID,
            providerID: discovery.providerID, arguments: operation.arguments, result: operation.result,
            declaration: .object(["capability": discovery.declaration, "interface": operation.declaration,
                "verification": try verification.map { .bytes(try JSONEncoder().encode($0)) } ?? .null,
                "expectedOutput": expectedOutput.map { .string($0) } ?? .null]))
        let scope = RCIRScope(target.absoluteString + "#" + operation.name, .execute)
        var returned: CapabilityValue?
        return try host.execute(abi: abi, discovery: discovery, arguments: input, scope: scope,
            capability: admissionOwner, executionID: executionID, argumentStrings: arguments, item: item,
            verification: verification, expectedOutput: expectedOutput, target: target,
            authority: { self.available() ? [scope] : [] }, revalidate: { self.available() && revalidate() },
            dispatch: { _, admit in
                let value = try self.invoke(operation.name, input, admit)
                try operation.result.validate(value)
                returned = value
                return ExecutionRecord(executionId: executionID, actionId: capability.id, title: capability.title,
                    state: .accepted, message: "The provider returned a schema-valid value; semantic success requires host verification.",
                    output: try CapabilityJSON.display(value),
                    evidence: .init(type: "interface_provider_result", boundary: "Provider result only; not independent verification."))
            }, resultValue: { _ in guard let returned else { throw RCIRError.unverified }; return returned })
    }
}

/// Closed JSON Schema importer shared by MCP and other descriptor formats.
/// Unsupported constraints are rejected, never silently erased.
public enum CapabilityJSON {
    public static func schema(_ raw: Any, depth: Int = 0) throws -> CapabilitySchema {
        guard depth <= 32, let object = raw as? [String: Any],
              let type = object["type"] as? String else { throw CapabilityABIError.invalidSchema }
        let annotations: Set<String> = ["title", "description", "$schema"]
        let structural: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum"]
        guard Set(object.keys).isSubset(of: annotations.union(structural)) else { throw CapabilityABIError.invalidSchema }
        let keys = Set(object.keys).subtracting(annotations)
        switch type {
        case "object":
            guard keys.isSubset(of: ["type", "properties", "required", "additionalProperties"]),
                  object["additionalProperties"] as? Bool == false,
                  let properties = object["properties"] as? [String: Any], properties.count <= 256,
                  object["required"] == nil || object["required"] is [String] else { throw CapabilityABIError.invalidSchema }
            let result = CapabilitySchema.object(properties: try properties.mapValues { try schema($0, depth: depth + 1) },
                                                 required: object["required"] as? [String] ?? [])
            _ = try result.canonicalData(); return result
        case "array":
            guard keys == ["type", "items"], let item = object["items"] else { throw CapabilityABIError.invalidSchema }
            return .array(try schema(item, depth: depth + 1))
        case "string":
            guard keys.isSubset(of: ["type", "enum"]) else { throw CapabilityABIError.invalidSchema }
            if let enumeration = object["enum"] {
                guard let values = enumeration as? [String] else { throw CapabilityABIError.invalidSchema }
                let result = CapabilitySchema.stringEnum(values); _ = try result.canonicalData(); return result
            }
            return .string
        case "null", "boolean", "integer", "number":
            guard keys == ["type"] else { throw CapabilityABIError.invalidSchema }
            switch type { case "null": return .null; case "boolean": return .boolean; case "integer": return .integer; default: return .number }
        default: throw CapabilityABIError.invalidSchema
        }
    }
    public static func value(_ raw: Any) throws -> CapabilityValue {
        if raw is NSNull { return .null }
        if let string = raw as? String { return .string(string) }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            if ["f", "d"].contains(String(cString: number.objCType)) { return .number(number.doubleValue) }
            return .integer(number.int64Value)
        }
        if let array = raw as? [Any] { return .array(try array.map(value)) }
        if let object = raw as? [String: Any] { return .object(try object.mapValues(value)) }
        throw CapabilityABIError.invalidWire
    }
    public static func object(_ value: CapabilityValue) throws -> Any {
        _ = try value.canonicalData()
        switch value {
        case .null: return NSNull()
        case let .boolean(value): return value
        case let .integer(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(values): return try values.map(object)
        case let .object(values): return try values.mapValues(object)
        case .bytes: throw CapabilityABIError.invalidWire
        }
    }
    public static func display(_ value: CapabilityValue) throws -> String {
        if case let .string(text) = value { return text }
        return String(decoding: try JSONSerialization.data(withJSONObject: object(value), options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
