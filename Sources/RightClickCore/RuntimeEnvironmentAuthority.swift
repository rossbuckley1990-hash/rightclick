import Foundation

/// Operator-supplied bindings refer to environment variables, never expose their
/// values in descriptors. Presence opts into this resolver instead of Keychain.
public enum RuntimeEnvironmentAuthority {
    public static let environmentKey = "RIGHTCLICK_AUTHORITY_BINDINGS"
    public static func token(origin: String, schemeName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
        guard let raw = environment[environmentKey] else { return nil }
        guard raw.utf8.count <= 65_536, let data = raw.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 64 else { throw OpenAPIAuthorityStoreError.invalidCredential }
        let expectedOrigin = try OpenAPIAuthorityStore.canonicalBearerOrigin(origin)
        let expectedScheme = try OpenAPIAuthorityStore.canonicalBearerSchemeName(schemeName)
        var identities = Set<Data>()
        var selected: String?
        for row in rows {
            guard Set(row.keys) == Set(["origin", "schemeName", "tokenEnvironment"]),
                  let rawOrigin = row["origin"] as? String,
                  let rawScheme = row["schemeName"] as? String,
                  let name = row["tokenEnvironment"] as? String,
                  name.utf8.count <= 128,
                  name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                throw OpenAPIAuthorityStoreError.invalidCredential
            }
            let boundOrigin = try OpenAPIAuthorityStore.canonicalBearerOrigin(rawOrigin)
            let boundScheme = try OpenAPIAuthorityStore.canonicalBearerSchemeName(rawScheme)
            let identity = try CapabilityValue.array([.string(boundOrigin), .string(boundScheme)]).canonicalData()
            guard identities.insert(identity).inserted else { throw OpenAPIAuthorityStoreError.invalidCredential }
            if boundOrigin.utf8.elementsEqual(expectedOrigin.utf8) && boundScheme.utf8.elementsEqual(expectedScheme.utf8) {
                selected = name
            }
        }
        guard let selected, let token = environment[selected] else { return nil }
        guard !token.isEmpty, token.utf8.count <= 1_048_576,
              token.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw OpenAPIAuthorityStoreError.invalidCredential
        }
        return token
    }
}

