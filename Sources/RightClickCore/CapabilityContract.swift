import CryptoKit
import Foundation

/// A content-addressed contract pin, not a grant, signature or approval.
/// Passed through the existing actionId field; old runtimes fail unavailable.
public enum CapabilityContract {
    private static let prefix = "reviewed:v1:"

    public static func digest(_ capability: Capability) throws -> String {
        var contract = capability
        contract.reviewedActionId = nil
        let encoded = try JSONEncoder().encode(contract)
        var bytes = Data("RIGHTCLICK-CONTRACT-1\u{0000}".utf8)
        bytes.append(try ContractCanonicalJSON.canonicalize(encoded))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func reviewedID(_ capability: Capability) throws -> String {
        guard !capability.id.isEmpty, capability.id.utf8.count <= 16_384 else {
            throw ContractCanonicalJSON.Failure.tooLarge
        }
        return prefix + (try digest(capability)) + ":" + base64URL(Data(capability.id.utf8))
    }

    static func explained(_ capability: Capability) -> Capability {
        var result = capability
        // Oversized/unsupported contracts are still describable and usable by
        // ordinary ID. No fingerprint is invented when exact encoding fails.
        result.reviewedActionId = try? reviewedID(capability)
        return result
    }

    static func select(id: String, from capabilities: [Capability]) -> Capability? {
        guard id.hasPrefix("reviewed:") else {
            return capabilities.first { $0.id == id || $0.title == id }
        }
        // Reserved reviewed IDs never fall back to provider names or titles.
        guard id.utf8.count <= 22_000 else { return nil }
        let fields = id.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "reviewed", fields[1] == "v1",
              fields[2].utf8.count == 64,
              fields[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        let encodedID = String(fields[3])
        let standard = encodedID.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        guard let rawID = Data(base64Encoded: padded), !rawID.isEmpty,
              rawID.count <= 16_384, String(data: rawID, encoding: .utf8) != nil,
              base64URL(rawID) == encodedID else { return nil }
        let matches = capabilities.filter { Data($0.id.utf8) == rawID }
        guard let match = matches.first,
              matches.allSatisfy({ (try? digest($0)) == String(fields[2]) }) else { return nil }
        return match
    }

    private static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
