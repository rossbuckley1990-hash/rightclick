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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
#if os(Windows)
        XCTAssertEqual(root.path.withCString { rc_host_harden_private($0, 1) }, 0)
#else
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
#endif
    }
    override func tearDownWithError() throws {
#if os(Windows)
        for file in files { _ = file.path.withCString { rc_host_release_snapshot($0) } }
#endif
        try FileManager.default.removeItem(at: root)
    }
    private func file(_ name: String, _ bytes: Data) throws -> URL {
        let file = root.appendingPathComponent(name)
        try bytes.write(to: file, options: .withoutOverwriting); files.append(file)
#if os(Windows)
        XCTAssertEqual(file.path.withCString { rc_host_harden_private($0, 0) }, 0)
#else
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
#endif
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
        let command = Process()
        command.executableURL = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\icacls.exe")
        command.arguments = [selected.path, "/grant", "*S-1-1-0:(R)"]
        command.standardOutput = FileHandle.nullDevice; command.standardError = FileHandle.nullDevice
        try command.run(); command.waitUntilExit(); XCTAssertEqual(command.terminationStatus, 0)
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
