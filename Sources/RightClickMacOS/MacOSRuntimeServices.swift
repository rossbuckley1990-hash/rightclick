import Foundation
import RightClickProtocol
import RightClickProviders

/// Native diagnostics and context-free catalog lookup belong to the adapter.
public enum MacOSRuntimeServices {
    public static func describe(id: String) throws -> Capability {
        var services = ServiceCatalog.capabilities(for: ContentItem(kind: "text", display: "", text: " ", typeIdentifier: "public.plain-text"))
        for index in services.indices { services[index].reflectorID = CapabilityReflectorID.macOSService }
        if let match = services.first(where: { $0.id == id }) { return match }
        if let record = ActionExtensionCatalog.records().first(where: {
            CapabilityID.actionExtension(bundleIdentifier: $0.bundleIdentifier, path: $0.bundlePath) == id
        }) {
            return Capability(id: id, title: record.name ?? id, source: .actionExtension,
                reflectorID: CapabilityReflectorID.macOSActionExtension,
                provider: CapabilityProvider(name: record.name, bundleIdentifier: record.bundleIdentifier),
                safety: .unknown, invocation: .unsupported, supportLevel: .publicSupported,
                requiresConfirmation: true,
                metadata: ["bundlePath": record.bundlePath, "note": "Pass an item to evaluate applicability."])
        }
        throw RightClickError("Capability \(id) was not found. Sharing capabilities only exist in the context of an item.")
    }

    public static func doctor() -> DoctorReport {
        let version = macosVersion()
        let services = ServiceCatalog.records()
        let actions = ActionExtensionCatalog.records()
        let sample = ContentItem(kind: "text", display: "doctor", text: "RightClick", typeIdentifier: "public.plain-text")
        let shares = SharingCatalog.capabilities(for: sample)
        return DoctorReport(
            macosVersion: version.product, macosBuild: version.build,
            sharingDiscovery: shares.isEmpty ? "FAIL" : "PASS", sharingExecution: "API_PRESENT", sharingSupportLevel: "public_deprecated",
            servicesDiscovery: services.isEmpty ? "FAIL" : "PASS", servicesExecution: "API_PRESENT", servicesSupportLevel: "public_supported",
            quickActionDiscovery: actions.isEmpty ? "FAIL" : "PASS", quickActionExecution: "UNAVAILABLE",
            quickActionSupportLevel: "public_supported discovery, execution unavailable",
            serviceRegistrationCount: services.count, actionExtensionCount: actions.count,
            notes: [
                "Sharing discovery uses NSSharingService.sharingServices(forItems:), which is deprecated in macOS 13 and still returns the context-filtered catalog on this Mac.",
                "NSSharingServicePicker.standardShareMenuItem does not enumerate services. It is a single Share menu item.",
                "Services are read from the documented NSServices Info.plist key and invoked with NSPerformService.",
                "Finder Action extensions are discovered from NSExtension metadata. Direct invocation is unsupported because NSExtension is not in the public SDK.",
                "Private NSExtension runtime matching was probed and is not used by this product.",
            ])
    }

    private static func macosVersion() -> (product: String, build: String) {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return ("unknown", "unknown") }
        return (plist["ProductVersion"] as? String ?? "unknown", plist["ProductBuildVersion"] as? String ?? "unknown")
    }
}
