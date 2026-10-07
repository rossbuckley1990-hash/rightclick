import AppKit
import Darwin
import Foundation

struct KnownSharingName {
    var name: NSSharingService.Name
    var status: SupportLevel
}

enum SharingCatalog {
    static let knownNames: [KnownSharingName] = [
        KnownSharingName(name: .composeEmail, status: .publicSupported),
        KnownSharingName(name: .composeMessage, status: .publicSupported),
        KnownSharingName(name: .sendViaAirDrop, status: .publicSupported),
        KnownSharingName(name: .addToSafariReadingList, status: .publicSupported),
        KnownSharingName(name: .addToIPhoto, status: .publicSupported),
        KnownSharingName(name: .addToAperture, status: .publicDeprecated),
        KnownSharingName(name: .useAsDesktopPicture, status: .publicSupported),
        KnownSharingName(name: .cloudSharing, status: .publicSupported),
    ]

    static func capabilities(for item: ContentItem) -> [Capability] {
        let items = pasteboardItems(for: item)
        guard !items.isEmpty else { return [] }
        let services = NSSharingService.sharingServices(forItems: items)
        return services.compactMap { service in
            guard service.canPerform(withItems: items) else { return nil }
            return capability(for: service)
        }
    }

    /// Invokes a discovered sharing service and returns when `perform(withItems:)` returns.
    /// The execution stays `started` or `awaiting_user` until a delegate callback or the deadline.
    static func launch(executionId: String, capabilityID: String, item: ContentItem) {
        let items = pasteboardItems(for: item)
        let services = NSSharingService.sharingServices(forItems: items)
        ExecutionLog.write("\(executionId) discovered services: \(services.map(\.title).joined(separator: ", "))")
        guard pthread_main_np() != 0 else {
            ExecutionStore.shared.update(executionId) { record in
                record.state = .failed
                record.message = "NSSharingService.perform(withItems:) was refused off the main thread."
                record.events.append("refused off main thread")
            }
            return
        }
        guard let service = services.first(where: { capability(for: $0).id == capabilityID && $0.canPerform(withItems: items) }) else {
            ExecutionStore.shared.update(executionId) { record in
                record.state = .failed
                record.message = "That sharing capability is not applicable to this item right now."
                record.events.append("service not resolved")
            }
            return
        }
        let built = capability(for: service)
        ExecutionLog.write("\(executionId) service resolved title=\(service.title) canPerform=true main=\(Thread.isMainThread)")
        let session = ShareSession(executionId: executionId, service: service)
        ShareExecutionRegistry.shared.keep(session)
        service.delegate = session
        session.mutate { model in
            model.serviceRetained()
            model.delegateRetained()
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate()
        let windowsBefore = app.windows.count
        session.mutate { $0.performEntered() }
        ExecutionLog.write("\(executionId) perform entered retained=\(ShareExecutionRegistry.shared.contains(executionId))")
        service.perform(withItems: items)
        session.mutate { model in
            model.performReturned()
            if app.windows.count > windowsBefore {
                model.noteAwaitingUser()
            }
        }
        if let current = ExecutionStore.shared.get(executionId), current.state == .started || current.state == .awaitingUser {
            session.armDeadline()
        }
        ExecutionLog.write("\(executionId) perform returned; execution still pending state=\(ExecutionStore.shared.get(executionId)?.state.rawValue ?? "")")
        _ = built
    }

    static func pasteboardItems(for item: ContentItem) -> [Any] {
        if let path = item.path {
            return [URL(fileURLWithPath: path) as NSURL]
        }
        if let urlString = item.url, let url = URL(string: urlString) {
            return [url as NSURL]
        }
        if let text = item.text {
            return [text as NSString]
        }
        return []
    }

    private static func capability(for service: NSSharingService) -> Capability {
        let matched = matchPublicName(service)
        let policy = SafetyPolicy.classify(
            title: service.title,
            source: .sharingService,
            publicName: matched?.rawValue
        )
        var metadata = [
            "menuItemTitle": service.menuItemTitle,
            "discoveryAPI": "NSSharingService.sharingServices(forItems:)",
        ]
        if let matched {
            metadata["publicName"] = matched.rawValue
        }
        return Capability(
            id: CapabilityID.sharing(title: service.title, publicName: matched?.rawValue),
            title: service.title,
            source: .sharingService,
            provider: CapabilityProvider(name: service.title, bundleIdentifier: matched?.rawValue),
            inputs: ["NSPasteboardWriting"],
            safety: policy.safety,
            invocation: policy.invocation,
            supportLevel: .publicDeprecated,
            requiresConfirmation: policy.requiresConfirmation,
            metadata: metadata
        )
    }

    private static func matchPublicName(_ service: NSSharingService) -> NSSharingService.Name? {
        for known in knownNames {
            guard let reference = NSSharingService(named: known.name) else { continue }
            if reference.title == service.title && reference.menuItemTitle == service.menuItemTitle {
                return known.name
            }
        }
        return nil
    }
}

enum ExecutionLog {
    static func write(_ line: String) {
        guard let destination = ProcessInfo.processInfo.environment["RIGHTCLICK_DIAGNOSTIC_LOG"], !destination.isEmpty else { return }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)"
        fputs(stamped + "\n", stderr)
        let url = URL(fileURLWithPath: destination)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = (stamped + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

private final class ShareExecutionRegistry {
    static let shared = ShareExecutionRegistry()
    private let lock = NSLock()
    private var sessions: [String: ShareSession] = [:]

    func keep(_ session: ShareSession) {
        lock.lock()
        sessions[session.executionId] = session
        lock.unlock()
    }

    func release(_ executionId: String) {
        lock.lock()
        sessions[executionId] = nil
        lock.unlock()
        ExecutionLog.write("\(executionId) session released")
    }

    func contains(_ executionId: String) -> Bool {
        lock.lock()
        let present = sessions[executionId] != nil
        lock.unlock()
        return present
    }
}

private final class ShareSession: NSObject, NSSharingServiceDelegate {
    let executionId: String
    let service: NSSharingService
    private var deadlineTimer: Timer?

    init(executionId: String, service: NSSharingService) {
        self.executionId = executionId
        self.service = service
    }

    func mutate(_ body: (inout SharingExecutionModel) -> Void) {
        ExecutionStore.shared.update(executionId) { record in
            var model = SharingExecutionModel()
            model.state = record.state
            model.events = record.events.isEmpty ? ["execution created"] : record.events
            let wasTerminal = model.isTerminal
            body(&model)
            record.state = model.state
            record.events = model.events
            record.message = model.message
            record.output = nil
            if model.state == .accepted {
                record.evidence = OutcomeEvidence(type: "provider_reported_completion", boundary: "NSSharingService didShareItems callback. Delivery or the intended external outcome has not been independently verified.")
            }
            if model.isTerminal && !wasTerminal {
                deadlineTimer?.invalidate()
                deadlineTimer = nil
                ShareExecutionRegistry.shared.release(executionId)
            }
        }
    }

    func armDeadline() {
        let executionId = self.executionId
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: SharingExecutionModel.deadline, repeats: false) { [weak self] _ in
            self?.mutate { $0.deadlineExpired() }
            ExecutionLog.write("\(executionId) deadline expired")
        }
    }

    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        let line = "willShareItems count=\(items.count) main=\(Thread.isMainThread)"
        mutate { $0.willShareItems(count: items.count, main: Thread.isMainThread) }
        ExecutionLog.write("\(executionId) \(line)")
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let line = "didShareItems count=\(items.count) main=\(Thread.isMainThread)"
        mutate { $0.didShareItems(count: items.count, main: Thread.isMainThread) }
        ExecutionLog.write("\(executionId) \(line)")
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let line = "didFailToShareItems \(error.localizedDescription) main=\(Thread.isMainThread)"
        mutate { $0.didFailToShareItems(error.localizedDescription, main: Thread.isMainThread) }
        ExecutionLog.write("\(executionId) \(line)")
    }
}
