import AppKit
import Foundation

public struct ProviderSummary: Codable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var source: String
    public var capabilityTitles: [String]
}

public struct DoctorReport: Codable, Sendable {
    public var macosVersion: String
    public var macosBuild: String
    public var sharingDiscovery: String
    public var sharingExecution: String
    public var sharingSupportLevel: String
    public var servicesDiscovery: String
    public var servicesExecution: String
    public var servicesSupportLevel: String
    public var quickActionDiscovery: String
    public var quickActionExecution: String
    public var quickActionSupportLevel: String
    public var serviceRegistrationCount: Int
    public var actionExtensionCount: Int
    public var notes: [String]
}

public final class CapabilityEngine {
    public init() {
        let app = NSApplication.shared
        if app.activationPolicy() == .prohibited {
            app.setActivationPolicy(.accessory)
        }
    }

    public func inspect(_ raw: String) throws -> ContentItem {
        try ContentParser.parse(raw)
    }

    public func capabilities(for raw: String) throws -> (item: ContentItem, capabilities: [Capability]) {
        let item = try ContentParser.parse(raw)
        let combined = dedupeCapabilities(
            SharingCatalog.capabilities(for: item)
                + ServiceCatalog.capabilities(for: item)
                + ActionExtensionCatalog.capabilities(for: item)
        )
        return (item, combined.sorted { lhs, rhs in
            if lhs.source.rawValue == rhs.source.rawValue { return lhs.title < rhs.title }
            return lhs.source.rawValue < rhs.source.rawValue
        })
    }

    public func describe(id: String, item raw: String?) throws -> Capability {
        if let raw {
            let (_, capabilities) = try capabilities(for: raw)
            if let match = capabilities.first(where: { $0.id == id || $0.title == id }) {
                return match
            }
            throw RightClickError("No capability \(id) applies to this item.")
        }
        let services = ServiceCatalog.capabilities(for: ContentItem(kind: "text", display: "", text: " ", typeIdentifier: "public.plain-text"))
        let actions = ActionExtensionCatalog.records()
        if let match = services.first(where: { $0.id == id }) {
            return match
        }
        if let record = actions.first(where: { CapabilityID.actionExtension(bundleIdentifier: $0.bundleIdentifier, path: $0.bundlePath) == id }) {
            return Capability(
                id: id,
                title: record.name ?? id,
                source: .actionExtension,
                provider: CapabilityProvider(name: record.name, bundleIdentifier: record.bundleIdentifier),
                safety: .unknown,
                invocation: .unsupported,
                supportLevel: .publicSupported,
                requiresConfirmation: true,
                metadata: ["bundlePath": record.bundlePath, "note": "Pass an item to evaluate applicability."]
            )
        }
        throw RightClickError("Capability \(id) was not found. Sharing capabilities only exist in the context of an item.")
    }

    public func run(id: String, item raw: String, confirmed: Bool) throws -> RunResult {
        let (item, capabilities) = try capabilities(for: raw)
        guard let capability = capabilities.first(where: { $0.id == id || $0.title == id }) else {
            return RunResult(status: .failed, actionID: id, message: "No discovered capability matches \(id) for this item.")
        }
        if capability.invocation == .unsupported {
            return RunResult(
                status: .unsupported,
                actionID: capability.id,
                title: capability.title,
                message: "macOS exposes \(capability.title) as an Action extension, and this system has no public API to invoke it directly.",
                requiresConfirmation: true,
                supportLevel: capability.supportLevel
            )
        }
        if capability.requiresConfirmation && !confirmed {
            return RunResult(
                status: .confirmationRequired,
                actionID: capability.id,
                title: capability.title,
                message: "CONFIRMATION_REQUIRED. \(capability.title) is classified as \(capability.safety.rawValue). Re-run with confirmation to invoke it.",
                requiresConfirmation: true,
                supportLevel: capability.supportLevel
            )
        }
        switch capability.source {
        case .sharingService:
            return SharingCatalog.perform(capabilityID: capability.id, item: item)
        case .service:
            return ServiceCatalog.perform(capabilityID: capability.id, item: item)
        case .actionExtension, .system:
            return RunResult(
                status: .unsupported,
                actionID: capability.id,
                title: capability.title,
                message: "Invocation is not supported for \(capability.source.rawValue).",
                supportLevel: capability.supportLevel
            )
        }
    }

    public func providers() -> [ProviderSummary] {
        var grouped: [String: ProviderSummary] = [:]
        for record in ServiceCatalog.records() {
            let key = "service:\(record.bundleIdentifier ?? record.bundlePath)"
            var summary = grouped[key] ?? ProviderSummary(
                name: record.bundleName ?? record.bundleIdentifier ?? record.bundlePath,
                bundleIdentifier: record.bundleIdentifier,
                source: CapabilitySource.service.rawValue,
                capabilityTitles: []
            )
            summary.capabilityTitles.append(record.menuTitle)
            grouped[key] = summary
        }
        for record in ActionExtensionCatalog.records() {
            let key = "action:\(record.bundleIdentifier ?? record.bundlePath)"
            grouped[key] = ProviderSummary(
                name: record.name ?? record.bundleIdentifier ?? record.bundlePath,
                bundleIdentifier: record.bundleIdentifier,
                source: CapabilitySource.actionExtension.rawValue,
                capabilityTitles: [record.name ?? "Action"]
            )
        }
        return grouped.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func doctor() -> DoctorReport {
        let version = macosVersion()
        let services = ServiceCatalog.records()
        let actions = ActionExtensionCatalog.records()
        let sample = ContentItem(kind: "text", display: "doctor", text: "RightClick", typeIdentifier: "public.plain-text")
        let shares = SharingCatalog.capabilities(for: sample)
        return DoctorReport(
            macosVersion: version.product,
            macosBuild: version.build,
            sharingDiscovery: shares.isEmpty ? "FAIL" : "PASS",
            sharingExecution: "API_PRESENT",
            sharingSupportLevel: "public_deprecated",
            servicesDiscovery: services.isEmpty ? "FAIL" : "PASS",
            servicesExecution: "API_PRESENT",
            servicesSupportLevel: "public_supported",
            quickActionDiscovery: actions.isEmpty ? "FAIL" : "PASS",
            quickActionExecution: "UNAVAILABLE",
            quickActionSupportLevel: "public_supported discovery, execution unavailable",
            serviceRegistrationCount: services.count,
            actionExtensionCount: actions.count,
            notes: [
                "Sharing discovery uses NSSharingService.sharingServices(forItems:), which is deprecated in macOS 13 and still returns the context-filtered catalog on this Mac.",
                "NSSharingServicePicker.standardShareMenuItem does not enumerate services. It is a single Share menu item.",
                "Services are read from the documented NSServices Info.plist key and invoked with NSPerformService.",
                "Finder Action extensions are discovered from NSExtension metadata. Direct invocation is unsupported because NSExtension is not in the public SDK.",
                "Private NSExtension runtime matching was probed and is not used by this product.",
            ]
        )
    }
}

private func macosVersion() -> (product: String, build: String) {
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return ("unknown", "unknown") }
    return (plist["ProductVersion"] as? String ?? "unknown", plist["ProductBuildVersion"] as? String ?? "unknown")
}

public enum RightClickJSON {
    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
