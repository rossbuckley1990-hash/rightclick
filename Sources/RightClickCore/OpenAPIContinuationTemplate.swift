import Foundation
import CryptoKit
import CoreFoundation

enum OpenAPIContinuationValue: Equatable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case null

    static func fromJSON(_ value: Any) -> OpenAPIContinuationValue? {
        if value is NSNull {
            return .null
        }

        if let string = value as? String {
            return .string(string)
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }

            let doubleValue = number.doubleValue
            let integerValue = number.int64Value

            if Double(integerValue) == doubleValue {
                return .integer(integerValue)
            }

            return .number(doubleValue)
        }

        return nil
    }

    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value

        case .integer(let value):
            return NSNumber(value: value)

        case .number(let value):
            return NSNumber(value: value)

        case .boolean(let value):
            return NSNumber(value: value)

        case .null:
            return NSNull()
        }
    }

    var stableDescription: String {
        switch self {
        case .string(let value):
            return "s:" + value

        case .integer(let value):
            return "i:" + String(value)

        case .number(let value):
            return "n:" + String(value)

        case .boolean(let value):
            return "b:" + String(value)

        case .null:
            return "null"
        }
    }
}

struct OpenAPIContinuationSchema: Equatable {
    let type: String?
    let format: String?

    func accepts(_ value: OpenAPIContinuationValue) -> Bool {
        guard let type else {
            return true
        }

        switch (type.lowercased(), value) {
        case ("string", .string):
            return true

        case ("integer", .integer):
            return true

        case ("number", .integer):
            return true

        case ("number", .number):
            return true

        case ("boolean", .boolean):
            return true

        default:
            return false
        }
    }

    func conflicts(with other: OpenAPIContinuationSchema) -> Bool {
        guard
            let lhs = type?.lowercased(),
            let rhs = other.type?.lowercased()
        else {
            return false
        }

        if lhs == rhs {
            return false
        }

        if Set([lhs, rhs]).isSubset(of: ["integer", "number"]) {
            return false
        }

        return true
    }
}

struct OpenAPIContinuationParameter: Equatable {
    let location: String
    let name: String
    let schema: OpenAPIContinuationSchema

    var normalizedName: String {
        Self.normalize(name)
    }

    var argumentKey: String {
        location.lowercased() + ":" + name
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

struct OpenAPIContinuationHandleSelector: Equatable {
    let statusCode: Int
    let mediaType: String?
    let propertyPath: [String]
    let propertyName: String
    let schema: OpenAPIContinuationSchema

    var safeSelectorDescription: String {
        "$." + propertyPath.joined(separator: ".")
    }
}

struct OpenAPIContinuationCarriedBinding: Equatable {
    let issuerSourceKey: String
    let issuerSourceName: String
    let targetParameter: OpenAPIContinuationParameter
}

enum OpenAPIContinuationSecurityRequirement: String, Equatable {
    case anonymous
    case credentialRequired
    case unresolved
}


enum OpenAPIContinuationRequestBodyKind: String, Equatable {
    case json
    case bytes
}

struct OpenAPIContinuationRequestBodyContract: Equatable {
    let kind: OpenAPIContinuationRequestBodyKind
    let mediaType: String
    let required: Bool
}

struct OpenAPIContinuationSecuritySchemeContract: Equatable {
    let name: String
    let kind: String
    let credentialHeaderName: String
}

struct OpenAPIContinuationSecurityAlternative: Equatable {
    let schemes: [OpenAPIContinuationSecuritySchemeContract]

    var schemeNames: [String] {
        schemes.map(\.name).sorted()
    }

    var schemeKinds: [String] {
        schemes.map(\.kind).sorted()
    }

    var credentialHeaderNames: [String] {
        schemes.map(\.credentialHeaderName).sorted()
    }

    var fingerprintSHA256: String {
        let canonical = schemes
            .sorted {
                if $0.name != $1.name {
                    return $0.name < $1.name
                }
                if $0.kind != $1.kind {
                    return $0.kind < $1.kind
                }
                return $0.credentialHeaderName.lowercased()
                    < $1.credentialHeaderName.lowercased()
            }
            .map {
                $0.name
                    + "\n"
                    + $0.kind
                    + "\n"
                    + $0.credentialHeaderName.lowercased()
            }
            .joined(separator: "\n---\n")

        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum OpenAPIContinuationTemplateDerivation {
    case derived(OpenAPIContinuationTemplate)
    case abstain(String)
}

struct OpenAPIContinuationTemplate {
    let contractID: String
    let providerSpecificationSHA256: String
    let providerOrigin: String

    let issuerOperationID: String
    let targetOperationID: String
    let targetMethod: String
    let targetPathTemplate: String

    let handleTarget: OpenAPIContinuationParameter
    let handleSelectors: [OpenAPIContinuationHandleSelector]

    let carriedContextBindings: [OpenAPIContinuationCarriedBinding]
    let ordinaryRequiredArguments: [OpenAPIContinuationParameter]
    let ordinaryOptionalArguments: [OpenAPIContinuationParameter]

    let requestBodyContract: OpenAPIContinuationRequestBodyContract?

    let targetSecurityRequirement: OpenAPIContinuationSecurityRequirement
    let targetSecurityAlternatives: [OpenAPIContinuationSecurityAlternative]

    var selectedExecutionSecurityAlternative:
        OpenAPIContinuationSecurityAlternative?
    {
        let bearer = targetSecurityAlternatives.filter {
            $0.schemes.count == 1
                && $0.schemes[0].kind == "http:bearer"
        }

        if bearer.count == 1 {
            return bearer[0]
        }

        if bearer.count > 1 {
            return nil
        }

        let headerAPIKey = targetSecurityAlternatives.filter {
            $0.schemes.count == 1
                && $0.schemes[0].kind == "apiKey:header"
        }

        return headerAPIKey.count == 1
            ? headerAPIKey[0]
            : nil
    }

    var requiresConfirmation: Bool {
        targetMethod.uppercased() != "GET"
    }

    static func derive(
        specificationData: Data,
        providerBaseURL: URL,
        issuerOperationID: String,
        targetOperationID: String
    ) -> OpenAPIContinuationTemplateDerivation {
        guard
            let parsed = try? JSONSerialization.jsonObject(
                with: specificationData
            ),
            let root = parsed as? [String: Any]
        else {
            return .abstain("invalid_openapi_json")
        }

        let operations = OpenAPIContinuationSpecReader.operations(
            root: root
        )

        let issuers = operations.filter {
            $0.operationID == issuerOperationID
        }

        guard issuers.count == 1 else {
            return .abstain("ambiguous_or_missing_issuer")
        }

        let targets = operations.filter {
            $0.operationID == targetOperationID
        }

        guard targets.count == 1 else {
            return .abstain("ambiguous_or_missing_target")
        }

        let issuer = issuers[0]
        let target = targets[0]

        let issuerSourcesResult =
            OpenAPIContinuationSpecReader.issuerInputSources(
                root: root,
                operation: issuer
            )

        switch issuerSourcesResult {
        case .failure(let reason):
            return .abstain(reason)

        case .success:
            break
        }

        guard
            case .success(let issuerSources)
                = issuerSourcesResult
        else {
            return .abstain("issuer_input_resolution_failed")
        }

        guard
            let targetParameterContracts =
                OpenAPIContinuationSpecReader
                    .supportedTargetParameterContracts(
                        root: root,
                        operation: target
                    )
        else {
            return .abstain(
                "unsupported_or_invalid_target_parameter_contract"
            )
        }

        let targetParameters =
            targetParameterContracts
                .filter(\.required)
                .map(\.parameter)

        guard !targetParameters.isEmpty else {
            return .abstain("target_has_no_required_parameters")
        }

        let ordinaryOptional =
            targetParameterContracts
                .filter { !$0.required }
                .map(\.parameter)

        let requestBodyResult =
            OpenAPIContinuationSpecReader
                .requestBodyContract(
                    root: root,
                    operation: target
                )

        let requestBodyContract:
            OpenAPIContinuationRequestBodyContract?

        switch requestBodyResult {
        case .success(let contract):
            requestBodyContract = contract

        case .failure(let reason):
            return .abstain(reason)
        }

        let issuerNames = Set(
            issuerSources.map(\.normalizedName)
        )

        var handleCandidates: [
            (
                parameter: OpenAPIContinuationParameter,
                selectors: [OpenAPIContinuationHandleSelector]
            )
        ] = []

        for parameter in targetParameters {
            if issuerNames.contains(parameter.normalizedName) {
                continue
            }

            let selectorResult =
                OpenAPIContinuationSpecReader.responseHandleSelectors(
                    root: root,
                    operation: issuer,
                    normalizedName: parameter.normalizedName
                )

            switch selectorResult {
            case .failure(let reason):
                return .abstain(reason)

            case .success(let selectors):
                if !selectors.isEmpty {
                    handleCandidates.append(
                        (
                            parameter: parameter,
                            selectors: selectors
                        )
                    )
                }
            }
        }

        guard handleCandidates.count == 1 else {
            return .abstain("ambiguous_or_missing_handle_candidate")
        }

        let handle = handleCandidates[0]

        for selector in handle.selectors {
            if selector.schema.conflicts(
                with: handle.parameter.schema
            ) {
                return .abstain("handle_schema_conflict")
            }
        }

        let sourceGroups = Dictionary(
            grouping: issuerSources,
            by: \.normalizedName
        )

        var carried: [OpenAPIContinuationCarriedBinding] = []
        var ordinary: [OpenAPIContinuationParameter] = []

        for parameter in targetParameters {
            if parameter.normalizedName
                == handle.parameter.normalizedName {
                continue
            }

            let matches = sourceGroups[
                parameter.normalizedName,
                default: []
            ]

            if matches.count > 1 {
                return .abstain("ambiguous_carried_context_binding")
            }

            if let source = matches.first {
                if source.schema.conflicts(
                    with: parameter.schema
                ) {
                    return .abstain("carried_context_schema_conflict")
                }

                carried.append(
                    OpenAPIContinuationCarriedBinding(
                        issuerSourceKey: source.sourceKey,
                        issuerSourceName: source.originalName,
                        targetParameter: parameter
                    )
                )
            } else {
                ordinary.append(parameter)
            }
        }

        guard
            let providerOrigin =
                OpenAPIContinuationSpecReader.originString(
                    from: providerBaseURL
                )
        else {
            return .abstain("invalid_provider_origin")
        }

        guard target.endpoint.hasPrefix("/") else {
            return .abstain("invalid_target_path_template")
        }

        guard
            let providerBaseComponents =
                URLComponents(
                    url: providerBaseURL,
                    resolvingAgainstBaseURL: false
                ),
            providerBaseComponents.query == nil,
            providerBaseComponents.fragment == nil
        else {
            return .abstain("invalid_provider_base_url")
        }

        var providerBasePath =
            providerBaseComponents.percentEncodedPath

        while
            providerBasePath.count > 1
            && providerBasePath.hasSuffix("/")
        {
            providerBasePath.removeLast()
        }

        if providerBasePath == "/" {
            providerBasePath = ""
        }

        let materializedTargetPathTemplate =
            providerBasePath
            + target.endpoint

        return .derived(
            OpenAPIContinuationTemplate(
                contractID:
                    "provider-neutral-continuation-template-v1",

                providerSpecificationSHA256:
                    OpenAPIContinuationSpecReader.sha256(
                        specificationData
                    ),

                providerOrigin:
                    providerOrigin,

                issuerOperationID:
                    issuerOperationID,

                targetOperationID:
                    targetOperationID,

                targetMethod:
                    target.method,

                targetPathTemplate:
                    materializedTargetPathTemplate,

                handleTarget:
                    handle.parameter,

                handleSelectors:
                    handle.selectors,

                carriedContextBindings:
                    carried,

                ordinaryRequiredArguments:
                    ordinary,

                ordinaryOptionalArguments:
                    ordinaryOptional,

                requestBodyContract:
                    requestBodyContract,

                targetSecurityRequirement:
                    OpenAPIContinuationSpecReader.securityRequirement(
                        root: root,
                        operation: target.operation
                    ),

                targetSecurityAlternatives:
                    OpenAPIContinuationSpecReader
                        .securityAlternatives(
                            root: root,
                            operation: target.operation
                        )
            )
        )
    }
}

private struct OpenAPIContinuationOperation {
    let endpoint: String
    let method: String
    let operationID: String?
    let operation: [String: Any]
    let pathObject: [String: Any]
}

private struct OpenAPIContinuationIssuerSource {
    let normalizedName: String
    let originalName: String
    let sourceKey: String
    let schema: OpenAPIContinuationSchema
}

private enum OpenAPIContinuationSourceResult {
    case success([OpenAPIContinuationIssuerSource])
    case failure(String)
}

private enum OpenAPIContinuationSelectorResult {
    case success([OpenAPIContinuationHandleSelector])
    case failure(String)
}


private struct OpenAPIContinuationTargetParameterContract {
    let parameter: OpenAPIContinuationParameter
    let required: Bool
}

private enum OpenAPIContinuationRequestBodyResult {
    case success(OpenAPIContinuationRequestBodyContract?)
    case failure(String)
}

private enum OpenAPIContinuationSpecReader {
    static let methods: Set<String> = [
        "get",
        "post",
        "put",
        "patch",
        "delete"
    ]

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func originString(from url: URL) -> String? {
        guard
            let scheme = url.scheme,
            let host = url.host
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port

        return components.url?.absoluteString
            .trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "/"
                )
            )
    }

    static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func operations(
        root: [String: Any]
    ) -> [OpenAPIContinuationOperation] {
        guard
            let paths = root["paths"]
                as? [String: Any]
        else {
            return []
        }

        var result: [OpenAPIContinuationOperation] = []

        for (endpoint, rawPath) in paths {
            guard
                let pathObject = rawPath
                    as? [String: Any]
            else {
                continue
            }

            for (rawMethod, rawOperation) in pathObject {
                let method = rawMethod.lowercased()

                guard methods.contains(method) else {
                    continue
                }

                guard
                    let expanded = expand(
                        root: root,
                        value: rawOperation
                    ) as? [String: Any]
                else {
                    continue
                }

                result.append(
                    OpenAPIContinuationOperation(
                        endpoint: endpoint,
                        method: method.uppercased(),
                        operationID:
                            expanded["operationId"]
                                as? String,
                        operation: expanded,
                        pathObject: pathObject
                    )
                )
            }
        }

        return result
    }


    static func supportedTargetParameterContracts(
        root: [String: Any],
        operation: OpenAPIContinuationOperation
    ) -> [OpenAPIContinuationTargetParameterContract]? {
        var result: [OpenAPIContinuationTargetParameterContract] = []

        for parameter in combinedParameters(
            root: root,
            operation: operation
        ) {
            guard
                let name = parameter["name"] as? String,
                let rawLocation = parameter["in"] as? String
            else {
                return nil
            }

            let location = rawLocation.lowercased()

            guard location == "path" || location == "header" else {
                return nil
            }

            let required = parameter["required"] as? Bool ?? false

            if location == "path" && !required {
                return nil
            }

            result.append(
                OpenAPIContinuationTargetParameterContract(
                    parameter:
                        OpenAPIContinuationParameter(
                            location: location,
                            name: name,
                            schema:
                                schema(
                                    fromParameter: parameter
                                )
                        ),
                    required: required
                )
            )
        }

        return result
    }

    static func requestBodyContract(
        root: [String: Any],
        operation: OpenAPIContinuationOperation
    ) -> OpenAPIContinuationRequestBodyResult {
        guard operation.operation.keys.contains("requestBody") else {
            return .success(nil)
        }

        guard
            let rawBody = operation.operation["requestBody"],
            let body = expand(
                root: root,
                value: rawBody
            ) as? [String: Any],
            let content = body["content"] as? [String: Any],
            !content.isEmpty
        else {
            return .failure(
                "invalid_target_request_body_contract"
            )
        }

        let supported = content.keys.compactMap {
            raw -> (
                media: String,
                kind: OpenAPIContinuationRequestBodyKind
            )? in

            let media = raw
                .split(
                    separator: ";",
                    maxSplits: 1,
                    omittingEmptySubsequences: true
                )
                .first
                .map(String.init)?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .lowercased()
                ?? ""

            switch media {
            case "application/json":
                return (media, .json)
            case "application/octet-stream":
                return (media, .bytes)
            default:
                return nil
            }
        }

        guard supported.count == 1 else {
            if supported.isEmpty {
                return .failure(
                    "unsupported_target_request_body_media"
                )
            }

            return .failure(
                "ambiguous_target_request_body_media"
            )
        }

        let selected = supported[0]

        return .success(
            OpenAPIContinuationRequestBodyContract(
                kind: selected.kind,
                mediaType: selected.media,
                required:
                    body["required"] as? Bool
                    ?? false
            )
        )
    }

    static func securityAlternatives(
        root: [String: Any],
        operation: [String: Any]
    ) -> [OpenAPIContinuationSecurityAlternative] {
        let rawSecurity: Any?

        if operation.keys.contains("security") {
            rawSecurity = operation["security"]
        } else {
            rawSecurity = root["security"]
        }

        guard
            let security = rawSecurity as? [Any],
            !security.isEmpty
        else {
            return []
        }

        var alternatives:
            [OpenAPIContinuationSecurityAlternative] = []

        for rawRequirement in security {
            guard
                let requirement =
                    rawRequirement as? [String: Any],
                !requirement.isEmpty
            else {
                return []
            }

            var schemes:
                [OpenAPIContinuationSecuritySchemeContract] = []

            for schemeName in requirement.keys.sorted() {
                guard
                    let scheme = securitySchemeContract(
                        named: schemeName,
                        root: root
                    )
                else {
                    return []
                }

                schemes.append(scheme)
            }

            alternatives.append(
                OpenAPIContinuationSecurityAlternative(
                    schemes: schemes
                )
            )
        }

        return alternatives
    }

    static func securitySchemeContract(
        named name: String,
        root: [String: Any]
    ) -> OpenAPIContinuationSecuritySchemeContract? {
        let rawDefinitions: [String: Any]?

        if
            let components =
                root["components"] as? [String: Any],
            let schemes =
                components["securitySchemes"]
                    as? [String: Any]
        {
            rawDefinitions = schemes
        } else {
            rawDefinitions =
                root["securityDefinitions"]
                    as? [String: Any]
        }

        guard
            let definitions = rawDefinitions,
            let rawScheme = definitions[name],
            let scheme = expand(
                root: root,
                value: rawScheme
            ) as? [String: Any],
            let type =
                (scheme["type"] as? String)?
                    .lowercased()
        else {
            return nil
        }

        if type == "http" {
            guard
                (scheme["scheme"] as? String)?
                    .lowercased()
                    == "bearer"
            else {
                return nil
            }

            return OpenAPIContinuationSecuritySchemeContract(
                name: name,
                kind: "http:bearer",
                credentialHeaderName: "Authorization"
            )
        }

        if type == "apikey" {
            guard
                (scheme["in"] as? String)?
                    .lowercased()
                    == "header",
                let headerName =
                    scheme["name"] as? String,
                !headerName.isEmpty
            else {
                return nil
            }

            return OpenAPIContinuationSecuritySchemeContract(
                name: name,
                kind: "apiKey:header",
                credentialHeaderName: headerName
            )
        }

        return nil
    }

    static func requiredTargetParameters(
        root: [String: Any],
        operation: OpenAPIContinuationOperation
    ) -> [OpenAPIContinuationParameter] {
        combinedParameters(
            root: root,
            operation: operation
        )
        .compactMap { parameter in
            guard
                parameter["required"] as? Bool == true,
                let name = parameter["name"] as? String,
                let location = parameter["in"] as? String
            else {
                return nil
            }

            return OpenAPIContinuationParameter(
                location: location.lowercased(),
                name: name,
                schema: schema(
                    fromParameter: parameter
                )
            )
        }
    }

    static func issuerInputSources(
        root: [String: Any],
        operation: OpenAPIContinuationOperation
    ) -> OpenAPIContinuationSourceResult {
        var sources: [OpenAPIContinuationIssuerSource] = []

        for parameter in combinedParameters(
            root: root,
            operation: operation
        ) {
            guard
                let name = parameter["name"] as? String,
                let location = parameter["in"] as? String
            else {
                continue
            }

            if location.lowercased() == "body" {
                if
                    let rawSchema = parameter["schema"],
                    let bodySchema = expand(
                        root: root,
                        value: rawSchema
                    ) as? [String: Any]
                {
                    collectBodySources(
                        root: root,
                        schema: bodySchema,
                        prefix:
                            "body-parameter:"
                            + name
                            + ":$",
                        into: &sources
                    )
                }

                continue
            }

            sources.append(
                OpenAPIContinuationIssuerSource(
                    normalizedName:
                        normalize(name),
                    originalName:
                        name,
                    sourceKey:
                        "parameter:"
                        + location.lowercased()
                        + ":"
                        + name,
                    schema:
                        schema(
                            fromParameter: parameter
                        )
                )
            )
        }

        if
            let rawBody = operation.operation[
                "requestBody"
            ],
            let body = expand(
                root: root,
                value: rawBody
            ) as? [String: Any],
            let content = body["content"]
                as? [String: Any]
        {
            for (media, rawEntry) in content {
                guard
                    let entry = rawEntry
                        as? [String: Any],
                    let rawSchema = entry["schema"],
                    let requestSchema = expand(
                        root: root,
                        value: rawSchema
                    ) as? [String: Any]
                else {
                    continue
                }

                collectBodySources(
                    root: root,
                    schema: requestSchema,
                    prefix:
                        "body:"
                        + media
                        + ":$",
                    into: &sources
                )
            }
        }

        return .success(sources)
    }

    static func responseHandleSelectors(
        root: [String: Any],
        operation: OpenAPIContinuationOperation,
        normalizedName: String
    ) -> OpenAPIContinuationSelectorResult {
        guard
            let responses = operation.operation[
                "responses"
            ] as? [String: Any]
        else {
            return .success([])
        }

        var selectors: [OpenAPIContinuationHandleSelector] = []

        for (rawStatus, rawResponse) in responses {
            guard
                let status = Int(rawStatus),
                (200...299).contains(status),
                let response = expand(
                    root: root,
                    value: rawResponse
                ) as? [String: Any]
            else {
                continue
            }

            if
                let content = response["content"]
                    as? [String: Any]
            {
                for (media, rawEntry) in content {
                    guard
                        let entry = rawEntry
                            as? [String: Any],
                        let rawSchema = entry["schema"],
                        let responseSchema = expand(
                            root: root,
                            value: rawSchema
                        ) as? [String: Any]
                    else {
                        continue
                    }

                    var matches: [
                        (
                            path: [String],
                            property: String,
                            schema: OpenAPIContinuationSchema
                        )
                    ] = []

                    findProperties(
                        root: root,
                        schema: responseSchema,
                        normalizedName: normalizedName,
                        path: [],
                        into: &matches
                    )

                    if matches.count > 1 {
                        return .failure(
                            "ambiguous_handle_selector"
                        )
                    }

                    if let match = matches.first {
                        selectors.append(
                            OpenAPIContinuationHandleSelector(
                                statusCode: status,
                                mediaType: media,
                                propertyPath: match.path,
                                propertyName: match.property,
                                schema: match.schema
                            )
                        )
                    }
                }
            }

            if let rawSchema = response["schema"] {
                guard
                    let responseSchema = expand(
                        root: root,
                        value: rawSchema
                    ) as? [String: Any]
                else {
                    continue
                }

                var matches: [
                    (
                        path: [String],
                        property: String,
                        schema: OpenAPIContinuationSchema
                    )
                ] = []

                findProperties(
                    root: root,
                    schema: responseSchema,
                    normalizedName: normalizedName,
                    path: [],
                    into: &matches
                )

                if matches.count > 1 {
                    return .failure(
                        "ambiguous_handle_selector"
                    )
                }

                if let match = matches.first {
                    selectors.append(
                        OpenAPIContinuationHandleSelector(
                            statusCode: status,
                            mediaType: nil,
                            propertyPath: match.path,
                            propertyName: match.property,
                            schema: match.schema
                        )
                    )
                }
            }
        }

        return .success(selectors)
    }

    static func securityRequirement(
        root: [String: Any],
        operation: [String: Any]
    ) -> OpenAPIContinuationSecurityRequirement {
        let rawSecurity: Any?

        if operation.keys.contains("security") {
            rawSecurity = operation["security"]
        } else {
            rawSecurity = root["security"]
        }

        guard let rawSecurity else {
            return .unresolved
        }

        guard
            let security = rawSecurity as? [Any]
        else {
            return .unresolved
        }

        if security.isEmpty {
            return .anonymous
        }

        var sawRequirement = false

        for item in security {
            guard
                let requirement = item
                    as? [String: Any]
            else {
                return .unresolved
            }

            if requirement.isEmpty {
                return .anonymous
            }

            sawRequirement = true
        }

        return sawRequirement
            ? .credentialRequired
            : .unresolved
    }

    static func combinedParameters(
        root: [String: Any],
        operation: OpenAPIContinuationOperation
    ) -> [[String: Any]] {
        var merged: [
            String: [String: Any]
        ] = [:]

        let collections: [Any?] = [
            operation.pathObject["parameters"],
            operation.operation["parameters"]
        ]

        for rawCollection in collections {
            guard
                let parameters = rawCollection
                    as? [Any]
            else {
                continue
            }

            for rawParameter in parameters {
                guard
                    let parameter = expand(
                        root: root,
                        value: rawParameter
                    ) as? [String: Any],
                    let name = parameter["name"]
                        as? String,
                    let location = parameter["in"]
                        as? String
                else {
                    continue
                }

                merged[
                    location.lowercased()
                    + ":"
                    + normalize(name)
                ] = parameter
            }
        }

        return Array(merged.values)
    }

    static func schema(
        fromParameter parameter: [String: Any]
    ) -> OpenAPIContinuationSchema {
        if
            let rawSchema = parameter["schema"]
                as? [String: Any]
        {
            return OpenAPIContinuationSchema(
                type: rawSchema["type"] as? String,
                format: rawSchema["format"] as? String
            )
        }

        return OpenAPIContinuationSchema(
            type: parameter["type"] as? String,
            format: parameter["format"] as? String
        )
    }

    static func schema(
        fromObject value: [String: Any]
    ) -> OpenAPIContinuationSchema {
        OpenAPIContinuationSchema(
            type: value["type"] as? String,
            format: value["format"] as? String
        )
    }

    static func collectBodySources(
        root: [String: Any],
        schema: [String: Any],
        prefix: String,
        into output:
            inout [OpenAPIContinuationIssuerSource]
    ) {
        guard
            let properties = schema["properties"]
                as? [String: Any]
        else {
            return
        }

        for (name, rawChild) in properties {
            guard
                let child = expand(
                    root: root,
                    value: rawChild
                ) as? [String: Any]
            else {
                continue
            }

            let childPrefix =
                prefix
                + "."
                + name

            output.append(
                OpenAPIContinuationIssuerSource(
                    normalizedName:
                        normalize(name),
                    originalName:
                        name,
                    sourceKey:
                        childPrefix,
                    schema:
                        Self.schema(
                            fromObject: child
                        )
                )
            )

            collectBodySources(
                root: root,
                schema: child,
                prefix: childPrefix,
                into: &output
            )
        }
    }

    static func findProperties(
        root: [String: Any],
        schema: [String: Any],
        normalizedName: String,
        path: [String],
        into output:
            inout [
                (
                    path: [String],
                    property: String,
                    schema: OpenAPIContinuationSchema
                )
            ]
    ) {
        guard
            let properties = schema["properties"]
                as? [String: Any]
        else {
            return
        }

        for (name, rawChild) in properties {
            guard
                let child = expand(
                    root: root,
                    value: rawChild
                ) as? [String: Any]
            else {
                continue
            }

            let childPath = path + [name]

            if normalize(name) == normalizedName {
                output.append(
                    (
                        path: childPath,
                        property: name,
                        schema:
                            Self.schema(
                                fromObject: child
                            )
                    )
                )
            }

            findProperties(
                root: root,
                schema: child,
                normalizedName: normalizedName,
                path: childPath,
                into: &output
            )
        }
    }

    static func expand(
        root: [String: Any],
        value: Any,
        depth: Int = 0,
        seen: Set<String> = []
    ) -> Any {
        guard depth <= 48 else {
            return value
        }

        if let array = value as? [Any] {
            return array.map {
                expand(
                    root: root,
                    value: $0,
                    depth: depth + 1,
                    seen: seen
                )
            }
        }

        guard
            var object = value
                as? [String: Any]
        else {
            return value
        }

        if let reference = object["$ref"] as? String {
            guard
                reference.hasPrefix("#/"),
                !seen.contains(reference),
                let resolved = resolve(
                    root: root,
                    reference: reference
                ) as? [String: Any]
            else {
                return object
            }

            var merged = resolved

            for (key, child) in object
            where key != "$ref" {
                merged[key] = child
            }

            var nextSeen = seen
            nextSeen.insert(reference)

            return expand(
                root: root,
                value: merged,
                depth: depth + 1,
                seen: nextSeen
            )
        }

        for (key, child) in object {
            object[key] = expand(
                root: root,
                value: child,
                depth: depth + 1,
                seen: seen
            )
        }

        if let allOf = object["allOf"] as? [Any] {
            var merged:
                [String: Any] = [:]

            var mergedProperties:
                [String: Any] = [:]

            var required:
                [String] = []

            for rawBranch in allOf {
                guard
                    let branch = rawBranch
                        as? [String: Any]
                else {
                    continue
                }

                if
                    let properties = branch[
                        "properties"
                    ] as? [String: Any]
                {
                    for (key, value) in properties {
                        mergedProperties[key] = value
                    }
                }

                if
                    let branchRequired = branch[
                        "required"
                    ] as? [String]
                {
                    required.append(
                        contentsOf: branchRequired
                    )
                }

                for (key, value) in branch
                where
                    key != "properties"
                    && key != "required"
                {
                    if merged[key] == nil {
                        merged[key] = value
                    }
                }
            }

            if
                let directProperties = object[
                    "properties"
                ] as? [String: Any]
            {
                for (key, value) in directProperties {
                    mergedProperties[key] = value
                }
            }

            if !mergedProperties.isEmpty {
                merged["properties"] =
                    mergedProperties
            }

            if
                let directRequired = object[
                    "required"
                ] as? [String]
            {
                required.append(
                    contentsOf: directRequired
                )
            }

            if !required.isEmpty {
                merged["required"] =
                    Array(Set(required)).sorted()
            }

            for (key, value) in object
            where
                key != "allOf"
                && key != "properties"
                && key != "required"
            {
                merged[key] = value
            }

            return merged
        }

        return object
    }

    static func resolve(
        root: [String: Any],
        reference: String
    ) -> Any? {
        guard reference.hasPrefix("#/") else {
            return nil
        }

        var current: Any = root

        let components = reference
            .dropFirst(2)
            .split(separator: "/")
            .map {
                String($0)
                    .replacingOccurrences(
                        of: "~1",
                        with: "/"
                    )
                    .replacingOccurrences(
                        of: "~0",
                        with: "~"
                    )
            }

        for component in components {
            guard
                let object = current
                    as? [String: Any],
                let next = object[component]
            else {
                return nil
            }

            current = next
        }

        return current
    }
}
