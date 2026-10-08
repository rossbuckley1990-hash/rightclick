#if os(macOS)
import Foundation

public struct BonjourGraphQLServiceDescriptor:
    Equatable,
    Sendable
{
    public var instanceName: String
    public var serviceType: String
    public var domain: String
    public var host: String
    public var port: Int
    public var txt: [String: String]

    public init(
        instanceName: String,
        serviceType: String,
        domain: String,
        host: String,
        port: Int,
        txt: [String: String]
    ) {
        self.instanceName =
            instanceName

        self.serviceType =
            serviceType

        self.domain =
            domain

        self.host =
            host

        self.port =
            port

        self.txt =
            txt
    }
}

public final class BonjourGraphQLSource:
    NSObject,
    CapabilityReflectorSource
{
    public let id =
        "bonjour.graphql"

    public static let serviceType =
        "_rightclick._tcp."

    public typealias SchemaLoader =
        (URL) throws -> Data

    public typealias IntrospectionLoader =
        (
            URL,
            String?
        ) throws -> Data

    private struct ServiceKey:
        Hashable
    {
        let instanceName: String
        let serviceType: String
        let domain: String
    }

    private struct Material {
        let endpointURL: URL
        let schemaURL: URL?
        let externalBearerSchemeName:
            String?
    }

    private let lock =
        NSLock()

    private let schemaLoader:
        SchemaLoader

    private let introspectionLoader:
        IntrospectionLoader

    private var currentReflectors:
        [ServiceKey: GraphQLReflector] = [:]

    private var discoveredServices:
        [ServiceKey: NetService] = [:]

    private var browser:
        NetServiceBrowser?

    private let acquisitionQueue =
        DispatchQueue(
            label:
                "rightclick.bonjour-graphql.acquire",
            qos:
                .utility
        )

    public convenience init(
        startBrowsing: Bool = true
    ) {
        self.init(
            startBrowsing:
                startBrowsing,
            schemaLoader: {
                try OriginPinnedHTTP
                    .loadOpenAPISpecification(
                        $0
                    )
            },
            introspectionLoader: {
                endpoint,
                bearerToken in

                try GraphQLIntrospection
                    .load(
                        endpointURL:
                            endpoint,
                        bearerToken:
                            bearerToken
                    )
            }
        )
    }

    public init(
        startBrowsing: Bool = true,
        schemaLoader:
            @escaping SchemaLoader,
        introspectionLoader:
            @escaping IntrospectionLoader
    ) {
        self.schemaLoader =
            schemaLoader

        self.introspectionLoader =
            introspectionLoader

        super.init()

        if startBrowsing {
            start()
        }
    }

    deinit {
        browser?.stop()

        lock.lock()

        let services =
            Array(
                discoveredServices.values
            )

        discoveredServices
            .removeAll()

        currentReflectors
            .removeAll()

        lock.unlock()

        for service in services {
            service.stop()
        }
    }

    public func reflectors()
        -> [any CapabilityReflector]
    {
        lock.lock()

        let snapshot =
            Array(
                currentReflectors.values
            )

        lock.unlock()

        return snapshot.sorted {
            $0.id < $1.id
        }
    }

    public func update(
        resolved descriptor:
            BonjourGraphQLServiceDescriptor
    ) {
        let key =
            serviceKey(
                descriptor
            )

        guard
            let material =
                validatedMaterial(
                    descriptor
                )
        else {
            removeReflector(
                for:
                    key
            )

            return
        }

        do {
            let schemaData:
                Data

            if let schemaURL =
                material.schemaURL
            {
                schemaData =
                    try schemaLoader(
                        schemaURL
                    )
            } else {
                let bearerToken:
                    String?

                if
                    let scheme =
                        material
                            .externalBearerSchemeName
                {
                    let origin =
                        try GraphQLHTTP
                            .canonicalOrigin(
                                material
                                    .endpointURL
                            )

                    guard
                        let token =
                            GraphQLHTTP
                                .bearerToken(
                                    origin:
                                        origin,
                                    schemeName:
                                        scheme
                                )
                    else {
                        removeReflector(
                            for:
                                key
                        )

                        return
                    }

                    bearerToken =
                        token
                } else {
                    bearerToken =
                        nil
                }

                schemaData =
                    try introspectionLoader(
                        material.endpointURL,
                        bearerToken
                    )
            }

            let reflector =
                try GraphQLReflector(
                    schemaData:
                        schemaData,
                    endpointURL:
                        material.endpointURL,
                    providerName:
                        descriptor
                            .instanceName,
                    externalBearerSchemeName:
                        material
                            .externalBearerSchemeName
                )

            lock.lock()

            currentReflectors[
                key
            ] =
                reflector

            lock.unlock()
        } catch {
            // Bonjour metadata, remote schema documents and introspection
            // responses are untrusted. Invalid providers contribute no
            // capabilities.
            removeReflector(
                for:
                    key
            )
        }
    }

    public func remove(
        instanceName: String,
        serviceType: String,
        domain: String
    ) {
        let key =
            ServiceKey(
                instanceName:
                    instanceName,
                serviceType:
                    serviceType,
                domain:
                    domain
            )

        lock.lock()

        currentReflectors
            .removeValue(
                forKey:
                    key
            )

        let service =
            discoveredServices
                .removeValue(
                    forKey:
                        key
                )

        lock.unlock()

        service?.stop()
    }

    private func start() {
        let startBrowser = {
            let browser =
                NetServiceBrowser()

            browser.delegate =
                self

            self.browser =
                browser

            browser
                .searchForServices(
                    ofType:
                        Self.serviceType,
                    inDomain:
                        "local."
                )
        }

        if Thread.isMainThread {
            startBrowser()
        } else {
            DispatchQueue
                .main
                .sync(
                    execute:
                        startBrowser
                )
        }
    }

    private func serviceKey(
        _ descriptor:
            BonjourGraphQLServiceDescriptor
    ) -> ServiceKey {
        ServiceKey(
            instanceName:
                descriptor
                    .instanceName,
            serviceType:
                descriptor
                    .serviceType,
            domain:
                descriptor
                    .domain
        )
    }

    private func serviceKey(
        _ service:
            NetService
    ) -> ServiceKey {
        ServiceKey(
            instanceName:
                service.name,
            serviceType:
                service.type,
            domain:
                service.domain
        )
    }

    private func removeReflector(
        for key:
            ServiceKey
    ) {
        lock.lock()

        currentReflectors
            .removeValue(
                forKey:
                    key
            )

        lock.unlock()
    }

    private func validatedMaterial(
        _ descriptor:
            BonjourGraphQLServiceDescriptor
    ) -> Material? {
        guard
            descriptor.serviceType
                == Self.serviceType
        else {
            return nil
        }

        guard
            descriptor.txt[
                "kind"
            ]?
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )
            .lowercased()
                == "graphql"
        else {
            return nil
        }

        let authorityScheme:
            String?

        if descriptor
            .txt
            .keys
            .contains(
                "auth-scheme"
            )
        {
            guard
                let value =
                    GraphQLHTTP
                        .validatedAuthoritySchemeName(
                            descriptor
                                .txt[
                                    "auth-scheme"
                                ]
                        )
            else {
                return nil
            }

            authorityScheme =
                value
        } else {
            authorityScheme =
                nil
        }

        let hasAbsoluteAdvertisement =
            descriptor.txt[
                "endpoint-url"
            ] != nil
            || descriptor.txt[
                "schema-url"
            ] != nil

        let hasLegacyAdvertisement =
            descriptor.txt[
                "scheme"
            ] != nil
            || descriptor.txt[
                "endpoint"
            ] != nil
            || descriptor.txt[
                "schema"
            ] != nil

        if hasAbsoluteAdvertisement {
            guard
                !hasLegacyAdvertisement,
                let endpoint =
                    validatedAbsoluteHTTPSURL(
                        descriptor
                            .txt[
                                "endpoint-url"
                            ]
                    )
            else {
                return nil
            }

            let schemaURL:
                URL?

            if descriptor.txt[
                "schema-url"
            ] != nil
            {
                guard
                    let validated =
                        validatedAbsoluteHTTPSURL(
                            descriptor
                                .txt[
                                    "schema-url"
                                ]
                        )
                else {
                    return nil
                }

                schemaURL =
                    validated
            } else {
                schemaURL =
                    nil
            }

            return Material(
                endpointURL:
                    endpoint,
                schemaURL:
                    schemaURL,
                externalBearerSchemeName:
                    authorityScheme
            )
        }

        let rawHost =
            descriptor.host
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        var host =
            rawHost

        if host.hasSuffix(".") {
            host.removeLast()
        }

        guard
            !host.isEmpty,
            !host.hasSuffix("."),
            (1...65_535)
                .contains(
                    descriptor.port
                ),
            let rawScheme =
                descriptor
                    .txt[
                        "scheme"
                    ]?
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .lowercased(),
            rawScheme == "http"
                || rawScheme == "https",
            let endpointPath =
                validatedAdvertisedPath(
                    descriptor
                        .txt[
                            "endpoint"
                        ]
                ),
            let endpoint =
                endpointURL(
                    scheme:
                        rawScheme,
                    host:
                        host,
                    port:
                        descriptor.port,
                    path:
                        endpointPath
                )
        else {
            return nil
        }

        let schemaURL:
            URL?

        if descriptor.txt[
            "schema"
        ] != nil
        {
            guard
                let schemaPath =
                    validatedAdvertisedPath(
                        descriptor
                            .txt[
                                "schema"
                            ]
                    ),
                let resolved =
                    endpointURL(
                        scheme:
                            rawScheme,
                        host:
                            host,
                        port:
                            descriptor.port,
                        path:
                            schemaPath
                    )
            else {
                return nil
            }

            schemaURL =
                resolved
        } else {
            schemaURL =
                nil
        }

        return Material(
            endpointURL:
                endpoint,
            schemaURL:
                schemaURL,
            externalBearerSchemeName:
                authorityScheme
        )
    }

    private func validatedAbsoluteHTTPSURL(
        _ raw: String?
    ) -> URL? {
        guard
            let raw
        else {
            return nil
        }

        let value =
            raw.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard
            !value.isEmpty,
            var components =
                URLComponents(
                    string:
                        value
                ),
            components.scheme?
                .lowercased()
                == "https",
            let rawHost =
                components.host,
            !rawHost.isEmpty,
            components.user == nil,
            components.password == nil,
            components.fragment == nil
        else {
            return nil
        }

        components.scheme =
            "https"

        components.host =
            rawHost.lowercased()

        if components.port == 443 {
            components.port =
                nil
        }

        return components.url
    }

    private func validatedAdvertisedPath(
        _ raw: String?
    ) -> String? {
        guard
            let raw
        else {
            return nil
        }

        let value =
            raw.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard
            value.hasPrefix("/"),
            !value.hasPrefix("//"),
            !value.contains("://"),
            !value.contains("#"),
            !value.contains("?"),
            !value.contains("\\")
        else {
            return nil
        }

        let pathComponents =
            value.split(
                separator: "/",
                omittingEmptySubsequences:
                    true
            )

        guard
            !pathComponents.contains("."),
            !pathComponents.contains("..")
        else {
            return nil
        }

        return value
    }

    private func endpointURL(
        scheme: String,
        host: String,
        port: Int,
        path: String
    ) -> URL? {
        var components =
            URLComponents()

        components.scheme =
            scheme

        components.host =
            host

        components.port =
            port

        components.path =
            path

        components.query =
            nil

        components.fragment =
            nil

        return components.url
    }

    private func descriptor(
        from service:
            NetService,
        txtData: Data? = nil
    ) -> BonjourGraphQLServiceDescriptor? {
        guard
            let rawHost =
                service.hostName
        else {
            return nil
        }

        let host =
            rawHost.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard
            !host.isEmpty
        else {
            return nil
        }

        let data =
            txtData
            ?? service
                .txtRecordData()

        let txt =
            Self.decodeTXT(
                data
            )

        return BonjourGraphQLServiceDescriptor(
            instanceName:
                service.name,
            serviceType:
                service.type,
            domain:
                service.domain,
            host:
                host,
            port:
                service.port,
            txt:
                txt
        )
    }

    private static func decodeTXT(
        _ data: Data?
    ) -> [String: String] {
        guard
            let data
        else {
            return [:]
        }

        let dictionary =
            NetService
                .dictionary(
                    fromTXTRecord:
                        data
                )

        var result:
            [String: String] = [:]

        for (
            rawKey,
            rawValue
        ) in dictionary
        {
            let key =
                rawKey
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
                    .lowercased()

            guard
                !key.isEmpty,
                let value =
                    String(
                        data:
                            rawValue,
                        encoding:
                            .utf8
                    )
            else {
                continue
            }

            result[
                key
            ] =
                value
        }

        return result
    }

    private func acquire(
        _ descriptor:
            BonjourGraphQLServiceDescriptor
    ) {
        acquisitionQueue
            .async {
                [weak self]
                in

                self?
                    .update(
                        resolved:
                            descriptor
                    )
            }
    }
}

extension BonjourGraphQLSource:
    NetServiceBrowserDelegate
{
    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard
            service.type
                == Self.serviceType
        else {
            return
        }

        let key =
            serviceKey(
                service
            )

        lock.lock()

        discoveredServices[
            key
        ] =
            service

        lock.unlock()

        service.delegate =
            self

        service
            .startMonitoring()

        service.resolve(
            withTimeout:
                5
        )
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        remove(
            instanceName:
                service.name,
            serviceType:
                service.type,
            domain:
                service.domain
        )
    }
}

extension BonjourGraphQLSource:
    NetServiceDelegate
{
    public func netServiceDidResolveAddress(
        _ sender: NetService
    ) {
        guard
            let descriptor =
                descriptor(
                    from:
                        sender
                )
        else {
            removeReflector(
                for:
                    serviceKey(
                        sender
                    )
            )

            return
        }

        acquire(
            descriptor
        )
    }

    public func netService(
        _ sender: NetService,
        didUpdateTXTRecord data: Data
    ) {
        guard
            let descriptor =
                descriptor(
                    from:
                        sender,
                    txtData:
                        data
                )
        else {
            return
        }

        acquire(
            descriptor
        )
    }

    public func netService(
        _ sender: NetService,
        didNotResolve errorDict:
            [String: NSNumber]
    ) {
        removeReflector(
            for:
                serviceKey(
                    sender
                )
        )
    }
}

#endif
