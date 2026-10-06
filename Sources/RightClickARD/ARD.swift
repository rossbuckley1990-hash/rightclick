import Foundation

public struct ARDSearchResult: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let type: String
    public let url: String?
    public let inlineData: Data?
    public let score: Int
    public let source: String

    public init(
        identifier: String,
        displayName: String,
        type: String,
        url: String?,
        inlineData: Data?,
        score: Int,
        source: String
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.type = type
        self.url = url
        self.inlineData = inlineData
        self.score = score
        self.source = source
    }
}

public struct ARDSearchResponse: Equatable, Sendable {
    public let results: [ARDSearchResult]
    public let referralCount: Int
    public let pageToken: String?

    public init(
        results: [ARDSearchResult],
        referralCount: Int = 0,
        pageToken: String? = nil
    ) {
        self.results = results
        self.referralCount = referralCount
        self.pageToken = pageToken
    }
}

public struct ARDOpenAPICandidate: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let mediaType: String
    public let specificationURL: String?
    public let inlineSpecification: Data?

    public init(
        identifier: String,
        displayName: String,
        mediaType: String,
        specificationURL: String?,
        inlineSpecification: Data?
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.mediaType = mediaType
        self.specificationURL = specificationURL
        self.inlineSpecification = inlineSpecification
    }
}

public enum ARDAcquisitionError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case invalidResult(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "ARD search request is invalid."
        case .invalidResponse:
            return "ARD SearchResponse is invalid."
        case let .invalidResult(index):
            return "ARD SearchResponse result at index \(index) is invalid."
        }
    }
}

public enum ARDAcquisition {
    public static let openAPIMediaTypes: Set<String> = [
        "application/openapi+json",
        "application/vnd.oai.openapi+json",
    ]

    public static func searchRequest(
        query rawQuery: String,
        pageSize: Int = 10,
        federation: String = "auto"
    ) throws -> Data {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            !query.isEmpty,
            query.utf8.count <= 16_384,
            (1...100).contains(pageSize),
            ["auto", "referrals", "none"].contains(federation)
        else {
            throw ARDAcquisitionError.invalidRequest
        }

        let object: [String: Any] = [
            "query": [
                "text": query,
            ],
            "federation": federation,
            "pageSize": pageSize,
        ]

        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    public static func decodeSearchResponse(
        _ data: Data
    ) throws -> ARDSearchResponse {
        guard
            data.count <= 4 * 1024 * 1024,
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["results"] as? [Any],
            rows.count <= 100
        else {
            throw ARDAcquisitionError.invalidResponse
        }

        var results: [ARDSearchResult] = []
        results.reserveCapacity(rows.count)

        for (index, raw) in rows.enumerated() {
            guard let row = raw as? [String: Any] else {
                throw ARDAcquisitionError.invalidResult(index)
            }

            results.append(
                try parseResult(row, index: index)
            )
        }

        let referrals: [Any]
        if let raw = root["referrals"] {
            guard let array = raw as? [Any], array.count <= 100 else {
                throw ARDAcquisitionError.invalidResponse
            }
            referrals = array
        } else {
            referrals = []
        }

        let pageToken: String?
        if let raw = root["pageToken"] {
            guard raw is NSNull || raw is String else {
                throw ARDAcquisitionError.invalidResponse
            }
            pageToken = raw as? String
        } else {
            pageToken = nil
        }

        return ARDSearchResponse(
            results: results,
            referralCount: referrals.count,
            pageToken: pageToken
        )
    }

    public static func openAPICandidates(
        in response: ARDSearchResponse
    ) -> [ARDOpenAPICandidate] {
        response.results.compactMap { result in
            let mediaType = result.type.lowercased()

            guard openAPIMediaTypes.contains(mediaType) else {
                return nil
            }

            return ARDOpenAPICandidate(
                identifier: result.identifier,
                displayName: result.displayName,
                mediaType: mediaType,
                specificationURL: result.url,
                inlineSpecification: result.inlineData
            )
        }
    }

    public static func literalOpenAPIBaseURL(
        from specificationData: Data
    ) -> String? {
        guard
            specificationData.count <= 16 * 1024 * 1024,
            let root = try? JSONSerialization.jsonObject(
                with: specificationData
            ) as? [String: Any],
            let rawServers = root["servers"] as? [Any],
            !rawServers.isEmpty
        else {
            return nil
        }

        var supported = Set<String>()

        for raw in rawServers {
            guard
                let server = raw as? [String: Any],
                server["variables"] == nil,
                let rawURL = server["url"] as? String,
                let canonical = canonicalHTTPURL(
                    rawURL,
                    allowQuery: false
                )
            else {
                continue
            }

            supported.insert(canonical)
        }

        guard supported.count == 1 else {
            return nil
        }

        return supported.first
    }

    public static func validatedArtifactURL(
        _ raw: String
    ) -> String? {
        canonicalHTTPURL(
            raw,
            allowQuery: true
        )
    }

    private static func parseResult(
        _ row: [String: Any],
        index: Int
    ) throws -> ARDSearchResult {
        guard
            let identifier = row["identifier"] as? String,
            validIdentifier(identifier),
            let displayName = row["displayName"] as? String,
            !displayName.isEmpty,
            displayName.utf8.count <= 512,
            let type = row["type"] as? String,
            !type.isEmpty,
            type.utf8.count <= 256,
            let score = row["score"] as? Int,
            (0...100).contains(score),
            let source = row["source"] as? String,
            !source.isEmpty,
            source.utf8.count <= 1024
        else {
            throw ARDAcquisitionError.invalidResult(index)
        }

        let rawURL = row["url"]
        let rawData = row["data"]

        guard (rawURL == nil) != (rawData == nil) else {
            throw ARDAcquisitionError.invalidResult(index)
        }

        let url: String?
        let inlineData: Data?

        if let rawURL {
            guard
                let string = rawURL as? String,
                let canonical = validatedArtifactURL(string)
            else {
                throw ARDAcquisitionError.invalidResult(index)
            }

            url = canonical
            inlineData = nil
        } else {
            guard
                let object = rawData as? [String: Any],
                JSONSerialization.isValidJSONObject(object)
            else {
                throw ARDAcquisitionError.invalidResult(index)
            }

            url = nil
            inlineData = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        }

        return ARDSearchResult(
            identifier: identifier,
            displayName: displayName,
            type: type,
            url: url,
            inlineData: inlineData,
            score: score,
            source: source
        )
    }

    private static func validIdentifier(
        _ value: String
    ) -> Bool {
        guard
            value.utf8.count <= 1024,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        return value.hasPrefix("urn:air:")
            || value.hasPrefix("urn:ai:")
    }

    private static func canonicalHTTPURL(
        _ raw: String,
        allowQuery: Bool
    ) -> String? {
        guard
            raw.utf8.count <= 4096,
            raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
            var components = URLComponents(string: raw),
            let rawScheme = components.scheme,
            let rawHost = components.host,
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            allowQuery || components.query == nil
        else {
            return nil
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            return nil
        }

        components.scheme = scheme
        components.host = rawHost.lowercased()

        if
            (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443)
        {
            components.port = nil
        }

        guard let url = components.url else {
            return nil
        }

        return url.absoluteString
    }
}
