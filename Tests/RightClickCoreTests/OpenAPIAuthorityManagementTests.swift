@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import XCTest
@testable import RightClickCore

final class OpenAPIAuthorityManagementTests:
    XCTestCase
{
    private func uniqueHost() -> String {
        "g9-"
        + UUID()
            .uuidString
            .lowercased()
        + ".invalid"
    }

    #if os(macOS)
    func testManagementStoreWritesTheExactAccountExecutionReads()
        throws
    {
        let host =
            uniqueHost()

        let rawOrigin =
            "HTTPS://"
            + host.uppercased()
            + ":443/"

        let scheme =
            "G9Bearer"

        let token =
            "g9-management-secret-do-not-disclose"

        let canonicalOrigin =
            try OpenAPIAuthorityStore
                .canonicalBearerOrigin(
                    rawOrigin
                )

        XCTAssertEqual(
            canonicalOrigin,
            "https://" + host
        )

        defer {
            _ = try?
                OpenAPIAuthorityStore
                    .deleteBearerToken(
                        origin:
                            canonicalOrigin,
                        schemeName:
                            scheme
                    )
        }

        try OpenAPIAuthorityStore
            .setBearerToken(
                token,
                origin:
                    rawOrigin,
                schemeName:
                    scheme
            )

        let requirement =
            OpenAPIAuthorityRequirement
                .httpBearer(
                    schemeName:
                        scheme,
                    origin:
                        canonicalOrigin
                )

        XCTAssertEqual(
            OpenAPIAuthorityStore
                .bearerToken(
                    for:
                        requirement
                ),
            token
        )

        let stored =
            try OpenAPIAuthorityStore
                .containsBearerToken(
                    origin:
                        canonicalOrigin,
                    schemeName:
                        scheme
                )

        XCTAssertTrue(
            stored
        )
    }

    func testAuthorityDeleteIsScopedToExactOriginAndScheme()
        throws
    {
        let host =
            uniqueHost()

        let origin =
            "https://"
            + host

        let firstScheme =
            "G9First"

        let secondScheme =
            "G9Second"

        defer {
            _ = try?
                OpenAPIAuthorityStore
                    .deleteBearerToken(
                        origin:
                            origin,
                        schemeName:
                            firstScheme
                    )

            _ = try?
                OpenAPIAuthorityStore
                    .deleteBearerToken(
                        origin:
                            origin,
                        schemeName:
                            secondScheme
                    )
        }

        try OpenAPIAuthorityStore
            .setBearerToken(
                "first-secret",
                origin:
                    origin,
                schemeName:
                    firstScheme
            )

        try OpenAPIAuthorityStore
            .setBearerToken(
                "second-secret",
                origin:
                    origin,
                schemeName:
                    secondScheme
            )

        let deleted =
            try OpenAPIAuthorityStore
                .deleteBearerToken(
                    origin:
                        origin,
                    schemeName:
                        firstScheme
                )

        XCTAssertTrue(
            deleted
        )

        let firstPresent =
            try OpenAPIAuthorityStore
                .containsBearerToken(
                    origin:
                        origin,
                    schemeName:
                        firstScheme
                )

        let secondPresent =
            try OpenAPIAuthorityStore
                .containsBearerToken(
                    origin:
                        origin,
                    schemeName:
                        secondScheme
                )

        XCTAssertFalse(
            firstPresent
        )

        XCTAssertTrue(
            secondPresent
        )
    }

    #endif

    func testAuthorityManagementRequiresCredentialFreeHTTPSOrigin()
        throws
    {
        XCTAssertThrowsError(
            try OpenAPIAuthorityStore
                .canonicalBearerOrigin(
                    "http://provider.example"
                )
        )

        XCTAssertThrowsError(
            try OpenAPIAuthorityStore
                .canonicalBearerOrigin(
                    "https://user:pass@provider.example"
                )
        )

        XCTAssertThrowsError(
            try OpenAPIAuthorityStore
                .canonicalBearerOrigin(
                    "https://provider.example/api"
                )
        )

        XCTAssertThrowsError(
            try OpenAPIAuthorityStore
                .canonicalBearerOrigin(
                    "https://provider.example?secret=value"
                )
        )

        XCTAssertThrowsError(
            try OpenAPIAuthorityStore
                .canonicalBearerSchemeName(
                    "bad|scheme"
                )
        )
    }
}
