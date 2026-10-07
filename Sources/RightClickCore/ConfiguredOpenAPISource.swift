import Foundation

public struct ConfiguredOpenAPIProviderDescriptor:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let kind: String
    public let specificationURL: String
    public let baseURL: String
    public let authorityScheme: String?

    public init(
        id: String,
        specificationURL: String,
        baseURL: String,
        authorityScheme: String? = nil
    ) {
        self.id =
            id

        self.kind =
            "openapi"

        self.specificationURL =
            specificationURL

        self.baseURL =
            baseURL

        self.authorityScheme =
            authorityScheme
    }
}

public enum ConfiguredOpenAPIProviderStoreError:
    LocalizedError
{
    case configurationTooLarge
    case unsafeConfigurationFile
    case invalidRoot
    case invalidSchemaVersion
    case invalidProviders
    case invalidProvider(String)
    case duplicateProviderID(String)

    public var errorDescription:
        String?
    {
        switch self {
        case .configurationTooLarge:
            return
                "Configured provider registry exceeds the 1 MiB limit."

        case .unsafeConfigurationFile:
            return
                "Configured provider registry must be a regular non-symlink file."

        case .invalidRoot:
            return
                "Configured provider registry must be one closed JSON object."

        case .invalidSchemaVersion:
            return
                "Configured provider registry has an unsupported schemaVersion."

        case .invalidProviders:
            return
                "Configured provider registry providers must be a JSON array."

        case let .invalidProvider(reason):
            return
                "Configured provider is invalid: "
                + reason

        case let .duplicateProviderID(id):
            return
                "Configured provider id is duplicated: "
                + id
        }
    }
}

public enum ConfiguredOpenAPIProviderStore {
    public static let schemaVersion =
        1

    public static let maximumConfigurationBytes =
        1_048_576

    public static func defaultFile(
        home:
            URL =
            FileManager.default
                .homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(
                "Library/Application Support/RIGHTCLICK",
                isDirectory:
                    true
            )
            .appendingPathComponent(
                "providers.json",
                isDirectory:
                    false
            )
    }

    public static func read(
        from file:
            URL =
            defaultFile()
    ) throws
        -> [ConfiguredOpenAPIProviderDescriptor]
    {
        guard
            let data =
                try dataIfPresent(
                    at:
                        file
                )
        else {
            return []
        }

        return try decode(
            data
        )
    }

    public static func decode(
        _ data: Data
    ) throws
        -> [ConfiguredOpenAPIProviderDescriptor]
    {
        guard
            data.count
                <= maximumConfigurationBytes
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .configurationTooLarge
        }

        let raw:
            Any

        do {
            raw =
                try JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
        } catch {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidRoot
        }

        guard
            let root =
                raw
                    as? [String: Any],
            Set(
                root.keys
            ) ==
                Set([
                    "schemaVersion",
                    "providers",
                ])
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidRoot
        }

        guard
            let version =
                root[
                    "schemaVersion"
                ] as? Int,
            version
                == schemaVersion
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidSchemaVersion
        }

        guard
            let rows =
                root[
                    "providers"
                ] as? [Any],
            rows.count <= 64
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidProviders
        }

        var providers:
            [ConfiguredOpenAPIProviderDescriptor] = []

        var ids =
            Set<String>()

        for rawRow
            in rows
        {
            guard
                let row =
                    rawRow
                        as? [String: Any]
            else {
                throw ConfiguredOpenAPIProviderStoreError
                    .invalidProvider(
                        "provider row is not an object"
                    )
            }

            let allowedKeys:
                Set<String> = [
                    "id",
                    "kind",
                    "specificationURL",
                    "baseURL",
                    "authorityScheme",
                ]

            guard
                Set(
                    row.keys
                )
                .isSubset(
                    of:
                        allowedKeys
                ),
                Set([
                    "id",
                    "kind",
                    "specificationURL",
                    "baseURL",
                ])
                .isSubset(
                    of:
                        Set(
                            row.keys
                        )
                )
            else {
                throw ConfiguredOpenAPIProviderStoreError
                    .invalidProvider(
                        "provider object contains missing or unknown fields"
                    )
            }

            guard
                let id =
                    row["id"]
                        as? String,
                let kind =
                    row["kind"]
                        as? String,
                kind == "openapi",
                let specificationURL =
                    row[
                        "specificationURL"
                    ] as? String,
                let baseURL =
                    row[
                        "baseURL"
                    ] as? String
            else {
                throw ConfiguredOpenAPIProviderStoreError
                    .invalidProvider(
                        "id, kind, specificationURL and baseURL must be strings"
                    )
            }

            let authorityScheme:
                String?

            if row.keys.contains(
                "authorityScheme"
            ) {
                guard
                    let rawScheme =
                        row[
                            "authorityScheme"
                        ] as? String
                else {
                    throw ConfiguredOpenAPIProviderStoreError
                        .invalidProvider(
                            "authorityScheme must be a string when present"
                        )
                }

                authorityScheme =
                    rawScheme
            } else {
                authorityScheme =
                    nil
            }

            let provider =
                try canonicalized(
                    ConfiguredOpenAPIProviderDescriptor(
                        id:
                            id,
                        specificationURL:
                            specificationURL,
                        baseURL:
                            baseURL,
                        authorityScheme:
                            authorityScheme
                    )
                )

            guard
                ids.insert(
                    provider.id
                )
                .inserted
            else {
                throw ConfiguredOpenAPIProviderStoreError
                    .duplicateProviderID(
                        provider.id
                    )
            }

            providers.append(
                provider
            )
        }

        return providers.sorted {
            $0.id < $1.id
        }
    }

    @discardableResult
    public static func write(
        _ rawProviders:
            [ConfiguredOpenAPIProviderDescriptor],
        to file:
            URL =
            defaultFile()
    ) throws -> URL {
        var providers:
            [ConfiguredOpenAPIProviderDescriptor] = []

        var ids =
            Set<String>()

        for raw
            in rawProviders
        {
            let provider =
                try canonicalized(
                    raw
                )

            guard
                ids.insert(
                    provider.id
                )
                .inserted
            else {
                throw ConfiguredOpenAPIProviderStoreError
                    .duplicateProviderID(
                        provider.id
                    )
            }

            providers.append(
                provider
            )
        }

        providers.sort {
            $0.id < $1.id
        }

        let rows:
            [[String: Any]] =
                providers.map {
                    provider in

                    var row:
                        [String: Any] = [
                            "id":
                                provider.id,

                            "kind":
                                provider.kind,

                            "specificationURL":
                                provider
                                .specificationURL,

                            "baseURL":
                                provider
                                .baseURL,
                        ]

                    if let authorityScheme =
                        provider
                            .authorityScheme
                    {
                        row[
                            "authorityScheme"
                        ] =
                            authorityScheme
                    }

                    return row
                }

        let root:
            [String: Any] = [
                "schemaVersion":
                    schemaVersion,

                "providers":
                    rows,
            ]

        var data =
            try JSONSerialization
                .data(
                    withJSONObject:
                        root,
                    options: [
                        .prettyPrinted,
                        .sortedKeys,
                        .withoutEscapingSlashes,
                    ]
                )

        data.append(
            0x0A
        )

        guard
            data.count
                <= maximumConfigurationBytes
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .configurationTooLarge
        }

        let fileManager =
            FileManager.default

        if
            fileManager
                .fileExists(
                    atPath:
                        file.path
                )
        {
            let values =
                try file
                    .resourceValues(
                        forKeys: [
                            .isRegularFileKey,
                            .isSymbolicLinkKey,
                        ]
                    )

            guard
                values.isRegularFile
                    == true,
                values.isSymbolicLink
                    != true
            else {
                throw ConfiguredOpenAPIProviderStoreError
                    .unsafeConfigurationFile
            }
        }

        let directory =
            file
                .deletingLastPathComponent()

        try fileManager
            .createDirectory(
                at:
                    directory,
                withIntermediateDirectories:
                    true
            )

        try data.write(
            to:
                file,
            options:
                .atomic
        )

        try fileManager
            .setAttributes(
                [
                    .posixPermissions:
                        0o600
                ],
                ofItemAtPath:
                    file.path
            )

        return file
    }

    public static func upsert(
        _ rawProvider:
            ConfiguredOpenAPIProviderDescriptor,
        in file:
            URL =
            defaultFile()
    ) throws
        -> [ConfiguredOpenAPIProviderDescriptor]
    {
        let provider =
            try canonicalized(
                rawProvider
            )

        var providers =
            try read(
                from:
                    file
            )

        providers.removeAll {
            $0.id
                == provider.id
        }

        providers.append(
            provider
        )

        try write(
            providers,
            to:
                file
        )

        return try read(
            from:
                file
        )
    }

    @discardableResult
    public static func remove(
        id rawID: String,
        from file:
            URL =
            defaultFile()
    ) throws -> Bool {
        let id =
            try validatedProviderID(
                rawID
            )

        var providers =
            try read(
                from:
                    file
            )

        let originalCount =
            providers.count

        providers.removeAll {
            $0.id == id
        }

        guard
            providers.count
                != originalCount
        else {
            return false
        }

        try write(
            providers,
            to:
                file
        )

        return true
    }

    static func dataIfPresent(
        at file: URL
    ) throws -> Data? {
        let fileManager =
            FileManager.default

        guard
            fileManager
                .fileExists(
                    atPath:
                        file.path
                )
        else {
            return nil
        }

        let values =
            try file
                .resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ]
                )

        guard
            values.isRegularFile
                == true,
            values.isSymbolicLink
                != true
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .unsafeConfigurationFile
        }

        let data =
            try Data(
                contentsOf:
                    file
            )

        guard
            data.count
                <= maximumConfigurationBytes
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .configurationTooLarge
        }

        return data
    }

    private static func canonicalized(
        _ raw:
            ConfiguredOpenAPIProviderDescriptor
    ) throws
        -> ConfiguredOpenAPIProviderDescriptor
    {
        let id =
            try validatedProviderID(
                raw.id
            )

        guard
            raw.kind
                == "openapi"
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidProvider(
                    "kind must be openapi"
                )
        }

        let specificationURL =
            try validatedHTTPSURL(
                raw.specificationURL,
                field:
                    "specificationURL"
            )

        let baseURL =
            try validatedHTTPSURL(
                raw.baseURL,
                field:
                    "baseURL"
            )

        let authorityScheme =
            try validatedAuthorityScheme(
                raw.authorityScheme
            )

        return ConfiguredOpenAPIProviderDescriptor(
            id:
                id,
            specificationURL:
                specificationURL,
            baseURL:
                baseURL,
            authorityScheme:
                authorityScheme
        )
    }

    private static func validatedProviderID(
        _ raw: String
    ) throws -> String {
        guard
            !raw.isEmpty,
            raw.count <= 64,
            raw
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                == raw
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidProvider(
                    "id is empty, too long, or contains surrounding whitespace"
                )
        }

        let valid =
            raw.unicodeScalars
                .allSatisfy {
                    scalar in

                    let value =
                        scalar.value

                    return
                        (value >= 48
                            && value <= 57)
                        || (value >= 65
                            && value <= 90)
                        || (value >= 97
                            && value <= 122)
                        || value == 45
                        || value == 46
                        || value == 95
                }

        guard valid else {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidProvider(
                    "id may contain only A-Z, a-z, 0-9, dot, dash and underscore"
                )
        }

        return raw
    }

    private static func validatedHTTPSURL(
        _ raw: String,
        field: String
    ) throws -> String {
        guard
            !raw.isEmpty,
            raw
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                == raw,
            var components =
                URLComponents(
                    string:
                        raw
                ),
            components.scheme?
                .lowercased()
                == "https",
            let host =
                components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            components.query == nil
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidProvider(
                    "\(field) must be an absolute credential-free HTTPS URL without query or fragment"
                )
        }

        components.scheme =
            "https"

        components.host =
            host.lowercased()

        if components.port == 443 {
            components.port =
                nil
        }

        guard
            let url =
                components.url
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidProvider(
                    "\(field) could not be canonicalized"
                )
        }

        return url.absoluteString
    }

    private static func validatedAuthorityScheme(
        _ raw: String?
    ) throws -> String? {
        guard
            let raw
        else {
            return nil
        }

        guard
            !raw.isEmpty,
            raw.count <= 128,
            raw
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                == raw,
            !raw.contains("|"),
            raw
                .rangeOfCharacter(
                    from:
                        .controlCharacters
                )
                == nil
        else {
            throw ConfiguredOpenAPIProviderStoreError
                .invalidProvider(
                    "authorityScheme is invalid"
                )
        }

        return raw
    }
}

public final class ConfiguredOpenAPISource:
    CapabilityReflectorSource
{
    public let id =
        "configured.openapi"

    public typealias SpecificationLoader =
        (URL) throws -> Data

    private let configurationFile:
        URL

    private let specificationLoader:
        SpecificationLoader

    private let reloadLock =
        NSLock()

    private let clock: () -> TimeInterval
    private var freshness: CapabilitySnapshotFreshness

    private let stateLock =
        NSLock()

    private var didLoadConfiguration =
        false

    private var lastConfigurationData:
        Data?

    private var currentReflectors:
        [String: OpenAPIReflector] = [:]

    public convenience init(
        configurationFile:
            URL =
            ConfiguredOpenAPIProviderStore
                .defaultFile()
    ) {
        self.init(
            configurationFile:
                configurationFile,
            specificationLoader: {
                try OriginPinnedHTTP
                    .loadOpenAPISpecification(
                        $0
                    )
            }
        )
    }

    public init(
        configurationFile: URL,
        refreshInterval: TimeInterval = 5,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        specificationLoader:
            @escaping SpecificationLoader
    ) {
        self.configurationFile =
            configurationFile

        self.specificationLoader =
            specificationLoader

        self.clock = clock
        self.freshness = CapabilitySnapshotFreshness(lifetime: refreshInterval)
    }

    public func reflectors()
        -> [any CapabilityReflector]
    {
        reloadLock.lock()

        reloadIfNeeded()

        reloadLock.unlock()

        stateLock.lock()
        let compiled = currentReflectors
        stateLock.unlock()
        for (key, old) in compiled where old.requiresContractRefresh {
            // Keep an unavailable snapshot pending reacquisition; its mandatory
            // execution check denies dispatch. A later read can recover it.
            guard let refreshed = try? old.refreshContract() as? OpenAPIReflector else { continue }
            stateLock.lock()
            if currentReflectors[key] === old { currentReflectors[key] = refreshed }
            stateLock.unlock()
        }

        stateLock.lock()

        let snapshot =
            Array(
                currentReflectors.values
            )

        stateLock.unlock()

        return snapshot.sorted {
            $0.id < $1.id
        }
    }

    private func reloadIfNeeded() {
        let data:
            Data?

        do {
            data =
                try ConfiguredOpenAPIProviderStore
                    .dataIfPresent(
                        at:
                            configurationFile
                    )
        } catch {
            replaceState(
                reflectors:
                    [:],
                configurationData:
                    nil,
                didLoad:
                    false
            )

            return
        }

        stateLock.lock()

        let unchanged =
            didLoadConfiguration
            && lastConfigurationData
                == data
            && freshness.isFresh(at: clock())

        stateLock.unlock()

        if unchanged {
            return
        }

        guard
            let data
        else {
            replaceState(
                reflectors:
                    [:],
                configurationData:
                    nil,
                didLoad:
                    true
            )

            return
        }

        let providers:
            [ConfiguredOpenAPIProviderDescriptor]

        do {
            providers =
                try ConfiguredOpenAPIProviderStore
                    .decode(
                        data
                    )
        } catch {
            // Malformed provider state must remove previously visible
            // configured capabilities rather than leaving stale
            // authority-bearing reflectors alive.
            replaceState(
                reflectors:
                    [:],
                configurationData:
                    data,
                didLoad:
                    true
            )

            return
        }

        var next:
            [String: OpenAPIReflector] = [:]

        for provider
            in providers
        {
            guard
                let specificationURL =
                    URL(
                        string:
                            provider
                                .specificationURL
                    ),
                let baseURL =
                    URL(
                        string:
                            provider
                                .baseURL
                    )
            else {
                continue
            }

            do {
                let specification =
                    try specificationLoader(
                        specificationURL
                    )

                let reflector =
                    try OpenAPIReflector(
                        specificationData:
                            specification,
                        baseURL:
                            baseURL,
                    externalBearerSchemeName:
                        provider
                                .authorityScheme,
                    revalidateSpecification: { [loader = specificationLoader] in
                        try loader(specificationURL)
                    }
                    )

                next[
                    provider.id
                ] =
                    reflector
            } catch {
                // Each configured provider is independently untrusted.
                // A provider that cannot be acquired contributes no
                // capabilities to this snapshot.
                continue
            }
        }

        // Duplicate reflector identities from distinct configured IDs
        // are ambiguous and therefore fail closed.
        var reflectorCounts:
            [String: Int] = [:]

        for reflector
            in next.values
        {
            reflectorCounts[
                reflector.id,
                default:
                    0
            ] += 1
        }

        next =
            next.filter {
                _,
                reflector in

                reflectorCounts[
                    reflector.id
                ] == 1
            }

        replaceState(
            reflectors:
                next,
            configurationData:
                data,
            didLoad:
                true
        )
    }

    private func replaceState(
        reflectors:
            [String: OpenAPIReflector],
        configurationData:
            Data?,
        didLoad:
            Bool
    ) {
        stateLock.lock()

        currentReflectors =
            reflectors

        lastConfigurationData =
            configurationData

        didLoadConfiguration =
            didLoad

        freshness.recordAcquisition(at: clock())

        stateLock.unlock()
    }

    public func invalidateSnapshot() {
        reloadLock.lock()
        defer { reloadLock.unlock() }
        stateLock.lock()
        freshness.invalidate()
        currentReflectors.removeAll()
        stateLock.unlock()
    }
}
