import Foundation

#if canImport(CryptoKit) || canImport(Crypto)
/// A host-provisioned signer retains immutable protected bytes, but retention is
/// not ongoing authority. Current host reference and protected source bytes are
/// checked at admission and on both sides of each signature operation.
/// This is local live-reference revalidation, not distributed key revocation or
/// a trust store. Historical receipts still require a separately trusted pin.
final class RCIRProvisionedSigner: RCIRReceiptSigning {
    private let snapshot: CapabilityArtifactSnapshot
    private let signer: RCIREd25519Signer
    private let reference: String
    private let currentReference: () -> String?

    init(path: String, currentReference: @escaping () -> String?) throws {
        do {
            snapshot = try CapabilityArtifactSnapshot(source: URL(fileURLWithPath: path), maximum: 32, protected: true)
            signer = try RCIREd25519Signer(rawPrivateKey:
                CapabilityArtifactSnapshot.read(source: snapshot.file, maximum: 32, protected: true))
            reference = path
            self.currentReference = currentReference
        } catch { throw RCIRError.authorityDenied }
    }
    var publicKey: Data { signer.publicKey }
    func validateCurrentAuthority() throws {
        guard let path = currentReference(), path.utf8.elementsEqual(reference.utf8),
              snapshot.sourceStillMatches() else { throw RCIRError.authorityDenied }
    }
    func sign(_ payload: Data) throws -> Data {
        try validateCurrentAuthority()
        let signature = try signer.sign(payload)
        try validateCurrentAuthority()
        return signature
    }
}
#endif
