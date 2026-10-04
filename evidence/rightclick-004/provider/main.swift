import AppKit
import Foundation

/// Independent macOS Service. RIGHTCLICK does not reference this provider.
final class RightClickTestProvider: NSObject {
    @objc func createSidecar(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let paths = Self.filePaths(from: pasteboard)
        if paths.isEmpty {
            error?.pointee = "No file URL was supplied to RIGHTCLICK Test Provider." as NSString
            return
        }
        for path in paths {
            let sidecar = path + ".rightclick-test.txt"
            do {
                try "RIGHTCLICK dynamic capability executed\n".write(toFile: sidecar, atomically: true, encoding: .utf8)
            } catch let writeError {
                error?.pointee = writeError.localizedDescription as NSString
                return
            }
        }
    }

    static func filePaths(from pasteboard: NSPasteboard) -> [String] {
        var paths: [String] = []
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls where !paths.contains(url.path) {
                paths.append(url.path)
            }
        }
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let listed = pasteboard.propertyList(forType: filenames) as? [String] {
            for path in listed where !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }
}

let provider = RightClickTestProvider()
NSApplication.shared.servicesProvider = provider
NSRegisterServicesProvider(provider, "RIGHTCLICK Test Provider")
NSUpdateDynamicServices()
NSApplication.shared.setActivationPolicy(.accessory)
NSApp.run()
