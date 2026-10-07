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

/// Genuine separate A2A agent and observer processes exercise runtime controls.
final class A2ARealLifecycleTests: XCTestCase {
    private var directory: URL!
    private var agent: Process!
    private var observer: Process!
    private var source: ConfiguredA2ASource!
    private var engine: CapabilityEngine!
    private var host: RCIRExecutionHost!
    private var config = RCIRHostConfiguration()
    private var capability: Capability!
    private var publicKey: Data!
    private var results: [ExecutionRecord] = []

    private func process(_ script: String) throws -> Process {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/" + script).path, directory.path]
        if script == "a2a-proof-agent.py" { process.arguments!.append("--hold-until-file") }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); return process
    }

    private func port(_ filename: String) throws -> String {
        let file = directory.appendingPathComponent(filename)
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: file.path) { Thread.sleep(forTimeInterval: 0.01) }
        return try String(contentsOf: file, encoding: .utf8)
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("a2a-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        agent = try process("a2a-proof-agent.py"); observer = try process("a2a-proof-observer.py")
        let base = "http://127.0.0.1:" + (try port("port"))
        let observerBase = "http://127.0.0.1:" + (try port("observer-port"))
        let providers = directory.appendingPathComponent("providers.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "agentCards": [base + "/.well-known/agent.json"]]).write(to: providers)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: providers.path)
        source = ConfiguredA2ASource(configurationFile: providers)
        host = RCIRExecutionHost(); host.configuration = { self.config }
        engine = CapabilityEngine(reflectorSources: [source], experience: nil, rcirHost: host)
        capability = try XCTUnwrap(engine.capabilities(for: "delegated proof").capabilities.first)
        var check = RCIRHostConfiguration.Observer(urlTemplate: observerBase + "/observations/{message}", expectedArgument: "message")
        check.trustedOrigin = observerBase
        config.observers = [capability.id: check]
        let key = Curve25519.Signing.PrivateKey(); publicKey = key.publicKey.rawRepresentation
        let keyFile = directory.appendingPathComponent("signer.raw")
        try key.rawRepresentation.write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        config.signingKeyFile = keyFile.path
    }

    override func tearDownWithError() throws {
        for process in [agent, observer] where process?.isRunning == true { process?.terminate(); process?.waitUntilExit() }
        if let path = ProcessInfo.processInfo.environment["RCIR_DEFERRED_EVIDENCE"] {
            let label = name.replacingOccurrences(of: "/", with: "_")
            let out = URL(fileURLWithPath: path).appendingPathComponent(label)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: out.appendingPathComponent("runtime-records.json"))
            for file in ["requests.jsonl", "polls.jsonl", "effects.jsonl", "observations.jsonl", "observation-attempts.jsonl"] {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(file)) { try data.write(to: out.appendingPathComponent(file)) }
            }
            try publicKey.write(to: out.appendingPathComponent("trusted-public-key.raw"))
        }
        try? FileManager.default.removeItem(at: directory)
        engine = nil; host = nil
    }

    private func rows(_ filename: String) -> [[String: Any]] {
        let data = (try? String(contentsOf: directory.appendingPathComponent(filename), encoding: .utf8)) ?? ""
        return data.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    private func invoke(_ value: String = "requested", confirmed: Bool = true) throws -> ExecutionRecord {
        let text = String(data: try JSONSerialization.data(withJSONObject: ["challenge": UUID().uuidString, "value": value], options: [.sortedKeys]), encoding: .utf8)!
        let record = try engine.begin(id: capability.id, item: "delegated proof", confirmed: confirmed, arguments: ["message": text])
        results.append(record); return record
    }

    private func finish(_ initial: ExecutionRecord) throws -> ExecutionRecord {
        try Data().write(to: directory.appendingPathComponent("release"))
        var record = initial
        for _ in 0..<80 {
            record = engine.executionStatus(initial.executionId)
            results.append(record)
            if record.state != .started && record.state != .awaitingUser { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return record
    }

    private func checkSignature(_ record: ExecutionRecord) throws {
        let envelope = try XCTUnwrap(record.rcir?.signedReceipt)
        let signed = try RCIRSignedReceipt(payload: XCTUnwrap(Data(base64Encoded: envelope.payload)),
            signature: XCTUnwrap(Data(base64Encoded: envelope.signature)), publicKey: XCTUnwrap(Data(base64Encoded: envelope.publicKey)))
        try signed.verify(trustedPublicKey: publicKey, using: RCIREd25519Verifier())
    }

    func testGenuineDelegationObservesEffectAndSignsTerminalReceipt() throws {
        let initial = try invoke()
        XCTAssertEqual(initial.state, .started); XCTAssertEqual(initial.rcir?.phase, "accepted")
        XCTAssertEqual(initial.rcir?.outcome, "unverified"); XCTAssertNil(initial.rcir?.receipt)
        XCTAssertTrue(rows("effects.jsonl").isEmpty)
        let final = try finish(initial)
        XCTAssertEqual(final.state, .succeeded, final.message)
        XCTAssertTrue(final.evidence.outcomeVerified); XCTAssertEqual(final.rcir?.outcome, "succeeded")
        XCTAssertEqual(rows("requests.jsonl").count, 1)
        XCTAssertEqual(rows("effects.jsonl").count, 1)
        XCTAssertEqual(rows("observations.jsonl").count, 1)
        XCTAssertEqual(rows("observations.jsonl").first?["invocation"] as? String, initial.rcir?.taskID)
        XCTAssertGreaterThanOrEqual(final.rcir?.taskEvents?.count ?? 0, 2)
        try checkSignature(final)
    }

    func testAcceptedAndCompletedTaskWithMismatchedEffectFailsWithSignedReceipt() throws {
        let final = try finish(invoke("mismatch-effect"))
        XCTAssertEqual(final.state, .failed); XCTAssertEqual(final.rcir?.outcome, "failed")
        XCTAssertFalse(final.evidence.outcomeVerified); try checkSignature(final)
    }

    func testCompletedWithoutIndependentEffectRemainsUnverified() throws {
        let final = try finish(invoke("missing-effect"))
        XCTAssertEqual(final.state, .accepted); XCTAssertEqual(final.rcir?.outcome, "unverified")
        XCTAssertFalse(final.evidence.outcomeVerified); XCTAssertTrue(rows("observations.jsonl").isEmpty)
        try checkSignature(final)
    }

    func testRemoteTaskFailureCannotBecomeSemanticSuccess() throws {
        let final = try finish(invoke("fail-task"))
        XCTAssertEqual(final.state, .failed); XCTAssertFalse(final.evidence.outcomeVerified)
        XCTAssertTrue(rows("effects.jsonl").isEmpty); try checkSignature(final)
    }

    func testProviderDisappearingMidTaskIsSignedUnknownWithoutReplay() throws {
        let initial = try invoke()
        agent.terminate(); agent.waitUntilExit()
        let final = engine.executionStatus(initial.executionId); results.append(final)
        XCTAssertEqual(final.state, .unknown); XCTAssertEqual(final.rcir?.outcome, "unknown")
        XCTAssertTrue(try engine.capabilities(for: "delegated proof").capabilities.isEmpty)
        XCTAssertEqual(rows("requests.jsonl").count, 1)
        XCTAssertEqual(engine.executionStatus(initial.executionId).state, .unknown)
        try checkSignature(final)
    }

    func testPolicyAndConfirmationDenialsHaveZeroDelegatedEffects() throws {
        XCTAssertEqual(try invoke(confirmed: false).state, .awaitingUser)
        config.deniedCapabilities = [capability.id]
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(rows("requests.jsonl").isEmpty)
    }

    func testUnpinnedIndependentObserverFailsBeforeDispatch() throws {
        config.observers![capability.id]!.trustedOrigin = nil
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(rows("requests.jsonl").isEmpty)
    }

    func testPolicyRevocationDuringTaskCannotBeSilentlyIgnored() throws {
        let initial = try invoke()
        config.deniedCapabilities = [capability.id]
        let final = engine.executionStatus(initial.executionId); results.append(final)
        XCTAssertEqual(final.state, .unknown); XCTAssertTrue(rows("effects.jsonl").isEmpty)
        try checkSignature(final)
    }

    func testDeadlineIsUnknownWithoutRetryingOrFabricatingCompletion() throws {
        var time: Int64 = 1000; host.now = { time }
        let initial = try invoke(); time += 30_001
        let final = engine.executionStatus(initial.executionId); results.append(final)
        XCTAssertEqual(final.state, .unknown); XCTAssertEqual(rows("requests.jsonl").count, 1)
        XCTAssertTrue(rows("effects.jsonl").isEmpty); try checkSignature(final)
    }

    func testCompletedUnverifiedTaskCannotObserveAfterPolicyRevocation() throws {
        let completed = try finish(invoke("missing-effect"))
        XCTAssertEqual(completed.state, .accepted); XCTAssertEqual(completed.rcir?.phase, "completed")
        let attempts = rows("observation-attempts.jsonl").count
        XCTAssertGreaterThan(attempts, 0)
        config.deniedCapabilities = [capability.id]
        let request = try XCTUnwrap(rows("requests.jsonl").first)
        let challenge = try XCTUnwrap(request["challenge"] as? String)
        // Make the real postcondition appear only after revocation. The retained
        // verifier could prove it, but current policy no longer permits its read.
        let message = String(data: try JSONSerialization.data(withJSONObject:
            ["challenge": challenge, "value": "missing-effect"], options: [.sortedKeys]), encoding: .utf8)!
        try Data(message.utf8).write(to: directory.appendingPathComponent("effects/" + challenge))
        let final = engine.executionStatus(completed.executionId); results.append(final)
        XCTAssertEqual(final.state, .accepted); XCTAssertEqual(final.rcir?.outcome, "unverified")
        XCTAssertFalse(final.evidence.outcomeVerified)
        XCTAssertEqual(rows("observation-attempts.jsonl").count, attempts)
        try checkSignature(final)
    }
}
