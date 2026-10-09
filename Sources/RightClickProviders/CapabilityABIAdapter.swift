import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public extension CapabilityContract {
    /// Content fingerprint only: not a signature, approval token or attestation.
    func sha256() throws -> String {
        SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
    }
}

public extension Capability {
    /// Read-only snapshot of the existing, engine-owned capability declaration.
    /// The caller must supply schemas produced by a validated substrate compiler.
    /// We do NOT guess input/output types, effects or authority from descriptions.
    /// Nil schemas mean unknown and cannot authorise an invocation.
    func abiContract(arguments: CapabilitySchema? = nil,
                     result: CapabilitySchema? = nil) throws -> CapabilityContract {
        guard reflectorID != "unowned" else { throw CapabilityABIError.invalidIdentity }
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
            ])
        )
        _ = try contract.canonicalData()
        return contract
    }
}
