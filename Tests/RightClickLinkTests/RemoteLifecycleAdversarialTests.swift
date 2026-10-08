import Foundation
import XCTest
import RightClickProtocol
import RightClickCore
import RightClickProviders
@testable import RightClickLink

private final class LifecycleAdversarialTransport: RemoteLinkTransport {
    var response: (Data) throws -> Data
    init(response: @escaping (Data) throws -> Data) { self.response = response }
    func exchange(_ request: Data, targetRuntimeID: String) async throws -> Data { try response(request) }
}

private final class LifecycleAdversarialProvider: RCIRExecutionReflector {
    let id = "fixture:adversarial-deferred-owner"
    let sentinel = "TEST-ONLY-PRIVATE-PROVIDER-OBSERVATION"
    var effects = 0
    var host: RCIRExecutionHost?
    var executionID: String?
    var capability: Capability {
        .init(id: "fixture:adversarial-deferred", title: "Adversarial deferred fixture", source: .system,
            reflectorID: id, safety: .read, invocation: .direct, supportLevel: .experimental, requiresConfirmation: false)
    }
    func capabilities(for item: ContentItem) throws -> [Capability] { [capability] }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        throw RightClickError("Fixture must enter the ordinary RCIR admission host.")
    }
    func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem, executionID: String,
        arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?,
        host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        let abi = try admissionOwner.abiContract(arguments: .string, result: .string)
        let scope = RCIRScope("urn:rightclick:adversarial:disposable-counter", .execute)
        return try host.execute(abi: abi, discovery: abi, arguments: .string(item.text ?? ""), scope: scope,
            taskModel: .init(shape: .deferred, maxEvents: 16, maxBytes: 16_384), capability: admissionOwner,
            executionID: executionID, argumentStrings: arguments, item: item, verification: verification,
            expectedOutput: expectedOutput, target: URL(string: "https://example.invalid/adversarial")!,
            authority: { [scope] }, revalidate: revalidate, currentContract: { true },
            dispatch: { _, start in
                try start {
                    self.effects += 1; self.host = host; self.executionID = executionID
                    _ = try? host.recordActiveTaskEvent(executionID: executionID, event: .accepted, now: Self.now())
                }
                return .init(executionId: executionID, actionId: capability.id, state: .started,
                    message: self.sentinel, output: self.sentinel)
            }, resultValue: { _ in throw RightClickError("A live task has no terminal result.") })
    }
    func emit(_ event: RCIRTaskEvent) throws {
        _ = try XCTUnwrap(host).recordActiveTaskEvent(executionID: XCTUnwrap(executionID), event: event, now: Self.now())
    }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

@MainActor
private final class LifecycleAdversarialFixture {
    let directory: URL
    let provider = LifecycleAdversarialProvider()
    let caller: RemoteNodeIdentity
    let node: RemoteNodeIdentity
    let engine: CapabilityEngine
    let ledger: RemoteReplayLedger
    let dispatcher: RemoteExecutionDispatcher
    let relay = SimulatedLinkRelay()
    let client: RemoteLinkClient
    init(statusAllowed: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-lifecycle-adversarial-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        caller = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 21, count: 32)))
        node = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 22, count: 32)))
        engine = CapabilityEngine(reflectors: [provider], experience: nil,
            runtimeEnvironment: .init(operatingSystem: .linux, architecture: "x86_64"))
        ledger = try .init(directory: directory.appendingPathComponent("journal"), runtimeID: node.runtimeID)
        let operations: Set<RemoteOperation> = statusAllowed ? [.runtime, .actions, .run, .status] : [.run]
        let grant = try RemoteCallerGrant(publicKey: caller.publicKey, operations: operations, capabilityIDs: [provider.capability.id])
        dispatcher = try .init(engine: engine, identity: node, ledger: ledger, grants: [grant], enabled: true, now: { 1_000 })
        client = try .init(identity: caller, trustedRuntimeKey: node.publicKey, transport: relay, now: { 1_000 })
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func connect() async throws { try await dispatcher.establishOutboundConnection(to: relay) }
    func run(key: UUID = UUID()) throws -> RemoteExecutionRequest {
        let capability = try XCTUnwrap(engine.capabilities(for: "fixture").capabilities.first)
        return client.makeRequest(operation: .run, item: "fixture", capabilityID: capability.id,
            capabilityDigest: try RemoteExecutionDispatcher.contractDigest(capability), idempotencyKey: key)
    }
    func handle(_ request: RemoteExecutionRequest, signer: RemoteNodeIdentity? = nil) throws -> RemoteExecutionResult {
        let bytes = try SignedRemoteMessage.request(request, signer: signer ?? caller)
        return try SignedRemoteMessage.verifiedResult(dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: node.publicKey)
    }
}

/// An enrolled signer is authenticated, but its status must still be coherent.
final class RemoteLifecycleAdversarialTests: XCTestCase {
    private let executionID = "00000000-0000-0000-0000-000000000001"
    private let originatingID = "00000000-0000-0000-0000-000000000002"
    private let taskID = "00000000-0000-0000-0000-000000000003"

    private func working() -> RemoteExecutionSummary {
        .init(state: .started, policy: .evaluated, providerAcceptance: .accepted,
            evidenceExecutionID: executionID,
            lifecycle: [.requested, .authorized, .delivered, .executing], completedAtMilliseconds: 1_000,
            executionLifecycle: .init(executionID: executionID, originatingRequestID: originatingID,
                runtimeID: "runtime:" + String(repeating: "a", count: 64), taskID: taskID,
                generation: 1, taskShape: .deferred, phase: .working, semanticOutcome: .unverified,
                sequence: 2, terminal: false, providerAcceptance: .accepted, verification: .unverified,
                observationBoundary: .none),
            eventPage: .init(events: [
                .init(sequence: 1, time: 999, kind: "accepted", value: .null),
                .init(sequence: 2, time: 1_000, kind: "working", value: .null)
            ], nextCursor: 2, hasMore: false, terminal: false))
    }

    private func alterLifecycle(_ summary: RemoteExecutionSummary, _ edits: [String: Any]) throws -> RemoteExecutionSummary {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteWire.encode(summary)) as? [String: Any])
        var lifecycle = try XCTUnwrap(object["executionLifecycle"] as? [String: Any])
        edits.forEach { lifecycle[$0.key] = $0.value }
        object["executionLifecycle"] = lifecycle
        return try JSONDecoder().decode(RemoteExecutionSummary.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    func testLiveSnapshotCannotAdvertiseReceiptResultOrVerifiedSuccess() throws {
        XCTAssertNoThrow(try working().validate())
        let mutations: [[String: Any]] = [
            ["receiptAvailable": true], ["signedReceiptAvailable": true],
            ["evidenceID": taskID], ["semanticOutcome": "succeeded"],
            ["verification": "VERIFIED_SUCCESS"], ["terminal": true],
            ["phase": "completed"], ["sequence": -1], ["sequence": 1_025], ["generation": -1]
        ]
        for mutation in mutations {
            let changed = try alterLifecycle(working(), mutation)
            XCTAssertThrowsError(try changed.validate(), "Accepted contradictory lifecycle: \(mutation)")
        }
        var withResult = working(); withResult.result = .integer(42)
        XCTAssertThrowsError(try withResult.validate())
    }

    func testPageCannotReplaySequenceSkipSequenceOrLieAboutCursor() throws {
        for sequences in [[Int64(1), 1], [1, 3], [2, 3], [0, 1]] {
            var summary = working()
            summary.eventPage = .init(events: sequences.map {
                .init(sequence: $0, time: 1_000, kind: "working", value: .null)
            }, nextCursor: 2, hasMore: false, terminal: false)
            XCTAssertThrowsError(try summary.validatePage(after: 0, limit: 64, maximumBytes: 16_384))
        }
        var lie = working()
        lie.eventPage = .init(events: working().eventPage!.events, nextCursor: 1, hasMore: false, terminal: false)
        XCTAssertThrowsError(try lie.validate())
        XCTAssertThrowsError(try lie.validatePage(after: 0, limit: 64, maximumBytes: 16_384))
    }

    func testStatusCursorAndByteBoundsRejectIntegerExtremes() throws {
        for cursor in [Int64.min, -1] {
            XCTAssertThrowsError(try RemoteStatusQuery(originatingRequestID: UUID(), executionID: executionID, cursor: cursor).validate())
        }
        for limit in [Int.min, 0, 257, Int.max] {
            XCTAssertThrowsError(try RemoteStatusQuery(originatingRequestID: UUID(), executionID: executionID, limit: limit).validate())
        }
        for maximum in [Int.min, 0, 16_385, Int.max] {
            XCTAssertThrowsError(try RemoteStatusQuery(originatingRequestID: UUID(), executionID: executionID, maximumBytes: maximum).validate())
        }
        XCTAssertThrowsError(try working().validatePage(after: 3, limit: 64, maximumBytes: 16_384))
        XCTAssertThrowsError(try working().validatePage(after: Int64.max, limit: 64, maximumBytes: 16_384))
    }

    func testOversizedTypedEventCannotExceedRequestedPageBudget() throws {
        var summary = working()
        summary.eventPage = .init(events: [
            .init(sequence: 1, time: 999, kind: "accepted", value: .null),
            .init(sequence: 2, time: 1_000, kind: "working", value: .string(String(repeating: "x", count: 16_384)))
        ], nextCursor: 2, hasMore: false, terminal: false)
        XCTAssertThrowsError(try summary.validatePage(after: 0, limit: 64, maximumBytes: 16_384))
    }

    func testEventPageTerminalityCannotContradictLifecycle() throws {
        var summary = working()
        summary.eventPage = .init(events: summary.eventPage!.events, nextCursor: 2, hasMore: false, terminal: true)
        XCTAssertThrowsError(try summary.validate())
        var missing = working(); missing.eventPage = nil
        XCTAssertThrowsError(try missing.validatePage(after: 0, limit: 64, maximumBytes: 16_384))
    }

    func testAuthenticatedCompletedEventCannotDescribeStillWorkingTask() throws {
        var summary = working()
        summary.eventPage = .init(events: [
            .init(sequence: 1, time: 999, kind: "accepted", value: .null),
            .init(sequence: 2, time: 1_000, kind: "completed", value: .integer(42))
        ], nextCursor: 2, hasMore: false, terminal: false)
        XCTAssertThrowsError(try summary.validate(), "A signed terminal provider event must not coexist with a live lifecycle")
    }

    func testObservationAvailabilityAndSemanticFailureCannotBeContradictory() throws {
        var unknown = try alterLifecycle(working(), ["phase": "unknown", "terminal": true, "semanticOutcome": "unverified"])
        unknown.state = .unknown; unknown.providerAcceptance = .unknown
        XCTAssertThrowsError(try unknown.validate())
        var unproved = try alterLifecycle(working(), ["phase": "completed", "terminal": true, "semanticOutcome": "succeeded"])
        unproved.state = .succeeded
        XCTAssertThrowsError(try unproved.validate())
    }

    private func signedReply(to bytes: Data, summary: RemoteExecutionSummary,
                             node: RemoteNodeIdentity, reused: Bool = false) throws -> Data {
        let envelope = try RemoteWire.decode(SignedRemoteMessage.self, bytes)
        let request = try RemoteWire.decode(RemoteExecutionRequest.self, envelope.payload)
        return try SignedRemoteMessage.seal(RemoteExecutionResult(version: 1, requestID: request.requestID,
            requestDigest: RemoteWire.digest(envelope.payload), callerID: request.callerID,
            runtimeID: node.runtimeID, deviceID: node.deviceID, idempotencyKey: request.idempotencyKey,
            reused: reused, summary: summary), domain: RemoteWire.resultDomain, signer: node)
    }

    func testInitialLiveResponseCannotSubstituteOriginatingRequestIdentity() async throws {
        let caller = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 11, count: 32)))
        let node = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 12, count: 32)))
        let substituted = try alterLifecycle(working(), ["runtimeID": node.runtimeID])
        let transport = LifecycleAdversarialTransport { try self.signedReply(to: $0, summary: substituted, node: node) }
        let client = try RemoteLinkClient(identity: caller, trustedRuntimeKey: node.publicKey,
            transport: transport, now: { 1_000 })
        let request = client.makeRequest(operation: .run, item: "fixture", capabilityID: "fixture:adversarial",
            capabilityDigest: String(repeating: "b", count: 64))
        XCTAssertNotEqual(request.requestID.uuidString, originatingID)
        do { _ = try await client.send(request); XCTFail("Accepted signed live identity from a different originating run") }
        catch { XCTAssertNotNil(error as? RemoteLinkError) }
    }

    func testStatusCannotSubstituteGenerationTaskOrShapeAfterInitialObservation() async throws {
        for change in [["generation": 2] as [String: Any], ["taskID": UUID().uuidString], ["taskShape": "unary"]] {
            let caller = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 13, count: 32)))
            let node = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 14, count: 32)))
            var summary = working()
            let transport = LifecycleAdversarialTransport { try self.signedReply(to: $0, summary: summary, node: node) }
            let client = try RemoteLinkClient(identity: caller, trustedRuntimeKey: node.publicKey,
                transport: transport, now: { 1_000 })
            let run = client.makeRequest(operation: .run, item: "fixture", capabilityID: "fixture:adversarial",
                capabilityDigest: String(repeating: "b", count: 64))
            summary = try alterLifecycle(summary, ["runtimeID": node.runtimeID, "originatingRequestID": run.requestID.uuidString])
            _ = try await client.send(run)
            summary = try alterLifecycle(summary, change)
            let poll = client.makeStatusRequest(for: run, executionID: executionID)
            do { _ = try await client.send(poll); XCTFail("Accepted changed admitted execution identity: \(change)") }
            catch { XCTAssertEqual(error as? RemoteLinkError, .staleGeneration) }
        }
    }

    func testAuthenticatedRepeatedEventCannotSubstituteTypedValue() async throws {
        let caller = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 15, count: 32)))
        let node = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 16, count: 32)))
        var summary = working()
        let transport = LifecycleAdversarialTransport { try self.signedReply(to: $0, summary: summary, node: node) }
        let client = try RemoteLinkClient(identity: caller, trustedRuntimeKey: node.publicKey,
            transport: transport, now: { 1_000 })
        let run = client.makeRequest(operation: .run, item: "fixture", capabilityID: "fixture:adversarial",
            capabilityDigest: String(repeating: "b", count: 64))
        summary = try alterLifecycle(summary, ["runtimeID": node.runtimeID, "originatingRequestID": run.requestID.uuidString])
        _ = try await client.send(run)
        summary.eventPage = .init(events: [
            .init(sequence: 1, time: 999, kind: "accepted", value: .null),
            .init(sequence: 2, time: 1_000, kind: "working", value: .string("substituted"))
        ], nextCursor: 2, hasMore: false, terminal: false)
        let poll = client.makeStatusRequest(for: run, executionID: executionID)
        do { _ = try await client.send(poll); XCTFail("Accepted changed bytes for an already authenticated sequence") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .invalidSequence) }
    }

    @MainActor func testAdmittedStatusRejectsEveryOriginalExecutionBindingSubstitution() async throws {
        let fixture = try LifecycleAdversarialFixture()
        let run = try fixture.run(), started = try fixture.handle(run)
        let id = try XCTUnwrap(started.summary.executionLifecycle?.executionID)
        let poll = fixture.client.makeStatusRequest(for: run, executionID: id)
        var changes: [RemoteExecutionRequest] = []
        var change = poll; change.status?.originatingRequestID = UUID(); changes.append(change)
        change = poll; change.status?.executionID = UUID().uuidString; changes.append(change)
        change = poll; change.idempotencyKey = UUID(); changes.append(change)
        change = poll; change.capabilityID = "fixture:other"; changes.append(change)
        change = poll; change.capabilityDigest = String(repeating: "a", count: 64); changes.append(change)
        change = poll; change.targetRuntimeID = "runtime:" + String(repeating: "a", count: 64); changes.append(change)
        change = poll; change.targetDeviceID = "device:" + String(repeating: "a", count: 64); changes.append(change)
        change = poll; change.arguments = ["confirmed": "true"]; changes.append(change)
        change = poll; change.item = "altered"; changes.append(change)
        for changed in changes {
            XCTAssertThrowsError(try fixture.handle(changed))
        }
        XCTAssertEqual(fixture.provider.effects, 1)
        XCTAssertEqual(try fixture.handle(poll).summary.executionLifecycle?.terminal, false)
    }

    @MainActor func testAnotherAuthorizedCallerCannotObserveOriginalCallersLiveExecution() async throws {
        let fixture = try LifecycleAdversarialFixture()
        let run = try fixture.run(), started = try fixture.handle(run)
        let id = try XCTUnwrap(started.summary.executionLifecycle?.executionID)
        let outsider = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 23, count: 32)))
        let outsiderGrant = try RemoteCallerGrant(publicKey: outsider.publicKey, operations: [.status],
            capabilityIDs: [fixture.provider.capability.id])
        let dispatcher = try RemoteExecutionDispatcher(engine: fixture.engine, identity: fixture.node,
            ledger: fixture.ledger, grants: [outsiderGrant], enabled: true, now: { 1_000 })
        var poll = fixture.client.makeStatusRequest(for: run, executionID: id)
        poll.callerID = RemoteWire.digest(outsider.publicKey)
        let bytes = try SignedRemoteMessage.request(poll, signer: outsider)
        XCTAssertThrowsError(try dispatcher.handle(bytes)) { XCTAssertEqual($0 as? RemoteLinkError, .unauthorized) }
        XCTAssertEqual(fixture.provider.effects, 1)
    }

    @MainActor func testRepeatedPollRequestAndNonceCannotBeReused() async throws {
        let fixture = try LifecycleAdversarialFixture()
        let run = try fixture.run(), started = try fixture.handle(run)
        let id = try XCTUnwrap(started.summary.executionLifecycle?.executionID)
        let first = fixture.client.makeStatusRequest(for: run, executionID: id)
        _ = try fixture.handle(first)
        XCTAssertThrowsError(try fixture.handle(first)) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        var nonceReuse = fixture.client.makeStatusRequest(for: run, executionID: id); nonceReuse.nonce = first.nonce
        XCTAssertThrowsError(try fixture.handle(nonceReuse)) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        var requestReuse = fixture.client.makeStatusRequest(for: run, executionID: id); requestReuse.requestID = first.requestID
        XCTAssertThrowsError(try fixture.handle(requestReuse)) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        XCTAssertEqual(fixture.provider.effects, 1)
    }

    @MainActor func testRunAndPollCannotReuseEachOthersEnvelopeIdentities() async throws {
        let fixture = try LifecycleAdversarialFixture()
        let run = try fixture.run(), started = try fixture.handle(run)
        let id = try XCTUnwrap(started.summary.executionLifecycle?.executionID)
        var pollNonce = fixture.client.makeStatusRequest(for: run, executionID: id); pollNonce.nonce = run.nonce
        XCTAssertThrowsError(try fixture.handle(pollNonce)) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        var pollID = fixture.client.makeStatusRequest(for: run, executionID: id); pollID.requestID = run.requestID
        XCTAssertThrowsError(try fixture.handle(pollID)) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        let freshPoll = fixture.client.makeStatusRequest(for: run, executionID: id)
        _ = try fixture.handle(freshPoll)
        var retryNonce = try fixture.run(key: run.idempotencyKey); retryNonce.nonce = freshPoll.nonce
        XCTAssertThrowsError(try fixture.handle(retryNonce)) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        var retryID = try fixture.run(key: run.idempotencyKey); retryID.requestID = freshPoll.requestID
        XCTAssertThrowsError(try fixture.handle(retryID)) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        XCTAssertEqual(fixture.provider.effects, 1)
    }

    @MainActor func testStatusGrantIsNotImplicitlyBroadenedFromRunGrant() async throws {
        let fixture = try LifecycleAdversarialFixture(statusAllowed: false)
        let run = try fixture.run(), started = try fixture.handle(run)
        let id = try XCTUnwrap(started.summary.executionLifecycle?.executionID)
        XCTAssertThrowsError(try fixture.handle(fixture.client.makeStatusRequest(for: run, executionID: id))) {
            XCTAssertEqual($0 as? RemoteLinkError, .unauthorized)
        }
        XCTAssertEqual(fixture.provider.effects, 1)
    }

    @MainActor func testDisconnectThenReconnectAndFreshSameIntentRetryHasExactlyOneEffect() async throws {
        let fixture = try LifecycleAdversarialFixture(); try await fixture.connect()
        let key = UUID(), run = try fixture.run(key: key)
        let started = try await fixture.client.send(run)
        let id = try XCTUnwrap(started.summary.executionLifecycle?.executionID)
        await fixture.relay.disconnect(runtimeID: fixture.node.runtimeID)
        do { _ = try await fixture.client.send(fixture.client.makeStatusRequest(for: run, executionID: id)); XCTFail("Disconnected transport returned status") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .unavailable) }
        try fixture.provider.emit(.working)
        try fixture.provider.emit(.completed(.string(fixture.provider.sentinel)))
        try await fixture.connect()
        let recovered = try await fixture.client.send(fixture.run(key: key))
        XCTAssertTrue(recovered.reused)
        XCTAssertEqual(recovered.summary.executionLifecycle?.terminal, true)
        XCTAssertEqual(recovered.summary.verification, .unverified)
        XCTAssertNil(recovered.summary.result, "Default export policy must redact provider values")
        XCTAssertFalse(String(decoding: try RemoteWire.encode(recovered), as: UTF8.self).contains(fixture.provider.sentinel))
        let terminal = try await fixture.client.send(fixture.client.makeStatusRequest(for: run, executionID: id))
        XCTAssertEqual(terminal.summary.executionLifecycle?.terminal, true)
        XCTAssertEqual(terminal.summary.eventPage?.events.map(\.kind), ["accepted", "working", "completed"])
        for event in terminal.summary.eventPage?.events ?? [] {
            XCTAssertEqual(try event.value.canonicalData(), try CapabilityValue.null.canonicalData())
        }
        XCTAssertEqual(fixture.provider.effects, 1)
    }

    @MainActor func testLostLiveOwnershipAfterDispatcherRestartBecomesUnknownWithoutRedispatch() async throws {
        let fixture = try LifecycleAdversarialFixture()
        let run = try fixture.run(), started = try fixture.handle(run)
        let id = try XCTUnwrap(started.summary.executionLifecycle?.executionID)
        let grant = try RemoteCallerGrant(publicKey: fixture.caller.publicKey, operations: [.run, .status],
            capabilityIDs: [fixture.provider.capability.id])
        let restarted = try RemoteExecutionDispatcher(engine: fixture.engine, identity: fixture.node,
            ledger: fixture.ledger, grants: [grant], enabled: true, now: { 1_000 })
        let poll = fixture.client.makeStatusRequest(for: run, executionID: id)
        let bytes = try SignedRemoteMessage.request(poll, signer: fixture.caller)
        let unknown = try SignedRemoteMessage.verifiedResult(restarted.handle(bytes), for: bytes, trustedRuntimeKey: fixture.node.publicKey)
        XCTAssertEqual(unknown.summary.state, .unknown)
        XCTAssertEqual(unknown.summary.executionLifecycle?.terminal, true)
        XCTAssertEqual(unknown.summary.verification, .unverified)
        let retry = try fixture.run(key: run.idempotencyKey)
        let retryBytes = try SignedRemoteMessage.request(retry, signer: fixture.caller)
        let retained = try SignedRemoteMessage.verifiedResult(restarted.handle(retryBytes), for: retryBytes, trustedRuntimeKey: fixture.node.publicKey)
        XCTAssertTrue(retained.reused)
        XCTAssertEqual(retained.summary.state, .unknown)
        XCTAssertEqual(fixture.provider.effects, 1)
    }

    @MainActor func testProviderInputRequiredIsLiveAndCannotBecomeConfirmationBypass() async throws {
        let fixture = try LifecycleAdversarialFixture()
        let run = try fixture.run(), initial = try fixture.handle(run)
        let id = try XCTUnwrap(initial.summary.executionLifecycle?.executionID)
        try fixture.provider.emit(.working)
        try fixture.provider.emit(.inputRequired)
        let input = try fixture.handle(fixture.client.makeStatusRequest(for: run, executionID: id))
        XCTAssertEqual(input.summary.state, .awaitingUser)
        XCTAssertEqual(input.summary.policy, .evaluated, "Provider input is distinct from host policy confirmation")
        XCTAssertEqual(input.summary.providerAcceptance, .accepted)
        XCTAssertEqual(input.summary.executionLifecycle?.phase, .inputRequired)
        XCTAssertEqual(input.summary.executionLifecycle?.terminal, false)
        XCTAssertThrowsError(try fixture.provider.emit(.completed(.string("not-yet-resumed"))))
        try fixture.provider.emit(.working)
        try fixture.provider.emit(.completed(.string("resumed")))
        let terminal = try fixture.handle(fixture.client.makeStatusRequest(for: run, executionID: id))
        XCTAssertEqual(terminal.summary.executionLifecycle?.terminal, true)
        XCTAssertEqual(terminal.summary.providerAcceptance, .accepted)
        XCTAssertEqual(terminal.summary.verification, .unverified)
        XCTAssertEqual(fixture.provider.effects, 1)
    }
}
