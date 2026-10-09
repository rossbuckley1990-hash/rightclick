import Foundation
import RightClickProtocol
import RightClickProviders
#if os(macOS)
import RightClickMacOS
#endif

enum NativeRuntimeDefaults {
    static func describe(id: String) throws -> Capability {
        #if os(macOS)
        return try MacOSRuntimeServices.describe(id: id)
        #else
        throw RightClickError("Native desktop capabilities are unavailable on this runtime.")
        #endif
    }
    static func doctor() -> DoctorReport {
        #if os(macOS)
        return MacOSRuntimeServices.doctor()
        #else
        return DoctorReport(macosVersion: "unavailable", macosBuild: "unavailable",
            sharingDiscovery: "UNAVAILABLE", sharingExecution: "UNAVAILABLE", sharingSupportLevel: "unavailable",
            servicesDiscovery: "UNAVAILABLE", servicesExecution: "UNAVAILABLE", servicesSupportLevel: "unavailable",
            quickActionDiscovery: "UNAVAILABLE", quickActionExecution: "UNAVAILABLE", quickActionSupportLevel: "unavailable",
            serviceRegistrationCount: 0, actionExtensionCount: 0,
            notes: ["Portable runtime ready: OS=\(RuntimeEnvironment.current.operatingSystem.rawValue), architecture=\(RuntimeEnvironment.current.architecture).",
                    "Configured providers use the shared engine; native desktop catalogs are unavailable."])
        #endif
    }
}
#if !os(macOS)
enum CapabilityReflectorDefaults {
    static func all() -> [any CapabilityReflector] { [] }
}
#endif
