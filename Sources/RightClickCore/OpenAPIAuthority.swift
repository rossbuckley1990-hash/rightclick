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

enum OpenAPIAuthorityStore {
    static let keychainService =
        "ai.rightclick.openapi-authority"

    static func bearerToken(
        for requirement:
            OpenAPIAuthorityRequirement
    ) -> String? {
        let query:
            [String: Any] = [
                kSecClass as String:
                    kSecClassGenericPassword,

                kSecAttrService as String:
                    keychainService,

                kSecAttrAccount as String:
                    requirement
                        .keychainAccount,

                kSecReturnData as String:
                    true,

                kSecMatchLimit as String:
                    kSecMatchLimitOne,
            ]

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
                    data: data,
                    encoding:
                        .utf8
                ),
            !token.isEmpty
        else {
            return nil
        }

        return token
    }
}
