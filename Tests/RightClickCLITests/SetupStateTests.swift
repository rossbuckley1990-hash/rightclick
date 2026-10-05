import Foundation
import XCTest
@testable import RightClickCLI
import RightClickMCP

final class SetupStateTests: XCTestCase {
    func testSetupStateRoundTripsExactly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rightclick-state-\(UUID().uuidString)",
                isDirectory: true
            )

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let executable = root.appendingPathComponent("rightclick")
        try Data("rightclick-test-binary".utf8).write(to: executable)

        let file = root.appendingPathComponent("setup-state.json")

        let state = try RightClickSetupStateStore.make(
            executable: executable.path,
            chatGPTTunnelID: "tunnel_test",
            tunnelClientPath: "/opt/homebrew/bin/tunnel-client",
            tunnelClientVersion: "0.0.15"
        )

        try RightClickSetupStateStore.write(
            state,
            to: file
        )

        let restored = try RightClickSetupStateStore.read(
            from: file
        )

        XCTAssertEqual(restored, state)

        XCTAssertEqual(
            state.setupSchemaVersion,
            1
        )

        XCTAssertEqual(
            state.bridgeConfigurationVersion,
            1
        )

        XCTAssertFalse(
            state.executableSHA256.isEmpty
        )

        XCTAssertFalse(
            state.mcpToolSchemaSHA256.isEmpty
        )
    }

    func testSetupStateWriteIsDeterministic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rightclick-state-\(UUID().uuidString)",
                isDirectory: true
            )

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let executable = root.appendingPathComponent("rightclick")
        try Data("same-binary".utf8).write(to: executable)

        let file = root.appendingPathComponent("setup-state.json")

        let state = try RightClickSetupStateStore.make(
            executable: executable.path
        )

        try RightClickSetupStateStore.write(state, to: file)
        let first = try Data(contentsOf: file)

        try RightClickSetupStateStore.write(state, to: file)
        let second = try Data(contentsOf: file)

        XCTAssertEqual(first, second)
    }

    func testMCPContractContainsCurrentSixTools() {
        XCTAssertEqual(
            Set(RightClickMCPContract.toolNames()),
            Set([
                "context_inspect",
                "context_actions",
                "context_explain",
                "context_run",
                "context_run_status",
                "context_providers",
            ])
        )

        XCTAssertFalse(
            RightClickMCPContract.toolSchemaSHA256().isEmpty
        )
    }
}

extension SetupStateTests {
    func testReconcilePreservesChatGPTBridgeIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rightclick-reconcile-\(UUID().uuidString)",
                isDirectory: true
            )

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let oldExecutable = root.appendingPathComponent("rightclick-old")
        let newExecutable = root.appendingPathComponent("rightclick-new")
        let stateFile = root.appendingPathComponent("setup-state.json")

        try Data("old-binary".utf8).write(to: oldExecutable)
        try Data("new-binary".utf8).write(to: newExecutable)

        let previous = try RightClickSetupStateStore.make(
            executable: oldExecutable.path,
            chatGPTTunnelID: "tunnel_keep_me",
            tunnelClientPath: "/opt/homebrew/bin/tunnel-client",
            tunnelClientVersion: "0.0.15"
        )

        try RightClickSetupStateStore.write(
            previous,
            to: stateFile
        )

        let result = RightClickSetupStateStore.reconcile(
            executable: newExecutable.path,
            at: stateFile
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.executableChanged)

        let current = try XCTUnwrap(result.current)

        XCTAssertEqual(
            current.chatGPTTunnelID,
            "tunnel_keep_me"
        )

        XCTAssertEqual(
            current.tunnelClientPath,
            "/opt/homebrew/bin/tunnel-client"
        )

        XCTAssertEqual(
            current.tunnelClientVersion,
            "0.0.15"
        )

        XCTAssertEqual(
            current.executablePath,
            newExecutable.path
        )

        XCTAssertNotEqual(
            previous.executableSHA256,
            current.executableSHA256
        )
    }

    func testMalformedExistingStateIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rightclick-reconcile-\(UUID().uuidString)",
                isDirectory: true
            )

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let executable = root.appendingPathComponent("rightclick")
        let stateFile = root.appendingPathComponent("setup-state.json")

        try Data("binary".utf8).write(to: executable)

        let original = Data(
            #"{"this":"must remain byte identical""#.utf8
        )

        try original.write(to: stateFile)

        let result = RightClickSetupStateStore.reconcile(
            executable: executable.path,
            at: stateFile
        )

        XCTAssertFalse(result.success)

        XCTAssertEqual(
            try Data(contentsOf: stateFile),
            original
        )
    }
}
