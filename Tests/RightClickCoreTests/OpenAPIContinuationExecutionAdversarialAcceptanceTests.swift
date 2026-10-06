import XCTest
import Foundation
import CryptoKit

@testable import RightClickCore

final class OpenAPIContinuationExecutionAdversarialAcceptanceTests: XCTestCase {
    private typealias JSON = [String: Any]

    private final class RecordingClient:
        OpenAPIContinuationExecutionHTTPClient
    {
        var requests: [URLRequest] = []
        var redirectPolicies:
            [OpenAPIContinuationExecutionRedirectPolicy] = []

        let statusCode: Int

        init(statusCode: Int) {
            self.statusCode = statusCode
        }

        func send(
            _ request: URLRequest,
            redirectPolicy:
                OpenAPIContinuationExecutionRedirectPolicy
        ) throws -> OpenAPIContinuationExecutionHTTPResponse {
            requests.append(request)
            redirectPolicies.append(redirectPolicy)

            return OpenAPIContinuationExecutionHTTPResponse(
                statusCode: statusCode,
                data: Data("green009e-response".utf8)
            )
        }
    }

    private final class AuthorityProbe {
        var materializations = 0
        var lastUnsignedFingerprint: String?
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func loadJSON(
        environmentKey: String
    ) throws -> JSON {
        guard
            let path = ProcessInfo.processInfo
                .environment[environmentKey],
            !path.isEmpty
        else {
            throw XCTSkip(
                environmentKey + " is required."
            )
        }

        return try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf:
                        URL(fileURLWithPath: path)
                )
            ) as? JSON
        )
    }

    private func vectors(
        environmentKey: String
    ) throws -> [JSON] {
        try XCTUnwrap(
            loadJSON(
                environmentKey: environmentKey
            )["vectors"] as? [JSON]
        )
    }

    private func continuationValue(
        _ raw: Any
    ) throws -> OpenAPIContinuationValue {
        try XCTUnwrap(
            OpenAPIContinuationValue.fromJSON(raw)
        )
    }

    private func derive(
        _ vector: JSON
    ) throws -> OpenAPIContinuationTemplate {
        let file = try XCTUnwrap(
            vector["providerSpecificationFile"]
                as? String
        )

        let issuer = try XCTUnwrap(
            vector["issuer"] as? JSON
        )

        let target = try XCTUnwrap(
            vector["target"] as? JSON
        )

        let result = OpenAPIContinuationTemplate.derive(
            specificationData:
                try Data(
                    contentsOf:
                        URL(fileURLWithPath: file)
                ),
            providerBaseURL:
                URL(
                    string:
                        "https://continuation.rightclick.invalid"
                )!,
            issuerOperationID:
                try XCTUnwrap(
                    issuer["operationId"] as? String
                ),
            targetOperationID:
                try XCTUnwrap(
                    target["operationId"] as? String
                )
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
                domain: "GREEN009E",
                code: 1
            )
        }
    }

    private func sourceInvocation(
        _ vector: JSON
    ) throws -> [String: OpenAPIContinuationValue] {
        var result:
            [String: OpenAPIContinuationValue] = [:]

        for item in (
            vector["carriedContext"]
                as? [JSON]
                ?? []
        ) {
            let key = try XCTUnwrap(
                item["issuerSource"] as? String
            )

            result[key] = try continuationValue(
                try XCTUnwrap(
                    item["syntheticValue"]
                )
            )
        }

        return result
    }

    private func boundInstance(
        _ vector: JSON
    ) throws -> OpenAPIContinuationInstance {
        let template = try derive(vector)

        let response = try XCTUnwrap(
            vector["syntheticIssuerResponse"]
                as? JSON
        )

        let body = try XCTUnwrap(
            response["bodyJSON"]
        )

        let data = try JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )

        let media: String?

        if response["media"] is NSNull {
            media = nil
        } else {
            media = response["media"] as? String
        }

        switch template.bindInstance(
            sourceInvocationArguments:
                try sourceInvocation(vector),
            issuerStatusCode:
                try XCTUnwrap(
                    response["status"] as? Int
                ),
            issuerResponseMediaType: media,
            issuerResponseData: data
        ) {
        case .bound(let instance):
            return instance
        case .abstain(let reason):
            XCTFail(
                "Unexpected instance abstention: "
                    + reason
            )
            throw NSError(
                domain: "GREEN009E",
                code: 2
            )
        }
    }

    private func requiredArguments(
        _ vector: JSON
    ) throws -> [String: OpenAPIContinuationValue] {
        var result:
            [String: OpenAPIContinuationValue] = [:]

        for row in (
            vector[
                "ordinaryRequiredTargetArguments"
            ] as? [JSON]
            ?? []
        ) {
            let location = try XCTUnwrap(
                row["location"] as? String
            )

            let name = try XCTUnwrap(
                row["name"] as? String
            )

            result[
                location.lowercased() + ":" + name
            ] = try continuationValue(
                try XCTUnwrap(
                    row["syntheticValue"]
                )
            )
        }

        return result
    }

    private func optionalArguments(
        _ vector: JSON
    ) throws -> [String: OpenAPIContinuationValue] {
        var result:
            [String: OpenAPIContinuationValue] = [:]

        for row in (
            vector[
                "ordinaryOptionalArguments"
            ] as? [JSON]
            ?? []
        ) {
            let location = try XCTUnwrap(
                row["location"] as? String
            )

            let name = try XCTUnwrap(
                row["name"] as? String
            )

            result[
                location.lowercased() + ":" + name
            ] = try continuationValue(
                try XCTUnwrap(
                    row["syntheticValue"]
                )
            )
        }

        return result
    }

    private func callerArguments(
        red: JSON,
        execution: JSON
    ) throws -> [String: OpenAPIContinuationValue] {
        var result = try requiredArguments(red)

        for (key, value)
            in try optionalArguments(execution)
        {
            result[key] = value
        }

        return result
    }

    private func bodyInput(
        _ execution: JSON
    ) throws -> OpenAPIContinuationRequestBodyInput? {
        guard
            let raw = execution["requestBodyInput"]
        else {
            return nil
        }

        if raw is NSNull {
            return nil
        }

        let body = try XCTUnwrap(
            raw as? JSON
        )

        switch try XCTUnwrap(
            body["kind"] as? String
        ) {
        case "json":
            return .json(
                try XCTUnwrap(body["json"])
            )

        case "bytes":
            return .bytes(
                try XCTUnwrap(
                    Data(
                        base64Encoded:
                            try XCTUnwrap(
                                body["base64"]
                                    as? String
                            )
                    )
                )
            )

        default:
            throw NSError(
                domain: "GREEN009E",
                code: 3
            )
        }
    }

    private func makeAuthority(
        instance: OpenAPIContinuationInstance,
        execution: JSON,
        probe: AuthorityProbe
    ) throws -> OpenAPIContinuationExecutionAuthority {
        let selected = try XCTUnwrap(
            instance
                .selectedExecutionSecurityAlternative
        )

        let headers = try XCTUnwrap(
            execution[
                "syntheticAuthorityHeaders"
            ] as? [String: String]
        )

        let vectorID =
            execution["vectorId"] as? String
            ?? "unknown"

        return OpenAPIContinuationExecutionAuthority(
            providerOrigin:
                instance.providerOrigin,
            targetOperationID:
                instance.targetOperationID,
            securityAlternative:
                selected,
            authorityFingerprint:
                sha256Hex(
                    Data(vectorID.utf8)
                ),
            materializer: {
                _,
                fingerprint in

                probe.materializations += 1
                probe.lastUnsignedFingerprint =
                    fingerprint

                return headers
            }
        )
    }

    private func normalizedHeaders(
        _ request: URLRequest
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues:
                (
                    request.allHTTPHeaderFields
                    ?? [:]
                )
                .map {
                    (
                        $0.key.lowercased(),
                        $0.value
                    )
                }
        )
    }


    private func derive(
        _ vector: JSON,
        specificationData: Data
    ) throws -> OpenAPIContinuationTemplate {
        let issuer = try XCTUnwrap(
            vector["issuer"] as? JSON
        )

        let target = try XCTUnwrap(
            vector["target"] as? JSON
        )

        let result =
            OpenAPIContinuationTemplate.derive(
                specificationData:
                    specificationData,
                providerBaseURL:
                    URL(
                        string:
                            "https://continuation.rightclick.invalid"
                    )!,
                issuerOperationID:
                    try XCTUnwrap(
                        issuer["operationId"]
                            as? String
                    ),
                targetOperationID:
                    try XCTUnwrap(
                        target["operationId"]
                            as? String
                    )
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
                    "GREEN009E-ADVERSARIAL",
                code:
                    11
            )
        }
    }

    private func boundInstance(
        _ vector: JSON,
        specificationData: Data
    ) throws -> OpenAPIContinuationInstance {
        let template =
            try derive(
                vector,
                specificationData:
                    specificationData
            )

        let response =
            try XCTUnwrap(
                vector[
                    "syntheticIssuerResponse"
                ] as? JSON
            )

        let body =
            try XCTUnwrap(
                response["bodyJSON"]
            )

        let data =
            try JSONSerialization.data(
                withJSONObject:
                    body,
                options:
                    [.sortedKeys]
            )

        let media: String? =
            response["media"] is NSNull
            ? nil
            : response["media"] as? String

        switch template.bindInstance(
            sourceInvocationArguments:
                try sourceInvocation(
                    vector
                ),
            issuerStatusCode:
                try XCTUnwrap(
                    response["status"]
                        as? Int
                ),
            issuerResponseMediaType:
                media,
            issuerResponseData:
                data
        ) {
        case .bound(let instance):
            return instance

        case .abstain(let reason):
            XCTFail(
                "Unexpected instance abstention: "
                + reason
            )

            throw NSError(
                domain:
                    "GREEN009E-ADVERSARIAL",
                code:
                    12
            )
        }
    }

    private func mutateTargetOperation(
        red vector: JSON,
        execution: JSON,
        _ mutate:
            (inout JSON) throws -> Void
    ) throws -> Data {
        let file =
            try XCTUnwrap(
                vector[
                    "providerSpecificationFile"
                ] as? String
            )

        let data =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            file
                    )
            )

        var root =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as? JSON
            )

        var paths =
            try XCTUnwrap(
                root["paths"]
                    as? JSON
            )

        let path =
            try XCTUnwrap(
                execution[
                    "targetPathTemplate"
                ] as? String
            )

        let method =
            try XCTUnwrap(
                execution[
                    "targetMethod"
                ] as? String
            )
            .lowercased()

        var pathObject =
            try XCTUnwrap(
                paths[path]
                    as? JSON
            )

        var operation =
            try XCTUnwrap(
                pathObject[method]
                    as? JSON
            )

        try mutate(
            &operation
        )

        pathObject[method] =
            operation

        paths[path] =
            pathObject

        root["paths"] =
            paths

        return try JSONSerialization.data(
            withJSONObject:
                root,
            options:
                [.sortedKeys]
        )
    }

    private func customAuthority(
        instance:
            OpenAPIContinuationInstance,
        alternative:
            OpenAPIContinuationSecurityAlternative,
        providerOrigin:
            String? = nil,
        targetOperationID:
            String? = nil,
        headers:
            [String: String],
        probe:
            AuthorityProbe
    ) -> OpenAPIContinuationExecutionAuthority {
        OpenAPIContinuationExecutionAuthority(
            providerOrigin:
                providerOrigin
                ?? instance.providerOrigin,
            targetOperationID:
                targetOperationID
                ?? instance.targetOperationID,
            securityAlternative:
                alternative,
            authorityFingerprint:
                sha256Hex(
                    Data(
                        "adversarial-authority"
                            .utf8
                    )
                ),
            materializer: {
                _,
                fingerprint in

                probe.materializations += 1

                probe.lastUnsignedFingerprint =
                    fingerprint

                return headers
            }
        )
    }

    func testFrozenAdversarialMatrix()
        throws
    {
        let red =
            try vectors(
                environmentKey:
                    "RIGHTCLICK_RED009A_VECTORS"
            )

        let execution =
            try vectors(
                environmentKey:
                    "RIGHTCLICK_RED009D_EXECUTION_VECTORS"
            )

        let matrix =
            try loadJSON(
                environmentKey:
                    "RIGHTCLICK_RED009D_ADVERSARIAL_MATRIX"
            )

        let cases =
            try XCTUnwrap(
                matrix["cases"]
                    as? [JSON]
            )

        let expectedIDs:
            Set<String> = [
                "CALLER_TARGET_URL",
                "CALLER_METHOD_OVERRIDE",
                "CALLER_HANDLE_OVERRIDE",
                "CALLER_CARRIED_CONTEXT_OVERRIDE",
                "CALLER_AUTHORIZATION_HEADER",
                "UNDECLARED_OPTIONAL_ARGUMENT",
                "MISSING_REQUIRED_BODY",
                "UNSUPPORTED_BODY_MEDIA",
                "AUTHORITY_UNAVAILABLE",
                "AUTHORITY_ORIGIN_MISMATCH",
                "AUTHORITY_OPERATION_MISMATCH",
                "AUTHORITY_SCHEME_MISMATCH",
                "UNCONFIRMED_MUTATION",
                "CREDENTIAL_HEADER_COLLISION",
                "REDIRECT",
                "PROVIDER_2XX",
                "PROVIDER_NON_2XX",
            ]

        XCTAssertEqual(
            cases.count,
            17
        )

        XCTAssertEqual(
            Set(
                cases.compactMap {
                    $0["id"] as? String
                }
            ),
            expectedIDs
        )

        func vector(
            _ id: String,
            from rows: [JSON]
        ) throws -> JSON {
            try XCTUnwrap(
                rows.first {
                    $0["vectorId"]
                        as? String
                        == id
                }
            )
        }

        var passed =
            Set<String>()

        func mark(
            _ id: String
        ) {
            passed.insert(
                id
            )

            print(
                "GREEN009E_ADVERSARIAL "
                + id
                + " PASS"
            )
        }

        let red01 =
            try vector(
                "RED009A-01",
                from:
                    red
            )

        let exec01 =
            try vector(
                "RED009A-01",
                from:
                    execution
            )

        let instance01 =
            try boundInstance(
                red01
            )

        let body01 =
            try bodyInput(
                exec01
            )

        let baseArgs01 =
            try callerArguments(
                red:
                    red01,
                execution:
                    exec01
            )

        func expectRejectedBeforeAuthority(
            _ id: String,
            key: String,
            value:
                OpenAPIContinuationValue
        ) throws {
            var args =
                baseArgs01

            args[key] =
                value

            let probe =
                AuthorityProbe()

            let client =
                RecordingClient(
                    statusCode:
                        204
                )

            let authority =
                try makeAuthority(
                    instance:
                        instance01,
                    execution:
                        exec01,
                    probe:
                        probe
                )

            let outcome =
                try OpenAPIContinuationExecutor
                    .execute(
                        instance:
                            instance01,
                        callerArguments:
                            args,
                        requestBody:
                            body01,
                        authority:
                            authority,
                        confirmed:
                            true,
                        client:
                            client
                    )

            guard
                case .rejected =
                    outcome
            else {
                XCTFail(
                    id
                    + " must reject."
                )
                return
            }

            XCTAssertEqual(
                probe.materializations,
                0
            )

            XCTAssertEqual(
                client.requests.count,
                0
            )

            mark(
                id
            )
        }

        try expectRejectedBeforeAuthority(
            "CALLER_TARGET_URL",
            key:
                "__targetURL",
            value:
                .string(
                    "https://attacker.invalid"
                )
        )

        try expectRejectedBeforeAuthority(
            "CALLER_METHOD_OVERRIDE",
            key:
                "__method",
            value:
                .string(
                    "DELETE"
                )
        )

        let handleBinding =
            try XCTUnwrap(
                red01[
                    "handleBinding"
                ] as? JSON
            )

        let handleParameter =
            try XCTUnwrap(
                handleBinding[
                    "targetParameter"
                ] as? JSON
            )

        let handleKey =
            try XCTUnwrap(
                handleParameter[
                    "location"
                ] as? String
            )
            .lowercased()
            + ":"
            + (
                try XCTUnwrap(
                    handleParameter[
                        "originalName"
                    ] as? String
                )
            )

        try expectRejectedBeforeAuthority(
            "CALLER_HANDLE_OVERRIDE",
            key:
                handleKey,
            value:
                .string(
                    "attacker-handle"
                )
        )

        let carriedRows =
            try XCTUnwrap(
                red01[
                    "carriedContext"
                ] as? [JSON]
            )

        let carried =
            try XCTUnwrap(
                carriedRows.first
            )

        let carriedKey =
            try XCTUnwrap(
                carried[
                    "targetLocation"
                ] as? String
            )
            .lowercased()
            + ":"
            + (
                try XCTUnwrap(
                    carried[
                        "targetOriginalName"
                    ] as? String
                )
            )

        try expectRejectedBeforeAuthority(
            "CALLER_CARRIED_CONTEXT_OVERRIDE",
            key:
                carriedKey,
            value:
                .string(
                    "attacker-context"
                )
        )

        try expectRejectedBeforeAuthority(
            "CALLER_AUTHORIZATION_HEADER",
            key:
                "header:Authorization",
            value:
                .string(
                    "Bearer attacker"
                )
        )

        try expectRejectedBeforeAuthority(
            "UNDECLARED_OPTIONAL_ARGUMENT",
            key:
                "header:X-Not-Declared",
            value:
                .string(
                    "attacker"
                )
        )

        let red02 =
            try vector(
                "RED009A-02",
                from:
                    red
            )

        let exec02 =
            try vector(
                "RED009A-02",
                from:
                    execution
            )

        let instance02 =
            try boundInstance(
                red02
            )

        let args02 =
            try callerArguments(
                red:
                    red02,
                execution:
                    exec02
            )

        let missingBodyProbe =
            AuthorityProbe()

        let missingBodyClient =
            RecordingClient(
                statusCode:
                    204
            )

        let missingBodyAuthority =
            try makeAuthority(
                instance:
                    instance02,
                execution:
                    exec02,
                probe:
                    missingBodyProbe
            )

        let missingBody =
            try OpenAPIContinuationExecutor
                .execute(
                    instance:
                        instance02,
                    callerArguments:
                        args02,
                    requestBody:
                        nil,
                    authority:
                        missingBodyAuthority,
                    confirmed:
                        true,
                    client:
                        missingBodyClient
                )

        guard
            case .inputContractFailure =
                missingBody
        else {
            XCTFail(
                "MISSING_REQUIRED_BODY must fail input contract."
            )
            return
        }

        XCTAssertEqual(
            missingBodyProbe
                .materializations,
            0
        )

        XCTAssertEqual(
            missingBodyClient
                .requests
                .count,
            0
        )

        mark(
            "MISSING_REQUIRED_BODY"
        )

        let unsupportedSpec =
            try mutateTargetOperation(
                red:
                    red02,
                execution:
                    exec02
            ) {
                operation in

                operation[
                    "requestBody"
                ] = [
                    "required":
                        true,
                    "content": [
                        "text/plain": [
                            "schema": [
                                "type":
                                    "string"
                            ]
                        ]
                    ]
                ]
            }

        let unsupportedTemplate =
            OpenAPIContinuationTemplate
                .derive(
                    specificationData:
                        unsupportedSpec,
                    providerBaseURL:
                        URL(
                            string:
                                "https://continuation.rightclick.invalid"
                        )!,
                    issuerOperationID:
                        try XCTUnwrap(
                            (
                                try XCTUnwrap(
                                    red02[
                                        "issuer"
                                    ] as? JSON
                                )
                            )[
                                "operationId"
                            ] as? String
                        ),
                    targetOperationID:
                        try XCTUnwrap(
                            (
                                try XCTUnwrap(
                                    red02[
                                        "target"
                                    ] as? JSON
                                )
                            )[
                                "operationId"
                            ] as? String
                        )
                )

        switch unsupportedTemplate {
        case .abstain(
            let reason
        ):
            XCTAssertEqual(
                reason,
                "unsupported_target_request_body_media"
            )

        case .derived:
            XCTFail(
                "UNSUPPORTED_BODY_MEDIA must abstain."
            )
            return
        }

        mark(
            "UNSUPPORTED_BODY_MEDIA"
        )

        let red03 =
            try vector(
                "RED009A-03",
                from:
                    red
            )

        let exec03 =
            try vector(
                "RED009A-03",
                from:
                    execution
            )

        let instance03 =
            try boundInstance(
                red03
            )

        let args03 =
            try callerArguments(
                red:
                    red03,
                execution:
                    exec03
            )

        let body03 =
            try bodyInput(
                exec03
            )

        let headers03 =
            try XCTUnwrap(
                exec03[
                    "syntheticAuthorityHeaders"
                ] as? [String: String]
            )

        let selected03 =
            try XCTUnwrap(
                instance03
                    .selectedExecutionSecurityAlternative
            )

        let unavailableClient =
            RecordingClient(
                statusCode:
                    204
            )

        let unavailable =
            try OpenAPIContinuationExecutor
                .execute(
                    instance:
                        instance03,
                    callerArguments:
                        args03,
                    requestBody:
                        body03,
                    authority:
                        nil,
                    confirmed:
                        true,
                    client:
                        unavailableClient
                )

        guard
            case .credentialRequired =
                unavailable
        else {
            XCTFail(
                "AUTHORITY_UNAVAILABLE must require credentials."
            )
            return
        }

        XCTAssertEqual(
            unavailableClient
                .requests
                .count,
            0
        )

        mark(
            "AUTHORITY_UNAVAILABLE"
        )

        func expectScopeReject(
            _ id: String,
            authority:
                OpenAPIContinuationExecutionAuthority,
            probe:
                AuthorityProbe
        ) throws {
            let client =
                RecordingClient(
                    statusCode:
                        204
                )

            let outcome =
                try OpenAPIContinuationExecutor
                    .execute(
                        instance:
                            instance03,
                        callerArguments:
                            args03,
                        requestBody:
                            body03,
                        authority:
                            authority,
                        confirmed:
                            true,
                        client:
                            client
                    )

            guard
                case .rejected =
                    outcome
            else {
                XCTFail(
                    id
                    + " must reject."
                )
                return
            }

            XCTAssertEqual(
                probe.materializations,
                0
            )

            XCTAssertEqual(
                client.requests.count,
                0
            )

            mark(
                id
            )
        }

        let originProbe =
            AuthorityProbe()

        try expectScopeReject(
            "AUTHORITY_ORIGIN_MISMATCH",
            authority:
                customAuthority(
                    instance:
                        instance03,
                    alternative:
                        selected03,
                    providerOrigin:
                        "https://attacker.invalid",
                    headers:
                        headers03,
                    probe:
                        originProbe
                ),
            probe:
                originProbe
        )

        let operationProbe =
            AuthorityProbe()

        try expectScopeReject(
            "AUTHORITY_OPERATION_MISMATCH",
            authority:
                customAuthority(
                    instance:
                        instance03,
                    alternative:
                        selected03,
                    targetOperationID:
                        "attacker-operation",
                    headers:
                        headers03,
                    probe:
                        operationProbe
                ),
            probe:
                operationProbe
        )

        let wrongAlternative =
            OpenAPIContinuationSecurityAlternative(
                schemes: [
                    OpenAPIContinuationSecuritySchemeContract(
                        name:
                            "wrongAuth",
                        kind:
                            "http:bearer",
                        credentialHeaderName:
                            "Authorization"
                    )
                ]
            )

        let schemeProbe =
            AuthorityProbe()

        try expectScopeReject(
            "AUTHORITY_SCHEME_MISMATCH",
            authority:
                customAuthority(
                    instance:
                        instance03,
                    alternative:
                        wrongAlternative,
                    headers:
                        headers03,
                    probe:
                        schemeProbe
                ),
            probe:
                schemeProbe
        )

        let unconfirmedProbe =
            AuthorityProbe()

        let unconfirmedClient =
            RecordingClient(
                statusCode:
                    204
            )

        let unconfirmedAuthority =
            customAuthority(
                instance:
                    instance03,
                alternative:
                    selected03,
                headers:
                    headers03,
                probe:
                    unconfirmedProbe
            )

        let unconfirmed =
            try OpenAPIContinuationExecutor
                .execute(
                    instance:
                        instance03,
                    callerArguments:
                        args03,
                    requestBody:
                        body03,
                    authority:
                        unconfirmedAuthority,
                    confirmed:
                        false,
                    client:
                        unconfirmedClient
                )

        guard
            case .confirmationRequired =
                unconfirmed
        else {
            XCTFail(
                "UNCONFIRMED_MUTATION must require confirmation."
            )
            return
        }

        XCTAssertEqual(
            unconfirmedProbe
                .materializations,
            0
        )

        XCTAssertEqual(
            unconfirmedClient
                .requests
                .count,
            0
        )

        mark(
            "UNCONFIRMED_MUTATION"
        )

        let collisionSpec =
            try mutateTargetOperation(
                red:
                    red01,
                execution:
                    exec01
            ) {
                operation in

                var parameters =
                    operation[
                        "parameters"
                    ] as? [Any]
                    ?? []

                parameters.append(
                    [
                        "name":
                            "Authorization",
                        "in":
                            "header",
                        "required":
                            false,
                        "schema": [
                            "type":
                                "string"
                        ]
                    ]
                )

                operation[
                    "parameters"
                ] =
                    parameters
            }

        let collisionInstance =
            try boundInstance(
                red01,
                specificationData:
                    collisionSpec
            )

        var collisionArgs =
            try callerArguments(
                red:
                    red01,
                execution:
                    exec01
            )

        collisionArgs[
            "header:Authorization"
        ] =
            .string(
                "caller-owned-authorization"
            )

        let collisionProbe =
            AuthorityProbe()

        let collisionClient =
            RecordingClient(
                statusCode:
                    204
            )

        let collisionAuthority =
            try makeAuthority(
                instance:
                    collisionInstance,
                execution:
                    exec01,
                probe:
                    collisionProbe
            )

        let collision =
            try OpenAPIContinuationExecutor
                .execute(
                    instance:
                        collisionInstance,
                    callerArguments:
                        collisionArgs,
                    requestBody:
                        body01,
                    authority:
                        collisionAuthority,
                    confirmed:
                        true,
                    client:
                        collisionClient
                )

        guard
            case .rejected(
                let collisionReason
            ) =
                collision
        else {
            XCTFail(
                "CREDENTIAL_HEADER_COLLISION must reject."
            )
            return
        }

        XCTAssertEqual(
            collisionReason,
            "credential_header_collision"
        )

        XCTAssertEqual(
            collisionProbe
                .materializations,
            0
        )

        XCTAssertEqual(
            collisionClient
                .requests
                .count,
            0
        )

        mark(
            "CREDENTIAL_HEADER_COLLISION"
        )

        func executeTransportOutcome(
            probe:
                AuthorityProbe,
            client:
                RecordingClient
        ) throws
            -> OpenAPIContinuationExecutionOutcome
        {
            let authority =
                customAuthority(
                    instance:
                        instance03,
                    alternative:
                        selected03,
                    headers:
                        headers03,
                    probe:
                        probe
                )

            return try OpenAPIContinuationExecutor
                .execute(
                    instance:
                        instance03,
                    callerArguments:
                        args03,
                    requestBody:
                        body03,
                    authority:
                        authority,
                    confirmed:
                        true,
                    client:
                        client
                )
        }

        let redirectProbe =
            AuthorityProbe()

        let redirectClient =
            RecordingClient(
                statusCode:
                    302
            )

        let redirect =
            try executeTransportOutcome(
                probe:
                    redirectProbe,
                client:
                    redirectClient
            )

        guard
            case .redirectRejected =
                redirect
        else {
            XCTFail(
                "REDIRECT must reject redirect."
            )
            return
        }

        XCTAssertEqual(
            redirectProbe
                .materializations,
            1
        )

        XCTAssertEqual(
            redirectClient
                .requests
                .count,
            1
        )

        XCTAssertEqual(
            redirectClient
                .redirectPolicies,
            [.reject]
        )

        mark(
            "REDIRECT"
        )

        let acceptedProbe =
            AuthorityProbe()

        let acceptedClient =
            RecordingClient(
                statusCode:
                    204
            )

        let accepted =
            try executeTransportOutcome(
                probe:
                    acceptedProbe,
                client:
                    acceptedClient
            )

        guard
            case let .providerAccepted(
                statusCode,
                _,
                semanticVerified,
                _,
                _
            ) =
                accepted
        else {
            XCTFail(
                "PROVIDER_2XX must be accepted/unverified."
            )
            return
        }

        XCTAssertEqual(
            statusCode,
            204
        )

        XCTAssertFalse(
            semanticVerified
        )

        XCTAssertEqual(
            acceptedProbe
                .materializations,
            1
        )

        XCTAssertEqual(
            acceptedClient
                .requests
                .count,
            1
        )

        mark(
            "PROVIDER_2XX"
        )

        let rejectedProbe =
            AuthorityProbe()

        let rejectedClient =
            RecordingClient(
                statusCode:
                    409
            )

        let rejected =
            try executeTransportOutcome(
                probe:
                    rejectedProbe,
                client:
                    rejectedClient
            )

        guard
            case .providerRejected =
                rejected
        else {
            XCTFail(
                "PROVIDER_NON_2XX must be provider rejected."
            )
            return
        }

        XCTAssertEqual(
            rejectedProbe
                .materializations,
            1
        )

        XCTAssertEqual(
            rejectedClient
                .requests
                .count,
            1
        )

        mark(
            "PROVIDER_NON_2XX"
        )

        XCTAssertEqual(
            passed,
            expectedIDs
        )
    }
}
