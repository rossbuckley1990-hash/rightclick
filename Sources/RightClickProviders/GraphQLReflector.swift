#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class GraphQLReflector:
    RCIRExecutionReflector
{
    private enum OperationKind:
        String
    {
        case query
        case mutation
    }

    private indirect enum TypeRef:
        Equatable
    {
        case named(
            kind: String,
            name: String
        )

        case list(
            TypeRef
        )

        case nonNull(
            TypeRef
        )

        var graphQLType: String {
            switch self {
            case let .named(
                _,
                name
            ):
                return name

            case let .list(
                inner
            ):
                return
                    "["
                    + inner.graphQLType
                    + "]"

            case let .nonNull(
                inner
            ):
                return
                    inner.graphQLType
                    + "!"
            }
        }

        var isNonNull: Bool {
            if case .nonNull =
                self
            {
                return true
            }

            return false
        }

        var namedType:
            (
                kind: String,
                name: String
            )?
        {
            switch self {
            case let .named(
                kind,
                name
            ):
                return (
                    kind,
                    name
                )

            case let .list(
                inner
            ),
                let .nonNull(
                    inner
                ):
                return
                    inner.namedType
            }
        }
    }

    private struct InputField {
        let name: String
        let type: TypeRef
        let defaultValue: String?
    }

    private struct Field {
        let name: String
        let description: String?
        let arguments: [InputField]
        let type: TypeRef
    }

    private struct TypeDefinition {
        let kind: String
        let name: String
        let fields: [Field]
        let inputFields: [InputField]
        let enumValues: Set<String>
    }

    private struct Operation {
        let capabilityID: String
        let kind: OperationKind
        let field: String
        let title: String
        let arguments: [InputField]
        let returnType: TypeRef
        let selection: String
    }

    private let endpointURL: URL
    private let providerName: String
    private let providerFingerprint: String
    private let schemaSHA256: String
    private let authorityOrigin: String
    private let authoritySchemeName: String?
    private let session: URLSession

    private let typeDefinitions:
        [String: TypeDefinition]

    private let operations:
        [Operation]

    private let operationByCapabilityID:
        [String: Operation]

    public let id: String

    public init(
        schemaData: Data,
        endpointURL: URL,
        providerName: String? = nil,
        externalBearerSchemeName:
            String? = nil,
        session: URLSession = .shared
    ) throws {
        guard
            schemaData.count
                <= GraphQLHTTP
                    .maximumSchemaBytes
        else {
            throw RightClickError(
                "GraphQL schema exceeded the maximum supported size."
            )
        }

        let endpoint =
            try GraphQLHTTP
                .canonicalEndpointURL(
                    endpointURL
                )

        let origin =
            try GraphQLHTTP
                .canonicalOrigin(
                    endpoint
                )

        let schemeName:
            String?

        if let externalBearerSchemeName {
            guard
                let validated =
                    GraphQLHTTP
                        .validatedAuthoritySchemeName(
                            externalBearerSchemeName
                        )
            else {
                throw RightClickError(
                    "GraphQL bearer authority scheme name is invalid."
                )
            }

            schemeName =
                validated
        } else {
            schemeName =
                nil
        }

        let schemaSHA256 =
            Self.sha256Hex(
                schemaData
            )

        var providerIdentity =
            endpoint.absoluteString
            + "\n"
            + schemaSHA256

        if let schemeName {
            providerIdentity +=
                "\nauth-scheme:"
                + schemeName
        }

        let providerFingerprint =
            Self.sha256Hex(
                Data(
                    providerIdentity.utf8
                )
            )

        let parsed =
            try Self.parseSchema(
                schemaData,
                providerFingerprint:
                    providerFingerprint
            )

        let trimmedName =
            providerName?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        self.endpointURL =
            endpoint

        self.providerName =
            (
                trimmedName?
                    .isEmpty == false
            )
            ? trimmedName!
            : "GraphQL provider"

        self.providerFingerprint =
            providerFingerprint

        self.schemaSHA256 =
            schemaSHA256

        self.authorityOrigin =
            origin

        self.authoritySchemeName =
            schemeName

        self.session =
            session

        self.typeDefinitions =
            parsed.types

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
            "graphql-reflector:"
            + providerFingerprint
    }

    public func capabilities(
        for item: ContentItem
    ) throws -> [Capability] {
        guard
            item.text != nil
        else {
            return []
        }

        return operations.map {
            operation in

            let policy =
                SafetyPolicy.classify(
                    title:
                        operation.title,
                    source:
                        .system,
                    sendTypes: [
                        "public.plain-text"
                    ],
                    returnTypes: [
                        "public.json"
                    ]
                )

            var metadata:
                [String: String] = [
                    "substrate":
                        "graphql",
                    "operationKind":
                        operation
                            .kind
                            .rawValue,
                    "field":
                        operation.field,
                    "providerIdentity":
                        providerFingerprint,
                    "schemaSHA256":
                        schemaSHA256,
                    "endpointURL":
                        endpointURL
                            .absoluteString,
                    "graphqlReturnType":
                        operation
                            .returnType
                            .graphQLType,
                    "resultValidation":
                        "graphql_response",
                ]

            if
                !operation
                    .arguments
                    .isEmpty
            {
                metadata[
                    "argumentsSchema"
                ] =
                    Self.argumentsSchema(
                        operation
                            .arguments,
                        types:
                            typeDefinitions
                    )
            }

            if let authoritySchemeName {
                metadata[
                    "authorityRequired"
                ] =
                    "true"

                metadata[
                    "authorityKind"
                ] =
                    "http_bearer"

                metadata[
                    "authorityScheme"
                ] =
                    authoritySchemeName

                metadata[
                    "authorityOrigin"
                ] =
                    authorityOrigin
            }

            return Capability(
                id:
                    operation
                        .capabilityID,
                title:
                    operation
                        .title,
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
                    "public.json"
                ],
                safety:
                    policy.safety,
                invocation:
                    policy.invocation,
                supportLevel:
                    .experimental,
                requiresConfirmation:
                    true,
                metadata:
                    metadata
            )
        }
    }

    public func providers()
        -> [ProviderSummary]
    {
        guard
            !operations.isEmpty
        else {
            return []
        }

        return [
            ProviderSummary(
                name:
                    providerName,
                bundleIdentifier:
                    nil,
                source:
                    "graphql",
                capabilityTitles:
                    operations
                        .map(
                            \.title
                        )
                        .sorted {
                            $0
                                .localizedCaseInsensitiveCompare(
                                    $1
                                )
                                == .orderedAscending
                        }
            )
        ]
    }

    public func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws
        -> ExecutionRecord
    {
        try begin(
            capability:
                capability,
            item:
                item,
            executionID:
                executionID,
            arguments:
                nil
        )
    }

    public func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments:
            CapabilityArguments?
    ) throws
        -> ExecutionRecord
    {
        try performBegin(capability: capability, item: item, executionID: executionID,
                         arguments: arguments, admitStart: nil)
    }

    public func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem,
                              executionID: String, arguments: CapabilityArguments?, verification: VerificationSpec?,
                              expectedOutput: String?, host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        guard let operation = operationByCapabilityID[capability.id] else { throw RCIRError.unavailable }
        return try RCIRUnaryInvocation.execute(capability: capability, owner: admissionOwner, item: item,
            executionID: executionID, arguments: arguments, names: operation.arguments.map(\.name),
            required: operation.arguments.filter { $0.type.isNonNull && $0.defaultValue == nil }.map(\.name),
            target: endpointURL, verification: verification, expectedOutput: expectedOutput,
            host: host, available: {
                guard let scheme = self.authoritySchemeName else { return true }
                return GraphQLHTTP.bearerToken(origin: self.authorityOrigin, schemeName: scheme) != nil
            }, revalidate: revalidate, invoke: { admit in
                try withoutActuallyEscaping(admit) { gate in
                    try self.performBegin(capability: capability, item: item, executionID: executionID,
                                          arguments: arguments, admitStart: gate)
                }
            })
    }

    private func performBegin(capability: Capability, item: ContentItem, executionID: String,
                              arguments: CapabilityArguments?,
                              admitStart: ((_ start: () -> Void) throws -> Void)?) throws -> ExecutionRecord
    {
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
                    "The reflected GraphQL operation is no longer available.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_unavailable",
                        boundary:
                            "No operation matching this capability exists in the current GraphQL reflector."
                    )
            )
        }

        let supplied =
            arguments
            ?? [:]

        let knownNames =
            Set(
                operation
                    .arguments
                    .map(
                        \.name
                    )
            )

        let unknownNames =
            Set(
                supplied.keys
            )
            .subtracting(
                knownNames
            )

        guard
            unknownNames
                .isEmpty
        else {
            return inputFailure(
                executionID:
                    executionID,
                capability:
                    capability,
                message:
                    "Unknown GraphQL capability arguments: "
                    + unknownNames
                        .sorted()
                        .joined(
                            separator:
                                ", "
                        )
                    + "."
            )
        }

        var variables:
            [String: Any] = [:]

        var usedArguments:
            [InputField] = []

        do {
            for argument
                in operation
                    .arguments
            {
                if let raw =
                    supplied[
                        argument.name
                    ]
                {
                    variables[
                        argument.name
                    ] =
                        try coerceTopLevel(
                            raw,
                            type:
                                argument.type
                        )

                    usedArguments
                        .append(
                            argument
                        )

                    continue
                }

                if
                    argument
                        .type
                        .isNonNull,
                    argument
                        .defaultValue
                        == nil
                {
                    throw RightClickError(
                        "Missing required GraphQL argument "
                        + argument.name
                        + "."
                    )
                }
            }
        } catch {
            return inputFailure(
                executionID:
                    executionID,
                capability:
                    capability,
                message:
                    String(
                        describing:
                            error
                    )
            )
        }

        let operationName =
            "RightClick_"
            + String(
                Self.sha256Hex(
                    Data(
                        capability
                            .id
                            .utf8
                    )
                )
                .prefix(16)
            )

        let variableDefinitions =
            usedArguments
                .map {
                    "$"
                    + $0.name
                    + ": "
                    + $0
                        .type
                        .graphQLType
                }
                .joined(
                    separator:
                        ", "
                )

        let fieldArguments =
            usedArguments
                .map {
                    $0.name
                    + ": $"
                    + $0.name
                }
                .joined(
                    separator:
                        ", "
                )

        var document =
            operation
                .kind
                .rawValue
            + " "
            + operationName

        if !variableDefinitions
            .isEmpty
        {
            document +=
                "("
                + variableDefinitions
                + ")"
        }

        document +=
            " { rightclickResult: "
            + operation.field

        if !fieldArguments
            .isEmpty
        {
            document +=
                "("
                + fieldArguments
                + ")"
        }

        document +=
            operation.selection

        document +=
            " }"

        let body:
            [String: Any] = [
                "query":
                    document,
                "operationName":
                    operationName,
                "variables":
                    variables,
            ]

        let bodyData:
            Data

        do {
            bodyData =
                try JSONSerialization
                    .data(
                        withJSONObject:
                            body,
                        options:
                            [.sortedKeys]
                    )
        } catch {
            return inputFailure(
                executionID:
                    executionID,
                capability:
                    capability,
                message:
                    "GraphQL variables could not be serialized: "
                    + String(
                        describing:
                            error
                    )
            )
        }

        let bearerToken:
            String?

        if let authoritySchemeName {
            guard
                let token =
                    GraphQLHTTP
                        .bearerToken(
                            origin:
                                authorityOrigin,
                            schemeName:
                                authoritySchemeName
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
                                "RIGHTCLICK found no credential for the exact reflected GraphQL authority origin and security scheme. No provider transport occurred."
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
                url:
                    endpointURL
            )

        request.httpMethod =
            "POST"

        request.httpBody =
            bodyData

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.setValue(
            "application/graphql-response+json, application/json",
            forHTTPHeaderField:
                "Accept"
        )

        if let bearerToken {
            request.setValue(
                "Bearer "
                    + bearerToken,
                forHTTPHeaderField:
                    "Authorization"
            )
        }

        let result:
            (
                response:
                    HTTPURLResponse,
                data:
                    Data
            )

        do {
            result =
                try GraphQLHTTP
                    .perform(
                        request,
                        template:
                            session,
                        deadline:
                            GraphQLHTTP
                                .invocationDeadline,
                        maximumBytes:
                            GraphQLHTTP
                                .maximumResponseBytes,
                        admitStart: admitStart
                    )
        } catch {
            if admitStart != nil { throw error }
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
                    "The GraphQL provider request failed: "
                    + String(
                        describing:
                            error
                    ),
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_transport_failure",
                        boundary:
                            "The HTTP transport failed before GraphQL provider acceptance could be established."
                    )
            )
        }

        guard
            (200...299)
                .contains(
                    result
                        .response
                        .statusCode
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
                    "The GraphQL provider returned HTTP "
                    + String(
                        result
                            .response
                            .statusCode
                    )
                    + ".",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_rejection",
                        boundary:
                            "The provider returned a non-2xx HTTP status code."
                    )
            )
        }

        guard
            GraphQLHTTP
                .isSupportedGraphQLMediaType(
                    result.response
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
                    "The GraphQL provider returned an unexpected response content type.",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_contract_failure",
                        boundary:
                            "The provider returned 2xx, but the media type was not application/graphql-response+json or application/json."
                    )
            )
        }

        let responseObject:
            [String: Any]

        do {
            guard
                let decoded =
                    try JSONSerialization
                        .jsonObject(
                            with:
                                result.data
                        )
                    as? [String: Any]
            else {
                throw RightClickError(
                    "GraphQL response must be a JSON object."
                )
            }

            responseObject =
                decoded
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
                    "The GraphQL provider returned invalid JSON: "
                    + String(
                        describing:
                            error
                    ),
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_contract_failure",
                        boundary:
                            "The provider returned 2xx, but its GraphQL response was not a valid JSON response object."
                    )
            )
        }

        if
            let errors =
                responseObject[
                    "errors"
                ] as? [Any],
            !errors.isEmpty
        {
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
                    "The GraphQL provider returned one or more GraphQL errors.",
                output:
                    Self.canonicalJSON(
                        responseObject
                    ),
                evidence:
                    OutcomeEvidence(
                        type:
                            "graphql_errors",
                        boundary:
                            "GraphQL returned an errors array. RIGHTCLICK does not treat partial data as successful execution."
                    )
            )
        }

        guard
            let dataObject =
                responseObject[
                    "data"
                ] as? [String: Any]
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
                    "The GraphQL provider returned no usable data object.",
                output:
                    Self.canonicalJSON(
                        responseObject
                    ),
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_contract_failure",
                        boundary:
                            "A successful GraphQL transport response did not contain a data object and supplied no accepted result."
                    )
            )
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
                "The GraphQL provider accepted the operation and returned a valid GraphQL data object. Semantic outcome is unverified.",
            output:
                Self.canonicalJSON(
                    dataObject
                ),
            evidence:
                OutcomeEvidence(
                    type:
                        "provider_acceptance",
                    boundary:
                        "GraphQL transport and response semantics were valid. This does not independently verify the user's intended external outcome."
                )
        )
    }

    private func inputFailure(
        executionID: String,
        capability: Capability,
        message: String
    ) -> ExecutionRecord {
        ExecutionRecord(
            executionId:
                executionID,
            actionId:
                capability.id,
            title:
                capability.title,
            state:
                .failed,
            message:
                message,
            evidence:
                OutcomeEvidence(
                    type:
                        "input_contract_failure",
                    boundary:
                        "RIGHTCLICK rejected GraphQL capability arguments before provider transport."
                )
        )
    }

    private func coerceTopLevel(
        _ raw: String,
        type: TypeRef
    ) throws -> Any {
        if raw == "null" {
            guard
                !type.isNonNull
            else {
                throw RightClickError(
                    "A non-null GraphQL argument cannot be null."
                )
            }

            return NSNull()
        }

        switch type {
        case let .nonNull(
            inner
        ):
            return
                try coerceTopLevel(
                    raw,
                    type:
                        inner
                )

        case .list:
            guard
                let data =
                    raw.data(
                        using:
                            .utf8
                    )
            else {
                throw RightClickError(
                    "GraphQL list argument is not UTF-8 JSON."
                )
            }

            let decoded =
                try JSONSerialization
                    .jsonObject(
                        with:
                            data,
                        options:
                            [.fragmentsAllowed]
                    )

            return
                try coerceJSON(
                    decoded,
                    type:
                        type
                )

        case let .named(
            kind,
            name
        ):
            if kind == "INPUT_OBJECT" {
                guard
                    let data =
                        raw.data(
                            using:
                                .utf8
                        )
                else {
                    throw RightClickError(
                        "GraphQL input-object argument is not UTF-8 JSON."
                    )
                }

                let decoded =
                    try JSONSerialization
                        .jsonObject(
                            with:
                                data,
                            options:
                                [.fragmentsAllowed]
                        )

                return
                    try coerceJSON(
                        decoded,
                        type:
                            type
                    )
            }

            return
                try coerceScalar(
                    raw,
                    kind:
                        kind,
                    name:
                        name
                )
        }
    }

    private func coerceJSON(
        _ value: Any,
        type: TypeRef
    ) throws -> Any {
        if value is NSNull {
            guard
                !type.isNonNull
            else {
                throw RightClickError(
                    "A non-null GraphQL value cannot be null."
                )
            }

            return NSNull()
        }

        switch type {
        case let .nonNull(
            inner
        ):
            return
                try coerceJSON(
                    value,
                    type:
                        inner
                )

        case let .list(
            inner
        ):
            guard
                let values =
                    value as? [Any]
            else {
                throw RightClickError(
                    "GraphQL list argument must be encoded as a JSON array."
                )
            }

            return
                try values.map {
                    try coerceJSON(
                        $0,
                        type:
                            inner
                    )
                }

        case let .named(
            kind,
            name
        ):
            if kind == "INPUT_OBJECT" {
                guard
                    let object =
                        value
                            as? [String: Any],
                    let definition =
                        typeDefinitions[
                            name
                        ]
                else {
                    throw RightClickError(
                        "GraphQL input-object argument does not match a reflected input type."
                    )
                }

                let allowedNames =
                    Set(
                        definition
                            .inputFields
                            .map(
                                \.name
                            )
                    )

                let unknown =
                    Set(
                        object.keys
                    )
                    .subtracting(
                        allowedNames
                    )

                guard
                    unknown.isEmpty
                else {
                    throw RightClickError(
                        "Unknown fields in GraphQL input object "
                        + name
                        + ": "
                        + unknown
                            .sorted()
                            .joined(
                                separator:
                                    ", "
                            )
                        + "."
                    )
                }

                var result:
                    [String: Any] = [:]

                for field
                    in definition
                        .inputFields
                {
                    if let raw =
                        object[
                            field.name
                        ]
                    {
                        result[
                            field.name
                        ] =
                            try coerceJSON(
                                raw,
                                type:
                                    field.type
                            )

                        continue
                    }

                    if
                        field
                            .type
                            .isNonNull,
                        field
                            .defaultValue
                            == nil
                    {
                        throw RightClickError(
                            "Missing required field "
                            + field.name
                            + " in GraphQL input object "
                            + name
                            + "."
                        )
                    }
                }

                return result
            }

            return
                try coerceJSONScalar(
                    value,
                    kind:
                        kind,
                    name:
                        name
                )
        }
    }

    private func coerceScalar(
        _ raw: String,
        kind: String,
        name: String
    ) throws -> Any {
        if kind == "ENUM" {
            guard
                let definition =
                    typeDefinitions[
                        name
                    ],
                definition
                    .enumValues
                    .contains(
                        raw
                    )
            else {
                throw RightClickError(
                    "GraphQL enum "
                    + name
                    + " does not accept value "
                    + raw
                    + "."
                )
            }

            return raw
        }

        switch name {
        case "Int":
            guard
                let value =
                    Int(raw)
            else {
                throw RightClickError(
                    "GraphQL Int argument is invalid."
                )
            }

            return value

        case "Float":
            guard
                let value =
                    Double(raw)
            else {
                throw RightClickError(
                    "GraphQL Float argument is invalid."
                )
            }

            return value

        case "Boolean":
            if raw.lowercased()
                == "true"
            {
                return true
            }

            if raw.lowercased()
                == "false"
            {
                return false
            }

            throw RightClickError(
                "GraphQL Boolean argument must be true or false."
            )

        default:
            return raw
        }
    }

    private func coerceJSONScalar(
        _ value: Any,
        kind: String,
        name: String
    ) throws -> Any {
        if kind == "ENUM" {
            guard
                let raw =
                    value as? String
            else {
                throw RightClickError(
                    "GraphQL enum "
                    + name
                    + " must be a JSON string."
                )
            }

            return
                try coerceScalar(
                    raw,
                    kind:
                        kind,
                    name:
                        name
                )
        }

        switch name {
        case "Int":
            if let number =
                value as? NSNumber
            {
                let double =
                    number.doubleValue

                guard
                    double.rounded()
                        == double
                else {
                    throw RightClickError(
                        "GraphQL Int JSON value is not integral."
                    )
                }

                return
                    number.intValue
            }

        case "Float":
            if let number =
                value as? NSNumber
            {
                return
                    number.doubleValue
            }

        case "Boolean":
            if let number =
                value as? NSNumber
            {
                return
                    number.boolValue
            }

        case "String",
            "ID":
            if let string =
                value as? String
            {
                return string
            }

        default:
            if
                let string =
                    value as? String
            {
                return string
            }

            if value
                is NSNumber
            {
                return value
            }
        }

        throw RightClickError(
            "GraphQL JSON value does not satisfy "
            + name
            + "."
        )
    }

    private static func parseSchema(
        _ data: Data,
        providerFingerprint: String
    ) throws
        -> (
            types:
                [String: TypeDefinition],
            operations:
                [Operation]
        )
    {
        guard
            let root =
                try JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                as? [String: Any]
        else {
            throw RightClickError(
                "GraphQL introspection response must be a JSON object."
            )
        }

        if
            let errors =
                root[
                    "errors"
                ] as? [Any],
            !errors.isEmpty
        {
            throw RightClickError(
                "GraphQL introspection returned errors."
            )
        }

        let dataObject =
            root[
                "data"
            ] as? [String: Any]
            ?? root

        guard
            let schema =
                dataObject[
                    "__schema"
                ] as? [String: Any]
        else {
            throw RightClickError(
                "GraphQL introspection response contains no __schema object."
            )
        }

        guard
            let rawTypes =
                schema[
                    "types"
                ] as? [Any],
            rawTypes.count
                <= 4096
        else {
            throw RightClickError(
                "GraphQL introspection types are missing or exceed the supported bound."
            )
        }

        var types:
            [String: TypeDefinition] = [:]

        for rawType in rawTypes {
            guard
                let object =
                    rawType
                        as? [String: Any],
                let kind =
                    object[
                        "kind"
                    ] as? String,
                let name =
                    object[
                        "name"
                    ] as? String,
                !name.isEmpty
            else {
                continue
            }

            let fields =
                try parseFields(
                    object[
                        "fields"
                    ]
                )

            let inputFields =
                try parseInputFields(
                    object[
                        "inputFields"
                    ]
                )

            let enumValues =
                Set(
                    (
                        object[
                            "enumValues"
                        ] as? [Any]
                        ?? []
                    )
                    .compactMap {
                        (
                            $0
                                as? [String: Any]
                        )?[
                            "name"
                        ] as? String
                    }
                )

            types[
                name
            ] =
                TypeDefinition(
                    kind:
                        kind,
                    name:
                        name,
                    fields:
                        fields,
                    inputFields:
                        inputFields,
                    enumValues:
                        enumValues
                )
        }

        let queryTypeName =
            (
                schema[
                    "queryType"
                ] as? [String: Any]
            )?[
                "name"
            ] as? String

        let mutationTypeName =
            (
                schema[
                    "mutationType"
                ] as? [String: Any]
            )?[
                "name"
            ] as? String

        var operations:
            [Operation] = []

        if let queryTypeName {
            operations +=
                makeOperations(
                    kind:
                        .query,
                    rootTypeName:
                        queryTypeName,
                    types:
                        types,
                    providerFingerprint:
                        providerFingerprint
                )
        }

        if let mutationTypeName {
            operations +=
                makeOperations(
                    kind:
                        .mutation,
                    rootTypeName:
                        mutationTypeName,
                    types:
                        types,
                    providerFingerprint:
                        providerFingerprint
                )
        }

        guard
            operations.count
                <= 2048
        else {
            throw RightClickError(
                "GraphQL root operation count exceeds the supported bound."
            )
        }

        return (
            types,
            operations.sorted {
                if
                    $0.kind
                        .rawValue
                    == $1.kind
                        .rawValue
                {
                    return
                        $0.field
                        < $1.field
                }

                return
                    $0.kind
                        .rawValue
                    < $1.kind
                        .rawValue
            }
        )
    }

    private static func parseFields(
        _ raw: Any?
    ) throws -> [Field] {
        guard
            let values =
                raw as? [Any]
        else {
            return []
        }

        return try values
            .compactMap {
                value
                in

                guard
                    let object =
                        value
                            as? [String: Any],
                    let name =
                        object[
                            "name"
                        ] as? String,
                    !name.isEmpty,
                    let typeObject =
                        object[
                            "type"
                        ] as? [String: Any]
                else {
                    return nil
                }

                let type =
                    try parseTypeRef(
                        typeObject
                    )

                let arguments =
                    try parseInputFields(
                        object[
                            "args"
                        ]
                    )

                return Field(
                    name:
                        name,
                    description:
                        object[
                            "description"
                        ] as? String,
                    arguments:
                        arguments,
                    type:
                        type
                )
            }
    }

    private static func parseInputFields(
        _ raw: Any?
    ) throws
        -> [InputField]
    {
        guard
            let values =
                raw as? [Any]
        else {
            return []
        }

        return try values
            .compactMap {
                value
                in

                guard
                    let object =
                        value
                            as? [String: Any],
                    let name =
                        object[
                            "name"
                        ] as? String,
                    !name.isEmpty,
                    let typeObject =
                        object[
                            "type"
                        ] as? [String: Any]
                else {
                    return nil
                }

                return InputField(
                    name:
                        name,
                    type:
                        try parseTypeRef(
                            typeObject
                        ),
                    defaultValue:
                        object[
                            "defaultValue"
                        ] as? String
                )
            }
    }

    private static func parseTypeRef(
        _ object:
            [String: Any],
        depth: Int = 0
    ) throws -> TypeRef {
        guard
            depth <= 16,
            let kind =
                object[
                    "kind"
                ] as? String
        else {
            throw RightClickError(
                "GraphQL type reference is missing or too deeply nested."
            )
        }

        switch kind {
        case "NON_NULL":
            guard
                let rawInner =
                    object[
                        "ofType"
                    ] as? [String: Any]
            else {
                throw RightClickError(
                    "GraphQL NON_NULL type has no wrapped type."
                )
            }

            return
                .nonNull(
                    try parseTypeRef(
                        rawInner,
                        depth:
                            depth
                            + 1
                    )
                )

        case "LIST":
            guard
                let rawInner =
                    object[
                        "ofType"
                    ] as? [String: Any]
            else {
                throw RightClickError(
                    "GraphQL LIST type has no wrapped type."
                )
            }

            return
                .list(
                    try parseTypeRef(
                        rawInner,
                        depth:
                            depth
                            + 1
                    )
                )

        default:
            guard
                let name =
                    object[
                        "name"
                    ] as? String,
                !name.isEmpty
            else {
                throw RightClickError(
                    "GraphQL named type has no name."
                )
            }

            return
                .named(
                    kind:
                        kind,
                    name:
                        name
                )
        }
    }

    private static func makeOperations(
        kind: OperationKind,
        rootTypeName: String,
        types:
            [String: TypeDefinition],
        providerFingerprint:
            String
    ) -> [Operation] {
        guard
            let root =
                types[
                    rootTypeName
                ]
        else {
            return []
        }

        return root.fields
            .compactMap {
                field
                in

                guard
                    field
                        .arguments
                        .allSatisfy({
                            supportsInputType(
                                $0.type,
                                types:
                                    types
                            )
                        }),
                    let selection =
                        selection(
                            for:
                                field.type,
                            types:
                                types,
                            depth:
                                0,
                            visited:
                                []
                        )
                else {
                    return nil
                }

                let argumentSignature =
                    field
                        .arguments
                        .map {
                            $0.name
                            + ":"
                            + $0
                                .type
                                .graphQLType
                            + ":"
                            + (
                                $0.defaultValue
                                ?? ""
                            )
                        }
                        .joined(
                            separator:
                                ","
                        )

                let operationMaterial =
                    kind.rawValue
                    + "\n"
                    + field.name
                    + "\n"
                    + argumentSignature
                    + "\n"
                    + field
                        .type
                        .graphQLType

                let operationFingerprint =
                    String(
                        sha256Hex(
                            Data(
                                operationMaterial
                                    .utf8
                            )
                        )
                        .prefix(16)
                    )

                let encodedField =
                    field.name
                        .addingPercentEncoding(
                            withAllowedCharacters:
                                .alphanumerics
                        )
                    ?? field.name

                let capabilityID =
                    "graphql:"
                    + providerFingerprint
                    + ":"
                    + operationFingerprint
                    + ":"
                    + encodedField

                let title =
                    (
                        kind
                            == .mutation
                        ? "GraphQL mutation: "
                        : "GraphQL query: "
                    )
                    + field.name

                return Operation(
                    capabilityID:
                        capabilityID,
                    kind:
                        kind,
                    field:
                        field.name,
                    title:
                        title,
                    arguments:
                        field.arguments,
                    returnType:
                        field.type,
                    selection:
                        selection
                )
            }
    }

    private static func supportsInputType(
        _ type: TypeRef,
        types:
            [String: TypeDefinition],
        visited:
            Set<String> = []
    ) -> Bool {
        switch type {
        case let .nonNull(
            inner
        ),
            let .list(
                inner
            ):
            return
                supportsInputType(
                    inner,
                    types:
                        types,
                    visited:
                        visited
                )

        case let .named(
            kind,
            name
        ):
            if
                kind == "SCALAR"
                || kind == "ENUM"
            {
                return true
            }

            guard
                kind == "INPUT_OBJECT",
                !visited
                    .contains(
                        name
                    ),
                let definition =
                    types[
                        name
                    ]
            else {
                return false
            }

            var nextVisited =
                visited

            nextVisited.insert(
                name
            )

            return definition
                .inputFields
                .allSatisfy {
                    supportsInputType(
                        $0.type,
                        types:
                            types,
                        visited:
                            nextVisited
                    )
                }
        }
    }

    private static func selection(
        for type: TypeRef,
        types:
            [String: TypeDefinition],
        depth: Int,
        visited:
            Set<String>
    ) -> String? {
        switch type {
        case let .nonNull(
            inner
        ),
            let .list(
                inner
            ):
            return
                selection(
                    for:
                        inner,
                    types:
                        types,
                    depth:
                        depth,
                    visited:
                        visited
                )

        case let .named(
            kind,
            name
        ):
            if
                kind == "SCALAR"
                || kind == "ENUM"
            {
                return ""
            }

            if
                kind == "UNION"
                || kind == "INTERFACE"
            {
                return
                    " { __typename }"
            }

            guard
                kind == "OBJECT",
                let definition =
                    types[
                        name
                    ]
            else {
                return nil
            }

            if
                depth >= 3
                || visited
                    .contains(
                        name
                    )
            {
                return
                    " { __typename }"
            }

            var nextVisited =
                visited

            nextVisited.insert(
                name
            )

            var selections:
                [String] = [
                    "__typename"
                ]

            for field
                in definition
                    .fields
                    .filter({
                        $0.arguments
                            .isEmpty
                    })
                    .prefix(16)
            {
                guard
                    let nested =
                        selection(
                            for:
                                field.type,
                            types:
                                types,
                            depth:
                                depth
                                + 1,
                            visited:
                                nextVisited
                        )
                else {
                    continue
                }

                selections.append(
                    field.name
                    + nested
                )
            }

            return
                " { "
                + selections
                    .joined(
                        separator:
                            " "
                    )
                + " }"
        }
    }

    private static func argumentsSchema(
        _ arguments:
            [InputField],
        types:
            [String: TypeDefinition]
    ) -> String {
        var properties:
            [String: Any] = [:]

        var required:
            [String] = []

        for argument
            in arguments
        {
            let named =
                argument
                    .type
                    .namedType

            var description =
                "GraphQL type "
                + argument
                    .type
                    .graphQLType
                + "."

            if
                named?.kind
                    == "INPUT_OBJECT"
                || Self.containsList(
                    argument.type
                )
            {
                description +=
                    " Supply this argument as a JSON-encoded string."
            } else {
                description +=
                    " Supply this argument as a string; RIGHTCLICK coerces it to the reflected GraphQL scalar or enum type."
            }

            if
                let named,
                named.kind
                    == "ENUM",
                let values =
                    types[
                        named.name
                    ]?
                    .enumValues,
                !values.isEmpty
            {
                description +=
                    " Allowed values: "
                    + values
                        .sorted()
                        .joined(
                            separator:
                                ", "
                        )
                    + "."
            }

            properties[
                argument.name
            ] = [
                "type":
                    "string",
                "description":
                    description,
            ]

            if
                argument
                    .type
                    .isNonNull,
                argument
                    .defaultValue
                    == nil
            {
                required.append(
                    argument.name
                )
            }
        }

        var schema:
            [String: Any] = [
                "type":
                    "object",
                "additionalProperties":
                    false,
                "properties":
                    properties,
            ]

        if !required
            .isEmpty
        {
            schema[
                "required"
            ] =
                required.sorted()
        }

        guard
            let data =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            schema,
                        options:
                            [.sortedKeys]
                    ),
            let text =
                String(
                    data:
                        data,
                    encoding:
                        .utf8
                )
        else {
            return
                "{\"type\":\"object\"}"
        }

        return text
    }

    private static func containsList(
        _ type: TypeRef
    ) -> Bool {
        switch type {
        case .list:
            return true

        case let .nonNull(
            inner
        ):
            return
                containsList(
                    inner
                )

        case .named:
            return false
        }
    }

    private static func canonicalJSON(
        _ value: Any
    ) -> String? {
        guard
            JSONSerialization
                .isValidJSONObject(
                    value
                ),
            let data =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            value,
                        options:
                            [.sortedKeys]
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
