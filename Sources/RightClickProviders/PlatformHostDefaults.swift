import Foundation
import RightClickProtocol
#if os(macOS)
import RightClickMacOSHost
#endif

public enum PlatformHostDefaults {
    public static let host: any PlatformHost = {
        #if os(macOS)
        return MacOSHost()
        #else
        return PortableHost()
        #endif
    }()
}

public struct PortableHost: PlatformHost {
    public init() {}
    public var requiresMainThread: Bool { false }
    public var plainTextDescription: String? { "Plain text" }
    public var urlDescription: String? { "URL" }
    public func prepareApplication() {}
    public func refreshNativeServices() {}
    public func imageObservation(path: String) -> PlatformImageObservation { .init() }
    public func hasXattr(path: String, key: String) -> Bool? { nil }
    public func fileItem(url: URL, isDirectory: Bool) -> ContentItem {
        let type = PortableContentType.forExtension(url.pathExtension, directory: isDirectory)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return ContentItem(kind: type.kind, display: url.path, path: url.path, typeIdentifier: type.identifier,
            typeDescription: type.description, byteCount: size, isDirectory: isDirectory)
    }
    public func readSecret(service: String, account: String) throws -> Data? { nil }
    public func containsSecret(service: String, account: String) throws -> Bool { false }
    public func writeSecret(_ data: Data, service: String, account: String) throws { throw PlatformSecretError.unavailable }
    public func deleteSecret(service: String, account: String) throws -> Bool { throw PlatformSecretError.unavailable }
    public func secretErrorDescription(_ status: Int32) -> String { "Credential store unavailable (" + String(status) + ")." }
}
