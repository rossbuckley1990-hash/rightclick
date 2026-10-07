import Foundation
import XCTest

@testable import RightClickCore

final class OAuthOIDCAuthorityTests: XCTestCase {
    private func metadataData(
        issuer: String = "https://auth.example.com/tenant",
        authorizationEndpoint: String = "https://auth.example.com/authorize",
        tokenEndpoint: String = "https://auth.example.com/token",
        pkce: [String] = ["S256"],
        responseTypes: [String] = ["code"],
        grantTypes: [String] = ["authorization_code", "refresh_token"]
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "issuer": issuer,
                "authorization_endpoint": authorizationEndpoint,
                "token_endpoint": tokenEndpoint,
                "code_challenge_methods_supported": pkce,
                "response_types_supported": responseTypes,
                "grant_types_supported": grantTypes,
                "scopes_supported": [
                    "openid",
                    "profile",
                    "repo.read",
                ],
            ],
            options: [.sortedKeys]
        )
    }

    func testRFC7636S256Vector() throws {
        let value = try OAuthPKCE.make(
            codeVerifier:
                "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        )

        XCTAssertEqual(
            value.codeChallenge,
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testMetadataDiscoveryURLsPreserveIssuerPathSemantics() throws {
        let urls = try OAuthOIDCAuthority.metadataDiscoveryURLs(
            for: "HTTPS://AUTH.EXAMPLE.COM:443/tenant/"
        )

        XCTAssertEqual(
            urls.map(\.absoluteString),
            [
                "https://auth.example.com/tenant/.well-known/openid-configuration",
                "https://auth.example.com/.well-known/oauth-authorization-server/tenant",
            ]
        )
    }

    func testMetadataRequiresExactIssuerHTTPSAndS256() throws {
        let valid = try OAuthAuthorizationServerMetadata.decodeAndValidate(
            metadataData(),
            expectedIssuer: "https://auth.example.com/tenant"
        )

        XCTAssertEqual(
            valid.issuer,
            "https://auth.example.com/tenant"
        )

        XCTAssertThrowsError(
            try OAuthAuthorizationServerMetadata.decodeAndValidate(
                metadataData(
                    issuer:
                        "https://other.example.com/tenant"
                ),
                expectedIssuer:
                    "https://auth.example.com/tenant"
            )
        )

        XCTAssertThrowsError(
            try OAuthAuthorizationServerMetadata.decodeAndValidate(
                metadataData(
                    issuer:
                        "HTTPS://AUTH.EXAMPLE.COM:443/tenant/"
                ),
                expectedIssuer:
                    "https://auth.example.com/tenant"
            )
        )

        XCTAssertThrowsError(
            try OAuthAuthorizationServerMetadata.decodeAndValidate(
                metadataData(
                    authorizationEndpoint:
                        "http://auth.example.com/authorize"
                ),
                expectedIssuer:
                    "https://auth.example.com/tenant"
            )
        )

        XCTAssertThrowsError(
            try OAuthAuthorizationServerMetadata.decodeAndValidate(
                metadataData(
                    pkce:
                        ["plain"]
                ),
                expectedIssuer:
                    "https://auth.example.com/tenant"
            )
        )
    }

    func testAuthorizationURLUsesPKCES256AndNeverVerifier() throws {
        let metadata =
            try OAuthAuthorizationServerMetadata
                .decodeAndValidate(
                    metadataData(),
                    expectedIssuer:
                        "https://auth.example.com/tenant"
                )

        let binding =
            try OAuthAuthorityBinding(
                issuer:
                    "https://auth.example.com/tenant",
                resourceOrigin:
                    "https://api.example.com",
                clientID:
                    "rightclick-public-client",
                scopes: [
                    "repo.read",
                    "openid",
                ]
            )

        let pkce =
            try OAuthPKCE.make(
                codeVerifier:
                    "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
            )

        let url =
            try OAuthOIDCAuthority
                .authorizationURL(
                    metadata:
                        metadata,
                    binding:
                        binding,
                    redirectURI:
                        "http://127.0.0.1:43891/callback",
                    state:
                        "state-001",
                    pkce:
                        pkce
                )

        let components =
            try XCTUnwrap(
                URLComponents(
                    url:
                        url,
                    resolvingAgainstBaseURL:
                        false
                )
            )

        let values =
            Dictionary(
                uniqueKeysWithValues:
                    (components.queryItems ?? [])
                    .map {
                        (
                            $0.name,
                            $0.value ?? ""
                        )
                    }
            )

        XCTAssertEqual(
            values["response_type"],
            "code"
        )

        XCTAssertEqual(
            values["client_id"],
            "rightclick-public-client"
        )

        XCTAssertEqual(
            values["redirect_uri"],
            "http://127.0.0.1:43891/callback"
        )

        XCTAssertEqual(
            values["scope"],
            "openid repo.read"
        )

        XCTAssertEqual(
            values["state"],
            "state-001"
        )

        XCTAssertEqual(
            values["code_challenge_method"],
            "S256"
        )

        XCTAssertEqual(
            values["code_challenge"],
            pkce.codeChallenge
        )

        XCTAssertFalse(
            url.absoluteString
                .contains(
                    pkce.codeVerifier
                )
        )
    }

    func testBindingIsExactAcrossIssuerResourceClientAndScopes() throws {
        let first =
            try OAuthAuthorityBinding(
                issuer:
                    "HTTPS://AUTH.EXAMPLE.COM:443/tenant/",
                resourceOrigin:
                    "HTTPS://API.EXAMPLE.COM:443/",
                clientID:
                    "client-a",
                scopes: [
                    "write",
                    "read",
                    "read",
                ]
            )

        XCTAssertEqual(
            first.issuer,
            "https://auth.example.com/tenant"
        )

        XCTAssertEqual(
            first.resourceOrigin,
            "https://api.example.com"
        )

        XCTAssertEqual(
            first.scopes,
            [
                "read",
                "write",
            ]
        )

        let narrower =
            try OAuthAuthorityBinding(
                issuer:
                    first.issuer,
                resourceOrigin:
                    first.resourceOrigin,
                clientID:
                    first.clientID,
                scopes: [
                    "read"
                ]
            )

        XCTAssertNotEqual(
            first.keychainAccount,
            narrower.keychainAccount
        )

        XCTAssertFalse(
            first.keychainAccount
                .contains(
                    first.clientID
                )
        )

        XCTAssertThrowsError(
            try OAuthAuthorityBinding(
                issuer:
                    first.issuer,
                resourceOrigin:
                    "https://api.example.com/path",
                clientID:
                    first.clientID,
                scopes:
                    first.scopes
            )
        )
    }

    func testTokenBundleScopeAndExpiryLease() throws {
        let binding =
            try OAuthAuthorityBinding(
                issuer:
                    "https://auth.example.com",
                resourceOrigin:
                    "https://api.example.com",
                clientID:
                    "client-a",
                scopes: [
                    "read",
                    "write",
                ]
            )

        let live =
            try OAuthTokenBundle(
                accessToken:
                    "access-token",
                refreshToken:
                    "refresh-token",
                expiresAt:
                    Date(
                        timeIntervalSince1970:
                            2_000
                    ),
                scopes: [
                    "write",
                    "read",
                    "extra",
                ]
            )

        XCTAssertTrue(
            live.satisfies(
                binding:
                    binding,
                now:
                    Date(
                        timeIntervalSince1970:
                            1_000
                    )
            )
        )

        XCTAssertFalse(
            live.satisfies(
                binding:
                    binding,
                now:
                    Date(
                        timeIntervalSince1970:
                            3_000
                    )
            )
        )
    }

    func testKeychainRoundTripIsBoundToExactAuthorityLease() throws {
        let unique =
            UUID()
                .uuidString
                .lowercased()

        let binding =
            try OAuthAuthorityBinding(
                issuer:
                    "https://auth-\(unique).invalid",
                resourceOrigin:
                    "https://api-\(unique).invalid",
                clientID:
                    "client-\(unique)",
                scopes: [
                    "read",
                    "write",
                ]
            )

        let narrower =
            try OAuthAuthorityBinding(
                issuer:
                    binding.issuer,
                resourceOrigin:
                    binding.resourceOrigin,
                clientID:
                    binding.clientID,
                scopes: [
                    "read"
                ]
            )

        defer {
            _ =
                try?
                OAuthOIDCAuthority
                    .delete(
                        binding:
                            binding
                    )

            _ =
                try?
                OAuthOIDCAuthority
                    .delete(
                        binding:
                            narrower
                    )
        }

        let bundle =
            try OAuthTokenBundle(
                accessToken:
                    "oauth-access-secret",
                refreshToken:
                    "oauth-refresh-secret",
                expiresAt:
                    nil,
                scopes:
                    binding.scopes
            )

        try OAuthOIDCAuthority.save(
            bundle,
            for:
                binding
        )

        XCTAssertEqual(
            try OAuthOIDCAuthority
                .read(
                    for:
                        binding
                ),
            bundle
        )

        XCTAssertNil(
            try OAuthOIDCAuthority
                .read(
                    for:
                        narrower
                )
        )

        XCTAssertTrue(
            try OAuthOIDCAuthority
                .contains(
                    binding:
                        binding
                )
        )

        XCTAssertTrue(
            try OAuthOIDCAuthority
                .delete(
                    binding:
                        binding
                )
        )

        XCTAssertFalse(
            try OAuthOIDCAuthority
                .contains(
                    binding:
                        binding
                )
        )
    }

    func testLoopbackRedirectAndSecretValidationFailClosed() throws {
        let metadata =
            try OAuthAuthorizationServerMetadata
                .decodeAndValidate(
                    metadataData(),
                    expectedIssuer:
                        "https://auth.example.com/tenant"
                )

        let binding =
            try OAuthAuthorityBinding(
                issuer:
                    metadata.issuer,
                resourceOrigin:
                    "https://api.example.com",
                clientID:
                    "client-a",
                scopes: [
                    "openid"
                ]
            )

        let pkce =
            try OAuthPKCE.generate()

        XCTAssertThrowsError(
            try OAuthOIDCAuthority
                .authorizationURL(
                    metadata:
                        metadata,
                    binding:
                        binding,
                    redirectURI:
                        "https://evil.example/callback",
                    state:
                        "state",
                    pkce:
                        pkce
                )
        )

        XCTAssertThrowsError(
            try OAuthTokenBundle(
                accessToken:
                    "secret\nleak",
                refreshToken:
                    nil,
                expiresAt:
                    nil,
                scopes: [
                    "openid"
                ]
            )
        )
    }
}
