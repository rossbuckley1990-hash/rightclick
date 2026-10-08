import CryptoKit
import Foundation
import RightClickProtocol
import Security

/// Explicit provisioning only: normal RIGHTCLICK startup never accesses this
/// identity. A locked/erroring Keychain fails closed rather than replacing a key.
public final class KeychainLinkSigner: RCIRReceiptSigning {
    private let signer: RCIREd25519Signer
    public var publicKey: Data { signer.publicKey }
    public func sign(_ payload: Data) throws -> Data { try signer.sign(payload) }

    public init(account: String = "default-runtime") throws {
        guard !account.isEmpty && account.utf8.count <= 512 && account.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RightClickError("Invalid link identity account.") }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.rightclick.link.identity.v1",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        func load() throws -> Data? {
            var value: CFTypeRef?
            var readQuery = query
            readQuery[kSecReturnData as String] = true
            readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            readQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            let status = SecItemCopyMatching(readQuery as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = value as? Data, data.count == 32
            else { throw RightClickError("Link identity storage is unavailable.") }
            return data
        }
        if let key = try load() {
            signer = try RCIREd25519Signer(rawPrivateKey: key)
            return
        }
        let key = Curve25519.Signing.PrivateKey().rawRepresentation
        var createQuery = query
        createQuery[kSecValueData as String] = key
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(createQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Concurrent provisioning has one durable identity. Reload its winner.
            guard let winner = try load() else { throw RightClickError("Link identity storage is unavailable.") }
            signer = try RCIREd25519Signer(rawPrivateKey: winner)
        } else {
            guard status == errSecSuccess else { throw RightClickError("Link identity storage is unavailable.") }
            signer = try RCIREd25519Signer(rawPrivateKey: key)
        }
    }
}
