import Foundation
#if canImport(CryptoKit) || canImport(Crypto)
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#endif

public enum RCIRReceiptError: Error, Equatable {
    case malformedEnvelope, untrustedKey, invalidSignature
}

/// Backend interfaces are host-only. Algorithm agility is deliberately absent:
/// RCIR-001 uses Ed25519 signatures over the exact canonical receipt bytes.
public protocol RCIRReceiptSigning {
    var publicKey: Data { get }
    func sign(_ payload: Data) throws -> Data
}
public protocol RCIRReceiptVerifying {
    func verify(signature: Data, payload: Data, publicKey: Data) throws -> Bool
}

/// The embedded public key is a locator, NOT a trust anchor. Verification requires
/// a separate pinned key from the caller's trusted configuration.
public struct RCIRSignedReceipt: Sendable {
    public static let algorithm = "Ed25519"
    public let payload: Data
    public let signature: Data
    public let publicKey: Data

    public init(payload: Data, signature: Data, publicKey: Data) throws {
        guard payload.starts(with: Data("RIGHTCLICK-RCIR-RECEIPT-1\0".utf8)),
              payload.count > 24, payload.count <= 1_048_576,
              signature.count == 64, publicKey.count == 32 else {
            throw RCIRReceiptError.malformedEnvelope
        }
        self.payload = payload; self.signature = signature; self.publicKey = publicKey
    }
    public static func sign(_ task: RCIRTask, using signer: any RCIRReceiptSigning) throws -> Self {
        let payload = try task.receiptData()
        return try .init(payload: payload, signature: signer.sign(payload), publicKey: signer.publicKey)
    }
    public func verify(trustedPublicKey: Data, using verifier: any RCIRReceiptVerifying) throws {
        guard trustedPublicKey.count == 32, trustedPublicKey == publicKey else { throw RCIRReceiptError.untrustedKey }
        guard try verifier.verify(signature: signature, payload: payload, publicKey: trustedPublicKey)
        else { throw RCIRReceiptError.invalidSignature }
    }
    /// This JSON transports opaque signed bytes. It does not re-canonicalise them.
    public func wireData() throws -> Data {
        let object: [String: Any] = ["version": 1, "algorithm": Self.algorithm,
                                    "payload": payload.base64EncodedString(),
                                    "signature": signature.base64EncodedString(),
                                    "publicKey": publicKey.base64EncodedString()]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// Failure to issue a signature must not erase terminal evidence or manufacture
/// an unknown/cancelled outcome. Shared by unary and retained task completion.
struct RCIRReceiptEmission {
    static let withheldEvent = "RCIR signed receipt withheld because current provisioned signing authority is unavailable."
    let payload: Data
    let signed: RCIRSignedReceipt?
    let signatureWithheld: Bool
    init(task: RCIRTask, signer: (any RCIRReceiptSigning)?) throws {
        payload = try task.receiptData()
        if let signer {
            do { signed = try RCIRSignedReceipt.sign(task, using: signer); signatureWithheld = false }
            catch { signed = nil; signatureWithheld = true }
        } else { signed = nil; signatureWithheld = false }
    }
}

#if canImport(CryptoKit) || canImport(Crypto)
/// Product backend on supported Apple platforms. Key provisioning/rotation is a
/// runtime deployment responsibility; no ephemeral key is installed implicitly.
public struct RCIREd25519Signer: RCIRReceiptSigning {
    private let key: Curve25519.Signing.PrivateKey
    public init(rawPrivateKey: Data) throws { key = try .init(rawRepresentation: rawPrivateKey) }
    public var publicKey: Data { key.publicKey.rawRepresentation }
    public func sign(_ payload: Data) throws -> Data { try key.signature(for: payload) }
}
public struct RCIREd25519Verifier: RCIRReceiptVerifying {
    public init() {}
    public func verify(signature: Data, payload: Data, publicKey: Data) throws -> Bool {
        try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signature, for: payload)
    }
}
#endif
