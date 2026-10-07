import Foundation
struct RightClickOnboardingError: Error { init(_ message: String) {} }
enum RightClickJSONConfigBackend {
    static func configurationAncestors(_ file: URL, maximumDepth: Int = 512) throws -> [URL] {
        var path = file.standardizedFileURL
        var visited = Set<String>()
        var ancestors: [URL] = []
        while true {
            guard ancestors.count < maximumDepth, visited.insert(path.path).inserted else {
                throw RightClickOnboardingError("Configuration path exceeds the bounded ancestor inspection limit.")
            }
            ancestors.append(path)
            if path.path == "/" { break }
            let parent = URL(fileURLWithPath: path.path, isDirectory: true).deletingLastPathComponent()
            if parent.path == path.path { break }
            path = parent
        }
        return ancestors
    }

 }
let start = Date()
for target in ["/", "/..", "/private/tmp/rightclick-path-walk/nonexistent/config.json", "/private/tmp/../../tmp/../"] {
    let values = try RightClickJSONConfigBackend.configurationAncestors(URL(fileURLWithPath: target, isDirectory: false))
    precondition(values.last?.path == "/")
    precondition(values.count <= 7)
    precondition(Set(values.map(\.path)).count == values.count)
    print("PASS bounded ancestor walk: \(target), \(values.count) unique ancestors, root reached")
}
let aliases = try RightClickJSONConfigBackend.configurationAncestors(URL(fileURLWithPath: "/private/tmp/rightclick-path-walk/nonexistent/config.json"))
precondition(aliases.contains { $0.path == "/private/tmp" })
print("PASS lexical /private/tmp retained for symlink inspection")
do {
    _ = try RightClickJSONConfigBackend.configurationAncestors(URL(fileURLWithPath: "/a/b/c/config.json"), maximumDepth: 2)
    fatalError("Depth limit accepted a deeper path")
} catch { print("PASS explicit depth limit abstains") }
precondition(Date().timeIntervalSince(start) < 1)
