import Foundation
import UniformTypeIdentifiers

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

    public var utType: UTType? {
        guard let typeIdentifier else { return nil }
        return UTType(typeIdentifier)
    }
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
                typeIdentifier: UTType.url.identifier,
                typeDescription: UTType.url.localizedDescription
            )
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
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
            typeIdentifier: UTType.plainText.identifier,
            typeDescription: UTType.plainText.localizedDescription,
            byteCount: trimmed.lengthOfBytes(using: .utf8)
        )
    }

    public static func fileItem(url: URL, isDirectory: Bool) -> ContentItem {
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
    }

    public static func conforms(_ item: ContentItem, to other: UTType) -> Bool {
        guard let type = item.utType else { return false }
        return type.conforms(to: other) || type.identifier == other.identifier
    }

    private static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func looksLikePath(_ raw: String) -> Bool {
        raw.hasPrefix("/") || raw.hasPrefix("~") || raw.hasPrefix("./") || raw.hasPrefix("../")
    }
}

public struct RightClickError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
