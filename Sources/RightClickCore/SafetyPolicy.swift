import Foundation

public enum SafetyPolicy {
    public static func classify(
        title: String,
        source: CapabilitySource,
        sendTypes: [String] = [],
        returnTypes: [String] = [],
        publicName: String? = nil
    ) -> (safety: CapabilitySafety, invocation: CapabilityInvocation, requiresConfirmation: Bool) {
        if source == .actionExtension {
            return (.unknown, .unsupported, true)
        }

        let haystack = ([title, publicName ?? ""] + sendTypes).joined(separator: " ").lowercased()

        if containsAny(haystack, ["purchase", "checkout", "subscribe", "apple pay"]) {
            return (.financial, .interactive, true)
        }

        if containsAny(haystack, ["delete", "trash", "erase", "overwrite", "empty trash"]) {
            return (.destructive, .interactive, true)
        }

        if containsAny(haystack, ["keychain", "password", "permission", "authentication", "firewall", "security", "grant access"]) {
            return (.securityChange, .interactive, true)
        }

        if containsAny(haystack, ["script", "execute", "shell", "eval", "run code"]) {
            return (.codeExecution, .interactive, true)
        }

        if containsAny(haystack, [
            "airdrop", "mail", "message", "messages", "facebook", "twitter", "weibo",
            "linkedin", "flickr", "vimeo", "post", "upload", "news", "journal",
            "freeform", "reminders", "simulator", "bluetooth",
        ]) {
            return (.externalShare, .interactive, true)
        }

        let textSend = sendTypes.contains { type in
            let lowered = type.lowercased()
            return lowered.contains("string") || lowered.contains("text") || lowered.contains("rtf")
        }
        if source == .service, !returnTypes.isEmpty, textSend {
            // A declared return representation says nothing about side effects.
            // Untrusted provider metadata may raise a risk classification, never
            // grant permission to execute without user authorisation.
            return (.unknown, .direct, true)
        }

        if source == .service, returnTypes.isEmpty {
            return (.unknown, .interactive, true)
        }

        if source == .sharingService {
            return (.externalShare, .interactive, true)
        }

        return (.unknown, .interactive, true)
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
