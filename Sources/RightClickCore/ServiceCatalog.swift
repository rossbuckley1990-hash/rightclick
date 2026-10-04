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
        let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")
        ExecutionLog.write("NSPerformService name=\(record.menuTitle) provider=\(record.bundleIdentifier ?? "") sendFileTypes=\(record.sendFileTypes) pasteboardTypes=\(types) main=\(Thread.isMainThread)")
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
            return record.sendTypes.contains { type in
                let lowered = type.lowercased()
                return lowered.contains("url")
            }
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
            return ServicePayload(text: nil, filePath: item.path)
        }
        if let text = item.text {
            return ServicePayload(text: text, filePath: nil)
        }
        if let path = item.path, item.kind == "text_file" || (item.utType?.conforms(to: .text) ?? false) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 1_000_000,
               let text = String(data: data, encoding: .utf8) {
                return ServicePayload(text: text, filePath: nil)
            }
        }
        if let path = item.path {
            return ServicePayload(text: nil, filePath: path)
        }
        return nil
    }

    private static func declare(_ payload: ServicePayload, on pasteboard: NSPasteboard, record: InstalledServiceRecord) {
        if let text = payload.text {
            let types: [NSPasteboard.PasteboardType] = [.string, NSPasteboard.PasteboardType("public.utf8-plain-text")]
            pasteboard.declareTypes(types, owner: nil)
            for type in types {
                pasteboard.setString(text, forType: type)
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
            _ = record
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
