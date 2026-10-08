import RightClickProtocol
import Foundation

enum OpenAPIAuthorityRequirement:
    Equatable
{
    case httpBearer(
        schemeName: String,
        origin: String
    )

    var kind: String {
        switch self {
        case .httpBearer:
            return "http_bearer"
        }
    }

    var schemeName: String {
        switch self {
        case let .httpBearer(
            schemeName,
            _
        ):
            return schemeName
        }
    }

    var origin: String {
        switch self {
        case let .httpBearer(
            _,
            origin
        ):
            return origin
        }
    }

    var keychainAccount: String {
        switch self {
        case let .httpBearer(
            schemeName,
            origin
        ):
            return
                "http-bearer|"
                + origin
                + "|"
                + schemeName
        }
    }
}

public enum OpenAPIAuthorityStoreError:
    Error,
    LocalizedError
{
    case invalidOrigin
    case invalidScheme
    case invalidCredential
    case keychain(Int32)

    public var errorDescription:
        String?
    {
        switch self {
        case .invalidOrigin:
            return
                "Authority origin must be one credential-free HTTPS origin with no path, query, or fragment."

        case .invalidScheme:
            return
                "Authority scheme is empty, too long, or contains unsupported characters."

        case .invalidCredential:
            return
                "Bearer credential is empty, too large, or contains newline/control characters."

        case let .keychain(status):
            return PlatformHostDefaults.host.secretErrorDescription(status)
        }
    }
}

public enum OpenAPIAuthorityStore {
    static let keychainService =
        "ai.rightclick.openapi-authority"

    public static func canonicalBearerOrigin(
        _ raw: String
    ) throws -> String {
        guard
            !raw.isEmpty,
            raw.count <= 2048,
            raw
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                == raw,
            var components =
                URLComponents(
                    string:
                        raw
                ),
            components.scheme?
                .lowercased()
                == "https",
            let host =
                components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty
                || components.path == "/"
        else {
            throw OpenAPIAuthorityStoreError
                .invalidOrigin
        }

        components.scheme =
            "https"

        components.host =
            host.lowercased()

        if components.port == 443 {
            components.port =
                nil
        }

        components.path =
            ""

        guard
            let url =
                components.url
        else {
            throw OpenAPIAuthorityStoreError
                .invalidOrigin
        }

        var value =
            url.absoluteString

        if value.hasSuffix("/") {
            value.removeLast()
        }

        return value
    }

    public static func canonicalBearerSchemeName(
        _ raw: String
    ) throws -> String {
        guard
            !raw.isEmpty,
            raw.count <= 128,
            raw
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                == raw,
            !raw.contains("|"),
            raw
                .rangeOfCharacter(
                    from:
                        .controlCharacters
                )
                == nil
        else {
            throw OpenAPIAuthorityStoreError
                .invalidScheme
        }

        return raw
    }

    public static func setBearerToken(_ token: String, origin rawOrigin: String, schemeName rawSchemeName: String) throws {
        try validateBearerToken(token)
        let requirement = try managedRequirement(origin: rawOrigin, schemeName: rawSchemeName)
        do { try PlatformHostDefaults.host.writeSecret(Data(token.utf8), service: keychainService, account: requirement.keychainAccount) }
        catch PlatformSecretError.store(let status) { throw OpenAPIAuthorityStoreError.keychain(status) }
    }

    public static func containsBearerToken(origin rawOrigin: String, schemeName rawSchemeName: String) throws -> Bool {
        let requirement = try managedRequirement(origin: rawOrigin, schemeName: rawSchemeName)
        do { return try PlatformHostDefaults.host.containsSecret(service: keychainService, account: requirement.keychainAccount) }
        catch PlatformSecretError.store(let status) { throw OpenAPIAuthorityStoreError.keychain(status) }
    }

    @discardableResult
    public static func deleteBearerToken(origin rawOrigin: String, schemeName rawSchemeName: String) throws -> Bool {
        let requirement = try managedRequirement(origin: rawOrigin, schemeName: rawSchemeName)
        do { return try PlatformHostDefaults.host.deleteSecret(service: keychainService, account: requirement.keychainAccount) }
        catch PlatformSecretError.store(let status) { throw OpenAPIAuthorityStoreError.keychain(status) }
    }

    static func bearerToken(for requirement: OpenAPIAuthorityRequirement) -> String? {
        #if !os(macOS)
        // Explicit operator bindings are the only Linux bearer source. Invalid
        // configuration grants no authority and has no ambient secret fallback.
        return try? RuntimeEnvironmentAuthority.token(origin: requirement.origin, schemeName: requirement.schemeName)
        #else
        guard let data = try? PlatformHostDefaults.host.readSecret(service: keychainService, account: requirement.keychainAccount),
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
        #endif
    }

    private static func managedRequirement(
        origin rawOrigin: String,
        schemeName rawSchemeName: String
    ) throws
        -> OpenAPIAuthorityRequirement
    {
        let origin =
            try canonicalBearerOrigin(
                rawOrigin
            )

        let schemeName =
            try canonicalBearerSchemeName(
                rawSchemeName
            )

        return .httpBearer(
            schemeName:
                schemeName,
            origin:
                origin
        )
    }

    private static func validateBearerToken(
        _ token: String
    ) throws {
        guard
            !token.isEmpty,
            token.utf8.count <= 1_048_576,
            token
                .rangeOfCharacter(
                    from:
                        .newlines
                )
                == nil,
            token
                .rangeOfCharacter(
                    from:
                        .controlCharacters
                )
                == nil
        else {
            throw OpenAPIAuthorityStoreError
                .invalidCredential
        }
    }

}
