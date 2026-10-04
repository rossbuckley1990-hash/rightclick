import AppKit
import Foundation

/// A tiny Services provider used only to prove that a newly installed
/// contextual service shows up in RIGHTCLICK without changing RIGHTCLICK.
final class MarkerProvider: NSObject {
    @objc func mark(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let input = pasteboard.string(forType: .string) ?? ""
        let output = "RIGHTCLICK_MARKER:\(input)"
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
        if let path = ProcessInfo.processInfo.environment["RIGHTCLICK_MARKER_LOG"] {
            try? output.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        }
    }
}

let provider = MarkerProvider()
NSRegisterServicesProvider(provider, "RightClickMarker")
NSUpdateDynamicServices()
NSApplication.shared.setActivationPolicy(.accessory)
NSApp.run()
