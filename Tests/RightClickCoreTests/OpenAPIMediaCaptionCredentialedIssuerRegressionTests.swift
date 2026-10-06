import Foundation
import XCTest

@testable import RightClickCore

final class OpenAPIMediaCaptionCredentialedIssuerRegressionTests:
    XCTestCase
{
    final class StubURLProtocol:
        URLProtocol
    {
        static var requestCount =
            0

        static var handler:
            ((URLRequest) throws
                -> (
                    HTTPURLResponse,
                    Data
                ))?

        override class func canInit(
            with request:
                URLRequest
        ) -> Bool {
            true
        }

        override class func canonicalRequest(
            for request:
                URLRequest
        ) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.requestCount += 1

            guard
                let handler =
                    Self.handler
            else {
                client?
                    .urlProtocol(
                        self,
                        didFailWithError:
                            NSError(
                                domain:
                                    "MediaCaptionIssuerRegression",
                                code:
                                    1
                            )
                    )

                return
            }

            do {
                var observed =
                    request

                if
                    observed.httpBody
                        == nil,
                    let stream =
                        observed
                            .httpBodyStream
                {
                    stream.open()

                    defer {
                        stream.close()
                    }

                    var body =
                        Data()

                    var buffer =
                        [
                            UInt8
                        ](
                            repeating:
                                0,
                            count:
                                4096
                        )

                    while true {
                        let count =
                            stream.read(
                                &buffer,
                                maxLength:
                                    buffer.count
                            )

                        if count < 0 {
                            throw
                                stream
                                    .streamError
                                ?? NSError(
                                    domain:
                                        "MediaCaptionIssuerRegression",
                                    code:
                                        2
                                )
                        }

                        if count == 0 {
                            break
                        }

                        body.append(
                            contentsOf:
                                buffer[
                                    0..<count
                                ]
                        )
                    }

                    observed.httpBody =
                        body
                }

                let (
                    response,
                    data
                ) =
                    try handler(
                        observed
                    )

                client?
                    .urlProtocol(
                        self,
                        didReceive:
                            response,
                        cacheStoragePolicy:
                            .notAllowed
                    )

                client?
                    .urlProtocol(
                        self,
                        didLoad:
                            data
                    )

                client?
                    .urlProtocolDidFinishLoading(
                        self
                    )
            } catch {
                client?
                    .urlProtocol(
                        self,
                        didFailWithError:
                            error
                    )
            }
        }

        override func stopLoading() {}
    }

    private func session()
        -> URLSession
    {
        let configuration =
            URLSessionConfiguration
                .ephemeral

        configuration
            .protocolClasses =
            [
                StubURLProtocol.self
            ]

        return URLSession(
            configuration:
                configuration
        )
    }

    func testMediaCaptionCreateUploadUsesGenericCredentialedIssuer()
        throws
    {
        guard
            let path =
                ProcessInfo
                    .processInfo
                    .environment[
                        "RIGHTCLICK_MEDIACAPTION_OPENAPI_JSON"
                    ]
        else {
            throw XCTSkip(
                "RIGHTCLICK_MEDIACAPTION_OPENAPI_JSON required"
            )
        }

        let specification =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            path
                    )
            )

        var resolutions =
            0

        var materializations =
            0

        let resolver:
            OpenAPIOperationExecutionAuthorityResolver =
        {
            request in

            resolutions += 1

            XCTAssertEqual(
                request
                    .providerOrigin,
                "https://api.mediacaption.io"
            )

            XCTAssertEqual(
                request
                    .operationID,
                "createUpload"
            )

            let bearer =
                try XCTUnwrap(
                    request
                        .securityAlternatives
                        .first(
                            where: {
                                $0
                                    .schemes
                                    .count
                                    == 1
                                && $0
                                    .schemes[
                                        0
                                    ]
                                    .name
                                    == "bearerApiKey"
                                && $0
                                    .schemes[
                                        0
                                    ]
                                    .kind
                                    == "http:bearer"
                            }
                        )
                )

            return
                OpenAPIOperationExecutionAuthority(
                    providerOrigin:
                        request
                            .providerOrigin,
                    operationID:
                        request
                            .operationID,
                    securityAlternative:
                        bearer,
                    authorityFingerprintSHA256:
                        "mediacaption-regression-fake-authority",
                    materializer: {
                        _ in

                        materializations += 1

                        return [
                            "Authorization":
                                "Bearer MEDIACAPTION-FAKE-NOT-LIVE"
                        ]
                    }
                )
        }

        StubURLProtocol.handler = {
            request in

            XCTAssertEqual(
                request
                    .httpMethod,
                "POST"
            )

            XCTAssertEqual(
                request
                    .url?
                    .absoluteString,
                "https://api.mediacaption.io/v1/uploads"
            )

            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField:
                        "Authorization"
                ),
                "Bearer MEDIACAPTION-FAKE-NOT-LIVE"
            )

            let data =
                try XCTUnwrap(
                    request
                        .httpBody
                )

            let object =
                try XCTUnwrap(
                    try JSONSerialization
                        .jsonObject(
                            with:
                                data
                        )
                    as? [String: Any]
                )

            XCTAssertEqual(
                object[
                    "contentType"
                ] as? String,
                "audio/mpeg"
            )

            XCTAssertEqual(
                object[
                    "durationSec"
                ] as? Int,
                1
            )

            XCTAssertEqual(
                object[
                    "filename"
                ] as? String,
                "rightclick-northstar-proof.mp3"
            )

            XCTAssertEqual(
                object[
                    "sizeBytes"
                ] as? Int,
                1024
            )

            let response =
                try XCTUnwrap(
                    HTTPURLResponse(
                        url:
                            request.url!,
                        statusCode:
                            201,
                        httpVersion:
                            "HTTP/1.1",
                        headerFields: [
                            "Content-Type":
                                "application/json"
                        ]
                    )
                )

            return (
                response,
                Data(
                    #"{"id":"upload_regression_123"}"#.utf8
                )
            )
        }

        let reflector =
            try OpenAPIReflector(
                specificationData:
                    specification,
                baseURL:
                    URL(
                        string:
                            "https://api.mediacaption.io/v1"
                    )!,
                session:
                    session(),
                executionAuthorityResolver:
                    resolver
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        let input =
            #"{"contentType":"audio/mpeg","durationSec":1,"filename":"rightclick-northstar-proof.mp3","sizeBytes":1024}"#

        let capability =
            try XCTUnwrap(
                try engine
                    .capabilities(
                        for:
                            input
                    )
                    .capabilities
                    .first(
                        where: {
                            $0
                                .metadata[
                                    "operationId"
                                ]
                                == "createUpload"
                        }
                    )
            )

        XCTAssertEqual(
            capability
                .invocation,
            .direct
        )

        XCTAssertTrue(
            capability
                .requiresConfirmation
        )

        let unconfirmed =
            try engine.run(
                id:
                    capability.id,
                item:
                    input,
                confirmed:
                    false
            )

        XCTAssertEqual(
            unconfirmed
                .status,
            .confirmationRequired
        )

        XCTAssertEqual(
            resolutions,
            0
        )

        XCTAssertEqual(
            materializations,
            0
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            0
        )

        let accepted =
            try engine.run(
                id:
                    capability.id,
                item:
                    input,
                confirmed:
                    true
            )

        XCTAssertEqual(
            accepted
                .status,
            .accepted
        )

        XCTAssertEqual(
            resolutions,
            1
        )

        XCTAssertEqual(
            materializations,
            1
        )

        XCTAssertEqual(
            StubURLProtocol
                .requestCount,
            1
        )

        XCTAssertFalse(
            accepted
                .evidence
                .outcomeVerified
        )

        print(
            "GREEN011I_MEDIACAPTION_GENERIC_ISSUER_REGRESSION PASS"
        )

        print(
            "GREEN011I_MEDIACAPTION_ZERO_LIVE_CREDENTIAL PASS"
        )
    }
}
