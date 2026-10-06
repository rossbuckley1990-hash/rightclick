import XCTest
import Foundation
@testable import RightClickCore

final class OpenAPIContinuationTemplateAcceptanceTests:
    XCTestCase
{
    private typealias JSON =
        [String: Any]

    private func vectors()
        throws -> [JSON]
    {
        guard
            let path =
                ProcessInfo.processInfo
                    .environment[
                        "RIGHTCLICK_RED009A_VECTORS"
                    ],
            !path.isEmpty
        else {
            throw XCTSkip(
                "RIGHTCLICK_RED009A_VECTORS is required."
            )
        }

        let data = try Data(
            contentsOf:
                URL(
                    fileURLWithPath: path
                )
        )

        let root = try XCTUnwrap(
            JSONSerialization
                .jsonObject(
                    with: data
                )
                as? JSON
        )

        return try XCTUnwrap(
            root["vectors"]
                as? [JSON]
        )
    }

    private func vector(
        id: String
    ) throws -> JSON {
        let all = try vectors()

        return try XCTUnwrap(
            all.first {
                ($0["vectorId"] as? String)
                    == id
            }
        )
    }

    private func derive(
        _ vector: JSON
    ) throws -> OpenAPIContinuationTemplate {
        let file = try XCTUnwrap(
            vector[
                "providerSpecificationFile"
            ] as? String
        )

        let issuer = try XCTUnwrap(
            vector["issuer"] as? JSON
        )

        let target = try XCTUnwrap(
            vector["target"] as? JSON
        )

        let issuerID = try XCTUnwrap(
            issuer["operationId"] as? String
        )

        let targetID = try XCTUnwrap(
            target["operationId"] as? String
        )

        let data = try Data(
            contentsOf:
                URL(
                    fileURLWithPath: file
                )
        )

        let result =
            OpenAPIContinuationTemplate
                .derive(
                    specificationData:
                        data,
                    providerBaseURL:
                        URL(
                            string:
                                "https://continuation.rightclick.invalid"
                        )!,
                    issuerOperationID:
                        issuerID,
                    targetOperationID:
                        targetID
                )

        switch result {
        case .derived(let template):
            return template

        case .abstain(let reason):
            XCTFail(
                "Unexpected template abstention: "
                + reason
            )

            throw NSError(
                domain:
                    "OpenAPIContinuationTemplateAcceptanceTests",
                code: 1
            )
        }
    }

    private func continuationValue(
        _ raw: Any
    ) throws -> OpenAPIContinuationValue {
        try XCTUnwrap(
            OpenAPIContinuationValue
                .fromJSON(raw)
        )
    }

    private func sourceInvocation(
        _ vector: JSON
    ) throws
        -> [String: OpenAPIContinuationValue]
    {
        let carried =
            vector["carriedContext"]
                as? [JSON]
                ?? []

        var result:
            [String: OpenAPIContinuationValue]
                = [:]

        for item in carried {
            let key = try XCTUnwrap(
                item["issuerSource"]
                    as? String
            )

            let raw = try XCTUnwrap(
                item["syntheticValue"]
            )

            result[key] =
                try continuationValue(raw)
        }

        return result
    }

    private func responseData(
        _ vector: JSON
    ) throws -> (
        status: Int,
        media: String?,
        data: Data
    ) {
        let response = try XCTUnwrap(
            vector[
                "syntheticIssuerResponse"
            ] as? JSON
        )

        let status = try XCTUnwrap(
            response["status"]
                as? Int
        )

        let body = try XCTUnwrap(
            response["bodyJSON"]
        )

        let data = try JSONSerialization
            .data(
                withJSONObject: body,
                options: [.sortedKeys]
            )

        let media: String?

        if response["media"] is NSNull {
            media = nil
        } else {
            media =
                response["media"]
                    as? String
        }

        return (
            status,
            media,
            data
        )
    }

    private func bind(
        _ vector: JSON,
        sourceOverride:
            [String: OpenAPIContinuationValue]?
                = nil,
        statusOverride: Int? = nil,
        bodyOverride: Data? = nil
    ) throws -> OpenAPIContinuationInstanceBinding {
        let template = try derive(vector)

        let response =
            try responseData(vector)

        let resolvedSourceInvocation:
            [String: OpenAPIContinuationValue]

        if let sourceOverride = sourceOverride {
            resolvedSourceInvocation =
                sourceOverride
        } else {
            resolvedSourceInvocation =
                try sourceInvocation(
                    vector
                )
        }

        return template.bindInstance(
            sourceInvocationArguments:
                resolvedSourceInvocation,
            issuerStatusCode:
                statusOverride
                ?? response.status,
            issuerResponseMediaType:
                response.media,
            issuerResponseData:
                bodyOverride
                ?? response.data
        )
    }

    private func boundInstance(
        _ vector: JSON
    ) throws -> OpenAPIContinuationInstance {
        let result = try bind(vector)

        switch result {
        case .bound(let instance):
            return instance

        case .abstain(let reason):
            XCTFail(
                "Unexpected instance abstention: "
                + reason
            )

            throw NSError(
                domain:
                    "OpenAPIContinuationTemplateAcceptanceTests",
                code: 2
            )
        }
    }

    private func ordinaryArguments(
        _ vector: JSON
    ) throws
        -> [String: OpenAPIContinuationValue]
    {
        let ordinary =
            vector[
                "ordinaryRequiredTargetArguments"
            ] as? [JSON]
            ?? []

        var result:
            [String: OpenAPIContinuationValue]
                = [:]

        for row in ordinary {
            let location = try XCTUnwrap(
                row["location"] as? String
            )

            let name = try XCTUnwrap(
                row["name"] as? String
            )

            let value = try continuationValue(
                try XCTUnwrap(
                    row["syntheticValue"]
                )
            )

            result[
                location.lowercased()
                + ":"
                + name
            ] = value
        }

        return result
    }

    private func selectorPath(
        _ vector: JSON
    ) throws -> [String] {
        let binding = try XCTUnwrap(
            vector[
                "handleBinding"
            ] as? JSON
        )

        let selector = try XCTUnwrap(
            binding["selector"]
                as? String
        )

        XCTAssertTrue(
            selector.hasPrefix("$.")
        )

        return selector
            .dropFirst(2)
            .split(
                separator: "."
            )
            .map(String.init)
    }

    private func mutateJSON(
        root: Any,
        path: [String],
        replacement: Any?,
        remove: Bool
    ) throws -> Any {
        guard !path.isEmpty else {
            return root
        }

        guard
            var object =
                root as? [String: Any]
        else {
            throw NSError(
                domain:
                    "OpenAPIContinuationTemplateAcceptanceTests",
                code: 3
            )
        }

        let key = path[0]

        if path.count == 1 {
            if remove {
                object.removeValue(
                    forKey: key
                )
            } else {
                object[key] =
                    replacement
                    ?? NSNull()
            }

            return object
        }

        let child = try XCTUnwrap(
            object[key]
        )

        object[key] = try mutateJSON(
            root: child,
            path:
                Array(
                    path.dropFirst()
                ),
            replacement:
                replacement,
            remove:
                remove
        )

        return object
    }

    func testSixFrozenRealContractVectorsDeriveBindAndResolve()
        throws
    {
        let all = try vectors()

        XCTAssertEqual(
            all.count,
            6
        )

        var providers = Set<String>()
        var handleFamilies = Set<String>()
        var transitionFamilies =
            Set<String>()

        for vector in all {
            let vectorID = try XCTUnwrap(
                vector[
                    "vectorId"
                ] as? String
            )

            providers.insert(
                try XCTUnwrap(
                    vector[
                        "provider"
                    ] as? String
                )
            )

            handleFamilies.insert(
                try XCTUnwrap(
                    vector[
                        "handleFamily"
                    ] as? String
                )
            )

            transitionFamilies.insert(
                try XCTUnwrap(
                    vector[
                        "transitionFamily"
                    ] as? String
                )
            )

            let template =
                try derive(vector)

            XCTAssertEqual(
                template.contractID,
                "provider-neutral-continuation-template-v1"
            )

            XCTAssertEqual(
                template
                    .targetSecurityRequirement,
                .credentialRequired
            )

            let instance =
                try boundInstance(
                    vector
                )

            let ordinary =
                try ordinaryArguments(
                    vector
                )

            switch instance.resolveTransition(
                callerArguments:
                    ordinary,
                executionAuthority:
                    .unavailable,
                confirmed:
                    true
            ) {
            case .credentialRequired:
                break

            default:
                XCTFail(
                    vectorID
                    + " should require independent execution authority."
                )
            }

            switch instance.resolveTransition(
                callerArguments:
                    ordinary,
                executionAuthority:
                    .available,
                confirmed:
                    false
            ) {
            case .confirmationRequired:
                break

            default:
                XCTFail(
                    vectorID
                    + " should require confirmation."
                )
            }

            let resolution =
                instance.resolveTransition(
                    callerArguments:
                        ordinary,
                    executionAuthority:
                        .available,
                    confirmed:
                        true
                )

            guard
                case .ready(let ready)
                    = resolution
            else {
                XCTFail(
                    vectorID
                    + " should resolve to a ready transition."
                )
                continue
            }

            let expected =
                vector[
                    "expectedAuthorityBoundTargetValues"
                ] as? [JSON]
                ?? []

            try ready.withBoundArguments {
                actual in

                for expectedRow in expected {
                    let location =
                        try XCTUnwrap(
                            expectedRow[
                                "location"
                            ] as? String
                        )

                    let name =
                        try XCTUnwrap(
                            expectedRow[
                                "name"
                            ] as? String
                        )

                    let expectedValue =
                        try continuationValue(
                            try XCTUnwrap(
                                expectedRow[
                                    "value"
                                ]
                            )
                        )

                    XCTAssertEqual(
                        actual[
                            location.lowercased()
                            + ":"
                            + name
                        ],
                        expectedValue,
                        vectorID
                    )
                }

                for (
                    key,
                    value
                ) in ordinary {
                    XCTAssertEqual(
                        actual[key],
                        value,
                        vectorID
                    )
                }
            }

            print(
                "GREEN009B vector="
                + vectorID
                + " provider="
                + (
                    vector[
                        "provider"
                    ] as? String
                    ?? "unknown"
                )
                + " status=PASS"
            )
        }

        XCTAssertEqual(
            providers.count,
            6
        )

        XCTAssertEqual(
            handleFamilies,
            [
                "file_asset",
                "generic",
                "session",
                "upload"
            ]
        )

        XCTAssertEqual(
            transitionFamilies,
            [
                "abort",
                "advance",
                "finalize",
                "part_chunk",
                "upload_data_step"
            ]
        )
    }

    func testHandleOverrideRejectedBeforeAuthority()
        throws
    {
        let vector =
            try vector(
                id: "RED009A-01"
            )

        let instance =
            try boundInstance(
                vector
            )

        let binding = try XCTUnwrap(
            vector[
                "handleBinding"
            ] as? JSON
        )

        let targetParameter =
            try XCTUnwrap(
                binding[
                    "targetParameter"
                ] as? JSON
            )

        let location =
            try XCTUnwrap(
                targetParameter[
                    "location"
                ] as? String
            )

        let name =
            try XCTUnwrap(
                targetParameter[
                    "originalName"
                ] as? String
            )

        let arguments = [
            location.lowercased()
            + ":"
            + name:
                OpenAPIContinuationValue
                    .string(
                        "attacker-handle"
                    )
        ]

        switch instance.resolveTransition(
            callerArguments:
                arguments,
            executionAuthority:
                .unavailable,
            confirmed:
                false
        ) {
        case .rejected:
            break

        default:
            XCTFail(
                "Handle override must reject before authority."
            )
        }
    }

    func testCarriedContextOverrideRejectedBeforeAuthority()
        throws
    {
        let vector =
            try vector(
                id: "RED009A-01"
            )

        let instance =
            try boundInstance(
                vector
            )

        let carried =
            try XCTUnwrap(
                vector[
                    "carriedContext"
                ] as? [JSON]
            )

        let row =
            try XCTUnwrap(
                carried.first
            )

        let location =
            try XCTUnwrap(
                row[
                    "targetLocation"
                ] as? String
            )

        let name =
            try XCTUnwrap(
                row[
                    "targetOriginalName"
                ] as? String
            )

        switch instance.resolveTransition(
            callerArguments: [
                location.lowercased()
                + ":"
                + name:
                    .string(
                        "attacker-context"
                    )
            ],
            executionAuthority:
                .unavailable,
            confirmed:
                false
        ) {
        case .rejected:
            break

        default:
            XCTFail(
                "Carried context override must reject."
            )
        }
    }

    func testTargetOperationOverrideRejectedAsUndeclared()
        throws
    {
        let instance =
            try boundInstance(
                vector(
                    id: "RED009A-03"
                )
            )

        switch instance.resolveTransition(
            callerArguments: [
                "__targetOperationID":
                    .string("attacker-target")
            ],
            executionAuthority:
                .unavailable,
            confirmed:
                false
        ) {
        case .rejected:
            break

        default:
            XCTFail(
                "Target override must reject."
            )
        }
    }

    func testMethodOverrideRejectedAsUndeclared()
        throws
    {
        let instance =
            try boundInstance(
                vector(
                    id: "RED009A-03"
                )
            )

        switch instance.resolveTransition(
            callerArguments: [
                "__method":
                    .string("DELETE")
            ],
            executionAuthority:
                .unavailable,
            confirmed:
                false
        ) {
        case .rejected:
            break

        default:
            XCTFail(
                "Method override must reject."
            )
        }
    }

    func testOriginOverrideRejectedAsUndeclared()
        throws
    {
        let instance =
            try boundInstance(
                vector(
                    id: "RED009A-03"
                )
            )

        switch instance.resolveTransition(
            callerArguments: [
                "__origin":
                    .string(
                        "https://attacker.invalid"
                    )
            ],
            executionAuthority:
                .unavailable,
            confirmed:
                false
        ) {
        case .rejected:
            break

        default:
            XCTFail(
                "Origin override must reject."
            )
        }
    }

    func testMissingHandleAbstains()
        throws
    {
        let vector =
            try vector(
                id: "RED009A-03"
            )

        let response =
            try responseData(vector)

        let root =
            try JSONSerialization
                .jsonObject(
                    with: response.data
                )

        let mutated =
            try mutateJSON(
                root: root,
                path:
                    selectorPath(vector),
                replacement:
                    nil,
                remove:
                    true
            )

        let data =
            try JSONSerialization
                .data(
                    withJSONObject:
                        mutated,
                    options: [.sortedKeys]
                )

        switch try bind(
            vector,
            bodyOverride:
                data
        ) {
        case .abstain:
            break

        case .bound:
            XCTFail(
                "Missing handle must abstain."
            )
        }
    }

    func testWrongHandleTypeAbstains()
        throws
    {
        let vector =
            try vector(
                id: "RED009A-03"
            )

        let response =
            try responseData(vector)

        let root =
            try JSONSerialization
                .jsonObject(
                    with: response.data
                )

        let binding =
            try XCTUnwrap(
                vector[
                    "handleBinding"
                ] as? JSON
            )

        let responseSchema =
            try XCTUnwrap(
                binding[
                    "responseSchema"
                ] as? JSON
            )

        let expectedType =
            responseSchema[
                "type"
            ] as? String

        let wrong: Any =
            expectedType == "integer"
            ? "wrong-type"
            : 987654

        let mutated =
            try mutateJSON(
                root: root,
                path:
                    selectorPath(vector),
                replacement:
                    wrong,
                remove:
                    false
            )

        let data =
            try JSONSerialization
                .data(
                    withJSONObject:
                        mutated,
                    options: [.sortedKeys]
                )

        switch try bind(
            vector,
            bodyOverride:
                data
        ) {
        case .abstain:
            break

        case .bound:
            XCTFail(
                "Wrong handle type must abstain."
            )
        }
    }

    func testWrongResponseVariantAbstains()
        throws
    {
        let vector =
            try vector(
                id: "RED009A-03"
            )

        switch try bind(
            vector,
            statusOverride:
                599
        ) {
        case .abstain:
            break

        case .bound:
            XCTFail(
                "Wrong response variant must abstain."
            )
        }
    }

    func testMissingCarriedContextAbstains()
        throws
    {
        let vector =
            try vector(
                id: "RED009A-01"
            )

        switch try bind(
            vector,
            sourceOverride:
                [:]
        ) {
        case .abstain:
            break

        case .bound:
            XCTFail(
                "Missing carried context must abstain."
            )
        }
    }

    func testMissingOrdinaryArgumentFailsInputContract()
        throws
    {
        let instance =
            try boundInstance(
                vector(
                    id: "RED009A-01"
                )
            )

        switch instance.resolveTransition(
            callerArguments:
                [:],
            executionAuthority:
                .available,
            confirmed:
                true
        ) {
        case .inputContractFailure:
            break

        default:
            XCTFail(
                "Missing ordinary argument must fail input contract."
            )
        }
    }

    func testInvalidOrdinaryArgumentFailsInputContract()
        throws
    {
        let vector =
            try vector(
                id: "RED009A-01"
            )

        let ordinary =
            try XCTUnwrap(
                vector[
                    "ordinaryRequiredTargetArguments"
                ] as? [JSON]
            )

        let row =
            try XCTUnwrap(
                ordinary.first
            )

        let location =
            try XCTUnwrap(
                row[
                    "location"
                ] as? String
            )

        let name =
            try XCTUnwrap(
                row[
                    "name"
                ] as? String
            )

        let schema =
            try XCTUnwrap(
                row[
                    "schema"
                ] as? JSON
            )

        let expectedType =
            schema[
                "type"
            ] as? String

        let wrong:
            OpenAPIContinuationValue =
                expectedType == "integer"
                ? .string("wrong")
                : .integer(999)

        let instance =
            try boundInstance(
                vector
            )

        switch instance.resolveTransition(
            callerArguments: [
                location.lowercased()
                + ":"
                + name:
                    wrong
            ],
            executionAuthority:
                .available,
            confirmed:
                true
        ) {
        case .inputContractFailure:
            break

        default:
            XCTFail(
                "Invalid ordinary argument must fail input contract."
            )
        }
    }

    func testCredentialRequirementIndependentFromContinuationBinding()
        throws
    {
        let vector =
            try vector(
                id: "RED009A-05"
            )

        let instance =
            try boundInstance(
                vector
            )

        XCTAssertEqual(
            instance
                .targetSecurityRequirement,
            .credentialRequired
        )

        switch instance.resolveTransition(
            callerArguments:
                try ordinaryArguments(
                    vector
                ),
            executionAuthority:
                .unavailable,
            confirmed:
                true
        ) {
        case .credentialRequired:
            break

        default:
            XCTFail(
                "Valid continuation state must not grant target execution authority."
            )
        }
    }

    func testUnconfirmedMutationRequiresConfirmation()
        throws
    {
        let vector =
            try vector(
                id: "RED009A-06"
            )

        let instance =
            try boundInstance(
                vector
            )

        switch instance.resolveTransition(
            callerArguments:
                try ordinaryArguments(
                    vector
                ),
            executionAuthority:
                .available,
            confirmed:
                false
        ) {
        case .confirmationRequired:
            break

        default:
            XCTFail(
                "Mutation must still require confirmation."
            )
        }
    }

    func testProvider2xxIsAcceptedSemanticUnverified()
        throws
    {
        XCTAssertEqual(
            OpenAPIContinuationProviderOutcome
                .classify(
                    statusCode: 204
                ),
            .providerAcceptedSemanticUnverified(
                204
            )
        )

        XCTAssertEqual(
            OpenAPIContinuationProviderOutcome
                .classify(
                    statusCode: 409
                ),
            .providerRejected(
                409
            )
        )
    }
}
