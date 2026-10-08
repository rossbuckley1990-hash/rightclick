#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

/// Real A2A effects and a separate read-only observer pressure-test retained
/// signing authority. Only disposable fixture keys are withdrawn or rotated.
final class RCIRSigningLifecycleTests: XCTestCase {
    private var directory: URL!
    private var agent: Process!
    private var observer: Process!
    private var engine: CapabilityEngine!
    private var host: RCIRExecutionHost!
    private var config = RCIRHostConfiguration()
    private var capability: Capability!
    private var keyFile: URL!
    private var publicKey: Data!
    private var freshPublicKey: Data?
    private var records: [ExecutionRecord] = []

    private func launch(_ script: String) throws -> Process {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = try NativeHTTPFixture.python()
        process.arguments = [root.appendingPathComponent("scripts/" + script).path, directory.path]
        if script == "a2a-proof-agent.py" { process.arguments!.append("--hold-until-file") }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); return process
    }
    private func waitFor(_ file: URL) throws {
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: file.path) { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Real fixture did not produce its artifact")
    }
    private func key(at file: URL) throws -> Data {
        let key = Curve25519.Signing.PrivateKey()
        if FileManager.default.fileExists(atPath: file.path) {
            try NativeHTTPFixture.release(file)
            try key.rawRepresentation.write(to: file)
            try NativeHTTPFixture.protect(file)
        } else { try NativeHTTPFixture.writePrivate(key.rawRepresentation, to: file) }
        return key.publicKey.rawRepresentation
    }
    override func setUpWithError() throws {
        directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("rcir-signing-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        agent = try launch("a2a-proof-agent.py"); observer = try launch("a2a-proof-observer.py")
        let port = directory.appendingPathComponent("port"), observerPort = directory.appendingPathComponent("observer-port")
        try waitFor(port); try waitFor(observerPort)
        let base = "http://127.0.0.1:" + (try String(contentsOf: port, encoding: .utf8))
        let observe = "http://127.0.0.1:" + (try String(contentsOf: observerPort, encoding: .utf8))
        let providers = directory.appendingPathComponent("providers.json")
        try NativeHTTPFixture.writePrivate(JSONSerialization.data(withJSONObject: ["version": 1, "agentCards": [base + "/.well-known/agent.json"]]), to: providers)
        host = RCIRExecutionHost(); host.configuration = { [weak self] in
            guard let self else { throw RCIRError.authorityDenied }; return self.config
        }
        engine = CapabilityEngine(reflectorSources: [ConfiguredA2ASource(configurationFile: providers)], experience: nil, rcirHost: host)
        capability = try XCTUnwrap(engine.capabilities(for: "signing lifecycle proof").capabilities.first)
        var check = RCIRHostConfiguration.Observer(urlTemplate: observe + "/observations/{message}", expectedArgument: "message")
        check.trustedOrigin = observe; config.observers = [capability.id: check]
        keyFile = directory.appendingPathComponent("signer.raw")
        publicKey = try key(at: keyFile); config.signingKeyFile = keyFile.path
    }
    override func tearDownWithError() throws {
        for process in [agent, observer] where process?.isRunning == true { process?.terminate(); process?.waitUntilExit() }
        if let path = ProcessInfo.processInfo.environment["RCIR_SIGNING_EVIDENCE"] {
            let output = URL(fileURLWithPath: path).appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: output.appendingPathComponent("runtime-records.json"))
            try publicKey.write(to: output.appendingPathComponent("original-public-key.raw"))
            try freshPublicKey?.write(to: output.appendingPathComponent("fresh-public-key.raw"))
            for file in ["requests.jsonl", "polls.jsonl", "effects.jsonl", "observations.jsonl", "unary-effects.jsonl"] {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(file)) { try data.write(to: output.appendingPathComponent(file)) }
            }
        }
        if let directory { try? NativeHTTPFixture.remove(directory) }
        engine = nil; host = nil
    }
    private func rows(_ filename: String) throws -> [[String: Any]] {
        try FixtureLineFraming.objects(at: directory.appendingPathComponent(filename))
    }
    private func begin(priorEffects: Int = 0) throws -> ExecutionRecord {
        let message = String(data: try JSONSerialization.data(withJSONObject: ["challenge": UUID().uuidString, "value": "signer-lifecycle"], options: [.sortedKeys]), encoding: .utf8)!
        let initial = try engine.begin(id: capability.id, item: "signing lifecycle proof", confirmed: true, arguments: ["message": message])
        records.append(initial); XCTAssertEqual(initial.state, .started)
        XCTAssertEqual(try rows("effects.jsonl").count, priorEffects)
        return initial
    }
    private func releaseEffect() throws {
        try Data().write(to: directory.appendingPathComponent("release"))
        try waitFor(directory.appendingPathComponent("effects.jsonl"))
        XCTAssertEqual(try rows("effects.jsonl").count, 1, "A real external effect is required before evaluating evidence")
    }
    private func finish(_ initial: ExecutionRecord) -> ExecutionRecord {
        var final = initial
        for _ in 0..<100 {
            final = engine.executionStatus(initial.executionId); records.append(final)
            if final.state != .started && final.state != .awaitingUser { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return final
    }
    private func signature(_ record: ExecutionRecord, trustedKey: Data) throws {
        let envelope = try XCTUnwrap(record.rcir?.signedReceipt)
        let signed = try RCIRSignedReceipt(payload: XCTUnwrap(Data(base64Encoded: envelope.payload)),
            signature: XCTUnwrap(Data(base64Encoded: envelope.signature)), publicKey: XCTUnwrap(Data(base64Encoded: envelope.publicKey)))
        try signed.verify(trustedPublicKey: trustedKey, using: RCIREd25519Verifier())
    }
    private func unsigned(_ final: ExecutionRecord) throws {
        XCTAssertTrue(final.rcir?.signedReceipt == nil, "Withdrawn or replaced provisioned signer must not issue a retained old-key signature")
        XCTAssertNotNil(final.rcir?.receipt, "Unsigned terminal truth remains available")
        XCTAssertTrue(final.events.contains(RCIRReceiptEmission.withheldEvent))
        XCTAssertEqual(try rows("requests.jsonl").count, 1, "Signing failure must never replay a mutation")
        XCTAssertEqual(try rows("effects.jsonl").count, 1)
    }
    func testUnchangedProvisionedSignerSignsGenuineEffect() throws {
        let initial = try begin(); try releaseEffect(); let final = finish(initial)
        XCTAssertEqual(final.state, .succeeded); XCTAssertTrue(final.evidence.outcomeVerified)
        XCTAssertEqual(try rows("observations.jsonl").count, 1); try signature(final, trustedKey: publicKey)
    }
    func testWithdrawnKeyDoesNotSignAlreadyAdmittedVerifiedEffect() throws {
        let initial = try begin(); try NativeHTTPFixture.release(keyFile); try FileManager.default.removeItem(at: keyFile)
        try releaseEffect(); let final = finish(initial)
        XCTAssertEqual(final.state, .succeeded); XCTAssertEqual(final.rcir?.outcome, "succeeded")
        XCTAssertTrue(final.evidence.outcomeVerified); try unsigned(final)
    }
    func testSamePathKeyRotationDoesNotSignWithRetainedOldKey() throws {
        let initial = try begin(); _ = try key(at: keyFile)
        try releaseEffect(); let final = finish(initial)
        XCTAssertEqual(final.state, .succeeded); XCTAssertTrue(final.evidence.outcomeVerified); try unsigned(final)
    }
    func testSignerReferenceRotationPreservesUnknownEffectWithoutOldSignature() throws {
        let initial = try begin()
        let replacement = directory.appendingPathComponent("replacement.raw"); _ = try key(at: replacement)
        config.signingKeyFile = replacement.path
        try releaseEffect(); let final = finish(initial)
        XCTAssertEqual(final.state, .unknown); XCTAssertEqual(final.rcir?.outcome, "unknown")
        XCTAssertFalse(final.evidence.outcomeVerified); XCTAssertTrue(try rows("observations.jsonl").isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyFile.path), "Old bytes still exist; current host reference is the boundary")
        try unsigned(final)
    }
    func testWithdrawnKeyAfterRealEffectAndProviderLossPreservesUnknown() throws {
        let initial = try begin(); try releaseEffect()
        agent.terminate(); agent.waitUntilExit()
        try NativeHTTPFixture.release(keyFile); try FileManager.default.removeItem(at: keyFile)
        let final = finish(initial)
        XCTAssertEqual(final.state, .unknown); XCTAssertEqual(final.rcir?.outcome, "unknown")
        XCTAssertFalse(final.evidence.outcomeVerified); try unsigned(final)
    }
    func testFreshInvocationAfterRotationUsesNewProvisionedKey() throws {
        let initial = try begin(); freshPublicKey = try key(at: keyFile)
        try releaseEffect(); let old = finish(initial); try unsigned(old)
        let fresh = try begin(priorEffects: 1); let final = finish(fresh)
        XCTAssertEqual(final.state, .succeeded); XCTAssertTrue(final.evidence.outcomeVerified)
        XCTAssertEqual(try rows("requests.jsonl").count, 2); XCTAssertEqual(try rows("effects.jsonl").count, 2)
        XCTAssertNotEqual(final.rcir?.taskID, old.rcir?.taskID)
        try signature(final, trustedKey: XCTUnwrap(freshPublicKey))
    }
    func testKeyWithdrawalAtAdmissionBoundaryHasZeroProviderEffects() throws {
        host.beforeStart = { _, admit, start in
            try NativeHTTPFixture.release(self.keyFile); try FileManager.default.removeItem(at: self.keyFile)
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(start) { enqueue in try permit(enqueue) }
            }
        }
        let message = "{\"challenge\":\"" + UUID().uuidString + "\",\"value\":\"admission-control\"}"
        let denied = try engine.begin(id: capability.id, item: "signing lifecycle proof", confirmed: true, arguments: ["message": message])
        records.append(denied)
        XCTAssertEqual(denied.state, .rejected); XCTAssertNil(denied.rcir)
        XCTAssertTrue(try rows("requests.jsonl").isEmpty); XCTAssertTrue(try rows("effects.jsonl").isEmpty)
    }
    private final class SingleSource: CapabilityReflectorSource {
        let id = "test.signing-lifecycle-unary"
        let reflector: OpenAPIReflector
        init(_ reflector: OpenAPIReflector) { self.reflector = reflector }
        func reflectors() -> [any CapabilityReflector] { [reflector] }
    }
    func testUnaryHTTPAfterKeyWithdrawalRetainsActualEffectAndUnsignedTruth() throws {
        let rest = directory.appendingPathComponent("rest")
        try FileManager.default.createDirectory(at: rest, withIntermediateDirectories: false)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let provider = Process(); provider.executableURL = try NativeHTTPFixture.python()
        provider.arguments = [root.appendingPathComponent("scripts/rcir-dispatch-test-provider.py").path, rest.path]
        provider.standardOutput = FileHandle.nullDevice; provider.standardError = FileHandle.nullDevice
        try provider.run(); defer { if provider.isRunning { provider.terminate(); provider.waitUntilExit() } }
        let port = rest.appendingPathComponent("port"); try waitFor(port)
        let base = URL(string: "http://127.0.0.1:" + (try String(contentsOf: port, encoding: .utf8)))!
        let schema: [String: Any] = ["type":"object", "additionalProperties":false, "required":["id", "value"],
            "properties":["id":["type":"string"], "value":["type":"string"]]]
        let content = ["application/json":["schema":schema]]
        let spec: [String: Any] = ["openapi":"3.0.3", "info":["title":"Signing lifecycle unary", "version":"1"],
            "paths":["/records":["post":["operationId":"persist", "requestBody":["required":true, "content":content],
                "responses":["200":["description":"ACK", "content":content]]]]]]
        let reflector = try OpenAPIReflector(specificationData: JSONSerialization.data(withJSONObject: spec), baseURL: base)
        let unary = CapabilityEngine(reflectorSources:[SingleSource(reflector)], experience:nil, rcirHost:host)
        let cap = try XCTUnwrap(unary.capabilities(for:"unary proof").capabilities.first)
        host.beforeStart = { _, admit, start in
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(start) { enqueue in
                    try permit {
                        enqueue()
                        try? NativeHTTPFixture.release(self.keyFile)
                        try? FileManager.default.removeItem(at: self.keyFile)
                    }
                }
            }
        }
        let final = try unary.begin(id:cap.id, item:"unary proof", confirmed:true, arguments:["id":"unary-signing", "value":"real-effect"])
        records.append(final)
        XCTAssertFalse(FileManager.default.fileExists(atPath:keyFile.path))
        XCTAssertEqual(final.state, .accepted); XCTAssertEqual(final.rcir?.outcome, "unverified")
        XCTAssertFalse(final.evidence.outcomeVerified)
        XCTAssertTrue(final.rcir?.signedReceipt == nil); XCTAssertNotNil(final.rcir?.receipt)
        XCTAssertTrue(final.events.contains(RCIRReceiptEmission.withheldEvent))
        let effects = try Data(contentsOf:rest.appendingPathComponent("effects.jsonl"))
        try effects.write(to:directory.appendingPathComponent("unary-effects.jsonl"))
        XCTAssertEqual(try rows("unary-effects.jsonl").count, 1)
        XCTAssertEqual(try rows("unary-effects.jsonl").first?["taskID"] as? String, final.rcir?.taskID)
        XCTAssertTrue(try rows("effects.jsonl").isEmpty)
    }
}
