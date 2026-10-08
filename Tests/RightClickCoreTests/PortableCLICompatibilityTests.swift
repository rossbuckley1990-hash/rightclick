#if os(Linux)
import Foundation
import XCTest

/// Real subprocess contracts retained from the exact v0.2.3 portable candidate.
final class PortableCLICompatibilityTests: XCTestCase {
    private func invoke(_ arguments: [String]) throws -> (Int32, Data, String) {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("rightclick")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = binary; process.arguments = arguments
        process.standardOutput = output; process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("RIGHTCLICK_") && $0.key != "DBUS_SESSION_BUS_ADDRESS"
        }
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, bytes, String(decoding: diagnostics, as: UTF8.self))
    }
    func testSetupPreservesRegistrationPreviewWithoutClientWrites() throws {
        let (status, bytes, errors) = try invoke(["setup", "--json"])
        XCTAssertEqual(status, 0, errors)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let servers = try XCTUnwrap(document["mcpServers"] as? [String: Any])
        let registration = try XCTUnwrap(servers["rightclick"] as? [String: Any])
        XCTAssertEqual(registration["args"] as? [String], ["mcp"])
        let command = try XCTUnwrap(registration["command"] as? String)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: command))
    }
    func testRefreshPreservesPortableHostRegistrationCommand() throws {
        let (status, bytes, errors) = try invoke(["refresh"])
        XCTAssertEqual(status, 0, errors)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Refreshed available host registrations."))
    }
    func testAuthorityRemainsUnavailableWithoutSecretStorageFallback() throws {
        let (status, bytes, errors) = try invoke(["authority", "status", "--origin", "https://example.invalid", "--scheme", "Bearer", "--json"])
        XCTAssertEqual(status, 2)
        XCTAssertTrue(bytes.isEmpty)
        XCTAssertTrue(errors.contains("Authority storage is unavailable"))
    }
}
#endif
