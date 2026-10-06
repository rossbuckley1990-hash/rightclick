#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
import Foundation

public struct BonjourGRPCServiceDescriptor:
    Equatable,
    Sendable
{
    public let instanceName:
        String

    public let serviceType:
        String

    public let domain:
        String

    public let host:
        String

    public let port:
        Int

    public let txt:
        [String: String]

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

public final class BonjourGRPCSource:
    NSObject,
    CapabilityReflectorSource
{
    public let id =
        "bonjour.grpc"

    public static let serviceType =
        "_rightclick._tcp."

    public typealias ReflectionLoader =
        (GRPCEndpoint) throws -> [Data]

    public typealias UnaryInvoker =
        GRPCReflector.UnaryInvoker

    private struct ServiceKey:
        Hashable
    {
        let instanceName:
            String

        let serviceType:
            String

        let domain:
            String
    }

    private struct Material {
        let endpoint:
            GRPCEndpoint

        let providerName:
            String
    }

    private let reflectionLoader:
        ReflectionLoader

    private let unaryInvoker:
        UnaryInvoker

    private let lock =
        NSLock()

    private var currentReflectors:
        [ServiceKey: GRPCReflector] = [:]

    private var discoveredServices:
        [ServiceKey: NetService] = [:]

    private var browser:
        NetServiceBrowser?

    private let acquisitionQueue =
        DispatchQueue(
            label:
                "rightclick.bonjour-grpc.acquire",
            qos:
                .utility
        )

    public convenience init(
        startBrowsing: Bool = true
    ) {
        self.init(
            startBrowsing:
                startBrowsing,
            reflectionLoader: {
                endpoint in

                try GRPCReflectionTransport
                    .discover(
                        endpoint:
                            endpoint
                    )
            },
            unaryInvoker: {
                endpoint,
                path,
                request in

                try GRPCReflectionTransport
                    .invokeUnary(
                        endpoint:
                            endpoint,
                        path:
                            path,
                        request:
                            request
                    )
            }
        )
    }

    public init(
        startBrowsing: Bool = true,
        reflectionLoader:
            @escaping ReflectionLoader,
        unaryInvoker:
            @escaping UnaryInvoker
    ) {
        self.reflectionLoader =
            reflectionLoader

        self.unaryInvoker =
            unaryInvoker

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
            BonjourGRPCServiceDescriptor
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
            let descriptors =
                try reflectionLoader(
                    material.endpoint
                )

            let reflector =
                try GRPCReflector(
                    descriptorData:
                        descriptors,
                    endpoint:
                        material.endpoint,
                    providerName:
                        material.providerName,
                    invoker:
                        unaryInvoker
                )

            lock.lock()

            currentReflectors[
                key
            ] =
                reflector

            lock.unlock()

        } catch {
            // DNS-SD metadata and reflected descriptor bytes are
            // untrusted. Failed reflection contributes no capability.
            removeReflector(
                for:
                    key
            )
        }
    }

    public func remove(
        instanceName: String,
        serviceType: String =
            BonjourGRPCSource
                .serviceType,
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

        let service =
            discoveredServices
                .removeValue(
                    forKey:
                        key
                )

        currentReflectors
            .removeValue(
                forKey:
                    key
            )

        lock.unlock()

        service?.stop()
    }

    public func start() {
        lock.lock()

        guard browser == nil else {
            lock.unlock()

            return
        }

        let browser =
            NetServiceBrowser()

        self.browser =
            browser

        lock.unlock()

        browser.delegate =
            self

        browser.searchForServices(
            ofType:
                Self.serviceType,
            inDomain:
                "local."
        )
    }

    private func serviceKey(
        _ descriptor:
            BonjourGRPCServiceDescriptor
    ) -> ServiceKey {
        ServiceKey(
            instanceName:
                descriptor.instanceName,
            serviceType:
                descriptor.serviceType,
            domain:
                descriptor.domain
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
            BonjourGRPCServiceDescriptor
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
                == "grpc"
        else {
            return nil
        }

        // gRPC metadata authority is intentionally a separate gate.
        // Until that gate exists, an auth advertisement must fail
        // closed rather than silently running unauthenticated.
        guard
            descriptor.txt[
                "auth-scheme"
            ] == nil
        else {
            return nil
        }

        guard
            let rawScheme =
                descriptor.txt[
                    "scheme"
                ]?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .lowercased(),
            rawScheme == "grpc"
                || rawScheme == "grpcs"
        else {
            return nil
        }

        let rawHost =
            descriptor.host
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard
            !rawHost.isEmpty,
            let endpoint =
                try? GRPCEndpoint(
                    scheme:
                        rawScheme,
                    host:
                        rawHost,
                    port:
                        descriptor.port
                )
        else {
            return nil
        }

        let rawName =
            descriptor.instanceName
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        let providerName =
            rawName.isEmpty
            ? "gRPC "
                + endpoint.host
                + ":"
                + String(
                    endpoint.port
                )
            : rawName

        return Material(
            endpoint:
                endpoint,
            providerName:
                providerName
        )
    }

    private func descriptor(
        from service:
            NetService,
        txtData: Data? = nil
    ) -> BonjourGRPCServiceDescriptor? {
        guard
            let rawHost =
                service.hostName
        else {
            return nil
        }

        let host =
            rawHost
                .trimmingCharacters(
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

        return BonjourGRPCServiceDescriptor(
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
                Self.decodeTXT(
                    data
                )
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
            BonjourGRPCServiceDescriptor
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

extension BonjourGRPCSource:
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

        service.startMonitoring()

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

extension BonjourGRPCSource:
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
