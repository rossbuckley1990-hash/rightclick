import Foundation

/// Canonical host compilation shared by local admission and parent-side Link
/// verification. Keys and dependency selectors are host-installed, never trust
/// supplied by a child's report. A fresh authenticated transport request uses
/// its request UUID as the environment execution UUID.
public enum EnvironmentContextualInvocation {
    public static func digest(executionID: String, capabilityID: String, item: String,
        arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?,
        dependencies: [ExecutionDependency]) throws -> Data {
        guard EnvironmentIdentity.isCanonicalID(executionID), dependencies.count <= 8 else {
            throw EnvironmentError.invalidIdentity
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = CapabilityValue.object(["executionID": .string(executionID), "capabilityID": .string(capabilityID),
            "item": .string(item), "arguments": .object((arguments ?? [:]).mapValues(CapabilityValue.string)),
            "verification": try verification.map { .bytes(try encoder.encode($0)) } ?? .null,
            "expectedOutput": expectedOutput.map(CapabilityValue.string) ?? .null,
            "dependencies": .bytes(try encoder.encode(dependencies))])
        let hex = ExecutionEvidenceDigest.sha256(try request.canonicalData())
        var bytes = [UInt8](); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw EnvironmentError.invalidIdentity }
            bytes.append(byte); index = next
        }
        return Data(bytes)
    }
}
