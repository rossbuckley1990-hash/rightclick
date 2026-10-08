import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore
@testable import RightClickMCP

final class FederationDeferredReconciliationTests: XCTestCase {
    private final class Peer: FederationPeerTransport {
        var identity = RightClickRuntimeIdentity(product: "RIGHTCLICK", version: "test", executablePath: "/fixture/node",
            executableRealPath: "/fixture/node", executableSHA256: "original", pid: 1, transport: "http")
        var views = [CapabilityView(Capability(id: "remote:ordinary-local-id", title: "Local task", source: .system,
            reflectorID: "local", safety: .localReversible, invocation: .direct, supportLevel: .publicSupported, requiresConfirmation: true))]
        let remoteID = UUID().uuidString
        var runs = 0, polls = 0, loseRun = false, loseStatus = false
        var statusState: ExecutionState = .started
        func runtime() throws -> RightClickRuntimeIdentity { identity }
        func actions(item: String) throws -> [CapabilityView] { views }
        func run(item: String, actionID: String, arguments: CapabilityArguments?, verification: VerificationSpec?) throws -> ExecutionRecord {
            runs += 1
            if loseRun { throw RightClickError("Ambiguous reply") }
            return ExecutionRecord(executionId: remoteID, actionId: actionID, state: .started, message: "Deferred task")
        }
        func status(executionID: String) throws -> ExecutionRecord {
            polls += 1
            if loseStatus { loseStatus = false; throw RightClickError("Lost status reply") }
            return ExecutionRecord(executionId: remoteID, actionId: "remote:ordinary-local-id", state: statusState,
                message: "Node observation", evidence: OutcomeEvidence(type: "host_observation", boundary: "Independent readback",
                    outcomeVerified: statusState == .succeeded, observationBoundary: .externalState),
                verification: statusState == .succeeded ? OutcomeVerification(status: .verifiedSuccess,
                    predicates: [.init(predicate: .init(type: .fileExists), evaluated: true, passed: true, message: "Fixture peer readback")]) : nil)
        }
    }
    private func engine(_ peer: Peer) -> CapabilityEngine {
        let reflector = FederatedPeerReflector(peer: .init(id: "peer", name: "Peer", endpoint: "http://127.0.0.1:9876/mcp", tokenEnvironment: "LOCAL_TOKEN"), transport: peer)
        return CapabilityEngine(reflectors: [reflector], experience: nil)
    }
    private func begin(_ engine: CapabilityEngine) throws -> ExecutionRecord {
        let capability = try XCTUnwrap(engine.capabilities(for: "task").capabilities.first)
        return try engine.begin(id: capability.id, item: "task", confirmed: true)
    }
    private final class LocalCapability: CapabilityReflector {
        let id = "node-local"
        var title = "Original contract", effects = 0
        func capabilities(for item: ContentItem) throws -> [Capability] {
            [Capability(id: "local:mutation", title: title, source: .system, reflectorID: id,
                safety: .localReversible, invocation: .direct, supportLevel: .publicSupported, requiresConfirmation: true)]
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            effects += 1
            return ExecutionRecord(executionId: executionID, actionId: capability.id, state: .accepted, message: "effect")
        }
    }
    private final class AdmissionPeer: FederationPeerTransport {
        let provider = LocalCapability()
        lazy var node = CapabilityEngine(reflectors: [provider], experience: nil)
        var receivedPin: String?, replaceBeforeAdmission = true
        func runtime() throws -> RightClickRuntimeIdentity {
            .init(product: "RIGHTCLICK", version: "test", executablePath: "/fixture/node", executableRealPath: "/fixture/node",
                executableSHA256: "original", pid: 1, transport: "http")
        }
        func actions(item: String) throws -> [CapabilityView] { try node.capabilities(for: item).capabilities.map(CapabilityView.init) }
        func run(item: String, actionID: String, arguments: CapabilityArguments?, verification: VerificationSpec?) throws -> ExecutionRecord {
            XCTFail("A discovered admission pin must reach execution-node Core")
            throw RightClickError("Unpinned transport")
        }
        func run(item: String, actionID: String, arguments: CapabilityArguments?, verification: VerificationSpec?, expectedContractSHA256: String?) throws -> ExecutionRecord {
            receivedPin = expectedContractSHA256
            if replaceBeforeAdmission { provider.title = "Changed after caller discovery" }
            return try node.begin(id: actionID, item: item, confirmed: true, arguments: arguments,
                verification: verification, contractSHA256: expectedContractSHA256)
        }
    }
    func testFederationPinIsEnforcedByExecutionNodeAcrossDiscoveryAdmissionRace() throws {
        let peer = AdmissionPeer()
        let reflector = FederatedPeerReflector(peer: .init(id: "race", name: "Peer", endpoint: "http://127.0.0.1:9876/mcp", tokenEnvironment: "LOCAL_TOKEN"), transport: peer)
        let caller = CapabilityEngine(reflectors: [reflector], experience: nil)
        let action = try XCTUnwrap(caller.capabilities(for: "mutation").capabilities.first)
        let rejected = try caller.begin(id: action.id, item: "mutation", confirmed: true)
        XCTAssertNotNil(peer.receivedPin)
        XCTAssertEqual(rejected.state, .unavailable); XCTAssertEqual(peer.provider.effects, 0)
        peer.replaceBeforeAdmission = false
        let changed = try XCTUnwrap(caller.capabilities(for: "mutation").capabilities.first)
        XCTAssertEqual(try caller.begin(id: changed.id, item: "mutation", confirmed: true).state, .accepted)
        XCTAssertEqual(peer.provider.effects, 1)
    }

    func testOriginalTaskRefreshesWithoutAnotherRunAndRecoversLostStatus() throws {
        let peer = Peer(), engine = engine(peer), initial = try begin(engine)
        XCTAssertEqual(initial.state, .started)
        peer.loseStatus = true
        XCTAssertEqual(engine.executionStatus(initial.executionId).state, .unknown)
        peer.statusState = .succeeded
        let final = engine.executionStatus(initial.executionId)
        XCTAssertEqual(final.state, .succeeded); XCTAssertTrue(final.evidence.outcomeVerified)
        XCTAssertEqual(final.executionId, initial.executionId); XCTAssertEqual(peer.runs, 1); XCTAssertEqual(peer.polls, 2)
    }
    func testWithdrawnOrChangedContractCannotRefreshAnotherTask() throws {
        for change in 0..<3 {
            let peer = Peer(), engine = engine(peer), initial = try begin(engine)
            switch change {
            case 0: peer.views = []
            case 1: peer.views[0].contractSHA256 = String(repeating: "f", count: 64)
            default: peer.identity.pid += 1
            }
            XCTAssertEqual(engine.executionStatus(initial.executionId).state, .unknown)
            XCTAssertEqual(peer.polls, 0); XCTAssertEqual(peer.runs, 1)
            // Withdrawal cannot resurrect old ownership through another discovery.
            XCTAssertEqual(engine.executionStatus(initial.executionId).state, .unknown)
            XCTAssertEqual(peer.polls, 0)
        }
    }
    func testTypedLinkOrFederationCapabilitiesAreNotReexportedButLocalIDsSurvive() throws {
        let peer = Peer(), engine = engine(peer)
        XCTAssertEqual(try engine.capabilities(for: "task").capabilities.count, 1)
        peer.views[0].routingOrigin = .init(transport: "rightclick-link", executionRuntimeID: "other-node")
        XCTAssertTrue(try engine.capabilities(for: "task").capabilities.isEmpty)
        peer.views[0].routingOrigin = .init(transport: "federation", executionRuntimeID: "another-peer")
        XCTAssertTrue(try engine.capabilities(for: "task").capabilities.isEmpty)
    }
    func testLostRunReplyCannotBeInterpretedAsRejectionOrRetriedByStatus() throws {
        let peer = Peer(), engine = engine(peer); peer.loseRun = true
        let initial = try begin(engine)
        XCTAssertEqual(initial.state, .unknown)
        for _ in 0..<3 { XCTAssertEqual(engine.executionStatus(initial.executionId).state, .unknown) }
        XCTAssertEqual(peer.runs, 1); XCTAssertEqual(peer.polls, 0)
    }
    func testNodeUnknownIsTerminalAndCannotCauseRedispatch() throws {
        let peer = Peer(), engine = engine(peer), initial = try begin(engine)
        peer.statusState = .unknown
        XCTAssertEqual(engine.executionStatus(initial.executionId).state, .unknown)
        peer.statusState = .succeeded
        XCTAssertEqual(engine.executionStatus(initial.executionId).state, .unknown)
        XCTAssertEqual(peer.runs, 1); XCTAssertEqual(peer.polls, 1)
    }
}
