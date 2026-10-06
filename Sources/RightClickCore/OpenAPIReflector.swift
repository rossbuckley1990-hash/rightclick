import CoreFoundation
import CryptoKit
import Foundation

public final class OpenAPIReflector: CapabilityReflector {
    private struct Operation {
        let capabilityID: String
        let operationID: String
        let title: String
        let method: String
        let path: String

        let requestContentType: String
        let responseContentType: String

        let requestSchemaJSON: String?
        let responseSchemaJSON: String?

        /// v0.3 GREEN-001 deliberately keeps only the original
        /// text/plain -> text/plain contract executable.
        ///
        /// Structured operations may enter the capability graph, but
        /// cannot reach provider transport until typed invocation is
        /// implemented and separately acceptance-tested.
        let supportsPlainTextInvocation: Bool
        let supportsTypedInvocation: Bool

        /// Execution authority derived only from the provider's
        /// OpenAPI security declaration.
        ///
        /// Values:
        /// - anonymous
        /// - credential_required
        /// - unresolved
        let authorityStatus: String

        /// Effective credential requirements from the provider contract.
        ///
        /// GREEN-007A exposes these for explainability only.
        /// No credential input or Authorization injection is implemented.
        let securityRequirementsJSON: String?

        /// Provider-declared credential alternatives that the generic
        /// execution-authority seam can represent exactly.
        let executionSecurityAlternatives:
            [OpenAPIOperationExecutionSecurityAlternative]

        /// Normalized declared OpenAPI parameters for explainability.
        let parametersJSON: String?

        /// GREEN-005 intentionally supports only declared string
        /// header parameters.
        let headerParameters:
            [HeaderParameterContract]

        /// Required parameters outside the GREEN-005 subset make the
        /// capability non-invocable rather than being silently ignored.
        let parameterInvocationSupported: Bool
    }

    private struct HeaderParameterContract {
        let name: String
        let required: Bool
        let schema: [String: Any]
    }

    private struct ParameterContract {
        let metadataJSON: String?
        let headers:
            [HeaderParameterContract]
        let hasUnsupportedRequired:
            Bool
    }

    private struct PreparedTypedArguments {
        let body: Any
        let headers: [String: String]
    }

    private struct BodyContract {
        let contentType: String
        let schemaJSON: String?
    }

    private struct PreparedRequestBody {
        let data: Data
        let contentType: String
        let headers: [String: String]
    }

    private final class HTTPResultBox: @unchecked Sendable {
        private let lock = NSLock()

        private var storedData: Data?
        private var storedResponse: URLResponse?
        private var storedError: Error?

        func store(
            data: Data?,
            response: URLResponse?,
            error: Error?
        ) {
            lock.lock()

            storedData = data
            storedResponse = response
            storedError = error

            lock.unlock()
        }

        func snapshot()
            -> (
                data: Data?,
                response: URLResponse?,
                error: Error?
            )
        {
            lock.lock()
            defer { lock.unlock() }

            return (
                storedData,
                storedResponse,
                storedError
            )
        }
    }

    public let id: String

    private let baseURL: URL
    private let providerName: String
    private let providerFingerprint: String
    private let specificationSHA256: String
    private let session: URLSession

    /// Optional host-supplied authority resolver.
    ///
    /// The resolver is generic to OpenAPI operation identity, provider
    /// origin and provider-declared security alternatives. Credentials
    /// never enter ContentItem text or reflected capability metadata.
    private let executionAuthorityResolver:
        OpenAPIOperationExecutionAuthorityResolver?

    private let operations: [Operation]
    private let operationByCapabilityID:
        [String: Operation]

    public init(
        specificationData: Data,
        baseURL: URL,
        session: URLSession = .shared,
        executionAuthorityResolver:
            OpenAPIOperationExecutionAuthorityResolver? = nil
    ) throws {
        let canonicalBaseURL =
            try Self.canonicalBaseURL(
                baseURL
            )

        let specificationSHA256 =
            Self.sha256Hex(
                specificationData
            )

        let providerIdentityMaterial =
            Data(
                (
                    canonicalBaseURL
                        .absoluteString
                    + "\n"
                    + specificationSHA256
                ).utf8
            )

        let providerFingerprint =
            Self.sha256Hex(
                providerIdentityMaterial
            )

        let parsed =
            try Self.parseSpecification(
                specificationData,
                providerFingerprint:
                    providerFingerprint
            )

        self.baseURL =
            canonicalBaseURL

        self.providerName =
            parsed.providerName

        self.providerFingerprint =
            providerFingerprint

        self.specificationSHA256 =
            specificationSHA256

        self.session =
            OriginPinnedHTTP.makeSession(
                template:
                    session
            )

        self.executionAuthorityResolver =
            executionAuthorityResolver

        self.operations =
            parsed.operations

        self.operationByCapabilityID =
            Dictionary(
                uniqueKeysWithValues:
                    parsed.operations.map {
                        (
                            $0.capabilityID,
                            $0
                        )
                    }
            )

        self.id =
            "openapi-reflector:"
            + providerFingerprint
    }

    public func capabilities(
        for item: ContentItem
    ) throws -> [Capability] {
        guard item.text != nil else {
            return []
        }

        return operations.map {
            operation in

            let policy =
                SafetyPolicy.classify(
                    title:
                        operation.title,
                    source: .system,
                    sendTypes: [
                        operation
                            .requestContentType
                    ],
                    returnTypes: [
                        operation
                            .responseContentType
                    ]
                )

            let bodyTransportExecutable =
                operation
                    .supportsPlainTextInvocation
                || operation
                    .supportsTypedInvocation

            let transportExecutable =
                bodyTransportExecutable
                && operation
                    .parameterInvocationSupported

            let credentialAuthorityExecutable =
                operation
                    .authorityStatus
                    == "credential_required"
                && executionAuthorityResolver
                    != nil
                && !operation
                    .executionSecurityAlternatives
                    .isEmpty

            let authorityExecutable =
                operation
                    .authorityStatus
                    == "anonymous"
                || credentialAuthorityExecutable

            let executable =
                transportExecutable
                && authorityExecutable

            var metadata:
                [String: String] = [
                    "substrate":
                        "openapi",
                    "method":
                        operation.method,
                    "path":
                        operation.path,
                    "operationId":
                        operation.operationID,
                    "providerIdentity":
                        providerFingerprint,
                    "specificationSHA256":
                        specificationSHA256,
                    "baseURL":
                        baseURL.absoluteString,
                    "requestContentType":
                        operation
                            .requestContentType,
                    "responseContentType":
                        operation
                            .responseContentType,
                    "typedInvocation":
                        operation
                            .supportsTypedInvocation
                        ? "true"
                        : "false",
                    "authorityStatus":
                        operation
                            .authorityStatus,
                ]

            if let requestSchema =
                operation
                    .requestSchemaJSON
            {
                metadata[
                    "requestSchemaJSON"
                ] = requestSchema
            }

            if let responseSchema =
                operation
                    .responseSchemaJSON
            {
                metadata[
                    "responseSchemaJSON"
                ] = responseSchema
            }

            if let parametersJSON =
                operation
                    .parametersJSON
            {
                metadata[
                    "parametersJSON"
                ] = parametersJSON
            }

            if let securityRequirementsJSON =
                operation
                    .securityRequirementsJSON
            {
                metadata[
                    "securityRequirementsJSON"
                ] = securityRequirementsJSON
            }

             if
                !authorityExecutable
            {
                metadata[
                    "invocationLimitation"
                ] =
                    operation
                        .authorityStatus
                        == "credential_required"
                    ? "The provider contract requires credentials; no matching generic execution authority is currently available."
                    : "Execution authority is unresolved because the provider contract does not explicitly permit anonymous invocation."
            } else if
                !transportExecutable
            {
                metadata[
                    "invocationLimitation"
                ] =
                    "The provider contract is authorized for anonymous use, but no implemented serializer matches this operation."
            }

            return Capability(
                id:
                    operation.capabilityID,
                title:
                    operation.title,
                source:
                    .system,
                provider:
                    CapabilityProvider(
                        name:
                            providerName,
                        bundleIdentifier:
                            nil
                    ),
                inputs:
                    executable
                    ? [
                        "public.plain-text"
                    ]
                    : [
                        operation
                            .requestContentType
                    ],
                output:
                    executable
                    ? [
                        "public.plain-text"
                    ]
                    : [
                        operation
                            .responseContentType
                    ],
                safety:
                    policy.safety,
                invocation:
                    executable
                    ? policy.invocation
                    : .unsupported,
                supportLevel:
                    .experimental,
                requiresConfirmation:
                    executable
                    ? policy
                        .requiresConfirmation
                    : true,
                metadata:
                    metadata
            )
        }
    }

    public func providers()
        -> [ProviderSummary]
    {
        guard !operations.isEmpty else {
            return []
        }

        return [
            ProviderSummary(
                name:
                    providerName,
                bundleIdentifier:
                    nil,
                source:
                    "openapi",
                capabilityTitles:
                    operations
                    .map(\.title)
                    .sorted {
                        $0.localizedCaseInsensitiveCompare(
                            $1
                        ) == .orderedAscending
                    }
            )
        ]
    }

    public func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws -> ExecutionRecord {
        guard
            let operation =
                operationByCapabilityID[
                    capability.id
                ]
        else {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .unavailable,
                message:
                    "The reflected OpenAPI operation is no longer available.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_unavailable",
                        boundary:
                            "No operation matching this capability exists in the current OpenAPI reflector."
                    )
            )
        }

        guard
            (
                operation
                    .supportsPlainTextInvocation
                || operation
                    .supportsTypedInvocation
            ),
            operation
                .parameterInvocationSupported
        else {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .unsupported,
                message:
                    "No implemented OpenAPI invocation path matches this capability.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_invocation_unsupported",
                        boundary:
                            "The capability was reflected but no implemented request serializer matches its provider contract."
                    )
            )
        }

        guard let text = item.text else {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .failed,
                message:
                    "The OpenAPI operation requires a plain-text input.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "input_contract_failure",
                        boundary:
                            "No plain-text ContentItem payload was available for the declared text/plain request body."
                    )
            )
        }

        let targetURL =
            try joinedURL(
                path:
                    operation.path
            )

        var request =
            URLRequest(
                url: targetURL
            )

        request.httpMethod =
            operation.method

        let preparedBody:
            PreparedRequestBody

        do {
            preparedBody =
                try Self.prepareRequestBody(
                    operation:
                        operation,
                    input:
                        text,
                    executionID:
                        executionID
                )
        } catch {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .failed,
                message:
                    "The typed OpenAPI input did not satisfy the reflected request contract: \(String(describing: error))",
                evidence:
                    OutcomeEvidence(
                        type:
                            "input_contract_failure",
                        boundary:
                            "Typed provider arguments are validated and serialized before HTTP transport."
                    )
            )
        }

        request.httpBody =
            preparedBody.data

        request.setValue(
            preparedBody.contentType,
            forHTTPHeaderField:
                "Content-Type"
        )

        request.setValue(
            operation.responseContentType,
            forHTTPHeaderField:
                "Accept"
        )

        for name in
            preparedBody
                .headers
                .keys
                .sorted()
        {
            guard
                let value =
                    preparedBody
                        .headers[name]
            else {
                continue
            }

            request.setValue(
                value,
                forHTTPHeaderField:
                    name
            )
        }

        func executionAuthorityFailure(
            state:
                ExecutionState,
            type:
                String,
            message:
                String,
            boundary:
                String
        ) -> ExecutionRecord {
            ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    state,
                message:
                    message,
                evidence:
                    OutcomeEvidence(
                        type:
                            type,
                        boundary:
                            boundary,
                        outcomeVerified:
                            false
                    )
            )
        }

        if
            operation
                .authorityStatus
                == "credential_required"
        {
            guard
                let resolver =
                    executionAuthorityResolver
            else {
                return executionAuthorityFailure(
                    state:
                        .unavailable,
                    type:
                        "execution_authority_unavailable",
                    message:
                        "The provider operation requires execution authority, but no authority resolver is available.",
                    boundary:
                        "No credential was materialized and no provider request was sent."
                )
            }

            guard
                !operation
                    .executionSecurityAlternatives
                    .isEmpty
            else {
                return executionAuthorityFailure(
                    state:
                        .unsupported,
                    type:
                        "execution_authority_unsupported",
                    message:
                        "The provider operation requires credentials, but none of its declared security alternatives are supported by the generic authority boundary.",
                    boundary:
                        "Unsupported security remains fail-closed before transport."
                )
            }

            guard
                let providerOrigin =
                    openAPICanonicalExecutionOrigin(
                        baseURL
                    )
            else {
                return executionAuthorityFailure(
                    state:
                        .failed,
                    type:
                        "execution_authority_origin_invalid",
                    message:
                        "The provider origin could not be canonicalized for execution authority.",
                    boundary:
                        "Authority resolution stopped before credential materialization and transport."
                )
            }

            let authorityRequest =
                OpenAPIOperationExecutionAuthorityRequest(
                    providerOrigin:
                        providerOrigin,
                    operationID:
                        operation
                            .operationID,
                    method:
                        operation
                            .method,
                    url:
                        targetURL,
                    securityAlternatives:
                        operation
                            .executionSecurityAlternatives
                )

            let authority:
                OpenAPIOperationExecutionAuthority?

            do {
                authority =
                    try resolver(
                        authorityRequest
                    )
            } catch {
                return executionAuthorityFailure(
                    state:
                        .failed,
                    type:
                        "execution_authority_resolution_failed",
                    message:
                        "Execution authority resolution failed.",
                    boundary:
                        "Resolver errors are not expanded because authority material may be private."
                )
            }

            guard
                let authority
            else {
                return executionAuthorityFailure(
                    state:
                        .unavailable,
                    type:
                        "execution_authority_unavailable",
                    message:
                        "No execution authority is available for the reflected provider operation.",
                    boundary:
                        "No credential was materialized and no provider request was sent."
                )
            }

            guard
                authority
                    .providerOrigin
                    == providerOrigin
            else {
                return executionAuthorityFailure(
                    state:
                        .failed,
                    type:
                        "execution_authority_origin_mismatch",
                    message:
                        "Execution authority origin does not match the reflected provider origin.",
                    boundary:
                        "Mismatched authority was rejected before credential materialization and transport."
                )
            }

            guard
                authority
                    .operationID
                    == operation
                        .operationID
            else {
                return executionAuthorityFailure(
                    state:
                        .failed,
                    type:
                        "execution_authority_operation_mismatch",
                    message:
                        "Execution authority operation does not match the reflected provider operation.",
                    boundary:
                        "Mismatched authority was rejected before credential materialization and transport."
                )
            }

            guard
                let selectedAlternative =
                    operation
                        .executionSecurityAlternatives
                        .first(
                            where: {
                                $0
                                    .fingerprintSHA256
                                    == authority
                                        .securityAlternativeFingerprintSHA256
                            }
                        )
            else {
                return executionAuthorityFailure(
                    state:
                        .failed,
                    type:
                        "execution_authority_security_mismatch",
                    message:
                        "Execution authority does not match a supported provider-declared security alternative.",
                    boundary:
                        "Security-alternative mismatch was rejected before credential materialization and transport."
                )
            }

            let reservedHeaders =
                Dictionary(
                    uniqueKeysWithValues:
                        selectedAlternative
                            .schemes
                            .map {
                                (
                                    $0
                                        .credentialHeaderName
                                        .lowercased(),
                                    $0
                                        .credentialHeaderName
                                )
                            }
                )

            let existingHeaders =
                Set(
                    (
                        request
                            .allHTTPHeaderFields
                        ?? [:]
                    )
                    .keys
                    .map {
                        $0
                            .lowercased()
                    }
                )

            guard
                Set(
                    reservedHeaders
                        .keys
                )
                .isDisjoint(
                    with:
                        existingHeaders
                )
            else {
                return executionAuthorityFailure(
                    state:
                        .failed,
                    type:
                        "credential_header_collision",
                    message:
                        "A caller-controlled or transport-owned header collides with a provider credential header.",
                    boundary:
                        "Credential headers are authority-owned and cannot be supplied through ordinary typed arguments."
                )
            }

            let descriptor =
                openAPIOperationUnsignedDescriptor(
                    request:
                        request
                )

            let rawAuthorityHeaders:
                [String: String]

            do {
                rawAuthorityHeaders =
                    try authority
                        .materializeCredentialHeaders(
                            for:
                                descriptor
                        )
            } catch {
                return executionAuthorityFailure(
                    state:
                        .failed,
                    type:
                        "execution_authority_materialization_failed",
                    message:
                        "Execution authority could not materialize the provider credential.",
                    boundary:
                        "Private authority errors are not expanded and no provider request was sent."
                )
            }

            guard
                let normalizedAuthorityHeaders =
                    normalizeOpenAPIOperationCredentialHeaders(
                        rawAuthorityHeaders
                    )
            else {
                return executionAuthorityFailure(
                    state:
                        .failed,
                    type:
                        "invalid_authority_headers",
                    message:
                        "Execution authority emitted invalid credential headers.",
                    boundary:
                        "Invalid credential material was rejected before transport."
                )
            }

            guard
                Set(
                    normalizedAuthorityHeaders
                        .keys
                )
                == Set(
                    reservedHeaders
                        .keys
                )
            else {
                return executionAuthorityFailure(
                    state:
                        .failed,
                    type:
                        "authority_emitted_wrong_credential_headers",
                    message:
                        "Execution authority did not emit exactly the credential headers required by the selected security alternative.",
                    boundary:
                        "Authority may emit only the provider-declared credential headers for its exact selected alternative."
                )
            }

            for (
                identity,
                value
            ) in normalizedAuthorityHeaders
            {
                guard
                    let canonicalName =
                        reservedHeaders[
                            identity
                        ]
                else {
                    return executionAuthorityFailure(
                        state:
                            .failed,
                        type:
                            "authority_emitted_noncredential_header",
                        message:
                            "Execution authority emitted a non-credential header.",
                        boundary:
                            "Authority may emit provider credential headers only."
                    )
                }

                request.setValue(
                    value,
                    forHTTPHeaderField:
                        canonicalName
                )
            }
        }

        let semaphore =
            DispatchSemaphore(
                value: 0
            )

        let box =
            HTTPResultBox()

        let task =
            session.dataTask(
                with: request
            ) {
                data,
                response,
                error in

                box.store(
                    data: data,
                    response: response,
                    error: error
                )

                semaphore.signal()
            }

        task.resume()

        let wait =
            semaphore.wait(
                timeout:
                    .now() + 10
            )

        if wait == .timedOut {
            task.cancel()

            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .unknown,
                message:
                    "The OpenAPI provider invocation deadline elapsed.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "invocation_timeout",
                        boundary:
                            "No completed HTTP provider response was observed before the bounded deadline."
                    )
            )
        }

        let result =
            box.snapshot()

        if let error = result.error {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .failed,
                message:
                    "The OpenAPI provider request failed: \(error.localizedDescription)",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_transport_failure",
                        boundary:
                            "The HTTP transport failed before provider acceptance could be established."
                    )
            )
        }

        guard
            let response =
                result.response
                    as? HTTPURLResponse
        else {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .unknown,
                message:
                    "The OpenAPI provider returned no HTTP response.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_response_unavailable",
                        boundary:
                            "No HTTP status code was available to establish provider acceptance."
                    )
            )
        }

        guard
            OriginPinnedHTTP.sameOrigin(
                targetURL,
                response.url
            )
        else {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .failed,
                message:
                    "The OpenAPI provider response escaped the selected origin.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_origin_violation",
                        boundary:
                            "The provider response origin differed from the discovered capability origin."
                    )
            )
        }

        guard
            (200...299).contains(
                response.statusCode
            )
        else {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .rejected,
                message:
                    "The OpenAPI provider returned HTTP \(response.statusCode).",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_rejection",
                        boundary:
                            "The provider returned a non-2xx HTTP status code."
                    )
            )
        }

        let responseData =
            result.data ?? Data()

        let mediaType =
            response
            .value(
                forHTTPHeaderField:
                    "Content-Type"
            )?
            .split(
                separator: ";",
                maxSplits: 1
            )
            .first
            .map {
                String($0)
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .lowercased()
            }

        let output: String?

        if
            mediaType == "text/plain"
            || mediaType == "application/json"
            || mediaType?
                .hasSuffix(
                    "+json"
                ) == true
        {
            output =
                String(
                    data:
                        responseData,
                    encoding:
                        .utf8
                )
        } else {
            output = nil
        }

        return ExecutionRecord(
            executionId:
                executionID,
            actionId:
                capability.id,
            title:
                capability.title,
            state:
                .accepted,
            message:
                "HTTP provider returned \(response.statusCode); semantic outcome is unverified.",
            output:
                output,
            events: [
                "HTTP \(operation.method) \(targetURL.absoluteString)",
                "provider returned \(response.statusCode)",
            ],
            evidence:
                OutcomeEvidence(
                    type:
                        output == nil
                        ? "provider_http_acceptance"
                        : (
                            mediaType == "application/json"
                            || mediaType?
                                .hasSuffix(
                                    "+json"
                                ) == true
                            ? "provider_returned_json"
                            : "provider_returned_text"
                        ),
                    boundary:
                        "A 2xx HTTP response establishes provider acceptance only. The intended semantic outcome has not been independently verified.",
                    outcomeVerified:
                        false
                )
        )
    }

    private func joinedURL(
        path operationPath: String
    ) throws -> URL {
        guard
            var components =
                URLComponents(
                    url:
                        baseURL,
                    resolvingAgainstBaseURL:
                        false
                )
        else {
            throw RightClickError(
                "Could not construct the OpenAPI request URL."
            )
        }

        var basePath =
            components.path

        while
            basePath.count > 1,
            basePath.hasSuffix("/")
        {
            basePath.removeLast()
        }

        if basePath == "/" {
            basePath = ""
        }

        let suffix =
            operationPath.hasPrefix("/")
            ? operationPath
            : "/" + operationPath

        components.path =
            basePath + suffix

        guard let url = components.url else {
            throw RightClickError(
                "Could not construct the OpenAPI request URL."
            )
        }

        return url
    }

    private static func canonicalBaseURL(
        _ url: URL
    ) throws -> URL {
        guard
            var components =
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL:
                        false
                ),
            let rawScheme =
                components.scheme,
            let rawHost =
                components.host
        else {
            throw RightClickError(
                "OpenAPI base URL must be an absolute HTTP or HTTPS URL."
            )
        }

        let scheme =
            rawScheme.lowercased()

        guard
            scheme == "http"
                || scheme == "https"
        else {
            throw RightClickError(
                "OpenAPI base URL must use HTTP or HTTPS."
            )
        }

        components.scheme =
            scheme

        components.host =
            rawHost.lowercased()

        components.fragment = nil
        components.query = nil

        if
            (scheme == "http"
                && components.port == 80)
            || (scheme == "https"
                && components.port == 443)
        {
            components.port = nil
        }

        var path =
            components.path

        while
            path.count > 1,
            path.hasSuffix("/")
        {
            path.removeLast()
        }

        if path == "/" {
            path = ""
        }

        components.path =
            path

        guard let result = components.url else {
            throw RightClickError(
                "Could not canonicalize OpenAPI base URL."
            )
        }

        return result
    }

    private static func parseSpecification(
        _ data: Data,
        providerFingerprint: String
    ) throws -> (
        providerName: String,
        operations: [Operation]
    ) {
        guard
            let root =
                try JSONSerialization
                    .jsonObject(
                        with: data
                    )
                    as? [String: Any]
        else {
            throw RightClickError(
                "OpenAPI specification must be a JSON object."
            )
        }

        guard
            let version =
                root["openapi"]
                    as? String,
            version.hasPrefix("3.")
        else {
            throw RightClickError(
                "Only OpenAPI 3.x JSON specifications are supported."
            )
        }

        let info =
            root["info"]
                as? [String: Any]

        let rawTitle =
            (
                info?["title"]
                    as? String
            )?
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        let providerName =
            rawTitle?.isEmpty == false
            ? rawTitle!
            : "OpenAPI provider"

        guard
            let paths =
                root["paths"]
                    as? [String: Any]
        else {
            return (
                providerName,
                []
            )
        }

        let methods = [
            "get",
            "post",
            "put",
            "patch",
        ]

        var operations: [Operation] = []

        for path in paths.keys.sorted() {
            guard
                let pathObject =
                    paths[path]
                        as? [String: Any]
            else {
                continue
            }

            for method in methods {
                guard
                    let operation =
                        pathObject[method]
                            as? [String: Any]
                else {
                    continue
                }

                guard
                    let operationID =
                        (
                            operation[
                                "operationId"
                            ]
                            as? String
                        )?
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        ),
                    !operationID.isEmpty
                else {
                    continue
                }

                let authorityStatus =
                    openAPIAuthorityStatus(
                        operation:
                            operation,
                        root:
                            root
                    )

                let pathIsParameterized =
                    path.contains("{")
                    || path.contains("}")

                if
                    pathIsParameterized,
                    authorityStatus
                        != "credential_required"
                {
                    continue
                }

                guard
                    let request =
                        reflectionRequestContract(
                            operation,
                            root:
                                root,
                            authorityStatus:
                                authorityStatus
                        ),
                    let response =
                        reflectionResponseContract(
                            operation,
                            root:
                                root,
                            authorityStatus:
                                authorityStatus
                        )
                else {
                    continue
                }

                let summary =
                    (
                        operation["summary"]
                            as? String
                    )?
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )

                let title =
                    summary?.isEmpty == false
                    ? summary!
                    : operationID

                let operationMaterial =
                    Data(
                        (
                            method.uppercased()
                            + "\n"
                            + path
                            + "\n"
                            + operationID
                        ).utf8
                    )

                let operationFingerprint =
                    String(
                        sha256Hex(
                            operationMaterial
                        )
                        .prefix(16)
                    )

                let encodedOperationID =
                    operationID
                    .addingPercentEncoding(
                        withAllowedCharacters:
                            identifierCharacters
                    )
                    ?? operationID

                let capabilityID =
                    "openapi:"
                    + providerFingerprint
                    + ":"
                    + operationFingerprint
                    + ":"
                    + encodedOperationID

                let supportsPlainTextInvocation =
                    request.contentType
                        == "text/plain"
                    && response.contentType
                        == "text/plain"

                let supportsTypedInvocation =
                    (
                        request.contentType
                            == "application/json"
                        || request.contentType
                            == "multipart/form-data"
                    )
                    && response.contentType
                        == "application/json"

                let securityRequirementsJSON =
                    authorityStatus
                        == "credential_required"
                    ? openAPISecurityRequirementsJSON(
                        operation:
                            operation,
                        root:
                            root
                    )
                    : nil

                let executionSecurityAlternatives =
                    authorityStatus
                        == "credential_required"
                    ? OpenAPIOperationExecutionSecurityAlternative
                        .derive(
                            operation:
                                operation,
                            root:
                                root
                        )
                    : []

                let parameterContract =
                    openAPIParameterContract(
                        pathObject:
                            pathObject,
                        operation:
                            operation,
                        root:
                            root
                    )

                // Header envelopes are part of typed invocation only.
                // Existing bare text/plain execution remains unchanged.
                let parameterInvocationSupported =
                    !parameterContract
                        .hasUnsupportedRequired
                    && (
                        parameterContract
                            .headers
                            .isEmpty
                        || supportsTypedInvocation
                    )

                operations.append(
                    Operation(
                        capabilityID:
                            capabilityID,
                        operationID:
                            operationID,
                        title:
                            title,
                        method:
                            method.uppercased(),
                        path:
                            path,
                        requestContentType:
                            request.contentType,
                        responseContentType:
                            response.contentType,
                        requestSchemaJSON:
                            request.schemaJSON,
                        responseSchemaJSON:
                            response.schemaJSON,
                        supportsPlainTextInvocation:
                            supportsPlainTextInvocation,
                        supportsTypedInvocation:
                            supportsTypedInvocation,
                        authorityStatus:
                            authorityStatus,
                        securityRequirementsJSON:
                            securityRequirementsJSON,
                        executionSecurityAlternatives:
                            executionSecurityAlternatives,
                        parametersJSON:
                            parameterContract
                                .metadataJSON,
                        headerParameters:
                            parameterContract
                                .headers,
                        parameterInvocationSupported:
                            parameterInvocationSupported
                    )
                )
            }
        }

        return (
            providerName,
            operations.sorted {
                if $0.path == $1.path {
                    if
                        $0.method
                            == $1.method
                    {
                        return
                            $0.operationID
                            < $1.operationID
                    }

                    return
                        $0.method
                        < $1.method
                }

                return
                    $0.path
                    < $1.path
            }
        )
    }

    private static func openAPIParameterContract(
        pathObject: [String: Any],
        operation: [String: Any],
        root: [String: Any]
    ) -> ParameterContract {
        var merged:
            [String: [String: Any]] = [:]

        // An unresolved declaration cannot safely be assumed optional.
        var unresolvedDeclaration =
            false

        func absorb(
            _ rawValue: Any?
        ) {
            guard
                let rawValue
            else {
                return
            }

            guard
                let rows =
                    rawValue
                        as? [Any]
            else {
                unresolvedDeclaration =
                    true

                return
            }

            for rawRow in rows {
                guard
                    let rawObject =
                        rawRow
                            as? [String: Any],
                    let parameter =
                        resolveSchema(
                            rawObject,
                            root:
                                root
                        ),
                    let rawName =
                        parameter["name"]
                            as? String,
                    let rawLocation =
                        parameter["in"]
                            as? String
                else {
                    unresolvedDeclaration =
                        true

                    continue
                }

                let name =
                    rawName
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )

                let location =
                    rawLocation
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )
                        .lowercased()

                guard
                    !name.isEmpty,
                    [
                        "header",
                        "query",
                        "path",
                        "cookie",
                    ].contains(
                        location
                    )
                else {
                    unresolvedDeclaration =
                        true

                    continue
                }

                let required =
                    location == "path"
                    || parameter[
                        "required"
                    ] as? Bool
                        == true

                var normalized:
                    [String: Any] = [
                        "name":
                            name,
                        "in":
                            location,
                        "required":
                            required,
                    ]

                if
                    let rawSchema =
                        parameter[
                            "schema"
                        ]
                            as? [String: Any],
                    let schema =
                        resolveSchema(
                            rawSchema,
                            root:
                                root
                        )
                {
                    normalized[
                        "schema"
                    ] = schema
                } else if
                    parameter[
                        "schema"
                    ] != nil
                {
                    normalized[
                        "schemaUnresolved"
                    ] = true
                }

                if
                    let style =
                        parameter[
                            "style"
                        ] as? String
                {
                    normalized[
                        "style"
                    ] = style
                }

                if
                    let explode =
                        parameter[
                            "explode"
                        ] as? Bool
                {
                    normalized[
                        "explode"
                    ] = explode
                }

                // Operation parameters replace path-item parameters
                // with the same location/name pair because absorb()
                // processes the operation list second.
                let identity =
                    location
                    + "\n"
                    + name.lowercased()

                merged[
                    identity
                ] = normalized
            }
        }

        absorb(
            pathObject[
                "parameters"
            ]
        )

        absorb(
            operation[
                "parameters"
            ]
        )

        let rows =
            merged
                .values
                .sorted {
                    lhs,
                    rhs in

                    let leftLocation =
                        lhs[
                            "in"
                        ] as? String
                        ?? ""

                    let rightLocation =
                        rhs[
                            "in"
                        ] as? String
                        ?? ""

                    if
                        leftLocation
                        != rightLocation
                    {
                        return
                            leftLocation
                            < rightLocation
                    }

                    return
                        (
                            lhs[
                                "name"
                            ] as? String
                            ?? ""
                        )
                        .localizedCaseInsensitiveCompare(
                            rhs[
                                "name"
                            ] as? String
                            ?? ""
                        )
                        == .orderedAscending
                }

        let metadataJSON:
            String?

        if
            !rows.isEmpty,
            JSONSerialization
                .isValidJSONObject(
                    rows
                ),
            let data =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            rows,
                        options: [
                            .sortedKeys
                        ]
                    )
        {
            metadataJSON =
                String(
                    data:
                        data,
                    encoding:
                        .utf8
                )
        } else {
            metadataJSON =
                nil
        }

        var headers:
            [HeaderParameterContract] = []

        var hasUnsupportedRequired =
            unresolvedDeclaration

        for row in rows {
            guard
                let name =
                    row[
                        "name"
                    ] as? String,
                let location =
                    row[
                        "in"
                    ] as? String
            else {
                hasUnsupportedRequired =
                    true

                continue
            }

            let required =
                row[
                    "required"
                ] as? Bool
                ?? false

            guard
                location == "header",
                let schema =
                    row[
                        "schema"
                    ]
                        as? [String: Any],
                supportedHeaderSchema(
                    schema
                ),
                supportedHeaderSerialization(
                    row
                ),
                safeForwardableHeaderName(
                    name
                )
            else {
                if required {
                    hasUnsupportedRequired =
                        true
                }

                continue
            }

            headers.append(
                HeaderParameterContract(
                    name:
                        name,
                    required:
                        required,
                    schema:
                        schema
                )
            )
        }

        headers.sort {
            $0.name
                .localizedCaseInsensitiveCompare(
                    $1.name
                )
                == .orderedAscending
        }

        return ParameterContract(
            metadataJSON:
                metadataJSON,
            headers:
                headers,
            hasUnsupportedRequired:
                hasUnsupportedRequired
        )
    }

    private static func supportedHeaderSerialization(
        _ parameter: [String: Any]
    ) -> Bool {
        if
            let style =
                parameter[
                    "style"
                ] as? String,
            style != "simple"
        {
            return false
        }

        if
            parameter[
                "explode"
            ] as? Bool
                == true
        {
            return false
        }

        return true
    }

    private static func supportedHeaderSchema(
        _ schema: [String: Any]
    ) -> Bool {
        guard
            schema[
                "type"
            ] as? String
                == "string"
        else {
            return false
        }

        // GREEN-005 implements exactly these string constraints.
        // Unknown validation semantics remain unsupported rather
        // than being silently ignored.
        let allowedKeys:
            Set<String> = [
                "type",
                "minLength",
                "maxLength",
                "pattern",

                // Annotation-only keys.
                "title",
                "description",
                "default",
                "example",
                "examples",
                "deprecated",
                "readOnly",
                "writeOnly",
            ]

        return
            Set(
                schema.keys
            )
            .isSubset(
                of:
                    allowedKeys
            )
    }

    private static func safeForwardableHeaderName(
        _ name: String
    ) -> Bool {
        let lowered =
            name.lowercased()

        // Caller-supplied credentials and transport-owned headers
        // are deliberately outside GREEN-005.
        let forbidden:
            Set<String> = [
                "authorization",
                "proxy-authorization",
                "cookie",
                "set-cookie",
                "host",
                "content-length",
                "transfer-encoding",
                "connection",
                "content-type",
                "accept",
            ]

        guard
            !forbidden.contains(
                lowered
            ),
            !name.isEmpty
        else {
            return false
        }

        let allowed =
            CharacterSet(
                charactersIn:
                    "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            )

        return
            name
                .unicodeScalars
                .allSatisfy {
                    allowed.contains(
                        $0
                    )
                }
    }

    private static func openAPIAuthorityStatus(
        operation: [String: Any],
        root: [String: Any]
    ) -> String {
        let rawSecurity: Any

        // OpenAPI operation-level security replaces the root declaration.
        if
            operation.keys
                .contains(
                    "security"
                )
        {
            guard
                let value =
                    operation[
                        "security"
                    ]
            else {
                return "unresolved"
            }

            rawSecurity =
                value
        } else if
            root.keys
                .contains(
                    "security"
                )
        {
            guard
                let value =
                    root[
                        "security"
                    ]
            else {
                return "unresolved"
            }

            rawSecurity =
                value
        } else {
            // Absence is not affirmative anonymous authority.
            return "unresolved"
        }

        guard
            let requirements =
                rawSecurity
                    as? [Any]
        else {
            return "unresolved"
        }

        // Explicit `security: []` means this operation is anonymous.
        if requirements.isEmpty {
            return "anonymous"
        }

        var sawCredentialRequirement =
            false

        for rawRequirement in requirements {
            guard
                let requirement =
                    rawRequirement
                        as? [String: Any]
            else {
                return "unresolved"
            }

            // OpenAPI `{}` is an explicit anonymous alternative.
            if requirement.isEmpty {
                return "anonymous"
            }

            sawCredentialRequirement =
                true
        }

        return
            sawCredentialRequirement
            ? "credential_required"
            : "unresolved"
    }

    private static func reflectionRequestContract(
        _ operation: [String: Any],
        root: [String: Any],
        authorityStatus: String
    ) -> BodyContract? {
        // Preserve every previously supported executable contract.
        if
            let supported =
                supportedRequestContract(
                    operation,
                    root:
                        root
                )
        {
            return supported
        }

        // GREEN-007A broadens DISCOVERY only for provider-declared
        // credential-required continuations.
        guard
            authorityStatus
                == "credential_required"
        else {
            return nil
        }

        // GET/status and POST/finalize may legitimately have no body.
        // "none" is capability metadata only. There is no serializer
        // for it, so it cannot reach provider transport.
        guard
            operation.keys
                .contains(
                    "requestBody"
                )
        else {
            return BodyContract(
                contentType:
                    "none",
                schemaJSON:
                    nil
            )
        }

        guard
            let requestBody =
                operation[
                    "requestBody"
                ] as? [String: Any],
            requestBody[
                "required"
            ] as? Bool
                == true,
            let content =
                requestBody[
                    "content"
                ] as? [String: Any]
        else {
            return nil
        }

        // The real temp.md continuation is a raw byte upload.
        //
        // This records its contract only. prepareRequestBody() has no
        // application/octet-stream case and remains untouched.
        guard
            let octet =
                content[
                    "application/octet-stream"
                ] as? [String: Any]
        else {
            return nil
        }

        var schemaJSON:
            String?

        if
            let rawSchema =
                octet[
                    "schema"
                ] as? [String: Any],
            let schema =
                resolveSchema(
                    rawSchema,
                    root:
                        root
                )
        {
            schemaJSON =
                schemaJSONString(
                    schema
                )
        } else {
            schemaJSON =
                nil
        }

        return BodyContract(
            contentType:
                "application/octet-stream",
            schemaJSON:
                schemaJSON
        )
    }

    private static func reflectionResponseContract(
        _ operation: [String: Any],
        root: [String: Any],
        authorityStatus: String
    ) -> BodyContract? {
        // Preserve every response contract previously understood.
        if
            let supported =
                supportedResponseContract(
                    operation,
                    root:
                        root
                )
        {
            return supported
        }

        guard
            authorityStatus
                == "credential_required",
            let responses =
                operation[
                    "responses"
                ] as? [String: Any]
        else {
            return nil
        }

        // Narrow fallback: credentialed continuation with a documented
        // 2xx response and no response body.
        for key in responses.keys.sorted() {
            guard
                let status =
                    Int(
                        key
                    ),
                (200...299)
                    .contains(
                        status
                    ),
                let response =
                    responses[
                        key
                    ] as? [String: Any]
            else {
                continue
            }

            if
                response[
                    "content"
                ] == nil
            {
                return BodyContract(
                    contentType:
                        "none",
                    schemaJSON:
                        nil
                )
            }

            if
                let content =
                    response[
                        "content"
                    ] as? [String: Any],
                content.isEmpty
            {
                return BodyContract(
                    contentType:
                        "none",
                    schemaJSON:
                        nil
                )
            }
        }

        return nil
    }

    private static func openAPISecurityRequirementsJSON(
        operation: [String: Any],
        root: [String: Any]
    ) -> String? {
        let rawSecurity: Any

        if
            operation.keys
                .contains(
                    "security"
                )
        {
            guard
                let value =
                    operation[
                        "security"
                    ]
            else {
                return nil
            }

            rawSecurity =
                value
        } else if
            root.keys
                .contains(
                    "security"
                )
        {
            guard
                let value =
                    root[
                        "security"
                    ]
            else {
                return nil
            }

            rawSecurity =
                value
        } else {
            return nil
        }

        guard
            let requirements =
                rawSecurity
                    as? [Any],
            JSONSerialization
                .isValidJSONObject(
                    requirements
                ),
            let data =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            requirements,
                        options: [
                            .sortedKeys
                        ]
                    )
        else {
            return nil
        }

        return String(
            data:
                data,
            encoding:
                .utf8
        )
    }

    private static func supportedRequestContract(
        _ operation: [String: Any],
        root: [String: Any]
    ) -> BodyContract? {
        guard
            let requestBody =
                operation["requestBody"]
                    as? [String: Any],
            requestBody["required"]
                as? Bool == true,
            let content =
                requestBody["content"]
                    as? [String: Any]
        else {
            return nil
        }

        if
            let text =
                content["text/plain"]
                    as? [String: Any],
            let rawSchema =
                text["schema"]
                    as? [String: Any],
            let schema =
                resolveSchema(
                    rawSchema,
                    root:
                        root
                ),
            schema["type"]
                as? String == "string"
        {
            return BodyContract(
                contentType:
                    "text/plain",
                schemaJSON:
                    schemaJSONString(
                        schema
                    )
            )
        }

        if
            let json =
                content["application/json"]
                    as? [String: Any],
            let rawSchema =
                json["schema"]
                    as? [String: Any],
            let schema =
                resolveSchema(
                    rawSchema,
                    root:
                        root
                ),
            supportedJSONSchema(
                schema
            )
        {
            return BodyContract(
                contentType:
                    "application/json",
                schemaJSON:
                    schemaJSONString(
                        schema
                    )
            )
        }

        if
            let multipart =
                content[
                    "multipart/form-data"
                ]
                    as? [String: Any],
            let rawSchema =
                multipart["schema"]
                    as? [String: Any],
            let schema =
                resolveSchema(
                    rawSchema,
                    root:
                        root
                ),
            schema["type"]
                as? String == "object"
        {
            return BodyContract(
                contentType:
                    "multipart/form-data",
                schemaJSON:
                    schemaJSONString(
                        schema
                    )
            )
        }

        return nil
    }

    private static func supportedResponseContract(
        _ operation: [String: Any],
        root: [String: Any]
    ) -> BodyContract? {
        guard
            let responses =
                operation["responses"]
                    as? [String: Any]
        else {
            return nil
        }

        var structuredFallback:
            BodyContract?

        for key in responses.keys.sorted() {
            guard
                let status =
                    Int(key),
                (200...299)
                    .contains(status),
                let response =
                    responses[key]
                        as? [String: Any],
                let content =
                    response["content"]
                        as? [String: Any]
            else {
                continue
            }

            if
                let text =
                    content["text/plain"]
                        as? [String: Any],
                let rawSchema =
                    text["schema"]
                        as? [String: Any],
                let schema =
                    resolveSchema(
                        rawSchema,
                        root:
                            root
                    ),
                schema["type"]
                    as? String == "string"
            {
                return BodyContract(
                    contentType:
                        "text/plain",
                    schemaJSON:
                        schemaJSONString(
                            schema
                        )
                )
            }

            if
                structuredFallback == nil,
                let json =
                    content["application/json"]
                        as? [String: Any],
                let rawSchema =
                    json["schema"]
                        as? [String: Any],
                let schema =
                    resolveSchema(
                        rawSchema,
                        root:
                            root
                    ),
                supportedJSONSchema(
                    schema
                )
            {
                structuredFallback =
                    BodyContract(
                        contentType:
                            "application/json",
                        schemaJSON:
                            schemaJSONString(
                                schema
                            )
                    )
            }
        }

        return structuredFallback
    }

    private static func resolveSchema(
        _ schema: [String: Any],
        root: [String: Any],
        visited: Set<String> = [],
        depth: Int = 0
    ) -> [String: Any]? {
        guard depth <= 16 else {
            return nil
        }

        var resolved =
            schema

        var activeVisited =
            visited

        if
            let rawReference =
                schema[
                    "$ref"
                ]
        {
            guard
                let reference =
                    rawReference
                        as? String,
                reference
                    .hasPrefix(
                        "#/"
                    ),
                Set(
                    schema.keys
                )
                .isSubset(
                    of: [
                        "$ref",
                        "summary",
                        "description",
                    ]
                ),
                !visited.contains(
                    reference
                ),
                depth < 16,
                let target =
                    localJSONPointerValue(
                        reference,
                        root:
                            root
                    )
                    as? [
                        String:
                        Any
                    ]
            else {
                return nil
            }

            activeVisited.insert(
                reference
            )

            guard
                let targetResolved =
                    resolveSchema(
                        target,
                        root:
                            root,
                        visited:
                            activeVisited,
                        depth:
                            depth + 1
                    )
            else {
                return nil
            }

            resolved =
                targetResolved
        }

        if
            let rawProperties =
                resolved[
                    "properties"
                ]
        {
            guard
                let properties =
                    rawProperties
                        as? [
                            String:
                            Any
                        ]
            else {
                return nil
            }

            var resolvedProperties:
                [
                    String:
                    Any
                ] = [:]

            for (
                name,
                rawChild
            ) in properties
            {
                guard
                    let child =
                        rawChild
                            as? [
                                String:
                                Any
                            ],
                    let resolvedChild =
                        resolveSchema(
                            child,
                            root:
                                root,
                            visited:
                                activeVisited,
                            depth:
                                depth
                        )
                else {
                    return nil
                }

                resolvedProperties[
                    name
                ] =
                    resolvedChild
            }

            resolved[
                "properties"
            ] =
                resolvedProperties
        }

        if
            let rawItems =
                resolved[
                    "items"
                ]
        {
            guard
                let items =
                    rawItems
                        as? [
                            String:
                            Any
                        ],
                let resolvedItems =
                    resolveSchema(
                        items,
                        root:
                            root,
                        visited:
                            activeVisited,
                        depth:
                            depth
                    )
            else {
                return nil
            }

            resolved[
                "items"
            ] =
                resolvedItems
        }

        if
            let rawAdditionalProperties =
                resolved[
                    "additionalProperties"
                ]
        {
            if
                let additionalSchema =
                    rawAdditionalProperties
                        as? [
                            String:
                            Any
                        ]
            {
                guard
                    let resolvedAdditionalSchema =
                        resolveSchema(
                            additionalSchema,
                            root:
                                root,
                            visited:
                                activeVisited,
                            depth:
                                depth
                        )
                else {
                    return nil
                }

                resolved[
                    "additionalProperties"
                ] =
                    resolvedAdditionalSchema
            } else if
                rawAdditionalProperties
                    is Bool
            {
                // Boolean additionalProperties is already a
                // complete schema-policy value.
            } else {
                return nil
            }
        }

        return resolved
    }

    private static func localJSONPointerValue(
        _ reference: String,
        root: [String: Any]
    ) -> Any? {
        guard
            reference
                .hasPrefix(
                    "#/"
                )
        else {
            return nil
        }

        let pointer =
            String(
                reference
                    .dropFirst(
                        2
                    )
            )

        let rawTokens =
            pointer.split(
                separator:
                    "/",
                omittingEmptySubsequences:
                    false
            )

        var current: Any =
            root

        for rawToken in rawTokens {
            guard
                let token =
                    decodeJSONPointerToken(
                        String(
                            rawToken
                        )
                    )
            else {
                return nil
            }

            if
                let object =
                    current
                        as? [String: Any]
            {
                guard
                    let next =
                        object[token]
                else {
                    return nil
                }

                current =
                    next
                continue
            }

            if
                let array =
                    current
                        as? [Any],
                let index =
                    Int(
                        token
                    ),
                index >= 0,
                index < array.count
            {
                current =
                    array[index]
                continue
            }

            return nil
        }

        return current
    }

    private static func decodeJSONPointerToken(
        _ rawToken: String
    ) -> String? {
        guard
            let percentDecoded =
                rawToken
                    .removingPercentEncoding
        else {
            return nil
        }

        let characters =
            Array(
                percentDecoded
            )

        var output =
            ""

        var index =
            0

        while
            index
                < characters.count
        {
            let character =
                characters[index]

            guard
                character == "~"
            else {
                output.append(
                    character
                )

                index += 1
                continue
            }

            guard
                index + 1
                    < characters.count
            else {
                return nil
            }

            let escape =
                characters[
                    index + 1
                ]

            switch escape {
            case "0":
                output.append(
                    "~"
                )

            case "1":
                output.append(
                    "/"
                )

            default:
                return nil
            }

            index += 2
        }

        return output
    }

    private static func supportedJSONSchema(
        _ schema: [String: Any]
    ) -> Bool {
        guard
            let type =
                schema["type"]
                    as? String
        else {
            return false
        }

        return [
            "string",
            "object",
            "array",
        ].contains(type)
    }

    private static func schemaJSONString(
        _ schema: [String: Any]
    ) -> String? {
        guard
            JSONSerialization
                .isValidJSONObject(
                    schema
                ),
            let data =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            schema,
                        options: [
                            .sortedKeys
                        ]
                    )
        else {
            return nil
        }

        return String(
            data: data,
            encoding: .utf8
        )
    }

    private static func prepareRequestBody(
        operation: Operation,
        input: String,
        executionID: String
    ) throws -> PreparedRequestBody {
        if
            operation
                .supportsPlainTextInvocation
        {
            return PreparedRequestBody(
                data:
                    Data(
                        input.utf8
                    ),
                contentType:
                    "text/plain",
                headers:
                    [:]
            )
        }

        guard
            let schema =
                schemaObject(
                    operation
                        .requestSchemaJSON
                )
        else {
            throw RightClickError(
                "The reflected typed request schema is unavailable."
            )
        }

        guard
            let inputData =
                input.data(
                    using: .utf8
                )
        else {
            throw RightClickError(
                "Typed arguments are not valid UTF-8."
            )
        }

        let value: Any

        do {
            value =
                try JSONSerialization
                    .jsonObject(
                        with:
                            inputData,
                        options: [
                            .fragmentsAllowed
                        ]
                    )
        } catch {
            throw RightClickError(
                "Typed arguments must be valid JSON."
            )
        }

        let preparedArguments =
            try prepareTypedArguments(
                value,
                operation:
                    operation
            )

        let bodyValue =
            preparedArguments.body

        switch
            operation
                .requestContentType
        {
        case "application/json":
            try validateJSONValue(
                bodyValue,
                schema:
                    schema,
                path:
                    "$"
            )

            let body =
                try JSONSerialization
                    .data(
                        withJSONObject:
                            bodyValue,
                        options: [
                            .sortedKeys,
                            .fragmentsAllowed
                        ]
                    )

            return PreparedRequestBody(
                data:
                    body,
                contentType:
                    "application/json",
                headers:
                    preparedArguments
                        .headers
            )

        case "multipart/form-data":
            guard
                let object =
                    bodyValue
                        as? [String: Any]
            else {
                throw RightClickError(
                    "Multipart typed arguments must be a JSON object."
                )
            }

            try validateMultipartArguments(
                object,
                schema:
                    schema
            )

            let boundary =
                "RIGHTCLICK-"
                + executionID

            let body =
                try multipartBody(
                    arguments:
                        object,
                    schema:
                        schema,
                    boundary:
                        boundary
                )

            return PreparedRequestBody(
                data:
                    body,
                contentType:
                    "multipart/form-data; boundary="
                    + boundary,
                headers:
                    preparedArguments
                        .headers
            )

        default:
            throw RightClickError(
                "No typed serializer exists for \(operation.requestContentType)."
            )
        }
    }

    private static func prepareTypedArguments(
        _ value: Any,
        operation: Operation
    ) throws -> PreparedTypedArguments {
        guard
            !operation
                .headerParameters
                .isEmpty
        else {
            return PreparedTypedArguments(
                body:
                    value,
                headers:
                    [:]
            )
        }

        var body =
            value

        var rawHeaders:
            [String: Any] = [:]

        if
            let object =
                value
                    as? [String: Any],
            object.keys
                .contains(
                    "body"
                )
        {
            let allowedEnvelopeKeys:
                Set<String> = [
                    "body",
                    "headers",
                ]

            for key in object.keys {
                guard
                    allowedEnvelopeKeys
                        .contains(
                            key
                        )
                else {
                    throw RightClickError(
                        "Unexpected typed argument envelope property \(key)."
                    )
                }
            }

            guard
                let envelopeBody =
                    object[
                        "body"
                    ]
            else {
                throw RightClickError(
                    "Typed argument envelope requires body."
                )
            }

            body =
                envelopeBody

            if
                let headerValue =
                    object[
                        "headers"
                    ]
            {
                guard
                    let objectHeaders =
                        headerValue
                            as? [String: Any]
                else {
                    throw RightClickError(
                        "Typed argument envelope headers must be a JSON object."
                    )
                }

                rawHeaders =
                    objectHeaders
            }
        } else if
            let object =
                value
                    as? [String: Any],
            object.keys
                .contains(
                    "headers"
                )
        {
            throw RightClickError(
                "Typed header arguments require the body + headers envelope."
            )
        }

        let declared =
            Dictionary(
                uniqueKeysWithValues:
                    operation
                    .headerParameters
                    .map {
                        (
                            $0.name
                                .lowercased(),
                            $0
                        )
                    }
            )

        var headers:
            [String: String] = [:]

        var seen =
            Set<String>()

        for (
            suppliedName,
            rawValue
        ) in rawHeaders {
            let identity =
                suppliedName
                    .lowercased()

            guard
                let parameter =
                    declared[
                        identity
                    ]
            else {
                throw RightClickError(
                    "Undeclared or unsupported header \(suppliedName)."
                )
            }

            guard
                seen
                    .insert(
                        identity
                    )
                    .inserted
            else {
                throw RightClickError(
                    "Duplicate header \(suppliedName)."
                )
            }

            guard
                let stringValue =
                    rawValue
                        as? String
            else {
                throw RightClickError(
                    "Declared header \(parameter.name) requires a string value."
                )
            }

            try validateHeaderValue(
                stringValue,
                parameter:
                    parameter
            )

            headers[
                parameter.name
            ] = stringValue
        }

        for parameter
            in operation
                .headerParameters
        {
            guard
                parameter.required
            else {
                continue
            }

            let supplied =
                headers.keys
                    .contains {
                        $0.caseInsensitiveCompare(
                            parameter.name
                        ) == .orderedSame
                    }

            guard supplied else {
                throw RightClickError(
                    "Missing required header \(parameter.name)."
                )
            }
        }

        return PreparedTypedArguments(
            body:
                body,
            headers:
                headers
        )
    }

    private static func validateHeaderValue(
        _ value: String,
        parameter:
            HeaderParameterContract
    ) throws {
        guard
            !value.contains("\r"),
            !value.contains("\n")
        else {
            throw RightClickError(
                "Header \(parameter.name) contains a forbidden line break."
            )
        }

        let length =
            value
                .unicodeScalars
                .count

        if
            let minimum =
                (
                    parameter
                        .schema[
                            "minLength"
                        ]
                    as? NSNumber
                )?
                .intValue,
            length < minimum
        {
            throw RightClickError(
                "Header \(parameter.name) violates minLength \(minimum)."
            )
        }

        if
            let maximum =
                (
                    parameter
                        .schema[
                            "maxLength"
                        ]
                    as? NSNumber
                )?
                .intValue,
            length > maximum
        {
            throw RightClickError(
                "Header \(parameter.name) violates maxLength \(maximum)."
            )
        }

        if
            let pattern =
                parameter
                    .schema[
                        "pattern"
                    ] as? String
        {
            let expression:
                NSRegularExpression

            do {
                expression =
                    try NSRegularExpression(
                        pattern:
                            pattern
                    )
            } catch {
                throw RightClickError(
                    "Header \(parameter.name) declares an invalid pattern."
                )
            }

            let range =
                NSRange(
                    value.startIndex
                        ..<
                        value.endIndex,
                    in:
                        value
                )

            guard
                expression
                    .firstMatch(
                        in:
                            value,
                        options:
                            [],
                        range:
                            range
                    )
                    != nil
            else {
                throw RightClickError(
                    "Header \(parameter.name) violates pattern \(pattern)."
                )
            }
        }
    }

    private static func schemaObject(
        _ raw: String?
    ) -> [String: Any]? {
        guard
            let raw,
            let data =
                raw.data(
                    using: .utf8
                ),
            let value =
                try? JSONSerialization
                    .jsonObject(
                        with:
                            data
                    ),
            let object =
                value
                    as? [String: Any]
        else {
            return nil
        }

        return object
    }

    private static func isJSONBoolean(
        _ number: NSNumber
    ) -> Bool {
        CFGetTypeID(
            number as CFTypeRef
        ) == CFBooleanGetTypeID()
    }

    private static func schemaNonNegativeInteger(
        _ raw: Any?,
        keyword: String,
        path: String
    ) throws -> Int? {
        guard let raw else {
            return nil
        }

        guard
            let number =
                raw as? NSNumber,
            !isJSONBoolean(
                number
            ),
            floor(
                number.doubleValue
            ) == number.doubleValue,
            number.doubleValue >= 0,
            number.doubleValue
                <= Double(
                    Int.max
                )
        else {
            throw RightClickError(
                "Schema \(keyword) must be a non-negative integer at \(path)."
            )
        }

        return number.intValue
    }

    private static func schemaNumber(
        _ raw: Any?,
        keyword: String,
        path: String
    ) throws -> Double? {
        guard let raw else {
            return nil
        }

        guard
            let number =
                raw as? NSNumber,
            !isJSONBoolean(
                number
            )
        else {
            throw RightClickError(
                "Schema \(keyword) must be numeric at \(path)."
            )
        }

        return number.doubleValue
    }

    private static func validateStringConstraints(
        _ value: String,
        schema: [String: Any],
        path: String
    ) throws {
        let length =
            value
                .unicodeScalars
                .count

        if
            let minimum =
                try schemaNonNegativeInteger(
                    schema[
                        "minLength"
                    ],
                    keyword:
                        "minLength",
                    path:
                        path
                ),
            length < minimum
        {
            throw RightClickError(
                "String at \(path) violates minLength \(minimum)."
            )
        }

        if
            let maximum =
                try schemaNonNegativeInteger(
                    schema[
                        "maxLength"
                    ],
                    keyword:
                        "maxLength",
                    path:
                        path
                ),
            length > maximum
        {
            throw RightClickError(
                "String at \(path) violates maxLength \(maximum)."
            )
        }

        if
            let rawPattern =
                schema[
                    "pattern"
                ]
        {
            guard
                let pattern =
                    rawPattern
                        as? String
            else {
                throw RightClickError(
                    "Schema pattern must be a string at \(path)."
                )
            }

            let expression:
                NSRegularExpression

            do {
                expression =
                    try NSRegularExpression(
                        pattern:
                            pattern
                    )
            } catch {
                throw RightClickError(
                    "Schema pattern is invalid at \(path)."
                )
            }

            let range =
                NSRange(
                    value.startIndex
                        ..<
                        value.endIndex,
                    in:
                        value
                )

            guard
                expression
                    .firstMatch(
                        in:
                            value,
                        options:
                            [],
                        range:
                            range
                    )
                    != nil
            else {
                throw RightClickError(
                    "String at \(path) violates pattern \(pattern)."
                )
            }
        }
    }

    private static func validateArrayConstraints(
        _ value: [Any],
        schema: [String: Any],
        path: String
    ) throws {
        if
            let minimum =
                try schemaNonNegativeInteger(
                    schema[
                        "minItems"
                    ],
                    keyword:
                        "minItems",
                    path:
                        path
                ),
            value.count < minimum
        {
            throw RightClickError(
                "Array at \(path) violates minItems \(minimum)."
            )
        }

        if
            let maximum =
                try schemaNonNegativeInteger(
                    schema[
                        "maxItems"
                    ],
                    keyword:
                        "maxItems",
                    path:
                        path
                ),
            value.count > maximum
        {
            throw RightClickError(
                "Array at \(path) violates maxItems \(maximum)."
            )
        }
    }

    private static func validateNumericConstraints(
        _ number: NSNumber,
        schema: [String: Any],
        path: String
    ) throws {
        if
            let minimum =
                try schemaNumber(
                    schema[
                        "minimum"
                    ],
                    keyword:
                        "minimum",
                    path:
                        path
                ),
            number.doubleValue
                < minimum
        {
            throw RightClickError(
                "Number at \(path) violates minimum \(minimum)."
            )
        }

        if
            let maximum =
                try schemaNumber(
                    schema[
                        "maximum"
                    ],
                    keyword:
                        "maximum",
                    path:
                        path
                ),
            number.doubleValue
                > maximum
        {
            throw RightClickError(
                "Number at \(path) violates maximum \(maximum)."
            )
        }
    }

    private static func validateJSONValue(
        _ value: Any,
        schema: [String: Any],
        path: String
    ) throws {
        guard
            let type =
                schema["type"]
                    as? String
        else {
            throw RightClickError(
                "Schema type is missing at \\(path)."
            )
        }

        switch type {
        case "string":
            guard
                let string = value as? String
            else {
                throw RightClickError(
                    "Expected string at \\(path)."
                )
            }

            try validateStringConstraints(
                string,
                schema:
                    schema,
                path:
                    path
            )

        case "object":
            guard
                let object =
                    value
                        as? [String: Any]
            else {
                throw RightClickError(
                    "Expected object at \\(path)."
                )
            }

            let required =
                schema["required"]
                    as? [String]
                ?? []

            for key in required {
                guard
                    object[key]
                        != nil
                else {
                    throw RightClickError(
                        "Missing required property \\(path).\\(key)."
                    )
                }
            }

            let properties =
                schema["properties"]
                    as? [
                        String:
                        Any
                    ]
                ?? [:]

            if
                schema[
                    "additionalProperties"
                ] as? Bool
                    == false
            {
                let allowed =
                    Set(
                        properties.keys
                    )

                for key in object.keys {
                    guard
                        allowed
                            .contains(
                                key
                            )
                    else {
                        throw RightClickError(
                            "Unexpected property \\(path).\\(key)."
                        )
                    }
                }
            }

            for (
                key,
                child
            ) in object {
                guard
                    let childSchema =
                        properties[key]
                            as? [
                                String:
                                Any
                            ]
                else {
                    continue
                }

                try validateJSONValue(
                    child,
                    schema:
                        childSchema,
                    path:
                        path
                        + "."
                        + key
                )
            }

        case "array":
            guard
                let array =
                    value
                        as? [Any]
            else {
                throw RightClickError(
                    "Expected array at \\(path)."
                )
            }

            try validateArrayConstraints(
                array,
                schema:
                    schema,
                path:
                    path
            )

            if
                let itemSchema =
                    schema["items"]
                        as? [
                            String:
                            Any
                        ]
            {
                for (
                    index,
                    child
                ) in array
                    .enumerated()
                {
                    try validateJSONValue(
                        child,
                        schema:
                            itemSchema,
                        path:
                            "\\(path)[\\(index)]"
                    )
                }
            }

        case "boolean":
            guard
                value is Bool
            else {
                throw RightClickError(
                    "Expected boolean at \\(path)."
                )
            }

        case "integer":
            guard
                let number =
                    value
                        as? NSNumber,
                !isJSONBoolean(number),
                floor(
                    number.doubleValue
                )
                    == number.doubleValue
            else {
                throw RightClickError(
                    "Expected integer at \\(path)."
                )
            }

            try validateNumericConstraints(
                number,
                schema:
                    schema,
                path:
                    path
            )

        case "number":
            guard
                value is NSNumber,
                !(value is Bool)
            else {
                throw RightClickError(
                    "Expected number at \\(path)."
                )
            }

        default:
            throw RightClickError(
                "Unsupported schema type \\(type) at \\(path)."
            )
        }
    }

    private static func validateMultipartArguments(
        _ arguments: [String: Any],
        schema: [String: Any]
    ) throws {
        guard
            schema["type"]
                as? String
                == "object"
        else {
            throw RightClickError(
                "Multipart schema must be an object."
            )
        }

        let required =
            schema["required"]
                as? [String]
            ?? []

        for key in required {
            guard
                arguments[key]
                    != nil
            else {
                throw RightClickError(
                    "Missing required multipart field \\(key)."
                )
            }
        }

        let properties =
            schema["properties"]
                as? [
                    String:
                    Any
                ]
            ?? [:]

        if
            schema[
                "additionalProperties"
            ] as? Bool
                == false
        {
            let allowed =
                Set(
                    properties.keys
                )

            for key in arguments.keys {
                guard
                    allowed
                        .contains(
                            key
                        )
                else {
                    throw RightClickError(
                        "Unexpected multipart field \\(key)."
                    )
                }
            }
        }

        for (
            key,
            value
        ) in arguments {
            guard
                let property =
                    properties[key]
                        as? [
                            String:
                            Any
                        ]
            else {
                continue
            }

            let isBinary =
                property["type"]
                    as? String
                    == "string"
                && property[
                    "format"
                ] as? String
                    == "binary"

            if isBinary {
                guard
                    let descriptor =
                        value
                            as? [
                                String:
                                Any
                            ],
                    let filename =
                        descriptor[
                            "filename"
                        ] as? String,
                    !filename.isEmpty
                else {
                    throw RightClickError(
                        "Binary multipart field \\(key) requires a filename."
                    )
                }

                let textValue =
                    descriptor[
                        "text"
                    ] as? String

                let base64Value =
                    descriptor[
                        "base64"
                    ] as? String

                guard
                    (textValue != nil)
                    != (base64Value != nil)
                else {
                    throw RightClickError(
                        "Binary multipart field \\(key) requires exactly one of text or base64."
                    )
                }

                if
                    let base64Value,
                    Data(
                        base64Encoded:
                            base64Value
                    ) == nil
                {
                    throw RightClickError(
                        "Binary multipart field \\(key) contains invalid base64."
                    )
                }

                continue
            }

            try validateJSONValue(
                value,
                schema:
                    property,
                path:
                    "$."
                    + key
            )
        }
    }

    private static func multipartBody(
        arguments: [String: Any],
        schema: [String: Any],
        boundary: String
    ) throws -> Data {
        let properties =
            schema["properties"]
                as? [
                    String:
                    Any
                ]
            ?? [:]

        var body =
            Data()

        func appendString(
            _ value: String
        ) {
            body.append(
                contentsOf:
                    value.utf8
            )
        }

        for key in arguments.keys.sorted() {
            guard
                let value =
                    arguments[key],
                let property =
                    properties[key]
                        as? [
                            String:
                            Any
                        ]
            else {
                continue
            }

            let isBinary =
                property["type"]
                    as? String
                    == "string"
                && property[
                    "format"
                ] as? String
                    == "binary"

            appendString(
                "--"
                + boundary
                + "\r\n"
            )

            let escapedName =
                multipartHeaderValue(
                    key
                )

            if isBinary {
                guard
                    let descriptor =
                        value
                            as? [
                                String:
                                Any
                            ],
                    let filename =
                        descriptor[
                            "filename"
                        ] as? String
                else {
                    throw RightClickError(
                        "Invalid binary multipart descriptor for \\(key)."
                    )
                }

                let escapedFilename =
                    multipartHeaderValue(
                        filename
                    )

                let contentType =
                    (
                        descriptor[
                            "contentType"
                        ] as? String
                    )
                    ?? "application/octet-stream"

                appendString(
                    "Content-Disposition: form-data; name=\""
                    + escapedName
                    + "\"; filename=\""
                    + escapedFilename
                    + "\"\r\n"
                )

                appendString(
                    "Content-Type: "
                    + contentType
                    + "\r\n\r\n"
                )

                if
                    let textValue =
                        descriptor[
                            "text"
                        ] as? String
                {
                    body.append(
                        contentsOf:
                            textValue.utf8
                    )
                } else if
                    let base64Value =
                        descriptor[
                            "base64"
                        ] as? String,
                    let binaryData =
                        Data(
                            base64Encoded:
                                base64Value
                        )
                {
                    body.append(
                        binaryData
                    )
                } else {
                    throw RightClickError(
                        "Multipart binary field \\(key) has no payload."
                    )
                }

                appendString(
                    "\r\n"
                )
            } else {
                appendString(
                    "Content-Disposition: form-data; name=\""
                    + escapedName
                    + "\"\r\n\r\n"
                )

                guard
                    let stringValue =
                        value as? String
                else {
                    throw RightClickError(
                        "Multipart field \\(key) currently requires a string value."
                    )
                }

                appendString(
                    stringValue
                )

                appendString(
                    "\r\n"
                )
            }
        }

        appendString(
            "--"
            + boundary
            + "--\r\n"
        )

        return body
    }

    private static func multipartHeaderValue(
        _ value: String
    ) -> String {
        value
            .replacingOccurrences(
                of:
                    "\\",
                with:
                    "\\\\"
            )
            .replacingOccurrences(
                of:
                    "\"",
                with:
                    "\\\""
            )
            .replacingOccurrences(
                of:
                    "\r",
                with:
                    ""
            )
            .replacingOccurrences(
                of:
                    "\n",
                with:
                    ""
            )
    }

    private static func sha256Hex(
        _ data: Data
    ) -> String {
        SHA256
            .hash(data: data)
            .map {
                String(
                    format: "%02x",
                    $0
                )
            }
            .joined()
    }

    private static let identifierCharacters:
        CharacterSet = {
            var value =
                CharacterSet.alphanumerics

            value.insert(
                charactersIn:
                    "-._~"
            )

            return value
        }()
}
