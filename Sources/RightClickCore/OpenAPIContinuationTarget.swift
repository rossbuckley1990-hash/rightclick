import CryptoKit
import Foundation

/// A concrete continuation target derived only from provider-returned
/// material and validated against the discovered OpenAPI operation.
///
/// Concrete URL and path identities are intentionally private.
/// This type performs no transport.
struct OpenAPIProviderContinuationTarget:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let operationID: String
    let method: String
    let providerOrigin: String
    let pathTemplate: String

    let requiredPathParameters: [String]

    let sourceResponseSHA256: String
    let concreteTargetFingerprintSHA256: String
    let pathBindingFingerprintSHA256: String

    let proofPath: String
    let proofSHA256: String
    let proofSize: Int

    let providerReturnedContentType: String?
    let declaredRequestMedia: [String]

    let mediaContractMatches: Bool

    private let concreteURL: URL
    private let pathParameters: [String: String]

    fileprivate init(
        operationID: String,
        method: String,
        providerOrigin: String,
        pathTemplate: String,
        requiredPathParameters: [String],
        sourceResponseSHA256: String,
        concreteTargetFingerprintSHA256: String,
        pathBindingFingerprintSHA256: String,
        proofPath: String,
        proofSHA256: String,
        proofSize: Int,
        providerReturnedContentType: String?,
        declaredRequestMedia: [String],
        mediaContractMatches: Bool,
        concreteURL: URL,
        pathParameters: [String: String]
    ) {
        self.operationID =
            operationID

        self.method =
            method

        self.providerOrigin =
            providerOrigin

        self.pathTemplate =
            pathTemplate

        self.requiredPathParameters =
            requiredPathParameters

        self.sourceResponseSHA256 =
            sourceResponseSHA256

        self.concreteTargetFingerprintSHA256 =
            concreteTargetFingerprintSHA256

        self.pathBindingFingerprintSHA256 =
            pathBindingFingerprintSHA256

        self.proofPath =
            proofPath

        self.proofSHA256 =
            proofSHA256

        self.proofSize =
            proofSize

        self.providerReturnedContentType =
            providerReturnedContentType

        self.declaredRequestMedia =
            declaredRequestMedia

        self.mediaContractMatches =
            mediaContractMatches

        self.concreteURL =
            concreteURL

        self.pathParameters =
            pathParameters
    }

    var description: String {
        "OpenAPIProviderContinuationTarget("
        + "operationID: \(operationID), "
        + "method: \(method), "
        + "providerOrigin: \(providerOrigin), "
        + "pathTemplate: \(pathTemplate), "
        + "requiredPathParameters: \(requiredPathParameters), "
        + "sourceResponseSHA256: \(sourceResponseSHA256), "
        + "concreteTargetFingerprintSHA256: \(concreteTargetFingerprintSHA256), "
        + "pathBindingFingerprintSHA256: \(pathBindingFingerprintSHA256), "
        + "proofPath: \(proofPath), "
        + "proofSHA256: \(proofSHA256), "
        + "proofSize: \(proofSize), "
        + "providerReturnedContentType: \(providerReturnedContentType ?? "none"), "
        + "declaredRequestMedia: \(declaredRequestMedia), "
        + "mediaContractMatches: \(mediaContractMatches), "
        + "concreteURL: <redacted>, "
        + "pathIdentities: <redacted>)"
    }

    var debugDescription: String {
        description
    }

    func withConcreteURL<Result>(
        _ operation: (URL) throws -> Result
    ) rethrows -> Result {
        try operation(
            concreteURL
        )
    }
}

/// GREEN-007B2 derives a concrete continuation target from:
///
/// - the discovered OpenAPI contract;
/// - the already-bound provider-issued authority;
/// - the exact provider response that created that authority;
/// - a previously frozen proof identity.
///
/// It accepts no sessionId, fileId, HTTP method, concrete URL or
/// path-argument dictionary from the caller.
///
/// This binder creates no URLRequest and performs no transport.
enum OpenAPIProviderContinuationTargetBinder {
    static func bind(
        specificationData: Data,
        providerResponseData: Data,
        authority: OpenAPIProviderContinuationAuthority,
        providerBaseURL: URL,
        proofPath: String,
        proofSHA256: String,
        proofSize: Int
    ) -> OpenAPIProviderContinuationTarget? {
        guard
            proofSize >= 0,

            !proofPath.isEmpty,

            !proofSHA256.isEmpty,

            let root =
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

            sha256Hex(
                providerResponseData
            )
                == authority
                    .sourceResponseSHA256,

            let canonicalOrigin =
                canonicalOrigin(
                    providerBaseURL
                ),

            canonicalOrigin
                == authority
                    .providerOrigin,

            let operationBinding =
                operation(
                    operationID:
                        authority
                            .targetOperationID,
                    root:
                        root
                ),

            let recipe =
                uniqueRecipe(
                    in:
                        response,
                    proofPath:
                        proofPath,
                    proofSHA256:
                        proofSHA256,
                    proofSize:
                        proofSize
                ),

            let rawURL =
                recipe[
                    "url"
                ] as? String,

            let concreteURL =
                URL(
                    string:
                        rawURL
                ),

            let rawMethod =
                recipe[
                    "method"
                ] as? String,

            rawMethod
                .uppercased()
                == operationBinding
                    .method,

            sameOrigin(
                concreteURL,
                providerBaseURL
            ),

            concreteURL
                .query == nil,

            concreteURL
                .fragment == nil,

            let parameterContract =
                pathParameterContract(
                    pathObject:
                        operationBinding
                            .pathObject,
                    operation:
                        operationBinding
                            .operation,
                    root:
                        root
                ),

            Set(
                parameterContract
            )
                == Set(
                    pathTemplateParameters(
                        operationBinding
                            .pathTemplate
                    )
                ),

            let extracted =
                matchConcretePath(
                    concreteURL:
                        concreteURL,
                    pathTemplate:
                        operationBinding
                            .pathTemplate
                ),

            Set(
                extracted.keys
            )
                == Set(
                    parameterContract
                ),

            !extracted.values
                .contains(
                    where:
                        \.isEmpty
                )
        else {
            return nil
        }

        let declaredRequestMedia =
            requestMedia(
                operationBinding
                    .operation,
                root:
                    root
            )

        let providerReturnedContentType =
            headerValue(
                "Content-Type",
                in:
                    recipe[
                        "headers"
                    ]
            )

        let mediaContractMatches =
            providerReturnedContentType
                .map {
                    declaredRequestMedia
                        .contains(
                            $0
                        )
                }
                ?? false

        let concreteTargetFingerprintSHA256 =
            sha256Hex(
                Data(
                    concreteURL
                        .absoluteString
                        .utf8
                )
            )

        let pathBindingMaterial =
            parameterContract
                .sorted()
                .compactMap {
                    name
                        -> String? in

                    guard
                        let value =
                            extracted[
                                name
                            ]
                    else {
                        return nil
                    }

                    return
                        name
                        + "="
                        + value
                }
                .joined(
                    separator:
                        "\n"
                )

        let pathBindingFingerprintSHA256 =
            sha256Hex(
                Data(
                    pathBindingMaterial
                        .utf8
                )
            )

        return OpenAPIProviderContinuationTarget(
            operationID:
                authority
                    .targetOperationID,
            method:
                operationBinding
                    .method,
            providerOrigin:
                canonicalOrigin,
            pathTemplate:
                operationBinding
                    .pathTemplate,
            requiredPathParameters:
                parameterContract
                    .sorted(),
            sourceResponseSHA256:
                authority
                    .sourceResponseSHA256,
            concreteTargetFingerprintSHA256:
                concreteTargetFingerprintSHA256,
            pathBindingFingerprintSHA256:
                pathBindingFingerprintSHA256,
            proofPath:
                proofPath,
            proofSHA256:
                proofSHA256,
            proofSize:
                proofSize,
            providerReturnedContentType:
                providerReturnedContentType,
            declaredRequestMedia:
                declaredRequestMedia,
            mediaContractMatches:
                mediaContractMatches,
            concreteURL:
                concreteURL,
            pathParameters:
                extracted
        )
    }

    private struct OperationBinding {
        let pathTemplate: String
        let method: String
        let pathObject: [String: Any]
        let operation: [String: Any]
    }

    private static func operation(
        operationID: String,
        root: [String: Any]
    ) -> OperationBinding? {
        guard
            let paths =
                root[
                    "paths"
                ] as? [String: Any]
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
            OperationBinding?

        for pathTemplate
            in paths.keys.sorted()
        {
            guard
                let pathObject =
                    paths[
                        pathTemplate
                    ] as? [String: Any]
            else {
                continue
            }

            for (
                rawMethod,
                rawOperation
            ) in pathObject {
                let method =
                    rawMethod
                        .lowercased()

                guard
                    methods
                        .contains(
                            method
                        ),

                    let operation =
                        rawOperation
                            as? [String: Any],

                    operation[
                        "operationId"
                    ] as? String
                        == operationID
                else {
                    continue
                }

                if match != nil {
                    return nil
                }

                match =
                    OperationBinding(
                        pathTemplate:
                            pathTemplate,
                        method:
                            method
                                .uppercased(),
                        pathObject:
                            pathObject,
                        operation:
                            operation
                    )
            }
        }

        return match
    }

    private static func uniqueRecipe(
        in value: Any,
        proofPath: String,
        proofSHA256: String,
        proofSize: Int
    ) -> [String: Any]? {
        var matches:
            [[String: Any]] = []

        func walk(
            _ value: Any
        ) {
            if
                let object =
                    value
                        as? [String: Any]
            {
                if
                    object[
                        "path"
                    ] as? String
                        == proofPath,

                    object[
                        "hash"
                    ] as? String
                        == proofSHA256,

                    integerValue(
                        object[
                            "size"
                        ]
                    )
                        == proofSize,

                    object[
                        "method"
                    ] is String,

                    object[
                        "url"
                    ] is String
                {
                    matches.append(
                        object
                    )
                }

                for child
                    in object.values
                {
                    walk(
                        child
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
                        child
                    )
                }
            }
        }

        walk(
            value
        )

        guard
            matches.count == 1
        else {
            return nil
        }

        return matches[0]
    }

    private static func integerValue(
        _ raw: Any?
    ) -> Int? {
        if
            let value =
                raw as? Int
        {
            return value
        }

        guard
            let number =
                raw as? NSNumber,
            floor(
                number.doubleValue
            )
                == number.doubleValue,
            number.doubleValue
                >= Double(
                    Int.min
                ),
            number.doubleValue
                <= Double(
                    Int.max
                )
        else {
            return nil
        }

        return number.intValue
    }

    private static func pathParameterContract(
        pathObject: [String: Any],
        operation: [String: Any],
        root: [String: Any]
    ) -> [String]? {
        var merged:
            [String: [String: Any]] = [:]

        func absorb(
            _ raw: Any?
        ) -> Bool {
            guard
                let raw
            else {
                return true
            }

            guard
                let rows =
                    raw as? [Any]
            else {
                return false
            }

            for row in rows {
                guard
                    let rawObject =
                        row as? [String: Any],

                    let parameter =
                        resolveLocalObject(
                            rawObject,
                            root:
                                root
                        ),

                    let name =
                        parameter[
                            "name"
                        ] as? String,

                    let location =
                        parameter[
                            "in"
                        ] as? String
                else {
                    return false
                }

                let key =
                    location
                        .lowercased()
                    + "\n"
                    + name
                        .lowercased()

                merged[
                    key
                ] =
                    parameter
            }

            return true
        }

        guard
            absorb(
                pathObject[
                    "parameters"
                ]
            ),
            absorb(
                operation[
                    "parameters"
                ]
            )
        else {
            return nil
        }

        var requiredPathNames:
            [String] = []

        for parameter
            in merged.values
        {
            guard
                let location =
                    parameter[
                        "in"
                    ] as? String,

                let name =
                    parameter[
                        "name"
                    ] as? String
            else {
                return nil
            }

            guard
                location
                    .lowercased()
                    == "path"
            else {
                continue
            }

            guard
                parameter[
                    "required"
                ] as? Bool
                    == true
            else {
                return nil
            }

            requiredPathNames.append(
                name
            )
        }

        return
            Array(
                Set(
                    requiredPathNames
                )
            )
    }

    private static func matchConcretePath(
        concreteURL: URL,
        pathTemplate: String
    ) -> [String: String]? {
        guard
            let components =
                URLComponents(
                    url:
                        concreteURL,
                    resolvingAgainstBaseURL:
                        false
                )
        else {
            return nil
        }

        let concreteSegments =
            components
                .percentEncodedPath
                .split(
                    separator:
                        "/",
                    omittingEmptySubsequences:
                        false
                )
                .map(
                    String.init
                )

        let templateSegments =
            pathTemplate
                .split(
                    separator:
                        "/",
                    omittingEmptySubsequences:
                        false
                )
                .map(
                    String.init
                )

        guard
            concreteSegments.count
                == templateSegments.count
        else {
            return nil
        }

        var values:
            [String: String] = [:]

        for (
            template,
            concrete
        ) in zip(
            templateSegments,
            concreteSegments
        ) {
            if
                template.hasPrefix(
                    "{"
                ),
                template.hasSuffix(
                    "}"
                ),
                template.count > 2
            {
                let name =
                    String(
                        template
                            .dropFirst()
                            .dropLast()
                    )

                guard
                    !name.isEmpty,

                    values[
                        name
                    ] == nil,

                    let decoded =
                        concrete
                            .removingPercentEncoding,

                    !decoded.isEmpty
                else {
                    return nil
                }

                values[
                    name
                ] =
                    decoded

                continue
            }

            guard
                template
                    == concrete
            else {
                return nil
            }
        }

        guard
            Set(
                values.keys
            )
                == Set(
                    pathTemplateParameters(
                        pathTemplate
                    )
                )
        else {
            return nil
        }

        return values
    }

    private static func pathTemplateParameters(
        _ template: String
    ) -> [String] {
        template
            .split(
                separator:
                    "/"
            )
            .compactMap {
                raw
                    -> String? in

                let value =
                    String(
                        raw
                    )

                guard
                    value.hasPrefix(
                        "{"
                    ),
                    value.hasSuffix(
                        "}"
                    ),
                    value.count > 2
                else {
                    return nil
                }

                return String(
                    value
                        .dropFirst()
                        .dropLast()
                )
            }
    }

    private static func requestMedia(
        _ operation: [String: Any],
        root: [String: Any]
    ) -> [String] {
        guard
            let rawBody =
                operation[
                    "requestBody"
                ] as? [String: Any],

            let body =
                resolveLocalObject(
                    rawBody,
                    root:
                        root
                ),

            let content =
                body[
                    "content"
                ] as? [String: Any]
        else {
            return []
        }

        return
            content.keys
                .sorted()
    }

    private static func headerValue(
        _ name: String,
        in raw: Any?
    ) -> String? {
        guard
            let headers =
                raw as? [String: Any]
        else {
            return nil
        }

        for (
            key,
            value
        ) in headers {
            guard
                key
                    .caseInsensitiveCompare(
                        name
                    )
                    == .orderedSame
            else {
                continue
            }

            return value
                as? String
        }

        return nil
    }

    private static func resolveLocalObject(
        _ raw: [String: Any],
        root: [String: Any]
    ) -> [String: Any]? {
        guard
            let reference =
                raw[
                    "$ref"
                ] as? String
        else {
            return raw
        }

        guard
            reference.hasPrefix(
                "#/"
            )
        else {
            return nil
        }

        var current:
            Any = root

        for encoded
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
            let key =
                String(
                    encoded
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
                let dictionary =
                    current
                        as? [String: Any],

                let next =
                    dictionary[
                        key
                    ]
            else {
                return nil
            }

            current =
                next
        }

        return current
            as? [String: Any]
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
            rawScheme
                .lowercased()

        guard
            scheme == "http"
            || scheme == "https"
        else {
            return nil
        }

        let host =
            rawHost
                .lowercased()

        let port =
            components.port

        let defaultPort =
            (
                scheme == "https"
                ? 443
                : 80
            )

        if
            let port,
            port != defaultPort
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

    private static func sameOrigin(
        _ lhs: URL,
        _ rhs: URL
    ) -> Bool {
        canonicalOrigin(
            lhs
        )
            == canonicalOrigin(
                rhs
            )
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
