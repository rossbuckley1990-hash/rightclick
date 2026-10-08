#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// These controls invoke CapabilityEngine run/begin and the actual HTTP transport.
/// A separate Python process records the requests that really reached the provider.
final class RCIRProductionDispatchTests: XCTestCase {
    private var directory: URL!
    private var provider: Process!
    private var base: URL!
    private var host: RCIRExecutionHost!
    private var reflector: OpenAPIReflector!
    private var source: Source!
    private var engine: CapabilityEngine!
    private var clock: Int64 = 1_000
    private var config = RCIRHostConfiguration()

    private final class ConcurrentAdmission {
        var admit: ((() -> Void) throws -> Void)?
        var enqueue: (() -> Void)?
        init(admit: @escaping (() -> Void) throws -> Void, enqueue: @escaping () -> Void) {
            self.admit = admit; self.enqueue = enqueue
        }
        func invoke() throws { try admit!(enqueue!) }
        func release() { admit = nil; enqueue = nil }
    }

    private final class Source: CapabilityReflectorSource {
        let id = "test.real-http-source"
        var current: [any CapabilityReflector] = []
        func reflectors() -> [any CapabilityReflector] { current }
    }

    private func specification(_ version: String = "1", secure: Bool = false) -> Data {
        let schema: [String: Any] = ["type": "object", "additionalProperties": false,
            "required": ["id", "value"], "properties": ["id": ["type": "string"], "value": ["type": "string"]]]
        let content: [String: Any] = ["application/json": ["schema": schema]]
        var operation: [String: Any] = ["operationId": "writeRecord", "summary": "Write disposable record",
            "requestBody": ["required": true, "content": content],
            "responses": ["200": ["description": "Accepted", "content": content]]]
        if secure { operation["security"] = [["disposableNeverProvisioned": [String]()]] }
        var object: [String: Any] = ["openapi": "3.0.3", "info": ["title": "Disposable RCIR provider", "version": version],
            "paths": ["/records": ["post": operation]]]
        if secure {
            object["components"] = ["securitySchemes": ["disposableNeverProvisioned": ["type": "http", "scheme": "bearer"]]]
        }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    override func setUpWithError() throws {
        directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("rcir-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        provider = Process(); provider.executableURL = try NativeHTTPFixture.python()
        provider.arguments = [root.appendingPathComponent("scripts/rcir-dispatch-test-provider.py").path, directory.path]
        provider.standardOutput = FileHandle.nullDevice; provider.standardError = FileHandle.nullDevice
        try provider.run()
        let portFile = directory.appendingPathComponent("port")
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        XCTAssertNotNil(Int(port)); XCTAssertGreaterThan(Int(port) ?? 0, 0)
        base = URL(string: "http://127.0.0.1:" + port)!
        host = RCIRExecutionHost(); host.now = { self.clock }; host.configuration = { self.config }
        reflector = try OpenAPIReflector(specificationData: specification(), baseURL: base)
        source = Source(); source.current = [reflector]
        engine = CapabilityEngine(reflectorSources: [source], experience: nil, rcirHost: host)
    }

    override func tearDownWithError() throws {
        if provider?.isRunning == true { provider.terminate(); provider.waitUntilExit() }
        if let path = ProcessInfo.processInfo.environment["RCIR_DISPATCH_EVIDENCE"] {
            let out = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let label = name.replacingOccurrences(of: "/", with: "_")
            let observations = (try? String(contentsOf: directory.appendingPathComponent("spec-observations.jsonl"), encoding: .utf8)) ?? ""
            let data = try JSONSerialization.data(withJSONObject: ["test": name, "effects": try effectRows(), "specObservations": observations], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out.appendingPathComponent(label + ".json"))
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        engine = nil; host = nil
    }

    private func effectRows() throws -> [[String: Any]] {
        try FixtureLineFraming.objects(at: directory.appendingPathComponent("effects.jsonl"))
    }

    @discardableResult private func invoke(_ name: String = "unique", confirmed: Bool = true) throws -> ExecutionRecord {
        let capability = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        return try engine.begin(id: capability.id, item: "disposable", confirmed: confirmed,
                                arguments: ["id": name, "value": "requested"])
    }

    func testFinalConfigurationCallbackCannotWithdrawGraphAndStillStartHTTP() throws {
        var armed = false
        host.beforeStart = { _, admit, enqueue in
            armed = true
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(enqueue) { start in try permit(start) }
            }
        }
        host.configuration = {
            if armed { self.source.current = [] }
            return self.config
        }
        let result = try invoke()
        XCTAssertEqual(result.state, .rejected)
        XCTAssertNotEqual(result.rcir?.leaseConsumed, true)
        XCTAssertTrue(try effectRows().isEmpty, "Graph withdrawal during final callbacks must precede every effect")
    }

    func testSuccessfulBoundedProviderAcquisitionSignalsTaskCompletion() throws {
        let bytes = specification()
        try bytes.write(to: directory.appendingPathComponent("spec.json"))
        let started = Date()
        XCTAssertEqual(try OriginPinnedHTTP.loadOpenAPISpecification(base.appendingPathComponent("openapi.json")), bytes)
        XCTAssertLessThan(Date().timeIntervalSince(started), OriginPinnedHTTP.acquisitionDeadline)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testPublicBeginConsumesOneLeaseAndRetainsTaskEvidence() throws {
        let result = try invoke()
        XCTAssertEqual(result.state, .accepted)
        XCTAssertEqual(result.rcir?.outcome, "unverified")
        XCTAssertEqual(result.rcir?.leaseConsumed, true)
        XCTAssertEqual(try effectRows().count, 1)
        XCTAssertEqual(try effectRows().first?["taskID"] as? String, result.rcir?.taskID)
        XCTAssertEqual(engine.executionStatus(result.executionId).rcir?.receipt, result.rcir?.receipt)
    }

#if os(macOS) || os(Linux)
    /// Freeze the actual protected-file policy race introduced by durable I/O.
    /// The provider is a separate HTTP process, and the positive control must
    /// reach it. No fabricated dispatch callback or in-memory policy revocation.
    func testJournalIntentPolicyRevocationDeniesActualHTTPBeforeEffect() throws {
        let temporaryPath = directory.path
        let physicalPath = try XCTUnwrap(realpath(temporaryPath, nil))
        defer { free(physicalPath) }
        let journalDirectory = URL(fileURLWithPath: String(cString: physicalPath))
            .appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let journal = try RCIRInvocationJournal(directory: journalDirectory)
        host.invocationJournal = { journal }
        let configurationFile = directory.appendingPathComponent("host-policy.json")
        let signingKey = directory.appendingPathComponent("synthetic-signing-key.raw")
        try Curve25519.Signing.PrivateKey().rawRepresentation.write(to: signingKey)
        try NativeHTTPFixture.protect(signingKey)
        let action = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        var configuration = RCIRHostConfiguration()
        configuration.revision = "journal-policy-race-1"
        configuration.signingKeyFile = signingKey.path
        func writeConfiguration() throws {
            try JSONEncoder().encode(configuration).write(to: configurationFile, options: .atomic)
            try NativeHTTPFixture.protect(configurationFile)
        }
        try writeConfiguration()
        var revoked = false, postRevocationLoads = 0, boundaryCalls = 0
        var stagedIntentSeen = false, issuedLease: String?
        host.configuration = {
            if revoked { postRevocationLoads += 1 }
            return try JSONDecoder().decode(RCIRHostConfiguration.self,
                from: RCIRHostConfiguration.protectedRead(configurationFile.path, maximum: 65_536))
        }
        host.beforeConsume = { issuedLease = $0.id.uuidString }
        journal.beforeCommit = {
            guard !revoked else { return } // The later not-dispatched checkpoint is separate.
            boundaryCalls += 1
            let lease = try XCTUnwrap(issuedLease)
            let staged = try String(contentsOf: journalDirectory.appendingPathComponent("invocations.tmp"), encoding: .utf8)
            let committed = try String(contentsOf: journalDirectory.appendingPathComponent("invocations.json"), encoding: .utf8)
            XCTAssertTrue(staged.contains(lease)); XCTAssertFalse(committed.contains(lease))
            stagedIntentSeen = staged.contains(lease)
            XCTAssertTrue(try self.effectRows().isEmpty, "The staged intent must precede the actual provider request")
            // Keep the human revision identical: the complete protected-file
            // fingerprint, rather than only its revision string, must change.
            configuration.deniedCapabilities = [action.id]
            try writeConfiguration()
            revoked = true
        }
        let denied = try invoke("must-never-reach-http")
        XCTAssertEqual(boundaryCalls, 1); XCTAssertTrue(stagedIntentSeen)
        XCTAssertGreaterThan(postRevocationLoads, 0, "The host must read protected policy again after durable intent I/O")
        XCTAssertEqual(denied.state, .rejected, denied.message)
        XCTAssertNil(denied.rcir, "No consumed lease or receipt may be manufactured for denied dispatch")
        XCTAssertTrue(try effectRows().isEmpty, "Revocation at the journal boundary must cause zero actual HTTP effects")
        XCTAssertEqual(try journal.status(denied.executionId, now: clock)?.state, .rejected)
        if let path = ProcessInfo.processInfo.environment["RCIR_DISPATCH_EVIDENCE"] {
            let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let proof: [String: Any] = ["productionBaseline": "baee56aae3c24f1a55d47522fcaa5641fa3f3b00",
                "stagedIntentSeen": stagedIntentSeen, "boundaryCalls": boundaryCalls,
                "postRevocationProtectedFileLoads": postRevocationLoads, "unchangedHumanPolicyRevision": true,
                "deniedExecutionID": denied.executionId, "deniedState": denied.state.rawValue,
                "actualHTTPMutationsAtDenial": try effectRows(), "retainedJournalState": "rejected"]
            try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("journal-policy-revocation-zero-effect.json"))
        }
        // The same native route really works when a fresh invocation is allowed.
        journal.beforeCommit = nil; configuration.deniedCapabilities = []
        try writeConfiguration()
        let allowed = try invoke("live-positive-control")
        XCTAssertEqual(allowed.state, .accepted, allowed.message)
        XCTAssertEqual(allowed.rcir?.leaseConsumed, true); XCTAssertNotNil(allowed.rcir?.signedReceipt)
        XCTAssertEqual(try effectRows().count, 1)
        XCTAssertEqual(try effectRows().first?["taskID"] as? String, allowed.rcir?.taskID)
    }
#endif

    func testSeparateRepeatIssuesNewLeaseThroughBothEntryPoints() throws {
        let first = try invoke("first")
        XCTAssertEqual(first.state, .accepted, first.message)
        let capability = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        let second = try engine.run(id: capability.id, item: "disposable", confirmed: true,
                                    arguments: ["id": "second", "value": "requested"])
        XCTAssertEqual(second.status, .accepted, second.message)
        XCTAssertNotEqual(first.rcir?.leaseID, second.rcir?.leaseID)
        XCTAssertEqual(try effectRows().count, 2)
    }

    func testIndependentInvocationsDoNotReplaceTheDiscoveredProviderGeneration() throws {
        // Pause the first invocation after issue, then complete a second request
        // to the same unchanged operation. Different bodies are requests, not
        // changes to the provider's discovered declaration.
        var nested: ExecutionRecord?
        host.beforeConsume = { _ in
            self.host.beforeConsume = nil
            nested = try self.invoke("independent-second")
        }
        let first = try invoke("independent-first")
        let second = try XCTUnwrap(nested)
        XCTAssertEqual(second.state, .accepted, second.message)
        XCTAssertEqual(first.state, .accepted, first.message)
        XCTAssertEqual(first.rcir?.generation, second.rcir?.generation)
        XCTAssertNotEqual(first.rcir?.leaseID, second.rcir?.leaseID)
        XCTAssertEqual(try effectRows().count, 2)
        XCTAssertEqual(Set(try effectRows().compactMap { ($0["body"] as? [String: String])?["id"] }),
                       ["independent-first", "independent-second"])
    }

    func testConfirmationDenialProducesZeroProviderEffects() throws {
        XCTAssertEqual(try invoke(confirmed: false).state, .awaitingUser)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testCurrentPolicyRevocationProducesZeroProviderEffects() throws {
        host.beforeConsume = { lease in self.config.deniedCapabilities = [lease.binding.contract.abi.capabilityID] }
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testExpiredLeaseProducesZeroProviderEffects() throws {
        host.beforeConsume = { lease in self.clock = lease.expiresAt }
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testNotYetValidLeaseProducesZeroProviderEffects() throws {
        host.beforeConsume = { lease in self.clock = lease.issuedAt - 1 }
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testSpentLeaseCannotDispatchAgain() throws {
        host.beforeStart = { _, admit, enqueue in
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(enqueue) { start in
                    try permit(start)
                    do { try permit(start); XCTFail("A spent lease dispatched again") }
                    catch { XCTAssertEqual(error as? RCIRError, .leaseUsed) }
                }
            }
        }
        XCTAssertEqual(try invoke().state, .accepted)
        XCTAssertEqual(try effectRows().count, 1)
    }

    func testCompetingConsumersStartAtMostOneRealRequest() throws {
        host.beforeStart = { _, admit, enqueue in
            // Group completion can precede destruction of the queued blocks.
            // Blocks retain only this holder; release its callbacks explicitly
            // after every synchronous invoke has returned.
            withoutActuallyEscaping(admit) { admit in
                withoutActuallyEscaping(enqueue) { enqueue in
                    let invocation = ConcurrentAdmission(admit: admit, enqueue: enqueue)
                    let started = Date()
                    let group = DispatchGroup(); let lock = NSLock()
                    var permitted = 0; var replayed = 0
                    for _ in 0..<2 {
                        group.enter()
                        DispatchQueue.global().async {
                            defer { group.leave() }
                            do { try invocation.invoke(); lock.lock(); permitted += 1; lock.unlock() }
                            catch { lock.lock(); replayed += 1; lock.unlock() }
                        }
                    }
                    XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
                    XCTAssertLessThan(Date().timeIntervalSince(started), 3, "Competing consumers remain bounded")
                    invocation.release()
                    XCTAssertEqual(permitted, 1); XCTAssertEqual(replayed, 1)
                }
            }
        }
        XCTAssertEqual(try invoke().state, .accepted)
        XCTAssertEqual(try effectRows().count, 1)
    }

    func testChangedArgumentsCannotUseOriginalLease() throws {
        host.consumptionArguments = { _ in .object(["item": .string("disposable"),
            "arguments": .object(["id": .string("changed"), "value": .string("changed")])]) }
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testChangedEndpointBeforeDispatchProducesZeroProviderEffects() throws {
        host.beforeConsume = { _ in
            self.source.current = [try OpenAPIReflector(specificationData: self.specification(),
                                                       baseURL: self.base.appendingPathComponent("different"))]
        }
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testRemovalBeforeDispatchProducesZeroProviderEffects() throws {
        host.beforeConsume = { _ in self.source.current = [] }
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testRemovalAtTransportAdmissionProducesZeroProviderEffects() throws {
        host.beforeStart = { _, admit, enqueue in
            self.source.current = []
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(enqueue) { start in try permit(start) }
            }
        }
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testSameProviderReappearingCannotReviveOldGeneration() throws {
        host.beforeConsume = { _ in
            self.source.current = []; _ = self.engine.providers()
            self.source.current = [self.reflector]
        }
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
        host.beforeConsume = nil
        XCTAssertEqual(try invoke("new-incarnation").state, .accepted)
        XCTAssertEqual(try effectRows().count, 1)
    }

    func testRemovalAfterDispatchPreservesUnknownWithoutRetry() throws {
        host.beforeStart = { _, admit, enqueue in
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(enqueue) { start in try permit(start) }
            }
            self.source.current = []
        }
        let result = try invoke()
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.rcir?.outcome, "unknown")
        XCTAssertEqual(try effectRows().count, 1)
    }

    func testLostResponseRetainsSignedUnknownAndDoesNotRetry() throws {
        let key = Curve25519.Signing.PrivateKey()
        let path = directory.appendingPathComponent("disposable-receipt-key.raw")
        try NativeHTTPFixture.writePrivate(key.rawRepresentation, to: path)
        config.signingKeyFile = path.path
        let result = try invoke("drop-response")
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.rcir?.outcome, "unknown")
        XCTAssertEqual(try effectRows().count, 1, "Lost replies must not cause another mutation")
        let envelope = try XCTUnwrap(result.rcir?.signedReceipt)
        let signed = try RCIRSignedReceipt(payload: XCTUnwrap(Data(base64Encoded: envelope.payload)),
            signature: XCTUnwrap(Data(base64Encoded: envelope.signature)),
            publicKey: XCTUnwrap(Data(base64Encoded: envelope.publicKey)))
        XCTAssertNoThrow(try signed.verify(trustedPublicKey: key.publicKey.rawRepresentation, using: RCIREd25519Verifier()))
        if let evidence = ProcessInfo.processInfo.environment["RCIR_DISPATCH_EVIDENCE"] {
            let output = URL(fileURLWithPath: evidence)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONEncoder().encode(envelope).write(to: output.appendingPathComponent("lost-response-receipt.json"))
            try key.publicKey.rawRepresentation.write(to: output.appendingPathComponent("lost-response-public-key.raw"))
        }
    }

    func testCallerPostconditionCannotBeSilentlyIgnoredByHostObserver() throws {
        let capability = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        config.observers = [capability.id: .init(urlTemplate: base.absoluteString + "/records/{id}", expectedArgument: "value")]
        let result = try engine.begin(id: capability.id, item: "disposable", confirmed: true,
            arguments: ["id": "contradictory", "value": "requested"],
            verification: .init(predicates: [.init(type: .textEquals, value: "contradictory")]))
        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.rcir?.outcome, "failed")
        XCTAssertEqual(result.verification?.status, .verifiedFailure)
        XCTAssertEqual(try effectRows().count, 1)
    }

    func testInvalidSignerBlocksBeforeAnyEffect() throws {
        config.signingKeyFile = directory.appendingPathComponent("not-provisioned").path
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testCrossOriginObserverBlocksBeforeAnyEffect() throws {
        let capability = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        config.observers = [capability.id: .init(urlTemplate: "http://other.invalid/records/{id}", expectedArgument: "value")]
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testObserverTraversalAndDoubleEncodingCannotDispatch() throws {
        let capability = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        config.observers = [capability.id: .init(urlTemplate: base.absoluteString + "/records/{id}", expectedArgument: "value")]
        for id in [".", "..", "../other", "..\\other", "%2Fother", "other?query", "other#fragment"] {
            let record = try engine.begin(id: capability.id, item: "disposable", confirmed: true,
                arguments: ["id": id, "value": "requested"])
            XCTAssertEqual(record.state, .rejected)
            XCTAssertTrue(try effectRows().isEmpty)
        }
    }

    func testSchemaDriftBeforeDispatchProducesZeroProviderEffects() throws {
        host.beforeConsume = { _ in
            self.source.current = [try OpenAPIReflector(specificationData: self.specification("2"), baseURL: self.base)]
        }
        XCTAssertEqual(try invoke().state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testMissingExactOriginAuthorityProducesZeroProviderEffects() throws {
        let secureBase = URL(string: base.absoluteString.replacingOccurrences(of: "http:", with: "https:"))!
        source.current = [try OpenAPIReflector(specificationData: specification(secure: true), baseURL: secureBase)]
        XCTAssertEqual(try invoke().state, .unavailable)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    private func acquireLiveArtifact() throws -> Capability {
        try specification().write(to: directory.appendingPathComponent("spec.json"))
        let artifacts = ConfiguredCapabilityArtifactSource(descriptors: [
            .init(id: "disposable-live-schema", kind: "openapi",
                  specificationURL: base.absoluteString + "/openapi.json", baseURL: base.absoluteString)
        ], refreshInterval: 300)
        engine = CapabilityEngine(reflectorSources: [artifacts], experience: nil, rcirHost: host)
        return try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
    }

    func testActualArtifactSchemaDriftRejectsOldInvocationAndReacquires() throws {
        let old = try acquireLiveArtifact()
        try specification("2").write(to: directory.appendingPathComponent("spec.json"))
        let denied = try engine.begin(id: old.id, item: "disposable", confirmed: true,
                                      arguments: ["id": "stale", "value": "requested"])
        XCTAssertEqual(denied.state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
        let current = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        XCTAssertNotEqual(current.id, old.id)
        let accepted = try engine.begin(id: current.id, item: "disposable", confirmed: true,
                                        arguments: ["id": "fresh", "value": "requested"])
        XCTAssertEqual(accepted.state, .accepted, accepted.message)
        XCTAssertEqual(try effectRows().count, 1)
        XCTAssertEqual(try effectRows().first?["taskID"] as? String, accepted.rcir?.taskID)
    }

    func testActualContractDisappearanceDeniesEffectsAndRecoversNewLease() throws {
        let capability = try acquireLiveArtifact()
        let first = try invoke("initial")
        XCTAssertEqual(first.state, .accepted, first.message)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("spec.json"))
        let denied = try engine.begin(id: capability.id, item: "disposable", confirmed: true,
                                      arguments: ["id": "missing-contract", "value": "requested"])
        XCTAssertEqual(denied.state, .rejected)
        XCTAssertEqual(try effectRows().count, 1)
        try specification().write(to: directory.appendingPathComponent("spec.json"))
        let recovered = try invoke("recovered")
        XCTAssertEqual(recovered.state, .accepted, recovered.message)
        XCTAssertNotEqual(recovered.rcir?.leaseID, first.rcir?.leaseID)
        XCTAssertGreaterThan(recovered.rcir?.generation ?? 0, first.rcir?.generation ?? 0)
        XCTAssertEqual(try effectRows().count, 2)
    }

    func testActualSchemaChangeAfterDispatchRemainsUnknownWithoutRetry() throws {
        _ = try acquireLiveArtifact()
        try Data().write(to: directory.appendingPathComponent("drift-after-write"))
        let record = try invoke()
        XCTAssertEqual(record.state, .unknown)
        XCTAssertEqual(record.rcir?.outcome, "unknown")
        XCTAssertEqual(try effectRows().count, 1)
    }

    func testBoundedLargeArgumentIsNotDuplicatedIntoContract() throws {
        let capability = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        let result = try engine.begin(id: capability.id, item: "disposable", confirmed: true,
            arguments: ["id": "bounded-large", "value": String(repeating: "x", count: 80_000)])
        XCTAssertEqual(result.state, .accepted, result.message)
        XCTAssertEqual(try effectRows().count, 1)
        XCTAssertEqual((try effectRows().first?["body"] as? [String: String])?["value"]?.utf8.count, 80_000)
    }

    func testRemovedInFlightBonjourAcquisitionCannotRestoreInvocation() throws {
        let entered = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0), loaderLock = NSLock()
        var loads = 0
        let bytes = specification()
        let descriptor = BonjourOpenAPIServiceDescriptor(instanceName: "disposable-race",
            serviceType: BonjourOpenAPISource.serviceType, domain: "local.", host: "127.0.0.1",
            port: base.port!, txt: ["kind": "openapi", "scheme": "http", "spec": "/openapi.json", "base": "/"])
        let bonjour = BonjourOpenAPISource(startBrowsing: false, specificationLoader: { _ in
            loaderLock.lock(); loads += 1; let count = loads; loaderLock.unlock()
            if count == 2 {
                entered.signal()
                guard unblock.wait(timeout: .now() + 5) == .success else { throw RightClickError("Fixture acquisition timed out") }
            }
            return bytes
        })
        defer { unblock.signal() }
        bonjour.update(resolved: descriptor)
        engine = CapabilityEngine(reflectorSources: [bonjour], experience: nil, rcirHost: host)
        let capability = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        host.beforeConsume = { _ in
            DispatchQueue.global().async { bonjour.update(resolved: descriptor); finished.signal() }
            guard entered.wait(timeout: .now() + 5) == .success else { throw RightClickError("Fixture did not enter acquisition") }
            bonjour.remove(instanceName: descriptor.instanceName, serviceType: descriptor.serviceType, domain: descriptor.domain)
            XCTAssertTrue(bonjour.reflectors().isEmpty)
            unblock.signal()
            guard finished.wait(timeout: .now() + 5) == .success else { throw RightClickError("Fixture acquisition did not finish") }
            XCTAssertTrue(bonjour.reflectors().isEmpty, "An obsolete acquisition cannot restore a removed provider")
        }
        let result = try engine.begin(id: capability.id, item: "disposable", confirmed: true,
            arguments: ["id": "removed-acquisition", "value": "requested"])
        XCTAssertEqual(result.state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
    }

    func testCredentialFreeObserverCannotInheritInvocationCookie() throws {
        let name = "RCIR_DISPOSABLE_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: name, .value: "fixture-only",
            .domain: "127.0.0.1", .path: "/records"]))
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        try JSONSerialization.data(withJSONObject: ["name": name, "value": "fixture-only"])
            .write(to: directory.appendingPathComponent("cookie-required.json"))
        let capability = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        config.observers = [capability.id: .init(urlTemplate: base.absoluteString + "/records/{id}", expectedArgument: "value")]
        let result = try invoke("cookie-gated")
        XCTAssertEqual(result.state, .accepted, "A credential-free observer cannot verify this protected endpoint")
        XCTAssertEqual(result.rcir?.outcome, "unverified")
        XCTAssertEqual(try effectRows().count, 1)
        let row = try XCTUnwrap(FixtureLineFraming.objects(at: directory.appendingPathComponent("observations.jsonl")).first)
        XCTAssertEqual(row["disposableAuthCookieReceived"] as? Bool, false)
    }

    func testBonjourReappearanceCannotReviveLeaseWithoutIntermediateDiscovery() throws {
        let bytes = specification()
        let descriptor = BonjourOpenAPIServiceDescriptor(instanceName: "disposable-incarnation",
            serviceType: BonjourOpenAPISource.serviceType, domain: "local.", host: "127.0.0.1",
            port: base.port!, txt: ["kind": "openapi", "scheme": "http", "spec": "/openapi.json", "base": "/"])
        let bonjour = BonjourOpenAPISource(startBrowsing: false, specificationLoader: { _ in bytes })
        bonjour.update(resolved: descriptor)
        engine = CapabilityEngine(reflectorSources: [bonjour], experience: nil, rcirHost: host)
        host.beforeConsume = { _ in
            bonjour.remove(instanceName: descriptor.instanceName, serviceType: descriptor.serviceType, domain: descriptor.domain)
            bonjour.update(resolved: descriptor)
            // No engine/providers call observes the missing interval.
        }
        let stale = try invoke("old-incarnation")
        XCTAssertEqual(stale.state, .rejected)
        XCTAssertTrue(try effectRows().isEmpty)
        host.beforeConsume = nil
        let fresh = try invoke("new-incarnation")
        XCTAssertEqual(fresh.state, .accepted)
        XCTAssertEqual(try effectRows().count, 1)
        XCTAssertEqual((try effectRows().first?["body"] as? [String: String])?["id"], "new-incarnation")
    }

    func testBonjourReappearanceAfterDispatchPreservesUnknown() throws {
        let bytes = specification()
        let descriptor = BonjourOpenAPIServiceDescriptor(instanceName: "disposable-post-dispatch",
            serviceType: BonjourOpenAPISource.serviceType, domain: "local.", host: "127.0.0.1",
            port: base.port!, txt: ["kind": "openapi", "scheme": "http", "spec": "/openapi.json", "base": "/"])
        let bonjour = BonjourOpenAPISource(startBrowsing: false, specificationLoader: { _ in bytes })
        bonjour.update(resolved: descriptor)
        engine = CapabilityEngine(reflectorSources: [bonjour], experience: nil, rcirHost: host)
        host.beforeStart = { _, admit, enqueue in
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(enqueue) { start in try permit(start) }
            }
            bonjour.remove(instanceName: descriptor.instanceName, serviceType: descriptor.serviceType, domain: descriptor.domain)
            bonjour.update(resolved: descriptor)
        }
        let result = try invoke("post-dispatch-incarnation")
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.rcir?.outcome, "unknown")
        XCTAssertEqual(try effectRows().count, 1)
    }
}
