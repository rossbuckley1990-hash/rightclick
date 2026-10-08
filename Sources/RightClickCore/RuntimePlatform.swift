import Foundation

/// Host facts and storage conventions; never a catalog of executable abilities.
public enum RuntimePlatform {
    public static var name: String {
#if os(macOS)
        return "macOS"
#elseif os(Windows)
        return "Windows"
#elseif os(Linux)
        return "Linux"
#else
        return "unknown"
#endif
    }

    public static var pathSeparator: Character {
#if os(Windows)
        return ";"
#else
        return ":"
#endif
    }

    public static func isAbsolutePath(_ path: String) -> Bool {
#if os(Windows)
        if path.hasPrefix("\\\\") { return true }
        let bytes = Array(path.utf8)
        if bytes.count >= 3, ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])),
           bytes[1] == 58, bytes[2] == 92 || bytes[2] == 47 { return true }
#endif
        return path.hasPrefix("/")
    }

    public static func supportDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
#if os(macOS)
        return home.appendingPathComponent("Library/Application Support/RIGHTCLICK", isDirectory: true)
#elseif os(Windows)
        return base(environment["LOCALAPPDATA"], fallback: home.appendingPathComponent("AppData/Local"))
            .appendingPathComponent("RIGHTCLICK", isDirectory: true)
#else
        return base(environment["XDG_STATE_HOME"], fallback: home.appendingPathComponent(".local/state"))
            .appendingPathComponent("rightclick", isDirectory: true)
#endif
    }

    public static func logDirectory() -> URL {
#if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RIGHTCLICK", isDirectory: true)
#else
        return supportDirectory().appendingPathComponent("logs", isDirectory: true)
#endif
    }

    private static func base(_ raw: String?, fallback: URL) -> URL {
        guard let raw, !raw.isEmpty, isAbsolutePath(raw) else { return fallback }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }
}

/// Conservative extension hints on hosts without UniformTypeIdentifiers.
/// Classification does not confer invocation or authority.
enum PortableContentType {
    static func forExtension(_ ext: String, directory: Bool) -> (kind: String, identifier: String, description: String) {
        if directory { return ("directory", "public.folder", "Folder") }
        switch ext.lowercased() {
        case "jpg", "jpeg": return ("image", "public.jpeg", "JPEG image")
        case "png": return ("image", "public.png", "PNG image")
        case "gif": return ("image", "com.compuserve.gif", "GIF image")
        case "webp": return ("image", "org.webmproject.webp", "WebP image")
        case "pdf": return ("pdf", "com.adobe.pdf", "PDF document")
        case "mov": return ("video", "com.apple.quicktime-movie", "QuickTime movie")
        case "mp4", "m4v": return ("video", "public.mpeg-4", "MPEG-4 video")
        case "mp3": return ("audio", "public.mp3", "MP3 audio")
        case "wav": return ("audio", "com.microsoft.waveform-audio", "WAVE audio")
        case "txt", "md", "csv", "tsv", "log": return ("text_file", "public.plain-text", "Plain text")
        case "json": return ("text_file", "public.json", "JSON")
        case "xml": return ("text_file", "public.xml", "XML")
        default: return ("file", "public.data", "Data")
        }
    }
}
