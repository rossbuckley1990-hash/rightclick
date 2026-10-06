import CryptoKit
import Foundation

public final class OpenAPIReflector: CapabilityReflector {
    private struct JSONStringProperty {
        let allowedValues: Set<String>?
    }

    private struct JSONObjectSchema {
        let required: Set<String>
        let properties:
            [String: JSONStringProperty]
        let canonicalJSON: String
    }

    private struct Operation {
        let capabilityID: String
        let operationID: String
        let title: String
        let method: String
        let path: String

        let requestContentType:
            String?

        let responseContentType:
            String

        let requestJSONSchema:
            JSONObjectSchema?

        let pathArgumentsSchema:
            JSONObjectSchema?

        let responseJSONSchema:
            JSONObjectSchema?
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

    private let operations: [Operation]
    private let operationByCapabilityID:
        [String: Operation]

    public init(
        specificationData: Data,
        baseURL: URL,
        session: URLSession = .shared
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

            let outputType =
                operation
                    .responseContentType
                    == "application/json"
                ? "public.json"
                : "public.plain-text"

            let policy =
                SafetyPolicy.classify(
                    title:
                        operation.title,
                    source: .system,
                    sendTypes: [
                        "public.plain-text"
                    ],
                    returnTypes: [
                        outputType
                    ]
                )

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
                    "responseContentType":
                        operation
                            .responseContentType,
                ]

            if let requestContentType =
                operation.requestContentType
            {
                metadata[
                    "requestContentType"
                ] =
                    requestContentType
            }

            if let schema =
                operation.requestJSONSchema
                    ?? operation.pathArgumentsSchema
            {
                metadata[
                    "argumentsSchema"
                ] =
                    schema.canonicalJSON
            }

            if let schema =
                operation.responseJSONSchema
            {
                metadata[
                    "resultSchema"
                ] =
                    schema.canonicalJSON
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
                inputs: [
                    "public.plain-text"
                ],
                output: [
                    outputType
                ],
                safety:
                    policy.safety,
                invocation:
                    policy.invocation,
                supportLevel:
                    .experimental,
                requiresConfirmation:
                    policy
                        .requiresConfirmation,
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
        try begin(
            capability: capability,
            item: item,
            executionID: executionID,
            arguments: nil
        )
    }

    public func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments: CapabilityArguments?
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

        let requestBody:
            Data?

        let targetPath:
            String

        if let pathSchema =
            operation.pathArgumentsSchema
        {
            guard
                let arguments
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
                        "Path capability arguments are required.",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "input_contract_failure",
                            boundary:
                                "The reflected OpenAPI path template requires structured arguments before transport."
                        )
                )
            }

            do {
                targetPath =
                    try Self.substitutedPath(
                        operation.path,
                        arguments:
                            arguments,
                        schema:
                            pathSchema
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
                        "Path capability arguments failed schema validation: \(error)",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "input_contract_failure",
                            boundary:
                                "RIGHTCLICK rejected path arguments before provider transport because they did not satisfy the reflected closed path-parameter schema."
                        )
                )
            }

            requestBody =
                nil

        } else if
            operation.requestContentType
                == "text/plain"
        {
            guard
                let text =
                    item.text
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

            targetPath =
                operation.path

            requestBody =
                Data(text.utf8)

        } else if
            operation.requestContentType
                == "application/json",
            let schema =
                operation.requestJSONSchema
        {
            guard
                let arguments
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
                        "Structured capability arguments are required.",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "input_contract_failure",
                            boundary:
                                "The reflected application/json request schema requires structured arguments before transport."
                        )
                )
            }

            do {
                requestBody =
                    try Self
                    .validatedJSONObjectBody(
                        arguments,
                        schema:
                            schema
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
                        "Structured capability arguments failed schema validation: \(error)",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "input_contract_failure",
                            boundary:
                                "RIGHTCLICK rejected structured arguments before provider transport because they did not satisfy the reflected closed JSON object schema."
                        )
                )
            }

            targetPath =
                operation.path

        } else {
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
                    "The reflected OpenAPI request contract is unavailable.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "input_contract_failure",
                        boundary:
                            "RIGHTCLICK had no supported request representation for this reflected operation."
                    )
            )
        }

        let targetURL =
            try joinedURL(
                path:
                    targetPath,
                percentEncoded:
                    operation
                        .pathArgumentsSchema
                        != nil
            )

        var request =
            URLRequest(
                url: targetURL
            )

        request.httpMethod =
            operation.method

        request.httpBody =
            requestBody

        if let requestContentType =
            operation.requestContentType
        {
            request.setValue(
                requestContentType,
                forHTTPHeaderField:
                    "Content-Type"
            )
        }

        request.setValue(
            operation.responseContentType,
            forHTTPHeaderField:
                "Accept"
        )

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

        let output:
            String?

        if operation.responseContentType
            == "text/plain"
        {
            if mediaType == "text/plain" {
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

        } else if
            operation.responseContentType
                == "application/json",
            let schema =
                operation.responseJSONSchema
        {
            guard
                mediaType
                    == "application/json"
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
                        "The OpenAPI provider returned an unexpected response content type.",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "provider_contract_failure",
                            boundary:
                                "The provider returned a 2xx response whose media type did not match the reflected application/json response contract."
                        )
                )
            }

            do {
                output =
                    try Self
                    .canonicalValidatedJSONObject(
                        responseData,
                        schema:
                            schema
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
                        "The OpenAPI provider response failed the reflected JSON schema: \(error)",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "provider_contract_failure",
                            boundary:
                                "The provider returned 2xx, but its application/json body did not satisfy the reflected closed JSON object schema."
                        )
                )
            }

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
                        : "provider_returned_text",
                    boundary:
                        "A 2xx HTTP response establishes provider acceptance only. The intended semantic outcome has not been independently verified.",
                    outcomeVerified:
                        false
                )
        )
    }

    private func joinedURL(
        path operationPath: String,
        percentEncoded: Bool = false
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
            percentEncoded
            ? components.percentEncodedPath
            : components.path

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

        if percentEncoded {
            components.percentEncodedPath =
                basePath + suffix
        } else {
            components.path =
                basePath + suffix
        }

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

                let requestContentType:
                    String?

                let responseContentType:
                    String

                let requestJSONSchema:
                    JSONObjectSchema?

                let pathArgumentsSchema:
                    JSONObjectSchema?

                let responseJSONSchema:
                    JSONObjectSchema?

                if method == "get" {
                    guard
                        let pathSchema =
                            supportedGETPathArgumentSchema(
                                path:
                                    path,
                                pathObject:
                                    pathObject,
                                operation:
                                    operation
                            ),
                        let responseSchema =
                            supportedJSONObjectResponseSchema(
                                operation
                            )
                    else {
                        continue
                    }

                    requestContentType =
                        nil

                    responseContentType =
                        "application/json"

                    requestJSONSchema =
                        nil

                    pathArgumentsSchema =
                        pathSchema

                    responseJSONSchema =
                        responseSchema

                } else {
                    guard
                        !path.contains("{"),
                        !path.contains("}")
                    else {
                        continue
                    }

                    pathArgumentsSchema =
                        nil

                    if
                        supportsPlainTextRequest(
                            operation
                        ),
                        supportsPlainTextResponse(
                            operation
                        )
                    {
                        requestContentType =
                            "text/plain"

                        responseContentType =
                            "text/plain"

                        requestJSONSchema =
                            nil

                        responseJSONSchema =
                            nil

                    } else if
                        let requestSchema =
                            supportedJSONObjectRequestSchema(
                                operation
                            ),
                        let responseSchema =
                            supportedJSONObjectResponseSchema(
                                operation
                            )
                    {
                        requestContentType =
                            "application/json"

                        responseContentType =
                            "application/json"

                        requestJSONSchema =
                            requestSchema

                        responseJSONSchema =
                            responseSchema

                    } else {
                        continue
                    }
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
                            requestContentType,
                        responseContentType:
                            responseContentType,
                        requestJSONSchema:
                            requestJSONSchema,
                        pathArgumentsSchema:
                            pathArgumentsSchema,
                        responseJSONSchema:
                            responseJSONSchema
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

    private static func supportedGETPathArgumentSchema(
        path: String,
        pathObject: [String: Any],
        operation: [String: Any]
    ) -> JSONObjectSchema? {
        guard
            pathObject["parameters"] == nil,
            operation["requestBody"] == nil,
            let parameters =
                operation["parameters"]
                    as? [[String: Any]],
            parameters.count == 1,
            let parameter =
                parameters.first
        else {
            return nil
        }

        let allowedParameterKeys:
            Set<String> = [
                "name",
                "in",
                "required",
                "schema",
                "description",
            ]

        guard
            Set(parameter.keys)
                .isSubset(
                    of:
                        allowedParameterKeys
                ),
            let name =
                parameter["name"]
                    as? String,
            !name.isEmpty,
            !name.contains("{"),
            !name.contains("}"),
            !name.contains("/"),
            parameter["in"]
                as? String == "path",
            parameter["required"]
                as? Bool == true,
            let schema =
                parameter["schema"]
                    as? [String: Any]
        else {
            return nil
        }

        let allowedSchemaKeys:
            Set<String> = [
                "type",
                "title",
                "description",
            ]

        guard
            Set(schema.keys)
                .isSubset(
                    of:
                        allowedSchemaKeys
                ),
            schema["type"]
                as? String == "string"
        else {
            return nil
        }

        let token =
            "{\(name)}"

        let pieces =
            path.components(
                separatedBy:
                    token
            )

        guard
            pieces.count == 2,
            !pieces[0].contains("{"),
            !pieces[0].contains("}"),
            !pieces[1].contains("{"),
            !pieces[1].contains("}")
        else {
            return nil
        }

        let argumentsSchema:
            [String: Any] = [
                "type":
                    "object",
                "additionalProperties":
                    false,
                "required": [
                    name
                ],
                "properties": [
                    name: [
                        "type":
                            "string"
                    ]
                ],
            ]

        return parseClosedJSONStringObjectSchema(
            argumentsSchema
        )
    }

    private static func supportsPlainTextRequest(
        _ operation: [String: Any]
    ) -> Bool {
        guard
            let requestBody =
                operation["requestBody"]
                    as? [String: Any],
            requestBody["required"]
                as? Bool == true,
            let content =
                requestBody["content"]
                    as? [String: Any],
            let text =
                content["text/plain"]
                    as? [String: Any],
            let schema =
                text["schema"]
                    as? [String: Any],
            schema["type"]
                as? String == "string"
        else {
            return false
        }

        return true
    }

    private static func supportsPlainTextResponse(
        _ operation: [String: Any]
    ) -> Bool {
        guard
            let responses =
                operation["responses"]
                    as? [String: Any]
        else {
            return false
        }

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
                        as? [String: Any],
                let text =
                    content["text/plain"]
                        as? [String: Any],
                let schema =
                    text["schema"]
                        as? [String: Any],
                schema["type"]
                    as? String == "string"
            else {
                continue
            }

            return true
        }

        return false
    }

    private static func supportedJSONObjectRequestSchema(
        _ operation:
            [String: Any]
    ) -> JSONObjectSchema? {
        guard
            let requestBody =
                operation["requestBody"]
                    as? [String: Any],
            requestBody["required"]
                as? Bool == true,
            let content =
                requestBody["content"]
                    as? [String: Any],
            let json =
                content[
                    "application/json"
                ] as? [String: Any],
            let rawSchema =
                json["schema"]
                    as? [String: Any]
        else {
            return nil
        }

        return parseClosedJSONStringObjectSchema(
            rawSchema
        )
    }

    private static func supportedJSONObjectResponseSchema(
        _ operation:
            [String: Any]
    ) -> JSONObjectSchema? {
        guard
            let responses =
                operation["responses"]
                    as? [String: Any]
        else {
            return nil
        }

        for key
            in responses.keys.sorted()
        {
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
                        as? [String: Any],
                let json =
                    content[
                        "application/json"
                    ] as? [String: Any],
                let rawSchema =
                    json["schema"]
                        as? [String: Any],
                let schema =
                    parseClosedJSONStringObjectSchema(
                        rawSchema
                    )
            else {
                continue
            }

            return schema
        }

        return nil
    }

    private static func parseClosedJSONStringObjectSchema(
        _ schema:
            [String: Any]
    ) -> JSONObjectSchema? {
        let allowedObjectKeys:
            Set<String> = [
                "type",
                "additionalProperties",
                "required",
                "properties",
                "title",
                "description",
            ]

        guard
            Set(schema.keys)
                .isSubset(
                    of:
                        allowedObjectKeys
                ),
            schema["type"]
                as? String == "object",
            schema[
                "additionalProperties"
            ] as? Bool == false,
            let rawRequired =
                schema["required"]
                    as? [String],
            !rawRequired.isEmpty,
            Set(rawRequired).count
                == rawRequired.count,
            let rawProperties =
                schema["properties"]
                    as? [String: Any],
            !rawProperties.isEmpty
        else {
            return nil
        }

        let required =
            Set(rawRequired)

        guard
            required.isSubset(
                of:
                    Set(
                        rawProperties.keys
                    )
            )
        else {
            return nil
        }

        var properties:
            [String: JSONStringProperty] =
                [:]

        for key
            in rawProperties.keys.sorted()
        {
            guard
                !key.isEmpty,
                let raw =
                    rawProperties[key]
                        as? [String: Any]
            else {
                return nil
            }

            let allowedPropertyKeys:
                Set<String> = [
                    "type",
                    "enum",
                    "title",
                    "description",
                ]

            guard
                Set(raw.keys)
                    .isSubset(
                        of:
                            allowedPropertyKeys
                    ),
                raw["type"]
                    as? String
                    == "string"
            else {
                return nil
            }

            let allowedValues:
                Set<String>?

            if let rawEnum =
                raw["enum"]
            {
                guard
                    let values =
                        rawEnum
                            as? [String],
                    !values.isEmpty,
                    Set(values).count
                        == values.count
                else {
                    return nil
                }

                allowedValues =
                    Set(values)
            } else {
                allowedValues =
                    nil
            }

            properties[key] =
                JSONStringProperty(
                    allowedValues:
                        allowedValues
                )
        }

        guard
            JSONSerialization
                .isValidJSONObject(
                    schema
                ),
            let canonicalData =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            schema,
                        options: [
                            .sortedKeys
                        ]
                    ),
            let canonicalJSON =
                String(
                    data:
                        canonicalData,
                    encoding:
                        .utf8
                )
        else {
            return nil
        }

        return JSONObjectSchema(
            required:
                required,
            properties:
                properties,
            canonicalJSON:
                canonicalJSON
        )
    }

    private static func validateArguments(
        _ arguments:
            CapabilityArguments,
        schema:
            JSONObjectSchema
    ) throws {
        let supplied =
            Set(arguments.keys)

        let missing =
            schema.required
                .subtracting(
                    supplied
                )

        guard missing.isEmpty else {
            throw RightClickError(
                "Missing required arguments: "
                + missing.sorted()
                    .joined(
                        separator: ", "
                    )
            )
        }

        let unknown =
            supplied
                .subtracting(
                    Set(
                        schema
                            .properties
                            .keys
                    )
                )

        guard unknown.isEmpty else {
            throw RightClickError(
                "Unknown arguments: "
                + unknown.sorted()
                    .joined(
                        separator: ", "
                    )
            )
        }

        for key
            in arguments.keys.sorted()
        {
            guard
                let property =
                    schema.properties[
                        key
                    ],
                let value =
                    arguments[key]
            else {
                throw RightClickError(
                    "Argument schema lookup failed."
                )
            }

            if let allowed =
                property.allowedValues,
                !allowed.contains(value)
            {
                throw RightClickError(
                    "Argument \(key) is not one of the declared enum values."
                )
            }
        }
    }

    private static func substitutedPath(
        _ template: String,
        arguments:
            CapabilityArguments,
        schema:
            JSONObjectSchema
    ) throws -> String {
        try validateArguments(
            arguments,
            schema:
                schema
        )

        var result =
            template

        for name
            in schema.required.sorted()
        {
            guard
                let value =
                    arguments[name]
            else {
                throw RightClickError(
                    "Missing required path argument."
                )
            }

            let token =
                "{\(name)}"

            let occurrences =
                result.components(
                    separatedBy:
                        token
                )

            guard
                occurrences.count == 2
            else {
                throw RightClickError(
                    "Path template does not contain exactly one matching placeholder."
                )
            }

            guard
                let encoded =
                    value.addingPercentEncoding(
                        withAllowedCharacters:
                            identifierCharacters
                    )
            else {
                throw RightClickError(
                    "Could not percent-encode path argument."
                )
            }

            result =
                result.replacingOccurrences(
                    of:
                        token,
                    with:
                        encoded
                )
        }

        guard
            !result.contains("{"),
            !result.contains("}")
        else {
            throw RightClickError(
                "Unresolved path placeholders remain."
            )
        }

        return result
    }

    private static func validatedJSONObjectBody(
        _ arguments:
            CapabilityArguments,
        schema:
            JSONObjectSchema
    ) throws -> Data {
        try validateArguments(
            arguments,
            schema:
                schema
        )

        guard
            JSONSerialization
                .isValidJSONObject(
                    arguments
                )
        else {
            throw RightClickError(
                "Structured arguments are not valid JSON."
            )
        }

        return try JSONSerialization
            .data(
                withJSONObject:
                    arguments,
                options: [
                    .sortedKeys
                ]
            )
    }

    private static func canonicalValidatedJSONObject(
        _ data:
            Data,
        schema:
            JSONObjectSchema
    ) throws -> String {
        guard
            let object =
                try JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as? [String: Any]
        else {
            throw RightClickError(
                "Expected a JSON object response."
            )
        }

        let supplied =
            Set(object.keys)

        let missing =
            schema.required
                .subtracting(
                    supplied
                )

        guard missing.isEmpty else {
            throw RightClickError(
                "Response is missing required fields."
            )
        }

        let unknown =
            supplied
                .subtracting(
                    Set(
                        schema
                            .properties
                            .keys
                    )
                )

        guard unknown.isEmpty else {
            throw RightClickError(
                "Response contains undeclared fields."
            )
        }

        var canonical:
            [String: String] = [:]

        for key
            in object.keys.sorted()
        {
            guard
                let property =
                    schema.properties[
                        key
                    ],
                let value =
                    object[key]
                        as? String
            else {
                throw RightClickError(
                    "Response field \(key) is not a declared string."
                )
            }

            if let allowed =
                property.allowedValues,
                !allowed.contains(value)
            {
                throw RightClickError(
                    "Response field \(key) is outside its declared enum."
                )
            }

            canonical[key] =
                value
        }

        let canonicalData =
            try JSONSerialization
                .data(
                    withJSONObject:
                        canonical,
                    options: [
                        .sortedKeys,
                        .withoutEscapingSlashes
                    ]
                )

        guard
            let string =
                String(
                    data:
                        canonicalData,
                    encoding:
                        .utf8
                )
        else {
            throw RightClickError(
                "Could not encode canonical JSON response."
            )
        }

        return string
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
