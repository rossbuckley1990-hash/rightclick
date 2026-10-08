import Foundation
import XCTest
#if os(Linux)
import Glibc
#endif
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore

final class MCPAdmissionPositiveAndCredentialTests: XCTestCase {
    private final class Fixture {
        let directory: URL, process: Process, endpoint: String
        init() throws {
            let directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("mcp-authority-race-" + UUID().uuidString)
            self.directory = directory
            try NativeHTTPFixture.createPrivateDirectory(directory)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let process = Process(); self.process = process
            var initialized = false
            defer {
                if !initialized {
                    if process.isRunning { process.terminate(); process.waitUntilExit() }
                    try? NativeHTTPFixture.remove(directory)
                }
            }
            process.executableURL = try NativeHTTPFixture.python()
            process.arguments = [root.appendingPathComponent("Tests/Fixtures/mcp-admission-race.py").path, directory.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let port = directory.appendingPathComponent("port"), deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: port.path), Date() < deadline {
                guard process.isRunning else { throw RightClickError("MCP fixture exited") }
                Thread.sleep(forTimeInterval: 0.01)
            }
            endpoint = "http://127.0.0.1:" + (try String(contentsOf: port, encoding: .utf8)) + "/mcp"
            initialized = true
        }
        func close() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? NativeHTTPFixture.remove(directory)
        }
        var effects: Int {
            ((try? String(contentsOf: directory.appendingPathComponent("effects.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        func engine(scheme: String? = nil) throws -> (CapabilityEngine, RCIRExecutionHost) {
            let reflector = try MCPCapabilityArtifactResolver().resolve(.init(id: "credential-race", kind: "mcp", endpointURL: endpoint, authorityScheme: scheme))
            let host = RCIRExecutionHost(); host.configuration = { RCIRHostConfiguration() }; host.invocationJournal = { nil }
            return (.init(reflectors: [reflector], experience: nil, rcirHost: host), host)
        }
    }
    func testUnchangedMCPContractExecutesOneAdmittedEffectWithoutFabricatedVerification() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let (engine, _) = try fixture.engine()
        let capability = try XCTUnwrap(engine.capabilities(for: "effect").capabilities.first)
        let result = try engine.begin(id: capability.id, item: "effect", confirmed: true, arguments: ["challenge": "positive"])
        XCTAssertEqual(result.state, .accepted)
        XCTAssertTrue(result.rcir?.leaseConsumed == true)
        XCTAssertFalse(result.evidence.outcomeVerified)
        XCTAssertEqual(fixture.effects, 1)
    }
    func testMCPTokenRotationInsideFinalAdmissionDoesNotUsePreparedOldCredential() throws {
        try credentialChange(remove: false)
    }
    func testMCPTokenDeletionInsideFinalAdmissionDoesNotUsePreparedOldCredential() throws {
        try credentialChange(remove: true)
    }
    private func credentialChange(remove: Bool) throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let origin = try GraphQLHTTP.canonicalOrigin(URL(string: fixture.endpoint)!)
        let scheme = "mcp-reconciliation-" + UUID().uuidString
        let initialToken = "test-only-original-" + UUID().uuidString
        let replacementToken = "test-only-replacement-" + UUID().uuidString
        #if os(macOS)
        // Unique loopback origin/scheme, synthetic values only; never alter an
        // existing provider credential. Do not treat an unavailable Keychain as proof.
        do { try OpenAPIAuthorityStore.setBearerToken(initialToken, origin: origin, schemeName: scheme) }
        catch { throw XCTSkip("Native Keychain unavailable; MCP credential-rotation proof not established") }
        defer { _ = try? OpenAPIAuthorityStore.deleteBearerToken(origin: origin, schemeName: scheme) }
        let rotate: () throws -> Void = {
            if remove { _ = try OpenAPIAuthorityStore.deleteBearerToken(origin: origin, schemeName: scheme) }
            else { try OpenAPIAuthorityStore.setBearerToken(replacementToken, origin: origin, schemeName: scheme) }
        }
        #elseif os(Linux)
        let key = "RIGHTCLICK_MCP_RECONCILIATION_TOKEN_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let oldBindings = ProcessInfo.processInfo.environment[RuntimeEnvironmentAuthority.environmentKey]
        let bindings = try JSONSerialization.data(withJSONObject: [["origin": origin, "schemeName": scheme, "tokenEnvironment": key]])
        XCTAssertEqual(setenv(RuntimeEnvironmentAuthority.environmentKey, String(decoding: bindings, as: UTF8.self), 1), 0)
        XCTAssertEqual(setenv(key, initialToken, 1), 0)
        defer {
            unsetenv(key)
            if let oldBindings { setenv(RuntimeEnvironmentAuthority.environmentKey, oldBindings, 1) }
            else { unsetenv(RuntimeEnvironmentAuthority.environmentKey) }
        }
        let rotate: () throws -> Void = {
            if remove { XCTAssertEqual(unsetenv(key), 0) }
            else { XCTAssertEqual(setenv(key, replacementToken, 1), 0) }
        }
        #else
        throw XCTSkip("No native credential authority fixture on this host")
        #endif
        #if os(macOS) || os(Linux)
        let (engine, host) = try fixture.engine(scheme: scheme)
        let capability = try XCTUnwrap(engine.capabilities(for: "effect").capabilities.first)
        host.beforeStart = { _, admit, enqueue in
            try rotate()
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(enqueue) { start in try permit(start) }
            }
        }
        let result = try engine.begin(id: capability.id, item: "effect", confirmed: true, arguments: ["challenge": "no-stale-token"])
        XCTAssertEqual(result.state, .rejected)
        XCTAssertFalse(result.rcir?.leaseConsumed ?? false)
        XCTAssertEqual(fixture.effects, 0)
        #endif
    }
}
