import RightClickProtocol
import RightClickProviders
import Foundation

/// Safe automatic native session discovery. Reads metadata from current owners,
/// walks declared child nodes within fixed limits and never activates a service.
public final class DBusSessionSource: CapabilityReflectorSource {
    public let id = "linux.dbus-session"
    private let resolver: DBusCapabilityArtifactResolver
    private let lock = NSLock()
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        resolver = DBusCapabilityArtifactResolver(environment: environment)
    }
    public init(resolver: DBusCapabilityArtifactResolver) { self.resolver = resolver }
    public func reflectors() -> [any CapabilityReflector] {
        lock.lock(); defer { lock.unlock() }
        guard let names = try? resolver.names() else { return [] }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var result: [any CapabilityReflector] = [], remaining = 64
        for name in names.prefix(32) {
            guard ProcessInfo.processInfo.systemUptime < deadline, let owner = try? resolver.owner(name) else { continue }
            var paths: [(String, Int)] = [("/", 0)], seen: Set<String> = []
            while !paths.isEmpty, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline {
                let (path, depth) = paths.removeFirst()
                guard seen.insert(path).inserted, depth <= 8 else { continue }
                remaining -= 1
                guard let xml = try? resolver.introspect(owner: owner, path: path), let metadata = try? DBusCapabilityArtifactResolver.discoveryMetadata(xml) else { continue }
                if metadata.hasSupportedMethods {
                    let endpoint = "dbus://" + name + path
                    if let reflector = try? resolver.resolve(.init(id: name + path, kind: "dbus", endpointURL: endpoint)) { result.append(reflector) }
                }
                for child in metadata.children { paths.append((path == "/" ? "/" + child : path + "/" + child, depth + 1)) }
            }
        }
        return result
    }
}
