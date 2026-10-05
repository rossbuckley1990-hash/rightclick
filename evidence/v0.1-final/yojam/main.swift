import AppKit
import Darwin

// Standalone experiment, deliberately independent of RightClickCore.
// One invocation; all input representations come from the installed service contract.
setbuf(stdout, nil)
let fixture = "https://example.com/rightclick-yojam-proof"
let infoURL = URL(fileURLWithPath: "/Applications/Yojam.app/Contents/Info.plist")
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
let entries = info["NSServices"] as! [[String: Any]]
let service = entries.first { ($0["NSMessage"] as? String) == "openURLViaService" }!
let title = (service["NSMenuItem"] as! [String: String])["default"]!
let declared = service["NSSendTypes"] as! [String]
let pasteboard = NSPasteboard.withUniqueName()

func stamp(_ text: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(text)")
}

final class Harness: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        precondition(Thread.isMainThread && pthread_main_np() != 0)
        stamp("main=true appRunning=\(NSApplication.shared.isRunning) activationPolicy=\(NSApplication.shared.activationPolicy().rawValue)")
        print("service=\(title) declared=\(declared.joined(separator: "|")) fixture=\(fixture)")
        let supported = declared.filter {
            ["public.url", "public.rtf", "public.utf8-plain-text", "NSStringPboardType", "public.plain-text"].contains($0)
        }.map { NSPasteboard.PasteboardType($0) }
        precondition(supported.count == declared.count)
        pasteboard.declareTypes(supported, owner: nil)
        for type in supported {
            let written: Bool
            if type == .rtf {
                let text = NSAttributedString(string: fixture)
                let bytes = try! text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                written = pasteboard.setData(bytes, forType: type)
                let readback = try! NSAttributedString(data: bytes, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                precondition(readback.string == fixture)
            } else {
                written = pasteboard.setString(fixture, forType: type)
                precondition(pasteboard.string(forType: type) == fixture)
            }
            precondition(written)
            print("representation=\(type.rawValue) bytes=\(pasteboard.data(forType: type)?.count ?? 0)")
        }
        print("actualTypes=\((pasteboard.types ?? []).map(\.rawValue).joined(separator: "|")) owner=nil eagerData=true name=\(pasteboard.name.rawValue)")
        let before = pasteboard.changeCount
        stamp("PAYLOAD_BUILT=true NSPerformService invocation=1")
        let accepted = NSPerformService(title, pasteboard)
        stamp("INVOKED=\(accepted) changeCount=\(before)->\(pasteboard.changeCount)")
        // Keep the same board and a running NSApplication for thirty seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            stamp("retained=30s appRunning=\(NSApplication.shared.isRunning) boardChangeCount=\(pasteboard.changeCount)")
            print("COMPLETED=unknown OUTCOME_VERIFIED=requires-independent-observation")
            pasteboard.releaseGlobally()
            exit(accepted ? 0 : 2)
        }
    }
}

let app = NSApplication.shared
let harness = Harness()
app.delegate = harness
app.setActivationPolicy(.accessory)
app.run()
