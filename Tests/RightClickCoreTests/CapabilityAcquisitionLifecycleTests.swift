@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
import XCTest
@testable import RightClickCore

/// Freeze the desired lifecycle before implementing freshness. The source
/// configuration stays byte-identical while the provider changes underneath it.
final class CapabilityAcquisitionLifecycleTests: XCTestCase {
    private func specification(_ operation: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "openapi": "3.0.3",
            "info": ["title": "Lifecycle proof", "version": "1"],
            "paths": ["/proof": ["get": [
                "operationId": operation,
                "responses": ["200": ["description": "proof", "content": [
                    "text/plain": ["schema": ["type": "string"]]
                ]]]
            ]]]
        ], options: [.sortedKeys])
    }

    func testUnchangedConfigurationDoesNotRetainWithdrawnProviderForever() throws {
        let directory = NativeHTTPFixture.temporaryDirectory
            .appendingPathComponent("rightclick-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("providers.json")
        try ConfiguredOpenAPIProviderStore.write([
            .init(id: "proof", specificationURL: "https://proof.example/openapi.json",
                  baseURL: "https://proof.example")
        ], to: file)
        let frozenConfiguration = try Data(contentsOf: file)
        var available = true
        var loads = 0
        let source = ConfiguredOpenAPISource(configurationFile: file, specificationLoader: { _ in
            loads += 1
            guard available else { throw URLError(.cannotConnectToHost) }
            return try self.specification("proof")
        })
        let engine = CapabilityEngine(reflectorSources: [source], experience: nil)
        XCTAssertEqual(try engine.capabilities(for: "challenge").capabilities.count, 1)
        available = false
        // The existing artifact cache has a five-second freshness window. The
        // configured source must also be bounded, without rewriting its file.
        Thread.sleep(forTimeInterval: 5.1)
        XCTAssertTrue(try engine.capabilities(for: "challenge").capabilities.isEmpty)
        XCTAssertTrue(engine.providers().isEmpty)
        XCTAssertGreaterThanOrEqual(loads, 2)
        XCTAssertEqual(try Data(contentsOf: file), frozenConfiguration)
    }

    func testRealProviderWithdrawalAndChangedReappearanceWithUnchangedConfiguration() throws {
        let directory = NativeHTTPFixture.temporaryDirectory
            .appendingPathComponent("rightclick-real-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = directory.appendingPathComponent("requests.jsonl")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/proof-discovery-provider.py")
        func start(_ port: Int, operation: String) throws -> (Process, Int) {
            let process = Process()
            process.executableURL = try NativeHTTPFixture.python()
            process.arguments = [script.path, "--port", String(port), "--operation", operation,
                                 "--evidence", requests.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let ready = pipe.fileHandleForReading.availableData
            let port = try XCTUnwrap(Int(String(decoding: ready, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            return (process, port)
        }
        let (first, port) = try start(0, operation: "proof-v1")
        defer { if first.isRunning { first.terminate(); first.waitUntilExit() } }
        let localSpecification = URL(string: "http://127.0.0.1:\(port)/openapi.json")!
        let file = directory.appendingPathComponent("providers.json")
        try ConfiguredOpenAPIProviderStore.write([
            .init(id: "proof", specificationURL: "https://proof.example/openapi.json",
                  baseURL: "https://proof.example")
        ], to: file)
        let frozenConfiguration = try Data(contentsOf: file)
        // Configured providers require HTTPS. This test injects only the
        // acquisition location to a disposable real loopback HTTP server; it
        // does not change that production URL/credential policy or invoke it.
        let source = ConfiguredOpenAPISource(configurationFile: file, specificationLoader: { _ in
            try OriginPinnedHTTP.loadOpenAPISpecification(localSpecification)
        })
        let engine = CapabilityEngine(reflectorSources: [source], experience: nil)
        XCTAssertEqual(try engine.capabilities(for: "challenge").capabilities
            .compactMap { $0.metadata["operationId"] }, ["proof-v1"])
        first.terminate()
        first.waitUntilExit()
        XCTAssertThrowsError(try OriginPinnedHTTP.loadOpenAPISpecification(localSpecification))
        Thread.sleep(forTimeInterval: 5.1)
        XCTAssertTrue(try engine.capabilities(for: "challenge").capabilities.isEmpty)
        XCTAssertTrue(engine.providers().isEmpty)
        let (second, _) = try start(port, operation: "proof-v2")
        defer { second.terminate(); second.waitUntilExit() }
        Thread.sleep(forTimeInterval: 5.1)
        XCTAssertEqual(try engine.capabilities(for: "challenge").capabilities
            .compactMap { $0.metadata["operationId"] }, ["proof-v2"])
        XCTAssertEqual(try Data(contentsOf: file), frozenConfiguration)
        let events = try String(contentsOf: requests, encoding: .utf8)
        XCTAssertTrue(events.contains("proof-v1"))
        XCTAssertTrue(events.contains("proof-v2"))
        if let evidence = ProcessInfo.processInfo.environment["RIGHTCLICK_LIFECYCLE_EVIDENCE"] {
            try Data(events.utf8).write(to: URL(fileURLWithPath: evidence))
        }
    }
}
