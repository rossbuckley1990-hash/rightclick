import RightClickProtocol
import Foundation

/// Bounded protected material known to this credential-backed boundary. This
/// rejects a contaminated result before retention, verification or signing; it
/// never substitutes redacted bytes and then treats them as observed truth.
/// Exact bytes plus common encodings are covered, not arbitrary obfuscation.
struct CapabilitySensitiveMaterial: Sendable {
    private let representations: [Data]
    init(_ secrets: [Data]) throws {
        guard !secrets.isEmpty, secrets.count <= 64,
              secrets.allSatisfy({ !$0.isEmpty && $0.count <= 8192 }),
              secrets.reduce(0, { $0 + $1.count }) <= 65_536 else { throw RCIRError.authorityDenied }
        var forms = Set<Data>()
        for secret in secrets {
            for material in [secret, Data("Bearer ".utf8) + secret] {
                forms.insert(material)
                let base64 = material.base64EncodedString()
                forms.insert(Data(base64.utf8))
                forms.insert(Data(base64.replacingOccurrences(of: "=", with: "").utf8))
                forms.insert(Data(base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "").utf8))
            }
            let hex = secret.map { String(format: "%02x", $0) }.joined()
            forms.insert(Data(hex.utf8)); forms.insert(Data(hex.uppercased().utf8))
        }
        guard forms.reduce(0, { $0 + $1.count }) <= 1_048_576 else { throw RCIRError.authorityDenied }
        representations = Array(forms)
    }
    func requireAbsent(in value: CapabilityValue) throws {
        // The canonical encoder also bounds nodes, depth and allocation. JSON
        // escapes have already been decoded by the typed acquisition boundary.
        let bytes = try value.canonicalData()
        guard !representations.contains(where: { bytes.range(of: $0) != nil }) else { throw RCIRError.authorityDenied }
    }
}
