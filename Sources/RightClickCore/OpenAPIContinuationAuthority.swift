import CryptoKit
import Foundation

/// Opaque authority learned from a provider response.
///
/// The bearer secret is deliberately private. Capability metadata,
/// descriptions and debug descriptions expose only provenance and
/// cryptographic fingerprints.
struct OpenAPIProviderContinuationAuthority:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let schemeName: String
    let targetOperationID: String
    let providerOrigin: String
    let sourceResponseSHA256: String
    let credentialFingerprintSHA256: String

    private let bearerToken: String

    fileprivate init(
        schemeName: String,
        targetOperationID: String,
        providerOrigin: String,
        sourceResponseSHA256: String,
        credentialFingerprintSHA256: String,
        bearerToken: String
    ) {
        self.schemeName =
            schemeName

        self.targetOperationID =
            targetOperationID

        self.providerOrigin =
            providerOrigin

        self.sourceResponseSHA256 =
            sourceResponseSHA256

        self.credentialFingerprintSHA256 =
            credentialFingerprintSHA256

        self.bearerToken =
            bearerToken
    }

    var description: String {
        "OpenAPIProviderContinuationAuthority("
        + "schemeName: \(schemeName), "
        + "targetOperationID: \(targetOperationID), "
        + "providerOrigin: \(providerOrigin), "
        + "sourceResponseSHA256: \(sourceResponseSHA256), "
        + "credentialFingerprintSHA256: \(credentialFingerprintSHA256), "
        + "credential: <redacted>)"
    }

    var debugDescription: String {
        description
    }

    func withBearerToken<Result>(
        _ operation: (String) throws -> Result
    ) rethrows -> Result {
        try operation(
            bearerToken
        )
    }
}

/// GREEN-007B1 deliberately accepts no caller-supplied bearer token
/// and no caller-supplied Authorization header.
///
/// The credential must be derived from a provider response in which:
///
/// 1. the response contains a Bearer Authorization recipe;
/// 2. the exact bearer token also appears as another provider-returned
///    response value;
/// 3. the target OpenAPI operation requires exactly one unambiguous
///    HTTP Bearer security scheme.
///
/// This gate does not apply the credential to an HTTP request.
enum OpenAPIProviderContinuationAuthorityBinder {
    static func bind(
        specificationData: Data,
        providerResponseData: Data,
        targetOperationID: String,
        providerBaseURL: URL
    ) -> OpenAPIProviderContinuationAuthority? {
        guard
            let specification =
                try? JSONSerialization
                    .jsonObject(
                        with:
                            specificationData
                    )
                    as? [String: Any],

            let response =
                try? JSONSerialization
                    .jsonObject(
                        with:
                            providerResponseData
                    ),

            let operation =
                operation(
                    operationID:
                        targetOperationID,
                    root:
                        specification
                ),

            let schemeName =
                uniqueRequiredBearerScheme(
                    operation:
                        operation,
                    root:
                        specification
                ),

            securitySchemeIsHTTPBearer(
                schemeName,
                root:
                    specification
            ),

            let bearerToken =
                uniqueProviderIssuedBearerToken(
                    response
                ),

            let providerOrigin =
                canonicalOrigin(
                    providerBaseURL
                )
        else {
            return nil
        }

        let sourceResponseSHA256 =
            sha256Hex(
                providerResponseData
            )

        let credentialFingerprintSHA256 =
            sha256Hex(
                Data(
                    bearerToken.utf8
                )
            )

        return OpenAPIProviderContinuationAuthority(
            schemeName:
                schemeName,
            targetOperationID:
                targetOperationID,
            providerOrigin:
                providerOrigin,
            sourceResponseSHA256:
                sourceResponseSHA256,
            credentialFingerprintSHA256:
                credentialFingerprintSHA256,
            bearerToken:
                bearerToken
        )
    }

    private static func operation(
        operationID: String,
        root: [String: Any]
    ) -> [String: Any]? {
        guard
            let paths =
                root["paths"]
                    as? [String: Any]
        else {
            return nil
        }

        let methods:
            Set<String> = [
                "get",
                "post",
                "put",
                "patch",
                "delete",
            ]

        var match:
            [String: Any]?

        for rawPathObject
            in paths.values
        {
            guard
                let pathObject =
                    rawPathObject
                        as? [String: Any]
            else {
                continue
            }

            for (
                method,
                rawOperation
            ) in pathObject {
                guard
                    methods.contains(
                        method.lowercased()
                    ),

                    let candidate =
                        rawOperation
                            as? [String: Any],

                    candidate[
                        "operationId"
                    ] as? String
                        == operationID
                else {
                    continue
                }

                // Duplicate operationId is ambiguous and fails closed.
                if match != nil {
                    return nil
                }

                match =
                    candidate
            }
        }

        return match
    }

    private static func effectiveSecurity(
        operation: [String: Any],
        root: [String: Any]
    ) -> Any? {
        if
            operation.keys
                .contains(
                    "security"
                )
        {
            return operation[
                "security"
            ]
        }

        return root[
            "security"
        ]
    }

    private static func uniqueRequiredBearerScheme(
        operation: [String: Any],
        root: [String: Any]
    ) -> String? {
        guard
            let raw =
                effectiveSecurity(
                    operation:
                        operation,
                    root:
                        root
                ),

            let requirements =
                raw as? [Any],

            !requirements.isEmpty
        else {
            return nil
        }

        var names =
            Set<String>()

        for rawRequirement
            in requirements
        {
            guard
                let requirement =
                    rawRequirement
                        as? [String: Any],

                !requirement.isEmpty,

                requirement.count == 1,

                let name =
                    requirement
                        .keys
                        .first
            else {
                // Anonymous alternative or multi-scheme AND requirement
                // is not an unambiguous single bearer authority.
                return nil
            }

            names.insert(
                name
            )
        }

        guard
            names.count == 1
        else {
            return nil
        }

        return names.first
    }

    private static func securitySchemeIsHTTPBearer(
        _ name: String,
        root: [String: Any]
    ) -> Bool {
        guard
            let schemes =
                (
                    root[
                        "components"
                    ] as? [String: Any]
                )?[
                    "securitySchemes"
                ] as? [String: Any],

            let rawScheme =
                schemes[
                    name
                ] as? [String: Any],

            let scheme =
                resolveSecurityScheme(
                    rawScheme,
                    schemes:
                        schemes
                ),

            scheme[
                "type"
            ] as? String
                == "http",

            (
                scheme[
                    "scheme"
                ] as? String
            )?
                .lowercased()
                == "bearer"
        else {
            return false
        }

        return true
    }

    private static func resolveSecurityScheme(
        _ raw: [String: Any],
        schemes: [String: Any]
    ) -> [String: Any]? {
        guard
            let reference =
                raw[
                    "$ref"
                ] as? String
        else {
            return raw
        }

        let prefix =
            "#/components/securitySchemes/"

        guard
            reference.hasPrefix(
                prefix
            )
        else {
            return nil
        }

        let encodedName =
            String(
                reference
                    .dropFirst(
                        prefix.count
                    )
            )

        let decodedName =
            encodedName
                .replacingOccurrences(
                    of: "~1",
                    with: "/"
                )
                .replacingOccurrences(
                    of: "~0",
                    with: "~"
                )

        return schemes[
            decodedName
        ] as? [String: Any]
    }

    private static func uniqueProviderIssuedBearerToken(
        _ response: Any
    ) -> String? {
        var nonAuthorizationStrings =
            Set<String>()

        var bearerTokens =
            Set<String>()

        func walk(
            _ value: Any,
            parentKey: String?
        ) {
            if
                let string =
                    value as? String
            {
                if
                    parentKey?
                        .caseInsensitiveCompare(
                            "Authorization"
                        )
                        == .orderedSame
                {
                    let prefix =
                        "Bearer "

                    guard
                        string.hasPrefix(
                            prefix
                        )
                    else {
                        return
                    }

                    let token =
                        String(
                            string
                                .dropFirst(
                                    prefix.count
                                )
                        )

                    if !token.isEmpty {
                        bearerTokens.insert(
                            token
                        )
                    }

                    return
                }

                nonAuthorizationStrings.insert(
                    string
                )

                return
            }

            if
                let object =
                    value
                        as? [String: Any]
            {
                for (
                    key,
                    child
                ) in object {
                    walk(
                        child,
                        parentKey:
                            key
                    )
                }

                return
            }

            if
                let array =
                    value as? [Any]
            {
                for child
                    in array
                {
                    walk(
                        child,
                        parentKey:
                            parentKey
                    )
                }
            }
        }

        walk(
            response,
            parentKey:
                nil
        )

        let boundTokens =
            bearerTokens
                .intersection(
                    nonAuthorizationStrings
                )

        guard
            boundTokens.count == 1
        else {
            return nil
        }

        return boundTokens.first
    }

    private static func canonicalOrigin(
        _ url: URL
    ) -> String? {
        guard
            let components =
                URLComponents(
                    url:
                        url,
                    resolvingAgainstBaseURL:
                        false
                ),

            let rawScheme =
                components.scheme,

            let rawHost =
                components.host
        else {
            return nil
        }

        let scheme =
            rawScheme.lowercased()

        guard
            scheme == "http"
            || scheme == "https"
        else {
            return nil
        }

        let host =
            rawHost.lowercased()

        let port =
            components.port

        let includePort =
            port != nil
            && !(
                scheme == "http"
                && port == 80
            )
            && !(
                scheme == "https"
                && port == 443
            )

        if
            includePort,
            let port
        {
            return
                scheme
                + "://"
                + host
                + ":"
                + String(
                    port
                )
        }

        return
            scheme
            + "://"
            + host
    }

    private static func sha256Hex(
        _ data: Data
    ) -> String {
        SHA256
            .hash(
                data:
                    data
            )
            .map {
                String(
                    format:
                        "%02x",
                    $0
                )
            }
            .joined()
    }
}
