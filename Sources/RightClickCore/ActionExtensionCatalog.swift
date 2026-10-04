import Foundation
import UniformTypeIdentifiers

struct ActionExtensionRecord {
    var name: String?
    var bundleIdentifier: String?
    var bundlePath: String
    var activationRule: String
    var activationRuleKind: String
    var roleType: String?
    var allowsFinderPreview: Bool
    var applicability: String
}

enum ActionExtensionCatalog {
    static func records() -> [ActionExtensionRecord] {
        var found: [ActionExtensionRecord] = []
        for infoURL in BundleScan.infoPlists(roots: BundleScan.standardExtensionRoots(), bundleExtensions: ["appex"]) {
            guard let plist = loadPropertyList(at: infoURL),
                  let ext = plist["NSExtension"] as? [String: Any],
                  (ext["NSExtensionPointIdentifier"] as? String) == "com.apple.ui-services"
            else { continue }
            let attributes = ext["NSExtensionAttributes"] as? [String: Any] ?? [:]
            let (ruleText, ruleKind) = describeRule(attributes["NSExtensionActivationRule"])
            if ruleKind == "true_predicate" { continue }
            let bundleURL = infoURL.deletingLastPathComponent().deletingLastPathComponent()
            found.append(ActionExtensionRecord(
                name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String,
                bundleIdentifier: plist["CFBundleIdentifier"] as? String,
                bundlePath: bundleURL.path,
                activationRule: ruleText,
                activationRuleKind: ruleKind,
                roleType: attributes["NSExtensionServiceRoleType"] as? String,
                allowsFinderPreview: (attributes["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool) ?? false,
                applicability: "pending"
            ))
        }
        return found
    }

    static func capabilities(for item: ContentItem, records: [ActionExtensionRecord]? = nil) -> [Capability] {
        (records ?? self.records()).compactMap { record in
            let applicability = applies(rule: record.activationRule, kind: record.activationRuleKind, item: item)
            guard applicability == .applies else { return nil }
            let policy = SafetyPolicy.classify(title: record.name ?? record.bundleIdentifier ?? "Action", source: .actionExtension)
            return Capability(
                id: CapabilityID.actionExtension(bundleIdentifier: record.bundleIdentifier, path: record.bundlePath),
                title: record.name ?? record.bundleIdentifier ?? "Action Extension",
                source: .actionExtension,
                provider: CapabilityProvider(name: record.name, bundleIdentifier: record.bundleIdentifier),
                inputs: [item.typeIdentifier ?? "public.item"],
                safety: policy.safety,
                invocation: .unsupported,
                supportLevel: .publicSupported,
                requiresConfirmation: true,
                metadata: [
                    "bundlePath": record.bundlePath,
                    "activationRuleKind": record.activationRuleKind,
                    "activationRule": String(record.activationRule.prefix(500)),
                    "discoverySource": "NSExtension Info.plist",
                    "invocation": "No public direct invocation API. NSExtension is not in the macOS SDK.",
                    "roleType": record.roleType ?? "",
                ]
            )
        }
    }

    static func applies(rule: String, kind: String, item: ContentItem) -> RuleApplicability {
        switch kind {
        case "dictionary":
            guard let data = rule.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .unknown }
            return applies(dictionary: dictionary, item: item)
        case "predicate":
            return applies(predicate: rule, item: item)
        default:
            return .unknown
        }
    }

    private static func applies(dictionary: [String: Any], item: ContentItem) -> RuleApplicability {
        func maxCount(_ key: String) -> Int? {
            if let value = dictionary[key] as? Int { return value }
            if let value = dictionary[key] as? NSNumber { return value.intValue }
            return nil
        }
        let image = maxCount("NSExtensionActivationSupportsImageWithMaxCount")
        let movie = maxCount("NSExtensionActivationSupportsMovieWithMaxCount")
        let web = maxCount("NSExtensionActivationSupportsWebURLWithMaxCount")
        let webpage = maxCount("NSExtensionActivationSupportsWebPageWithMaxCount")
        let file = maxCount("NSExtensionActivationSupportsFileWithMaxCount")
        let attachments = maxCount("NSExtensionActivationSupportsAttachmentsWithMaxCount")
        let text = dictionary["NSExtensionActivationSupportsText"] as? Bool
        if ContentParser.conforms(item, to: .image) {
            if let image { return image > 0 ? .applies : .doesNotApply }
            if (file ?? 0) > 0 || (attachments ?? 0) > 0 { return .applies }
            return .doesNotApply
        }
        if ContentParser.conforms(item, to: .movie) || ContentParser.conforms(item, to: .video) {
            if let movie { return movie > 0 ? .applies : .doesNotApply }
            if (file ?? 0) > 0 || (attachments ?? 0) > 0 { return .applies }
            return .doesNotApply
        }
        if ContentParser.conforms(item, to: .pdf) {
            if (file ?? 0) > 0 || (attachments ?? 0) > 0 { return .applies }
            return .doesNotApply
        }
        if item.kind == "text" || item.kind == "text_file" || ContentParser.conforms(item, to: .text) {
            if text == true { return .applies }
            if (file ?? 0) > 0 || (attachments ?? 0) > 0 { return .applies }
            return .doesNotApply
        }
        if item.url != nil {
            if (web ?? 0) > 0 || (webpage ?? 0) > 0 { return .applies }
            return .doesNotApply
        }
        return .unknown
    }

    private static func applies(predicate: String, item: ContentItem) -> RuleApplicability {
        let pattern = #"UTI-(?:CONFORMS-TO|EQUALS)\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern), let type = item.utType else { return .unknown }
        let range = NSRange(predicate.startIndex..<predicate.endIndex, in: predicate)
        let matches = regex.matches(in: predicate, range: range)
        if matches.isEmpty { return .unknown }
        var hit = false
        var sawType = false
        for match in matches {
            guard let swiftRange = Range(match.range(at: 1), in: predicate) else { continue }
            let identifier = String(predicate[swiftRange])
            guard let mentioned = UTType(identifier) else { continue }
            sawType = true
            if type.conforms(to: mentioned) || type.identifier == mentioned.identifier {
                hit = true
            }
        }
        if !sawType { return .unknown }
        return hit ? .applies : .doesNotApply
    }

    private static func describeRule(_ value: Any?) -> (String, String) {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return (string, trimmed == "TRUEPREDICATE" ? "true_predicate" : "predicate")
        case let dictionary as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return (text, "dictionary")
            }
            return (String(describing: dictionary), "dictionary")
        default:
            return ("", "missing")
        }
    }
}

enum RuleApplicability: String {
    case applies
    case doesNotApply
    case unknown
}
