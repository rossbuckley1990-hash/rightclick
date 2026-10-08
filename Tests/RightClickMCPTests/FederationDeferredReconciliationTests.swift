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
            reflectorID: "local", safety: .localReversible, invocation: .direct, requiresConfirmation: true))]
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
                    outcomeVerified: statusState == .succeeded, observationBoundary: .externalState))
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
