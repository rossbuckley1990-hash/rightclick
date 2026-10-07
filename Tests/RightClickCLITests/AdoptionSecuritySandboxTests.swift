import Foundation
import XCTest
import RightClickCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RightClickCLI

final class AdoptionSecuritySandboxTests: XCTestCase {
    func testDisposableSandboxCannotImportHostPolicyObserversOrSigningReferences() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-sandbox-host-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = directory.appendingPathComponent("host-policy.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "revision": "production-host-only",
            "deniedCapabilities": ["sandbox:fixture:record_challenge"],
            "signingKeyFile": directory.appendingPathComponent("not-a-sandbox-key").path,
        ])
        try data.write(to: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        let previous = ProcessInfo.processInfo.environment["RIGHTCLICK_RCIR_CONFIG"]
        setenv("RIGHTCLICK_RCIR_CONFIG", configuration.path, 1)
        defer {
            if let previous { setenv("RIGHTCLICK_RCIR_CONFIG", previous, 1) }
            else { unsetenv("RIGHTCLICK_RCIR_CONFIG") }
        }

        let sandbox = try RightClickSandbox()
        let challenge = "isolated_sandbox_challenge"
        let actions = try sandbox.engine.capabilities(for: challenge).capabilities
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(actions.count, 1, "Only the disposable provider may enter the sandbox graph.")
        let denied = try sandbox.engine.begin(id: action.id, item: challenge,
            confirmed: false, arguments: ["challenge": challenge])
        XCTAssertEqual(denied.state, .awaitingUser)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path).isEmpty)
        let record = try sandbox.engine.begin(id: action.id, item: challenge,
            confirmed: true, arguments: ["challenge": challenge])
        XCTAssertEqual(record.state, .succeeded,
            "The disposable fixture must use its own confirmation policy and never load host key references: \(record.message)")
        XCTAssertTrue(record.evidence.outcomeVerified)
        XCTAssertNil(record.rcir?.signedReceipt,
            "Sandbox host receipts cannot carry production signatures imported from environment configuration.")
    }

    func testSandboxCleanupRemovesEffectAndDirectoryAfterFixtureLifetime() throws {
        var sandbox: RightClickSandbox? = try RightClickSandbox()
        let directory = try XCTUnwrap(sandbox?.directory)
        let challenge = "cleanup_sandbox_challenge"
        let action = try XCTUnwrap(sandbox?.engine.capabilities(for: challenge).capabilities.first)
        let record = try XCTUnwrap(sandbox?.engine.begin(id: action.id, item: challenge,
            confirmed: true, arguments: ["challenge": challenge]))
        XCTAssertEqual(record.state, .succeeded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        sandbox = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
