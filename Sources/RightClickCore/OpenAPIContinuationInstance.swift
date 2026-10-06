import Foundation
import CryptoKit

enum OpenAPIContinuationInstanceBinding {
    case bound(OpenAPIContinuationInstance)
    case abstain(String)
}

enum OpenAPIContinuationArgumentBinding {
    case bound([String: OpenAPIContinuationValue])
    case rejected(String)
    case inputContractFailure(String)
}

enum OpenAPIContinuationExecutionAuthorityState {
    case unavailable
    case available
}

enum OpenAPIContinuationTransitionResolution {
    case rejected(String)
    case abstain(String)
    case inputContractFailure(String)
    case credentialRequired
    case confirmationRequired
    case ready(OpenAPIContinuationResolvedTransition)
}

enum OpenAPIContinuationProviderOutcome: Equatable {
    case providerAcceptedSemanticUnverified(Int)
    case providerRejected(Int)

    static func classify(
        statusCode: Int
    ) -> OpenAPIContinuationProviderOutcome {
        if (200...299).contains(statusCode) {
            return .providerAcceptedSemanticUnverified(
                statusCode
            )
        }

        return .providerRejected(statusCode)
    }
}

struct OpenAPIContinuationResolvedTransition {
    let targetOperationID: String
    let targetMethod: String
    let providerOrigin: String

    private let boundArguments:
        [String: OpenAPIContinuationValue]

    init(
        targetOperationID: String,
        targetMethod: String,
        providerOrigin: String,
        boundArguments:
            [String: OpenAPIContinuationValue]
    ) {
        self.targetOperationID =
            targetOperationID

        self.targetMethod =
            targetMethod

        self.providerOrigin =
            providerOrigin

        self.boundArguments =
            boundArguments
    }

    func withBoundArguments<T>(
        _ body:
            ([String: OpenAPIContinuationValue])
            throws -> T
    ) rethrows -> T {
        try body(boundArguments)
    }
}

struct OpenAPIContinuationInstance {
    let contractID: String
    let providerSpecificationSHA256: String

    let issuerOperationID: String
    let targetOperationID: String
    let targetMethod: String
    let targetPathTemplate: String
    let providerOrigin: String

    let sourceInvocationSHA256: String
    let sourceResponseSHA256: String

    let targetSecurityRequirement:
        OpenAPIContinuationSecurityRequirement

    let ordinaryRequiredArguments:
        [OpenAPIContinuationParameter]

    let ordinaryOptionalArguments:
        [OpenAPIContinuationParameter]

    let requestBodyContract:
        OpenAPIContinuationRequestBodyContract?

    let targetSecurityAlternatives:
        [OpenAPIContinuationSecurityAlternative]

    let selectedExecutionSecurityAlternative:
        OpenAPIContinuationSecurityAlternative?

    let targetParameterContracts:
        [OpenAPIContinuationParameter]

    let carriedBindingNames: [String]
    let handleSelectorDescription: String

    private let mintedHandle:
        OpenAPIContinuationValue

    private let handleTarget:
        OpenAPIContinuationParameter

    private let carriedValues:
        [String: OpenAPIContinuationValue]

    private let requiresConfirmation: Bool

    init(
        template: OpenAPIContinuationTemplate,
        sourceInvocationSHA256: String,
        sourceResponseSHA256: String,
        mintedHandle:
            OpenAPIContinuationValue,
        carriedValues:
            [String: OpenAPIContinuationValue]
    ) {
        contractID =
            template.contractID

        providerSpecificationSHA256 =
            template.providerSpecificationSHA256

        issuerOperationID =
            template.issuerOperationID

        targetOperationID =
            template.targetOperationID

        targetMethod =
            template.targetMethod

        targetPathTemplate =
            template.targetPathTemplate

        providerOrigin =
            template.providerOrigin

        self.sourceInvocationSHA256 =
            sourceInvocationSHA256

        self.sourceResponseSHA256 =
            sourceResponseSHA256

        targetSecurityRequirement =
            template.targetSecurityRequirement

        ordinaryRequiredArguments =
            template.ordinaryRequiredArguments

        ordinaryOptionalArguments =
            template.ordinaryOptionalArguments

        requestBodyContract =
            template.requestBodyContract

        targetSecurityAlternatives =
            template.targetSecurityAlternatives

        selectedExecutionSecurityAlternative =
            template.selectedExecutionSecurityAlternative

        var targetParameters:
            [OpenAPIContinuationParameter] = [
                template.handleTarget
            ]

        targetParameters.append(
            contentsOf:
                template.carriedContextBindings.map {
                    $0.targetParameter
                }
        )

        targetParameters.append(
            contentsOf:
                template.ordinaryRequiredArguments
        )

        targetParameters.append(
            contentsOf:
                template.ordinaryOptionalArguments
        )

        var seenTargetKeys = Set<String>()

        targetParameterContracts =
            targetParameters.filter {
                seenTargetKeys
                    .insert($0.argumentKey)
                    .inserted
            }

        carriedBindingNames =
            template.carriedContextBindings.map {
                $0.targetParameter.argumentKey
            }

        handleSelectorDescription =
            template.handleSelectors
                .first?
                .safeSelectorDescription
                ?? "$"

        self.mintedHandle =
            mintedHandle

        handleTarget =
            template.handleTarget

        self.carriedValues =
            carriedValues

        requiresConfirmation =
            template.requiresConfirmation
    }

    func bindArgumentsForExecution(
        callerArguments:
            [String: OpenAPIContinuationValue]
    ) -> OpenAPIContinuationArgumentBinding {
        let allowedKeys = Set(
            (
                ordinaryRequiredArguments
                    + ordinaryOptionalArguments
            )
            .map(\.argumentKey)
        )

        for key in callerArguments.keys {
            if !allowedKeys.contains(key) {
                return .rejected(
                    "caller_attempted_undeclared_or_authority_bound_argument"
                )
            }
        }

        for parameter in ordinaryRequiredArguments {
            guard
                let value =
                    callerArguments[parameter.argumentKey]
            else {
                return .inputContractFailure(
                    "missing_required_ordinary_argument:"
                        + parameter.argumentKey
                )
            }

            guard parameter.schema.accepts(value) else {
                return .inputContractFailure(
                    "invalid_ordinary_argument:"
                        + parameter.argumentKey
                )
            }
        }

        for parameter in ordinaryOptionalArguments {
            guard
                let value =
                    callerArguments[parameter.argumentKey]
            else {
                continue
            }

            guard parameter.schema.accepts(value) else {
                return .inputContractFailure(
                    "invalid_optional_ordinary_argument:"
                        + parameter.argumentKey
                )
            }
        }

        var bound:
            [String: OpenAPIContinuationValue]
                = carriedValues

        bound[handleTarget.argumentKey] =
            mintedHandle

        for (key, value) in callerArguments {
            bound[key] = value
        }

        return .bound(bound)
    }

    func resolveTransition(
        callerArguments:
            [String: OpenAPIContinuationValue],
        executionAuthority:
            OpenAPIContinuationExecutionAuthorityState,
        confirmed: Bool
    ) -> OpenAPIContinuationTransitionResolution {
        let bound:
            [String: OpenAPIContinuationValue]

        switch bindArgumentsForExecution(
            callerArguments: callerArguments
        ) {
        case .rejected(let reason):
            return .rejected(reason)

        case .inputContractFailure(let reason):
            return .inputContractFailure(reason)

        case .bound(let values):
            bound = values
        }

        switch targetSecurityRequirement {
        case .credentialRequired:
            guard executionAuthority == .available else {
                return .credentialRequired
            }

        case .unresolved:
            return .abstain(
                "execution_authority_unresolved"
            )

        case .anonymous:
            break
        }

        if requiresConfirmation && !confirmed {
            return .confirmationRequired
        }

        return .ready(
            OpenAPIContinuationResolvedTransition(
                targetOperationID:
                    targetOperationID,
                targetMethod:
                    targetMethod,
                providerOrigin:
                    providerOrigin,
                boundArguments:
                    bound
            )
        )
    }
}

extension OpenAPIContinuationTemplate {
    func bindInstance(
        sourceInvocationArguments:
            [String: OpenAPIContinuationValue],
        issuerStatusCode: Int,
        issuerResponseMediaType: String?,
        issuerResponseData: Data
    ) -> OpenAPIContinuationInstanceBinding {
        let matchingSelectors =
            handleSelectors.filter { selector in
                guard
                    selector.statusCode
                        == issuerStatusCode
                else {
                    return false
                }

                return Self.mediaMatches(
                    expected:
                        selector.mediaType,
                    actual:
                        issuerResponseMediaType
                )
            }

        guard matchingSelectors.count == 1 else {
            return .abstain(
                "response_variant_not_covered_or_ambiguous"
            )
        }

        let selector = matchingSelectors[0]

        guard
            let parsed = try?
                JSONSerialization.jsonObject(
                    with: issuerResponseData
                )
        else {
            return .abstain(
                "issuer_response_is_not_json"
            )
        }

        guard
            let rawHandle =
                Self.value(
                    at: selector.propertyPath,
                    in: parsed
                ),
            let handle =
                OpenAPIContinuationValue
                    .fromJSON(rawHandle)
        else {
            return .abstain(
                "missing_or_non_scalar_handle"
            )
        }

        guard selector.schema.accepts(handle) else {
            return .abstain(
                "wrong_handle_type"
            )
        }

        guard handleTarget.schema.accepts(handle) else {
            return .abstain(
                "wrong_handle_type_for_target"
            )
        }

        var carried:
            [String: OpenAPIContinuationValue]
                = [:]

        for binding in carriedContextBindings {
            guard
                let value =
                    sourceInvocationArguments[
                        binding.issuerSourceKey
                    ]
            else {
                return .abstain(
                    "missing_carried_context:"
                    + binding.issuerSourceKey
                )
            }

            guard
                binding.targetParameter
                    .schema
                    .accepts(value)
            else {
                return .abstain(
                    "carried_context_type_mismatch:"
                    + binding.issuerSourceKey
                )
            }

            carried[
                binding.targetParameter
                    .argumentKey
            ] = value
        }

        return .bound(
            OpenAPIContinuationInstance(
                template: self,
                sourceInvocationSHA256:
                    Self.invocationHash(
                        sourceInvocationArguments
                    ),
                sourceResponseSHA256:
                    Self.sha256(
                        issuerResponseData
                    ),
                mintedHandle:
                    handle,
                carriedValues:
                    carried
            )
        )
    }

    private static func mediaMatches(
        expected: String?,
        actual: String?
    ) -> Bool {
        guard let expected else {
            return true
        }

        guard let actual else {
            return false
        }

        return normalizeMedia(expected)
            == normalizeMedia(actual)
    }

    private static func normalizeMedia(
        _ value: String
    ) -> String {
        value
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
    }

    private static func value(
        at path: [String],
        in root: Any
    ) -> Any? {
        var current: Any = root

        for component in path {
            guard
                let object =
                    current as? [String: Any],
                let next = object[component]
            else {
                return nil
            }

            current = next
        }

        return current
    }

    private static func invocationHash(
        _ values:
            [String: OpenAPIContinuationValue]
    ) -> String {
        let canonical = values
            .keys
            .sorted()
            .map {
                $0
                + "="
                + values[$0]!
                    .stableDescription
            }
            .joined(
                separator: "\n"
            )

        return sha256(
            Data(
                canonical.utf8
            )
        )
    }

    private static func sha256(
        _ data: Data
    ) -> String {
        SHA256.hash(
            data: data
        )
        .map {
            String(
                format: "%02x",
                $0
            )
        }
        .joined()
    }
}
