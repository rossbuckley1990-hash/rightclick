import Foundation
import XCTest
@testable import RightClickCLI

final class OnboardingEngineTests: XCTestCase {
    private struct FixtureAdapter: RightClickClientAdapter {
        let id = "fixture"
        let displayName = "Fixture"
        func detected(home: URL, applications: URL) -> Bool { true }
        func configurationFile(home: URL) -> URL { home.appendingPathComponent(".fixture/mcp.json") }
        func connectionRecipe(executable: String) throws -> RightClickConnectionRecipe {
            try .stdio(command: executable, arguments: ["mcp"])
        }
        func planConfiguration(home: URL, recipe: RightClickConnectionRecipe, disconnect: Bool) throws -> RightClickOnboardingMutation {
            .json(try RightClickJSONConfigBackend.plan(
                file: configurationFile(home: home),
                containerKey: "mcpServers",
                entryKey: "rightclick",
                desiredEntry: recipe.jsonMCPEntry,
                disconnect: disconnect
            ))
        }
    }

    private func isolated(_ body: (URL, URL, String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-generic-onboard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("rightclick")
        try Data("fixture".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try body(home, home.appendingPathComponent(".fixture/mcp.json"), binary.path)
    }

    private func seed(_ file: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func object(_ file: URL) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary)
    }

    func testGenericEngineUsesAdapterAndPreservesUnrelatedConfiguration() throws {
        try isolated { home, file, binary in
            let original = #"{"extra":{"keep":true},"mcpServers":{"other":{"command":"preserve"}}}"#
            try seed(file, original)
            let before = try object(file)
            let plan = try RightClickOnboardingEngine.plan(adapter: FixtureAdapter(), home: home, executable: binary)
            XCTAssertEqual(plan.clientID, "fixture")
            XCTAssertEqual(plan.recipe.transport, .stdio)
            XCTAssertEqual(plan.recipe.command, binary)
            XCTAssertEqual(plan.recipe.arguments, ["mcp"])
            let result = try RightClickOnboardingEngine.apply(plan)
            XCTAssertEqual(result.operation, "CONFIGURED")
            let after = try object(file)
            XCTAssertEqual(after["extra"] as? NSDictionary, before["extra"] as? NSDictionary)
            XCTAssertEqual((after["mcpServers"] as? NSDictionary)?["other"] as? NSDictionary,
                           (before["mcpServers"] as? NSDictionary)?["other"] as? NSDictionary)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.backup)), Data(original.utf8))
        }
    }

    func testGenericEngineFailsClosedOnConflictingOwnedEntry() throws {
        try isolated { home, file, binary in
            let original = #"{"mcpServers":{"rightclick":{"command":"/different","args":["mcp"]}}}"#
            try seed(file, original)
            XCTAssertThrowsError(try RightClickOnboardingEngine.plan(adapter: FixtureAdapter(), home: home, executable: binary))
            XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        }
    }

    func testPostWriteVerificationFailurePreservesNewerClientContent() throws {
        try isolated { _, file, binary in
            let original = #"{"keep":"original"}"#
            try seed(file, original)
            let desired = try RightClickConnectionRecipe.stdio(command: binary, arguments: ["mcp"]).jsonMCPEntry
            let plan = try RightClickJSONConfigBackend.plan(
                file: file, containerKey: "mcpServers", entryKey: "rightclick", desiredEntry: desired
            )
            XCTAssertThrowsError(try RightClickJSONConfigBackend.apply(plan, afterReplace: {
                try Data("tampered".utf8).write(to: file)
            }))
            XCTAssertEqual(try Data(contentsOf: file), Data("tampered".utf8))
        }
    }

    func testPostWriteFailureRemovesConfigurationCreatedFromNothing() throws {
        try isolated { _, file, binary in
            let desired = try RightClickConnectionRecipe.stdio(command: binary, arguments: ["mcp"]).jsonMCPEntry
            let plan = try RightClickJSONConfigBackend.plan(
                file: file, containerKey: "mcpServers", entryKey: "rightclick", desiredEntry: desired
            )
            XCTAssertThrowsError(try RightClickJSONConfigBackend.apply(plan, afterReplace: {
                throw RightClickOnboardingError("synthetic post-write failure")
            }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testDisconnectRemovesOnlyOwnedEntryAfterIndependentEdits() throws {
        try isolated { home, file, binary in
            let adapter = FixtureAdapter()
            _ = try RightClickOnboardingEngine.apply(
                RightClickOnboardingEngine.plan(adapter: adapter, home: home, executable: binary)
            )
            var root = try object(file) as! [String: Any]
            var servers = root["mcpServers"] as! [String: Any]
            servers["later"] = ["command": "keep"]
            root["mcpServers"] = servers
            root["newRoot"] = "keep"
            try JSONSerialization.data(withJSONObject: root).write(to: file)

            let disconnect = try RightClickOnboardingEngine.plan(
                adapter: adapter, home: home, executable: binary, disconnect: true
            )
            let result = try RightClickOnboardingEngine.apply(disconnect)
            XCTAssertEqual(result.operation, "DISCONNECTED")
            let after = try object(file)
            XCTAssertNil((after["mcpServers"] as? NSDictionary)?["rightclick"])
            XCTAssertNotNil((after["mcpServers"] as? NSDictionary)?["later"])
            XCTAssertEqual(after["newRoot"] as? String, "keep")
        }
    }

    func testClientStateVocabularySeparatesConfigurationConnectionAndAttestation() {
        XCTAssertNotEqual(RightClickClientState.configured, .connected)
        XCTAssertNotEqual(RightClickClientState.connected, .liveAttested)
        XCTAssertEqual(RightClickClientState.liveAttested.rawValue, "LIVE_ATTESTED")
    }
}
