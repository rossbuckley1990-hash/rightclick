#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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
    public let effect: RCIREffect

    public init(name: String, title: String, arguments: CapabilitySchema,
                result: CapabilitySchema, declaration: CapabilityValue, effect: RCIREffect = .execute) {
        self.name = name; self.title = title; self.arguments = arguments
        self.result = result; self.declaration = declaration
        self.effect = effect
    }
}

/// Closed JSON Schema importer shared by MCP and other descriptor formats.
/// Unsupported constraints are rejected, never silently erased.
public enum CapabilityJSON {
    public static func schema(_ raw: Any, depth: Int = 0) throws -> CapabilitySchema {
        guard depth <= 32, let object = raw as? [String: Any],
              let type = object["type"] as? String else { throw CapabilityABIError.invalidSchema }
        let annotations: Set<String> = ["title", "description", "$schema"]
        let structural: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum", "pattern", "minLength", "maxLength"]
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
            return try CapabilitySchema.stringContract(object)
        case "null", "boolean", "integer", "number":
            guard keys == ["type"] else { throw CapabilityABIError.invalidSchema }
            switch type { case "null": return .null; case "boolean": return .boolean; case "integer": return .integer; default: return .number }
        default: throw CapabilityABIError.invalidSchema
        }
    }
    public static func value(_ raw: Any, depth: Int = 0) throws -> CapabilityValue {
        guard depth <= 32 else { throw CapabilityABIError.limitExceeded }
        if raw is NSNull { return .null }
        if let string = raw as? String { return .string(string) }
        if let number = raw as? NSNumber {
            if CapabilityJSONNumber.isBoolean(number) { return .boolean(number.boolValue) }
            if ["f", "d"].contains(String(cString: number.objCType)) { return .number(number.doubleValue) }
            guard let integer = Int64(number.stringValue) else { throw CapabilityABIError.invalidWire }
            return .integer(integer)
        }
        if let array = raw as? [Any] {
            guard array.count <= 4096 else { throw CapabilityABIError.limitExceeded }
            return .array(try array.map { try value($0, depth: depth + 1) })
        }
        if let object = raw as? [String: Any] {
            guard object.count <= 4096 else { throw CapabilityABIError.limitExceeded }
            return .object(try object.mapValues { try value($0, depth: depth + 1) })
        }
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
