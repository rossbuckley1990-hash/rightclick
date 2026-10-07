// Standalone native Foundation diagnostic. This is fixture setup evidence,
// not a product authority gate or substitute for HostProtectedReferenceTests.
import Foundation

let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("rightclick-command-probe-" + UUID().uuidString)
try manager.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? manager.removeItem(at: root) }
let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
let powershell = "WindowsPowerShell\\v1.0\\powershell.exe"

func invoke(_ label: String, _ executable: String, _ arguments: [String]) throws -> Int32 {
    let output = root.appendingPathComponent(UUID().uuidString + ".log")
    try Data().write(to: output, options: .withoutOverwriting)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close(); try? manager.removeItem(at: output) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: system + "\\System32\\" + executable)
    process.arguments = arguments
    process.standardOutput = handle; process.standardError = handle
    try process.run(); process.waitUntilExit(); try handle.synchronize()
    let reader = try FileHandle(forReadingFrom: output)
    defer { try? reader.close() }
    let bytes = try reader.read(upToCount: 16_384) ?? Data()
    let diagnostic = String(decoding: bytes, as: UTF8.self)
        .replacingOccurrences(of: root.path, with: "<owned-fixture>")
        .replacingOccurrences(of: root.path.replacingOccurrences(of: "/", with: "\\"), with: "<owned-fixture>")
    let data = try JSONSerialization.data(withJSONObject: ["case": label, "exitCode": process.terminationStatus,
        "diagnostic": diagnostic, "scope": "fixture-setup-only"], options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    return process.terminationStatus
}

let target = root.appendingPathComponent("target", isDirectory: true)
try manager.createDirectory(at: target, withIntermediateDirectories: false)
let marker = Data("synthetic-command-fixture".utf8)
try marker.write(to: target.appendingPathComponent("marker"), options: .withoutOverwriting)
for nativeSeparators in [false, true] {
    let alias = root.appendingPathComponent(nativeSeparators ? "native-alias" : "original-alias", isDirectory: true)
    let path: (URL) -> String = { nativeSeparators ? $0.path.replacingOccurrences(of: "/", with: "\\") : $0.path }
    let result = try invoke(nativeSeparators ? "native-separator-mklink" : "original-foundation-mklink",
        "cmd.exe", ["/d", "/c", "mklink", "/J", path(alias), path(target)])
    let readback = (try? Data(contentsOf: alias.appendingPathComponent("marker"))) == marker
    let data = try JSONSerialization.data(withJSONObject: ["case": nativeSeparators ? "native-alias-readback" : "original-alias-readback",
        "commandSucceeded": result == 0, "exactMarkerRead": readback, "foundationPathHasSlash": alias.path.contains("/"),
        "scope": "fixture-setup-only"], options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    if result == 0 {
        _ = try invoke("remove-owned-junction", "cmd.exe", ["/d", "/c", "rmdir", path(alias)])
    }
}

let selected = root.appendingPathComponent("null-dacl")
try Data("synthetic-private-reference".utf8).write(to: selected, options: .withoutOverwriting)
let selectedPath = selected.path.replacingOccurrences(of: "'", with: "''")
_ = try invoke("assign-readonly-fixture", powershell, ["-NoProfile", "-NonInteractive", "-Command",
    "[System.IO.File]::SetAttributes('\(selectedPath)', [System.IO.FileAttributes]::ReadOnly)"])
_ = try invoke("original-null-dacl-script", powershell, ["-NoProfile", "-NonInteractive", "-Command",
    "$acl=Get-Acl -LiteralPath '\(selectedPath)'; $acl.SetSecurityDescriptorSddlForm('D:NO_ACCESS_CONTROL', [System.Security.AccessControl.AccessControlSections]::Access); Set-Acl -LiteralPath '\(selectedPath)' -AclObject $acl -ErrorAction Stop"])
_ = try invoke("release-owned-fixture", powershell, ["-NoProfile", "-NonInteractive", "-Command",
    "[System.IO.File]::SetAttributes('\(selectedPath)', [System.IO.FileAttributes]::Normal)"])
