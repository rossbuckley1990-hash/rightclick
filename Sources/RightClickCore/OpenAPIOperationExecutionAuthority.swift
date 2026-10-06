import CryptoKit
import Foundation

public struct OpenAPIOperationExecutionSecurityScheme:
    Sendable,
    Equatable
{
    public let name: String
    public let kind: String
    public let credentialHeaderName: String
    public let credentialPrefix: String

    fileprivate init(
        name: String,
        kind: String,
        credentialHeaderName: String,
        credentialPrefix: String
    ) {
        self.name = name
        self.kind = kind
        self.credentialHeaderName =
            credentialHeaderName
        self.credentialPrefix =
            credentialPrefix
    }

    fileprivate var canonicalObject:
        [String: String]
    {
        [
            "name":
                name,
            "kind":
                kind,
            "credentialHeaderName":
                credentialHeaderName,
            "credentialPrefix":
                credentialPrefix,
        ]
    }
}

public struct OpenAPIOperationExecutionSecurityAlternative:
    Sendable,
    Equatable
{
    public let schemes:
        [OpenAPIOperationExecutionSecurityScheme]

    public let fingerprintSHA256:
        String

    fileprivate init(
        schemes:
            [OpenAPIOperationExecutionSecurityScheme]
    ) {
        let ordered =
            schemes.sorted {
                if $0.name == $1.name {
                    return $0.kind < $1.kind
                }

                return $0.name < $1.name
            }

        self.schemes =
            ordered

        let object =
            ordered.map(
                \.canonicalObject
            )

        let data =
            try! JSONSerialization.data(
                withJSONObject:
                    object,
                options: [
                    .sortedKeys
                ]
            )

        fingerprintSHA256 =
            Self.sha256Hex(
                data
            )
    }

    public var credentialHeaderNames:
        [String]
    {
        schemes.map(
            \.credentialHeaderName
        )
    }

    static func derive(
        operation:
            [String: Any],
        root:
            [String: Any]
    ) -> [
        OpenAPIOperationExecutionSecurityAlternative
    ] {
        OpenAPIOperationExecutionSecurityReader
            .alternatives(
                operation:
                    operation,
                root:
                    root
            )
    }

    private static func sha256Hex(
        _ data: Data
    ) -> String {
        SHA256.hash(
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

public struct OpenAPIOperationExecutionAuthorityRequest {
    public let providerOrigin:
        String

    public let operationID:
        String

    public let method:
        String

    public let url:
        URL

    public let securityAlternatives:
        [
            OpenAPIOperationExecutionSecurityAlternative
        ]

    init(
        providerOrigin: String,
        operationID: String,
        method: String,
        url: URL,
        securityAlternatives:
            [
                OpenAPIOperationExecutionSecurityAlternative
            ]
    ) {
        self.providerOrigin =
            providerOrigin

        self.operationID =
            operationID

        self.method =
            method

        self.url =
            url

        self.securityAlternatives =
            securityAlternatives
    }
}

public struct OpenAPIOperationUnsignedRequestDescriptor:
    Sendable
{
    public let method:
        String

    public let url:
        URL

    public let headers:
        [String: String]

    public let bodySHA256:
        String

    public let requestFingerprintSHA256:
        String

    fileprivate init(
        method: String,
        url: URL,
        headers: [String: String],
        bodySHA256: String,
        requestFingerprintSHA256:
            String
    ) {
        self.method =
            method

        self.url =
            url

        self.headers =
            headers

        self.bodySHA256 =
            bodySHA256

        self.requestFingerprintSHA256 =
            requestFingerprintSHA256
    }
}

public struct OpenAPIOperationExecutionAuthority:
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let providerOrigin:
        String

    public let operationID:
        String

    public let securityAlternativeFingerprintSHA256:
        String

    public let authorityFingerprintSHA256:
        String

    private let materializer:
        (
            OpenAPIOperationUnsignedRequestDescriptor
        ) throws -> [String: String]

    public init(
        providerOrigin: String,
        operationID: String,
        securityAlternative:
            OpenAPIOperationExecutionSecurityAlternative,
        authorityFingerprintSHA256:
            String,
        materializer:
            @escaping (
                OpenAPIOperationUnsignedRequestDescriptor
            ) throws -> [String: String]
    ) {
        self.providerOrigin =
            providerOrigin

        self.operationID =
            operationID

        self.securityAlternativeFingerprintSHA256 =
            securityAlternative
                .fingerprintSHA256

        self.authorityFingerprintSHA256 =
            authorityFingerprintSHA256

        self.materializer =
            materializer
    }

    public var description:
        String
    {
        "OpenAPIOperationExecutionAuthority("
            + "providerOrigin: "
            + providerOrigin
            + ", operationID: "
            + operationID
            + ", securityAlternativeFingerprintSHA256: "
            + securityAlternativeFingerprintSHA256
            + ", authorityFingerprintSHA256: "
            + authorityFingerprintSHA256
            + ", privateMaterial: <redacted>)"
    }

    public var debugDescription:
        String
    {
        description
    }

    func materializeCredentialHeaders(
        for descriptor:
            OpenAPIOperationUnsignedRequestDescriptor
    ) throws -> [String: String] {
        try materializer(
            descriptor
        )
    }
}

public typealias OpenAPIOperationExecutionAuthorityResolver =
    (
        OpenAPIOperationExecutionAuthorityRequest
    ) throws -> OpenAPIOperationExecutionAuthority?

private enum OpenAPIOperationExecutionSecurityReader {
    static func alternatives(
        operation:
            [String: Any],
        root:
            [String: Any]
    ) -> [
        OpenAPIOperationExecutionSecurityAlternative
    ] {
        let rawSecurity:
            Any

        if operation.keys.contains(
            "security"
        ) {
            guard
                let value =
                    operation[
                        "security"
                    ]
            else {
                return []
            }

            rawSecurity =
                value
        } else if root.keys.contains(
            "security"
        ) {
            guard
                let value =
                    root[
                        "security"
                    ]
            else {
                return []
            }

            rawSecurity =
                value
        } else {
            return []
        }

        guard
            let requirements =
                rawSecurity
                    as? [Any],
            !requirements.isEmpty,
            let components =
                root[
                    "components"
                ] as? [String: Any],
            let securitySchemes =
                components[
                    "securitySchemes"
                ] as? [String: Any]
        else {
            return []
        }

        var result:
            [
                OpenAPIOperationExecutionSecurityAlternative
            ] = []

        var seen =
            Set<String>()

        for rawRequirement
            in requirements
        {
            guard
                let requirement =
                    rawRequirement
                        as? [String: Any],
                !requirement.isEmpty
            else {
                continue
            }

            var schemes:
                [
                    OpenAPIOperationExecutionSecurityScheme
                ] = []

            var supported =
                true

            for name
                in requirement
                    .keys
                    .sorted()
            {
                guard
                    let rawScheme =
                        securitySchemes[
                            name
                        ],
                    let scheme =
                        resolveObject(
                            rawScheme,
                            root:
                                root
                        ),
                    let normalized =
                        normalizedScheme(
                            name:
                                name,
                            definition:
                                scheme
                        )
                else {
                    supported =
                        false

                    break
                }

                schemes.append(
                    normalized
                )
            }

            guard
                supported,
                schemes.count
                    == requirement.count
            else {
                continue
            }

            let headerIdentities =
                schemes.map {
                    $0
                        .credentialHeaderName
                        .lowercased()
                }

            guard
                Set(
                    headerIdentities
                ).count
                    == headerIdentities.count
            else {
                continue
            }

            let alternative =
                OpenAPIOperationExecutionSecurityAlternative(
                    schemes:
                        schemes
                )

            if seen.insert(
                alternative
                    .fingerprintSHA256
            ).inserted {
                result.append(
                    alternative
                )
            }
        }

        return result.sorted {
            $0.fingerprintSHA256
                < $1.fingerprintSHA256
        }
    }

    private static func normalizedScheme(
        name:
            String,
        definition:
            [String: Any]
    ) -> OpenAPIOperationExecutionSecurityScheme? {
        let rawType =
            (
                definition[
                    "type"
                ] as? String
            )?
            .lowercased()

        if
            rawType == "http",
            (
                definition[
                    "scheme"
                ] as? String
            )?
            .lowercased()
                == "bearer"
        {
            return
                OpenAPIOperationExecutionSecurityScheme(
                    name:
                        name,
                    kind:
                        "http:bearer",
                    credentialHeaderName:
                        "Authorization",
                    credentialPrefix:
                        "Bearer "
                )
        }

        if
            rawType == "apikey",
            (
                definition[
                    "in"
                ] as? String
            )?
            .lowercased()
                == "header",
            let header =
                definition[
                    "name"
                ] as? String,
            validHeaderName(
                header
            )
        {
            return
                OpenAPIOperationExecutionSecurityScheme(
                    name:
                        name,
                    kind:
                        "apiKey:header",
                    credentialHeaderName:
                        header,
                    credentialPrefix:
                        ""
                )
        }

        return nil
    }

    private static func validHeaderName(
        _ value:
            String
    ) -> Bool {
        guard
            !value.isEmpty,
            !value.contains(
                "\r"
            ),
            !value.contains(
                "\n"
            )
        else {
            return false
        }

        return true
    }

    private static func resolveObject(
        _ raw:
            Any,
        root:
            [String: Any],
        seen:
            Set<String> = []
    ) -> [String: Any]? {
        guard
            let object =
                raw
                    as? [String: Any]
        else {
            return nil
        }

        guard
            let reference =
                object[
                    "$ref"
                ] as? String
        else {
            return object
        }

        guard
            reference.hasPrefix(
                "#/"
            ),
            !seen.contains(
                reference
            ),
            let resolved =
                resolvePointer(
                    reference,
                    root:
                        root
                ) as? [String: Any]
        else {
            return nil
        }

        var merged =
            resolved

        for (
            key,
            value
        ) in object
        where key != "$ref"
        {
            merged[
                key
            ] =
                value
        }

        var nextSeen =
            seen

        nextSeen.insert(
            reference
        )

        return resolveObject(
            merged,
            root:
                root,
            seen:
                nextSeen
        )
    }

    private static func resolvePointer(
        _ reference:
            String,
        root:
            [String: Any]
    ) -> Any? {
        guard
            reference.hasPrefix(
                "#/"
            )
        else {
            return nil
        }

        var current:
            Any =
                root

        for rawPart
            in reference
                .dropFirst(
                    2
                )
                .split(
                    separator:
                        "/",
                    omittingEmptySubsequences:
                        false
                )
        {
            let part =
                String(
                    rawPart
                )
                .replacingOccurrences(
                    of:
                        "~1",
                    with:
                        "/"
                )
                .replacingOccurrences(
                    of:
                        "~0",
                    with:
                        "~"
                )

            guard
                let object =
                    current
                        as? [String: Any],
                let next =
                    object[
                        part
                    ]
            else {
                return nil
            }

            current =
                next
        }

        return current
    }
}

func openAPICanonicalExecutionOrigin(
    _ url:
        URL
) -> String? {
    guard
        var components =
            URLComponents(
                url:
                    url,
                resolvingAgainstBaseURL:
                    false
            ),
        let rawScheme =
            components
                .scheme,
        let rawHost =
            components
                .host
    else {
        return nil
    }

    let scheme =
        rawScheme
            .lowercased()

    guard
        scheme == "http"
            || scheme == "https"
    else {
        return nil
    }

    components.scheme =
        scheme

    components.host =
        rawHost
            .lowercased()

    components.user =
        nil

    components.password =
        nil

    components.path =
        ""

    components.query =
        nil

    components.fragment =
        nil

    if
        (
            scheme == "http"
            && components.port
                == 80
        )
        || (
            scheme == "https"
            && components.port
                == 443
        )
    {
        components.port =
            nil
    }

    guard
        let result =
            components
                .url
    else {
        return nil
    }

    var value =
        result
            .absoluteString

    while
        value.count > 1,
        value.hasSuffix(
            "/"
        )
    {
        value.removeLast()
    }

    return value
}

func openAPIOperationUnsignedDescriptor(
    request:
        URLRequest
) -> OpenAPIOperationUnsignedRequestDescriptor {
    let body =
        request
            .httpBody
        ?? Data()

    let bodySHA =
        openAPIOperationSHA256Hex(
            body
        )

    let headers =
        request
            .allHTTPHeaderFields
        ?? [:]

    let normalizedHeaders =
        headers
            .map {
                (
                    $0.key
                        .lowercased(),
                    $0.value
                )
            }
            .sorted {
                if $0.0
                    == $1.0
                {
                    return
                        $0.1
                        < $1.1
                }

                return
                    $0.0
                    < $1.0
            }
            .map {
                $0.0
                    + ":"
                    + $0.1
            }
            .joined(
                separator:
                    "\n"
            )

    let canonical =
        (
            request
                .httpMethod
            ?? ""
        )
        .uppercased()
        + "\n"
        + request
            .url!
            .absoluteString
        + "\n"
        + normalizedHeaders
        + "\n"
        + bodySHA

    return
        OpenAPIOperationUnsignedRequestDescriptor(
            method:
                (
                    request
                        .httpMethod
                    ?? ""
                )
                .uppercased(),
            url:
                request.url!,
            headers:
                headers,
            bodySHA256:
                bodySHA,
            requestFingerprintSHA256:
                openAPIOperationSHA256Hex(
                    Data(
                        canonical.utf8
                    )
                )
        )
}

func normalizeOpenAPIOperationCredentialHeaders(
    _ raw:
        [String: String]
) -> [String: String]? {
    var result:
        [String: String] = [:]

    for (
        name,
        value
    ) in raw
    {
        let identity =
            name
                .lowercased()

        guard
            !name.isEmpty,
            !identity.isEmpty,
            result[
                identity
            ] == nil,
            !name.contains(
                "\r"
            ),
            !name.contains(
                "\n"
            ),
            !value.contains(
                "\r"
            ),
            !value.contains(
                "\n"
            )
        else {
            return nil
        }

        result[
            identity
        ] =
            value
    }

    return result
}

private func openAPIOperationSHA256Hex(
    _ data:
        Data
) -> String {
    SHA256.hash(
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
