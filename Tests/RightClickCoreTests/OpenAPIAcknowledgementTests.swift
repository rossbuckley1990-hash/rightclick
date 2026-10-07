import CryptoKit
import Foundation
import XCTest
@testable import RightClickCore

/// Actual HTTP mutation plus separate read-only file observation. This is not
/// native Windows full-runtime proof; its ACK contract exposed a generic gap.
final class OpenAPIAcknowledgementTests: XCTestCase {
    private var directory: URL!
    private var processes: [Process] = []
    private var provider: URL!
    private var observer: URL!
    private var host: RCIRExecutionHost!
    private var engine: CapabilityEngine!
    private var config = RCIRHostConfiguration()
    private var capability: Capability!
    private let item = "genuine acknowledgement-only external mutation"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ack-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("ack-response"))
        let token = directory.appendingPathComponent("observer.token")
        try Data(UUID().uuidString.utf8).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for role in ["provider", "observer"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [root.appendingPathComponent("scripts/rcir-http-json-fixture.py").path, directory.path, role]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); processes.append(process)
            let port = directory.appendingPathComponent(role + "-port")
            for _ in 0..<300 { if FileManager.default.fileExists(atPath: port.path) { break }; Thread.sleep(forTimeInterval: 0.01) }
            let address = URL(string: "http://127.0.0.1:" + (try String(contentsOf: port, encoding: .utf8)))!
            if role == "provider" { provider = address } else { observer = address }
        }
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["id", "value"],
            "properties": ["id": ["type": "string", "pattern": "^[A-Za-z0-9_-]{8,128}$"], "value": ["type": "string"]]]
        let spec: [String: Any] = ["openapi": "3.0.3", "info": ["title": "Actual ACK-only HTTP provider", "version": "1"],
            "paths": ["/records": ["post": ["operationId": "write", "requestBody": ["required": true,
                "content": ["application/json": ["schema": schema]]],
                "responses": ["202": ["description": "Effect accepted; verify file independently"]]]]]]
        let reflector = try OpenAPIReflector(specificationData: JSONSerialization.data(withJSONObject: spec), baseURL: provider)
        host = RCIRExecutionHost(); host.configuration = { self.config }
        config.signingKeyFile = directory.appendingPathComponent("signer.raw").path
        try Curve25519.Signing.PrivateKey().rawRepresentation.write(to: URL(fileURLWithPath: config.signingKeyFile!))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.signingKeyFile!)
        engine = CapabilityEngine(reflectors: [reflector], experience: nil, rcirHost: host)
        capability = try engine.capabilities(for: item).capabilities.first { $0.metadata["operationId"] == "write" }
    }

    override func tearDownWithError() throws {
        for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() }
        processes.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        engine = nil; host = nil
    }

    private func configure() throws {
        let capability = try XCTUnwrap(capability, "The acquired ACK-only capability must exist.")
        let properties = Dictionary(uniqueKeysWithValues: ["challenge", "result", "machine", "observation", "observerPrincipal", "platform", "principal"].map { ($0, ["type": "string"]) }).merging(["uid": ["type": "null"]]) { _, value in value }
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": Array(properties.keys), "additionalProperties": false]
        let json = RCIRJSONObservationConfiguration(schemaJSON: String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self),
            fields: ["challenge": .init(path: ["challenge"], argument: "id"), "result": .init(path: ["result"], expectedOutput: true)])
        config.observers = [capability.id: .init(urlTemplate: observer.absoluteString + "/observations/{id}", trustedOrigin: observer.absoluteString,
            credentialFile: directory.appendingPathComponent("observer.token").path, jsonObservation: json)]
    }

    private func invoke(_ value: String = "actual ACK-only effect", expected: Bool = true) throws -> ExecutionRecord {
        let capability = try XCTUnwrap(capability, "The acquired ACK-only capability must exist.")
        let arguments = ["id": UUID().uuidString, "value": value]
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return try engine.begin(id: capability.id, item: item, confirmed: true, arguments: arguments, expectedOutput: expected ? digest : nil)
    }

    private func effectCount() -> Int {
        ((try? String(contentsOf: directory.appendingPathComponent("effects.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private func preserve(_ record: ExecutionRecord, label: String) throws {
        guard let path = ProcessInfo.processInfo.environment["RIGHTCLICK_ACK_HTTP_EVIDENCE"] else { return }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(XCTUnwrap(record.rcir?.signedReceipt)).write(to: output.appendingPathComponent(label + "-receipt.json"))
        // Pin the provisioned fixture key independently before verification;
        // never derive trust from the envelope being checked.
        let provisioned = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: config.signingKeyFile!)))
        try provisioned.publicKey.rawRepresentation.write(to: output.appendingPathComponent(label + "-trusted-key.raw"))
        for file in ["effects.jsonl", "observations.jsonl"] {
            let source = directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: source.path) {
                try Data(contentsOf: source).write(to: output.appendingPathComponent(label + "-" + file))
            }
        }
    }

    func testAcknowledgementHasNoTypedOutputAndRemainsUnverified() throws {
        let record = try invoke(expected: false)
        XCTAssertEqual(record.state, .accepted); XCTAssertEqual(record.rcir?.phase, "completed")
        XCTAssertEqual(record.rcir?.outcome, "unverified"); XCTAssertFalse(record.evidence.outcomeVerified)
        XCTAssertNil(record.output)
        XCTAssertEqual(capability.output, [])
        XCTAssertEqual(capability.metadata["resultValidation"], "no_declared_output")
        XCTAssertEqual(effectCount(), 1)
        XCTAssertNotNil(record.rcir?.signedReceipt)
        try preserve(record, label: "unverified")
    }

    func testIndependentStructuredObservationVerifiesActualEffectAndSignsReceipt() throws {
        try configure(); let record = try invoke()
        XCTAssertEqual(record.state, .succeeded, record.message); XCTAssertEqual(record.rcir?.outcome, "succeeded")
        XCTAssertTrue(record.evidence.outcomeVerified); XCTAssertNil(record.output); XCTAssertEqual(effectCount(), 1)
        let envelope = try XCTUnwrap(record.rcir?.signedReceipt)
        let payload = try XCTUnwrap(Data(base64Encoded: envelope.payload))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: envelope.publicKey)!)
        XCTAssertTrue(publicKey.isValidSignature(Data(base64Encoded: envelope.signature)!, for: payload))
        XCTAssertNotNil(payload.range(of: Data("fixture-readonly".utf8)))
        XCTAssertNotNil(payload.range(of: Data("completedWithoutOutput".utf8)))
        XCTAssertNil(payload.range(of: Data("effect verified".utf8)))
        try preserve(record, label: "success")
    }

    func testAcknowledgementCannotSatisfyCallerReturnedValuePostcondition() throws {
        let record = try invoke()
        XCTAssertEqual(record.state, .accepted); XCTAssertEqual(record.rcir?.outcome, "unverified")
        XCTAssertFalse(record.evidence.outcomeVerified); XCTAssertEqual(effectCount(), 1)
    }

    func testWrongOrMissingExternalEffectNeverBecomesSuccess() throws {
        try configure()
        let mismatch = try invoke("mismatch")
        XCTAssertEqual(mismatch.state, .failed); XCTAssertEqual(mismatch.rcir?.outcome, "failed")
        try preserve(mismatch, label: "failure")
        let missing = try invoke("missing")
        XCTAssertEqual(missing.state, .accepted); XCTAssertEqual(missing.rcir?.outcome, "unverified")
        XCTAssertEqual(effectCount(), 2)
    }

    func testUndeclared2xxStatusRemainsUnknownDespiteActualEffect() throws {
        try configure()
        try Data("200".utf8).write(to: directory.appendingPathComponent("ack-status"))
        let record = try invoke()
        XCTAssertEqual(record.state, .unknown); XCTAssertEqual(record.rcir?.outcome, "unknown")
        XCTAssertFalse(record.evidence.outcomeVerified); XCTAssertEqual(effectCount(), 1)
        XCTAssertNil(record.output)
    }

    func testConfirmationAndCurrentHostPolicyStopAcknowledgementMutation() throws {
        let action = try XCTUnwrap(capability)
        let arguments = ["id": UUID().uuidString, "value": "never dispatched"]
        let gated = try engine.begin(id: action.id, item: item, confirmed: false, arguments: arguments)
        XCTAssertEqual(gated.state, .awaitingUser); XCTAssertEqual(effectCount(), 0)
        config.deniedCapabilities = [action.id]
        let denied = try engine.begin(id: action.id, item: item, confirmed: true, arguments: arguments)
        XCTAssertEqual(denied.state, .rejected); XCTAssertEqual(effectCount(), 0)
    }
}
