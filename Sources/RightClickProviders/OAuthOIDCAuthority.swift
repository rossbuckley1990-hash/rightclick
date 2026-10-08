import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum OAuthOIDCAuthorityError: Error, LocalizedError {
    case invalidIssuer
    case issuerMismatch
    case invalidMetadata(String)
    case invalidBinding(String)
    case invalidPKCE
    case invalidRedirectURI
    case invalidState
    case invalidTokenBundle(String)
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidIssuer:
            return "OAuth/OIDC issuer must be one credential-free HTTPS URL without query or fragment."
        case .issuerMismatch:
            return "OAuth/OIDC discovery metadata issuer does not exactly match the requested issuer."
        case let .invalidMetadata(reason):
            return "OAuth/OIDC discovery metadata is invalid: \(reason)"
        case let .invalidBinding(reason):
            return "OAuth/OIDC authority binding is invalid: \(reason)"
        case .invalidPKCE:
            return "OAuth PKCE material is invalid."
        case .invalidRedirectURI:
            return "OAuth redirect URI must be a credential-free loopback HTTP URI."
        case .invalidState:
            return "OAuth state is empty, too large, or contains control characters."
        case let .invalidTokenBundle(reason):
            return "OAuth token bundle is invalid: \(reason)"
        case let .keychain(status):
            return PlatformHostDefaults.host.secretErrorDescription(status)
        }
    }
}

public struct OAuthAuthorizationServerMetadata: Codable, Equatable, Sendable {
    public let issuer: String
    public let authorizationEndpoint: String
    public let tokenEndpoint: String
    public let codeChallengeMethodsSupported: [String]?
    public let scopesSupported: [String]?
    public let responseTypesSupported: [String]?
    public let grantTypesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case scopesSupported = "scopes_supported"
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
    }

    public static func decodeAndValidate(
        _ data: Data,
        expectedIssuer rawExpectedIssuer: String
    ) throws -> Self {
        let expectedIssuer = try OAuthOIDCAuthority.canonicalIssuer(rawExpectedIssuer)
        let metadata = try JSONDecoder().decode(Self.self, from: data)

        // RFC 8414 requires the returned issuer identifier to be identical
        // to the issuer used to derive the metadata location. Canonical
        // equivalence is deliberately not enough here: exact comparison is
        // part of the authorization-server mix-up defence.
        guard metadata.issuer == expectedIssuer else {
            throw OAuthOIDCAuthorityError.issuerMismatch
        }

        _ = try OAuthOIDCAuthority.canonicalIssuer(metadata.issuer)

        guard try OAuthOIDCAuthority.validatedHTTPSURL(metadata.authorizationEndpoint) != nil else {
            throw OAuthOIDCAuthorityError.invalidMetadata(
                "authorization_endpoint must be an absolute credential-free HTTPS URL"
            )
        }

        guard try OAuthOIDCAuthority.validatedHTTPSURL(metadata.tokenEndpoint) != nil else {
            throw OAuthOIDCAuthorityError.invalidMetadata(
                "token_endpoint must be an absolute credential-free HTTPS URL"
            )
        }

        guard metadata.codeChallengeMethodsSupported?.contains("S256") == true else {
            throw OAuthOIDCAuthorityError.invalidMetadata(
                "S256 PKCE support must be explicitly advertised"
            )
        }

        if let responseTypes = metadata.responseTypesSupported,
           !responseTypes.contains("code") {
            throw OAuthOIDCAuthorityError.invalidMetadata(
                "authorization code response type is not supported"
            )
        }

        if let grantTypes = metadata.grantTypesSupported,
           !grantTypes.contains("authorization_code") {
            throw OAuthOIDCAuthorityError.invalidMetadata(
                "authorization_code grant is not supported"
            )
        }

        return Self(
            issuer: expectedIssuer,
            authorizationEndpoint: metadata.authorizationEndpoint,
            tokenEndpoint: metadata.tokenEndpoint,
            codeChallengeMethodsSupported: metadata.codeChallengeMethodsSupported,
            scopesSupported: metadata.scopesSupported,
            responseTypesSupported: metadata.responseTypesSupported,
            grantTypesSupported: metadata.grantTypesSupported
        )
    }
}

public struct OAuthAuthorityBinding: Codable, Equatable, Sendable {
    public let issuer: String
    public let resourceOrigin: String
    public let clientID: String
    public let scopes: [String]

    public init(
        issuer rawIssuer: String,
        resourceOrigin rawResourceOrigin: String,
        clientID rawClientID: String,
        scopes rawScopes: [String]
    ) throws {
        let issuer = try OAuthOIDCAuthority.canonicalIssuer(rawIssuer)
        let resourceOrigin = try OAuthOIDCAuthority.canonicalHTTPSOrigin(rawResourceOrigin)
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !clientID.isEmpty,
            clientID.utf8.count <= 1024,
            clientID.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw OAuthOIDCAuthorityError.invalidBinding(
                "client_id is empty, too large, or contains control characters"
            )
        }

        var scopes = Set<String>()

        for rawScope in rawScopes {
            let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)

            guard
                !scope.isEmpty,
                scope.utf8.count <= 256,
                scope.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                scope.rangeOfCharacter(from: .controlCharacters) == nil
            else {
                throw OAuthOIDCAuthorityError.invalidBinding(
                    "scope values must be non-empty single tokens"
                )
            }

            scopes.insert(scope)
        }

        guard !scopes.isEmpty else {
            throw OAuthOIDCAuthorityError.invalidBinding("at least one scope is required")
        }

        self.issuer = issuer
        self.resourceOrigin = resourceOrigin
        self.clientID = clientID
        self.scopes = scopes.sorted()
    }

    public var keychainAccount: String {
        let material = [
            issuer,
            resourceOrigin,
            clientID,
            scopes.joined(separator: " "),
        ].joined(separator: "\n")

        let digest = SHA256.hash(data: Data(material.utf8))

        return "oauth|" + digest.map {
            String(format: "%02x", $0)
        }.joined()
    }
}

public struct OAuthPKCE: Equatable, Sendable {
    public let codeVerifier: String
    public let codeChallenge: String

    public static func generate() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)

        var generator = SystemRandomNumberGenerator()
        bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }

        return try make(randomBytes: Data(bytes))
    }

    public static func make(randomBytes: Data) throws -> Self {
        guard randomBytes.count == 32 else {
            throw OAuthOIDCAuthorityError.invalidPKCE
        }

        return try make(
            codeVerifier: OAuthOIDCAuthority.base64URL(randomBytes)
        )
    }

    public static func make(codeVerifier: String) throws -> Self {
        guard
            codeVerifier.count >= 43,
            codeVerifier.count <= 128,
            codeVerifier.unicodeScalars.allSatisfy({ scalar in
                let value = scalar.value
                return
                    (value >= 48 && value <= 57)
                    || (value >= 65 && value <= 90)
                    || (value >= 97 && value <= 122)
                    || value == 45
                    || value == 46
                    || value == 95
                    || value == 126
            })
        else {
            throw OAuthOIDCAuthorityError.invalidPKCE
        }

        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        let challenge = OAuthOIDCAuthority.base64URL(Data(digest))

        return Self(
            codeVerifier: codeVerifier,
            codeChallenge: challenge
        )
    }
}

public struct OAuthTokenBundle: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let expiresAt: Date?
    public let scopes: [String]

    public init(
        accessToken: String,
        refreshToken: String?,
        tokenType: String = "Bearer",
        expiresAt: Date?,
        scopes: [String]
    ) throws {
        try OAuthOIDCAuthority.validateSecret(accessToken, field: "access_token")

        if let refreshToken {
            try OAuthOIDCAuthority.validateSecret(refreshToken, field: "refresh_token")
        }

        guard tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw OAuthOIDCAuthorityError.invalidTokenBundle(
                "only Bearer access tokens are supported"
            )
        }

        var normalizedScopes = Set<String>()

        for rawScope in scopes {
            let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines)

            guard
                !scope.isEmpty,
                scope.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                scope.rangeOfCharacter(from: .controlCharacters) == nil
            else {
                throw OAuthOIDCAuthorityError.invalidTokenBundle(
                    "token scope contains an invalid value"
                )
            }

            normalizedScopes.insert(scope)
        }

        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = "Bearer"
        self.expiresAt = expiresAt
        self.scopes = normalizedScopes.sorted()
    }

    public func satisfies(
        binding: OAuthAuthorityBinding,
        now: Date = Date()
    ) -> Bool {
        guard Set(binding.scopes).isSubset(of: Set(scopes)) else {
            return false
        }

        if let expiresAt {
            return expiresAt > now
        }

        return true
    }
}

public enum OAuthOIDCAuthority {
    public static let keychainService = "ai.rightclick.oauth-authority"

    public static func metadataDiscoveryURLs(
        for rawIssuer: String
    ) throws -> [URL] {
        let issuer = try canonicalIssuer(rawIssuer)

        guard
            let issuerURL = URL(string: issuer),
            let components = URLComponents(
                url: issuerURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw OAuthOIDCAuthorityError.invalidIssuer
        }

        let issuerPath = components.path

        var oidc = components
        oidc.path =
            (issuerPath == "/" || issuerPath.isEmpty)
            ? "/.well-known/openid-configuration"
            : issuerPath + "/.well-known/openid-configuration"

        var oauth = components
        oauth.path =
            "/.well-known/oauth-authorization-server"
            + (issuerPath == "/" ? "" : issuerPath)

        guard
            let oidcURL = oidc.url,
            let oauthURL = oauth.url
        else {
            throw OAuthOIDCAuthorityError.invalidIssuer
        }

        return [oidcURL, oauthURL]
    }

    public static func authorizationURL(
        metadata: OAuthAuthorizationServerMetadata,
        binding: OAuthAuthorityBinding,
        redirectURI: String,
        state: String,
        pkce: OAuthPKCE
    ) throws -> URL {
        guard metadata.issuer == binding.issuer else {
            throw OAuthOIDCAuthorityError.issuerMismatch
        }

        let redirect = try validatedLoopbackRedirectURI(redirectURI)

        guard
            !state.isEmpty,
            state.utf8.count <= 1024,
            state.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw OAuthOIDCAuthorityError.invalidState
        }

        guard var components = URLComponents(
            string: metadata.authorizationEndpoint
        ) else {
            throw OAuthOIDCAuthorityError.invalidMetadata(
                "authorization_endpoint could not be parsed"
            )
        }

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: binding.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "scope", value: binding.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let result = components.url else {
            throw OAuthOIDCAuthorityError.invalidMetadata(
                "authorization request URL could not be constructed"
            )
        }

        return result
    }

    public static func save(_ bundle: OAuthTokenBundle, for binding: OAuthAuthorityBinding) throws {
        guard Set(binding.scopes).isSubset(of: Set(bundle.scopes)) else {
            throw OAuthOIDCAuthorityError.invalidTokenBundle("granted scopes do not satisfy the authority binding")
        }
        do { try PlatformHostDefaults.host.writeSecret(try JSONEncoder().encode(bundle), service: keychainService, account: binding.keychainAccount) }
        catch PlatformSecretError.store(let status) { throw OAuthOIDCAuthorityError.keychain(status) }
    }

    public static func read(for binding: OAuthAuthorityBinding) throws -> OAuthTokenBundle? {
        do {
            guard let data = try PlatformHostDefaults.host.readSecret(service: keychainService, account: binding.keychainAccount) else { return nil }
            return try JSONDecoder().decode(OAuthTokenBundle.self, from: data)
        } catch PlatformSecretError.store(let status) { throw OAuthOIDCAuthorityError.keychain(status) }
    }

    public static func contains(binding: OAuthAuthorityBinding) throws -> Bool { try read(for: binding) != nil }

    @discardableResult
    public static func delete(binding: OAuthAuthorityBinding) throws -> Bool {
        do { return try PlatformHostDefaults.host.deleteSecret(service: keychainService, account: binding.keychainAccount) }
        catch PlatformSecretError.store(let status) { throw OAuthOIDCAuthorityError.keychain(status) }
    }

    static func canonicalIssuer(_ raw: String) throws -> String {
        guard
            !raw.isEmpty,
            raw.utf8.count <= 2048,
            raw.trimmingCharacters(in: .whitespacesAndNewlines) == raw,
            var components = URLComponents(string: raw),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw OAuthOIDCAuthorityError.invalidIssuer
        }

        components.scheme = "https"
        components.host = host.lowercased()

        if components.port == 443 {
            components.port = nil
        }

        var path = components.path

        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }

        if path == "/" {
            path = ""
        }

        components.path = path

        guard let url = components.url else {
            throw OAuthOIDCAuthorityError.invalidIssuer
        }

        var value = url.absoluteString

        if value.hasSuffix("/") {
            value.removeLast()
        }

        return value
    }

    static func canonicalHTTPSOrigin(_ raw: String) throws -> String {
        guard
            let url = try validatedHTTPSURL(raw),
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.path.isEmpty || components.path == "/",
            components.query == nil,
            components.fragment == nil
        else {
            throw OAuthOIDCAuthorityError.invalidBinding(
                "resource origin must be one credential-free HTTPS origin"
            )
        }

        components.path = ""

        guard let canonical = components.url else {
            throw OAuthOIDCAuthorityError.invalidBinding(
                "resource origin could not be canonicalized"
            )
        }

        var value = canonical.absoluteString

        if value.hasSuffix("/") {
            value.removeLast()
        }

        return value
    }

    static func validatedHTTPSURL(_ raw: String) throws -> URL? {
        guard
            !raw.isEmpty,
            raw.trimmingCharacters(in: .whitespacesAndNewlines) == raw,
            var components = URLComponents(string: raw),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil
        else {
            return nil
        }

        components.scheme = "https"
        components.host = host.lowercased()

        if components.port == 443 {
            components.port = nil
        }

        return components.url
    }

    static func validatedLoopbackRedirectURI(_ raw: String) throws -> URL {
        guard
            let components = URLComponents(string: raw),
            components.scheme?.lowercased() == "http",
            let host = components.host?.lowercased(),
            ["127.0.0.1", "::1", "localhost"].contains(host),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            let url = components.url
        else {
            throw OAuthOIDCAuthorityError.invalidRedirectURI
        }

        return url
    }

    static func base64URL(_ data: Data) -> String {
        data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func validateSecret(
        _ value: String,
        field: String
    ) throws {
        guard
            !value.isEmpty,
            value.utf8.count <= 1_048_576,
            value.rangeOfCharacter(from: .newlines) == nil,
            value.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw OAuthOIDCAuthorityError.invalidTokenBundle(
                "\(field) is empty, too large, or contains control characters"
            )
        }
    }

}
