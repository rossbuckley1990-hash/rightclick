import Foundation
import XCTest
import RightClickCore
@testable import RightClickCLI
@testable import RightClickMCP
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class AdoptionSecurityStdioIdentityTests: XCTestCase {
    private func fixture(mode: String, inspectFoundationHome: Bool = false,
                         _ body: (URL, URL, URL) throws -> Void) throws {
#if os(Windows)
        throw XCTSkip("Counterfeit stdio fixture uses the POSIX Python launcher; Windows remains unvalidated.")
#else
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("The explicit Python fixture launcher is unavailable.")
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-counterfeit-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repository.appendingPathComponent("scripts/acceptance-adoption-stdio-fixture.py")
        let executable = root.appendingPathComponent("fake-rightclick")
        try Data(contentsOf: source).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let receipt = root.appendingPathComponent("child-environment.json")
        let identity = RightClickRuntime.identity(transport: "stdio", executablePath: executable.path, pid: 0)
        let configuration: [String: Any] = [
            "tools": try JSONSerialization.jsonObject(with: RightClickMCPContract.toolSchemaJSON()),
            "runtime": try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)),
            "mode": mode, "environmentReceipt": receipt.path,
            "inspectFoundationHome": inspectFoundationHome,
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        try data.write(to: executable.appendingPathExtension("json"))
        try body(executable, root, receipt)
#endif
    }

    func testExactCounterfeitProtocolControlCompletesLocalProbe() throws {
        try fixture(mode: "valid") { executable, _, _ in
            let result = try RightClickStdioProbe.run(executable: executable.path)
            XCTAssertTrue(result.contains("AI client handshake NOT_OBSERVED"))
        }
    }

    func testRuntimeIdentityTextRejectsDuplicateIdenticalPID() throws {
        try fixture(mode: "same_pid") { executable, _, _ in
            XCTAssertThrowsError(try RightClickStdioProbe.run(executable: executable.path)) { error in
                XCTAssertTrue(String(describing: error).contains("runtime identity"),
                    "A transport timeout cannot prove duplicate identity rejection.")
            }
        }
    }

    func testRuntimeIdentityTextRejectsConflictingPIDWithExpectedValueFirst() throws {
        try fixture(mode: "conflicting_expected_first") { executable, _, _ in
            XCTAssertThrowsError(try RightClickStdioProbe.run(executable: executable.path)) { error in
                XCTAssertTrue(String(describing: error).contains("runtime identity"),
                    "A transport timeout cannot prove duplicate identity rejection.")
            }
        }
    }

    func testRuntimeIdentityTextRejectsConflictingPIDWithExpectedValueLast() throws {
        try fixture(mode: "conflicting_expected_last") { executable, _, _ in
            XCTAssertThrowsError(try RightClickStdioProbe.run(executable: executable.path)) { error in
                XCTAssertTrue(String(describing: error).contains("runtime identity"),
                    "A transport timeout cannot prove duplicate identity rejection.")
            }
        }
    }

#if os(macOS)
    func testProbeChildFoundationHomeRemainsInsideExplicitLexicalHome() throws {
        try fixture(mode: "valid", inspectFoundationHome: true) { executable, root, receipt in
            let isolatedHome = root.appendingPathComponent("isolated-home")
            try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let previous = getenv("HOME").map { String(cString: $0) }
            setenv("HOME", isolatedHome.path, 1)
            defer {
                if let previous { setenv("HOME", previous, 1) }
                else { unsetenv("HOME") }
            }
            _ = try RightClickStdioProbe.run(executable: executable.path)
            let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
            XCTAssertEqual(recorded["HOME"] as? String, isolatedHome.path)
            XCTAssertEqual(recorded["CFFIXED_USER_HOME"] as? String, isolatedHome.path)
            XCTAssertEqual(recorded["foundationExitCode"] as? Int, 0)
            let reported = try XCTUnwrap(recorded["foundationHome"] as? String)
            XCTAssertEqual(URL(fileURLWithPath: reported).resolvingSymlinksInPath().path,
                           isolatedHome.resolvingSymlinksInPath().path)
        }
    }
#endif
}
