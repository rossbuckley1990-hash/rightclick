import Foundation
import XCTest
@testable import RightClickCLI

final class LocalOnboardingTests: XCTestCase {
    typealias S = RightClickLocalOnboarding

    private func isolated(_ body: (URL, URL, String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-onboard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent("rightclick with spaces")
        try Data("test fixture; never execute".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try body(home, home.appendingPathComponent(".cursor/mcp.json"), binary.path)
    }

    private func seed(_ file: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func object(_ file: URL) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary)
    }

    private func privateFile(_ file: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOptionsRejectUnknownOrIncompleteArguments() {
        for args in [["--wat"], ["--client"], ["--client", "gemini"], ["--client=cursor"], ["cursor"], ["--yes"], ["--json", "--json"], ["--client", "cursor", "--client", "cursor"]] {
            XCTAssertThrowsError(try S.Options(args), "\(args)")
        }
    }

    func testOptionsAcceptExplicitLocalPlan() throws {
        let options = try S.Options(["--client", "cursor", "--dry-run", "--json", "--yes"])
        XCTAssertEqual(options.client, "cursor")
        XCTAssertTrue(options.dryRun)
        XCTAssertTrue(options.json)
        XCTAssertTrue(options.yes)
    }

    func testBridgeIsOnlyExplicitAndCannotMixModes() throws {
        XCTAssertFalse(try S.bridgeArguments([]))
        XCTAssertFalse(try S.bridgeArguments(["--client", "cursor"]))
        let id = "tunnel_" + String(repeating: "a", count: 32)
        XCTAssertTrue(try S.bridgeArguments(["--chatgpt-tunnel-id", id, "--json"]))
        for args in [["--chatgpt-tunnel-id"], ["--chatgpt-tunnel-id", "bad"], ["--chatgpt-tunnel-id", id, "--dry-run"], ["--chatgpt-tunnel-id", id, "--client", "cursor"], ["--chatgpt-tunnel-id", id, "--yes"], ["--chatgpt-tunnel-id", id, "--json", "--json"], ["--chatgpt-tunnel-id", id + "\n"]] {
            XCTAssertThrowsError(try S.bridgeArguments(args), "\(args)")
        }
    }

    func testDetectsOnlySupportedClientLocations() throws {
        try isolated { home, _, _ in
            let emptyApps = home.appendingPathComponent("emptyApplications")
            XCTAssertFalse(S.cursorDetected(home: home, applications: emptyApps))
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Applications/Cursor.app"), withIntermediateDirectories: true)
            XCTAssertTrue(S.cursorDetected(home: home, applications: emptyApps))
        }
    }

    func testNewPlanDoesNotCreateDirectories() throws {
        try isolated { _, file, binary in
            let plan = try S.plan(file: file, executable: binary)
            XCTAssertTrue(plan.changed)
            XCTAssertEqual(plan.operation, "CONFIGURED")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        }
    }

    func testCreateHasExpectedStdioEntryAndPrivatePermissions() throws {
        try isolated { _, file, binary in
            let result = try S.apply(S.plan(file: file, executable: binary))
            XCTAssertNil(result.backup)
            let root = try object(file)
            let servers = try XCTUnwrap(root["mcpServers"] as? NSDictionary)
            XCTAssertEqual(servers["rightclick"] as? NSDictionary, try S.desiredEntry(executable: binary) as NSDictionary)
            try privateFile(file)
        }
    }

    func testMergePreservesOtherServersAndRootFieldsWithPrivateExactBackup() throws {
        try isolated { _, file, binary in
            let original = #"{"extra":{"unicode":"π","keep":[true,null,3]},"mcpServers":{"other":{"command":"preserve","env":{"TOKEN":"sentinel-secret"}}}}"#
            try seed(file, original)
            let before = try object(file)
            let result = try S.apply(S.plan(file: file, executable: binary))
            let after = try object(file)
            XCTAssertEqual(after["extra"] as? NSDictionary, before["extra"] as? NSDictionary)
            XCTAssertEqual((after["mcpServers"] as? NSDictionary)?["other"] as? NSDictionary,
                           (before["mcpServers"] as? NSDictionary)?["other"] as? NSDictionary)
            let backup = try XCTUnwrap(result.backup)
            XCTAssertEqual(try Data(contentsOf: backup), Data(original.utf8))
            try privateFile(file)
            try privateFile(backup)
        }
    }

    func testSecondRunIsByteIdenticalWithoutAnotherBackup() throws {
        try isolated { _, file, binary in
            _ = try S.apply(S.plan(file: file, executable: binary))
            let bytes = try Data(contentsOf: file)
            let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            let second = try S.plan(file: file, executable: binary)
            XCTAssertFalse(second.changed)
            XCTAssertEqual(try S.apply(second).operation, "ALREADY_CONFIGURED")
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), beforeFiles)
        }
    }

    func testEquivalentLegacyEntryIsPreservedByteForByte() throws {
        try isolated { _, file, binary in
            let entry: [String: Any] = ["mcpServers": ["rightclick": ["command": binary, "args": ["mcp"]]]]
            let bytes = try JSONSerialization.data(withJSONObject: entry, options: .prettyPrinted)
            try seed(file, String(decoding: bytes, as: UTF8.self))
            XCTAssertFalse(try S.plan(file: file, executable: binary).changed)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testDifferentRightclickEntryNeverOverwrittenOrRemoved() throws {
        try isolated { _, file, binary in
            for prior in [#"{"command":"/sealed/rc1","args":["mcp"]}"#, "null", "42", #"{"url":"https://remote.invalid"}"#] {
                let original = "{\"mcpServers\":{\"rightclick\":\(prior)}}"
                try seed(file, original)
                XCTAssertThrowsError(try S.plan(file: file, executable: binary))
                XCTAssertThrowsError(try S.plan(file: file, executable: binary, disconnect: true))
                XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
            }
        }
    }

    func testAdditionalRightclickSettingsAreNotSilentlyDropped() throws {
        try isolated { _, file, binary in
            let root: [String: Any] = ["mcpServers": ["rightclick": ["command": binary, "args": ["mcp"], "env": ["TOKEN": "secret"]]]]
            try seed(file, String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self))
            XCTAssertThrowsError(try S.plan(file: file, executable: binary))
        }
    }

    func testInvalidRootAndMalformedJSONArePreserved() throws {
        try isolated { _, file, binary in
            for text in ["[]", "null", "42", "\"secret\"", "{", "{\"x\":"] {
                try seed(file, text)
                XCTAssertThrowsError(try S.plan(file: file, executable: binary))
                XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))
            }
        }
    }

    func testInvalidServerContainersArePreserved() throws {
        try isolated { _, file, binary in
            for value in ["[]", "[1]", "null", "42", "true", "\"secret\""] {
                let text = "{\"mcpServers\":\(value)}"
                try seed(file, text)
                XCTAssertThrowsError(try S.plan(file: file, executable: binary))
                XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))
            }
        }
    }

    func testDuplicateJSONKeysAreRejectedWithoutLosingData() throws {
        try isolated { _, file, binary in
            for original in [
                #"{"mcpServers":{},"mcpServers":{}}"#,
                #"{"mcpServers":{},"mcp\u0053ervers":{}}"#,
                #"{"array":[{"x":1,"x":2}]}"#,
                #"{"other":{"env":{"TOKEN":"first","TOKEN":"second"}}}"#,
            ] {
                try seed(file, original)
                XCTAssertThrowsError(try S.plan(file: file, executable: binary))
                XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
            }
        }
    }

    func testNestedJSONEscapesAndArraysAreAccepted() throws {
        try isolated { _, file, binary in
            let original = #"{"keep":[{},[],{"a":"quote\" slash\\ brackets{} []","b":-12.5e2},true,null,"π"]}"#
            try seed(file, original)
            let before = try object(file)
            _ = try S.apply(S.plan(file: file, executable: binary))
            XCTAssertEqual(try object(file)["keep"] as? NSArray, before["keep"] as? NSArray)
        }
    }

    func testLocalSetupIgnoresSavedBridgeAndOtherClientFiles() throws {
        try isolated { home, _, binary in
            let untouched = ["Library/Application Support/RIGHTCLICK/setup.json", ".codex/config.toml", "plugins/rightclick/.mcp.json", "Library/LaunchAgents/rightclick.plist"]
            for path in untouched { try seed(home.appendingPathComponent(path), "DO-NOT-CHANGE") }
            XCTAssertEqual(S.run(args: ["--client", "cursor", "--yes", "--json"], executable: binary,
                                 home: home, interactive: false, output: { _ in }, probe: { "synthetic probe passed" }), 0)
            for path in untouched {
                XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent(path)), Data("DO-NOT-CHANGE".utf8))
            }
        }
    }

    func testInteractiveYesAppliesOnlyAfterPrompt() throws {
        try isolated { home, file, binary in
            var prompted = false
            XCTAssertEqual(S.run(args: ["--client", "cursor"], executable: binary,
                                 home: home, interactive: true, readAnswer: { prompted = true; return "yes" },
                                 output: { _ in }, probe: { XCTAssertTrue(prompted); return "synthetic probe passed" }), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testRejectsUnsafeExecutablePaths() {
        for executable in ["rightclick", "relative/path", "/tmp/x\nrightclick", "/tmp/${env:HOME}/rightclick"] {
            XCTAssertThrowsError(try S.desiredEntry(executable: executable))
        }
        XCTAssertNoThrow(try S.desiredEntry(executable: "/Applications/with spaces/it's rightclick"))
    }

    func testSymlinkFileIsRejected() throws {
        try isolated { home, file, binary in
            let target = home.appendingPathComponent("protected.json")
            try seed(target, "{}")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            XCTAssertThrowsError(try S.plan(file: file, executable: binary))
            XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
        }
    }

    func testSymlinkDirectoryIsRejected() throws {
        try isolated { home, file, binary in
            let other = home.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: other)
            XCTAssertThrowsError(try S.plan(file: file, executable: binary))
        }
    }

    func testDanglingSymlinkIsRejected() throws {
        try isolated { home, file, binary in
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: home.appendingPathComponent("absent"))
            XCTAssertThrowsError(try S.plan(file: file, executable: binary))
        }
    }

    func testHardLinkedConfigIsRejected() throws {
        try isolated { home, file, binary in
            try seed(file, "{}")
            try FileManager.default.linkItem(at: file, to: home.appendingPathComponent("other.json"))
            XCTAssertThrowsError(try S.plan(file: file, executable: binary))
        }
    }

    func testDirectoryAtConfigPathIsRejected() throws {
        try isolated { _, file, binary in
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            XCTAssertThrowsError(try S.plan(file: file, executable: binary))
        }
    }

    func testOversizedConfigIsRejected() throws {
        try isolated { _, file, binary in
            try seed(file, String(repeating: " ", count: 4 * 1024 * 1024 + 1))
            XCTAssertThrowsError(try S.plan(file: file, executable: binary))
        }
    }

    func testChangesAfterPreviewAreNotOverwritten() throws {
        try isolated { _, file, binary in
            try seed(file, "{}")
            let plan = try S.plan(file: file, executable: binary)
            try seed(file, #"{"concurrent":"edit"}"#)
            XCTAssertThrowsError(try S.apply(plan))
            XCTAssertEqual(try Data(contentsOf: file), Data(#"{"concurrent":"edit"}"#.utf8))
        }
    }

    func testFileAppearingAfterPreviewIsNotOverwritten() throws {
        try isolated { _, file, binary in
            let plan = try S.plan(file: file, executable: binary)
            try seed(file, #"{"appeared":true}"#)
            XCTAssertThrowsError(try S.apply(plan))
        }
    }

    func testConcurrentInstallerLockPreventsWrite() throws {
        try isolated { _, file, binary in
            try seed(file, "{}")
            let lock = file.deletingLastPathComponent().appendingPathComponent(".rightclick-setup.lock")
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            XCTAssertThrowsError(try S.apply(S.plan(file: file, executable: binary)))
            XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        }
    }

    func testDisconnectRemovesOnlyMatchingEntryAndKeepsLaterEdits() throws {
        try isolated { _, file, binary in
            _ = try S.apply(S.plan(file: file, executable: binary))
            var root = try object(file) as! [String: Any]
            var servers = root["mcpServers"] as! [String: Any]
            servers["later"] = ["command": "keep"]
            root["mcpServers"] = servers
            root["newRootField"] = "keep"
            try JSONSerialization.data(withJSONObject: root).write(to: file)
            let before = try Data(contentsOf: file)
            let result = try S.apply(S.plan(file: file, executable: binary, disconnect: true))
            let after = try object(file)
            XCTAssertNil((after["mcpServers"] as? NSDictionary)?["rightclick"])
            XCTAssertNotNil((after["mcpServers"] as? NSDictionary)?["later"])
            XCTAssertEqual(after["newRootField"] as? String, "keep")
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.backup)), before)
        }
    }

    func testDisconnectAbsentConfigIsNoOp() throws {
        try isolated { _, file, binary in
            let result = try S.apply(S.plan(file: file, executable: binary, disconnect: true))
            XCTAssertEqual(result.operation, "ALREADY_DISCONNECTED")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        }
    }

    func testDryRunDoesNotWritePromptOrProbe() throws {
        try isolated { home, file, binary in
            var output: [String] = []
            let code = S.run(args: ["--client", "cursor", "--dry-run", "--json"], executable: binary, home: home,
                             interactive: true, readAnswer: { XCTFail("prompted"); return nil }, output: { output.append($0) },
                             probe: { XCTFail("probe ran"); return "FAIL" })
            XCTAssertEqual(code, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
            XCTAssertEqual(output.count, 1)
            XCTAssertTrue(output[0].contains("DRY_RUN"))
            XCTAssertTrue(output[0].contains("NOT_VERIFIED"))
        }
    }

    func testNonInteractiveNeedsExplicitConsent() throws {
        try isolated { home, file, binary in
            var output: [String] = []
            let code = S.run(args: ["--client", "cursor", "--json"], executable: binary, home: home, interactive: false,
                             output: { output.append($0) }, probe: { XCTFail("probe ran"); return "FAIL" })
            XCTAssertEqual(code, 3)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(output.joined().contains("CONSENT_REQUIRED"))
        }
    }

    func testJSONNeverPromptsEvenWithTerminal() throws {
        try isolated { home, _, binary in
            XCTAssertEqual(S.run(args: ["--client", "cursor", "--json"], executable: binary, home: home,
                                 interactive: true, readAnswer: { XCTFail("prompted"); return "yes" }, output: { _ in },
                                 probe: { XCTFail("probe ran"); return "FAIL" }), 3)
        }
    }

    func testDeclineAndEOFDoNotChangeConfig() throws {
        try isolated { home, file, binary in
            for answer in [nil, "", "n", "not today"] as [String?] {
                XCTAssertEqual(S.run(args: ["--client", "cursor"], executable: binary, home: home,
                                     interactive: true, readAnswer: { answer }, output: { _ in },
                                     probe: { XCTFail("probe ran"); return "FAIL" }), 3)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    func testProbeFailurePreventsConfigWrite() throws {
        try isolated { home, file, binary in
            XCTAssertEqual(S.run(args: ["--client", "cursor", "--yes"], executable: binary, home: home,
                                 interactive: false, output: { _ in },
                                 probe: { throw S.SetupError("synthetic probe failure") }), 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testSuccessDoesNotClaimClientConnectionOrOutcomeAndDoesNotLeakConfigSecrets() throws {
        try isolated { home, file, binary in
            try seed(file, #"{"mcpServers":{"other":{"env":{"TOKEN":"SENSITIVE_SENTINEL"}}}}"#)
            var output: [String] = []
            var calls = 0
            XCTAssertEqual(S.run(args: ["--client", "cursor", "--yes", "--json"], executable: binary, home: home,
                                 interactive: false, output: { output.append($0) },
                                 probe: { calls += 1; return "inspect text: public.plain-text" }), 0)
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(output.count, 1)
            XCTAssertTrue(output[0].contains("CONFIGURED"))
            XCTAssertTrue(output[0].contains("NOT_VERIFIED"))
            XCTAssertTrue(output[0].contains("NOT_RUN"))
            XCTAssertFalse(output[0].contains("SENSITIVE_SENTINEL"))
        }
    }

    func testNoClientAndMissingExecutableDoNotWrite() throws {
        try isolated { home, file, _ in
            for args in [[], ["--client", "cursor", "--yes"]] as [[String]] {
                XCTAssertEqual(S.run(args: args, executable: "/absent/rightclick", home: home,
                                     interactive: false, output: { _ in }, probe: { XCTFail("probe ran"); return "FAIL" }), 1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    func testHelpNeverProbesOrWrites() throws {
        try isolated { home, file, binary in
            XCTAssertEqual(S.run(args: ["--help"], executable: binary, home: home,
                                 output: { _ in }, probe: { XCTFail("probe ran"); return "FAIL" }), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
}
