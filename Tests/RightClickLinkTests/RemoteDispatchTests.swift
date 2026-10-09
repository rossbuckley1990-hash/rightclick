import Foundation
import XCTest
import RightClickCore
@testable import RightClickLink
@testable import RightClickMCP

final class RemoteDispatchTests: XCTestCase {
    @MainActor func testAuthenticatedExecutionUsesExistingEngineAndIndependentObservation() async throws {
        let f = try LinkFixture(); try await f.connect()
        let request = try f.request(); let result = try await f.client.send(request)
        XCTAssertEqual(result.summary.state, .succeeded)
        XCTAssertEqual(result.summary.verification, .verifiedSuccess)
        XCTAssertEqual(result.summary.observationBoundary, .externalState)
        XCTAssertEqual(f.provider.effects, 1); XCTAssertEqual(f.provider.observations, 1); XCTAssertEqual(f.provider.credentialReads, 1)
        let id = try XCTUnwrap(result.summary.evidenceExecutionID)
        XCTAssertEqual(f.engine.executionStatus(id).state, .succeeded)
        let wire = try f.dispatcher.handle(f.bytes(f.client.makeRequest(operation: .actions, item: "desired")))
        XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains(LinkMockReflector.sentinel))
        let payload = try RemoteWire.decode(SignedRemoteMessage.self, try SignedRemoteMessage.seal(result, domain: RemoteWire.resultDomain, signer: f.identity), maximum: RemoteWire.maximumWireBytes).payload
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains(LinkMockReflector.sentinel))
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("Provider response"))
        print("LINK DEMO: caller -> outbound relay -> existing engine -> local credential resolution -> provider acceptance -> independent state observation -> signed VERIFIED; effects=1")
    }
    @MainActor func testSameIdempotencyIntentReturnsPriorResultWithoutAnotherEffect() async throws {
        let f = try LinkFixture(); try await f.connect(); let key = UUID()
        let first = try await f.client.send(f.request(key: key))
        let retry = try await f.client.send(f.request(key: key))
        XCTAssertFalse(first.reused); XCTAssertTrue(retry.reused)
        XCTAssertEqual(first.summary.evidenceExecutionID, retry.summary.evidenceExecutionID)
        XCTAssertEqual(f.provider.effects, 1)
        print("LINK DEMO: fresh authenticated retry, same idempotency key -> reused VERIFIED; effects=1")
    }
    @MainActor func testCompletedRequestReplayAndNonceReuseAreRejected() async throws {
        let f = try LinkFixture(); let request = try f.request(); _ = try f.dispatcher.handle(f.bytes(request))
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(request))) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        var duplicate = try f.request(); duplicate.nonce = request.nonce
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(duplicate))) { XCTAssertEqual($0 as? RemoteLinkError, .replay) }
        XCTAssertEqual(f.provider.effects, 1)
    }
    @MainActor func testInvalidAuthenticationTamperingAndWrongTargetDoNotExecute() async throws {
        let f = try LinkFixture(); let request = try f.request()
        var envelope = try RemoteWire.decode(SignedRemoteMessage.self, f.bytes(request), maximum: RemoteWire.maximumWireBytes)
        var changed = request; changed.item = "substituted"
        envelope.payload = try RemoteWire.encode(changed)
        XCTAssertThrowsError(try f.dispatcher.handle(RemoteWire.encode(envelope))) { XCTAssertEqual($0 as? RemoteLinkError, .unauthenticated) }
        changed = request; changed.targetRuntimeID = "runtime:" + String(repeating: "a", count: 64)
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(changed))) { XCTAssertEqual($0 as? RemoteLinkError, .wrongRuntime) }
        changed = request; changed.targetDeviceID = "device:" + String(repeating: "a", count: 64)
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(changed))) { XCTAssertEqual($0 as? RemoteLinkError, .wrongRuntime) }
        XCTAssertEqual(f.provider.effects, 0)
    }
    @MainActor func testExpiryVersionMalformedAndUnsupportedOperationFailClosed() async throws {
        let f = try LinkFixture(); let request = try f.request()
        var bad = request; bad.expiresAtMilliseconds = 999
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(bad))) { XCTAssertEqual($0 as? RemoteLinkError, .expired) }
        bad = request; bad.version = 2
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(bad))) { XCTAssertEqual($0 as? RemoteLinkError, .unsupportedVersion) }
        bad = request; bad.operation = .providers
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(bad))) { XCTAssertEqual($0 as? RemoteLinkError, .unsupportedOperation) }
        bad = request; bad.nonce = Data()
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(bad)))
        XCTAssertThrowsError(try f.dispatcher.handle(Data("{malformed".utf8)))
        XCTAssertEqual(f.provider.effects, 0)
    }
    @MainActor func testUnknownCapabilityAndCapabilitySubstitutionFailClosed() async throws {
        let f = try LinkFixture(); var request = try f.request(); request.capabilityID = "fixture:missing"
        let result = try SignedRemoteMessage.verifiedResult(f.dispatcher.handle(f.bytes(request)), for: f.bytes(request), trustedRuntimeKey: f.identity.publicKey)
        XCTAssertEqual(result.summary.state, .unavailable); XCTAssertEqual(result.summary.providerAcceptance, .notInvoked)
        request = try f.request(); request.capabilityDigest = String(repeating: "a", count: 64)
        _ = try f.dispatcher.handle(f.bytes(request)); XCTAssertEqual(f.provider.effects, 0)
    }
    @MainActor func testChangedIntentWithSameIdempotencyKeyIsRejected() async throws {
        let f = try LinkFixture(); let key = UUID(); _ = try f.dispatcher.handle(f.bytes(f.request(key: key)))
        var changed = try f.request(key: key); changed.arguments = ["payload":"different"]
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(changed))) { XCTAssertEqual($0 as? RemoteLinkError, .idempotencyConflict) }
        XCTAssertEqual(f.provider.effects, 1)
    }
    @MainActor func testConfirmationDefaultPreservedAndOnlyExactHostTicketCanApprove() async throws {
        let f = try LinkFixture(); f.provider.declaration.requiresConfirmation = true
        var request = try f.request(); var bytes = try f.bytes(request)
        let pending = try SignedRemoteMessage.verifiedResult(f.dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: f.identity.publicKey)
        XCTAssertEqual(pending.summary.state, .awaitingUser); XCTAssertEqual(f.provider.effects, 0)
        f.approval.ticket = try .init(approvedRequest: request, capabilityDigest: request.capabilityDigest!)
        request = try f.request(); bytes = try f.bytes(request)
        let substituted = try SignedRemoteMessage.verifiedResult(f.dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: f.identity.publicKey)
        XCTAssertEqual(substituted.summary.state, .awaitingUser); XCTAssertEqual(f.provider.effects, 0)
        request = try f.request(); f.approval.ticket = try .init(approvedRequest: request, capabilityDigest: request.capabilityDigest!)
        bytes = try f.bytes(request)
        let approved = try SignedRemoteMessage.verifiedResult(f.dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: f.identity.publicKey)
        XCTAssertEqual(approved.summary.state, .succeeded); XCTAssertEqual(f.provider.effects, 1)
    }
    @MainActor func testAcceptanceMissingObservationMismatchAndContradictionStayDistinct() async throws {
        let f = try LinkFixture(); try await f.connect()
        let accepted = try await f.client.send(f.request(verification: false))
        XCTAssertEqual(accepted.summary.state, .accepted); XCTAssertEqual(accepted.summary.verification, .unverified)
        f.provider.observerAvailable = false
        let missing = try await f.client.send(f.request())
        XCTAssertEqual(missing.summary.state, .accepted); XCTAssertEqual(missing.summary.verification, .unverified)
        f.provider.observerAvailable = true; f.provider.changeState = false; f.provider.state = "unchanged"
        let mismatch = try await f.client.send(f.request())
        XCTAssertEqual(mismatch.summary.state, .failed); XCTAssertEqual(mismatch.summary.providerAcceptance, .accepted)
        XCTAssertEqual(mismatch.summary.verification, .verifiedFailure)
        f.provider.contradictory = true
        let contradiction = try await f.client.send(f.request())
        XCTAssertEqual(contradiction.summary.state, .accepted); XCTAssertEqual(contradiction.summary.verification, .unverified)
    }
    @MainActor func testContractChangeInsideEngineAdmissionPreventsInvocation() async throws {
        let f = try LinkFixture(); let request = try f.request(); let count = f.provider.discoveryCount
        f.provider.onDiscovery = { n in if n == count + 2 { f.provider.declaration.requiresConfirmation = true } }
        let bytes = try f.bytes(request)
        let result = try SignedRemoteMessage.verifiedResult(f.dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: f.identity.publicKey)
        XCTAssertEqual(result.summary.state, .unavailable); XCTAssertEqual(f.provider.effects, 0)
    }
    @MainActor func testCanonicallyEquivalentUnicodeContractSubstitutionCannotDispatch() async throws {
        let f = try LinkFixture(); f.provider.declaration.metadata = ["endpoint": "https://fixture.invalid/caf\u{e9}"]
        let request = try f.request(); let count = f.provider.discoveryCount
        f.provider.onDiscovery = { n in
            if n == count + 2 { f.provider.declaration.metadata = ["endpoint": "https://fixture.invalid/cafe\u{301}"] }
        }
        let bytes = try f.bytes(request)
        let result = try SignedRemoteMessage.verifiedResult(f.dispatcher.handle(bytes), for: bytes, trustedRuntimeKey: f.identity.publicKey)
        XCTAssertEqual(result.summary.state, .unavailable); XCTAssertEqual(f.provider.effects, 0)
    }
    @MainActor func testLostResponseRetryAndThrownProviderCannotDoubleExecute() async throws {
        let f = try LinkFixture(); try await f.connect(); let key = UUID()
        await f.relay.loseNextResponse()
        do { _ = try await f.client.send(f.request(key: key)); XCTFail("Lost response became success") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .connectionLost) }
        let retry = try await f.client.send(f.request(key: key))
        XCTAssertTrue(retry.reused); XCTAssertEqual(f.provider.effects, 1)
        f.provider.throwAfterEffect = true; let ambiguous = UUID()
        let first = try await f.client.send(f.request(key: ambiguous))
        let second = try await f.client.send(f.request(key: ambiguous))
        XCTAssertEqual(first.summary.state, .unknown); XCTAssertTrue(second.reused); XCTAssertEqual(f.provider.effects, 2)
    }
    @MainActor func testOfflineAndDisabledNeverBecomeSuccessfulExecution() async throws {
        let disabled = try LinkFixture(enabled: false)
        XCTAssertThrowsError(try disabled.dispatcher.handle(disabled.bytes(disabled.request()))) { XCTAssertEqual($0 as? RemoteLinkError, .disabled) }
        do { try await disabled.connect(); XCTFail("Disabled link connected") } catch { XCTAssertEqual(error as? RemoteLinkError, .disabled) }
        let f = try LinkFixture()
        do { _ = try await f.client.send(f.request()); XCTFail("Offline execution became success") } catch { XCTAssertEqual(error as? RemoteLinkError, .unavailable) }
        XCTAssertEqual(f.provider.effects, 0); XCTAssertEqual(disabled.provider.effects, 0)
    }
    @MainActor func testIncompatibleHostAndRevokedGrantDoNotExecute() async throws {
        let f = try LinkFixture(); f.provider.declaration.runtimeRequirements = .init(operatingSystems: [.windows])
        let bytes = try f.bytes(f.request()); _ = try f.dispatcher.handle(bytes); XCTAssertEqual(f.provider.effects, 0)
        f.dispatcher.revoke(callerID: RemoteWire.digest(f.caller.publicKey))
        XCTAssertThrowsError(try f.dispatcher.handle(f.bytes(f.request()))) { XCTAssertEqual($0 as? RemoteLinkError, .unauthenticated) }
    }
    @MainActor func testLinuxMacGraphRoutesThroughExistingMCPAndEngine() async throws {
        let f = try LinkFixture(); try await f.connect()
        let registry = RemoteRuntimeRegistry(now: { 1_000 }); try await registry.enroll(f.client, item: "desired")
        let local = LinkMockReflector(); local.declaration.id = "fixture:linux-api"; local.declaration.title = "Portable fixture capability"; local.declaration.runtimeRequirements = .init(operatingSystems: [.linux])
        let cloud = CapabilityEngine(reflectors: [local], reflectorSources: [RemoteCapabilitySource(registry: registry)], experience: nil,
            runtimeEnvironment: .init(operatingSystem: .linux, architecture: "x86_64"))
        let capabilities = try cloud.capabilities(for: "desired").capabilities
        XCTAssertEqual(capabilities.count, 2)
        let routed = try XCTUnwrap(capabilities.first { $0.id.hasPrefix("remote:") })
        XCTAssertEqual(routed.runtimeRequirements?.operatingSystems, [.macOS])
        let box = EngineBox(cloud)
        let initial = try handleTool("context_run", arguments: ["item": .string("desired"), "actionId": .string(routed.id),
            "verification": .object(["predicates": .array([.object(["type": .string("text_equals"), "value": .string("desired")])])])], engine: box, transport: "stdio")
        let started = try JSONDecoder().decode(ExecutionRecord.self, from: Data(initial.utf8))
        var result = started
        for _ in 0..<200 where result.state == .started {
            try await Task.sleep(for: .milliseconds(5))
            let status = try handleTool("context_run_status", arguments: ["executionId": .string(started.executionId)], engine: box, transport: "stdio")
            result = try JSONDecoder().decode(ExecutionRecord.self, from: Data(status.utf8))
        }
        XCTAssertEqual(result.state, .succeeded); XCTAssertTrue(result.evidence.outcomeVerified)
        XCTAssertEqual(f.provider.effects, 1); XCTAssertEqual(local.effects, 0)
        let actions = try handleTool("context_actions", arguments: ["item": .string("desired")], engine: box, transport: "stdio")
        XCTAssertTrue(actions.contains("remote:"))
        registry.remove(runtimeID: f.identity.runtimeID)
        XCTAssertFalse(try cloud.capabilities(for: "desired").capabilities.contains { $0.id.hasPrefix("remote:") })
        print("FABRIC DEMO: synthetic Linux local API + enrolled Mac capability -> one graph -> existing generic MCP -> authenticated target -> independent VERIFIED; Mac effects=1, Linux effects=0")
    }
}
