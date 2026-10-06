import CryptoKit
import Foundation

/// Exact bytes bound to the proof identity already frozen in a
/// provider-derived continuation target.
///
/// The bytes are deliberately private. Public-facing descriptions expose
/// only the cryptographic identity and length.
struct OpenAPIProviderContinuationBody:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let proofSHA256: String
    let proofSize: Int
    let targetFingerprintSHA256: String

    private let bytes: Data

    fileprivate init(
        proofSHA256: String,
        proofSize: Int,
        targetFingerprintSHA256: String,
        bytes: Data
    ) {
        self.proofSHA256 =
            proofSHA256

        self.proofSize =
            proofSize

        self.targetFingerprintSHA256 =
            targetFingerprintSHA256

        self.bytes =
            bytes
    }

    var description: String {
        "OpenAPIProviderContinuationBody("
        + "proofSHA256: \(proofSHA256), "
        + "proofSize: \(proofSize), "
        + "targetFingerprintSHA256: \(targetFingerprintSHA256), "
        + "bytes: <redacted>)"
    }

    var debugDescription: String {
        description
    }

    func withBytes<Result>(
        _ operation: (Data) throws -> Result
    ) rethrows -> Result {
        try operation(
            bytes
        )
    }
}

/// GREEN-007B3 accepts candidate bytes, but the caller cannot define what
/// those bytes are expected to be.
///
/// Expected size and SHA-256 come exclusively from the already
/// provider-bound target.
enum OpenAPIProviderContinuationBodyBinder {
    static func bind(
        target: OpenAPIProviderContinuationTarget,
        candidateData: Data
    ) -> OpenAPIProviderContinuationBody? {
        guard
            target.proofSize > 0,

            candidateData.count
                == target.proofSize
        else {
            return nil
        }

        let candidateSHA256 =
            sha256Hex(
                candidateData
            )

        guard
            candidateSHA256
                == target.proofSHA256
        else {
            return nil
        }

        return OpenAPIProviderContinuationBody(
            proofSHA256:
                candidateSHA256,
            proofSize:
                candidateData.count,
            targetFingerprintSHA256:
                target
                    .concreteTargetFingerprintSHA256,
            bytes:
                candidateData
        )
    }

    private static func sha256Hex(
        _ data: Data
    ) -> String {
        SHA256
            .hash(
                data:
                    data
            )
            .map {
                String(
                    format:
                        "%02x",
                    $0
                )
            }
            .joined()
    }
}
