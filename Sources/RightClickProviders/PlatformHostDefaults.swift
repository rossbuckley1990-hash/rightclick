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
        let types: [String: (String, String)] = ["txt": ("text_file", "public.plain-text"),
            "json": ("text_file", "public.json"), "jpg": ("image", "public.jpeg"), "jpeg": ("image", "public.jpeg"),
            "png": ("image", "public.png"), "pdf": ("pdf", "com.adobe.pdf"), "mov": ("video", "com.apple.quicktime-movie"),
            "mp4": ("video", "public.mpeg-4"), "mp3": ("audio", "public.mp3")]
        let type = isDirectory ? ("directory", "public.folder") : (types[url.pathExtension.lowercased()] ?? ("file", "public.data"))
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return ContentItem(kind: type.0, display: url.path, path: url.path, typeIdentifier: type.1,
            typeDescription: "File type inferred from extension", byteCount: size, isDirectory: isDirectory)
    }
    public func readSecret(service: String, account: String) throws -> Data? { nil }
    public func containsSecret(service: String, account: String) throws -> Bool { false }
    public func writeSecret(_ data: Data, service: String, account: String) throws { throw PlatformSecretError.unavailable }
    public func deleteSecret(service: String, account: String) throws -> Bool { throw PlatformSecretError.unavailable }
    public func secretErrorDescription(_ status: Int32) -> String { "Credential store unavailable (" + String(status) + ")." }
}
