#if canImport(RightClickARD)
import Foundation
import RightClickARD

public struct ARDRegistryDescriptor:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let searchURL: String

    public init(
        id: String,
        searchURL: String
    ) {
        self.id = id
        self.searchURL = searchURL
    }
}

/// Contextual ARD discovery source.
///
/// ARD remains discovery-only. A supported ARD result is converted into an
/// ordinary RIGHTCLICK reflector; execution, authority and semantic
/// verification remain owned by the existing capability runtime.
public final class ARDRegistrySource:
    ContextualCapabilityReflectorSource
{
    public static let environmentKey =
        "RIGHTCLICK_ARD_REGISTRIES"

    public let id =
        "ard.registry"

    public typealias SearchLoader =
        (URL, Data) throws -> Data

    public typealias SpecificationLoader =
        (URL) throws -> Data

    private let registries:
        [ARDRegistryDescriptor]

    private let searchLoader:
        SearchLoader

    private let specificationLoader:
        SpecificationLoader

    private let providerSession:
        URLSession

    private let stateLock =
        NSLock()

    private var lastReflectors:
        [any CapabilityReflector] = []

    public convenience init(
        registries:
            [ARDRegistryDescriptor]
    ) {
        self.init(
            registries:
                registries,
            searchLoader: {
                url,
                body in

                try Self.defaultSearch(
                    url:
                        url,
                    body:
                        body
                )
            },
            specificationLoader: {
                try OriginPinnedHTTP
                    .loadOpenAPISpecification(
                        $0
                    )
            },
            providerSession:
                .shared
        )
    }

    public init(
        registries:
            [ARDRegistryDescriptor],
        searchLoader:
            @escaping SearchLoader,
        specificationLoader:
            @escaping SpecificationLoader,
        providerSession:
            URLSession = .shared
    ) {
        self.registries =
            Self.validatedRegistries(
                registries
            )

        self.searchLoader =
            searchLoader

        self.specificationLoader =
            specificationLoader

        self.providerSession =
            providerSession
    }

    public static func fromEnvironment(
        _ environment:
            [String: String] =
                ProcessInfo
                    .processInfo
                    .environment
    ) -> ARDRegistrySource? {
        guard
            let raw =
                environment[
                    environmentKey
                ],
            raw.utf8.count
                <= 65_536,
            let data =
                raw.data(
                    using:
                        .utf8
                ),
            let decoded =
                try? JSONDecoder()
                    .decode(
                        [ARDRegistryDescriptor].self,
                        from:
                            data
                    ),
            !decoded.isEmpty,
            decoded.count <= 16
        else {
            return nil
        }

        let validated =
            validatedRegistries(
                decoded
            )

        guard
            validated.count
                == decoded.count
        else {
            return nil
        }

        return ARDRegistrySource(
            registries:
                validated
        )
    }

    public func reflectors()
        -> [any CapabilityReflector]
    {
        stateLock.lock()

        let snapshot =
            lastReflectors

        stateLock.unlock()

        return snapshot
    }

    public func reflectors(
        for item: ContentItem
    ) -> [any CapabilityReflector] {
        let query =
            item.text
            ?? item.url
            ?? item.path
            ?? item.display

        guard
            !query
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .isEmpty
        else {
            replaceState(
                []
            )

            return []
        }

        var next:
            [any CapabilityReflector] = []

        for registry
            in registries
        {
            guard
                let searchURL =
                    Self.allowedNetworkURL(
                        registry.searchURL
                    ),
                let request =
                    try? ARDAcquisition
                        .searchRequest(
                            query:
                                query
                        ),
                let responseData =
                    try? searchLoader(
                        searchURL,
                        request
                    ),
                let response =
                    try? ARDAcquisition
                        .decodeSearchResponse(
                            responseData
                        )
            else {
                continue
            }

            let candidates =
                ARDAcquisition
                    .openAPICandidates(
                        in:
                            response
                    )

            for candidate
                in candidates
            {
                guard
                    let specification =
                        try? specificationData(
                            candidate
                        ),
                    let rawBaseURL =
                        ARDAcquisition
                            .literalOpenAPIBaseURL(
                                from:
                                    specification
                            ),
                    let baseURL =
                        Self.allowedNetworkURL(
                            rawBaseURL
                        ),
                    let reflector =
                        try? OpenAPIReflector(
                            specificationData:
                                specification,
                            baseURL:
                                baseURL,
                            session:
                                providerSession
                        )
                else {
                    continue
                }

                next.append(
                    ARDOpenAPIReflector(
                        registryID:
                            registry.id,
                        candidate:
                            candidate,
                        underlying:
                            reflector
                    )
                )
            }
        }

        var counts:
            [String: Int] = [:]

        for reflector
            in next
        {
            counts[
                reflector.id,
                default:
                    0
            ] += 1
        }

        next =
            next.filter {
                counts[$0.id] == 1
            }
            .sorted {
                $0.id < $1.id
            }

        replaceState(
            next
        )

        return next
    }

    private func specificationData(
        _ candidate:
            ARDOpenAPICandidate
    ) throws -> Data {
        if let inline =
            candidate.inlineSpecification
        {
            return inline
        }

        guard
            let raw =
                candidate.specificationURL,
            let url =
                Self.allowedNetworkURL(
                    raw
                )
        else {
            throw RightClickError(
                "ARD OpenAPI artifact URL is unsafe."
            )
        }

        return try specificationLoader(
            url
        )
    }

    private func replaceState(
        _ reflectors:
            [any CapabilityReflector]
    ) {
        stateLock.lock()

        lastReflectors =
            reflectors

        stateLock.unlock()
    }

    private static func validatedRegistries(
        _ rows:
            [ARDRegistryDescriptor]
    ) -> [ARDRegistryDescriptor] {
        guard rows.count <= 16 else {
            return []
        }

        var seen =
            Set<String>()

        var validated:
            [ARDRegistryDescriptor] = []

        for row
            in rows
        {
            guard
                validID(
                    row.id
                ),
                seen.insert(
                    row.id
                )
                .inserted,
                let url =
                    allowedNetworkURL(
                        row.searchURL
                    )
            else {
                return []
            }

            validated.append(
                ARDRegistryDescriptor(
                    id:
                        row.id,
                    searchURL:
                        url.absoluteString
                )
            )
        }

        return validated.sorted {
            $0.id < $1.id
        }
    }

    private static func validID(
        _ value: String
    ) -> Bool {
        guard
            !value.isEmpty,
            value.count <= 64,
            value
                == value
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
        else {
            return false
        }

        return value
            .unicodeScalars
            .allSatisfy {
                scalar in

                let raw =
                    scalar.value

                return
                    (raw >= 48
                        && raw <= 57)
                    || (raw >= 65
                        && raw <= 90)
                    || (raw >= 97
                        && raw <= 122)
                    || raw == 45
                    || raw == 46
                    || raw == 95
            }
    }

    private static func allowedNetworkURL(
        _ raw: String
    ) -> URL? {
        guard
            var components =
                URLComponents(
                    string:
                        raw
                ),
            let rawScheme =
                components.scheme,
            let rawHost =
                components.host,
            components.user == nil,
            components.password == nil,
            components.fragment == nil
        else {
            return nil
        }

        let scheme =
            rawScheme.lowercased()

        let host =
            rawHost.lowercased()

        guard
            scheme == "https"
            || (
                scheme == "http"
                && [
                    "localhost",
                    "127.0.0.1",
                    "::1",
                ]
                .contains(
                    host
                )
            )
        else {
            return nil
        }

        components.scheme =
            scheme

        components.host =
            host

        if
            (
                scheme == "http"
                && components.port == 80
            )
            || (
                scheme == "https"
                && components.port == 443
            )
        {
            components.port =
                nil
        }

        return components.url
    }

    private final class SearchBox:
        @unchecked Sendable
    {
        private let lock =
            NSLock()

        private var stored:
            (
                Data?,
                URLResponse?,
                Error?
            ) =
            (
                nil,
                nil,
                nil
            )

        func set(
            data: Data?,
            response: URLResponse?,
            error: Error?
        ) {
            lock.lock()

            stored =
                (
                    data,
                    response,
                    error
                )

            lock.unlock()
        }

        func get()
            -> (
                Data?,
                URLResponse?,
                Error?
            )
        {
            lock.lock()

            defer {
                lock.unlock()
            }

            return stored
        }
    }

    private static func defaultSearch(
        url: URL,
        body: Data
    ) throws -> Data {
        let session =
            OriginPinnedHTTP
                .makeSession()

        defer {
            session.invalidateAndCancel()
        }

        var request =
            URLRequest(
                url:
                    url
            )

        request.httpMethod =
            "POST"

        request.httpBody =
            body

        request.timeoutInterval =
            OriginPinnedHTTP
                .acquisitionDeadline

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Accept"
        )

        let semaphore =
            DispatchSemaphore(
                value:
                    0
            )

        let box =
            SearchBox()

        let task =
            session.dataTask(
                with:
                    request
            ) {
                data,
                response,
                error in

                box.set(
                    data:
                        data,
                    response:
                        response,
                    error:
                        error
                )

                semaphore.signal()
            }

        task.resume()

        let wait =
            semaphore.wait(
                timeout:
                    .now()
                    + .milliseconds(
                        Int(
                            OriginPinnedHTTP
                                .acquisitionDeadline
                                * 1_000
                        )
                    )
            )

        guard wait == .success else {
            task.cancel()

            throw RightClickError(
                "ARD registry search exceeded the acquisition deadline."
            )
        }

        let result =
            box.get()

        if let error =
            result.2
        {
            throw error
        }

        guard
            let response =
                result.1
                    as? HTTPURLResponse,
            OriginPinnedHTTP
                .sameOrigin(
                    url,
                    response.url
                ),
            (200...299)
                .contains(
                    response.statusCode
                ),
            let data =
                result.0,
            data.count <= 4 * 1024 * 1024
        else {
            throw RightClickError(
                "ARD registry returned an invalid search response."
            )
        }

        return data
    }
}

private final class ARDOpenAPIReflector:
    CapabilityReflector
{
    let id: String

    private let registryID:
        String

    private let candidate:
        ARDOpenAPICandidate

    private let underlying:
        OpenAPIReflector

    init(
        registryID: String,
        candidate:
            ARDOpenAPICandidate,
        underlying:
            OpenAPIReflector
    ) {
        self.registryID =
            registryID

        self.candidate =
            candidate

        self.underlying =
            underlying

        self.id =
            "ard.openapi."
            + registryID
            + "."
            + underlying.id
    }

    var completionWaitSeconds:
        TimeInterval
    {
        underlying
            .completionWaitSeconds
    }

    func capabilities(
        for item: ContentItem
    ) throws -> [Capability] {
        try underlying
            .capabilities(
                for:
                    item
            )
            .map {
                capability in

                var capability =
                    capability

                let underlyingID =
                    capability.id

                capability.id =
                    "ard:"
                    + registryID
                    + ":"
                    + underlyingID

                capability.metadata[
                    "ardUnderlyingCapabilityID"
                ] =
                    underlyingID

                capability.metadata[
                    "acquiredVia"
                ] =
                    "ard"

                capability.metadata[
                    "ardRegistryID"
                ] =
                    registryID

                capability.metadata[
                    "ardIdentifier"
                ] =
                    candidate.identifier

                capability.metadata[
                    "ardMediaType"
                ] =
                    candidate.mediaType

                return capability
            }
    }

    func providers()
        -> [ProviderSummary]
    {
        underlying
            .providers()
            .map {
                provider in

                var provider =
                    provider

                provider.source =
                    "ard/openapi"

                return provider
            }
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws -> ExecutionRecord {
        try underlying.begin(
            capability:
                underlyingCapability(
                    capability
                ),
            item:
                item,
            executionID:
                executionID
        )
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments:
            CapabilityArguments?
    ) throws -> ExecutionRecord {
        try underlying.begin(
            capability:
                underlyingCapability(
                    capability
                ),
            item:
                item,
            executionID:
                executionID,
            arguments:
                arguments
        )
    }

    private func underlyingCapability(
        _ capability: Capability
    ) -> Capability {
        guard
            let underlyingID =
                capability.metadata[
                    "ardUnderlyingCapabilityID"
                ]
        else {
            return capability
        }

        var result =
            capability

        result.id =
            underlyingID

        result.reflectorID =
            underlying.id

        return result
    }
}
#endif
