import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickCore

/// Frozen pressure test: a genuine A2A task is accepted before its effect exists.
final class RCIRDeferredProductionTests: XCTestCase {
    func testAcceptedRemoteTaskRemainsPendingUntilLaterObservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-red-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = try NativeHTTPFixture.python()
        process.arguments = [root.appendingPathComponent("scripts/a2a-proof-agent.py").path, directory.path, "--hold-until-file"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(at: directory) }
        let portFile = directory.appendingPathComponent("port")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: portFile.path) { Thread.sleep(forTimeInterval: 0.01) }
        let base = URL(string: "http://127.0.0.1:" + (try String(contentsOf: portFile, encoding: .utf8)))!
        let capability = Capability(id: "deferred-proof", title: "Remote proof", source: .system,
            reflectorID: "deferred-proof", safety: .localReversible, invocation: .direct,
            supportLevel: .publicSupported, requiresConfirmation: false,
            metadata: ["executionMode": "deferred"])
        let abi = try capability.abiContract(arguments: .null, result: .string)
        let scope = RCIRScope(base.absoluteString, .execute)
        let host = RCIRExecutionHost()
        let challenge = UUID().uuidString
        let message = String(data: try JSONSerialization.data(withJSONObject: ["challenge": challenge, "value": "requested"]), encoding: .utf8)!
        let body: [String: Any] = ["jsonrpc": "2.0", "id": "request-1", "method": "message/send",
            "params": ["message": ["kind": "message", "role": "user", "messageId": UUID().uuidString,
                                     "parts": [["kind": "text", "text": message]]]]]
        let result = try host.execute(abi: abi, discovery: abi, arguments: .null, scope: scope,
            capability: capability, executionID: UUID().uuidString, argumentStrings: nil,
            item: try ContentParser.parse("proof"), verification: nil, expectedOutput: nil, target: base,
            authority: { [scope] }, revalidate: { true }, dispatch: { taskID, admit in
                var request = URLRequest(url: base.appendingPathComponent("a2a")); request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(taskID, forHTTPHeaderField: "X-RightClick-Invocation")
                var response = Data()
                try admit { response = try! OriginPinnedHTTP.loadObservation(request, maximumBytes: 65536) }
                return ExecutionRecord(executionId: "", actionId: capability.id, state: .started,
                    message: "A2A submitted", output: String(data: response, encoding: .utf8))
            }, resultValue: { .string($0.output ?? "") })
        XCTAssertEqual(result.state, .started, "Accepted remote work must remain pending")
        XCTAssertEqual(result.rcir?.phase, "accepted", "The host must retain a nonterminal task")
        XCTAssertEqual(result.rcir?.outcome, "unverified")
        XCTAssertNil(result.rcir?.signedReceipt, "There is no terminal receipt at acceptance")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("effects/" + challenge).path))
        if let path = ProcessInfo.processInfo.environment["RCIR_DEFERRED_EVIDENCE"] {
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: destination.appendingPathComponent("initial-task.json"))
            try Data(contentsOf: directory.appendingPathComponent("requests.jsonl")).write(to: destination.appendingPathComponent("actual-requests.jsonl"))
        }
    }
}
