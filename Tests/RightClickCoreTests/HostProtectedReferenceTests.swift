import Foundation
import XCTest
import RightClickHostFiles
@testable import RightClickCore

/// These are actual filesystem boundaries, not fabricated authority outcomes.
final class HostProtectedReferenceTests: XCTestCase {
    private var root: URL!
    private var files: [URL] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("host-reference-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(root)
    }
    override func tearDownWithError() throws {
#if os(Windows)
        for file in files { _ = file.path.withCString { rc_host_release_snapshot($0) } }
#endif
        try FileManager.default.removeItem(at: root)
    }
    private func file(_ name: String, _ bytes: Data) throws -> URL {
        let file = root.appendingPathComponent(name)
        try NativeHTTPFixture.writePrivate(bytes, to: file); files.append(file)
        return file
    }
    func testConfiguredPolicySigningAndObserverReferencesUseOneProtectedBackend() throws {
        let fixtures: [(String, Data)] = [
            ("policy.json", Data(#"{"version":1,"revision":"native-test","deniedCapabilities":[]}"#.utf8)),
            ("signing-key.raw", Data(repeating: 17, count: 32)),
            ("observer.token", Data("dummy-private-observer-token".utf8)),
        ]
        for (name, bytes) in fixtures {
            let selected = try file(name, bytes)
            XCTAssertEqual(try RCIRHostConfiguration.protectedRead(selected.path, maximum: 1024), bytes)
            XCTAssertEqual(try CapabilityProtectedReference.read(selected.path, maximum: 1024), bytes)
        }
    }
    func testBroaderNativeReadAuthorityIsDenied() throws {
        let selected = try file("broader-reference", Data("dummy-private-reference".utf8))
#if os(Windows)
        for grant in ["*S-1-1-0:(R)", "*S-1-1-0:(F)"] {
            try nativeCommand("icacls.exe", [selected.path, "/grant", grant])
            XCTAssertThrowsError(try RCIRHostConfiguration.protectedRead(selected.path, maximum: 1024))
            XCTAssertThrowsError(try CapabilityProtectedReference.read(selected.path, maximum: 1024))
            XCTAssertEqual(selected.path.withCString { rc_host_harden_private($0, 0) }, 0)
        }
        try nativeCommand("icacls.exe", [selected.path, "/grant", "*S-1-1-0:(R)"])
#else
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: selected.path)
#endif
        XCTAssertThrowsError(try RCIRHostConfiguration.protectedRead(selected.path, maximum: 1024))
        XCTAssertThrowsError(try CapabilityProtectedReference.read(selected.path, maximum: 1024))
#if os(Windows)
        // Restore only this test-owned object's ACL for bounded cleanup.
        XCTAssertEqual(selected.path.withCString { rc_host_harden_private($0, 0) }, 0)
#endif
    }
#if os(Windows)
    func testPrivateCreationNeverOverwritesOrAdoptsExistingObjects() throws {
        let original = Data("dummy-private-reference".utf8)
        let selected = try file("existing-reference", original)
        let replacement = Data("replacement-must-not-be-written".utf8)
        let result = replacement.withUnsafeBytes { bytes in
            selected.path.withCString { rc_host_create_private_file($0, bytes.bindMemory(to: UInt8.self).baseAddress, replacement.count) }
        }
        XCTAssertNotEqual(result, 0)
        XCTAssertEqual(try CapabilityProtectedReference.read(selected.path, maximum: 1024), original)
        XCTAssertNotEqual(root.path.withCString { rc_host_create_private_directory($0) }, 0)
    }
    func testPrivateCreationThroughParentJunctionCreatesNoTargetObjects() throws {
        let actual = root.appendingPathComponent("creation-target", isDirectory: true)
        try NativeHTTPFixture.createPrivateDirectory(actual)
        let alias = root.appendingPathComponent("creation-alias", isDirectory: true)
        try nativeCommand("cmd.exe", ["/c", "mklink", "/J", alias.path, actual.path])
        defer { try? FileManager.default.removeItem(at: alias) }
        let file = alias.appendingPathComponent("new-reference")
        let bytes = Data("must-not-reach-redirected-target".utf8)
        let result = bytes.withUnsafeBytes { buffer in
            file.path.withCString { rc_host_create_private_file($0, buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
        }
        XCTAssertNotEqual(result, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: actual.appendingPathComponent("new-reference").path))
        XCTAssertNotEqual(alias.appendingPathComponent("new-directory").path.withCString { rc_host_create_private_directory($0) }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: actual.appendingPathComponent("new-directory").path))
    }
    func testReleaseClearsReadOnlyOnlyAttributeAndAllowsActualRemoval() throws {
        let selected = try file("readonly-only", Data("dummy-private-reference".utf8))
        let path = selected.path.replacingOccurrences(of: "'", with: "''")
        try nativeCommand("WindowsPowerShell\\v1.0\\powershell.exe", ["-NoProfile", "-NonInteractive", "-Command",
            "[System.IO.File]::SetAttributes('\(path)', [System.IO.FileAttributes]::ReadOnly)"])
        XCTAssertEqual(selected.path.withCString { rc_host_release_snapshot($0) }, 0)
        try nativeCommand("WindowsPowerShell\\v1.0\\powershell.exe", ["-NoProfile", "-NonInteractive", "-Command",
            "if (([System.IO.File]::GetAttributes('\(path)') -band [System.IO.FileAttributes]::ReadOnly) -ne 0) { exit 1 }"])
        try FileManager.default.removeItem(at: selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
    }
    private func nativeCommand(_ executable: String, _ arguments: [String]) throws {
        let command = Process()
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        command.executableURL = URL(fileURLWithPath: system + "\\System32\\" + executable)
        command.arguments = arguments
        // Retain bounded fixture diagnostics without blocking a child on a pipe.
        // These commands operate only on this test's synthetic owned paths.
        let output = root.appendingPathComponent("command-" + UUID().uuidString + ".log")
        try Data().write(to: output, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        command.standardOutput = handle; command.standardError = handle
        try command.run(); command.waitUntilExit()
        try handle.synchronize()
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let bytes = try reader.read(upToCount: 16_384) ?? Data()
        let diagnostic = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: root.path, with: "<owned-fixture>")
            .replacingOccurrences(of: root.path.replacingOccurrences(of: "/", with: "\\"), with: "<owned-fixture>")
        XCTAssertEqual(command.terminationStatus, 0, "Native fixture command \(executable): \(diagnostic)")
        guard command.terminationStatus == 0 else { throw RCIRError.authorityDenied }
    }
    func testNullDACLNeverBecomesProtectedAuthority() throws {
        let selected = try file("null-dacl", Data("dummy-private-reference".utf8))
        let path = selected.path.replacingOccurrences(of: "'", with: "''")
        let script = "$acl=Get-Acl -LiteralPath '\(path)'; $acl.SetSecurityDescriptorSddlForm('D:NO_ACCESS_CONTROL', [System.Security.AccessControl.AccessControlSections]::Access); Set-Acl -LiteralPath '\(path)' -AclObject $acl -ErrorAction Stop"
        try nativeCommand("WindowsPowerShell\\v1.0\\powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script])
        XCTAssertThrowsError(try RCIRHostConfiguration.protectedRead(selected.path, maximum: 1024))
        XCTAssertThrowsError(try CapabilityProtectedReference.read(selected.path, maximum: 1024))
        XCTAssertEqual(selected.path.withCString { rc_host_harden_private($0, 0) }, 0)
    }
    func testParentDirectoryJunctionCannotRedirectProtectedReference() throws {
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        try NativeHTTPFixture.createPrivateDirectory(actual)
        let selected = actual.appendingPathComponent("reference")
        try NativeHTTPFixture.writePrivate(Data("dummy-private-reference".utf8), to: selected)
        files.append(selected)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try nativeCommand("cmd.exe", ["/c", "mklink", "/J", alias.path, actual.path])
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertThrowsError(try CapabilityProtectedReference.read(alias.appendingPathComponent("reference").path, maximum: 1024))
        XCTAssertEqual(try CapabilityProtectedReference.read(selected.path, maximum: 1024), Data("dummy-private-reference".utf8))
    }
#endif
    func testDirectoriesAndOversizedFilesNeverBecomeReferences() throws {
        XCTAssertThrowsError(try CapabilityProtectedReference.read(root.path, maximum: 64))
        let selected = try file("oversized-reference", Data(repeating: 19, count: 65))
        XCTAssertThrowsError(try RCIRHostConfiguration.protectedRead(selected.path, maximum: 64))
    }
    func testPrivateSnapshotRetainsExactBytesWhenSelectedSourceChanges() throws {
        let selected = try file("artifact", Data("original artifact".utf8))
        let snapshot = try CapabilityArtifactSnapshot(source: selected, maximum: 1024, protected: true)
#if os(Windows)
        XCTAssertEqual(selected.path.withCString { rc_host_release_snapshot($0) }, 0)
#endif
        try Data("changed artifact".utf8).write(to: selected)
        XCTAssertFalse(snapshot.sourceStillMatches())
        XCTAssertEqual(try CapabilityProtectedReference.read(snapshot.file.path, maximum: 1024), Data("original artifact".utf8))
    }
}
