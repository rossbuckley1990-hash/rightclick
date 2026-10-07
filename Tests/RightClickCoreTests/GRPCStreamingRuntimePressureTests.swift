#if canImport(GRPC) && canImport(SwiftProtobuf) && canImport(NIOCore) && canImport(NIOPosix)
import Foundation
import XCTest
@testable import RightClickCore

/// Real reflected transport control, then the unchanged common runtime entry.
/// Absence of the official SDK fixture is an explicit environment exclusion;
/// no synthetic descriptor or fake callback can establish this proof.
final class GRPCStreamingRuntimePressureTests: XCTestCase {
    func testRealReflectedServerStreamUsesRetainedTypedTask() throws {
        guard let interpreter = ProcessInfo.processInfo.environment["RIGHTCLICK_TEST_GRPC_PYTHON"] else {
            throw XCTSkip("Official isolated gRPC SDK fixture must be provisioned")
        }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/grpc-stream-pressure-provider.py")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-grpc-pressure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let provider = Process(), stdout = Pipe()
        provider.executableURL = URL(fileURLWithPath: interpreter)
        provider.arguments = [script.path, "--directory", directory.path]
        provider.standardOutput = stdout
        provider.standardError = FileHandle.nullDevice
        try provider.run()
        defer {
            if provider.isRunning { provider.terminate(); provider.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        var line = Data()
        while line.last != 10 {
            let byte = stdout.fileHandleForReading.readData(ofLength: 1)
            guard !byte.isEmpty, line.count < 32 else { throw RCIRError.unavailable }
            line.append(byte)
        }
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let challenge = "pressure-" + UUID().uuidString
        let native = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: interpreter),
            arguments: [script.path, "--control", String(port), "--challenge", challenge + "-control"],
            timeout: 6, maximumBytes: 8192)
        let nativeValues = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [[String: Any]])
        XCTAssertEqual(nativeValues.count, 3)
        XCTAssertEqual(nativeValues.compactMap { $0["value"] as? String }, (1...3).map { challenge + "-control:" + String($0) })

        let endpoint = try GRPCEndpoint(scheme: "grpc", host: "127.0.0.1", port: port)
        let acquired = try GRPCReflectionTransport.discover(endpoint: endpoint)
        let reflector = try GRPCReflector(descriptorData: acquired, endpoint: endpoint)
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        let capabilities = try engine.capabilities(for: "Native stream pressure").capabilities
        let capability = try XCTUnwrap(capabilities.first { $0.metadata["rpcPath"] == "/rightclick.pressure.Streams/Read" })
        XCTAssertEqual(capability.metadata["callType"], "server_streaming")
        let result = try engine.begin(id: capability.id, item: "Native stream pressure", confirmed: true,
                                      arguments: ["challenge": challenge])
        if let root = ProcessInfo.processInfo.environment["RIGHTCLICK_GRPC_PRESSURE_EVIDENCE"] {
            let out = URL(fileURLWithPath: root)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(capability).write(to: out.appendingPathComponent("acquired-capability.json"))
            try encoder.encode(result).write(to: out.appendingPathComponent("runtime-result.json"))
            try native.write(to: out.appendingPathComponent("native-control.json"))
            try Data(contentsOf: directory.appendingPathComponent("stream-events.jsonl"))
                .write(to: out.appendingPathComponent("independent-native-journal.jsonl"))
            for (index, data) in acquired.enumerated() {
                try data.write(to: out.appendingPathComponent("actual-descriptor-" + String(index) + ".pb"))
            }
        }
        XCTAssertNotEqual(result.state, .unsupported,
            "Real native server-streaming works, but reflected streaming cannot enter the common retained task host")
        XCTAssertNotNil(result.rcir, "A live stream must retain admitted typed task evidence")
    }
}
#endif
