import AppKit
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

    static func perform(capabilityID: String, item: ContentItem) -> RunResult {
        let items = pasteboardItems(for: item)
        let services = NSSharingService.sharingServices(forItems: items)
        guard let service = services.first(where: { capability(for: $0).id == capabilityID && $0.canPerform(withItems: items) }) else {
            return RunResult(
                status: .failed,
                actionID: capabilityID,
                message: "That sharing capability is not applicable to this item right now."
            )
        }
        let built = capability(for: service)
        let delegate = ShareCallback()
        service.delegate = delegate
        service.perform(withItems: items)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && delegate.events.isEmpty {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let invoked = !delegate.events.isEmpty
        return RunResult(
            status: invoked ? .executed : .executed,
            actionID: built.id,
            title: built.title,
            message: invoked
                ? "macOS invoked \(built.title). \(delegate.events.joined(separator: "; "))"
                : "macOS accepted perform(withItems:) for \(built.title) without a delegate callback.",
            output: delegate.events.joined(separator: "\n"),
            supportLevel: .publicDeprecated
        )
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

private final class ShareCallback: NSObject, NSSharingServiceDelegate {
    var events: [String] = []

    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        events.append("willShareItems")
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        events.append("didShareItems")
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        events.append("didFailToShareItems: \(error.localizedDescription)")
    }
}
