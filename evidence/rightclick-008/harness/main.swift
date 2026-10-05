import AppKit
import Darwin

let fixture = "RIGHTCLICK minimal service control 28471"
let serviceName = "BBEdit/New BBEdit Document with Selection"
let legacy = NSPasteboard.PasteboardType("NSStringPboardType")
let boardName = NSPasteboard.Name("rightclick.minimal.service.\(UUID().uuidString)")
let pasteboard = NSPasteboard(name: boardName)

func stamp(_ label: String) {
    let formatter = ISO8601DateFormatter()
    print("\(formatter.string(from: Date())) \(label)")
}

final class Harness: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        stamp("app launched main=\(Thread.isMainThread) pthread_main=\(pthread_main_np() != 0)")
        let declared = pasteboard.declareTypes([legacy], owner: nil)
        let wrote = pasteboard.setString(fixture, forType: legacy)
        let readback = pasteboard.string(forType: legacy) ?? ""
        let bytes = pasteboard.data(forType: legacy)?.count ?? -1
        let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: "|")
        print("pasteboardName=\(boardName.rawValue)")
        print("rawType=\(legacy.rawValue)")
        print("declareTypes=\(declared)")
        print("setString=\(wrote)")
        print("types=\(types)")
        print("readback=\(readback)")
        print("rawBytes=\(bytes)")
        print("mainThread=\(Thread.isMainThread)")
        print("nsApplicationRunning=\(NSApplication.shared.isRunning)")
        stamp("pasteboard populated")
        stamp("NSPerformService called")
        let accepted = NSPerformService(serviceName, pasteboard)
        stamp("NSPerformService returned \(accepted)")
        let after = pasteboard.string(forType: legacy) ?? ""
        let afterBytes = pasteboard.data(forType: legacy)?.count ?? -1
        let afterTypes = (pasteboard.types ?? []).map(\.rawValue).joined(separator: "|")
        print("serviceName=\(serviceName)")
        print("perform=\(accepted)")
        print("afterReadback=\(after)")
        print("afterRawBytes=\(afterBytes)")
        print("afterTypes=\(afterTypes)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            stamp("10-second retention ends")
            stamp("process exits")
            exit(accepted ? 0 : 2)
        }
    }
}

let application = NSApplication.shared
let harness = Harness()
application.delegate = harness
application.setActivationPolicy(.accessory)
application.run()
