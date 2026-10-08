import RightClickProtocol
import Foundation

#if canImport(CryptoKit) || canImport(Crypto)
/// A host-provisioned signer retains immutable protected bytes, but retention is
/// not ongoing authority. Current host reference and protected source bytes are
/// checked at admission and on both sides of each signature operation.
/// This is local live-reference revalidation, not distributed revocation.
/// Optional host policy adds current issuer/key lifecycle authorization;
/// independent receipt acceptance still requires separately provisioned trust.
final class RCIRProvisionedSigner: RCIRReceiptSigning {
    private let snapshot: CapabilityArtifactSnapshot
    private let signer: RCIREd25519Signer
    private let reference: String
    private let currentReference: () -> String?
    private let receiptTrust: RCIRProvisionedReceiptTrust?
    private let receiptAuthorization: RCIRReceiptSigningAuthorization?
    private let currentReceiptTrust: () -> Bool

    init(path: String, currentReference: @escaping () -> String?,
         receiptTrust: RCIRProvisionedReceiptTrust? = nil,
         currentReceiptTrust: @escaping () -> Bool = { true }) throws {
        do {
            snapshot = try CapabilityArtifactSnapshot(source: URL(fileURLWithPath: path), maximum: 32, protected: true)
            signer = try RCIREd25519Signer(rawPrivateKey:
                CapabilityArtifactSnapshot.read(source: snapshot.file, maximum: 32, protected: true))
            reference = path
            self.currentReference = currentReference
            self.receiptTrust = receiptTrust
            self.currentReceiptTrust = currentReceiptTrust
            receiptAuthorization = try receiptTrust?.authorization(for: signer.publicKey)
        } catch { throw RCIRError.authorityDenied }
    }
    var publicKey: Data { signer.publicKey }
    func validateCurrentAuthority() throws {
        guard currentReceiptTrust(), let path = currentReference(), path.utf8.elementsEqual(reference.utf8),
              snapshot.sourceStillMatches() else { throw RCIRError.authorityDenied }
        if let receiptAuthorization { try receiptTrust?.revalidate(receiptAuthorization) }
    }
    func sign(_ payload: Data) throws -> Data {
        try validateCurrentAuthority()
        let signature = try signer.sign(payload)
        try validateCurrentAuthority()
        return signature
    }
}
#endif
