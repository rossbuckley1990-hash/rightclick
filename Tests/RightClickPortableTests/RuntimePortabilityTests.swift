import Foundation
import XCTest
@testable import RightClickCore
import RightClickMCP

final class RuntimePortabilityTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/portable-fixture-home", isDirectory: true)
    private func environment(_ rows: [[String: String]]) throws -> [String: String] {
        [RuntimeEnvironmentAuthority.environmentKey: String(decoding: try JSONEncoder().encode(rows), as: UTF8.self), "TEST_TOKEN": "fixture-token"]
    }
    private var row: [String: String] { ["origin": "https://api.example.test", "schemeName": "fixture", "tokenEnvironment": "TEST_TOKEN"] }
    private func config(_ args: [String]) throws -> [String: Any] {
        let text = try RuntimeClientConfiguration.render(arguments: args, executable: "/fixture/rightclick")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    func testMacPathsRemainCompatible() {
        XCTAssertEqual(RuntimePlatform.supportDirectory(home: home, environment: [:], platform: .macOS).path, home.path + "/Library/Application Support/RIGHTCLICK")
        XCTAssertEqual(RuntimePlatform.logDirectory(home: home, environment: [:], platform: .macOS).path, home.path + "/Library/Logs/RIGHTCLICK")
    }
    func testLinuxDefaultPaths() {
        XCTAssertEqual(RuntimePlatform.supportDirectory(home: home, environment: [:], platform: .linux).path, home.path + "/.config/rightclick")
        XCTAssertEqual(RuntimePlatform.logDirectory(home: home, environment: [:], platform: .linux).path, home.path + "/.local/state/rightclick/logs")
    }
    func testLinuxXDGOverridesMustBeAbsolute() {
        XCTAssertEqual(RuntimePlatform.supportDirectory(home: home, environment: ["XDG_CONFIG_HOME": "/fixture/config"], platform: .linux).path, "/fixture/config/rightclick")
        for bad in ["relative", "", " /wrong", "/wrong\0"] {
            XCTAssertEqual(RuntimePlatform.supportDirectory(home: home, environment: ["XDG_CONFIG_HOME": bad], platform: .linux).path, home.path + "/.config/rightclick")
        }
    }
    func testWindowsFallbackHasNoMacPath() {
        let path = RuntimePlatform.supportDirectory(home: home, environment: ["APPDATA": "relative"], platform: .windows).path
        XCTAssertTrue(path.hasSuffix("AppData/Roaming/RIGHTCLICK")); XCTAssertFalse(path.contains("Library"))
    }
    func testAuthorityIsBoundToOriginAndScheme() throws {
        let env = try environment([row])
        XCTAssertEqual(try RuntimeEnvironmentAuthority.token(origin: "https://api.example.test:443/", schemeName: "fixture", environment: env), "fixture-token")
        XCTAssertNil(try RuntimeEnvironmentAuthority.token(origin: "https://other.example.test", schemeName: "fixture", environment: env))
        XCTAssertNil(try RuntimeEnvironmentAuthority.token(origin: "https://api.example.test", schemeName: "other", environment: env))
    }
    func testDuplicateAuthorityFailsClosed() throws {
        let env = try environment([row, row])
        XCTAssertThrowsError(try RuntimeEnvironmentAuthority.token(origin: "https://api.example.test", schemeName: "fixture", environment: env))
    }
    func testInvalidAuthorityConfigurationDoesNotFallback() throws {
        for raw in ["broken", "{}", "null", "[1]", String(repeating: "x", count: 65_537)] {
            XCTAssertThrowsError(try RuntimeEnvironmentAuthority.token(origin: "https://api.example.test", schemeName: "fixture", environment: [RuntimeEnvironmentAuthority.environmentKey: raw]))
        }
    }
    func testAuthorityRejectsUnknownFieldsUnsafeOriginsAndEnvironmentNames() throws {
        for (key, value) in [("unexpected", "x"), ("origin", "http://api.example.test"), ("tokenEnvironment", "TOKEN;cmd")] {
            var bad = row; bad[key] = value
            XCTAssertThrowsError(try RuntimeEnvironmentAuthority.token(origin: "https://api.example.test", schemeName: "fixture", environment: environment([bad])))
        }
    }
    func testMissingAuthorityIsUnavailable() throws {
        XCTAssertNil(try RuntimeEnvironmentAuthority.token(origin: "https://api.example.test", schemeName: "fixture", environment: [:]))
        var env = try environment([row]); env.removeValue(forKey: "TEST_TOKEN")
        XCTAssertNil(try RuntimeEnvironmentAuthority.token(origin: "https://api.example.test", schemeName: "fixture", environment: env))
    }
    func testUnsafeTokenNeverReachesTransport() throws {
        for token in ["", "header\r\ninjection", String(repeating: "a", count: 1_048_577)] {
            var env = try environment([row]); env["TEST_TOKEN"] = token
            XCTAssertThrowsError(try RuntimeEnvironmentAuthority.token(origin: "https://api.example.test", schemeName: "fixture", environment: env))
        }
    }
    func testBasicConnectConfigurationIsDeterministicAndSecretFree() throws {
        let first = try RuntimeClientConfiguration.render(arguments: [], executable: "/fixture/rightclick")
        XCTAssertEqual(first, try RuntimeClientConfiguration.render(arguments: [], executable: "/fixture/rightclick"))
        let servers = try XCTUnwrap(try config([])["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["rightclick"]?["args"] as? [String], ["mcp"])
        XCTAssertNil(servers["rightclick"]?["env"])
    }
    func testConnectProducesExistingGenericArtifactEnvelope() throws {
        let root = try config(["--openapi", "https://api.example.test/openapi.json", "--base-url", "https://api.example.test", "--id", "test"])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: [String: Any]])
        let env = try XCTUnwrap(servers["rightclick"]?["env"] as? [String: String])
        let raw = try XCTUnwrap(env[ConfiguredCapabilityArtifactSource.environmentKey])
        let descriptors = try JSONDecoder().decode([CapabilityArtifactDescriptor].self, from: Data(raw.utf8))
        XCTAssertEqual(descriptors.count, 1); XCTAssertEqual(descriptors[0].kind, "openapi")
        XCTAssertEqual(descriptors[0].id, "test")
    }
    func testConnectRejectsAmbiguousOrUnsafeConfiguration() {
        let bad = [["--unknown"], ["--graphql"], ["--openapi", "https://example.test/spec"],
            ["--graphql", "http://example.test/graphql"], ["--graphql", "https://u:p@example.test/g"],
            ["--graphql", "https://example.test/g", "--graphql", "https://example.test/g"],
            ["--graphql", "https://example.test/g", "--grpc", "grpc://127.0.0.1:9000"], ["--id", "x"]]
        for args in bad { XCTAssertThrowsError(try RuntimeClientConfiguration.render(arguments: args)) }
    }
    func testSevenMCPToolNamesArePreserved() {
        XCTAssertEqual(RightClickMCPContract.toolNames(), ["context_runtime", "context_inspect", "context_actions", "context_explain", "context_run", "context_run_status", "context_providers"].sorted())
    }
    func testPortableFileObservationAndTextVerification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("data.bin"); try Data("data".utf8).write(to: file)
        let item = try ContentParser.parse(file.path)
        let snapshot = try OutcomeVerifier.snapshot(item: item)
        XCTAssertTrue(snapshot.fileExists); XCTAssertEqual(snapshot.fileSize, 4)
        XCTAssertEqual(snapshot.fileSHA256, "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7")
        let checked = try OutcomeVerifier.verify(spec: .init(predicates: [.init(type: .fileExists)]), item: item, before: snapshot, returnedText: nil)
        XCTAssertEqual(checked.status, .verifiedSuccess)
    }
#if !os(macOS)
    func testHeadlessHostDoesNotInventDesktopCapabilities() throws {
        let engine = CapabilityEngine(experience: nil)
        XCTAssertTrue(try engine.capabilities(for: "fixture").capabilities.isEmpty)
        XCTAssertFalse(RuntimePlatform.report().nativeDesktopServices)
    }
    func testMissingNativeObserversCannotVerifyAbsence() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("plain".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let item = try ContentParser.parse(file.path); let before = try OutcomeVerifier.snapshot(item: item)
        for predicate in [VerificationPredicate(type: .xattrAbsent, key: "fixture"),
                          .init(type: .metadataValueAbsent, value: "secret"), .init(type: .dimensionsEqual, width: 1, height: 1)] {
            let result = try OutcomeVerifier.verify(spec: .init(predicates: [predicate]), item: item, before: before, returnedText: nil)
            XCTAssertNotEqual(result.status, .verifiedSuccess)
            XCTAssertFalse(result.predicates.allSatisfy { $0.evaluated && $0.passed })
        }
    }
#endif
}

