import RightClickProtocol
import Foundation

public struct BonjourOpenAPIServiceDescriptor:
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
        self.instanceName = instanceName
        self.serviceType = serviceType
        self.domain = domain
        self.host = host
        self.port = port
        self.txt = txt
    }
}

/// Portable descriptor acquisition. Native discovery adapters supply descriptors;
/// compilation, contract refresh and withdrawal share this implementation.
public final class OpenAPIServiceDescriptorSource: CapabilityReflectorSource {
    public let id = "bonjour.openapi"
    public static let serviceType = "_rightclick._tcp."
    public typealias SpecificationLoader = (URL) throws -> Data
    private struct ServiceKey: Hashable {
        let instanceName: String
        let serviceType: String
        let domain: String
    }
    private let lock = NSLock()
    private let specificationLoader: SpecificationLoader
    private var currentReflectors: [ServiceKey: OpenAPIReflector] = [:]
    private var acquisitionTokens: [ServiceKey: UUID] = [:]

    /// `startBrowsing` is retained for source compatibility on portable hosts.
    /// Browsing itself belongs to the macOS adapter.
    public convenience init(startBrowsing: Bool = false) {
        self.init(startBrowsing: startBrowsing, specificationLoader: {
            try OriginPinnedHTTP.loadOpenAPISpecification($0)
        })
    }
    public init(startBrowsing: Bool = false, specificationLoader: @escaping SpecificationLoader) {
        self.specificationLoader = specificationLoader
    }
    public func reflectors()
        -> [any CapabilityReflector]
    {
        lock.lock()
        let compiled = currentReflectors
        lock.unlock()
        for (key, old) in compiled where old.requiresContractRefresh {
            guard let refreshed = try? old.refreshContract() as? OpenAPIReflector else { continue }
            lock.lock()
            // A delayed refresh must never resurrect a removed/replaced service.
            if currentReflectors[key] === old { currentReflectors[key] = refreshed }
            lock.unlock()
        }
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


    public func update(resolved descriptor: BonjourOpenAPIServiceDescriptor) {
        let token = beginAcquisition(descriptor)
        completeAcquisition(descriptor, token: token)
    }
    // Capture before native work is queued. Removal/replacement revokes the token.
    package func beginAcquisition(_ descriptor: BonjourOpenAPIServiceDescriptor) -> UUID {
        let key = serviceKey(descriptor)
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        acquisitionTokens[key] = token
        currentReflectors.removeValue(forKey: key)
        return token
    }
    package func completeAcquisition(_ descriptor: BonjourOpenAPIServiceDescriptor, token: UUID) {
        update(descriptor, key: serviceKey(descriptor), token: token)
    }
    private func update(_ descriptor: BonjourOpenAPIServiceDescriptor, key: ServiceKey, token: UUID) {
        lock.lock(); let current = acquisitionTokens[key] == token; lock.unlock()
        guard current else { return }
        var reflected: OpenAPIReflector?
        if let material = validatedMaterial(descriptor) {
            do {
                let specification = try specificationLoader(material.specificationURL)
                reflected = try OpenAPIReflector(specificationData: specification,
                    baseURL: material.baseURL, externalBearerSchemeName: material.externalBearerSchemeName,
                    revalidateSpecification: { [loader = specificationLoader] in
                        try loader(material.specificationURL)
                    }, acquisitionIncarnation: token)
            } catch {
                // Untrusted/unavailable input contributes no capability. An old
                // failed read must not remove a newer successful acquisition.
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard acquisitionTokens[key] == token else { return }
        currentReflectors[key] = reflected
    }


    public func remove(instanceName: String, serviceType: String, domain: String) {
        let key = ServiceKey(instanceName: instanceName, serviceType: serviceType, domain: domain)
        lock.lock(); defer { lock.unlock() }
        acquisitionTokens.removeValue(forKey: key)
        currentReflectors.removeValue(forKey: key)
    }
    private func serviceKey(
        _ descriptor:
            BonjourOpenAPIServiceDescriptor
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

    private func validatedMaterial(
        _ descriptor:
            BonjourOpenAPIServiceDescriptor
    ) -> (
        specificationURL: URL,
        baseURL: URL,
        externalBearerSchemeName: String?
    )? {
        guard
            descriptor.serviceType
                == Self.serviceType
        else {
            return nil
        }

        guard
            descriptor.txt["kind"]?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .lowercased()
                == "openapi"
        else {
            return nil
        }

        let externalBearerSchemeName:
            String?

        if descriptor.txt.keys.contains(
            "auth-scheme"
        ) {
            guard
                let value =
                    validatedAuthoritySchemeName(
                        descriptor.txt[
                            "auth-scheme"
                        ]
                    )
            else {
                return nil
            }

            externalBearerSchemeName =
                value

        } else {
            externalBearerSchemeName =
                nil
        }

        let hasAbsoluteAdvertisement =
            descriptor.txt["spec-url"] != nil
            || descriptor.txt["base-url"] != nil

        let hasLegacyAdvertisement =
            descriptor.txt["scheme"] != nil
            || descriptor.txt["spec"] != nil
            || descriptor.txt["base"] != nil

        if hasAbsoluteAdvertisement {
            guard
                !hasLegacyAdvertisement,
                let specificationURL =
                    validatedAbsoluteHTTPSURL(
                        descriptor.txt[
                            "spec-url"
                        ]
                    ),
                let baseURL =
                    validatedAbsoluteHTTPSURL(
                        descriptor.txt[
                            "base-url"
                        ]
                    )
            else {
                return nil
            }

            return (
                specificationURL,
                baseURL,
                externalBearerSchemeName
            )
        }

        let rawHost =
            descriptor.host
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        var host = rawHost

        if host.hasSuffix(".") {
            host.removeLast()
        }

        guard
            !host.isEmpty,
            !host.hasSuffix(".")
        else {
            return nil
        }

        guard
            (1...65_535).contains(
                descriptor.port
            )
        else {
            return nil
        }

        guard
            let rawScheme =
                descriptor.txt["scheme"]?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .lowercased(),
            rawScheme == "http"
                || rawScheme == "https"
        else {
            return nil
        }

        guard
            let specificationPath =
                validatedAdvertisedPath(
                    descriptor.txt["spec"]
                ),
            let basePath =
                validatedAdvertisedPath(
                    descriptor.txt["base"]
                )
        else {
            return nil
        }

        guard
            let specificationURL =
                endpointURL(
                    scheme:
                        rawScheme,
                    host:
                        host,
                    port:
                        descriptor.port,
                    path:
                        specificationPath
                ),
            let baseURL =
                endpointURL(
                    scheme:
                        rawScheme,
                    host:
                        host,
                    port:
                        descriptor.port,
                    path:
                        basePath
                )
        else {
            return nil
        }

        return (
            specificationURL,
            baseURL,
            externalBearerSchemeName
        )
    }

    private func validatedAuthoritySchemeName(
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
            !value.isEmpty,
            !value.contains("|"),
            value.rangeOfCharacter(
                from:
                    .controlCharacters
            ) == nil
        else {
            return nil
        }

        return value
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
            value
            .split(
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

        components.query = nil
        components.fragment = nil

        return components.url
    }

}
