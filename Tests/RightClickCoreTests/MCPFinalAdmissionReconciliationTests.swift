import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore

// Coordinator must copy mcp-admission-race.py into Tests/Fixtures.
final class MCPFinalAdmissionReconciliationTests: XCTestCase {
    func testProviderContractReplacementInsideFinalAdmissionDoesNotInvokeOldContract() throws {
        let directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("mcp-admission-race-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = try NativeHTTPFixture.python()
        process.arguments = [root.appendingPathComponent("Tests/Fixtures/mcp-admission-race.py").path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let port = directory.appendingPathComponent("port")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: port.path), Date() < deadline {
            guard process.isRunning else { throw RightClickError("MCP fixture exited") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let endpoint = "http://127.0.0.1:" + (try String(contentsOf: port, encoding: .utf8)) + "/mcp"
        let reflector = try MCPCapabilityArtifactResolver().resolve(.init(id: "race", kind: "mcp", endpointURL: endpoint))
        let host = RCIRExecutionHost()
        host.configuration = { RCIRHostConfiguration() }
        host.invocationJournal = { nil }
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil, rcirHost: host)
        let capability = try XCTUnwrap(engine.capabilities(for: "mutation").capabilities.first)
        host.beforeStart = { _, admit, enqueue in
            try Data().write(to: directory.appendingPathComponent("changed"))
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(enqueue) { start in try permit(start) }
            }
        }
        let result = try engine.begin(id: capability.id, item: "mutation", confirmed: true, arguments: ["challenge": "proof"])
        XCTAssertEqual(result.state, .rejected)
        XCTAssertFalse(result.rcir?.leaseConsumed ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("effects.jsonl").path))
        XCTAssertTrue(try engine.capabilities(for: "mutation").capabilities.isEmpty)
    }
}
