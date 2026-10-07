#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

@testable import RightClickCore

final class MOAT004G1AcquisitionTests:
    XCTestCase
{
    private final class StubURLProtocol:
        URLProtocol
    {
        static var body =
            Data()

        static var statusCode =
            200

        static var extraHeaders:
            [String: String] = [:]

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
            guard
                let url =
                    request.url
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError:
                        NSError(
                            domain:
                                "MOAT004G1AcquisitionTests",
                            code:
                                1
                        )
                )

                return
            }

            let body =
                Self.body

            var headers =
                Self.extraHeaders

            headers[
                "Content-Length"
            ] =
                String(
                    body.count
                )

            let response =
                HTTPURLResponse(
                    url:
                        url,
                    statusCode:
                        Self.statusCode,
                    httpVersion:
                        "HTTP/1.1",
                    headerFields:
                        headers
                )!

            client?.urlProtocol(
                self,
                didReceive:
                    response,
                cacheStoragePolicy:
                    .notAllowed
            )

            if
                (200...299)
                .contains(
                    Self.statusCode
                )
            {
                client?.urlProtocol(
                    self,
                    didLoad:
                        body
                )
            }

            client?
                .urlProtocolDidFinishLoading(
                    self
                )
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        StubURLProtocol.body =
            Data()

        StubURLProtocol.statusCode =
            200

        StubURLProtocol.extraHeaders =
            [:]

        super.tearDown()
    }

    private func session()
        -> URLSession
    {
        let configuration =
            URLSessionConfiguration
                .ephemeral

        configuration.protocolClasses = [
            StubURLProtocol.self
        ]

        return URLSession(
            configuration:
                configuration
        )
    }

    private func fixtureURL()
        -> URL
    {
        URL(
            string:
                "https://provider.example/openapi.json"
        )!
    }

    private func sha256Hex(
        _ data: Data
    ) -> String {
        SHA256
            .hash(
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

    func testFrozenBoundsRemainExplicit()
        throws
    {
        XCTAssertEqual(
            OriginPinnedHTTP
                .maximumAcquisitionBytes,
            1_048_576
        )

        XCTAssertEqual(
            OriginPinnedHTTP
                .maximumOpenAPISpecificationBytes,
            16_777_216
        )

        XCTAssertEqual(
            OriginPinnedHTTP
                .acquisitionDeadline,
            5
        )
    }

    func testGenericDefaultLoaderStillRejectsOneByteOverOneMiB()
        throws
    {
        StubURLProtocol.body =
            Data(
                repeating:
                    0x61,
                count:
                    1_048_577
            )

        XCTAssertThrowsError(
            try OriginPinnedHTTP.load(
                fixtureURL(),
                template:
                    session()
            )
        ) {
            error in

            XCTAssertTrue(
                error
                    .localizedDescription
                    .contains(
                        "maximum acquisition size"
                    )
            )
        }
    }

    func testOpenAPISpecificationLoaderAcceptsFrozenGitHubSize()
        throws
    {
        StubURLProtocol.body =
            Data(
                repeating:
                    0x61,
                count:
                    12_901_084
            )

        let result =
            try OriginPinnedHTTP
                .loadOpenAPISpecification(
                    fixtureURL(),
                    template:
                        session()
                )

        XCTAssertEqual(
            result.count,
            12_901_084
        )
    }

    func testOpenAPISpecificationLoaderRejectsOneByteOverSixteenMiB()
        throws
    {
        StubURLProtocol.body =
            Data(
                repeating:
                    0x61,
                count:
                    16_777_217
            )

        XCTAssertThrowsError(
            try OriginPinnedHTTP
                .loadOpenAPISpecification(
                    fixtureURL(),
                    template:
                        session()
                )
        ) {
            error in

            XCTAssertTrue(
                error
                    .localizedDescription
                    .contains(
                        "maximum acquisition size"
                    )
            )
        }
    }

    func testOpenAPISpecificationLoaderRejectsRedirectResponse()
        throws
    {
        StubURLProtocol.statusCode =
            302

        StubURLProtocol.extraHeaders = [
            "Location":
                "https://different.example/openapi.json"
        ]

        XCTAssertThrowsError(
            try OriginPinnedHTTP
                .loadOpenAPISpecification(
                    fixtureURL(),
                    template:
                        session()
                )
        )
    }

    func testExactFrozenGitHubSpecificationLoadsThroughOpenAPISpecificBound()
        throws
    {
        guard
            let rawURL =
                ProcessInfo
                    .processInfo
                    .environment[
                        "MOAT004_G1_SPEC_URL"
                    ],
            let expectedSHA =
                ProcessInfo
                    .processInfo
                    .environment[
                        "MOAT004_G1_SPEC_SHA256"
                    ]
        else {
            throw XCTSkip(
                "MOAT004_G1_SPEC_URL and MOAT004_G1_SPEC_SHA256 required."
            )
        }

        let url =
            try XCTUnwrap(
                URL(
                    string:
                        rawURL
                )
            )

        let data =
            try OriginPinnedHTTP
                .loadOpenAPISpecification(
                    url
                )

        XCTAssertEqual(
            data.count,
            12_901_084
        )

        XCTAssertEqual(
            sha256Hex(
                data
            ),
            expectedSHA
        )
    }
}
