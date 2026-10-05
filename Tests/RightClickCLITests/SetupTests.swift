import Foundation
import XCTest
@testable import RightClickCLI

final class SetupTests: XCTestCase {
    private func isolated(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-setup-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("nested/mcp.json"))
    }

    func testAbsentConfigurationIsCreated() throws {
        try isolated { file in
            let result = RightClickSetup.writeCursorConfig(executable: "/example/rightclick", at: file)
            XCTAssertTrue(result.success)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
            let entry = try XCTUnwrap(servers["rightclick"] as? [String: Any])
            XCTAssertEqual(entry["command"] as? String, "/example/rightclick")
            XCTAssertEqual(entry["args"] as? [String], ["mcp"])
        }
    }

    func testInvalidServerContainersRemainByteIdentical() throws {
        for value in ["[]", "[1,2]", "\"keep\"", "null", "42", "true"] {
            try isolated { file in
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let original = Data("{\"mcpServers\":\(value),\"untouched\":\"π\"}".utf8)
                try original.write(to: file)
                XCTAssertFalse(RightClickSetup.writeCursorConfig(executable: "/example/rightclick", at: file).success, value)
                XCTAssertEqual(try Data(contentsOf: file), original, value)
            }
        }
    }

    func testInvalidRootAndMalformedJSONRemainByteIdentical() throws {
        for value in ["[]", "\"keep\"", "null", "42", "{", "{\"x\":"] {
            try isolated { file in
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let original = Data(value.utf8)
                try original.write(to: file)
                XCTAssertFalse(RightClickSetup.writeCursorConfig(executable: "/example/rightclick", at: file).success, value)
                XCTAssertEqual(try Data(contentsOf: file), original, value)
            }
        }
    }

    func testUnrelatedValuesAndOnlyOwnedEntryArePreserved() throws {
        try isolated { file in
            let original = Data(#"{"rootExtra":{"nested":["π",true,null]},"mcpServers":{"other":{"command":"unchanged","args":["a\\b","\"quoted\""]},"unrecognised":42,"rightclick":{"command":"replace me","oldField":true}}}"#.utf8)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: file)
            XCTAssertTrue(RightClickSetup.writeCursorConfig(executable: "/example/with spaces/rightclick", at: file).success)
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary)
            XCTAssertEqual(after["rootExtra"] as? NSDictionary, before["rootExtra"] as? NSDictionary)
            let servers = try XCTUnwrap(after["mcpServers"] as? NSDictionary)
            let prior = try XCTUnwrap(before["mcpServers"] as? NSDictionary)
            XCTAssertEqual(servers["other"] as? NSDictionary, prior["other"] as? NSDictionary)
            XCTAssertEqual(servers["unrecognised"] as? NSNumber, prior["unrecognised"] as? NSNumber)
            let entry = try XCTUnwrap(servers["rightclick"] as? NSDictionary)
            XCTAssertEqual(entry, ["command": "/example/with spaces/rightclick", "args": ["mcp"]] as NSDictionary)
            let first = try Data(contentsOf: file)
            XCTAssertTrue(RightClickSetup.writeCursorConfig(executable: "/example/with spaces/rightclick", at: file).success)
            XCTAssertEqual(try Data(contentsOf: file), first)
        }
    }

    func testWriteFailureIsReported() {
        let result = RightClickSetup.writeCursorConfig(executable: "/example/rightclick", at: URL(fileURLWithPath: "/dev/null/no-directory/mcp.json"))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("not written"))
    }

    func testEveryFailedStagePreventsSuccessfulExit() {
        for discovery in ["FAIL", "UNKNOWN", "", "not a status"] {
            XCTAssertFalse(RightClickSetup.succeeded(discovery: discovery, cursorWritten: true, selfTestPassed: true))
        }
        XCTAssertFalse(RightClickSetup.succeeded(discovery: "PASS", cursorWritten: false, selfTestPassed: true))
        XCTAssertFalse(RightClickSetup.succeeded(discovery: "PASS", cursorWritten: true, selfTestPassed: false))
        XCTAssertTrue(RightClickSetup.succeeded(discovery: "PASS", cursorWritten: true, selfTestPassed: true))
    }
}
