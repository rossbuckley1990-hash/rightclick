import Foundation
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
