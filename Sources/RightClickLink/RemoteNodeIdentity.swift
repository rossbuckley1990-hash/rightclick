import Foundation
import RightClickProtocol

/// Explicit signer injection keeps custody at the execution host. macOS can
/// inject KeychainLinkSigner; Linux operators inject a securely provisioned
/// RCIREd25519Signer. Missing/corrupt custody never creates a replacement key.
public struct RemoteNodeIdentity: RCIRReceiptSigning {
    private let signer: any RCIRReceiptSigning
    public init(signer: any RCIRReceiptSigning) throws {
        guard signer.publicKey.count == 32 else { throw RemoteLinkError.malformed }
        self.signer = signer
    }
    public var publicKey: Data { signer.publicKey }
    public var runtimeID: String { RemoteWire.runtimeID(publicKey) }
    public var deviceID: String { RemoteWire.deviceID(publicKey) }
    public func sign(_ payload: Data) throws -> Data { try signer.sign(payload) }
}
