#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public extension CapabilityContract {
    static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Content fingerprint only: not a signature, approval token or attestation.
    func sha256() throws -> String {
        SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
    }
}

public extension Capability {
    /// Uses the existing exact ABI declaration; unknown schemas stay unknown.
    /// The fingerprint and engine-owned experience never hash themselves or grant
    /// authority. This pins content, not a byte-identical provider incarnation.
    func discoveryContractSHA256() throws -> String {
        try withoutDiscoveryAdvice().abiContract().sha256()
    }

    package func withoutDiscoveryAdvice() -> Capability {
        var clean = CapabilityDispatchContract.withoutExperience(self)
        clean.contractSHA256 = nil
        return clean
    }

    /// Read-only snapshot of the existing, engine-owned capability declaration.
    /// The caller must supply schemas produced by a validated substrate compiler.
    /// We do NOT guess input/output types, effects or authority from descriptions.
    /// Nil schemas mean unknown and cannot authorise an invocation.
    func abiContract(arguments: CapabilitySchema? = nil,
                     result: CapabilitySchema? = nil) throws -> CapabilityContract {
        guard reflectorID != "unowned" else { throw CapabilityABIError.invalidIdentity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var additional: [String: CapabilityValue] = [:]
        if let runtimeRequirements { additional["runtimeRequirements"] = .bytes(try encoder.encode(runtimeRequirements)) }
        if let routingOrigin { additional["routingOrigin"] = .bytes(try encoder.encode(routingOrigin)) }
        let contract = CapabilityContract(
            capabilityID: id,
            reflectorID: reflectorID,
            providerID: metadata["providerIdentity"] ?? provider?.bundleIdentifier ?? reflectorID,
            arguments: arguments,
            result: result,
            declaration: .object([
                "title": .string(title),
                "source": .string(source.rawValue),
                "providerName": provider?.name.map { .string($0) } ?? .null,
                "providerBundleID": provider?.bundleIdentifier.map { .string($0) } ?? .null,
                "inputs": .array(inputs.map { .string($0) }),
                "outputs": .array(output.map { .string($0) }),
                "safety": .string(safety.rawValue),
                "invocation": .string(invocation.rawValue),
                "supportLevel": .string(supportLevel.rawValue),
                "requiresConfirmation": .boolean(requiresConfirmation),
                "metadata": .object(metadata.mapValues { .string($0) })
            ].merging(additional) { _, added in added })
        )
        _ = try contract.canonicalData()
        return contract
    }
}
