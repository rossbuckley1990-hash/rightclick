import Foundation
import RightClickProtocol
import Security

extension MacOSHost {
    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func secretErrorDescription(_ status: Int32) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? ("macOS Keychain error: " + String(status))
    }
    public func readSecret(service: String, account: String) throws -> Data? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw PlatformSecretError.store(status) }
        return data
    }
    public func containsSecret(service: String, account: String) throws -> Bool {
        var request = query(service: service, account: account)
        request[kSecReturnAttributes as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw PlatformSecretError.store(status) }
        return true
    }
    public func writeSecret(_ data: Data, service: String, account: String) throws {
        let request = query(service: service, account: account)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PlatformSecretError.store(status) }
        var add = request; add[kSecValueData as String] = data
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw PlatformSecretError.store(added) }
    }
    public func deleteSecret(service: String, account: String) throws -> Bool {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw PlatformSecretError.store(status) }
        return true
    }
}
