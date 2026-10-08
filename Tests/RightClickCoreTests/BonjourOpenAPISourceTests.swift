@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
import XCTest
@testable import RightClickCore

final class BonjourOpenAPISourceTests:
    XCTestCase
{
    final class LoaderProbe {
        var requestedURLs: [URL] = []
        var data: Data

        init(data: Data) {
            self.data = data
        }

        func load(_ url: URL) throws -> Data {
            requestedURLs.append(url)
            return data
        }
    }

    private func specification(
        operationID: String = "uppercaseText"
    ) -> Data {
        Data(
            """
            {
              "openapi": "3.0.3",
              "info": {
                "title": "Discovered Text Provider",
                "version": "1.0.0"
              },
              "paths": {
                "/transform": {
                  "post": {
                    "operationId": "\(operationID)",
                    "summary": "Uppercase text",
                    "requestBody": {
                      "required": true,
                      "content": {
                        "text/plain": {
                          "schema": {
                            "type": "string"
                          }
                        }
                      }
                    },
                    "responses": {
                      "200": {
                        "description": "Success",
                        "content": {
                          "text/plain": {
                            "schema": {
                              "type": "string"
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
            """.utf8
        )
    }

    private func descriptor(
        host: String = "127.0.0.1",
        port: Int = 40123,
        txt: [String: String] = [
            "kind": "openapi",
            "scheme": "http",
            "spec": "/openapi.json",
            "base": "/api",
        ]
    ) -> BonjourOpenAPIServiceDescriptor {
        BonjourOpenAPIServiceDescriptor(
            instanceName: "Unknown Provider",
            serviceType:
                "_rightclick._tcp.",
            domain: "local.",
            host: host,
            port: port,
            txt: txt
        )
    }

    func testResolvedAdvertisementCreatesDynamicOpenAPIReflector()
        throws
    {
        let loader =
            LoaderProbe(
                data: specification()
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing: false,
                specificationLoader:
                    loader.load
            )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(for: "hello")
                .capabilities
                .isEmpty
        )

        source.update(
            resolved:
                descriptor()
        )

        XCTAssertEqual(
            loader.requestedURLs.map(
                \.absoluteString
            ),
            [
                "http://127.0.0.1:40123/openapi.json"
            ]
        )

        let reflectors =
            source.reflectors()

        XCTAssertEqual(
            reflectors.count,
            1
        )

        let capabilities =
            try engine
                .capabilities(
                    for: "hello"
                )
                .capabilities

        XCTAssertEqual(
            capabilities.count,
            1
        )

        XCTAssertEqual(
            capabilities.first?
                .metadata["substrate"],
            "openapi"
        )

        XCTAssertEqual(
            capabilities.first?
                .metadata["baseURL"],
            "http://127.0.0.1:40123/api"
        )
    }

    func testMalformedMetadataAbstainsWithoutFetching()
        throws
    {
        let loader =
            LoaderProbe(
                data: specification()
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing: false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                descriptor(
                    txt: [
                        "kind": "openapi",
                        "scheme": "http",
                        "base": "/api",
                    ]
                )
        )

        XCTAssertTrue(
            source.reflectors().isEmpty
        )

        XCTAssertTrue(
            loader.requestedURLs.isEmpty
        )

        source.update(
            resolved:
                descriptor(
                    txt: [
                        "kind": "openapi",
                        "scheme": "ftp",
                        "spec": "/openapi.json",
                        "base": "/api",
                    ]
                )
        )

        XCTAssertTrue(
            source.reflectors().isEmpty
        )

        XCTAssertTrue(
            loader.requestedURLs.isEmpty
        )

        source.update(
            resolved:
                descriptor(
                    txt: [
                        "kind": "grpc",
                        "scheme": "http",
                        "spec": "/openapi.json",
                        "base": "/api",
                    ]
                )
        )

        XCTAssertTrue(
            source.reflectors().isEmpty
        )

        XCTAssertTrue(
            loader.requestedURLs.isEmpty
        )
    }

    func testTXTMetadataCannotRedirectToExternalHost()
        throws
    {
        let loader =
            LoaderProbe(
                data: specification()
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing: false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                descriptor(
                    txt: [
                        "kind": "openapi",
                        "scheme": "http",
                        "spec":
                            "https://evil.example/openapi.json",
                        "base": "/api",
                    ]
                )
        )

        source.update(
            resolved:
                descriptor(
                    txt: [
                        "kind": "openapi",
                        "scheme": "http",
                        "spec": "/openapi.json",
                        "base":
                            "https://evil.example/api",
                    ]
                )
        )

        XCTAssertTrue(
            source.reflectors().isEmpty
        )

        XCTAssertTrue(
            loader.requestedURLs.isEmpty
        )
    }

    func testRemovalMakesStaleCapabilityUnavailable()
        throws
    {
        let loader =
            LoaderProbe(
                data: specification()
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing: false,
                specificationLoader:
                    loader.load
            )

        let service =
            descriptor()

        source.update(
            resolved: service
        )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for: "hello"
                    )
                    .capabilities
                    .first
            )

        source.remove(
            instanceName:
                service.instanceName,
            serviceType:
                service.serviceType,
            domain:
                service.domain
        )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for: "hello"
                )
                .capabilities
                .isEmpty
        )

        let stale =
            try engine.run(
                id:
                    capability.id,
                item:
                    "hello",
                confirmed:
                    true
            )

        XCTAssertEqual(
            stale.status,
            .unavailable
        )
    }

    func testEndpointReplacementChangesCapabilityIdentity()
        throws
    {
        let loader =
            LoaderProbe(
                data: specification()
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing: false,
                specificationLoader:
                    loader.load
            )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        source.update(
            resolved:
                descriptor(
                    port: 40123
                )
        )

        let firstID =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for: "hello"
                    )
                    .capabilities
                    .first?
                    .id
            )

        source.update(
            resolved:
                descriptor(
                    port: 48999
                )
        )

        let secondID =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for: "hello"
                    )
                    .capabilities
                    .first?
                    .id
            )

        XCTAssertNotEqual(
            firstID,
            secondID
        )

        let stale =
            try engine.run(
                id:
                    firstID,
                item:
                    "hello",
                confirmed:
                    true
            )

        XCTAssertEqual(
            stale.status,
            .unavailable
        )
    }

    func testAbsoluteBonjourDNSNameCanonicalizesTerminalRootDot()
        throws
    {
        let loader =
            LoaderProbe(
                data: specification()
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing: false,
                specificationLoader:
                    loader.load
            )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        source.update(
            resolved:
                descriptor(
                    host:
                        "remote.example.",
                    port:
                        443,
                    txt: [
                        "kind": "openapi",
                        "scheme": "https",
                        "spec": "/openapi.json",
                        "base": "/",
                    ]
                )
        )

        let requestedURL =
            try XCTUnwrap(
                loader.requestedURLs.first
            )

        XCTAssertEqual(
            requestedURL.scheme,
            "https"
        )

        XCTAssertEqual(
            requestedURL.host,
            "remote.example"
        )

        XCTAssertEqual(
            requestedURL.port,
            443
        )

        let capability =
            try XCTUnwrap(
                engine
                    .capabilities(
                        for: "hello"
                    )
                    .capabilities
                    .first
            )

        XCTAssertEqual(
            capability
                .metadata["baseURL"],
            "https://remote.example"
        )
    }

    func testMultipleTerminalRootDotsAreRejected()
        throws
    {
        let loader =
            LoaderProbe(
                data: specification()
            )

        let source =
            BonjourOpenAPISource(
                startBrowsing: false,
                specificationLoader:
                    loader.load
            )

        source.update(
            resolved:
                descriptor(
                    host:
                        "remote.example..",
                    port:
                        443,
                    txt: [
                        "kind": "openapi",
                        "scheme": "https",
                        "spec": "/openapi.json",
                        "base": "/",
                    ]
                )
        )

        XCTAssertTrue(
            source.reflectors().isEmpty
        )

        XCTAssertTrue(
            loader.requestedURLs.isEmpty
        )
    }

}
