#if os(macOS)
import Foundation

enum BundleScan {
    static let skipDirectoryNames: Set<String> = [
        "Resources", "MacOS", "_CodeSignature", "Frameworks", "SharedFrameworks",
        "Headers", "Modules", "Documentation", "Developer", "iOSSupport",
        "node_modules", "DerivedData", ".git",
    ]

    static func infoPlists(roots: [URL], bundleExtensions: Set<String>) -> [URL] {
        var results: [URL] = []
        var seen = Set<String>()
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            walk(root, depth: 0, bundleExtensions: bundleExtensions, results: &results, seen: &seen)
        }
        return results
    }

    static func standardServiceRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/System/Library/Services"),
            URL(fileURLWithPath: "/Library/Services"),
            home.appendingPathComponent("Library/Services"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            home.appendingPathComponent("Applications"),
        ]
    }

    static func standardExtensionRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            URL(fileURLWithPath: "/System/Library/Frameworks"),
            URL(fileURLWithPath: "/System/Library/PrivateFrameworks"),
            URL(fileURLWithPath: "/Library/Application Support"),
            home.appendingPathComponent("Library/Application Support"),
        ]
    }

    private static func walk(
        _ url: URL,
        depth: Int,
        bundleExtensions: Set<String>,
        results: inout [URL],
        seen: inout Set<String>
    ) {
        if depth > 8 { return }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard seen.insert(resolved.path).inserted else { return }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let name = child.lastPathComponent
            let ext = child.pathExtension
            if bundleExtensions.contains(ext) {
                let info = child.appendingPathComponent("Contents/Info.plist")
                if FileManager.default.fileExists(atPath: info.path) {
                    results.append(info)
                }
                for nested in ["Contents/PlugIns", "Contents/Extensions", "Contents/Applications", "Contents/Library", "PlugIns", "Extensions", "Versions"] {
                    let next = child.appendingPathComponent(nested)
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: next.path, isDirectory: &isDirectory), isDirectory.boolValue || isSymlink(next) {
                        walk(next, depth: depth + 1, bundleExtensions: bundleExtensions, results: &results, seen: &seen)
                    }
                }
                continue
            }
            if skipDirectoryNames.contains(name) { continue }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
            if exists && (isDirectory.boolValue || isSymlink(child)) {
                walk(child, depth: depth + 1, bundleExtensions: bundleExtensions, results: &results, seen: &seen)
            }
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}

func loadPropertyList(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
}

func stringList(_ value: Any?) -> [String] {
    (value as? [Any])?.compactMap { $0 as? String } ?? []
}

#endif
