import RightClickProviders
import RightClickProtocol
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
            guard seen.insert(infoURL.resolvingSymlinksInPath().path).inserted else { continue }
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
        let installed = records ?? self.records()
        return installed.compactMap { record in
            guard accepts(record, item: item) else { return nil }
            var result = capability(for: record)
            if isAmbiguous(record, installed: installed) {
                result.invocation = .unsupported
                result.metadata["invocationLimitation"] = "Ambiguous Service name or identifier; the public title-based API cannot safely select this provider."
            }
            return result
        }
    }

    private static func isAmbiguous(_ record: InstalledServiceRecord, installed: [InstalledServiceRecord]) -> Bool {
        let title = record.menuTitle.split(separator: "/").last.map(String.init) ?? record.menuTitle
        let id = capability(for: record).id
        return installed.filter {
            ($0.menuTitle.split(separator: "/").last.map(String.init) ?? $0.menuTitle) == title || capability(for: $0).id == id
        }.count > 1
    }

    static func perform(capabilityID: String, item: ContentItem, expectedOutput: String? = nil) -> RunResult {
        NSUpdateDynamicServices()
        let installed = records()
        guard let record = installed.first(where: { capability(for: $0).id == capabilityID }) else {
            return RunResult(status: .unavailable, actionID: capabilityID, message: "No installed service has id \(capabilityID).")
        }
        guard !isAmbiguous(record, installed: installed) else {
            return RunResult(status: .unsupported, actionID: capabilityID, title: record.menuTitle,
                             message: "Ambiguous Service name or identifier. Invocation withheld.")
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
        ExecutionLog.write("NSPerformService name=\(record.menuTitle) provider=\(record.bundleIdentifier ?? "") sendFileTypes=\(record.sendFileTypes) pasteboardTypes=\(written.joined(separator: ",")) main=\(Thread.isMainThread)")
        let box = ServiceCallBox()
        if Thread.isMainThread {
            box.finish(NSPerformService(record.menuTitle, pasteboard))
        } else {
            DispatchQueue.main.async {
                let accepted = NSPerformService(record.menuTitle, pasteboard)
                if box.finish(accepted) {
                    if accepted { retain(pasteboard, seconds: 10) }
                    pasteboard.releaseGlobally()
                }
            }
            let deadline = Date().addingTimeInterval(20)
            while !box.done && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
        if box.ok && pasteboard.changeCount == before {
            // Some providers consume input after the invocation API returns.
            retain(pasteboard, seconds: 10)
        }
        let changed = pasteboard.changeCount != before
        let output = changed ? declaredReturnedText(on: pasteboard, types: record.returnTypes) : nil
        // A timed-out asynchronous invocation can still own and consume its board.
        // Retain it in that invocation closure until the public call returns.
        if box.expire() { pasteboard.releaseGlobally() }
        return ServiceOutcome.result(actionID: capabilityID, title: record.menuTitle,
                                     returned: box.done ? box.ok : nil,
                                     pasteboardChanged: changed, returnedText: output,
                                     expectedOutput: expectedOutput, inputText: payload.text ?? payload.webURL ?? payload.filePath)
    }

    private static func declaredReturnedText(on pasteboard: NSPasteboard, types: [String]) -> String? {
        for raw in types where isTextType(raw) {
            let type = pasteboardType(for: raw)
            if isRichTextType(type) {
                if let data = pasteboard.data(forType: type),
                   let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                    return attributed.string
                }
            } else if let text = pasteboard.string(forType: type) {
                return text
            }
        }
        return nil
    }

    static func accepts(_ record: InstalledServiceRecord, item: ContentItem) -> Bool {
        ServiceContext.accepts(record.requiredContext, item: item) && servicePayload(for: item, record: record) != nil
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
            id: CapabilityID.service(
                bundleIdentifier: record.bundleIdentifier,
                bundlePath: record.bundlePath,
                message: record.message,
                menuTitle: record.menuTitle
            ),
            title: record.menuTitle,
            source: .service,
            provider: CapabilityProvider(name: record.bundleName, bundleIdentifier: record.bundleIdentifier),
            inputs: record.sendTypes + record.sendFileTypes,
            output: record.returnTypes,
            safety: policy.safety,
            invocation: policy.invocation,
            supportLevel: .publicSupported,
            requiresConfirmation: policy.requiresConfirmation,
            metadata: metadata,
            runtimeRequirements: RuntimeRequirements(operatingSystems: [.macOS])
        )
    }

    private static func servicePayload(for item: ContentItem, record: InstalledServiceRecord) -> ServicePayload? {
        if let path = item.path {
            if record.sendFileTypes.contains(where: { typeIdentifier($0).map { ContentParser.conforms(item, to: $0) } ?? false }) {
                return ServicePayload(text: nil, filePath: path, webURL: nil)
            }
            if record.sendTypes.contains(where: isFileURLSendType) ||
                (ServiceContext.requiresFilePath(record.requiredContext, item: item) && record.sendTypes.contains(where: isTextType)) {
                return ServicePayload(text: nil, filePath: path, webURL: nil)
            }
            if record.sendTypes.contains(where: isTextType), item.utType?.conforms(to: .text) == true,
               let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size <= 1_000_000,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 1_000_000,
               let text = String(data: data, encoding: .utf8) {
                return ServicePayload(text: text, filePath: nil, webURL: nil)
            }
            return nil
        }
        if let web = item.url {
            guard canEncodeWebURL(declaredSendTypes: record.sendTypes) else { return nil }
            return ServicePayload(text: nil, filePath: nil, webURL: web)
        }
        if let text = item.text, record.sendTypes.contains(where: isTextType) {
            return ServicePayload(text: text, filePath: nil, webURL: nil)
        }
        return nil
    }

    static func preparePasteboard(_ pasteboard: NSPasteboard, item: ContentItem, record: InstalledServiceRecord) -> Bool {
        guard accepts(record, item: item), let payload = servicePayload(for: item, record: record) else { return false }
        declare(payload, on: pasteboard, record: record)
        return true
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
            if !record.sendFileTypes.isEmpty {
                // NSSendFileTypes explicitly declares a file-URL contract.
                pasteboard.clearContents()
                pasteboard.writeObjects([url as NSURL])
                return
            }
            let types = record.sendTypes.filter { isFileURLSendType($0) || isTextType($0) }.map(pasteboardType)
            pasteboard.declareTypes(types, owner: nil)
            for raw in record.sendTypes {
                let type = pasteboardType(for: raw)
                if isFileURLSendType(raw) {
                    pasteboard.setString(url.absoluteString, forType: type)
                } else if isTextType(raw) {
                    if isRichTextType(type) { pasteboard.setData(plainTextRTF(path), forType: type) }
                    else { pasteboard.setString(path, forType: type) }
                }
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
        ServiceRTFEncoder.encode(text)
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

    private static func isFileURLSendType(_ type: String) -> Bool {
        isWebURLSendType(type) || type.lowercased() == "public.file-url"
    }

    private static func isTextType(_ type: String) -> Bool {
        switch type.lowercased() {
        case "nsstringpboardtype", "nspasteboardtypestring", "public.utf8-plain-text", "public.plain-text", "public.text", "public.rtf", "nsrtfpboardtype": return true
        default: return false
        }
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
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "invalid-required-context" }
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
    private var storedExpired = false

    func expire() -> Bool {
        lock.lock()
        let completed = storedDone
        storedExpired = !completed
        lock.unlock()
        return completed
    }

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

    @discardableResult func finish(_ value: Bool) -> Bool {
        lock.lock()
        storedOK = value
        storedDone = true
        let expired = storedExpired
        lock.unlock()
        return expired
    }
}
