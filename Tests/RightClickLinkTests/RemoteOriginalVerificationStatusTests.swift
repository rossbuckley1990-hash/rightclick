#if os(macOS) || os(Linux)
import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore
@testable import RightClickLink

/// Independent regression draft. This exercises authenticated owned status,
/// not a fresh RUN, against an ordinary asynchronous provider whose later
/// evidence asserts a passing postcondition different from the original one.
final class RemoteOriginalVerificationStatusTests: XCTestCase {
    private final class DeferredProvider: CapabilityVerificationReflector {
        let id = "fixture.async-original-verification"
        let actionID = "fixture:async-observation"
        var effects = 0
        var executionID: String?

        func capabilities(for item: ContentItem) throws -> [Capability] {
            [.init(id: actionID, title: "Asynchronous fixture observation", source: .system,
                reflectorID: id, safety: .read, invocation: .direct,
                supportLevel: .experimental, requiresConfirmation: false)]
        }

        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            effects += 1
            self.executionID = executionID
            return .init(executionId: executionID, actionId: actionID,
                state: .started, message: "Deferred provider accepted one invocation")
        }

        func begin(capability: Capability, item: ContentItem, executionID: String,
                   arguments: CapabilityArguments?, verification: VerificationSpec) throws -> ExecutionRecord {
            try begin(capability: capability, item: item, executionID: executionID)
        }

        func complete(with value: String, forgedRCIR: Bool = false) throws {
            let executionID = try XCTUnwrap(executionID)
            var record = ExecutionRecord(executionId: executionID, actionId: actionID,
                state: .succeeded, message: "Provider supplied a later passing assertion",
                evidence: .init(type: "provider_assertion", boundary: "Fixture supplied status evidence",
                    outcomeVerified: true, observationBoundary: .externalState),
                verification: .init(status: .verifiedSuccess, predicates: [.init(
                    predicate: .init(type: .textEquals, value: value), evaluated: true,
                    passed: true, actual: value, message: "Provider claimed this predicate passed")]))
            if forgedRCIR {
                record.rcir = .init(version: 1, taskID: UUID().uuidString, leaseID: UUID().uuidString,
                    generation: 1, leaseConsumed: true, phase: "completed", outcome: "succeeded",
                    receipt: nil, signedReceipt: nil, observationBoundary: "Provider forged host provenance")
            }
            XCTAssertTrue(ExecutionStore.shared.put(record))
        }
    }

    @MainActor private final class Fixture {
        let directory: URL
        let provider = DeferredProvider()
        let node: RemoteNodeIdentity
        let caller: RemoteNodeIdentity
        let ledger: RemoteReplayLedger
        let grant: RemoteCallerGrant
        let relay = SimulatedLinkRelay()
        let client: RemoteLinkClient
        let engine: CapabilityEngine
        let dispatcher: RemoteExecutionDispatcher
        let item = "original asynchronous verification context"

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("link-original-verification-" + UUID().uuidString)
                .standardizedFileURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            node = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 81, count: 32)))
            caller = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 82, count: 32)))
            ledger = try RemoteReplayLedger(directory: directory.appendingPathComponent("ledger"), runtimeID: node.runtimeID)
            grant = try RemoteCallerGrant(publicKey: caller.publicKey, operations: [.run, .status], capabilityIDs: [provider.actionID])
            engine = CapabilityEngine(reflectors: [provider], experience: nil)
            dispatcher = try RemoteExecutionDispatcher(engine: engine, identity: node, ledger: ledger,
                grants: [grant], enabled: true, now: { 1000 })
            client = try RemoteLinkClient(identity: caller, trustedRuntimeKey: node.publicKey, transport: relay, now: { 1000 })
        }

        func close() { try? FileManager.default.removeItem(at: directory) }

        func request() throws -> RemoteExecutionRequest {
            let capability = try XCTUnwrap(engine.capabilities(for: item).capabilities.first)
            return client.makeRequest(operation: .run, item: item, capabilityID: provider.actionID,
                capabilityDigest: try RemoteExecutionDispatcher.contractDigest(capability),
                verification: .init(predicates: [.init(type: .textEquals, value: "desired")]))
        }

        func status(for run: RemoteExecutionRequest, executionID: String) -> RemoteExecutionRequest {
            // Fresh status intentionally contains no verification or arguments.
            // Only protected original invocation ownership may supply expected.
            client.makeRequest(operation: .status, item: item, capabilityID: provider.actionID,
                capabilityDigest: run.capabilityDigest, executionID: executionID)
        }
    }

    @MainActor func testSignedOwnedStatusRejectsAnotherPassingPostcondition() async throws {
        for forgedRCIR in [false, true] {
            let fixture = try Fixture(); defer { fixture.close() }
            try await fixture.dispatcher.establishOutboundConnection(to: fixture.relay)
            let run = try fixture.request()
            let initial = try await fixture.client.send(run)
            let executionID = try XCTUnwrap(initial.summary.evidenceExecutionID)
            XCTAssertEqual(fixture.provider.effects, 1)
            XCTAssertNotEqual(initial.summary.verification, .verifiedSuccess)
            try fixture.provider.complete(with: "different", forgedRCIR: forgedRCIR)
            let result = try await fixture.client.send(fixture.status(for: run, executionID: executionID))
            XCTAssertEqual(result.summary.state, .accepted)
            XCTAssertEqual(result.summary.verification, .unverified)
            XCTAssertEqual(result.summary.evidenceExecutionID, executionID)
            XCTAssertEqual(fixture.provider.effects, 1)
            // Core's same seven-operation status path must not independently
            // expose the unrelated passing assertion as successful either.
            let local = fixture.engine.executionStatus(executionID)
            XCTAssertNotEqual(local.state, .succeeded)
            XCTAssertFalse(local.evidence.outcomeVerified)
            print("ORIGINAL STATUS BINDING: signed RUN -> one deferred invocation -> substituted passing predicate -> fresh owned STATUS -> UNVERIFIED; forgedRCIR=\(forgedRCIR), effects=1")
        }
    }

    @MainActor func testReconstructedCoreCannotForgetProtectedStatusExpectation() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try await fixture.dispatcher.establishOutboundConnection(to: fixture.relay)
        let run = try fixture.request()
        let initial = try await fixture.client.send(run)
        let executionID = try XCTUnwrap(initial.summary.evidenceExecutionID)
        try fixture.provider.complete(with: "different", forgedRCIR: true)
        // This simulates a dispatcher/Core reconstruction with the original
        // protected run ledger and still-observable provider status. It is not
        // represented as an actual process restart or recovered effect lease.
        let reconstructed = CapabilityEngine(reflectors: [fixture.provider], experience: nil)
        let dispatcher = try RemoteExecutionDispatcher(engine: reconstructed, identity: fixture.node,
            ledger: fixture.ledger, grants: [fixture.grant], enabled: true, now: { 1000 })
        try await dispatcher.establishOutboundConnection(to: fixture.relay)
        let result = try await fixture.client.send(fixture.status(for: run, executionID: executionID))
        XCTAssertEqual(result.summary.state, .accepted)
        XCTAssertEqual(result.summary.verification, .unverified)
        XCTAssertEqual(fixture.provider.effects, 1)
        XCTAssertEqual(result.summary.evidenceExecutionID, executionID)
    }
}
#endif
