import XCTest
import Foundation
import CryptoKit

@testable import RightClickCore

final class OpenAPIContinuationExecutionWireAcceptanceTests: XCTestCase {
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

    func testSixFrozenWireOracles()
        throws
    {
        let red = try vectors(
            environmentKey:
                "RIGHTCLICK_RED009A_VECTORS"
        )

        let execution = try vectors(
            environmentKey:
                "RIGHTCLICK_RED009D_EXECUTION_VECTORS"
        )

        XCTAssertEqual(red.count, 6)
        XCTAssertEqual(execution.count, 6)

        for exec in execution {
            let vectorID = try XCTUnwrap(
                exec["vectorId"] as? String
            )

            let redVector = try XCTUnwrap(
                red.first {
                    $0["vectorId"] as? String
                        == vectorID
                }
            )

            let instance =
                try boundInstance(redVector)

            XCTAssertEqual(
                instance.targetPathTemplate,
                try XCTUnwrap(
                    exec["targetPathTemplate"]
                        as? String
                )
            )

            XCTAssertEqual(
                instance
                    .ordinaryOptionalArguments
                    .count,
                (
                    exec["ordinaryOptionalArguments"]
                        as? [JSON]
                    ?? []
                ).count
            )

            let selected = try XCTUnwrap(
                instance
                    .selectedExecutionSecurityAlternative
            )

            let frozenAlternative =
                try XCTUnwrap(
                    exec[
                        "selectedSecurityAlternative"
                    ] as? JSON
                )

            let frozenSchemes =
                try XCTUnwrap(
                    frozenAlternative["schemes"]
                        as? [JSON]
                )

            XCTAssertEqual(
                selected.schemeKinds,
                try frozenSchemes
                    .map {
                        try XCTUnwrap(
                            $0["kind"] as? String
                        )
                    }
                    .sorted()
            )

            let arguments =
                try callerArguments(
                    red: redVector,
                    execution: exec
                )

            let body = try bodyInput(exec)

            let unconfirmedProbe =
                AuthorityProbe()

            let unconfirmedClient =
                RecordingClient(
                    statusCode: 204
                )

            let unconfirmed =
                try OpenAPIContinuationExecutor.execute(
                    instance: instance,
                    callerArguments: arguments,
                    requestBody: body,
                    authority:
                        try makeAuthority(
                            instance: instance,
                            execution: exec,
                            probe:
                                unconfirmedProbe
                        ),
                    confirmed: false,
                    client: unconfirmedClient
                )

            guard
                case .confirmationRequired =
                    unconfirmed
            else {
                XCTFail(
                    vectorID
                        + " must stop before credentials."
                )
                continue
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

            let missingClient =
                RecordingClient(
                    statusCode: 204
                )

            let missingAuthority =
                try OpenAPIContinuationExecutor.execute(
                    instance: instance,
                    callerArguments: arguments,
                    requestBody: body,
                    authority: nil,
                    confirmed: true,
                    client: missingClient
                )

            guard
                case .credentialRequired =
                    missingAuthority
            else {
                XCTFail(
                    vectorID
                        + " must require independent authority."
                )
                continue
            }

            XCTAssertEqual(
                missingClient.requests.count,
                0
            )

            let probe = AuthorityProbe()
            let client = RecordingClient(
                statusCode: 204
            )

            let outcome =
                try OpenAPIContinuationExecutor.execute(
                    instance: instance,
                    callerArguments: arguments,
                    requestBody: body,
                    authority:
                        try makeAuthority(
                            instance: instance,
                            execution: exec,
                            probe: probe
                        ),
                    confirmed: true,
                    client: client
                )

            let expectedUnsigned =
                try XCTUnwrap(
                    exec[
                        "expectedUnsignedRequest"
                    ] as? JSON
                )

            let expectedFinal =
                try XCTUnwrap(
                    exec["expectedFinalWire"]
                        as? JSON
                )

            guard
                case let .providerAccepted(
                    statusCode,
                    _,
                    semanticVerified,
                    unsignedSHA,
                    finalSHA
                ) = outcome
            else {
                XCTFail(
                    vectorID
                        + " did not execute."
                )
                continue
            }

            XCTAssertEqual(statusCode, 204)
            XCTAssertFalse(semanticVerified)

            XCTAssertEqual(
                unsignedSHA,
                try XCTUnwrap(
                    expectedUnsigned[
                        "requestFingerprintSHA256"
                    ] as? String
                )
            )

            XCTAssertEqual(
                finalSHA,
                try XCTUnwrap(
                    expectedFinal[
                        "wireFingerprintSHA256"
                    ] as? String
                )
            )

            XCTAssertEqual(
                probe.materializations,
                1
            )

            XCTAssertEqual(
                probe.lastUnsignedFingerprint,
                unsignedSHA
            )

            XCTAssertEqual(
                client.requests.count,
                1
            )

            XCTAssertEqual(
                client.redirectPolicies,
                [.reject]
            )

            let request = try XCTUnwrap(
                client.requests.first
            )

            XCTAssertEqual(
                request.httpMethod,
                try XCTUnwrap(
                    expectedFinal["method"]
                        as? String
                )
            )

            XCTAssertEqual(
                request.url?.absoluteString,
                try XCTUnwrap(
                    expectedFinal["url"]
                        as? String
                )
            )

            XCTAssertEqual(
                normalizedHeaders(request),
                try XCTUnwrap(
                    expectedFinal["headers"]
                        as? [String: String]
                )
            )

            let actualBody =
                request.httpBody
                ?? Data()

            XCTAssertEqual(
                actualBody.count,
                try XCTUnwrap(
                    expectedFinal["bodyBytes"]
                        as? Int
                )
            )

            XCTAssertEqual(
                sha256Hex(actualBody),
                try XCTUnwrap(
                    expectedFinal["bodySHA256"]
                        as? String
                )
            )

            print(
                "GREEN009E_WIRE "
                    + vectorID
                    + " unsigned="
                    + unsignedSHA
                    + " final="
                    + finalSHA
                    + " PASS"
            )
        }
    }
}
