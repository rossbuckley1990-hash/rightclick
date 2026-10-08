#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

/// Real no-op HTTP acknowledgement and independent file read-back. The exact
/// old bytes are already present before this invocation reaches the provider.
final class RCIRHTTPJSONCausalityTests: XCTestCase {
    private var directory: URL!
    private var processes: [Process] = []
    private var observer: URL!
    private var host: RCIRExecutionHost!
    private var engine: CapabilityEngine!
    private var config = RCIRHostConfiguration()
    private var capability: Capability!
    private var key: Curve25519.Signing.PrivateKey!
    private let item = "actual independent HTTP causal pressure"
    private let challenge = "fixed-disposable-resource"
    private let value = "requested-but-already-present"
    private let oldMarker = "11111111-1111-4111-8111-111111111111"

    override func setUpWithError() throws {
        directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("http-causality-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        for flag in ["ack-response", "include-invocation"] { try Data().write(to: directory.appendingPathComponent(flag)) }
        let token = directory.appendingPathComponent("observer.token")
        try NativeHTTPFixture.writePrivate(Data(UUID().uuidString.utf8), to: token)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var provider: URL!
        for role in ["provider", "observer"] {
            let process = Process(); process.executableURL = try NativeHTTPFixture.python()
            process.arguments = [root.appendingPathComponent("scripts/rcir-http-json-fixture.py").path, directory.path, role]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try NativeHTTPFixture.runFixture(process); processes.append(process)
            let port = directory.appendingPathComponent(role + "-port")
            let number = try NativeHTTPFixture.waitForPort(port, process: process)
            let address = try XCTUnwrap(URL(string: "http://127.0.0.1:\(number)"))
            if role == "provider" { provider = address } else { observer = address }
        }
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["id", "value"],
            "properties": ["id": ["type": "string"], "value": ["type": "string"]]]
        let spec: [String: Any] = ["openapi": "3.0.3", "info": ["title": "Causal ACK-only pressure", "version": "1"],
            "paths": ["/records": ["post": ["operationId": "write", "requestBody": ["required": true,
                "content": ["application/json": ["schema": schema]]], "responses": ["202": ["description": "Accepted"]]]]]]
        let reflector = try OpenAPIReflector(specificationData: JSONSerialization.data(withJSONObject: spec), baseURL: provider)
        host = RCIRExecutionHost(); host.configuration = { self.config }
        key = Curve25519.Signing.PrivateKey()
        config.signingKeyFile = directory.appendingPathComponent("signer.raw").path
        try NativeHTTPFixture.writePrivate(key.rawRepresentation, to: URL(fileURLWithPath: config.signingKeyFile!))
        engine = CapabilityEngine(reflectors: [reflector], experience: nil, rcirHost: host)
        capability = try XCTUnwrap(engine.capabilities(for: item).capabilities.first)
    }
    override func tearDownWithError() throws {
        for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() }
        if let directory {
            try NativeHTTPFixture.remove(directory)
        }
        processes.removeAll(); engine = nil; host = nil
    }
    private func configure(causal: Bool = true) throws {
        let names = ["challenge", "result", "machine", "observation", "observerPrincipal", "platform", "principal", "invocationID"]
        let properties = Dictionary(uniqueKeysWithValues: names.map { ($0, ["type": "string"]) }).merging(["uid": ["type": "null"]]) { _, value in value }
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": Array(properties.keys), "additionalProperties": false]
        var raw: [String: Any] = ["schemaJSON": String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self),
            "fields": ["challenge": ["path": ["challenge"], "argument": "id"], "result": ["path": ["result"], "expectedOutput": true]]]
        // JSON decoding freezes the requested host configuration without needing
        // a new constructor that would make the original RED fail to compile.
        if causal { raw["invocationBindingPath"] = ["invocationID"] }
        let json = try JSONDecoder().decode(RCIRJSONObservationConfiguration.self, from: JSONSerialization.data(withJSONObject: raw))
        config.observers = [capability.id: .init(urlTemplate: observer.absoluteString + "/observations/{id}",
            trustedOrigin: observer.absoluteString, credentialFile: directory.appendingPathComponent("observer.token").path, jsonObservation: json)]
    }
    private func seedNoOp(marker: String?) throws {
        try Data().write(to: directory.appendingPathComponent("noop-provider"))
        let records = directory.appendingPathComponent("records")
        try Data(value.utf8).write(to: records.appendingPathComponent(challenge))
        if let marker { try Data(marker.utf8).write(to: records.appendingPathComponent(challenge + ".invocation")) }
    }
    private func invoke() throws -> ExecutionRecord {
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return try engine.begin(id: capability.id, item: item, confirmed: true,
            arguments: ["id": challenge, "value": value], expectedOutput: digest)
    }
    private func effects() throws -> [[String: Any]] {
        try FixtureLineFraming.objects(at: directory.appendingPathComponent("effects.jsonl"))
    }
    private func preserve(_ record: ExecutionRecord) throws {
        let envelope = try XCTUnwrap(record.rcir?.signedReceipt)
        let signed = try RCIRSignedReceipt(payload: XCTUnwrap(Data(base64Encoded: envelope.payload)),
            signature: XCTUnwrap(Data(base64Encoded: envelope.signature)), publicKey: XCTUnwrap(Data(base64Encoded: envelope.publicKey)))
        try signed.verify(trustedPublicKey: key.publicKey.rawRepresentation, using: RCIREd25519Verifier())
        guard let path = ProcessInfo.processInfo.environment["RIGHTCLICK_HTTP_CAUSAL_EVIDENCE"] else { return }
        let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let label = name.replacingOccurrences(of: "/", with: "_")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: output.appendingPathComponent(label + "-record.json"))
        try signed.wireData().write(to: output.appendingPathComponent(label + "-receipt.json"))
        try key.publicKey.rawRepresentation.write(to: output.appendingPathComponent(label + "-trusted-key.raw"))
        try JSONSerialization.data(withJSONObject: try effects(), options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(label + "-effects.json"))
    }
    func testNoOpAcknowledgementAndOldMatchingArtifactCannotVerifyCurrentMutation() throws {
        try configure(); try seedNoOp(marker: oldMarker)
        let record = try invoke(); try preserve(record)
        XCTAssertEqual(try effects().count, 1); XCTAssertEqual(try effects().first?["mutationApplied"] as? Bool, false)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("records/" + challenge + ".invocation"), encoding: .utf8), oldMarker)
        XCTAssertEqual(record.state, .failed, record.message); XCTAssertEqual(record.rcir?.outcome, "failed")
        XCTAssertFalse(record.evidence.outcomeVerified)
    }
    func testFreshIndependentMarkerMatchesHostTaskAndProducesSignedSuccess() throws {
        try configure(); let record = try invoke(); try preserve(record)
        XCTAssertEqual(record.state, .succeeded, record.message); XCTAssertEqual(record.rcir?.outcome, "succeeded")
        XCTAssertEqual(try effects().first?["mutationApplied"] as? Bool, true)
        XCTAssertEqual(try effects().first?["invocationID"] as? String, record.rcir?.taskID)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("records/" + challenge + ".invocation"), encoding: .utf8), record.rcir?.taskID)
    }
    func testMissingIndependentMarkerRemainsSignedUnverified() throws {
        try configure(); try seedNoOp(marker: nil)
        let record = try invoke(); try preserve(record)
        XCTAssertEqual(record.state, .accepted); XCTAssertEqual(record.rcir?.outcome, "unverified")
        XCTAssertEqual(try effects().first?["mutationApplied"] as? Bool, false)
    }
    func testStateOnlyPredicateDoesNotClaimCurrentMutationCausality() throws {
        try configure(causal: false); try seedNoOp(marker: oldMarker)
        let record = try invoke(); try preserve(record)
        XCTAssertEqual(record.state, .succeeded); XCTAssertEqual(record.rcir?.outcome, "succeeded")
        XCTAssertTrue(record.rcir?.observationBoundary.contains("state predicate") == true)
        XCTAssertEqual(try effects().first?["mutationApplied"] as? Bool, false)
    }
    func testObserverCannotReflectProtectedCredentialIntoMetadataOrReceipt() throws {
        try configure()
        let token = try String(contentsOf: directory.appendingPathComponent("observer.token"), encoding: .utf8)
        var diagnostics: [[String: Any]] = []
        for mode in ["raw", "base64", "base64url", "base64-authorization", "hex", "json-unicode"] {
            try Data(mode.utf8).write(to: directory.appendingPathComponent("echo-observer-credential"))
            let record = try invoke()
            let wire = try JSONEncoder().encode(record)
            let payload = Data(base64Encoded: try XCTUnwrap(record.rcir?.receipt))!
            let leaked = payload.range(of: Data(token.utf8)) != nil || wire.range(of: Data(token.utf8)) != nil
            diagnostics.append(["encoding": mode, "secretLeaked": leaked, "outcome": record.rcir?.outcome ?? "missing", "actualRequests": try effects().count])
            XCTAssertEqual(record.state, .accepted); XCTAssertEqual(record.rcir?.outcome, "unverified")
            XCTAssertFalse(leaked); XCTAssertNotNil(record.rcir?.signedReceipt)
        }
        // Preserve diagnostic booleans only; even the RED artifact must not
        // republish the private disposable credential or its leaking receipt.
        if let path = ProcessInfo.processInfo.environment["RIGHTCLICK_HTTP_CAUSAL_EVIDENCE"] {
            let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["test": name, "encodings": diagnostics], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("credential-reflection-diagnostic.json"))
        }
        XCTAssertEqual(try effects().count, 6)
    }
    func testInvalidCausalBindingPathsRejectBeforeActualMutation() throws {
        try configure()
        let original = try XCTUnwrap(config.observers?[capability.id])
        for invalid in [[], ["*"], [""], ["marker\n"], Array(repeating: "marker", count: 33)] {
            var modified = original
            modified.jsonObservation?.invocationBindingPath = invalid
            config.observers = [capability.id: modified]
            let record = try invoke()
            XCTAssertEqual(record.state, .rejected); XCTAssertTrue(try effects().isEmpty)
        }
    }
}
