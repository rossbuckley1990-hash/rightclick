import Foundation

/// Explicit compiler-selected compatibility adapter. Literal string fields
/// remain literal. Rich values use the existing bounded, type-tagged ABI wire
/// format inside the Core profile's text field; JSON numbers never round them.
public enum CapabilityCoreArgumentEncoding: String {
    case literalStrings
    case taggedNonStrings

    package func decode(_ arguments: CapabilityArguments?, schema: CapabilitySchema) throws -> CapabilityValue {
        guard case let .object(properties, _) = schema else {
            throw CapabilityABIError.schemaMismatch
        }
        let supplied = arguments ?? [:]
        guard Set(supplied.keys).isSubset(of: Set(properties.keys)) else { throw CapabilityABIError.schemaMismatch }
        var values: [String: CapabilityValue] = [:]
        for (key, text) in supplied {
            let field = properties[key]!
            switch (self, field) {
            case (.literalStrings, _), (_, .string), (_, .stringEnum), (_, .constrainedString):
                values[key] = .string(text)
            default:
                values[key] = try CapabilityValue.decodeWire(Data(text.utf8))
            }
        }
        let value = CapabilityValue.object(values)
        try schema.validate(value)
        return value
    }
}
