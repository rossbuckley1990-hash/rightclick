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

/// Goal pressure test, not a claim that the bare-pin API promised policy. Both
/// receipts come from real same-host A2A effects and a separate read-only observer.
/// Frozen commit 969ce6f passed only the bare pin and failed six policy cases.
/// The same real-effect matrix now exercises the explicit shared trust policy.
final class RCIRReceiptTrustGapTests: XCTestCase {
    private var directory: URL!
    private var processes: [Process] = []
    private var engine: CapabilityEngine!
    private var host: RCIRExecutionHost!
    private var config = RCIRHostConfiguration()
    private var records: [ExecutionRecord] = []
    private var policyMatrix: [[String: Any]] = []
    private var outcomes: [[String: Any]] = []
    private var keys: [Data] = []

    private enum FixtureBoundary: String {
        case directoryProvisioning, agents, providerConfiguration
        case firstSigner, firstEffect, firstSignature
        case rotatedSigner, rotatedEffect, rotatedSignature
    }
    private struct FixtureFailure: Error, CustomStringConvertible {
        let boundary: FixtureBoundary
        let cocoaCode: Int?
        var description: String {
            "ReceiptTrustFixture boundary=\(boundary.rawValue) cocoa=\(cocoaCode.map(String.init) ?? "none")"
        }
    }
    private func fixtureBoundary<T>(_ boundary: FixtureBoundary, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch {
            // Retain only a fixed setup boundary and a public Cocoa code. Error
            // messages, paths, configurations and key material remain private.
            throw FixtureFailure(boundary: boundary, cocoaCode: (error as? CocoaError)?.code.rawValue)
        }
    }

    private func launch(_ script: String) throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = try NativeHTTPFixture.python()
        process.arguments = [root.appendingPathComponent("scripts/" + script).path, directory.path]
        if script == "a2a-proof-agent.py" { process.arguments!.append("--hold-until-file") }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); processes.append(process)
    }
    private func port(_ name: String) throws -> String {
        let path = directory.appendingPathComponent(name)
        for _ in 0..<400 where !FileManager.default.fileExists(atPath:path.path) { Thread.sleep(forTimeInterval:0.01) }
        return try String(contentsOf:path, encoding:.utf8)
    }
    private func rows(_ name: String) throws -> [[String: Any]] {
        try FixtureLineFraming.objects(at: directory.appendingPathComponent(name))
    }
    private func provision() throws -> Data {
        let file = directory.appendingPathComponent("signer.raw")
        let key = Curve25519.Signing.PrivateKey()
        if FileManager.default.fileExists(atPath:file.path) {
            try NativeHTTPFixture.replacePrivate(key.rawRepresentation, at:file)
        } else { try NativeHTTPFixture.writePrivate(key.rawRepresentation, to:file) }
        config.signingKeyFile = file.path
        keys.append(key.publicKey.rawRepresentation); return key.publicKey.rawRepresentation
    }
    private func invoke(_ capability: Capability, ordinal: Int) throws -> ExecutionRecord {
        let message = String(data:try JSONSerialization.data(withJSONObject:["challenge":UUID().uuidString,"value":"trust-rotation-\(ordinal)"],options:[.sortedKeys]),encoding:.utf8)!
        let initial = try engine.begin(id:capability.id,item:"receipt trust pressure",confirmed:true,arguments:["message":message])
        records.append(initial); XCTAssertEqual(initial.state,.started)
        try Data().write(to:directory.appendingPathComponent("release"))
        var final = initial
        for _ in 0..<100 {
            final = engine.executionStatus(initial.executionId); records.append(final)
            if final.state != .started && final.state != .awaitingUser { break }
            Thread.sleep(forTimeInterval:0.02)
        }
        XCTAssertEqual(final.state,.succeeded); XCTAssertTrue(final.evidence.outcomeVerified)
        XCTAssertEqual(try rows("requests.jsonl").count,ordinal); XCTAssertEqual(try rows("effects.jsonl").count,ordinal)
        XCTAssertEqual(try rows("observations.jsonl").count,ordinal)
        XCTAssertEqual(try rows("observations.jsonl").last?["invocation"] as? String,final.rcir?.taskID)
        return final
    }
    private func signed(_ record: ExecutionRecord) throws -> RCIRSignedReceipt {
        let envelope = try XCTUnwrap(record.rcir?.signedReceipt)
        return try RCIRSignedReceipt(payload:XCTUnwrap(Data(base64Encoded:envelope.payload)),
            signature:XCTUnwrap(Data(base64Encoded:envelope.signature)),publicKey:XCTUnwrap(Data(base64Encoded:envelope.publicKey)))
    }
    override func setUpWithError() throws {
        directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("rcir-receipt-trust-" + UUID().uuidString)
        try fixtureBoundary(.directoryProvisioning) { try NativeHTTPFixture.createPrivateDirectory(directory) }
        try fixtureBoundary(.agents) { try launch("a2a-proof-agent.py"); try launch("a2a-proof-observer.py") }
        let base = "http://127.0.0.1:" + (try port("port")), observer = "http://127.0.0.1:" + (try port("observer-port"))
        let providers = directory.appendingPathComponent("providers.json")
        try fixtureBoundary(.providerConfiguration) {
            try NativeHTTPFixture.writePrivate(JSONSerialization.data(withJSONObject:["version":1,"agentCards":[base + "/.well-known/agent.json"]]), to:providers)
        }
        host = RCIRExecutionHost(); host.configuration = { [weak self] in
            guard let self else { throw RCIRError.authorityDenied }; return self.config
        }
        engine = CapabilityEngine(reflectorSources:[ConfiguredA2ASource(configurationFile:providers)],experience:nil,rcirHost:host)
        let cap = try XCTUnwrap(engine.capabilities(for:"receipt trust pressure").capabilities.first)
        var observation = RCIRHostConfiguration.Observer(urlTemplate:observer + "/observations/{message}",expectedArgument:"message")
        observation.trustedOrigin = observer; config.observers = [cap.id:observation]
        _ = try fixtureBoundary(.firstSigner) { try provision() }
        let first = try fixtureBoundary(.firstEffect) { try invoke(cap,ordinal:1) }
        try fixtureBoundary(.firstSignature) { try signed(first).verify(trustedPublicKey:keys[0],using:RCIREd25519Verifier()) }
        _ = try fixtureBoundary(.rotatedSigner) { try provision() }
        let second = try fixtureBoundary(.rotatedEffect) { try invoke(cap,ordinal:2) }
        try fixtureBoundary(.rotatedSignature) { try signed(second).verify(trustedPublicKey:keys[1],using:RCIREd25519Verifier()) }
        XCTAssertNotEqual(keys[0],keys[1]); XCTAssertEqual(first.rcir?.generation,second.rcir?.generation)
        XCTAssertNotEqual(first.rcir?.taskID,second.rcir?.taskID)
    }
    override func tearDownWithError() throws {
        for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() }
        if let path = ProcessInfo.processInfo.environment["RCIR_TRUST_EVIDENCE"] {
            let out = URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(records).write(to:out.appendingPathComponent("runtime-records.json"))
            try JSONSerialization.data(withJSONObject:policyMatrix,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("requested-policy-matrix.json"))
            try JSONSerialization.data(withJSONObject:outcomes,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("trust-results.json"))
            for (index,key) in keys.enumerated() { try key.write(to:out.appendingPathComponent("key-\(index)-public.raw")) }
            for file in ["requests.jsonl","effects.jsonl","observations.jsonl","polls.jsonl"] {
                if let data = try? Data(contentsOf:directory.appendingPathComponent(file)) { try data.write(to:out.appendingPathComponent(file)) }
            }
        }
        if let directory { try? NativeHTTPFixture.remove(directory) }
        engine = nil; host = nil
    }
    func testActualLegalRotationReceiptsRequireExplicitIssuerLifecyclePolicy() throws {
        let final = records.last!, firstID = records.first!.executionId
        let oldRecord = try XCTUnwrap(records.last(where: { $0.executionId == firstID }))
        let old = try signed(oldRecord), current = try signed(final)
        let oldClaims = try RCIRReceiptClaims.read(old.payload), currentClaims = try RCIRReceiptClaims.read(current.payload)
        XCTAssertLessThan(oldClaims.lastObservationTime,currentClaims.startedAt)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Allow actual wall-clock time to pass a declared test key expiry. No
        // mocked clock, provider ACK or invented signature drives this RED.
        let expiry = now + 20; Thread.sleep(forTimeInterval:0.04)
        var tampered = current.signature; tampered[0] ^= 1
        let bad = try RCIRSignedReceipt(payload:current.payload,signature:tampered,publicKey:current.publicKey)
        let unknownPin = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let cases: [(String,RCIRSignedReceipt,Data,String,Bool,String,Bool)] = [
            ("live-current-legal",current,keys[1],"live",false,"fixture-issuer",true),
            ("live-retired-old",old,keys[1],"live",false,"fixture-issuer",false),
            ("historical-retired-old",old,keys[1],"historical",false,"fixture-issuer",true),
            ("live-expired-current",current,keys[1],"live",false,"fixture-issuer",false),
            ("historical-expired-current",current,keys[1],"historical",false,"fixture-issuer",true),
            ("live-revoked-current",current,keys[1],"live",true,"fixture-issuer",false),
            ("historical-revoked-current",current,keys[1],"historical",true,"fixture-issuer",false),
            ("live-wrong-issuer",current,keys[1],"live",false,"another-issuer",false),
            ("live-untrusted-pin",current,unknownPin,"live",false,"fixture-issuer",false),
            ("live-tampered-signature",bad,keys[1],"live",false,"fixture-issuer",false),
            ("live-wrong-task",current,keys[1],"live",false,"fixture-issuer",false),
            ("live-wrong-lease",current,keys[1],"live",false,"fixture-issuer",false),
            ("live-wrong-outcome",current,keys[1],"live",false,"fixture-issuer",false)
        ]
        for (name,receipt,pin,mode,revoked,issuer,expected) in cases {
            let claims = receipt.publicKey == old.publicKey ? oldClaims : currentClaims
            let expiryCase = name.contains("expired-current")
            let key1End = expiryCase ? expiry : now + 60_000
            let task = name == "live-wrong-task" ? UUID() : claims.taskID
            let lease = name == "live-wrong-lease" ? UUID() : claims.leaseID
            let expectedOutcome: RCIRSemanticOutcome = name == "live-wrong-outcome" ? .failed : .succeeded
            let k0 = try RCIRReceiptKeyRecord(keyID:"key-0",publicKey:keys[0],notBefore:0,
                notAfter:now + 60_000,retiredAt:currentClaims.startedAt)
            let k1 = try RCIRReceiptKeyRecord(keyID:"key-1",publicKey:pin,notBefore:currentClaims.startedAt,notAfter:key1End)
            let trust = try RCIRReceiptTrustPolicy(issuerID:"fixture-issuer",records:[k0,k1])
            if revoked { try trust.revoke(keyID:"key-1") }
            let trustedJSON: [String: Any] = ["version":1,"issuerID":"fixture-issuer","maximumLiveAge":60_000,
                "keys":[["keyID":"key-0","publicKey":keys[0].base64EncodedString(),"notBefore":0,
                         "notAfter":now + 60_000,"retiredAt":currentClaims.startedAt,"revoked":false],
                        ["keyID":"key-1","publicKey":pin.base64EncodedString(),"notBefore":currentClaims.startedAt,
                         "notAfter":key1End,"retiredAt":NSNull(),"revoked":revoked]]]
            let policy: [String: Any] = ["case":name,"mode":mode,"recordIssuer":"fixture-issuer","expectedIssuer":issuer,
                "key0":"retired","key1Revoked":revoked,"expectedTaskID":task.uuidString,"expectedLeaseID":lease.uuidString,
                "expectedOutcome":expectedOutcome.rawValue,"key1NotAfter":key1End,"trustPolicy":trustedJSON,
                "receiptKey":receipt.publicKey == old.publicKey ? "key-0" : "key-1",
                "verificationTime":Int64(Date().timeIntervalSince1970 * 1000),"expectedAccepted":expected]
            policyMatrix.append(policy)
            let accepted: Bool
            do {
                let request = try RCIRReceiptTrustRequest(issuerID:issuer,taskID:task,leaseID:lease,
                    outcome:expectedOutcome,mode:RCIRReceiptTrustMode(rawValue:mode)!)
                _ = try trust.verify(receipt,expecting:request,using:RCIREd25519Verifier()); accepted = true
            }
            catch { accepted = false }
            outcomes.append(["case":name,"actualAccepted":accepted,"expectedAccepted":expected,"satisfied":accepted == expected])
            XCTAssertEqual(accepted,expected,"Missing shared issuer/lifecycle/mode policy: \(name)")
        }
    }
}
