#if os(macOS)
import Foundation
import CoreFoundation

/// NSServices context conditions are data, never authorisation instructions.
/// Unknown selection-language/script constraints abstain: the runtime has no
/// native text-selection language/script evidence to satisfy them.
enum ServiceContext {
    static func accepts(_ encoded: String?, item: ContentItem) -> Bool {
        guard let encoded else { return true }
        guard let data = encoded.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let dictionary = value as? [String: Any] { return matches(dictionary, item: item) }
        if let alternatives = value as? [[String: Any]], !alternatives.isEmpty {
            return alternatives.contains { matches($0, item: item) }
        }
        return false
    }

    static func requiresFilePath(_ encoded: String?, item: ContentItem) -> Bool {
        guard let encoded, let data = encoded.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return false }
        let contexts = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
        return contexts.contains { context in
            matches(context, item: item) &&
                (strings(context["NSTextContent"] ?? context["NSTextContext"])?.contains("FilePath") ?? false)
        }
    }

    private static func matches(_ context: [String: Any], item: ContentItem) -> Bool {
        let selected = item.text ?? item.url ?? item.path ?? ""
        return context.allSatisfy { key, value in
            switch key {
            case "NSApplicationIdentifier":
                guard let allowed = strings(value), let host = Bundle.main.bundleIdentifier else { return false }
                return allowed.contains(host)
            case "NSWordLimit":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue else { return false }
                var words = 0
                selected.enumerateSubstrings(in: selected.startIndex..<selected.endIndex, options: .byWords) { _, _, _, _ in words += 1 }
                return Double(words) <= number.doubleValue
            case "NSTextContent", "NSTextContext":
                guard let contents = strings(value) else { return false }
                return contents.contains { contains($0, selected: selected, item: item) }
            case "NSServiceCategory":
                // This describes menu grouping rather than an applicability restriction.
                return value is String
            default:
                return false
            }
        }
    }

    private static func strings(_ value: Any?) -> [String]? {
        if let value = value as? String, !value.isEmpty { return [value] }
        if let values = value as? [String], !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) { return values }
        return nil
    }

    private static func contains(_ kind: String, selected: String, item: ContentItem) -> Bool {
        if kind == "FilePath" {
            if item.path != nil { return true }
            // Accept a complete existing absolute path; mixed prose/path selections
            // have no unambiguous path representation in this runtime.
            let path = (selected as NSString).expandingTildeInPath
            return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path)
        }
        let type: NSTextCheckingResult.CheckingType
        switch kind {
        case "URL", "Email": type = .link
        case "Date": type = .date
        case "Address": type = .address
        default: return false
        }
        guard let detector = try? NSDataDetector(types: type.rawValue) else { return false }
        return detector.matches(in: selected, range: NSRange(selected.startIndex..<selected.endIndex, in: selected)).contains {
            if kind == "Email" { return $0.url?.scheme == "mailto" }
            if kind == "URL" { return $0.url?.scheme != "mailto" }
            return true
        }
    }
}

#endif
