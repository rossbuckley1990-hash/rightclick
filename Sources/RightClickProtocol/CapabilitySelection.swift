import Foundation

/// Selection is an identity operation, not a ranking operation. A title is a
/// convenience alias only when it resolves to one unambiguous live contract.
public enum CapabilitySelectionError: Error, LocalizedError, Equatable {
    case notFound
    case ambiguousTitle
    case conflictingIdentity
    case contractMismatch

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No discovered capability matches this selector for this item."
        case .ambiguousTitle:
            return "The capability title is ambiguous. Discover again and use an exact capability ID."
        case .conflictingIdentity:
            return "Conflicting declarations share a capability ID. No provider was selected."
        case .contractMismatch:
            return "CONTRACT_MISMATCH. The reviewed declaration changed or is unavailable. Discover and review it again; do not retry unpinned automatically."
        }
    }
}

public enum CapabilitySelection {
    package struct Catalog {
        package let capabilities: [Capability]
        package let quarantinedIDs: Set<Data>
    }
    /// Preserve byte identity: Swift String equality treats some different
    /// Unicode spellings as equivalent, which is not appropriate for routing.
    private static func key(_ string: String) -> Data { Data(string.utf8) }

    private static func snapshot(_ capability: Capability) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(capability.withoutDiscoveryAdvice())
    }

    /// Exact repeats are harmless. Conflicting repeats quarantine the whole ID,
    /// including later repetitions of the original declaration. Other IDs stay.
    public static func unambiguous(_ capabilities: [Capability]) -> [Capability] {
        catalog(capabilities).capabilities
    }

    /// Quarantine context belongs to this discovery snapshot. Retain it through
    /// selection so removing a conflicting ID cannot enable a title fallback.
    package static func catalog(_ capabilities: [Capability]) -> Catalog {
        var first: [Data: Capability] = [:]
        var snapshots: [Data: Data] = [:]
        var order: [Data] = []
        var conflicts = Set<Data>()
        for capability in capabilities {
            let id = key(capability.id)
            guard !capability.id.isEmpty else { continue }
            if conflicts.contains(id) { continue }
            if let original = first[id] {
                // Unique IDs need no serialization. Pay the snapshot cost only
                // when a duplicate identity actually needs adjudication.
                guard let prior = snapshots[id] ?? (try? snapshot(original)),
                      let bytes = try? snapshot(capability) else {
                    conflicts.insert(id)
                    continue
                }
                snapshots[id] = prior
                if prior != bytes { conflicts.insert(id) }
            } else {
                first[id] = capability
                order.append(id)
            }
        }
        return Catalog(capabilities: order.compactMap { conflicts.contains($0) ? nil : first[$0] },
                       quarantinedIDs: conflicts)
    }

    public static func resolve(_ selector: String, from capabilities: [Capability]) throws -> Capability {
        try resolve(selector, from: capabilities, quarantinedIDs: [])
    }

    package static func resolve(_ selector: String, from capabilities: [Capability], quarantinedIDs: Set<Data>) throws -> Capability {
        guard !selector.isEmpty else { throw CapabilitySelectionError.notFound }
        let selectorKey = key(selector)
        guard !quarantinedIDs.contains(selectorKey) else { throw CapabilitySelectionError.conflictingIdentity }
        let exact = capabilities.filter { key($0.id) == selectorKey }
        if !exact.isEmpty {
            let unique = unambiguous(exact)
            guard unique.count == 1 else { throw CapabilitySelectionError.conflictingIdentity }
            return unique[0]
        }

        // An exact ID always wins over another provider's title claiming to be
        // that ID. Otherwise aliases must be unique, even across substrates.
        let aliases = capabilities.filter { key($0.title) == selectorKey }
        guard !aliases.isEmpty else { throw CapabilitySelectionError.notFound }
        let ids = Set(aliases.map { key($0.id) })
        guard ids.count == 1, let id = ids.first else {
            throw CapabilitySelectionError.ambiguousTitle
        }
        // Include every declaration of the ID, not just same-title rows.
        let unique = unambiguous(capabilities.filter { key($0.id) == id })
        guard unique.count == 1 else { throw CapabilitySelectionError.conflictingIdentity }
        return unique[0]
    }
}
