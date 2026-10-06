import Foundation
import CryptoKit

enum OpenAPIContinuationExecutionRedirectPolicy: String, Equatable {
    case reject
}

struct OpenAPIContinuationExecutionHTTPResponse {
    let statusCode: Int
    let data: Data
}

protocol OpenAPIContinuationExecutionHTTPClient {
    func send(
        _ request: URLRequest,
        redirectPolicy: OpenAPIContinuationExecutionRedirectPolicy
    ) throws -> OpenAPIContinuationExecutionHTTPResponse
}

enum OpenAPIContinuationRequestBodyInput {
    case json(Any)
    case bytes(Data)
}

struct OpenAPIContinuationUnsignedRequestDescriptor {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data
    let bodySHA256: String
    let requestFingerprintSHA256: String
}

struct OpenAPIContinuationExecutionAuthority:
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let providerOrigin: String
    let targetOperationID: String
    let securityAlternativeFingerprint: String
    let securitySchemeNames: [String]
    let securitySchemeKinds: [String]
    let authorityFingerprint: String

    private let materializer:
        (OpenAPIContinuationUnsignedRequestDescriptor, String) throws
            -> [String: String]

    init(
        providerOrigin: String,
        targetOperationID: String,
        securityAlternative: OpenAPIContinuationSecurityAlternative,
        authorityFingerprint: String,
        materializer: @escaping (
            OpenAPIContinuationUnsignedRequestDescriptor,
            String
        ) throws -> [String: String]
    ) {
        self.providerOrigin = providerOrigin
        self.targetOperationID = targetOperationID
        self.securityAlternativeFingerprint =
            securityAlternative.fingerprintSHA256
        self.securitySchemeNames = securityAlternative.schemeNames
        self.securitySchemeKinds = securityAlternative.schemeKinds
        self.authorityFingerprint = authorityFingerprint
        self.materializer = materializer
    }

    var description: String {
        "OpenAPIContinuationExecutionAuthority("
            + "providerOrigin: \(providerOrigin), "
            + "targetOperationID: \(targetOperationID), "
            + "securityAlternativeFingerprint: \(securityAlternativeFingerprint), "
            + "securitySchemeNames: \(securitySchemeNames), "
            + "securitySchemeKinds: \(securitySchemeKinds), "
            + "authorityFingerprint: \(authorityFingerprint), "
            + "privateMaterial: <redacted>)"
    }

    var debugDescription: String { description }

    func materializeCredentialHeaders(
        for descriptor: OpenAPIContinuationUnsignedRequestDescriptor,
        confirmed: Bool
    ) throws -> [String: String]? {
        guard confirmed else { return nil }
        return try materializer(
            descriptor,
            descriptor.requestFingerprintSHA256
        )
    }
}

enum OpenAPIContinuationExecutionOutcome {
    case rejected(String)
    case abstain(String)
    case inputContractFailure(String)
    case credentialRequired
    case confirmationRequired
    case redirectRejected(
        statusCode: Int,
        unsignedRequestSHA256: String,
        finalWireSHA256: String
    )
    case providerRejected(
        statusCode: Int,
        responseData: Data,
        unsignedRequestSHA256: String,
        finalWireSHA256: String
    )
    case providerAccepted(
        statusCode: Int,
        responseData: Data,
        semanticOutcomeVerified: Bool,
        unsignedRequestSHA256: String,
        finalWireSHA256: String
    )
}

enum OpenAPIContinuationExecutor {
    static func execute(
        instance: OpenAPIContinuationInstance,
        callerArguments: [String: OpenAPIContinuationValue],
        requestBody: OpenAPIContinuationRequestBodyInput?,
        authority: OpenAPIContinuationExecutionAuthority?,
        confirmed: Bool,
        client: any OpenAPIContinuationExecutionHTTPClient
    ) throws -> OpenAPIContinuationExecutionOutcome {
        let boundArguments: [String: OpenAPIContinuationValue]

        switch instance.bindArgumentsForExecution(
            callerArguments: callerArguments
        ) {
        case .rejected(let reason):
            return .rejected(reason)
        case .inputContractFailure(let reason):
            return .inputContractFailure(reason)
        case .bound(let values):
            boundArguments = values
        }

        let bodyData: Data
        let bodyContentType: String?

        switch materializeBody(
            contract: instance.requestBodyContract,
            input: requestBody
        ) {
        case .ready(let data, let contentType):
            bodyData = data
            bodyContentType = contentType
        case .rejected(let reason):
            return .rejected(reason)
        case .abstain(let reason):
            return .abstain(reason)
        case .inputContractFailure(let reason):
            return .inputContractFailure(reason)
        }

        let unsigned: OpenAPIContinuationUnsignedRequestDescriptor

        switch materializeUnsignedRequest(
            instance: instance,
            boundArguments: boundArguments,
            body: bodyData,
            bodyContentType: bodyContentType
        ) {
        case .ready(let descriptor):
            unsigned = descriptor
        case .rejected(let reason):
            return .rejected(reason)
        case .abstain(let reason):
            return .abstain(reason)
        case .inputContractFailure(let reason):
            return .inputContractFailure(reason)
        }

        let selectedSecurity: OpenAPIContinuationSecurityAlternative?

        switch instance.targetSecurityRequirement {
        case .anonymous:
            selectedSecurity = nil
        case .unresolved:
            return .abstain("execution_authority_unresolved")
        case .credentialRequired:
            guard let selected =
                instance.selectedExecutionSecurityAlternative
            else {
                return .abstain(
                    "unsupported_or_ambiguous_security_alternative"
                )
            }
            selectedSecurity = selected
        }

        var finalHeaders = unsigned.headers

        if let selectedSecurity {
            guard let authority else {
                return .credentialRequired
            }

            guard authority.providerOrigin == instance.providerOrigin else {
                return .rejected("authority_origin_mismatch")
            }

            guard
                authority.targetOperationID == instance.targetOperationID
            else {
                return .rejected("authority_operation_mismatch")
            }

            guard
                authority.securityAlternativeFingerprint
                    == selectedSecurity.fingerprintSHA256
            else {
                return .rejected(
                    "authority_security_alternative_mismatch"
                )
            }

            let reservedCredentialHeaders = Set(
                selectedSecurity.credentialHeaderNames.map {
                    $0.lowercased()
                }
            )

            guard
                reservedCredentialHeaders.isDisjoint(
                    with: Set(unsigned.headers.keys)
                )
            else {
                return .rejected("credential_header_collision")
            }

            if instance.requiresExecutionConfirmation && !confirmed {
                return .confirmationRequired
            }

            let authorityMayMaterialize =
                confirmed
                || !instance.requiresExecutionConfirmation

            guard
                let authorityHeaders =
                    try authority.materializeCredentialHeaders(
                        for: unsigned,
                        confirmed: authorityMayMaterialize
                    )
            else {
                return .confirmationRequired
            }

            guard
                let normalizedAuthorityHeaders =
                    normalizeHeaders(authorityHeaders)
            else {
                return .rejected("invalid_authority_headers")
            }

            let materializedNames =
                Set(normalizedAuthorityHeaders.keys)

            guard
                materializedNames.isSubset(
                    of: reservedCredentialHeaders
                )
            else {
                return .rejected(
                    "authority_emitted_noncredential_header"
                )
            }

            guard
                materializedNames.isDisjoint(
                    with: Set(finalHeaders.keys)
                )
            else {
                return .rejected("credential_header_collision")
            }

            for (name, value) in normalizedAuthorityHeaders {
                finalHeaders[name] = value
            }
        } else {
            if instance.requiresExecutionConfirmation && !confirmed {
                return .confirmationRequired
            }

            if authority != nil {
                return .rejected("unexpected_execution_authority")
            }
        }

        let finalWireSHA256 = requestFingerprint(
            method: unsigned.method,
            url: unsigned.url,
            headers: finalHeaders,
            bodySHA256: unsigned.bodySHA256
        )

        var request = URLRequest(url: unsigned.url)
        request.httpMethod = unsigned.method

        if instance.requestBodyContract != nil && requestBody != nil {
            request.httpBody = unsigned.body
        }

        for (name, value) in finalHeaders.sorted(
            by: { $0.key < $1.key }
        ) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let response = try client.send(
            request,
            redirectPolicy: .reject
        )

        if (300..<400).contains(response.statusCode) {
            return .redirectRejected(
                statusCode: response.statusCode,
                unsignedRequestSHA256:
                    unsigned.requestFingerprintSHA256,
                finalWireSHA256: finalWireSHA256
            )
        }

        if (200..<300).contains(response.statusCode) {
            return .providerAccepted(
                statusCode: response.statusCode,
                responseData: response.data,
                semanticOutcomeVerified: false,
                unsignedRequestSHA256:
                    unsigned.requestFingerprintSHA256,
                finalWireSHA256: finalWireSHA256
            )
        }

        return .providerRejected(
            statusCode: response.statusCode,
            responseData: response.data,
            unsignedRequestSHA256:
                unsigned.requestFingerprintSHA256,
            finalWireSHA256: finalWireSHA256
        )
    }

    private enum BodyMaterialization {
        case ready(Data, String?)
        case rejected(String)
        case abstain(String)
        case inputContractFailure(String)
    }

    private enum UnsignedRequestMaterialization {
        case ready(OpenAPIContinuationUnsignedRequestDescriptor)
        case rejected(String)
        case abstain(String)
        case inputContractFailure(String)
    }

    private static func materializeBody(
        contract: OpenAPIContinuationRequestBodyContract?,
        input: OpenAPIContinuationRequestBodyInput?
    ) -> BodyMaterialization {
        guard let contract else {
            guard input == nil else {
                return .rejected(
                    "caller_supplied_undeclared_request_body"
                )
            }
            return .ready(Data(), nil)
        }

        guard let input else {
            if contract.required {
                return .inputContractFailure(
                    "missing_required_request_body"
                )
            }
            return .ready(Data(), nil)
        }

        switch (contract.kind, input) {
        case (.json, .json(let object)):
            guard
                JSONSerialization.isValidJSONObject(object),
                let data = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
            else {
                return .inputContractFailure(
                    "invalid_json_request_body"
                )
            }
            return .ready(data, contract.mediaType)

        case (.bytes, .bytes(let data)):
            return .ready(data, contract.mediaType)

        case (.json, .bytes), (.bytes, .json):
            return .inputContractFailure(
                "request_body_kind_mismatch"
            )
        }
    }

    private static func materializeUnsignedRequest(
        instance: OpenAPIContinuationInstance,
        boundArguments: [String: OpenAPIContinuationValue],
        body: Data,
        bodyContentType: String?
    ) -> UnsignedRequestMaterialization {
        var target = instance.targetPathTemplate
        var headers: [String: String] = [:]

        for parameter in instance.targetParameterContracts {
            guard
                let value = boundArguments[parameter.argumentKey]
            else {
                if instance.ordinaryOptionalArguments.contains(
                    where: {
                        $0.argumentKey == parameter.argumentKey
                    }
                ) {
                    continue
                }
                return .inputContractFailure(
                    "missing_bound_target_argument:"
                        + parameter.argumentKey
                )
            }

            guard let scalar = scalarString(value) else {
                return .abstain(
                    "complex_or_null_target_parameter:"
                        + parameter.argumentKey
                )
            }

            switch parameter.location.lowercased() {
            case "path":
                guard
                    let encoded = percentEncodePathScalar(scalar)
                else {
                    return .abstain(
                        "path_parameter_encoding_failed:"
                            + parameter.argumentKey
                    )
                }

                let placeholder = "{\(parameter.name)}"

                guard target.contains(placeholder) else {
                    return .abstain(
                        "target_path_placeholder_missing:"
                            + parameter.argumentKey
                    )
                }

                target = target.replacingOccurrences(
                    of: placeholder,
                    with: encoded
                )

            case "header":
                let name = parameter.name.lowercased()

                guard headers[name] == nil else {
                    return .rejected(
                        "ordinary_header_collision"
                    )
                }

                headers[name] = scalar

            default:
                return .abstain(
                    "unsupported_target_parameter_location:"
                        + parameter.location
                )
            }
        }

        if target.contains("{") || target.contains("}") {
            return .abstain(
                "unresolved_target_path_placeholder"
            )
        }

        if let bodyContentType {
            guard headers["content-type"] == nil else {
                return .rejected(
                    "content_type_header_collision"
                )
            }
            headers["content-type"] = bodyContentType
        }

        guard
            let url = URL(
                string: instance.providerOrigin + target
            )
        else {
            return .abstain(
                "invalid_materialized_target_url"
            )
        }

        guard canonicalOrigin(url) == instance.providerOrigin else {
            return .rejected(
                "materialized_target_origin_mismatch"
            )
        }

        let bodySHA256 = sha256Hex(body)
        let fingerprint = requestFingerprint(
            method: instance.targetMethod,
            url: url,
            headers: headers,
            bodySHA256: bodySHA256
        )

        return .ready(
            OpenAPIContinuationUnsignedRequestDescriptor(
                method: instance.targetMethod.uppercased(),
                url: url,
                headers: headers,
                body: body,
                bodySHA256: bodySHA256,
                requestFingerprintSHA256: fingerprint
            )
        )
    }

    private static func scalarString(
        _ value: OpenAPIContinuationValue
    ) -> String? {
        switch value {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .number(let value):
            return value.isFinite
                ? String(value)
                : nil
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return nil
        }
    }

    private static func percentEncodePathScalar(
        _ value: String
    ) -> String? {
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                + "abcdefghijklmnopqrstuvwxyz"
                + "0123456789"
                + "-._~"
        )

        return value.addingPercentEncoding(
            withAllowedCharacters: allowed
        )
    }

    private static func normalizeHeaders(
        _ raw: [String: String]
    ) -> [String: String]? {
        var result: [String: String] = [:]

        for (rawName, value) in raw {
            let name = rawName
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .lowercased()

            guard
                !name.isEmpty,
                !value.contains("\r"),
                !value.contains("\n"),
                result[name] == nil
            else {
                return nil
            }

            result[name] = value
        }

        return result
    }

    static func requestFingerprint(
        method: String,
        url: URL,
        headers: [String: String],
        bodySHA256: String
    ) -> String {
        let normalizedHeaders = headers
            .map {
                ($0.key.lowercased(), $0.value)
            }
            .sorted {
                if $0.0 != $1.0 {
                    return $0.0 < $1.0
                }
                return $0.1 < $1.1
            }
            .map {
                $0.0 + ":" + $0.1
            }
            .joined(separator: "\n")

        let canonical =
            method.uppercased()
            + "\n"
            + url.absoluteString
            + "\n"
            + normalizedHeaders
            + "\n"
            + bodySHA256

        return sha256Hex(Data(canonical.utf8))
    }

    private static func canonicalOrigin(
        _ url: URL
    ) -> String? {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            let rawScheme = components.scheme,
            let rawHost = components.host
        else {
            return nil
        }

        let scheme = rawScheme.lowercased()

        guard scheme == "http" || scheme == "https" else {
            return nil
        }

        let host = rawHost.lowercased()
        let defaultPort = scheme == "https" ? 443 : 80

        if let port = components.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }

        return "\(scheme)://\(host)"
    }

    private static func sha256Hex(
        _ data: Data
    ) -> String {
        SHA256.hash(data: data)
            .map {
                String(format: "%02x", $0)
            }
            .joined()
    }
}

extension OpenAPIContinuationInstance {
    var requiresExecutionConfirmation: Bool {
        targetMethod.uppercased() != "GET"
    }
}
