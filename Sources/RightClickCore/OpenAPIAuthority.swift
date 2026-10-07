import Foundation
import Security

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
            if let message =
                SecCopyErrorMessageString(
                    status,
                    nil
                ) as String?
            {
                return
                    "macOS Keychain error: "
                    + message
            }

            return
                "macOS Keychain error: "
                + String(
                    status
                )
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

    public static func setBearerToken(
        _ token: String,
        origin rawOrigin: String,
        schemeName rawSchemeName: String
    ) throws {
        try validateBearerToken(
            token
        )

        let requirement =
            try managedRequirement(
                origin:
                    rawOrigin,
                schemeName:
                    rawSchemeName
            )

        let data =
            Data(
                token.utf8
            )

        let attributes:
            [String: Any] = [
                kSecValueData as String:
                    data,
            ]

        let query =
            baseQuery(
                for:
                    requirement
            )

        let updateStatus =
            SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )

        if updateStatus == errSecSuccess {
            return
        }

        guard
            updateStatus
                == errSecItemNotFound
        else {
            throw OpenAPIAuthorityStoreError
                .keychain(
                    updateStatus
                )
        }

        var addQuery =
            query

        addQuery[
            kSecValueData as String
        ] =
            data

        let addStatus =
            SecItemAdd(
                addQuery as CFDictionary,
                nil
            )

        guard
            addStatus == errSecSuccess
        else {
            throw OpenAPIAuthorityStoreError
                .keychain(
                    addStatus
                )
        }
    }

    public static func containsBearerToken(
        origin rawOrigin: String,
        schemeName rawSchemeName: String
    ) throws -> Bool {
        let requirement =
            try managedRequirement(
                origin:
                    rawOrigin,
                schemeName:
                    rawSchemeName
            )

        var query =
            baseQuery(
                for:
                    requirement
            )

        query[
            kSecReturnAttributes as String
        ] =
            true

        query[
            kSecMatchLimit as String
        ] =
            kSecMatchLimitOne

        var item:
            CFTypeRef?

        let status =
            SecItemCopyMatching(
                query as CFDictionary,
                &item
            )

        if status == errSecSuccess {
            return true
        }

        if status == errSecItemNotFound {
            return false
        }

        throw OpenAPIAuthorityStoreError
            .keychain(
                status
            )
    }

    @discardableResult
    public static func deleteBearerToken(
        origin rawOrigin: String,
        schemeName rawSchemeName: String
    ) throws -> Bool {
        let requirement =
            try managedRequirement(
                origin:
                    rawOrigin,
                schemeName:
                    rawSchemeName
            )

        let status =
            SecItemDelete(
                baseQuery(
                    for:
                        requirement
                ) as CFDictionary
            )

        if status == errSecSuccess {
            return true
        }

        if status == errSecItemNotFound {
            return false
        }

        throw OpenAPIAuthorityStoreError
            .keychain(
                status
            )
    }

    static func bearerToken(
        for requirement:
            OpenAPIAuthorityRequirement
    ) -> String? {
        var query =
            baseQuery(
                for:
                    requirement
            )

        query[
            kSecReturnData as String
        ] =
            true

        query[
            kSecMatchLimit as String
        ] =
            kSecMatchLimitOne

        var item:
            CFTypeRef?

        let status =
            SecItemCopyMatching(
                query as CFDictionary,
                &item
            )

        guard
            status == errSecSuccess,
            let data =
                item as? Data,
            let token =
                String(
                    data:
                        data,
                    encoding:
                        .utf8
                ),
            !token.isEmpty
        else {
            return nil
        }

        return token
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

    private static func baseQuery(
        for requirement:
            OpenAPIAuthorityRequirement
    ) -> [String: Any] {
        [
            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                keychainService,

            kSecAttrAccount as String:
                requirement
                    .keychainAccount,
        ]
    }
}
