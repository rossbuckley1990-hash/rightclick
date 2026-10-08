import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import RightClickCore
@testable import RightClickProviders
@testable import RightClickLink
@testable import RightClickMCP

private final class AdversarialResponseTransport: RemoteLinkTransport {
    let response: Data
    init(_ response: Data) { self.response = response }
    func exchange(_ request: Data, targetRuntimeID: String) async throws -> Data { response }
}

private final class AdversarialFailureReflector: CapabilityVerificationReflector {
    enum EvidenceMode { case empty, allPassed, unevaluated }
    let id = "fixture.inconsistent-failure"
    let capability = Capability(id: "fixture:inconsistent-failure", title: "Inconsistent observer fixture", source: .system,
        safety: .read, invocation: .direct, supportLevel: .experimental, requiresConfirmation: false)
    var mode: EvidenceMode = .empty
    var effects = 0
    func capabilities(for item: ContentItem) throws -> [Capability] { [capability] }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        effects += 1
        return .init(executionId: executionID, actionId: capability.id, state: .accepted,
                     message: "Fixture provider accepted before inconsistent observation.", output: "desired")
    }
    func begin(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?,
               verification: VerificationSpec) throws -> ExecutionRecord {
        var record = try begin(capability: capability, item: item, executionID: executionID)
        record.state = .failed
        record.verification = .init(status: .verifiedFailure, predicates: mode == .empty ? [] : verification.predicates.map {
            .init(predicate: $0, evaluated: mode == .allPassed, passed: mode == .allPassed,
                  message: "Fixture presents contradictory or incomplete failure evidence.")
        })
        record.evidence = .init(type: "fixture_inconsistent_observation", boundary: "Fixture observer assertion.",
                                observationBoundary: .externalState)
        return record
    }
}

private actor DisconnectAfterDeliveryTransport: RemoteLinkTransport {
    let relay: SimulatedLinkRelay
    private var disconnect = true
    init(_ relay: SimulatedLinkRelay) { self.relay = relay }
    func exchange(_ request: Data, targetRuntimeID: String) async throws -> Data {
        let response = try await relay.exchange(request, targetRuntimeID: targetRuntimeID)
        if disconnect {
            disconnect = false
            await relay.disconnect(runtimeID: targetRuntimeID)
            throw RemoteLinkError.connectionLost
        }
        return response
    }
}

/// A real disposable provider, reached through the original OpenAPI transport
/// and original RCIR host. No provider invocation is implemented by this fixture.
@MainActor
private final class AdversarialRCIRFixture {
    final class HostState {
        var clock: Int64 = 1_000
        var configuration = RCIRHostConfiguration()
    }
    final class Source: CapabilityReflectorSource {
        let id = "test.remote.actual-openapi"
        var current: [any CapabilityReflector] = []
        func reflectors() -> [any CapabilityReflector] { current }
    }
    let directory: URL
    let provider: Process
    let base: URL
    let host = RCIRExecutionHost()
    let hostState = HostState()
    let source = Source()
    let engine: CapabilityEngine
    let caller: RemoteNodeIdentity
    let node: RemoteNodeIdentity
    let approval = LinkFixtureApproval()
    let relay = SimulatedLinkRelay()
    let ledger: RemoteReplayLedger
    let dispatcher: RemoteExecutionDispatcher
    let client: RemoteLinkClient
    let capability: Capability

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-adversarial-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        provider = Process()
        provider.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        provider.arguments = [root.appendingPathComponent("scripts/rcir-dispatch-test-provider.py").path, directory.path]
        provider.standardOutput = FileHandle.nullDevice
        provider.standardError = FileHandle.nullDevice
        try provider.run()
        let portFile = directory.appendingPathComponent("port")
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let port = Int(try String(contentsOf: portFile, encoding: .utf8)), (1...65_535).contains(port),
              let url = URL(string: "http://127.0.0.1:\(port)") else {
            provider.terminate(); provider.waitUntilExit()
            throw RightClickError("Disposable provider did not start")
        }
        base = url
        let schema: [String: Any] = ["type": "object", "additionalProperties": false,
            "required": ["id", "value"], "properties": ["id": ["type": "string"], "value": ["type": "string"]]]
        let content: [String: Any] = ["application/json": ["schema": schema]]
        let specification: [String: Any] = ["openapi": "3.0.3", "info": ["title": "Disposable remote RCIR provider", "version": "1"],
            "paths": ["/records": ["post": ["operationId": "writeRecord", "summary": "Write disposable record",
                "requestBody": ["required": true, "content": content],
                "responses": ["200": ["description": "Accepted", "content": content]]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: specification, options: [.sortedKeys])
        let reflector = try OpenAPIReflector(specificationData: bytes, baseURL: base)
        source.current = [reflector]
        let state = hostState
        host.now = { state.clock }
        host.configuration = { state.configuration }
        engine = CapabilityEngine(reflectorSources: [source], experience: nil, rcirHost: host)
        capability = try XCTUnwrap(engine.capabilities(for: "disposable").capabilities.first)
        caller = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 41, count: 32)))
        node = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 42, count: 32)))
        ledger = try .init(directory: directory.appendingPathComponent("journal"), runtimeID: node.runtimeID)
        let grant = try RemoteCallerGrant(publicKey: caller.publicKey, operations: [.runtime, .actions, .run], capabilityIDs: [capability.id])
        dispatcher = try .init(engine: engine, identity: node, ledger: ledger, grants: [grant], enabled: true,
                               localApproval: approval, now: { state.clock })
        client = try .init(identity: caller, trustedRuntimeKey: node.publicKey, transport: relay, now: { state.clock })
    }
    deinit {
        if provider.isRunning { provider.terminate(); provider.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
    func connect() async throws { try await dispatcher.establishOutboundConnection(to: relay) }
    func request(id: String = "remote-record", value: String = "requested", key: UUID = UUID(),
                 verification: VerificationSpec? = nil, approved: Bool = true) throws -> RemoteExecutionRequest {
        let request = client.makeRequest(operation: .run, item: "disposable", capabilityID: capability.id,
            capabilityDigest: try RemoteExecutionDispatcher.contractDigest(capability), arguments: ["id": id, "value": value],
            verification: verification, idempotencyKey: key)
        if approved { approval.ticket = try .init(approvedRequest: request, capabilityDigest: request.capabilityDigest!) }
        return request
    }
    func observe(expectedArgument: String = "value", path: String = "/records/{id}") {
        hostState.configuration.observers = [capability.id: .init(urlTemplate: base.absoluteString + path,
                                                                 expectedArgument: expectedArgument)]
    }
    func effects() throws -> [[String: Any]] {
        let path = directory.appendingPathComponent("effects.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
    func invoke(_ request: RemoteExecutionRequest) throws -> RemoteExecutionResult {
        let bytes = try SignedRemoteMessage.request(request, signer: caller)
        return try SignedRemoteMessage.verifiedResult(dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: node.publicKey)
    }
}

final class RemoteAdversarialTests: XCTestCase {
    @MainActor func testRelayCannotForgeAcceptanceWithAnotherSigningKey() async throws {
        let f = try LinkFixture()
        let request = try f.request()
        let bytes = try f.bytes(request)
        let honest = try SignedRemoteMessage.verifiedResult(f.dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: f.identity.publicKey)
        let forged = try SignedRemoteMessage.seal(honest, domain: RemoteWire.resultDomain, signer: f.caller)
        let client = try RemoteLinkClient(identity: f.caller, trustedRuntimeKey: f.identity.publicKey,
            transport: AdversarialResponseTransport(forged), now: { 1_000 })
        do { _ = try await client.send(request); XCTFail("The relay's key impersonated the enrolled node") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .unauthenticated) }
        XCTAssertEqual(f.provider.effects, 1)
    }

    @MainActor func testRelayCannotChangeAuthenticatedResultOrSubstituteAnotherRequestResult() async throws {
        let f = try LinkFixture()
        let first = try f.request(); let firstBytes = try f.bytes(first)
        let honest = try f.dispatcher.handle(firstBytes)
        var envelope = try RemoteWire.decode(SignedRemoteMessage.self, honest, maximum: RemoteWire.maximumWireBytes)
        let result = try RemoteWire.decode(RemoteExecutionResult.self, envelope.payload)
        var summary = result.summary; summary.completedAtMilliseconds += 1
        let changed = RemoteExecutionResult(version: result.version, requestID: result.requestID,
            requestDigest: result.requestDigest, callerID: result.callerID, runtimeID: result.runtimeID,
            deviceID: result.deviceID, idempotencyKey: result.idempotencyKey, reused: result.reused, summary: summary)
        envelope.payload = try RemoteWire.encode(changed)
        XCTAssertThrowsError(try SignedRemoteMessage.verifiedResult(RemoteWire.encode(envelope), for: firstBytes,
            trustedRuntimeKey: f.identity.publicKey)) { XCTAssertEqual($0 as? RemoteLinkError, .unauthenticated) }
        XCTAssertThrowsError(try SignedRemoteMessage.verifiedResult(honest, for: f.bytes(f.request()),
            trustedRuntimeKey: f.identity.publicKey)) { XCTAssertEqual($0 as? RemoteLinkError, .wrongRuntime) }
        XCTAssertEqual(f.provider.effects, 1)
    }

    @MainActor func testEveryAuthoritativeRequestFieldIsCoveredByAuthentication() async throws {
        let f = try LinkFixture()
        let original = try f.request()
        let signed = try RemoteWire.decode(SignedRemoteMessage.self, f.bytes(original), maximum: RemoteWire.maximumWireBytes)
        var changes: [RemoteExecutionRequest] = []
        var changed = original; changed.capabilityID = "fixture:missing"; changes.append(changed)
        changed = original; changed.capabilityDigest = String(repeating: "a", count: 64); changes.append(changed)
        changed = original; changed.targetRuntimeID = "runtime:" + String(repeating: "a", count: 64); changes.append(changed)
        changed = original; changed.targetDeviceID = "device:" + String(repeating: "a", count: 64); changes.append(changed)
        changed = original; changed.expiresAtMilliseconds += 1; changes.append(changed)
        changed = original; changed.issuedAtMilliseconds -= 1; changes.append(changed)
        changed = original; changed.idempotencyKey = UUID(); changes.append(changed)
        changed = original; changed.nonce = Data(repeating: 9, count: 32); changes.append(changed)
        changed = original; changed.operation = .actions; changed.capabilityID = nil; changed.capabilityDigest = nil; changed.verification = nil; changes.append(changed)
        changed = original; changed.arguments = ["consent": "true"]; changes.append(changed)
        changed = original; changed.verification = .init(predicates: [.init(type: .textEquals, value: "forged")]); changes.append(changed)
        for change in changes {
            var envelope = signed; envelope.payload = try RemoteWire.encode(change)
            XCTAssertThrowsError(try f.dispatcher.handle(RemoteWire.encode(envelope))) { XCTAssertEqual($0 as? RemoteLinkError, .unauthenticated) }
        }
        XCTAssertEqual(f.provider.effects, 0)
    }

    @MainActor func testSignedUnknownConsentFieldAndNestedOversizedPayloadCannotApprove() async throws {
        let f = try LinkFixture(); f.provider.declaration.requiresConfirmation = true
        let request = try f.request()
        let payload = try RemoteWire.encode(request)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        object["confirmed"] = true
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let envelope = SignedRemoteMessage(keyID: RemoteWire.digest(f.caller.publicKey), payload: changed,
            signature: try f.caller.sign(RemoteWire.requestDomain + changed))
        XCTAssertThrowsError(try f.dispatcher.handle(RemoteWire.encode(envelope))) { XCTAssertEqual($0 as? RemoteLinkError, .malformed) }
        XCTAssertThrowsError(try f.dispatcher.handle(Data(repeating: 65, count: RemoteWire.maximumWireBytes + 1))) {
            XCTAssertEqual($0 as? RemoteLinkError, .limitExceeded)
        }
        let nested = Data((String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17)).utf8)
        XCTAssertThrowsError(try RemoteWire.decode(SignedRemoteMessage.self, nested)) { XCTAssertEqual($0 as? RemoteLinkError, .limitExceeded) }
        XCTAssertEqual(f.provider.effects, 0)
    }

    @MainActor func testSimultaneousFreshRequestsWithSameIntentHaveOneEffect() async throws {
        let f = try LinkFixture(); try await f.connect()
        let key = UUID()
        let requests = try (0..<12).map { _ in try f.request(key: key) }
        var results: [RemoteExecutionResult] = []
        try await withThrowingTaskGroup(of: RemoteExecutionResult.self) { group in
            for request in requests { group.addTask { try await f.client.send(request) } }
            for try await result in group { results.append(result) }
        }
        XCTAssertEqual(results.count, 12)
        XCTAssertEqual(results.filter { !$0.reused }.count, 1)
        XCTAssertEqual(Set(results.compactMap { $0.summary.evidenceExecutionID }).count, 1)
        XCTAssertTrue(results.allSatisfy { $0.summary.verification == .verifiedSuccess })
        XCTAssertEqual(f.provider.effects, 1)
    }

    @MainActor func testOfflineAfterDeliveryAndAmbiguousRetryCannotMoveOrRepeatExecution() async throws {
        let f = try LinkFixture(); try await f.connect()
        let client = try RemoteLinkClient(identity: f.caller, trustedRuntimeKey: f.identity.publicKey,
            transport: DisconnectAfterDeliveryTransport(f.relay), now: { 1_000 })
        let key = UUID()
        do { _ = try await client.send(f.request(key: key)); XCTFail("Lost response became execution evidence") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .connectionLost) }
        do { _ = try await client.send(f.request(key: key)); XCTFail("Offline node fabricated a result") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .unavailable) }
        try await f.connect()
        let recovered = try await client.send(f.request(key: key))
        XCTAssertTrue(recovered.reused)
        XCTAssertEqual(recovered.summary.verification, .verifiedSuccess)
        XCTAssertEqual(f.provider.effects, 1)
    }

    func testAcceptedUnverifiedSummaryCannotClaimVerifiedLifecycle() throws {
        let contradiction = RemoteExecutionSummary(state: .accepted, policy: .evaluated, providerAcceptance: .accepted,
            lifecycle: [.requested, .authorized, .delivered, .executing, .providerAccepted, .verified], completedAtMilliseconds: 1_000)
        XCTAssertThrowsError(try contradiction.validate()) { XCTAssertEqual($0 as? RemoteLinkError, .inconsistentResult) }
    }

    @MainActor func testEmptyPassedOrUnevaluatedFailureEvidenceCannotClaimVerifiedFailure() async throws {
        let f = try LinkFixture()
        let provider = AdversarialFailureReflector()
        let engine = CapabilityEngine(reflectors: [provider], experience: nil)
        let capability = try XCTUnwrap(engine.capabilities(for: "desired").capabilities.first)
        let grant = try RemoteCallerGrant(publicKey: f.caller.publicKey, operations: [.run], capabilityIDs: [capability.id])
        let dispatcher = try RemoteExecutionDispatcher(engine: engine, identity: f.identity, ledger: f.ledger,
            grants: [grant], enabled: true, now: { 1_000 })
        for mode in [AdversarialFailureReflector.EvidenceMode.empty, .allPassed, .unevaluated] {
            provider.mode = mode
            let request = f.client.makeRequest(operation: .run, item: "desired", capabilityID: capability.id,
                capabilityDigest: try RemoteExecutionDispatcher.contractDigest(capability),
                verification: .init(predicates: [.init(type: .textEquals, value: "desired")]))
            let bytes = try f.bytes(request)
            let result = try SignedRemoteMessage.verifiedResult(dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: f.identity.publicKey)
            XCTAssertEqual(result.summary.verification, .unverified)
            XCTAssertNotEqual(result.summary.state, .succeeded)
        }
        XCTAssertEqual(provider.effects, 3)
    }

    @MainActor func testWebURLUsesExistingContentKindAndCanExecuteRemotely() async throws {
        let f = try LinkFixture()
        var request = try f.request(verification: false)
        request.item = "https://example.invalid/disposable"
        let bytes = try f.bytes(request)
        let result = try SignedRemoteMessage.verifiedResult(f.dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: f.identity.publicKey)
        XCTAssertEqual(result.summary.state, .accepted)
        XCTAssertEqual(result.summary.providerAcceptance, .accepted)
        XCTAssertEqual(f.provider.effects, 1)
    }

    @MainActor func testTargetRelativePathsAndInspectErrorsReturnOnlySafeLinkErrors() async throws {
        let f = try LinkFixture()
        for item in ["~/rightclick-private-missing-" + UUID().uuidString,
                     "/rightclick-private-missing-" + UUID().uuidString,
                     "./rightclick-private-missing-" + UUID().uuidString,
                     "../rightclick-private-missing-" + UUID().uuidString,
                     "file:///rightclick-private-missing-" + UUID().uuidString,
                     ""] {
            let request = f.client.makeRequest(operation: .actions, item: item)
            XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(request))) { error in
                XCTAssertNotNil(error as? RemoteLinkError, "Raw local parser errors must not escape over Link")
                XCTAssertFalse(String(describing: error).contains(NSHomeDirectory()))
                XCTAssertFalse(String(describing: error).contains("No file at"))
            }
        }
        XCTAssertEqual(f.provider.effects, 0)
    }

    @MainActor func testRemoteBasenameCannotProbeFilesAndReentrantLocalMCPRetainsFileParsing() async throws {
        let f = try LinkFixture()
        // SwiftPM runs this package's tests from its checkout. The manifest is
        // existing read-only input; this test never changes the working directory.
        let hostItem = try f.engine.inspect("Package.swift")
        XCTAssertNotNil(hostItem.path)
        let box = EngineBox(f.engine)
        var localItems: [ContentItem] = []
        f.provider.onDiscovery = { _ in
            do {
                let json = try handleTool("context_inspect", arguments: ["item": .string("Package.swift")], engine: box, transport: "stdio")
                localItems.append(try JSONDecoder().decode(ContentItem.self, from: Data(json.utf8)))
            } catch { XCTFail("Reentrant local inspection failed: \(error)") }
        }
        let request = f.client.makeRequest(operation: .actions, item: "Package.swift")
        let bytes = try f.bytes(request)
        let result = try SignedRemoteMessage.verifiedResult(f.dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: f.identity.publicKey)
        XCTAssertEqual(result.summary.capabilities.count, 1)
        XCTAssertFalse(localItems.isEmpty)
        XCTAssertTrue(localItems.allSatisfy { $0.path == hostItem.path })
        XCTAssertEqual(try f.engine.inspect("Package.swift").path, hostItem.path)
        XCTAssertEqual(f.provider.effects, 0)
    }

    #if os(macOS)
    private func addACL(_ acl: String, path: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", acl, path.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RightClickError("Could not provision disposable ACL attack fixture") }
    }

    @MainActor func testMacExtendedACLDeleteChildGrantCannotResetPrivateLedger() async throws {
        let f = try LinkFixture()
        try addACL("everyone allow search,delete_child,add_file,add_subdirectory", path: f.parent)
        defer {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["-N", f.parent.path]; process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice; try? process.run(); process.waitUntilExit()
        }
        XCTAssertThrowsError(try f.ledger.reserve(f.request(), now: 1_000)) { XCTAssertEqual($0 as? RemoteLinkError, .storageUnavailable) }
        XCTAssertThrowsError(try RemoteReplayLedger(directory: f.parent.appendingPathComponent("new-journal"), runtimeID: f.identity.runtimeID)) {
            XCTAssertEqual($0 as? RemoteLinkError, .storageUnavailable)
        }
        XCTAssertEqual(f.provider.effects, 0)
    }

    @MainActor func testMacExtendedACLWriteGrantCannotTamperPrivateHistory() async throws {
        let f = try LinkFixture()
        let history = f.parent.appendingPathComponent("journal/link.json")
        try addACL("everyone allow write", path: history)
        XCTAssertThrowsError(try f.ledger.reserve(f.request(), now: 1_000)) { XCTAssertEqual($0 as? RemoteLinkError, .storageUnavailable) }
        XCTAssertEqual(f.provider.effects, 0)
    }
    #endif

    @MainActor func testRealOpenAPIExecutionThroughLinkUsesOneRCIRLeaseAndHostReadback() async throws {
        let f = try AdversarialRCIRFixture(); f.observe(); try await f.connect()
        let key = UUID(); let request = try f.request(key: key)
        let result = try await f.client.send(request)
        XCTAssertEqual(result.summary.state, .succeeded)
        XCTAssertEqual(result.summary.providerAcceptance, .accepted)
        XCTAssertEqual(result.summary.verification, .verifiedSuccess)
        XCTAssertEqual(result.summary.observationBoundary, .externalState)
        let evidenceID = try XCTUnwrap(result.summary.evidenceExecutionID)
        let retained = f.engine.executionStatus(evidenceID)
        XCTAssertEqual(retained.rcir?.leaseConsumed, true)
        XCTAssertEqual(retained.rcir?.outcome, "succeeded")
        XCTAssertEqual(retained.evidence.type, "rcir_http_readback")
        let effects = try f.effects()
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects.first?["taskID"] as? String, retained.rcir?.taskID)
        let retry = try await f.client.send(f.request(key: key))
        XCTAssertTrue(retry.reused)
        XCTAssertEqual(retry.summary.evidenceExecutionID, result.summary.evidenceExecutionID)
        XCTAssertEqual(try f.effects().count, 1)
        print("ADVERSARIAL REAL PROVIDER: Link -> original CapabilityEngine -> actual OpenAPI HTTP -> consumed RCIR lease -> separate host GET -> signed verified result; fresh retry effects=1")
    }

    @MainActor func testRealOpenAPIRequiresLocalApprovalAndHostDenialNeverInvokesProvider() async throws {
        let f = try AdversarialRCIRFixture()
        XCTAssertTrue(f.capability.requiresConfirmation)
        let pending = try f.invoke(f.request(approved: false))
        XCTAssertEqual(pending.summary.state, .awaitingUser)
        XCTAssertEqual(pending.summary.policy, .confirmationRequired)
        XCTAssertEqual(pending.summary.providerAcceptance, .notInvoked)
        XCTAssertEqual(try f.effects().count, 0)
        f.hostState.configuration.deniedCapabilities = [f.capability.id]
        let denied = try f.invoke(f.request())
        XCTAssertEqual(denied.summary.state, .rejected)
        XCTAssertEqual(denied.summary.policy, .denied)
        XCTAssertEqual(denied.summary.providerAcceptance, .notInvoked)
        XCTAssertEqual(denied.summary.verification, .unverified)
        XCTAssertEqual(try f.effects().count, 0)
    }

    @MainActor func testRealOpenAPICurrentPolicyRevocationAtConsumptionBlocksEffect() async throws {
        let f = try AdversarialRCIRFixture()
        f.host.beforeConsume = { _ in f.hostState.configuration.deniedCapabilities = [f.capability.id] }
        let denied = try f.invoke(f.request())
        XCTAssertEqual(denied.summary.policy, .denied)
        XCTAssertEqual(denied.summary.providerAcceptance, .notInvoked)
        XCTAssertEqual(try f.effects().count, 0)
    }

    @MainActor func testRealOpenAPICallerRevocationAfterAdmissionBlocksEffect() async throws {
        let f = try AdversarialRCIRFixture()
        f.host.beforeConsume = { _ in f.dispatcher.revoke(callerID: RemoteWire.digest(f.caller.publicKey)) }
        let denied = try f.invoke(f.request())
        XCTAssertEqual(denied.summary.policy, .denied)
        XCTAssertEqual(denied.summary.providerAcceptance, .notInvoked)
        XCTAssertEqual(try f.effects().count, 0)
    }

    @MainActor func testRealOpenAPIExpiryAfterAdmissionBlocksEffect() async throws {
        let f = try AdversarialRCIRFixture()
        let request = try f.request()
        f.host.beforeConsume = { _ in f.hostState.clock = request.expiresAtMilliseconds }
        let expired = try f.invoke(request)
        XCTAssertEqual(expired.summary.policy, .denied)
        XCTAssertEqual(expired.summary.providerAcceptance, .notInvoked)
        XCTAssertEqual(try f.effects().count, 0)
    }

    @MainActor func testRealOpenAPIAcceptanceWithoutObserverStaysUnverified() async throws {
        let f = try AdversarialRCIRFixture()
        let result = try f.invoke(f.request())
        XCTAssertEqual(result.summary.state, .accepted)
        XCTAssertEqual(result.summary.providerAcceptance, .accepted)
        XCTAssertEqual(result.summary.verification, .unverified)
        XCTAssertEqual(result.summary.observationBoundary, .none)
        XCTAssertEqual(try f.effects().count, 1)
    }

    @MainActor func testRealOpenAPIContradictoryReturnedEvidenceCannotPromoteAcceptance() async throws {
        let f = try AdversarialRCIRFixture(); f.observe()
        let result = try f.invoke(f.request(verification: .init(predicates: [.init(type: .textEquals, value: "false-postcondition")])) )
        XCTAssertEqual(result.summary.state, .failed)
        XCTAssertEqual(result.summary.providerAcceptance, .accepted)
        XCTAssertEqual(result.summary.verification, .verifiedFailure)
        XCTAssertEqual(result.summary.observationBoundary, .externalState)
        XCTAssertEqual(try f.effects().count, 1)
    }

    @MainActor func testRealOpenAPIReadbackMismatchReportsAcceptedVerifiedFailure() async throws {
        let f = try AdversarialRCIRFixture(); f.observe(expectedArgument: "id")
        let result = try f.invoke(f.request(id: "expected-id", value: "different-state"))
        XCTAssertEqual(result.summary.state, .failed)
        XCTAssertEqual(result.summary.providerAcceptance, .accepted)
        XCTAssertEqual(result.summary.verification, .verifiedFailure)
        XCTAssertEqual(try f.effects().count, 1)
    }

    @MainActor func testRealOpenAPIUnobservableStateDoesNotBorrowInvocationCookieOrExportIt() async throws {
        let f = try AdversarialRCIRFixture(); f.observe()
        let cookieName = "RIGHTCLICK_ADVERSARIAL_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let secret = "TEST-ONLY-PROVIDER-COOKIE-" + UUID().uuidString
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: cookieName, .value: secret, .domain: "127.0.0.1", .path: "/records"]))
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        try JSONSerialization.data(withJSONObject: ["name": cookieName, "value": secret])
            .write(to: f.directory.appendingPathComponent("cookie-required.json"))
        let result = try f.invoke(f.request())
        XCTAssertEqual(result.summary.state, .accepted)
        XCTAssertEqual(result.summary.providerAcceptance, .accepted)
        XCTAssertEqual(result.summary.verification, .unverified)
        XCTAssertEqual(try f.effects().count, 1)
        let observations = try String(contentsOf: f.directory.appendingPathComponent("observations.jsonl"), encoding: .utf8)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(observations.split(separator: "\n").first).utf8)) as? [String: Any])
        XCTAssertEqual(row["disposableAuthCookieReceived"] as? Bool, false)
        XCTAssertFalse(String(decoding: try RemoteWire.encode(result), as: UTF8.self).contains(secret))
        XCTAssertFalse(try String(contentsOf: f.directory.appendingPathComponent("journal/link.json"), encoding: .utf8).contains(secret))
    }

    @MainActor func testRealOpenAPIProviderDisappearanceAfterDispatchRemainsUnknownWithoutRetry() async throws {
        let f = try AdversarialRCIRFixture()
        f.host.beforeStart = { _, admit, enqueue in
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(enqueue) { start in try permit(start) }
            }
            f.source.current = []
        }
        let key = UUID(); let first = try f.invoke(f.request(key: key))
        XCTAssertEqual(first.summary.state, .unknown)
        XCTAssertEqual(first.summary.providerAcceptance, .unknown)
        XCTAssertEqual(first.summary.verification, .unverified)
        XCTAssertEqual(try f.effects().count, 1)
        let retry = try f.invoke(f.request(key: key))
        XCTAssertTrue(retry.reused)
        XCTAssertEqual(retry.summary.state, .unknown)
        XCTAssertEqual(try f.effects().count, 1)
    }
}
