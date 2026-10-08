import Foundation
import CryptoKit
import XCTest
@testable import RightClickCore

/// Real disposable HTTP transport + separate host readback. Authenticated peer
/// context is attached by the test host; production MCP/OS identity wiring is RED.
final class RCIRAuthorityDispatchTests: XCTestCase {
    private var directory: URL!, process: Process!, base: URL!, host: RCIRExecutionHost!
    private var capability: Capability!, abi: CapabilityContract!, scope: RCIRScope!, binding: RCIRBinding!
    private var rootGrant: RCIRAuthorityGrant!, childGrant: RCIRAuthorityGrant!
    private var key: Curve25519.Signing.PrivateKey!
    private var clock: Int64 = 1000
    private var config = RCIRHostConfiguration()
    private var subject = "agent:bob", audience = "runtime:proof"
    private var credentialScopes: Set<RCIRScope> = []

    private func identity(_ value: String) throws -> RCIRAuthorityIdentity { try .init(value) }
    private func context(_ subject: String? = nil, audience: String? = nil) throws -> RCIRAuthorityContext {
        .init(authenticatedSubject: try identity(subject ?? self.subject), audience: try identity(audience ?? self.audience))
    }
    private var arguments: CapabilityValue { .object(["id":.string("bounded-child"),"value":.string("requested")]) }
    private func request(subject: String, limit: Int, depth: Int, expiry: Int64) throws -> RCIRAuthorityRequest {
        try .init(subject: identity(subject), audiences:[identity("runtime:proof")],targets:[.init(binding)],scopes:[scope],
              arguments:.oneOf([arguments]),expiresAt:expiry,invocationLimit:limit,delegationDepth:depth)
    }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rcir-authority-dispatch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let repository = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = [repository.appendingPathComponent("scripts/rcir-dispatch-test-provider.py").path,directory.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
        let port = directory.appendingPathComponent("port")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath:port.path) { Thread.sleep(forTimeInterval:0.01) }
        base = try XCTUnwrap(URL(string:"http://127.0.0.1:"+String(contentsOf:port,encoding:.utf8)))
        host = RCIRExecutionHost(); host.now = { self.clock }; host.configuration = { self.config }
        capability = Capability(id:"authority:write",title:"Disposable write",source:.system,reflectorID:"authority:fixture",
            safety:.localReversible,invocation:.direct,supportLevel:.publicSupported,requiresConfirmation:false)
        abi = try capability.abiContract(arguments:.object(properties:["id":.string,"value":.string],required:["id","value"]),result:.string)
        scope = RCIRScope(base.absoluteString,.write); credentialScopes = [scope]
        config.observers = [capability.id:.init(urlTemplate:base.absoluteString+"/records/{id}",expectedArgument:"value")]
        key = Curve25519.Signing.PrivateKey()
        let keyFile = directory.appendingPathComponent("signer.raw"); try key.rawRepresentation.write(to:keyFile)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:keyFile.path); config.signingKeyFile = keyFile.path
        let verification = RCIRVerificationContract(observerID:base.absoluteString+"/records/bounded-child",schema:.string,expected:.string("requested"))
        binding = try host.admission.publishInvocation(.init(abi:abi,scopes:[scope],verification:verification),discovery:abi,
                                                       authenticatedPrincipal:"local-owner:"+abi.reflectorID)
        rootGrant = try host.admission.issueAuthority(request(subject:"agent:alice",limit:1,depth:1,expiry:3000),issuer:identity("issuer:host"),now:clock)
        childGrant = try host.admission.attenuate(rootGrant,request:request(subject:"agent:bob",limit:1,depth:0,expiry:2000),
                                                 authenticated:context("agent:alice"),now:clock)
    }
    override func tearDownWithError() throws {
        if process?.isRunning == true { process.terminate(); process.waitUntilExit() }
        if let out = ProcessInfo.processInfo.environment["RCIR_AUTHORITY_EVIDENCE"] {
            let target = URL(fileURLWithPath:out); try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            let name = name.replacingOccurrences(of:"/",with:"_")
            let rows = try JSONSerialization.data(withJSONObject:["test":name,"effects":effects()],options:[.prettyPrinted,.sortedKeys])
            try rows.write(to:target.appendingPathComponent(name+".json"))
        }
        if let directory { try? FileManager.default.removeItem(at:directory) }
    }
    private func effects() -> [[String:Any]] {
        let rows = (try? String(contentsOf:directory.appendingPathComponent("effects.jsonl"),encoding:.utf8)) ?? ""
        return rows.split(separator:"\n").map { try! JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
    }
    private func invoke(_ grant: RCIRAuthorityGrant? = nil, authenticatedContext: (() throws -> RCIRAuthorityContext)? = nil) throws -> ExecutionRecord {
        let attachment = RCIRHostAuthority(grant:grant ?? childGrant,authenticatedContext:authenticatedContext ?? { try self.context() })
        return try host.execute(abi:abi,discovery:abi,arguments:arguments,scope:scope,capability:capability,
            executionID:UUID().uuidString,argumentStrings:["id":"bounded-child","value":"requested"],
            item:ContentParser.parse("disposable"),verification:nil,expectedOutput:nil,target:base,
            authority:{ self.credentialScopes },revalidate:{ true },invocationAuthority:attachment,
            dispatch:{ taskID, admit in
                var request = URLRequest(url:self.base.appendingPathComponent("records")); request.httpMethod = "POST"
                request.httpBody = try JSONSerialization.data(withJSONObject:["id":"bounded-child","value":"requested"])
                request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue(taskID,forHTTPHeaderField:"X-RightClick-Invocation")
                let data = try OriginPinnedHTTP.loadInvocation(request,maximumBytes:65536,admitStart:admit)
                return ExecutionRecord(executionId:"",actionId:self.capability.id,state:.accepted,message:"Actual HTTP accepted",output:String(data:data,encoding:.utf8))
            },resultValue:{ .string($0.output ?? "") })
    }
    func testLegalChildProducesIndependentlyObservedSignedEffect() throws {
        let result = try invoke()
        XCTAssertEqual(result.state,.succeeded,result.message); XCTAssertEqual(effects().count,1)
        XCTAssertEqual(result.rcir?.outcome,"succeeded"); XCTAssertEqual(result.rcir?.leaseConsumed,true)
        let envelope = try XCTUnwrap(result.rcir?.signedReceipt)
        let signed = try RCIRSignedReceipt(payload:Data(base64Encoded:envelope.payload)!,signature:Data(base64Encoded:envelope.signature)!,publicKey:Data(base64Encoded:envelope.publicKey)!)
        try signed.verify(trustedPublicKey:key.publicKey.rawRepresentation,using:RCIREd25519Verifier())
        XCTAssertTrue(signed.payload.range(of:childGrant.bytes) != nil)
        XCTAssertTrue(signed.payload.range(of:rootGrant.bytes) != nil)
        let external = try OriginPinnedHTTP.loadObservation(URLRequest(url:base.appendingPathComponent("records/bounded-child")),maximumBytes:65536)
        XCTAssertEqual(String(decoding:external,as:UTF8.self),"requested")
        if let out = ProcessInfo.processInfo.environment["RCIR_AUTHORITY_EVIDENCE"] {
            let target = URL(fileURLWithPath:out); try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            try signed.wireData().write(to:target.appendingPathComponent("legal-child-receipt.json"))
            try key.publicKey.rawRepresentation.write(to:target.appendingPathComponent("trusted-public-key.raw"))
        }
    }
    func testWrongSubjectAtFinalGateProducesZeroActualHTTPRequests() throws {
        host.beforeConsume = { _ in self.subject = "agent:mallory" }
        XCTAssertEqual(try invoke().state,.rejected); XCTAssertTrue(effects().isEmpty)
    }
    func testWrongAudienceAtFinalGateProducesZeroActualHTTPRequests() throws {
        host.beforeConsume = { _ in self.audience = "runtime:other" }
        XCTAssertEqual(try invoke().state,.rejected); XCTAssertTrue(effects().isEmpty)
    }
    func testAncestorRevocationAtFinalGateProducesZeroActualHTTPRequests() throws {
        host.beforeConsume = { _ in try self.host.admission.revokeAuthority(self.rootGrant) }
        XCTAssertEqual(try invoke().state,.rejected); XCTAssertTrue(effects().isEmpty)
    }
    func testPolicyRevocationAtFinalGateProducesZeroActualHTTPRequests() throws {
        host.beforeConsume = { _ in self.config.deniedCapabilities = [self.capability.id] }
        XCTAssertEqual(try invoke().state,.rejected); XCTAssertTrue(effects().isEmpty)
    }
    func testCredentialScopeWithdrawalAtFinalGateProducesZeroActualHTTPRequests() throws {
        host.beforeConsume = { _ in self.credentialScopes = [] }
        XCTAssertEqual(try invoke().state,.rejected); XCTAssertTrue(effects().isEmpty)
    }
    func testSiblingAndParentCannotExceedSharedBudget() throws {
        let sibling = try host.admission.attenuate(rootGrant,request:request(subject:"agent:carol",limit:1,depth:0,expiry:2000),authenticated:context("agent:alice"),now:clock)
        XCTAssertEqual(try invoke().state,.succeeded)
        subject = "agent:carol"; XCTAssertEqual(try invoke(sibling).state,.rejected)
        subject = "agent:alice"; XCTAssertEqual(try invoke(rootGrant).state,.rejected)
        XCTAssertEqual(effects().count,1)
    }
    func testAuthenticatedContextErrorsCannotLeakCredentialMaterial() throws {
        let sentinel = "DISPOSABLE_AUTHORITY_SECRET_SENTINEL"
        let result = try invoke(authenticatedContext:{ throw RightClickError(sentinel) })
        XCTAssertEqual(result.state,.rejected); XCTAssertTrue(effects().isEmpty)
        let encoded = try JSONEncoder().encode(result)
        let leaked = String(decoding:encoded,as:UTF8.self).contains(sentinel)
        if let out = ProcessInfo.processInfo.environment["RCIR_AUTHORITY_EVIDENCE"] {
            let target = URL(fileURLWithPath:out); try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            try encoded.write(to:target.appendingPathComponent(leaked ? "context-error-red.json" : "context-error-green.json"))
        }
        XCTAssertFalse(leaked)
    }
    func testRevocationAfterEffectWithholdsObservationAndSuccess() throws {
        host.beforeStart = { _,admit,start in
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(start) { enqueue in try permit(enqueue) }
            }
            try self.host.admission.revokeAuthority(self.rootGrant)
        }
        let result = try invoke()
        XCTAssertEqual(effects().count,1); XCTAssertEqual(result.state,.unknown)
        XCTAssertEqual(result.rcir?.outcome,"unknown"); XCTAssertNotNil(result.rcir?.signedReceipt)
    }
}
