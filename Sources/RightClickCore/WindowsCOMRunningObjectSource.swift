import Foundation

/// Native live discovery composes with the ordinary capability graph. A failed
/// or unsupported host abstains; no native capability is fabricated elsewhere.
public final class WindowsCOMRunningObjectSource: CapabilityReflectorSource {
    public let id = "windows.com-running-objects"
#if os(Windows)
    private let resolver: WindowsCOMCapabilityArtifactResolver
    private let lock = NSLock()
    public init() { resolver = WindowsCOMCapabilityArtifactResolver() }
    public func reflectors() -> [any CapabilityReflector] {
        lock.lock(); defer { lock.unlock() }
        guard let libraries = try? resolver.catalog() else { return [] }
        return libraries.compactMap { try? resolver.reflector($0) }
    }
#else
    public init() {}
    public func reflectors() -> [any CapabilityReflector] { [] }
#endif
}
