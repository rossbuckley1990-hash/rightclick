import RightClickProviders
import RightClickProtocol
import Foundation

/// Native Bonjour discovery only. Portable descriptor validation and compilation
/// live in Providers and use the same withdrawal tokens on every host.
public final class BonjourOpenAPISource: NSObject, CapabilityReflectorSource {
    public let id = "bonjour.openapi"
    public static let serviceType = OpenAPIServiceDescriptorSource.serviceType
    public typealias SpecificationLoader = OpenAPIServiceDescriptorSource.SpecificationLoader
    private struct ServiceKey: Hashable {
        let instanceName: String
        let serviceType: String
        let domain: String
    }
    private let acquisition: OpenAPIServiceDescriptorSource
    private let lock = NSLock()
    private var discoveredServices: [ServiceKey: NetService] = [:]
    private var browser: NetServiceBrowser?
    private let acquisitionQueue = DispatchQueue(label: "rightclick.bonjour-openapi.acquire", qos: .utility)
    public convenience init(startBrowsing: Bool = true) {
        self.init(startBrowsing: startBrowsing, specificationLoader: {
            try OriginPinnedHTTP.loadOpenAPISpecification($0)
        })
    }
    public init(startBrowsing: Bool = true, specificationLoader: @escaping SpecificationLoader) {
        acquisition = OpenAPIServiceDescriptorSource(specificationLoader: specificationLoader)
        super.init()
        if startBrowsing { start() }
    }
    deinit {
        browser?.stop()
        lock.lock()
        let services = Array(discoveredServices.values)
        discoveredServices.removeAll()
        lock.unlock()
        for service in services { service.stop() }
    }
    public func reflectors() -> [any CapabilityReflector] { acquisition.reflectors() }
    public func update(resolved descriptor: BonjourOpenAPIServiceDescriptor) { acquisition.update(resolved: descriptor) }
    public func remove(instanceName: String, serviceType: String, domain: String) {
        remove(for: ServiceKey(instanceName: instanceName, serviceType: serviceType, domain: domain))
    }
    private func invalidate(_ key: ServiceKey) {
        acquisition.remove(instanceName: key.instanceName, serviceType: key.serviceType, domain: key.domain)
    }
    private func remove(for key: ServiceKey, requiring expected: NetService? = nil) {
        lock.lock()
        if let expected, discoveredServices[key] !== expected { lock.unlock(); return }
        invalidate(key)
        let service = discoveredServices.removeValue(forKey: key)
        lock.unlock()
        service?.stop()
    }
    private func removeReflector(for key: ServiceKey, requiring service: NetService? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let service, discoveredServices[key] !== service { return }
        invalidate(key)
    }
    private func start() {
        let startBrowser = {
            let browser =
                NetServiceBrowser()

            browser.delegate = self

            self.browser = browser

            browser.searchForServices(
                ofType:
                    Self.serviceType,
                inDomain:
                    "local."
            )
        }

        if Thread.isMainThread {
            startBrowser()
        } else {
            DispatchQueue.main.sync(
                execute: startBrowser
            )
        }
    }

    private func serviceKey(
        _ service: NetService
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

    private func descriptor(
        from service: NetService,
        txtData: Data? = nil
    ) -> BonjourOpenAPIServiceDescriptor? {
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

        guard !host.isEmpty else {
            return nil
        }

        let data =
            txtData
            ?? service.txtRecordData()

        let txt =
            Self.decodeTXT(
                data
            )

        return BonjourOpenAPIServiceDescriptor(
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
            NetService.dictionary(
                fromTXTRecord:
                    data
            )

        var result:
            [String: String] = [:]

        for (rawKey, rawValue)
            in dictionary
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

            result[key] =
                value
        }

        return result
    }


    private func acquire(_ descriptor: BonjourOpenAPIServiceDescriptor, from service: NetService) {
        let key = serviceKey(service)
        lock.lock()
        guard discoveredServices[key] === service else { lock.unlock(); return }
        let token = acquisition.beginAcquisition(descriptor)
        lock.unlock()
        acquisitionQueue.async { [weak self] in
            self?.acquisition.completeAcquisition(descriptor, token: token)
        }
    }
}

extension BonjourOpenAPISource:
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

        if discoveredServices[key] !== service {
            invalidate(key)
        }
        discoveredServices[key] = service

        lock.unlock()

        service.delegate = self
        service.startMonitoring()

        service.resolve(
            withTimeout: 5
        )
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        remove(for: serviceKey(service), requiring: service)
    }
}

extension BonjourOpenAPISource:
    NetServiceDelegate
{
    public func netServiceDidResolveAddress(
        _ sender: NetService
    ) {
        guard
            let descriptor =
                descriptor(
                    from: sender
                )
        else {
            removeReflector(
                for:
                    serviceKey(sender), requiring: sender
            )

            return
        }

        acquire(descriptor, from: sender)
    }

    public func netService(
        _ sender: NetService,
        didUpdateTXTRecord data: Data
    ) {
        guard
            let descriptor =
                descriptor(
                    from: sender,
                    txtData:
                        data
                )
        else {
            return
        }

        acquire(descriptor, from: sender)
    }

    public func netService(
        _ sender: NetService,
        didNotResolve errorDict:
            [String: NSNumber]
    ) {
        removeReflector(
            for:
                serviceKey(sender), requiring: sender
        )
    }
}
