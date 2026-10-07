import Foundation
import XCTest
@testable import RightClickCLI

/// A failed setup owns only its own replacement. It cannot erase later edits.
final class AdoptionSecurityRollbackTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-adoption-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testFailedJSONPostconditionPreservesNewerValidClientEdit() throws {
        try fixture { root in
            let file = root.appendingPathComponent("mcp.json")
            try Data(#"{"keep":"original"}"#.utf8).write(to: file)
            let plan = try RightClickJSONConfigBackend.plan(
                file: file, containerKey: "mcpServers", entryKey: "rightclick",
                desiredEntry: ["command": "/fixture/rightclick", "args": ["mcp"]]
            )
            let concurrent = Data(#"{"keep":"updated by client","mcpServers":{"other":{"command":"/user/tool"}}}"#.utf8)
            XCTAssertThrowsError(try RightClickJSONConfigBackend.apply(plan, afterReplace: {
                try concurrent.write(to: file)
            }))
            XCTAssertEqual(try Data(contentsOf: file), concurrent,
                "Postcondition failure must preserve client edits made after setup's replacement.")
        }
    }

    func testFailedJSONPostconditionPreservesNewerFileCreatedFromNothing() throws {
        try fixture { root in
            let file = root.appendingPathComponent("mcp.json")
            let plan = try RightClickJSONConfigBackend.plan(
                file: file, containerKey: "mcpServers", entryKey: "rightclick",
                desiredEntry: ["command": "/fixture/rightclick", "args": ["mcp"]]
            )
            let concurrent = Data(#"{"mcpServers":{"personal":{"command":"/user/tool"}}}"#.utf8)
            XCTAssertThrowsError(try RightClickJSONConfigBackend.apply(plan, afterReplace: {
                try concurrent.write(to: file)
                throw RightClickOnboardingError("synthetic verifier failure")
            }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                "Rollback must not delete a newer file merely because setup created its predecessor.")
            if FileManager.default.fileExists(atPath: file.path) {
                XCTAssertEqual(try Data(contentsOf: file), concurrent)
            }
        }
    }

    private func nativeFixture(_ root: URL) throws -> (URL, URL, RightClickNativeRegistrationBackend.Contract) {
        let executable = root.appendingPathComponent("client")
        let state = root.appendingPathComponent("registration")
        let script = """
        #!/bin/sh
        STATE='\(state.path)'
        case "$1" in
          get)
            if [ ! -f "$STATE" ]; then echo ABSENT; exit 1; fi
            cat "$STATE"
            ;;
          add) printf 'RIGHTCLICK=DESIRED\\n' > "$STATE" ;;
          remove) rm -f "$STATE" ;;
          *) exit 20 ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command: (String) -> RightClickNativeRegistrationBackend.Command = {
            .init(executable: executable.path, arguments: [$0])
        }
        let contract = RightClickNativeRegistrationBackend.Contract(
            backendID: "security-native-fixture", scope: "fixture",
            inspect: command("get"), add: command("add"), remove: command("remove"),
            exactInspection: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "RIGHTCLICK=DESIRED" },
            absenceMarkers: ["ABSENT"]
        )
        return (executable, state, contract)
    }

    func testNativeConfigureRollbackPreservesNewerRegistration() throws {
        try fixture { root in
            let (_, state, contract) = try nativeFixture(root)
            let plan = try RightClickNativeRegistrationBackend.plan(contract: contract, disconnect: false)
            _ = try RightClickNativeRegistrationBackend.apply(plan)
            let newer = Data("RIGHTCLICK=USER_CHANGED\n".utf8)
            try newer.write(to: state)
            XCTAssertThrowsError(try RightClickNativeRegistrationBackend.rollback(plan))
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
            if FileManager.default.fileExists(atPath: state.path) {
                XCTAssertEqual(try Data(contentsOf: state), newer,
                    "Transaction rollback may remove only the registration installed by this transaction.")
            }
        }
    }

    func testNativeDisconnectRollbackPreservesNewerRegistration() throws {
        try fixture { root in
            let (_, state, contract) = try nativeFixture(root)
            try Data("RIGHTCLICK=DESIRED\n".utf8).write(to: state)
            let plan = try RightClickNativeRegistrationBackend.plan(contract: contract, disconnect: true)
            _ = try RightClickNativeRegistrationBackend.apply(plan)
            let newer = Data("RIGHTCLICK=USER_CHANGED\n".utf8)
            try newer.write(to: state)
            XCTAssertThrowsError(try RightClickNativeRegistrationBackend.rollback(plan))
            XCTAssertEqual(try Data(contentsOf: state), newer,
                "Rollback cannot replace a registration created after the transaction disconnected RIGHTCLICK.")
        }
    }

    func testJSONRollbackRejectsPathReplacedWithSymlinkWithoutTouchingTarget() throws {
        try fixture { root in
            let file = root.appendingPathComponent("mcp.json")
            let target = root.appendingPathComponent("user-secret.json")
            let targetBytes = Data(#"{"user":"private"}"#.utf8)
            try targetBytes.write(to: target)
            let plan = try RightClickJSONConfigBackend.plan(
                file: file, containerKey: "mcpServers", entryKey: "rightclick",
                desiredEntry: ["command": "/fixture/rightclick", "args": ["mcp"]]
            )
            let applied = try RightClickJSONConfigBackend.apply(plan)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            XCTAssertThrowsError(try RightClickJSONConfigBackend.rollbackTransaction(plan, applied: applied))
            XCTAssertEqual(try Data(contentsOf: target), targetBytes)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), target.path)
        }
    }
}
