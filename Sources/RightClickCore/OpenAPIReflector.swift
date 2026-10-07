import CryptoKit
import Foundation

public final class OpenAPIReflector: RCIRExecutionReflector, CapabilityContractRefreshingReflector {
    private struct JSONStringProperty {
        let allowedValues: Set<String>?
    }

    private struct JSONObjectSchema {
        let required: Set<String>
        let properties:
            [String: JSONStringProperty]
        let canonicalJSON: String
        let multiSegmentPathArguments:
            Set<String>

        init(
            required: Set<String>,
            properties:
                [String: JSONStringProperty],
            canonicalJSON: String,
            multiSegmentPathArguments:
                Set<String> = []
        ) {
            self.required =
                required

            self.properties =
                properties

            self.canonicalJSON =
                canonicalJSON

            self.multiSegmentPathArguments =
                multiSegmentPathArguments
        }
    }

    private enum AuthorityResolution {
        case publicAccess
        case required(
            OpenAPIAuthorityRequirement
        )
        case unsupported
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

        let zeroArgumentGET:
            Bool

        let responseJSONSchema:
            JSONObjectSchema?

        let responseJSONSyntaxOnly:
            Bool

        let authorityRequirement:
            OpenAPIAuthorityRequirement?
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

    private let standaloneHost = RCIRExecutionHost()
    private let baseURL: URL
    private let providerName: String
    private let providerFingerprint: String
    private let specificationSHA256: String
    private let revalidateSpecification: (() throws -> Data)?
    private let externalBearerSchemeName: String?
    private let freshnessLock = NSLock()
    private var staleContract = false
    private let session: URLSession

    private let operations: [Operation]
    private let operationByCapabilityID:
        [String: Operation]

    public init(
        specificationData: Data,
        baseURL: URL,
        externalBearerSchemeName:
            String? = nil,
        session: URLSession = .shared,
        revalidateSpecification: (() throws -> Data)? = nil
    ) throws {
        let canonicalBaseURL =
            try Self.canonicalBaseURL(
                baseURL
            )

        let resolvedExternalBearerSchemeName =
            try Self.validatedExternalBearerSchemeName(
                externalBearerSchemeName
            )

        try Self
            .validateDeclaredServerBinding(
                specificationData,
                baseURL:
                    canonicalBaseURL
            )

        let specificationSHA256 =
            Self.sha256Hex(
                specificationData
            )

        var providerIdentity =
            canonicalBaseURL.absoluteString
            + "\n"
            + specificationSHA256

        if let resolvedExternalBearerSchemeName {
            providerIdentity +=
                "\nauth-scheme:"
                + resolvedExternalBearerSchemeName
        }

        let providerIdentityMaterial =
            Data(
                providerIdentity.utf8
            )

        let providerFingerprint =
            Self.sha256Hex(
                providerIdentityMaterial
            )

        let authorityOrigin =
            try Self.canonicalAuthorityOrigin(
                canonicalBaseURL
            )

        let parsed =
            try Self.parseSpecification(
                specificationData,
                providerFingerprint:
                    providerFingerprint,
                authorityOrigin:
                    authorityOrigin,
                externalBearerSchemeName:
                    resolvedExternalBearerSchemeName
            )

        self.baseURL =
            canonicalBaseURL

        self.providerName =
            parsed.providerName

        self.providerFingerprint =
            providerFingerprint

        self.specificationSHA256 =
            specificationSHA256

        self.revalidateSpecification = revalidateSpecification
        self.externalBearerSchemeName = resolvedExternalBearerSchemeName

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

            let argumentsSchema:
                JSONObjectSchema?

            if
                let pathSchema =
                    operation.pathArgumentsSchema,
                let requestSchema =
                    operation.requestJSONSchema
            {
                argumentsSchema =
                    Self.combinedArgumentsSchema(
                        pathSchema:
                            pathSchema,
                        requestSchema:
                            requestSchema
                    )
            } else {
                argumentsSchema =
                    operation.requestJSONSchema
                    ?? operation.pathArgumentsSchema
            }

            if let schema =
                argumentsSchema
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

            if operation.responseJSONSyntaxOnly {
                metadata[
                    "resultValidation"
                ] =
                    "json_syntax_only"
            }

            if let authority =
                operation.authorityRequirement
            {
                metadata[
                    "authorityRequired"
                ] =
                    "true"

                metadata[
                    "authorityKind"
                ] =
                    authority.kind

                metadata[
                    "authorityScheme"
                ] =
                    authority.schemeName

                metadata[
                    "authorityOrigin"
                ] =
                    authority.origin
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
        try admittedBegin(capability: capability, admissionOwner: capability, item: item, executionID: executionID,
                          arguments: arguments, verification: nil, expectedOutput: nil,
                          host: standaloneHost, revalidate: { true })
    }

    public func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem, executionID: String,
                              arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?,
                              host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
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

        if operation.zeroArgumentGET {
            guard arguments == nil else {
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
                        "The OpenAPI GET operation accepts no capability arguments.",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "input_contract_failure",
                            boundary:
                                "RIGHTCLICK rejected arguments before transport because this reflected GET operation declares no path, query, header, cookie or body inputs."
                        )
                )
            }

            targetPath =
                operation.path

            requestBody =
                nil

        } else if
            let pathSchema =
                operation.pathArgumentsSchema,
            let requestSchema =
                operation.requestJSONSchema,
            operation.requestContentType
                == "application/json"
        {
            guard
                let arguments,
                let combinedSchema =
                    Self.combinedArgumentsSchema(
                        pathSchema:
                            pathSchema,
                        requestSchema:
                            requestSchema
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
                        "The combined OpenAPI argument contract is unavailable.",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "input_contract_failure",
                            boundary:
                                "RIGHTCLICK could not construct a collision-free combined path and JSON argument schema."
                        )
                )
            }

            do {
                try Self.validateArguments(
                    arguments,
                    schema:
                        combinedSchema
                )

                let pathArguments =
                    Dictionary(
                        uniqueKeysWithValues:
                            arguments
                            .compactMap {
                                key,
                                value
                                in

                                pathSchema
                                    .properties[
                                        key
                                    ] != nil
                                ? (
                                    key,
                                    value
                                )
                                : nil
                            }
                    )

                let bodyArguments =
                    Dictionary(
                        uniqueKeysWithValues:
                            arguments
                            .compactMap {
                                key,
                                value
                                in

                                requestSchema
                                    .properties[
                                        key
                                    ] != nil
                                ? (
                                    key,
                                    value
                                )
                                : nil
                            }
                    )

                targetPath =
                    try Self.substitutedPath(
                        operation.path,
                        arguments:
                            pathArguments,
                        schema:
                            pathSchema
                    )

                requestBody =
                    try Self
                    .validatedJSONObjectBody(
                        bodyArguments,
                        schema:
                            requestSchema
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
                        "Combined capability arguments failed schema validation: \(error)",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "input_contract_failure",
                            boundary:
                                "RIGHTCLICK rejected combined path and JSON arguments before provider transport."
                        )
                )
            }

        } else if let pathSchema =
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

        let bearerToken:
            String?

        if let authority =
            operation.authorityRequirement
        {
            guard
                let targetOrigin =
                    try? Self
                    .canonicalAuthorityOrigin(
                        targetURL
                    ),
                targetOrigin
                    == authority.origin
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
                        "The reflected authority origin does not match the request origin.",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "authority_boundary_violation",
                            boundary:
                                "RIGHTCLICK refused to attach authority because the request origin did not match the reflected authority origin."
                        )
                )
            }

            guard
                let token =
                    OpenAPIAuthorityStore
                    .bearerToken(
                        for:
                            authority
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
                        .unavailable,
                    message:
                        "Required provider authority is unavailable.",
                    evidence:
                        OutcomeEvidence(
                            type:
                                "authority_unavailable",
                            boundary:
                                "RIGHTCLICK found no credential for the exact reflected authority origin and security scheme. No provider transport occurred."
                        )
                )
            }

            bearerToken =
                token

        } else {
            bearerToken =
                nil
        }

        var request =
            URLRequest(
                url: targetURL
            )

        request.httpMethod =
            operation.method

        request.httpBody =
            requestBody

        if let bearerToken {
            request.setValue(
                "Bearer "
                + bearerToken,
                forHTTPHeaderField:
                    "Authorization"
            )
        }

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

        // The existing request compiler and credential origin checks above
        // remain authoritative. Lower their exact output into the existing ABI.
        func schema(_ object: JSONObjectSchema) -> CapabilitySchema {
            .object(properties: object.properties.mapValues {
                $0.allowedValues.map { .stringEnum($0.sorted()) } ?? .string
            }, required: object.required.sorted())
        }
        let argumentSchema: CapabilitySchema
        if let path = operation.pathArgumentsSchema, let body = operation.requestJSONSchema,
           let combined = Self.combinedArgumentsSchema(pathSchema: path, requestSchema: body) {
            argumentSchema = schema(combined)
        } else if let object = operation.requestJSONSchema ?? operation.pathArgumentsSchema {
            argumentSchema = schema(object)
        } else { argumentSchema = .null }
        let resultSchema: CapabilitySchema = operation.responseJSONSchema.map(schema)
            ?? (operation.responseJSONSyntaxOnly ? .bytes : .string)
        var owned = CapabilityExperience.withoutExperience(admissionOwner)
        if owned.reflectorID == "unowned" { owned.reflectorID = id }
        let reflected = try owned.abiContract(arguments: .object(properties: [
            "item": .string, "arguments": argumentSchema
        ], required: ["item", "arguments"]), result: resultSchema)
        let abi = CapabilityContract(capabilityID: reflected.capabilityID, reflectorID: reflected.reflectorID,
            providerID: reflected.providerID, arguments: reflected.arguments, result: resultSchema,
            declaration: .object(["capability": reflected.declaration,
                "requestURL": .string(targetURL.absoluteString), "method": .string(operation.method),
                // Exact compiled bytes are committed without duplicating the
                // full invocation value into the bounded declaration. The lease
                // separately binds the complete typed arguments.
                "bodySHA256": requestBody.map { .string(Self.sha256Hex($0)) } ?? .null,
                "verification": try verification.map { .bytes(try JSONEncoder().encode($0)) } ?? .null,
                "expectedOutput": expectedOutput.map { .string($0) } ?? .null]))
        let input = CapabilityValue.object(["item": .string(item.text ?? ""),
            "arguments": CapabilityValue.fromLegacyArguments(arguments) ?? .null])
        // POST is conservatively execute (never inferred pure from a title).
        let effect: RCIREffect = operation.method == "GET" ? .read : .execute
        let scope = RCIRScope(targetURL.absoluteString, effect)
        return try host.execute(abi: abi, discovery: reflected, arguments: input, scope: scope,
            capability: admissionOwner, executionID: executionID, argumentStrings: arguments,
            item: item, verification: verification, expectedOutput: expectedOutput, target: targetURL, authority: {
                if let required = operation.authorityRequirement {
                    guard let current = OpenAPIAuthorityStore.bearerToken(for: required),
                          current.utf8.elementsEqual((bearerToken ?? "").utf8) else { return [] }
                }
                return [scope]
            }, revalidate: revalidate, currentContract: { self.contractIsCurrent() }, dispatch: { correlationID, admitStart in
                var boundRequest = request
                boundRequest.setValue(correlationID, forHTTPHeaderField: "X-RightClick-Invocation")
                return try self.send(boundRequest, operation: operation, capability: capability,
                                     executionID: executionID, admitStart: admitStart)
            }, resultValue: { record in
                if let object = operation.responseJSONSchema, let output = record.output {
                    guard let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String] else {
                        throw RCIRError.invalidContract
                    }
                    let value = CapabilityValue.object(json.mapValues { .string($0) })
                    try schema(object).validate(value)
                    return value
                }
                if operation.responseJSONSyntaxOnly { return .bytes(Data((record.output ?? "").utf8)) }
                return .string(record.output ?? "")
            })
    }

    public var requiresContractRefresh: Bool {
        freshnessLock.lock(); defer { freshnessLock.unlock() }
        return staleContract
    }

    public func refreshContract() throws -> any CapabilityReflector {
        guard let revalidateSpecification else { throw RCIRError.unavailable }
        return try OpenAPIReflector(specificationData: revalidateSpecification(), baseURL: baseURL,
            externalBearerSchemeName: externalBearerSchemeName, session: session,
            revalidateSpecification: revalidateSpecification)
    }

    private func contractIsCurrent() -> Bool {
        // Inline/operator-owned snapshots have no remote locator. Their graph
        // owner is still revalidated by the engine. Acquired URL contracts must
        // read current bounded source bytes before transport and after dispatch.
        guard let revalidateSpecification else { return true }
        let current = (try? revalidateSpecification()).map(Self.sha256Hex) == specificationSHA256
        freshnessLock.lock(); staleContract = !current; freshnessLock.unlock()
        return current
    }

    private func send(_ request: URLRequest, operation: Operation,
                      capability: Capability, executionID: String,
                      admitStart: (_ start: () -> Void) throws -> Void) throws -> ExecutionRecord {
        guard let targetURL = request.url else { throw RCIRError.invalidContract }
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

        // Only enqueue while the admission lock is held. Waiting below happens
        // after unlocking, so disappearance can invalidate other live bindings.
        try admitStart { task.resume() }

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
                    .unknown,
                message:
                    "The OpenAPI transport ended without acceptance: \(error.localizedDescription). External effects are unknown; do not retry blindly.",
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
                == "application/json"
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

            if let schema =
                operation.responseJSONSchema
            {
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

            } else if
                operation.responseJSONSyntaxOnly
            {
                do {
                    output =
                        try Self
                        .canonicalValidatedJSON(
                            responseData
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
                            "The OpenAPI provider response failed JSON syntax validation: \(error)",
                        evidence:
                            OutcomeEvidence(
                                type:
                                    "provider_contract_failure",
                                boundary:
                                    "The provider returned 2xx application/json, but the body was not valid JSON. No schema-level semantic claim was made."
                            )
                    )
                }

            } else {
                output =
                    nil
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

    private static func validatedExternalBearerSchemeName(
        _ raw: String?
    ) throws -> String? {
        guard
            let raw
        else {
            return nil
        }

        let value =
            raw.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard
            !value.isEmpty,
            !value.contains("|"),
            value.rangeOfCharacter(
                from:
                    .controlCharacters
            ) == nil
        else {
            throw RightClickError(
                "External OpenAPI bearer authority scheme name is invalid."
            )
        }

        return value
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

    private static func validateDeclaredServerBinding(
        _ data: Data,
        baseURL: URL
    ) throws {
        guard
            let root =
                try JSONSerialization
                    .jsonObject(
                        with:
                            data
                    ) as? [String: Any]
        else {
            throw RightClickError(
                "OpenAPI specification must be a JSON object."
            )
        }

        guard
            root.keys.contains(
                "servers"
            )
        else {
            return
        }

        guard
            let servers =
                root[
                    "servers"
                ] as? [Any],
            !servers.isEmpty
        else {
            throw RightClickError(
                "OpenAPI servers declaration is unsupported."
            )
        }

        var sawSupportedLiteral =
            false

        for rawServer in servers {
            guard
                let server =
                    rawServer
                        as? [String: Any],
                server[
                    "variables"
                ] == nil,
                let rawURL =
                    (
                        server[
                            "url"
                        ] as? String
                    )?
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    ),
                !rawURL.isEmpty,
                !rawURL.contains("{"),
                !rawURL.contains("}"),
                let serverURL =
                    URL(
                        string:
                            rawURL
                    ),
                let components =
                    URLComponents(
                        url:
                            serverURL,
                        resolvingAgainstBaseURL:
                            false
                    ),
                components.scheme != nil,
                components.host != nil,
                components.user == nil,
                components.password == nil,
                let canonicalServer =
                    try? canonicalBaseURL(
                        serverURL
                    )
            else {
                continue
            }

            sawSupportedLiteral =
                true

            if canonicalServer
                == baseURL
            {
                return
            }
        }

        if !sawSupportedLiteral {
            throw RightClickError(
                "OpenAPI servers declaration has no supported literal HTTP or HTTPS server."
            )
        }

        throw RightClickError(
            "OpenAPI base URL does not match a supported literal server declaration."
        )
    }

    private static func canonicalAuthorityOrigin(
        _ url: URL
    ) throws -> String {
        guard
            var components =
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
            throw RightClickError(
                "OpenAPI authority origin requires an absolute HTTP or HTTPS URL."
            )
        }

        let scheme =
            rawScheme.lowercased()

        guard
            scheme == "http"
                || scheme == "https"
        else {
            throw RightClickError(
                "OpenAPI authority origin must use HTTP or HTTPS."
            )
        }

        components.scheme =
            scheme

        components.host =
            rawHost.lowercased()

        if
            (
                scheme == "http"
                && components.port == 80
            )
            || (
                scheme == "https"
                && components.port == 443
            )
        {
            components.port =
                nil
        }

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

        guard
            let result =
                components.url
        else {
            throw RightClickError(
                "Could not canonicalize OpenAPI authority origin."
            )
        }

        var value =
            result.absoluteString

        if value.hasSuffix("/") {
            value.removeLast()
        }

        return value
    }

    private static func parseSpecification(
        _ data: Data,
        providerFingerprint: String,
        authorityOrigin: String,
        externalBearerSchemeName:
            String?
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

        let rootHasSecurity =
            root.keys.contains(
                "security"
            )

        let rootSecurityIsExplicitlyEmpty =
            rootHasSecurity
            && (
                root[
                    "security"
                ] as? [Any]
            )?.isEmpty == true

        let components =
            root["components"]
                as? [String: Any]

        let securitySchemes =
            components?[
                "securitySchemes"
            ] as? [String: Any]
            ?? [:]

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

                let authorityRequirement:
                    OpenAPIAuthorityRequirement?

                switch authorityResolution(
                    operation:
                        operation,
                    rootHasSecurity:
                        rootHasSecurity,
                    rootSecurityIsExplicitlyEmpty:
                        rootSecurityIsExplicitlyEmpty,
                    securitySchemes:
                        securitySchemes,
                    authorityOrigin:
                        authorityOrigin,
                    externalBearerSchemeName:
                        externalBearerSchemeName
                ) {
                case .publicAccess:
                    authorityRequirement =
                        nil

                case let .required(
                    requirement
                ):
                    authorityRequirement =
                        requirement

                case .unsupported:
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

                let responseJSONSyntaxOnly:
                    Bool

                let zeroArgumentGET:
                    Bool

                if method == "get" {
                    let pathSchema =
                        supportedPathArgumentSchema(
                            path:
                                path,
                            pathObject:
                                pathObject,
                            operation:
                                operation,
                            root:
                                root,
                            allowRequestBody:
                                false
                        )

                    if let pathSchema =
                        pathSchema
                    {
                        zeroArgumentGET =
                            false

                        pathArgumentsSchema =
                            pathSchema

                    } else if
                        supportsZeroArgumentGET(
                            path:
                                path,
                            pathObject:
                                pathObject,
                            operation:
                                operation
                        )
                    {
                        zeroArgumentGET =
                            true

                        pathArgumentsSchema =
                            nil

                    } else {
                        continue
                    }

                    requestContentType =
                        nil

                    requestJSONSchema =
                        nil

                    if
                        supportsPlainTextResponse(
                            operation
                        )
                    {
                        responseJSONSyntaxOnly =
                            false

                        responseContentType =
                            "text/plain"

                        responseJSONSchema =
                            nil

                    } else {
                        let responseSchema =
                            supportedJSONObjectResponseSchema(
                                operation
                            )

                        responseJSONSyntaxOnly =
                            responseSchema == nil
                            && hasDeclaredJSONResponseSchema(
                                operation
                            )

                        guard
                            responseSchema != nil
                            || responseJSONSyntaxOnly
                        else {
                            continue
                        }

                        responseContentType =
                            "application/json"

                        responseJSONSchema =
                            responseSchema
                    }

                } else {
                    zeroArgumentGET =
                        false

                    if
                        supportsPlainTextRequest(
                            operation
                        ),
                        supportsPlainTextResponse(
                            operation
                        )
                    {
                        guard
                            !path.contains("{"),
                            !path.contains("}")
                        else {
                            continue
                        }

                        pathArgumentsSchema =
                            nil

                        responseJSONSyntaxOnly =
                            false

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
                            )
                    {
                        let responseSchema =
                            supportedJSONObjectResponseSchema(
                                operation
                            )

                        let responseSyntaxOnly =
                            responseSchema == nil
                            && hasDeclaredJSONResponseSchema(
                                operation
                            )

                        guard
                            responseSchema != nil
                            || responseSyntaxOnly
                        else {
                            continue
                        }

                        responseJSONSyntaxOnly =
                            responseSyntaxOnly

                        let pathSchema:
                            JSONObjectSchema?

                        if
                            path.contains("{")
                            || path.contains("}")
                        {
                            guard
                                let supportedPathSchema =
                                    supportedPathArgumentSchema(
                                        path:
                                            path,
                                        pathObject:
                                            pathObject,
                                        operation:
                                            operation,
                                        root:
                                            root,
                                        allowRequestBody:
                                            true
                                    ),
                                combinedArgumentsSchema(
                                    pathSchema:
                                        supportedPathSchema,
                                    requestSchema:
                                        requestSchema
                                ) != nil
                            else {
                                continue
                            }

                            pathSchema =
                                supportedPathSchema
                        } else {
                            pathSchema =
                                nil
                        }

                        pathArgumentsSchema =
                            pathSchema

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
                        zeroArgumentGET:
                            zeroArgumentGET,
                        responseJSONSchema:
                            responseJSONSchema,
                        responseJSONSyntaxOnly:
                            responseJSONSyntaxOnly,
                        authorityRequirement:
                            authorityRequirement
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

    private static func authorityResolution(
        operation:
            [String: Any],
        rootHasSecurity:
            Bool,
        rootSecurityIsExplicitlyEmpty:
            Bool,
        securitySchemes:
            [String: Any],
        authorityOrigin:
            String,
        externalBearerSchemeName:
            String?
    ) -> AuthorityResolution {
        guard
            operation.keys.contains(
                "security"
            )
        else {
            if rootHasSecurity {
                return
                    rootSecurityIsExplicitlyEmpty
                    ? .publicAccess
                    : .unsupported
            }

            if let externalBearerSchemeName {
                return .required(
                    .httpBearer(
                        schemeName:
                            externalBearerSchemeName,
                        origin:
                            authorityOrigin
                    )
                )
            }

            return .publicAccess
        }

        guard
            let rawSecurity =
                operation[
                    "security"
                ] as? [Any]
        else {
            return .unsupported
        }

        if rawSecurity.isEmpty {
            return .publicAccess
        }

        guard
            rawSecurity.count == 1,
            let rawRequirement =
                rawSecurity.first
                    as? [String: Any],
            rawRequirement.count == 1,
            let schemeName =
                rawRequirement.keys.first,
            !schemeName.isEmpty,
            !schemeName.contains("|"),
            let scopes =
                rawRequirement[
                    schemeName
                ] as? [Any],
            scopes.isEmpty,
            let rawScheme =
                securitySchemes[
                    schemeName
                ] as? [String: Any]
        else {
            return .unsupported
        }

        let allowedSchemeKeys:
            Set<String> = [
                "type",
                "scheme",
                "bearerFormat",
                "description",
            ]

        guard
            Set(
                rawScheme.keys
            )
            .isSubset(
                of:
                    allowedSchemeKeys
            ),
            rawScheme[
                "type"
            ] as? String
                == "http",
            let httpScheme =
                rawScheme[
                    "scheme"
                ] as? String,
            httpScheme
                .lowercased()
                == "bearer"
        else {
            return .unsupported
        }

        if let bearerFormat =
            rawScheme[
                "bearerFormat"
            ],
            !(bearerFormat is String)
        {
            return .unsupported
        }

        if let description =
            rawScheme[
                "description"
            ],
            !(description is String)
        {
            return .unsupported
        }

        return .required(
            .httpBearer(
                schemeName:
                    schemeName,
                origin:
                    authorityOrigin
            )
        )
    }

    private static func supportsZeroArgumentGET(
        path: String,
        pathObject: [String: Any],
        operation: [String: Any]
    ) -> Bool {
        guard
            !path.contains("{"),
            !path.contains("}"),
            pathObject["parameters"] == nil,
            operation["requestBody"] == nil
        else {
            return false
        }

        guard
            operation.keys.contains(
                "parameters"
            )
        else {
            return true
        }

        guard
            let parameters =
                operation[
                    "parameters"
                ] as? [Any],
            parameters.isEmpty
        else {
            return false
        }

        return true
    }

    private static func resolveLocalReferenceObject(
        _ object: [String: Any],
        root: [String: Any],
        visited: Set<String> = [],
        depth: Int = 0
    ) -> [String: Any]? {
        guard
            depth <= 16
        else {
            return nil
        }

        guard
            let rawReference =
                object["$ref"]
        else {
            return object
        }

        let allowedReferenceKeys:
            Set<String> = [
                "$ref",
                "summary",
                "description",
            ]

        guard
            Set(object.keys)
                .isSubset(
                    of:
                        allowedReferenceKeys
                ),
            let reference =
                rawReference
                    as? String,
            reference
                .hasPrefix(
                    "#/"
                ),
            !visited
                .contains(
                    reference
                ),
            depth < 16,
            let target =
                localJSONPointerValue(
                    reference,
                    root:
                        root
                )
                    as? [String: Any]
        else {
            return nil
        }

        var nextVisited =
            visited

        nextVisited.insert(
            reference
        )

        return resolveLocalReferenceObject(
            target,
            root:
                root,
            visited:
                nextVisited,
            depth:
                depth + 1
        )
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

        for rawToken
            in rawTokens
        {
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
                character
                    == "~"
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

    private static func supportedPathArgumentSchema(
        path: String,
        pathObject: [String: Any],
        operation: [String: Any],
        root: [String: Any],
        allowRequestBody: Bool
    ) -> JSONObjectSchema? {
        guard
            pathObject["parameters"] == nil,
            (
                allowRequestBody
                || operation["requestBody"] == nil
            ),
            let rawParameters =
                operation["parameters"]
                    as? [Any],
            !rawParameters.isEmpty
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
                "x-multi-segment",
            ]

        let allowedSchemaKeys:
            Set<String> = [
                "type",
                "title",
                "description",
            ]

        var names:
            Set<String> = []

        var rawProperties:
            [String: Any] = [:]

        var multiSegmentNames:
            Set<String> = []

        for rawParameter
            in rawParameters
        {
            guard
                let rawObject =
                    rawParameter
                        as? [String: Any],
                let parameter =
                    resolveLocalReferenceObject(
                        rawObject,
                        root:
                            root
                    ),
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
                let rawSchema =
                    parameter["schema"]
                        as? [String: Any],
                let schema =
                    resolveLocalReferenceObject(
                        rawSchema,
                        root:
                            root
                    ),
                Set(schema.keys)
                    .isSubset(
                        of:
                            allowedSchemaKeys
                    ),
                schema["type"]
                    as? String == "string",
                names.insert(
                    name
                ).inserted
            else {
                return nil
            }

            let isMultiSegment:
                Bool

            if
                let rawMultiSegment =
                    parameter[
                        "x-multi-segment"
                    ]
            {
                guard
                    let declared =
                        rawMultiSegment
                            as? Bool
                else {
                    return nil
                }

                isMultiSegment =
                    declared

            } else {
                isMultiSegment =
                    false
            }

            if isMultiSegment {
                multiSegmentNames.insert(
                    name
                )
            }

            let token =
                "{\(name)}"

            let pieces =
                path.components(
                    separatedBy:
                        token
                )

            guard
                pieces.count == 2
            else {
                return nil
            }

            rawProperties[
                name
            ] = [
                "type":
                    "string"
            ]
        }

        var remainder =
            path

        for name
            in names.sorted()
        {
            remainder =
                remainder
                .replacingOccurrences(
                    of:
                        "{\(name)}",
                    with:
                        ""
                )
        }

        guard
            !remainder.contains("{"),
            !remainder.contains("}")
        else {
            return nil
        }

        let argumentsSchema:
            [String: Any] = [
                "type":
                    "object",

                "additionalProperties":
                    false,

                "required":
                    names.sorted(),

                "properties":
                    rawProperties,
            ]

        guard
            let parsed =
                parseClosedJSONStringObjectSchema(
                    argumentsSchema
                )
        else {
            return nil
        }

        return JSONObjectSchema(
            required:
                parsed.required,
            properties:
                parsed.properties,
            canonicalJSON:
                parsed.canonicalJSON,
            multiSegmentPathArguments:
                multiSegmentNames
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

        if let strictSchema =
            parseClosedJSONStringObjectSchema(
                rawSchema
            )
        {
            return strictSchema
        }

        return parseSafelyNarrowedJSONStringObjectSchema(
            rawSchema
        )
    }

    private static func hasDeclaredJSONResponseSchema(
        _ operation:
            [String: Any]
    ) -> Bool {
        guard
            let responses =
                operation[
                    "responses"
                ] as? [String: Any]
        else {
            return false
        }

        for key
            in responses.keys.sorted()
        {
            guard
                let status =
                    Int(key),
                (200...299)
                    .contains(
                        status
                    ),
                let response =
                    responses[
                        key
                    ] as? [String: Any],
                let content =
                    response[
                        "content"
                    ] as? [String: Any],
                let json =
                    content[
                        "application/json"
                    ] as? [String: Any],
                let rawSchema =
                    json[
                        "schema"
                    ] as? [String: Any],
                !rawSchema.isEmpty
            else {
                continue
            }

            return true
        }

        return false
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

    /// Conservatively project a provider request schema into the
    /// existing closed string-object argument model.
    ///
    /// This is intentionally request-only and one-way:
    ///
    /// - every provider-required property must survive projection;
    /// - unsupported optional properties are omitted;
    /// - the projected object is always closed;
    /// - oneOf is narrowed only when exactly one branch is a supported
    ///   string schema and every other branch is provably non-string.
    ///
    /// Therefore every argument object RIGHTCLICK accepts through the
    /// projection remains inside the provider's declared request space.
    private static func parseSafelyNarrowedJSONStringObjectSchema(
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

        var narrowedProperties:
            [String: Any] = [:]

        for key
            in rawProperties.keys.sorted()
        {
            guard
                !key.isEmpty,
                let raw =
                    rawProperties[key]
                        as? [String: Any]
            else {
                if required.contains(key) {
                    return nil
                }

                continue
            }

            if let narrowed =
                safelyNarrowedJSONStringProperty(
                    raw
                )
            {
                narrowedProperties[
                    key
                ] =
                    narrowed

            } else if
                required.contains(key)
            {
                // A provider-required field that RIGHTCLICK cannot model
                // cannot be silently discarded.
                return nil
            }
        }

        guard
            required.isSubset(
                of:
                    Set(
                        narrowedProperties.keys
                    )
            )
        else {
            return nil
        }

        let closedSchema:
            [String: Any] = [
                "type":
                    "object",

                "additionalProperties":
                    false,

                "required":
                    required.sorted(),

                "properties":
                    narrowedProperties,
            ]

        return parseClosedJSONStringObjectSchema(
            closedSchema
        )
    }

    /// Return the normalized closed-string representation of one provider
    /// property, or nil when RIGHTCLICK cannot prove a safe narrowing.
    private static func safelyNarrowedJSONStringProperty(
        _ property:
            [String: Any]
    ) -> [String: Any]? {
        if let direct =
            normalizedDirectJSONStringProperty(
                property
            )
        {
            return direct
        }

        let allowedUnionKeys:
            Set<String> = [
                "oneOf",
                "title",
                "description",
            ]

        guard
            Set(property.keys)
                .isSubset(
                    of:
                        allowedUnionKeys
                ),
            let branches =
                property["oneOf"]
                    as? [[String: Any]],
            !branches.isEmpty
        else {
            return nil
        }

        var supportedStrings:
            [[String: Any]] = []

        for branch
            in branches
        {
            if let supported =
                normalizedDirectJSONStringProperty(
                    branch
                )
            {
                supportedStrings.append(
                    supported
                )

                continue
            }

            guard
                isProvablyNonStringJSONSchema(
                    branch
                )
            else {
                return nil
            }
        }

        guard
            supportedStrings.count == 1
        else {
            return nil
        }

        return supportedStrings[0]
    }

    /// Normalize only the existing strong direct string-property subset.
    private static func normalizedDirectJSONStringProperty(
        _ property:
            [String: Any]
    ) -> [String: Any]? {
        let allowedKeys:
            Set<String> = [
                "type",
                "enum",
                "title",
                "description",
            ]

        guard
            Set(property.keys)
                .isSubset(
                    of:
                        allowedKeys
                ),
            property["type"]
                as? String == "string"
        else {
            return nil
        }

        var normalized:
            [String: Any] = [
                "type":
                    "string"
            ]

        if let rawEnum =
            property["enum"]
        {
            guard
                let values =
                    rawEnum as? [String],
                !values.isEmpty,
                Set(values).count
                    == values.count
            else {
                return nil
            }

            normalized[
                "enum"
            ] =
                values
        }

        return normalized
    }

    /// A branch can be discarded from a oneOf string narrowing only when
    /// its top-level JSON type proves that a string accepted by RIGHTCLICK
    /// cannot satisfy that branch.
    private static func isProvablyNonStringJSONSchema(
        _ schema:
            [String: Any]
    ) -> Bool {
        let allowedKeys:
            Set<String> = [
                "type",
                "title",
                "description",
            ]

        guard
            Set(schema.keys)
                .isSubset(
                    of:
                        allowedKeys
                ),
            let type =
                schema["type"]
                    as? String
        else {
            return false
        }

        return [
            "array",
            "boolean",
            "integer",
            "number",
            "object",
            "null",
        ].contains(
            type
        )
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

    private static func combinedArgumentsSchema(
        pathSchema:
            JSONObjectSchema,
        requestSchema:
            JSONObjectSchema
    ) -> JSONObjectSchema? {
        let pathNames =
            Set(
                pathSchema
                    .properties
                    .keys
            )

        let requestNames =
            Set(
                requestSchema
                    .properties
                    .keys
            )

        guard
            pathNames.isDisjoint(
                with:
                    requestNames
            )
        else {
            return nil
        }

        var rawProperties:
            [String: Any] = [:]

        for (
            name,
            property
        ) in pathSchema.properties {
            var raw:
                [String: Any] = [
                    "type":
                        "string"
                ]

            if let allowed =
                property.allowedValues
            {
                raw[
                    "enum"
                ] =
                    allowed.sorted()
            }

            rawProperties[
                name
            ] =
                raw
        }

        for (
            name,
            property
        ) in requestSchema.properties {
            var raw:
                [String: Any] = [
                    "type":
                        "string"
                ]

            if let allowed =
                property.allowedValues
            {
                raw[
                    "enum"
                ] =
                    allowed.sorted()
            }

            rawProperties[
                name
            ] =
                raw
        }

        let rawSchema:
            [String: Any] = [
                "type":
                    "object",

                "additionalProperties":
                    false,

                "required":
                    pathSchema
                    .required
                    .union(
                        requestSchema
                            .required
                    )
                    .sorted(),

                "properties":
                    rawProperties,
            ]

        return parseClosedJSONStringObjectSchema(
            rawSchema
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

    private static func encodedMultiSegmentPathArgument(
        _ value: String
    ) throws -> String {
        let segments =
            value.split(
                separator:
                    "/",
                omittingEmptySubsequences:
                    false
            )

        guard
            !segments.isEmpty
        else {
            throw RightClickError(
                "Multi-segment path argument is empty."
            )
        }

        var encodedSegments:
            [String] = []

        for rawSegment
            in segments
        {
            let segment =
                String(
                    rawSegment
                )

            guard
                !segment.isEmpty,
                segment != ".",
                segment != ".."
            else {
                throw RightClickError(
                    "Multi-segment path argument contains an unsafe path segment."
                )
            }

            guard
                let encoded =
                    segment
                        .addingPercentEncoding(
                            withAllowedCharacters:
                                identifierCharacters
                        )
            else {
                throw RightClickError(
                    "Could not percent-encode multi-segment path argument."
                )
            }

            encodedSegments.append(
                encoded
            )
        }

        return encodedSegments
            .joined(
                separator:
                    "/"
            )
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

            let encoded:
                String

            if
                schema
                    .multiSegmentPathArguments
                    .contains(
                        name
                    )
            {
                encoded =
                    try encodedMultiSegmentPathArgument(
                        value
                    )

            } else {
                guard
                    let singleSegment =
                        value.addingPercentEncoding(
                            withAllowedCharacters:
                                identifierCharacters
                        )
                else {
                    throw RightClickError(
                        "Could not percent-encode path argument."
                    )
                }

                encoded =
                    singleSegment
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

    private static func canonicalValidatedJSON(
        _ data:
            Data
    ) throws -> String {
        let object:
            Any

        do {
            object =
                try JSONSerialization
                .jsonObject(
                    with:
                        data,
                    options: [
                        .fragmentsAllowed
                    ]
                )
        } catch {
            throw RightClickError(
                "Response is not valid JSON."
            )
        }

        let canonicalData =
            try JSONSerialization
            .data(
                withJSONObject:
                    object,
                options: [
                    .sortedKeys,
                    .withoutEscapingSlashes,
                    .fragmentsAllowed,
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
