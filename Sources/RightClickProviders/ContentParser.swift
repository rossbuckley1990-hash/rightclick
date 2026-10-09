import Foundation
import RightClickProtocol

public enum ContentParser {
    public static func parse(_ raw: String, allowFileInputs: Bool = true) throws -> ContentItem {
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
                typeDescription: PlatformHostDefaults.host.urlDescription
            )
        }
        if !allowFileInputs {
            guard !looksLikePath(trimmed), !trimmed.lowercased().hasPrefix("file:") else {
                throw RightClickError("File inputs are unavailable in this input scope.")
            }
            return ContentItem(kind: "text", display: trimmed, text: trimmed, typeIdentifier: "public.plain-text",
                typeDescription: PlatformHostDefaults.host.plainTextDescription, byteCount: trimmed.lengthOfBytes(using: .utf8))
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
            typeIdentifier: "public.plain-text",
            typeDescription: PlatformHostDefaults.host.plainTextDescription,
            byteCount: trimmed.lengthOfBytes(using: .utf8)
        )
    }

    public static func fileItem(url: URL, isDirectory: Bool) -> ContentItem {
        PlatformHostDefaults.host.fileItem(url: url, isDirectory: isDirectory)
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
