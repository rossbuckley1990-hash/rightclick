import Foundation

public enum CapabilityABIError: Error, Equatable {
    case invalidWire
    case invalidLimits
    case limitExceeded
    case nonfiniteNumber
    case invalidSchema
    case schemaMismatch
    case unknownSchema
    case invalidIdentity
    case nonStringLegacyArgument
}

/// Callers may tighten, but never raise, the ABI-001 hard resource ceilings.
public struct CapabilityABILimits: Sendable {
    public let maxDepth: Int
    public let maxNodes: Int
    public let maxBytes: Int
    public init(maxDepth: Int = 32, maxNodes: Int = 4096, maxBytes: Int = 1_048_576) {
        self.maxDepth = maxDepth; self.maxNodes = maxNodes; self.maxBytes = maxBytes
    }
    fileprivate func check() throws {
        guard (0...32).contains(maxDepth), (1...4096).contains(maxNodes),
              (1...1_048_576).contains(maxBytes) else { throw CapabilityABIError.invalidLimits }
    }
}

/// Typed ABI values, not a replacement for the current string-only MCP inputs.
/// Integers are Int64; numbers are finite IEEE-754 binary64, not exact decimals.
public indirect enum CapabilityValue: Sendable, Codable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case bytes(Data)
    case array([CapabilityValue])
    case object([String: CapabilityValue])

    /// Versioned, type-tagged and length-framed bytes. This is NOT RFC 8785 JCS.
    /// UTF-8 and negative zero are preserved. Compare these bytes, not Swift's
    /// Unicode-normalising String equality, when binding authority in later gates.
    public func canonicalData(limits: CapabilityABILimits = .init()) throws -> Data {
        try limits.check()
        var data = Data()
        var nodes = 0
        func append(_ part: Data) throws {
            guard part.count <= limits.maxBytes - data.count else { throw CapabilityABIError.limitExceeded }
            data.append(part)
        }
        func ascii(_ text: String) throws { try append(Data(text.utf8)) }
        func frame(_ tag: String, _ payload: Data) throws {
            try ascii(tag + String(payload.count) + ":")
            try append(payload)
        }
        func write(_ value: CapabilityValue, depth: Int) throws {
            guard depth <= limits.maxDepth, nodes < limits.maxNodes else { throw CapabilityABIError.limitExceeded }
            nodes += 1
            switch value {
            case .null: try ascii("n")
            case let .boolean(value): try ascii(value ? "b1" : "b0")
            case let .integer(value): try frame("i", Data(String(value).utf8))
            case let .number(value):
                guard value.isFinite else { throw CapabilityABIError.nonfiniteNumber }
                try ascii("d")
                var bits = value.bitPattern.bigEndian
                try withUnsafeBytes(of: &bits) { try append(Data($0)) }
            case let .string(value): try frame("s", Data(value.utf8))
            case let .bytes(value): try frame("x", value)
            case let .array(values):
                try ascii("a" + String(values.count) + ":")
                for value in values { try write(value, depth: depth + 1) }
            case let .object(values):
                try ascii("o" + String(values.count) + ":")
                for key in Self.ordered(values.keys) {
                    try write(.string(key), depth: depth + 1)
                    try write(values[key]!, depth: depth + 1)
                }
            }
        }
        try ascii("RIGHTCLICK-VALUE-1\0")
        try write(self, depth: 0)
        return data
    }

    /// Bounded tagged JSON transport. Numeric payloads are strings so a JSON
    /// intermediary cannot silently round Int64 or erase a number's exact bits.
    public func wireData(limits: CapabilityABILimits = .init()) throws -> Data {
        _ = try canonicalData(limits: limits)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= limits.maxBytes else { throw CapabilityABIError.limitExceeded }
        return data
    }

    public static func decodeWire(_ data: Data, limits: CapabilityABILimits = .init()) throws -> Self {
        try limits.check()
        guard data.count <= limits.maxBytes else { throw CapabilityABIError.limitExceeded }
        let value = try JSONDecoder().decode(Self.self, from: data)
        _ = try value.canonicalData(limits: limits)
        return value
    }

    public func encode(to encoder: Encoder) throws {
        guard encoder.codingPath.count <= 128 else { throw CapabilityABIError.limitExceeded }
        _ = try canonicalData()
        var container = encoder.unkeyedContainer()
        switch self {
        case .null: try container.encode("null")
        case let .boolean(value): try container.encode("boolean"); try container.encode(value)
        case let .integer(value): try container.encode("integer"); try container.encode(String(value))
        case let .number(value):
            guard value.isFinite else { throw CapabilityABIError.nonfiniteNumber }
            try container.encode("number")
            try container.encode(String(format: "%016llx", value.bitPattern))
        case let .string(value): try container.encode("string"); try container.encode(value)
        case let .bytes(value): try container.encode("bytes"); try container.encode(value.base64EncodedString())
        case let .array(values): try container.encode("array"); try container.encode(values)
        case let .object(values):
            try container.encode("object")
            var entries = container.nestedUnkeyedContainer()
            for key in Self.ordered(values.keys) {
                var pair = entries.nestedUnkeyedContainer()
                try pair.encode(key); try pair.encode(values[key]!)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        // Reject deep tagged nesting during decoding, not only after allocation.
        guard decoder.codingPath.count <= 128 else { throw CapabilityABIError.limitExceeded }
        var container = try decoder.unkeyedContainer()
        let tag = try container.decode(String.self)
        switch tag {
        case "null": self = .null
        case "boolean": self = .boolean(try container.decode(Bool.self))
        case "integer":
            let raw = try container.decode(String.self)
            guard let value = Int64(raw), String(value) == raw else { throw CapabilityABIError.invalidWire }
            self = .integer(value)
        case "number":
            let raw = try container.decode(String.self)
            guard raw.utf8.count == 16, raw.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let bits = UInt64(raw, radix: 16) else { throw CapabilityABIError.invalidWire }
            let value = Double(bitPattern: bits)
            guard value.isFinite else { throw CapabilityABIError.nonfiniteNumber }
            self = .number(value)
        case "string": self = .string(try container.decode(String.self))
        case "bytes":
            let raw = try container.decode(String.self)
            guard let value = Data(base64Encoded: raw), value.base64EncodedString() == raw else { throw CapabilityABIError.invalidWire }
            self = .bytes(value)
        case "array":
            var elements = try container.nestedUnkeyedContainer()
            var values: [Self] = []
            while !elements.isAtEnd {
                guard values.count < 4096 else { throw CapabilityABIError.limitExceeded }
                values.append(try elements.decode(Self.self))
            }
            self = .array(values)
        case "object":
            var entries = try container.nestedUnkeyedContainer()
            var values: [String: Self] = [:]
            while !entries.isAtEnd {
                guard values.count < 4096 else { throw CapabilityABIError.limitExceeded }
                var pair = try entries.nestedUnkeyedContainer()
                let key = try pair.decode(String.self)
                // Also reject Unicode-equivalent Swift keys rather than lose one.
                guard values[key] == nil else { throw CapabilityABIError.invalidWire }
                values[key] = try pair.decode(Self.self)
                guard pair.isAtEnd else { throw CapabilityABIError.invalidWire }
            }
            self = .object(values)
        default: throw CapabilityABIError.invalidWire
        }
        guard container.isAtEnd else { throw CapabilityABIError.invalidWire }
        _ = try canonicalData()
    }

    public static func fromLegacyArguments(_ arguments: [String: String]?) -> Self? {
        arguments.map { .object($0.mapValues { .string($0) }) }
    }

    /// No stringification, JSON-in-string conversion or dropping unknown fields.
    public func legacyArguments() throws -> [String: String] {
        _ = try canonicalData()
        guard case let .object(values) = self else { throw CapabilityABIError.nonStringLegacyArgument }
        var result: [String: String] = [:]
        for (key, value) in values {
            guard case let .string(text) = value else { throw CapabilityABIError.nonStringLegacyArgument }
            result[key] = text
        }
        return result
    }

    fileprivate static func ordered<S: Sequence>(_ values: S) -> [String] where S.Element == String {
        values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}

/// A deliberately closed structural subset; not an implementation of JSON Schema.
/// Unknown constraints must be rejected by an importing compiler, never discarded.
public indirect enum CapabilitySchema: Sendable {
    case null, boolean, integer, number, string, bytes
    case stringEnum([String])
    case array(CapabilitySchema)
    case object(properties: [String: CapabilitySchema], required: [String])
    case nullable(CapabilitySchema)

    public func canonicalData() throws -> Data {
        var remaining = 4096
        return try representation(depth: 0, remaining: &remaining).canonicalData()
    }

    private func representation(depth: Int, remaining: inout Int) throws -> CapabilityValue {
        guard depth <= 32, remaining > 0 else { throw CapabilityABIError.limitExceeded }
        remaining -= 1
        switch self {
        case .null: return .string("null")
        case .boolean: return .string("boolean")
        case .integer: return .string("integer")
        case .number: return .string("number")
        case .string: return .string("string")
        case .bytes: return .string("bytes")
        case let .stringEnum(values):
            guard !values.isEmpty, values.count == Set(values).count else { throw CapabilityABIError.invalidSchema }
            return .object(["enum": .array(CapabilityValue.ordered(values).map { .string($0) })])
        case let .array(schema):
            return .object(["array": try schema.representation(depth: depth + 1, remaining: &remaining)])
        case let .nullable(schema):
            return .object(["nullable": try schema.representation(depth: depth + 1, remaining: &remaining)])
        case let .object(properties, required):
            guard required.count == Set(required).count, Set(required.map { Data($0.utf8) }).isSubset(of: Set(properties.keys.map { Data($0.utf8) })),
                  properties.count <= remaining else { throw CapabilityABIError.invalidSchema }
            var fields: [String: CapabilityValue] = [:]
            for key in CapabilityValue.ordered(properties.keys) {
                fields[key] = try properties[key]!.representation(depth: depth + 1, remaining: &remaining)
            }
            return .object(["object": .object(fields),
                "required": .array(CapabilityValue.ordered(required).map { .string($0) }),
                "additionalProperties": .boolean(false)])
        }
    }

    public func validate(_ value: CapabilityValue) throws {
        _ = try canonicalData()
        _ = try value.canonicalData()
        try check(value)
    }

    private func check(_ value: CapabilityValue) throws {
        switch (self, value) {
        case (.null, .null), (.boolean, .boolean), (.integer, .integer),
             (.number, .number), (.string, .string), (.bytes, .bytes): return
        case let (.stringEnum(choices), .string(text)):
            guard choices.contains(where: { $0.utf8.elementsEqual(text.utf8) }) else { throw CapabilityABIError.schemaMismatch }
        case (.nullable, .null): return
        case let (.nullable(schema), value): try schema.check(value)
        case let (.array(schema), .array(values)):
            for value in values { try schema.check(value) }
        case let (.object(properties, required), .object(values)):
            // Match exact UTF-8, not Swift's canonically equivalent key lookup.
            let actual = Set(values.keys.map { Data($0.utf8) })
            let allowed = Set(properties.keys.map { Data($0.utf8) })
            guard actual.isSubset(of: allowed), Set(required.map { Data($0.utf8) }).isSubset(of: actual)
            else { throw CapabilityABIError.schemaMismatch }
            for (key, value) in values { try properties[key]!.check(value) }
        default: throw CapabilityABIError.schemaMismatch
        }
    }
}

/// Immutable declaration snapshot. No field grants authority or verifies an
/// outcome. Provider identity here is a locator, not an authenticated principal.
public struct CapabilityContract: Sendable {
    public static let version = 1
    public let capabilityID: String
    public let reflectorID: String
    public let providerID: String
    public let arguments: CapabilitySchema?
    public let result: CapabilitySchema?
    public let declaration: CapabilityValue

    public init(capabilityID: String, reflectorID: String, providerID: String,
                arguments: CapabilitySchema?, result: CapabilitySchema?, declaration: CapabilityValue) {
        self.capabilityID = capabilityID; self.reflectorID = reflectorID; self.providerID = providerID
        self.arguments = arguments; self.result = result; self.declaration = declaration
    }

    public func canonicalData() throws -> Data {
        guard [capabilityID, reflectorID, providerID].allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 4096 && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else { throw CapabilityABIError.invalidIdentity }
        let value = CapabilityValue.object([
            "version": .integer(Int64(Self.version)), "capability": .string(capabilityID),
            "reflector": .string(reflectorID), "provider": .string(providerID),
            "arguments": try arguments.map { .bytes(try $0.canonicalData()) } ?? .null,
            "result": try result.map { .bytes(try $0.canonicalData()) } ?? .null,
            "declaration": declaration
        ])
        var data = Data("RIGHTCLICK-CONTRACT-1\0".utf8)
        data.append(try value.canonicalData())
        guard data.count <= 1_048_576 else { throw CapabilityABIError.limitExceeded }
        return data
    }

    public func validateArguments(_ value: CapabilityValue) throws {
        _ = try canonicalData()
        guard let arguments else { throw CapabilityABIError.unknownSchema }
        try arguments.validate(value)
    }
}
