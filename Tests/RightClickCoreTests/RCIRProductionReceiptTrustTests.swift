import Foundation
import XCTest
@testable import RightClickCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Production wiring pressure test. Host-owned policy is separately provisioned
/// and enforced by the delivered trust library. The default execution host has
/// no receipt-policy input/seam yet; these tests explicitly expose that gap,
/// rather than pretend the sidecar is already connected to the runtime.
final class RCIRProductionReceiptTrustTests: XCTestCase {
    private var directory: URL!
    private var keyFile: URL!
    private var policyFile: URL!
    private var processes: [Process] = []
    private var host: RCIRExecutionHost!
    private var engine: CapabilityEngine!
    private var capability: Capability!
    private var configuration = RCIRHostConfiguration()
    private var trust: RCIRReceiptTrustPolicy!
    private var records: [ExecutionRecord] = []
    private var keys: [Data] = []
    private var keyRecords: [[String: Any]] = []
    private var summary: [String: Any] = ["runtimeReceiptPolicySeam":"MISSING_IN_FROZEN_BASELINE"]
    private let issuer = "issuer:production-fixture"

    private func privateDirectory(_ path: URL) throws {
#if os(Windows)
        try NativeHTTPFixture.createPrivateDirectory(path)
#else
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
#endif
    }
    private func privateWrite(_ bytes: Data, to path: URL) throws {
        if FileManager.default.fileExists(atPath:path.path) {
            // These exact fixture paths were created/protected by this test.
            try NativeHTTPFixture.release(path); try FileManager.default.removeItem(at:path)
        }
#if os(Windows)
        try NativeHTTPFixture.writePrivate(bytes,to:path)
#else
        try bytes.write(to:path,options:.withoutOverwriting); try NativeHTTPFixture.protect(path)
#endif
    }
    private func launch(_ script: String) throws {
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = try NativeHTTPFixture.python()
        process.arguments = [source.appendingPathComponent("scripts/" + script).path,directory.path]
        if script == "a2a-proof-agent.py" { process.arguments!.append("--hold-until-file") }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); processes.append(process)
    }
    private func waitFor(_ name: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        for _ in 0..<400 where !FileManager.default.fileExists(atPath:file.path) { Thread.sleep(forTimeInterval:0.01) }
        return try XCTUnwrap(FileManager.default.fileExists(atPath:file.path) ? file : nil)
    }
    private func rows(_ name: String) -> [[String: Any]] {
        let data = (try? String(contentsOf:directory.appendingPathComponent(name),encoding:.utf8)) ?? ""
        return data.split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String: Any] }
    }
    private func provisionKey() throws -> Data {
        let key = Curve25519.Signing.PrivateKey()
        try privateWrite(key.rawRepresentation,to:keyFile)
        keys.append(key.publicKey.rawRepresentation); return key.publicKey.rawRepresentation
    }
    private func persistPolicy() throws {
        let document: [String: Any] = ["version":1,"issuerID":issuer,"maximumLiveAge":60_000,"keys":keyRecords]
        try privateWrite(JSONSerialization.data(withJSONObject:document,options:[.sortedKeys]),to:policyFile)
        XCTAssertEqual(try JSONSerialization.jsonObject(with:RCIRHostConfiguration.protectedRead(policyFile.path,maximum:131_072)) as? NSDictionary,document as NSDictionary)
    }
    private func revokeOriginal() throws {
        try trust.revoke(keyID:"fixture-k0"); keyRecords[0]["revoked"] = true; try persistPolicy()
    }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rcir-production-trust-" + UUID().uuidString)
        try privateDirectory(directory)
        try launch("a2a-proof-agent.py"); try launch("a2a-proof-observer.py")
        let endpoint = "http://127.0.0.1:" + (try String(contentsOf:waitFor("port"),encoding:.utf8))
        let observer = "http://127.0.0.1:" + (try String(contentsOf:waitFor("observer-port"),encoding:.utf8))
        let providers = directory.appendingPathComponent("providers.json")
        try privateWrite(JSONSerialization.data(withJSONObject:["version":1,"agentCards":[endpoint + "/.well-known/agent.json"]]),to:providers)
        host = RCIRExecutionHost(); host.configuration = { [weak self] in
            guard let self else { throw RCIRError.authorityDenied }; return self.configuration
        }
        engine = CapabilityEngine(reflectorSources:[ConfiguredA2ASource(configurationFile:providers)],experience:nil,rcirHost:host)
        capability = try XCTUnwrap(engine.capabilities(for:"production receipt trust").capabilities.first)
        var check = RCIRHostConfiguration.Observer(urlTemplate:observer + "/observations/{message}",expectedArgument:"message")
        check.trustedOrigin = observer; configuration.observers = [capability.id:check]
        keyFile = directory.appendingPathComponent("signer.raw"); policyFile = directory.appendingPathComponent("receipt-trust.json")
        let publicKey = try provisionKey(); configuration.signingKeyFile = keyFile.path
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let record = try RCIRReceiptKeyRecord(keyID:"fixture-k0",publicKey:publicKey,notBefore:now - 1000,notAfter:now + 60_000)
        trust = try .init(issuerID:issuer,records:[record])
        keyRecords = [["keyID":record.keyID,"publicKey":publicKey.base64EncodedString(),"notBefore":record.notBefore,
                       "notAfter":record.notAfter,"retiredAt":NSNull(),"revoked":false]]
        try persistPolicy()
        // Intentionally no nonexistent host property: the sidecar is a declared
        // desired host input, not provider metadata and not an enforced seam.
    }
    override func tearDownWithError() throws {
        for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() }
        if let path = ProcessInfo.processInfo.environment["RCIR_PRODUCTION_TRUST_EVIDENCE"] {
            let output = URL(fileURLWithPath:path).appendingPathComponent(name.replacingOccurrences(of:"/",with:"_"))
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(records).write(to:output.appendingPathComponent("runtime-records.json"))
            try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("control-summary.json"))
            if let policyFile, let data = try? RCIRHostConfiguration.protectedRead(policyFile.path,maximum:131_072) {
                try data.write(to:output.appendingPathComponent("host-policy-current.json"))
            }
            for (slot,key) in keys.enumerated() { try key.write(to:output.appendingPathComponent("key-\(slot)-public.raw")) }
            for name in ["requests.jsonl","effects.jsonl","observations.jsonl","polls.jsonl"] {
                let bytes = (try? Data(contentsOf:directory.appendingPathComponent(name))) ?? Data()
                try bytes.write(to:output.appendingPathComponent(name))
            }
        }
        if let directory { try? NativeHTTPFixture.remove(directory) }
        engine = nil; host = nil
    }
    private func begin() throws -> ExecutionRecord {
        let message = String(data:try JSONSerialization.data(withJSONObject:["challenge":UUID().uuidString,"value":"production-trust-effect"],options:[.sortedKeys]),encoding:.utf8)!
        let record = try engine.begin(id:capability.id,item:"production receipt trust",confirmed:true,arguments:["message":message])
        records.append(record); return record
    }
    private func release() throws { try Data().write(to:directory.appendingPathComponent("release")) }
    private func finish(_ initial: ExecutionRecord) -> ExecutionRecord {
        var final = initial
        for _ in 0..<100 {
            final = engine.executionStatus(initial.executionId); records.append(final)
            if final.state != .started && final.state != .awaitingUser { break }
            Thread.sleep(forTimeInterval:0.02)
        }
        return final
    }
    private func signed(_ record: ExecutionRecord) throws -> RCIRSignedReceipt {
        let envelope = try XCTUnwrap(record.rcir?.signedReceipt)
        return try .init(payload:XCTUnwrap(Data(base64Encoded:envelope.payload)),signature:XCTUnwrap(Data(base64Encoded:envelope.signature)),publicKey:XCTUnwrap(Data(base64Encoded:envelope.publicKey)))
    }
    private func independentlyObserved(_ final: ExecutionRecord, count: Int) throws {
        XCTAssertEqual(final.state,.succeeded); XCTAssertTrue(final.evidence.outcomeVerified)
        XCTAssertEqual(rows("requests.jsonl").count,count); XCTAssertEqual(rows("effects.jsonl").count,count)
        XCTAssertEqual(rows("observations.jsonl").count,count)
        XCTAssertEqual(rows("observations.jsonl").last?["invocation"] as? String,final.rcir?.taskID)
    }
    private func acceptedByPolicy(_ final: ExecutionRecord) throws -> Bool {
        guard final.rcir?.signedReceipt != nil else { return false }
        let receipt = try signed(final)
        do {
            let task = try XCTUnwrap(UUID(uuidString:XCTUnwrap(final.rcir?.taskID)))
            let lease = try XCTUnwrap(UUID(uuidString:XCTUnwrap(final.rcir?.leaseID)))
            _ = try trust.verify(receipt,expecting:.init(issuerID:issuer,taskID:task,leaseID:lease,outcome:.succeeded,mode:.live),using:RCIREd25519Verifier())
            return true
        } catch {
            summary["policyRejectedBecauseRevoked"] = (error as? RCIRReceiptTrustError) == .keyRevoked
            return false
        }
    }
    func testActiveIssuerControlProducesOneTrustedObservedEffect() throws {
        let initial = try begin(); XCTAssertEqual(initial.state,.started)
        try release(); let final = finish(initial); try independentlyObserved(final,count:1)
        let accepted = try acceptedByPolicy(final); summary["currentPolicyAccepted"] = accepted
        XCTAssertTrue(accepted)
    }
    func testRevokedPolicyAfterAdmissionWithholdsSignatureAndRetainsRealTruth() throws {
        let before = try RCIRHostConfiguration.protectedRead(keyFile.path,maximum:32)
        let initial = try begin(); XCTAssertEqual(initial.state,.started); XCTAssertTrue(rows("effects.jsonl").isEmpty)
        try revokeOriginal(); try release(); let final = finish(initial)
        try independentlyObserved(final,count:1)
        let unchanged = try RCIRHostConfiguration.protectedRead(keyFile.path,maximum:32) == before
        XCTAssertTrue(unchanged); summary["privateKeyUnchanged"] = unchanged
        let accepted = try acceptedByPolicy(final); summary["currentPolicyAccepted"] = accepted
        summary["runtimeSigned"] = final.rcir?.signedReceipt != nil
        XCTAssertFalse(accepted)
        XCTAssertEqual(summary["policyRejectedBecauseRevoked"] as? Bool,true)
        if final.rcir?.signedReceipt != nil { try signed(final).verify(trustedPublicKey:keys[0],using:RCIREd25519Verifier()) }
        XCTAssertNotNil(final.rcir?.receipt)
        XCTAssertTrue(final.rcir?.signedReceipt == nil,"Missing production issuer-policy seam: revoked unchanged key still emitted a signature")
        XCTAssertTrue(final.events.contains(RCIRReceiptEmission.withheldEvent),"Current issuer withdrawal must be represented honestly")
    }
    func testPreRevokedPolicyDeniesAdmissionWithZeroProviderEffects() throws {
        let before = try RCIRHostConfiguration.protectedRead(keyFile.path,maximum:32)
        try revokeOriginal(); let initial = try begin()
        // Preserve actual baseline effect evidence even after the desired
        // rejection fails, instead of ending at a return-code assertion.
        if initial.state == .started { try release(); _ = finish(initial) }
        summary["privateKeyUnchanged"] = try RCIRHostConfiguration.protectedRead(keyFile.path,maximum:32) == before
        summary["requests"] = rows("requests.jsonl").count; summary["effects"] = rows("effects.jsonl").count
        if let final = records.last { summary["currentPolicyAccepted"] = try acceptedByPolicy(final) }
        XCTAssertEqual(initial.state,.rejected,"Missing production issuer-policy admission seam")
        XCTAssertTrue(rows("requests.jsonl").isEmpty,"Revoked configured signing authority must fail before dispatch")
        XCTAssertTrue(rows("effects.jsonl").isEmpty)
    }
    func testLegalHostKeyRotationControlUsesFreshTrustedKey() throws {
        let first = try begin(); try release(); let old = finish(first); try independentlyObserved(old,count:1)
        XCTAssertTrue(try acceptedByPolicy(old))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try trust.retire(keyID:"fixture-k0",at:now); keyRecords[0]["retiredAt"] = now
        let publicKey = try provisionKey()
        let record = try RCIRReceiptKeyRecord(keyID:"fixture-k1",publicKey:publicKey,notBefore:now,notAfter:now + 60_000)
        try trust.register(record)
        keyRecords.append(["keyID":record.keyID,"publicKey":publicKey.base64EncodedString(),"notBefore":record.notBefore,
            "notAfter":record.notAfter,"retiredAt":NSNull(),"revoked":false]); try persistPolicy()
        let fresh = try begin(); let final = finish(fresh); try independentlyObserved(final,count:2)
        let accepted = try acceptedByPolicy(final); summary["currentPolicyAccepted"] = accepted
        XCTAssertTrue(accepted); XCTAssertNotEqual(final.rcir?.taskID,old.rcir?.taskID)
        try signed(final).verify(trustedPublicKey:keys[1],using:RCIREd25519Verifier())
    }
}
