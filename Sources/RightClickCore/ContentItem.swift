import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public struct ContentItem: Codable, Sendable, Equatable {
    public var kind: String
    public var display: String
    public var path: String?
    public var url: String?
    public var text: String?
    public var typeIdentifier: String?
    public var typeDescription: String?
    public var byteCount: Int?
    public var isDirectory: Bool

    public init(
        kind: String,
        display: String,
        path: String? = nil,
        url: String? = nil,
        text: String? = nil,
        typeIdentifier: String? = nil,
        typeDescription: String? = nil,
        byteCount: Int? = nil,
        isDirectory: Bool = false
    ) {
        self.kind = kind
        self.display = display
        self.path = path
        self.url = url
        self.text = text
        self.typeIdentifier = typeIdentifier
        self.typeDescription = typeDescription
        self.byteCount = byteCount
        self.isDirectory = isDirectory
    }

#if canImport(UniformTypeIdentifiers)
    public var utType: UTType? {
        guard let typeIdentifier else { return nil }
        return UTType(typeIdentifier)
    }
#endif
}

public enum ContentParser {
    public static func parse(_ raw: String) throws -> ContentItem {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw RightClickError("Item is empty.")
        }
        if let web = webURL(trimmed) {
            return ContentItem(
                kind: "web_url",
                display: web.absoluteString,
                url: web.absoluteString,
                typeIdentifier: "public.url",
                typeDescription: portableURLDescription
            )
        }
        let expanded = expandHomePath(trimmed)
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            return fileItem(url: candidate, isDirectory: isDirectory.boolValue)
        }
        if looksLikePath(trimmed) {
            throw RightClickError("No file at \(candidate.path).")
        }
        return ContentItem(
            kind: "text",
            display: trimmed,
            text: trimmed,
            typeIdentifier: "public.plain-text",
            typeDescription: portableTextDescription,
            byteCount: trimmed.lengthOfBytes(using: .utf8)
        )
    }

    public static func fileItem(url: URL, isDirectory: Bool) -> ContentItem {
#if canImport(UniformTypeIdentifiers)
        let values = try? url.resourceValues(forKeys: [
            .contentTypeKey, .fileSizeKey, .localizedTypeDescriptionKey, .isDirectoryKey,
        ])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let identifier = type?.identifier ?? (isDirectory ? UTType.folder.identifier : UTType.data.identifier)
        let resolved = UTType(identifier) ?? .data
        let kind: String
        if isDirectory || resolved.conforms(to: .folder) {
            kind = "directory"
        } else if resolved.conforms(to: .image) {
            kind = "image"
        } else if resolved.conforms(to: .pdf) {
            kind = "pdf"
        } else if resolved.conforms(to: .movie) || resolved.conforms(to: .video) {
            kind = "video"
        } else if resolved.conforms(to: .audio) {
            kind = "audio"
        } else if resolved.conforms(to: .text) || resolved.conforms(to: .plainText) {
            kind = "text_file"
        } else {
            kind = "file"
        }
        return ContentItem(
            kind: kind,
            display: url.path,
            path: url.path,
            typeIdentifier: identifier,
            typeDescription: values?.localizedTypeDescription ?? resolved.localizedDescription,
            byteCount: values?.fileSize,
            isDirectory: isDirectory || resolved.conforms(to: .folder)
        )
    #else
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let directory = isDirectory || values?.isDirectory == true
        return ContentItem(kind: directory ? "directory" : "file", display: url.path,
            path: url.path, typeIdentifier: directory ? "public.folder" : "public.data",
            typeDescription: directory ? "Directory" : "File", byteCount: values?.fileSize,
            isDirectory: directory)
#endif
    }

#if canImport(UniformTypeIdentifiers)
    public static func conforms(_ item: ContentItem, to other: UTType) -> Bool {
        guard let type = item.utType else { return false }
        return type.conforms(to: other) || type.identifier == other.identifier
    }
#endif

    private static var portableURLDescription: String? {
#if canImport(UniformTypeIdentifiers)
        UTType.url.localizedDescription
#else
        "URL"
#endif
    }
    private static var portableTextDescription: String? {
#if canImport(UniformTypeIdentifiers)
        UTType.plainText.localizedDescription
#else
        "Plain text"
#endif
    }
    private static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    static func expandHomePath(_ raw: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
#if os(Windows)
        if raw == "~" { return home.path }
        if raw.hasPrefix("~/") || raw.hasPrefix("~\\") {
            let tail = String(raw.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
            return home.appendingPathComponent(tail).path
        }
        // Windows has no POSIX ~username expansion. Never guess another user's home.
        return raw
#else
        if raw == "~" { return home.path }
        if raw.hasPrefix("~/") { return home.appendingPathComponent(String(raw.dropFirst(2))).path }
        return (raw as NSString).expandingTildeInPath
#endif
    }

    private static func looksLikePath(_ raw: String) -> Bool {
#if os(Windows)
        if raw.hasPrefix("\\\\") || raw.hasPrefix(".\\") || raw.hasPrefix("..\\") ||
            raw.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return true }
#endif
        return raw.hasPrefix("/") || raw.hasPrefix("~") || raw.hasPrefix("./") || raw.hasPrefix("../")
    }
}

public struct RightClickError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
