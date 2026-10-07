import Foundation
import XCTest
import RightClickCore
@testable import RightClickCLI

final class PortableClientLifecycleTests: XCTestCase {
    private struct Fixture {
        let home: URL
        let oldBinary: URL
        let newBinary: URL
        let configuration: URL
        init() throws {
            home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("rightclick-lifecycle-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
#if os(Windows)
            oldBinary = home.appendingPathComponent("old/rightclick.exe")
            newBinary = home.appendingPathComponent("new/rightclick.exe")
#else
            oldBinary = home.appendingPathComponent("old/rightclick")
            newBinary = home.appendingPathComponent("new/rightclick")
#endif
            configuration = home.appendingPathComponent("client/mcp.json")
            for binary in [oldBinary, newBinary] {
                try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(binary.path.utf8).write(to: binary)
#if !os(Windows)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
#endif
            }
        }
        func cleanup() { try? FileManager.default.removeItem(at: home) }
        func prepared(binary: URL? = nil) throws -> RightClickSetupAllTransaction.PreparedClient {
            let adapter = RightClickGenericClientAdapter(file: configuration)
            return .init(adapter: adapter, plan: try RightClickOnboardingEngine.plan(adapter: adapter,
                home: home, executable: (binary ?? oldBinary).path))
        }
    }

    private func entry(_ file: URL) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        return try XCTUnwrap(servers["rightclick"] as? [String: Any])
    }

    func testConfigurationPathInspectionTerminatesAtRoot() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let start = Date()
        let ancestors = try RightClickJSONConfigBackend.configurationAncestors(fixture.configuration)
        XCTAssertEqual(Set(ancestors.map(\.path)).count, ancestors.count)
#if !os(Windows)
        XCTAssertEqual(ancestors.last?.path, "/")
        XCTAssertEqual(try RightClickJSONConfigBackend.configurationAncestors(
            URL(fileURLWithPath: "/", isDirectory: false)).count, 1)
#endif
        _ = try fixture.prepared()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertThrowsError(try RightClickJSONConfigBackend.configurationAncestors(
            fixture.configuration, maximumDepth: 2))
    }

#if !os(Windows)
    func testBoundedPathInspectionStillRejectsAnAncestorSymlink() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let target = fixture.home.appendingPathComponent("target", isDirectory: true)
        let alias = fixture.home.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertThrowsError(try RightClickJSONConfigBackend.snapshot(alias.appendingPathComponent("missing/config.json")))
    }
#endif

    func testGenericNeedsAnExplicitAbsoluteConfiguration() throws {
        XCTAssertTrue(RightClickClientRegistry.supportedIDs.contains("generic"))
        XCTAssertThrowsError(try RightClickLocalOnboarding.Options(["--client", "generic", "--yes"]))
        XCTAssertThrowsError(try RightClickLocalOnboarding.Options(["--client", "generic", "--config", "relative.json"]))
        XCTAssertThrowsError(try RightClickLocalOnboarding.Options(["--client", "cursor", "--config", "/tmp/client.json"]))
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let options = try RightClickLocalOnboarding.Options(["--client", "generic", "--config", fixture.configuration.path, "--yes"])
        XCTAssertEqual(options.configuration, fixture.configuration)
        XCTAssertFalse(RightClickGenericClientAdapter(file: fixture.configuration).detected(home: fixture.home, applications: fixture.home))
    }

    func testOwnershipRecordContainsOnlyRecipeAndExecutableEvidence() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"keep":true,"mcpServers":{"other":{"env":{"TOKEN":"PRIVATE_SENTINEL"}}}}"#.utf8)
        try original.write(to: fixture.configuration)
        _ = try RightClickLocalLifecycle.apply([fixture.prepared()], home: fixture.home)
        let file = RightClickClientOwnershipStore.file(home: fixture.home)
        let data = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_SENTINEL"))
        let state = try RightClickClientOwnershipStore.read(home: fixture.home)
        XCTAssertEqual(state.clients.count, 1)
        XCTAssertEqual(state.clients[0].command, fixture.oldBinary.path)
        XCTAssertEqual(state.clients[0].arguments, ["mcp"])
        XCTAssertEqual(state.clients[0].configurationPath, fixture.configuration.path)
        XCTAssertEqual(state.clients[0].executableSHA256.count, 64)
#if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
#endif
    }

    func testRepairReplacesOnlyRecordedRecipeAndPreservesOtherClientContent() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try RightClickLocalLifecycle.apply([fixture.prepared()], home: fixture.home)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.configuration)) as? [String: Any])
        root["afterSetup"] = ["env": ["TOKEN": "DO_NOT_REPORT"]]
        try JSONSerialization.data(withJSONObject: root).write(to: fixture.configuration)
        var outputs: [String] = [], probes = 0
        let code = RightClickLocalLifecycle.runRepair(args: ["--fix", "--json"], executable: fixture.newBinary.path,
            home: fixture.home, output: { outputs.append($0) }, probe: { probes += 1; return "synthetic local transport proof" })
        XCTAssertEqual(code, 0)
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(try entry(fixture.configuration)["command"] as? String, fixture.newBinary.path)
        XCTAssertTrue(String(decoding: try Data(contentsOf: fixture.configuration), as: UTF8.self).contains("DO_NOT_REPORT"))
        XCTAssertFalse(outputs.joined().contains("DO_NOT_REPORT"))
        XCTAssertTrue(outputs.joined().contains("NOT_OBSERVED"))
        XCTAssertEqual(try RightClickClientOwnershipStore.read(home: fixture.home).clients[0].command, fixture.newBinary.path)
    }

    func testRepairPreservesUnownedConflictingRegistration() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try RightClickLocalLifecycle.apply([fixture.prepared()], home: fixture.home)
        let foreign = Data(#"{"mcpServers":{"rightclick":{"url":"https://foreign.invalid","env":{"TOKEN":"SECRET"}}}}"#.utf8)
        try foreign.write(to: fixture.configuration)
        var probes = 0, outputs: [String] = []
        XCTAssertEqual(RightClickLocalLifecycle.runRepair(args: ["--fix", "--json"], executable: fixture.newBinary.path,
            home: fixture.home, output: { outputs.append($0) }, probe: { probes += 1; return "unused" }), 1)
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.configuration), foreign)
        XCTAssertFalse(outputs.joined().contains("SECRET"))
    }

    func testFailedPostRepairProbeRestoresExactOriginalConfigAndOwnership() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try RightClickLocalLifecycle.apply([fixture.prepared()], home: fixture.home)
        let before = try Data(contentsOf: fixture.configuration)
        let ownershipFile = RightClickClientOwnershipStore.file(home: fixture.home)
        let ownershipBefore = try Data(contentsOf: ownershipFile)
        var probes = 0, outputs: [String] = []
        XCTAssertEqual(RightClickLocalLifecycle.runRepair(args: ["--fix", "--json"], executable: fixture.newBinary.path,
            home: fixture.home, output: { outputs.append($0) }, probe: {
                probes += 1
                if probes == 2 { throw RightClickOnboardingError("synthetic post-repair failure") }
                return "preflight proof"
            }), 1)
        XCTAssertEqual(probes, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.configuration), before)
        XCTAssertEqual(try Data(contentsOf: ownershipFile), ownershipBefore)
        XCTAssertTrue(outputs.joined().contains("original registrations were restored"))
        XCTAssertTrue(outputs.joined().contains("\"rollbackStatus\":\"RESTORED\""))
    }

    func testExecutableUpgradeDuringVerificationRestoresOriginalConfigAndOwnership() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try RightClickLocalLifecycle.apply([fixture.prepared()], home: fixture.home)
        let before = try Data(contentsOf: fixture.configuration)
        let ownershipFile = RightClickClientOwnershipStore.file(home: fixture.home)
        let ownershipBefore = try Data(contentsOf: ownershipFile)
        let prior = try XCTUnwrap(RightClickClientOwnershipStore.read(home: fixture.home).clients.first)
        let prepared = try RightClickLocalLifecycle.repairPlan(record: prior, home: fixture.home,
            executable: fixture.newBinary.path)
        let upgraded = Data("new executable bytes written during the final transport probe".utf8)
        XCTAssertThrowsError(try RightClickLocalLifecycle.apply([prepared], home: fixture.home, verify: {
            try upgraded.write(to: fixture.newBinary)
        })) { error in
            let failure = error as? RightClickLocalLifecycle.ValidationFailure
            XCTAssertEqual(failure?.rollbackStatus, "RESTORED")
            XCTAssertEqual(failure?.configurationChanged, "false")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.configuration), before)
        XCTAssertEqual(try Data(contentsOf: ownershipFile), ownershipBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.newBinary), upgraded)
    }

    func testRepairDryRunDoesNotChangeOwnershipOrConfigurationOrProbe() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try RightClickLocalLifecycle.apply([fixture.prepared()], home: fixture.home)
        let before = try Data(contentsOf: fixture.configuration)
        let ownershipFile = RightClickClientOwnershipStore.file(home: fixture.home)
        let ownershipBefore = try Data(contentsOf: ownershipFile)
        XCTAssertEqual(RightClickLocalLifecycle.runRepair(args: ["--fix", "--dry-run", "--json"], executable: fixture.newBinary.path,
            home: fixture.home, output: { _ in }, probe: { XCTFail("Dry-run launched probe"); return "unused" }), 0)
        XCTAssertEqual(try Data(contentsOf: fixture.configuration), before)
        XCTAssertEqual(try Data(contentsOf: ownershipFile), ownershipBefore)
    }

    func testPostRepairProbeCannotOverwriteNewerClientStateDuringRollback() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try RightClickLocalLifecycle.apply([fixture.prepared()], home: fixture.home)
        let newer = Data(#"{"mcpServers":{"personal":{"command":"keep"}},"editedAfterRepair":true}"#.utf8)
        var probes = 0, output = ""
        XCTAssertEqual(RightClickLocalLifecycle.runRepair(args: ["--fix", "--json"], executable: fixture.newBinary.path,
            home: fixture.home, output: { output = $0 }, probe: {
                probes += 1
                if probes == 2 {
                    try newer.write(to: fixture.configuration)
                    throw RightClickOnboardingError("client changed configuration during verification")
                }
                return "preflight"
            }), 1)
        XCTAssertEqual(try Data(contentsOf: fixture.configuration), newer)
        XCTAssertTrue(output.contains("\"rollbackStatus\":\"ROLLBACK_FAILED\""))
        XCTAssertTrue(output.contains("\"configurationChanged\":\"UNKNOWN\""))
    }

    func testSetupRollsBackWhenOwnershipLedgerIsMalformed() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let file = RightClickClientOwnershipStore.file(home: fixture.home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("malformed".utf8).write(to: file)
#if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
#endif
        XCTAssertThrowsError(try RightClickLocalLifecycle.apply([fixture.prepared()], home: fixture.home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("malformed".utf8))
    }

    func testGenericCannotAbandonPriorRecordedConfigBySelectingAnotherFile() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try RightClickLocalLifecycle.apply([fixture.prepared()], home: fixture.home)
        let alternative = fixture.home.appendingPathComponent("other/mcp.json")
        let adapter = RightClickGenericClientAdapter(file: alternative)
        let plan = try RightClickOnboardingEngine.plan(adapter: adapter, home: fixture.home, executable: fixture.newBinary.path)
        XCTAssertThrowsError(try RightClickLocalLifecycle.apply([.init(adapter: adapter, plan: plan)], home: fixture.home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternative.path))
        XCTAssertEqual(try entry(fixture.configuration)["command"] as? String, fixture.oldBinary.path)
    }

    func testRepairDoesNotAdoptExistingRegistrationWhenOwnershipMissing() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try RightClickOnboardingEngine.apply(fixture.prepared().plan)
        let before = try Data(contentsOf: fixture.configuration)
        var output = ""
        XCTAssertEqual(RightClickLocalLifecycle.runRepair(args: ["--fix", "--json"], executable: fixture.newBinary.path,
            home: fixture.home, output: { output = $0 }, probe: { XCTFail("Unowned repair probed"); return "unused" }), 0)
        XCTAssertTrue(output.contains("NO_OWNED_REGISTRATIONS"))
        XCTAssertEqual(try Data(contentsOf: fixture.configuration), before)
    }

    func testLiveProbeRejectsMissingExecutableWithoutChangingClientConfig() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        XCTAssertThrowsError(try RightClickLocalLifecycle.liveProbe(executable: fixture.home.appendingPathComponent("missing").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.path))
    }
}
