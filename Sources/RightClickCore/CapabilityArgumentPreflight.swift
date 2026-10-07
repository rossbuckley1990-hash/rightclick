import Foundation
import CoreFoundation

public struct CapabilityPreflightIssue: Equatable, Sendable {
    public let code: String
    public let message: String
}

/// A bounded, side-effect-free early check of the advertised top-level argument
/// envelope. This is NOT a JSON Schema validator or an authorization decision.
/// Substrate validators remain responsible for values, enums, nested objects,
/// URL/path encoding, zero-argument rules, credentials and transport admission.
public enum CapabilityArgumentPreflight {
    public static let maximumSchemaBytes = 262_144

    private static func invalidSchema() -> CapabilityPreflightIssue {
        .init(code: "invalid_argument_schema", message: "The advertised argument envelope is malformed or exceeds the preflight limit. No provider was invoked.")
    }

    public static func issue(
        for capability: Capability,
        arguments: [String: String]?
    ) -> CapabilityPreflightIssue? {
        // Old/custom reflectors without this metadata retain their own input
        // validation. Absence of a schema is not proof that no arguments exist.
        guard let raw = capability.metadata["argumentsSchema"] else { return nil }
        guard raw.utf8.count <= maximumSchemaBytes else { return invalidSchema() }
        let data = Data(raw.utf8)
        guard let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              schema["type"] as? String == "object"
        else { return invalidSchema() }

        let properties: [String: Any]
        if let value = schema["properties"] {
            guard let object = value as? [String: Any] else { return invalidSchema() }
            properties = object
        } else {
            properties = [:]
        }
        let required: [String]
        if let value = schema["required"] {
            guard let names = value as? [String] else { return invalidSchema() }
            required = names
        } else {
            required = []
        }
        var closed = false
        if let additional = schema["additionalProperties"] {
            if let flag = additional as? NSNumber,
               CFGetTypeID(flag) == CFBooleanGetTypeID() {
                closed = !flag.boolValue
            } else if additional is [String: Any] {
                // The authoritative substrate validator owns this subschema.
                closed = false
            } else {
                return invalidSchema()
            }
        }
        let allowed = Set(properties.keys.map { Data($0.utf8) })
        let needed = Set(required.map { Data($0.utf8) })
        guard needed.count == required.count else { return invalidSchema() }
        // JSON Schema permits undeclared required names for open objects.
        guard !closed || needed.isSubset(of: allowed) else { return invalidSchema() }
        let supplied = Set((arguments ?? [:]).keys.map { Data($0.utf8) })
        if !needed.isSubset(of: supplied) {
            return .init(
                code: "missing_required_arguments",
                message: "Required capability arguments are missing. Inspect argumentsSchema and supply the required fields before requesting confirmation. No provider was invoked."
            )
        }
        if closed && !supplied.isSubset(of: allowed) {
            return .init(
                code: "unexpected_arguments",
                message: "Capability arguments include fields outside the advertised closed envelope. No provider was invoked."
            )
        }
        return nil
    }
}
