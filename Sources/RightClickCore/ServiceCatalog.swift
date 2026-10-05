import AppKit
import Foundation
import UniformTypeIdentifiers

struct InstalledServiceRecord: Equatable {
    var menuTitle: String
    var message: String?
    var bundleIdentifier: String?
    var bundleName: String?
    var bundlePath: String
    var sendTypes: [String]
    var sendFileTypes: [String]
    var returnTypes: [String]
    var requiredContext: String?
}

enum ServiceCatalog {
    static func records() -> [InstalledServiceRecord] {
        records(roots: BundleScan.standardServiceRoots())
    }

    static func records(roots: [URL]) -> [InstalledServiceRecord] {
        var found: [InstalledServiceRecord] = []
        var seen = Set<String>()
        for infoURL in BundleScan.infoPlists(roots: roots, bundleExtensions: ["app", "service", "workflow"]) {
            guard let plist = loadPropertyList(at: infoURL),
                  let entries = plist["NSServices"] as? [[String: Any]]
            else { continue }
            let bundleURL = infoURL.deletingLastPathComponent().deletingLastPathComponent()
            let bundleID = plist["CFBundleIdentifier"] as? String
            let bundleName = plist["CFBundleName"] as? String ?? plist["CFBundleDisplayName"] as? String
            for entry in entries {
                let menuTitle = ((entry["NSMenuItem"] as? [String: Any])?["default"] as? String) ?? ""
                if menuTitle.isEmpty { continue }
                let message = entry["NSMessage"] as? String
                let key = [bundleID ?? bundleURL.path, menuTitle, message ?? ""].joined(separator: "|")
                if !seen.insert(key).inserted { continue }
                found.append(InstalledServiceRecord(
                    menuTitle: menuTitle,
                    message: message,
                    bundleIdentifier: bundleID,
                    bundleName: bundleName,
                    bundlePath: bundleURL.path,
                    sendTypes: stringList(entry["NSSendTypes"]),
                    sendFileTypes: stringList(entry["NSSendFileTypes"]),
                    returnTypes: stringList(entry["NSReturnTypes"]),
                    requiredContext: jsonString(entry["NSRequiredContext"])
                ))
            }
        }
        return found.sorted { $0.menuTitle < $1.menuTitle }
    }

    static func capabilities(for item: ContentItem, records: [InstalledServiceRecord]? = nil) -> [Capability] {
        (records ?? self.records()).compactMap { record in
            guard accepts(record, item: item) else { return nil }
            return capability(for: record)
        }
    }

    static func perform(capabilityID: String, item: ContentItem) -> RunResult {
        NSUpdateDynamicServices()
        guard let record = records().first(where: { capability(for: $0).id == capabilityID }) else {
            return RunResult(status: .failed, actionID: capabilityID, message: "No installed service has id \(capabilityID).")
        }
        guard accepts(record, item: item) else {
            return RunResult(status: .failed, actionID: capabilityID, title: record.menuTitle, message: "\(record.menuTitle) does not accept this item.")
        }
        guard let payload = servicePayload(for: item, record: record) else {
            return RunResult(status: .failed, actionID: capabilityID, title: record.menuTitle, message: "Could not build a pasteboard payload for \(record.menuTitle).")
        }
        let pasteboard = NSPasteboard.withUniqueName()
        declare(payload, on: pasteboard, record: record)
        let before = pasteboard.changeCount
        let written = (pasteboard.types ?? []).map(\.rawValue)
        let readback = bestString(on: pasteboard) ?? ""
        let utf8Bytes = readback.data(using: .utf8)?.count ?? 0
        let utf16Bytes = readback.data(using: .utf16)?.count ?? 0
        ExecutionLog.write("service payload declared=\(record.sendTypes.joined(separator: "|")) written=\(written.joined(separator: "|")) stringBytes=\(utf16Bytes) utf8Bytes=\(utf8Bytes) readback=\(readback)")
        ExecutionLog.write("NSPerformService name=\(record.menuTitle) provider=\(record.bundleIdentifier ?? "") sendFileTypes=\(record.sendFileTypes) pasteboardTypes=\(written.joined(separator: ",")) main=\(Thread.isMainThread)")
        let box = ServiceCallBox()
        if Thread.isMainThread {
            box.finish(NSPerformService(record.menuTitle, pasteboard))
        } else {
            DispatchQueue.main.async {
                box.finish(NSPerformService(record.menuTitle, pasteboard))
            }
            let deadline = Date().addingTimeInterval(20)
            while !box.done && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        let output = bestString(on: pasteboard)
        let after = pasteboard.changeCount
        if box.ok && after == before {
            // NSPerformService can return before the provider reads the pasteboard.
            ExecutionLog.write("service pasteboard retained after NSPerformService returned without a pasteboard result")
            retain(pasteboard, seconds: 10)
        }
        pasteboard.releaseGlobally()
        _ = before
        if !box.done {
            ExecutionLog.write("NSPerformService timed out")
            return RunResult(
                status: .failed,
                actionID: capabilityID,
                title: record.menuTitle,
                message: "NSPerformService(\"\(record.menuTitle)\") did not return within 20 seconds.",
                supportLevel: .publicSupported
            )
        }
        ExecutionLog.write("NSPerformService returned \(box.ok) changeCount \(before)->\(after)")
        if !box.ok {
            return RunResult(
                status: .failed,
                actionID: capabilityID,
                title: record.menuTitle,
                message: "NSPerformService(\"\(record.menuTitle)\") returned false.",
                output: output,
                supportLevel: .publicSupported
            )
        }
        return RunResult(
            status: .executed,
            actionID: capabilityID,
            title: record.menuTitle,
            message: "NSPerformService(\"\(record.menuTitle)\") returned true.",
            output: output,
            supportLevel: .publicSupported
        )
    }

    static func accepts(_ record: InstalledServiceRecord, item: ContentItem) -> Bool {
        if item.path != nil {
            if record.sendFileTypes.contains(where: { typeIdentifier($0).map { ContentParser.conforms(item, to: $0) } ?? false }) {
                return true
            }
            if item.kind == "text_file" || item.kind == "text" {
                return record.sendTypes.contains(where: isTextType)
            }
            if let type = item.utType, record.sendTypes.contains(where: { declared in
                guard let declaredType = typeIdentifier(declared) else { return false }
                return type.conforms(to: declaredType)
            }) {
                return true
            }
            return false
        }
        if item.url != nil {
            return canEncodeWebURL(declaredSendTypes: record.sendTypes)
        }
        if item.text != nil {
            return record.sendTypes.contains(where: isTextType)
        }
        return false
    }

    private static func capability(for record: InstalledServiceRecord) -> Capability {
        let policy = SafetyPolicy.classify(
            title: record.menuTitle,
            source: .service,
            sendTypes: record.sendTypes + record.sendFileTypes,
            returnTypes: record.returnTypes
        )
        var metadata = [
            "bundlePath": record.bundlePath,
            "discoverySource": "NSServices Info.plist",
        ]
        if let message = record.message { metadata["message"] = message }
        if let required = record.requiredContext { metadata["requiredContext"] = required }
        return Capability(
            id: CapabilityID.service(bundleIdentifier: record.bundleIdentifier, message: record.message, menuTitle: record.menuTitle),
            title: record.menuTitle,
            source: .service,
            provider: CapabilityProvider(name: record.bundleName, bundleIdentifier: record.bundleIdentifier),
            inputs: record.sendTypes + record.sendFileTypes,
            output: record.returnTypes,
            safety: policy.safety,
            invocation: policy.invocation,
            supportLevel: .publicSupported,
            requiresConfirmation: policy.requiresConfirmation,
            metadata: metadata
        )
    }

    private static func servicePayload(for item: ContentItem, record: InstalledServiceRecord) -> ServicePayload? {
        if item.path != nil, record.sendFileTypes.contains(where: { typeIdentifier($0).map { ContentParser.conforms(item, to: $0) } ?? false }) {
            return ServicePayload(text: nil, filePath: item.path, webURL: nil)
        }
        if let web = item.url {
            guard canEncodeWebURL(declaredSendTypes: record.sendTypes) else { return nil }
            return ServicePayload(text: nil, filePath: nil, webURL: web)
        }
        if let text = item.text {
            return ServicePayload(text: text, filePath: nil, webURL: nil)
        }
        if let path = item.path, item.kind == "text_file" || (item.utType?.conforms(to: .text) ?? false) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 1_000_000,
               let text = String(data: data, encoding: .utf8) {
                return ServicePayload(text: text, filePath: nil, webURL: nil)
            }
        }
        if let path = item.path {
            return ServicePayload(text: nil, filePath: path, webURL: nil)
        }
        return nil
    }

    static func canEncodeWebURL(declaredSendTypes: [String]) -> Bool {
        declaredSendTypes.contains { isWebURLSendType($0) || isTextType($0) }
    }

    static func prepareWebURLPasteboard(_ pasteboard: NSPasteboard, url: String, declaredSendTypes: [String]) -> Bool {
        let record = InstalledServiceRecord(
            menuTitle: "url",
            message: nil,
            bundleIdentifier: nil,
            bundleName: nil,
            bundlePath: "",
            sendTypes: declaredSendTypes,
            sendFileTypes: [],
            returnTypes: [],
            requiredContext: nil
        )
        guard let payload = servicePayload(
            for: ContentItem(kind: "web_url", display: url, url: url, typeIdentifier: "public.url"),
            record: record
        ) else { return false }
        declare(payload, on: pasteboard, record: record)
        return true
    }

    static func pasteboardTypesForText(declaredSendTypes: [String]) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = []
        for raw in declaredSendTypes where isTextType(raw) {
            let type = pasteboardType(for: raw)
            if !types.contains(type) {
                types.append(type)
            }
        }
        if types.isEmpty {
            types = [.string, NSPasteboard.PasteboardType("public.utf8-plain-text")]
        }
        return types
    }

    static func prepareTextPasteboard(_ pasteboard: NSPasteboard, text: String, declaredSendTypes: [String]) {
        let record = InstalledServiceRecord(
            menuTitle: "text",
            message: nil,
            bundleIdentifier: nil,
            bundleName: nil,
            bundlePath: "",
            sendTypes: declaredSendTypes,
            sendFileTypes: [],
            returnTypes: [],
            requiredContext: nil
        )
        declare(ServicePayload(text: text, filePath: nil), on: pasteboard, record: record)
    }

    private static func declare(_ payload: ServicePayload, on pasteboard: NSPasteboard, record: InstalledServiceRecord) {
        if let web = payload.webURL {
            var types: [NSPasteboard.PasteboardType] = []
            var rich: [NSPasteboard.PasteboardType] = []
            for raw in record.sendTypes {
                let type = pasteboardType(for: raw)
                let include = isWebURLSendType(raw) || isTextType(raw)
                guard include, !types.contains(type) else { continue }
                types.append(type)
                if isTextType(raw), isRichTextType(type) {
                    rich.append(type)
                }
            }
            guard !types.isEmpty else { return }
            pasteboard.declareTypes(types, owner: nil)
            for type in types {
                if rich.contains(type) {
                    pasteboard.setData(plainTextRTF(web), forType: type)
                } else {
                    pasteboard.setString(web, forType: type)
                }
            }
            return
        }
        if let text = payload.text {
            let types = pasteboardTypesForText(declaredSendTypes: record.sendTypes)
            pasteboard.declareTypes(types, owner: nil)
            for type in types {
                if isRichTextType(type) {
                    pasteboard.setData(plainTextRTF(text), forType: type)
                } else {
                    pasteboard.setString(text, forType: type)
                }
            }
            return
        }
        if let path = payload.filePath {
            let url = URL(fileURLWithPath: path)
            let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            pasteboard.addTypes([filenames], owner: nil)
            pasteboard.setPropertyList([path], forType: filenames)
            for raw in record.sendTypes where raw.lowercased().contains("url") || raw == "NSURLPboardType" {
                let type = pasteboardType(for: raw)
                pasteboard.addTypes([type], owner: nil)
                pasteboard.setString(url.absoluteString, forType: type)
            }
        }
    }

    private static func pasteboardType(for raw: String) -> NSPasteboard.PasteboardType {
        switch raw {
        case "NSStringPboardType", "NSPasteboardTypeString":
            return NSPasteboard.PasteboardType("NSStringPboardType")
        case "NSRTFPboardType":
            return .rtf
        case "NSRTFDPboardType":
            return NSPasteboard.PasteboardType("NSRTFDPboardType")
        case "public.utf8-plain-text":
            return .string
        default:
            return NSPasteboard.PasteboardType(raw)
        }
    }

    private static func isRichTextType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let raw = type.rawValue.lowercased()
        return raw == "public.rtf" || raw == "nsrtfpboardtype" || raw == NSPasteboard.PasteboardType.rtf.rawValue.lowercased()
    }

    private static func plainTextRTF(_ text: String) -> Data {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: "\\par ")
        return Data("{\\rtf1\\ansi \(escaped)}".utf8)
    }

    private static func retain(_ pasteboard: NSPasteboard, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        let hold = {
            _ = NSApplication.shared
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            _ = pasteboard
        }
        if Thread.isMainThread {
            hold()
            return
        }
        let box = ServiceCallBox()
        DispatchQueue.main.async {
            hold()
            box.finish(true)
        }
        let wait = Date().addingTimeInterval(seconds + 2)
        while !box.done && Date() < wait {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func bestString(on pasteboard: NSPasteboard) -> String? {
        let preferred: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
            .string,
        ]
        for type in preferred {
            if let string = pasteboard.string(forType: type), !string.isEmpty {
                return string
            }
        }
        for type in pasteboard.types ?? [] {
            if let string = pasteboard.string(forType: type), !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func isWebURLSendType(_ type: String) -> Bool {
        switch type.lowercased() {
        case "public.url", "nsurlpboardtype", "nspasteboardtypeurl":
            return true
        default:
            return false
        }
    }

    private static func isTextType(_ type: String) -> Bool {
        let lowered = type.lowercased()
        return lowered.contains("string") || lowered.contains("text") || lowered.contains("rtf")
    }

    private static func typeIdentifier(_ raw: String) -> UTType? {
        switch raw {
        case "NSStringPboardType":
            return .utf8PlainText
        case "NSRTFPboardType":
            return .rtf
        case "NSRTFDPboardType":
            return .flatRTFD
        default:
            return UTType(raw)
        }
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct ServicePayload {
    var text: String?
    var filePath: String?
    var webURL: String?
}

private final class ServiceCallBox {
    private let lock = NSLock()
    private var storedDone = false
    private var storedOK = false

    var done: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedDone
    }

    var ok: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedOK
    }

    func finish(_ value: Bool) {
        lock.lock()
        storedOK = value
        storedDone = true
        lock.unlock()
    }
}
