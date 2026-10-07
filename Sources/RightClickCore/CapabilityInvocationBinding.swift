import Foundation

public enum CapabilityBindingError: Error, Equatable {
    case mismatch
    case unsupportedContext
    case unknownCapability
    case foreignPlan
}

/// Immutable content binding, NOT an approval, signature or single-use lease.
/// Canonical bytes contain potentially private inputs; do not log them.
public struct CapabilityInvocationBinding: Sendable, Equatable {
    private let bytes: Data

    public init(contract: CapabilityContract, context: CapabilityValue,
                arguments: CapabilityValue? = nil, verification: CapabilityValue? = nil) throws {
        let envelope = CapabilityValue.object([
            "contract": .bytes(try contract.canonicalData()),
            "context": context,
            // Empty option envelope is absent; [null] is explicitly present null.
            "arguments": .array(arguments.map { [$0] } ?? []),
            "verification": .array(verification.map { [$0] } ?? [])
        ])
        var data = Data("RIGHTCLICK-INVOCATION-1\0".utf8)
        data.append(try envelope.canonicalData())
        guard data.count <= 1_048_576 else { throw CapabilityABIError.limitExceeded }
        bytes = data
    }

    public func canonicalData() -> Data { bytes }

    public func validate(contract: CapabilityContract, context: CapabilityValue,
                         arguments: CapabilityValue? = nil, verification: CapabilityValue? = nil) throws {
        let candidate = try Self(contract: contract, context: context,
                                 arguments: arguments, verification: verification)
        guard candidate == self else { throw CapabilityBindingError.mismatch }
    }
}
