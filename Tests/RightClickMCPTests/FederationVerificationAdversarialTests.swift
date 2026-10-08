import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickCore
@testable import RightClickMCP

final class FederationVerificationAdversarialTests: XCTestCase {
    private final class Peer: FederationPeerTransport {
        let taskID = UUID().uuidString
        var initialState: ExecutionState = .succeeded
        var initialEvidence = OutcomeEvidence()
        var initialVerification: OutcomeVerification?
        var finalEvidence = OutcomeEvidence()
        var finalVerification: OutcomeVerification?
        var runs = 0, polls = 0
        func runtime() throws -> RightClickRuntimeIdentity {
            .init(product: "RIGHTCLICK", version: "test", executablePath: "/fixture/node",
                  executableRealPath: "/fixture/node", executableSHA256: "fixture", pid: 1, transport: "http")
        }
        func actions(item: String) throws -> [CapabilityView] {
            [CapabilityView(Capability(id: "local:effect", title: "Mutation", source: .system,
                 reflectorID: "local", safety: .externalShare, invocation: .direct,
                 supportLevel: .publicSupported, requiresConfirmation: true))]
        }
        func run(item: String, actionID: String, arguments: CapabilityArguments?, verification: VerificationSpec?) throws -> ExecutionRecord {
            runs += 1
            return .init(executionId: taskID, actionId: actionID, state: initialState,
                         message: "Provider claimed success", evidence: initialEvidence,
                         verification: initialVerification)
        }
        func status(executionID: String) throws -> ExecutionRecord {
            polls += 1
            return .init(executionId: taskID, actionId: "local:effect", state: .succeeded,
                         message: "Provider claimed success", evidence: finalEvidence,
                         verification: finalVerification)
        }
    }
    private func engine(_ peer: Peer) -> CapabilityEngine {
        .init(reflectors: [FederatedPeerReflector(peer: .init(id: "peer", name: "Peer",
            endpoint: "http://127.0.0.1:9876/mcp", tokenEnvironment: "LOCAL_TOKEN"), transport: peer)], experience: nil)
    }
    private func begin(_ engine: CapabilityEngine, verification: VerificationSpec? = nil) throws -> ExecutionRecord {
        let capability = try XCTUnwrap(engine.capabilities(for: "mutation").capabilities.first)
        return try engine.begin(id: capability.id, item: "mutation", confirmed: true, verification: verification)
    }
    private let predicate = VerificationPredicate(type: .textEquals, value: "desired")
    private var spec: VerificationSpec { .init(predicates: [predicate]) }
    private var contradiction: OutcomeVerification {
        .init(status: .verifiedSuccess, predicates: [.init(predicate: predicate, evaluated: true,
            passed: false, actual: "unchanged", message: "Contradictory peer assertion")])
    }
    func testInitialProviderSuccessWithoutVerificationIsDowngraded() throws {
        let peer = Peer(), engine = engine(peer)
        let record = try begin(engine)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertFalse(record.evidence.outcomeVerified)
        XCTAssertEqual(peer.runs, 1)
    }
    func testInitialContradictoryPredicateCannotBeVerified() throws {
        let peer = Peer(), engine = engine(peer)
        peer.initialEvidence = .init(type: "node_claim", boundary: "Independent observation claimed",
            outcomeVerified: true, observationBoundary: .externalState)
        peer.initialVerification = contradiction
        let record = try begin(engine, verification: spec)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertFalse(record.evidence.outcomeVerified)
    }
    func testDeferredContradictoryPredicateCannotBeVerified() throws {
        let peer = Peer(), engine = engine(peer)
        peer.initialState = .started
        peer.finalEvidence = .init(type: "node_claim", boundary: "Independent observation claimed",
            outcomeVerified: true, observationBoundary: .externalState)
        peer.finalVerification = contradiction
        let initial = try begin(engine, verification: spec)
        let record = engine.executionStatus(initial.executionId)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertFalse(record.evidence.outcomeVerified)
        XCTAssertEqual(peer.runs, 1)
        XCTAssertEqual(peer.polls, 1)
    }
    func testInitialPassingPredicateForAnotherPostconditionCannotBeVerified() throws {
        let peer = Peer(), engine = engine(peer)
        peer.initialEvidence = .init(type: "node_claim", boundary: "Independent observation claimed",
            outcomeVerified: true, observationBoundary: .externalState)
        peer.initialVerification = .init(status: .verifiedSuccess, predicates: [.init(
            predicate: .init(type: .textEquals, value: "different"), evaluated: true,
            passed: true, actual: "different", message: "Verified a different predicate")])
        let record = try begin(engine, verification: spec)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertFalse(record.evidence.outcomeVerified)
    }
    func testDeferredPassingPredicateForAnotherPostconditionCannotBeVerified() throws {
        let peer = Peer(), engine = engine(peer)
        peer.initialState = .started
        peer.finalEvidence = .init(type: "node_claim", boundary: "Independent observation claimed",
            outcomeVerified: true, observationBoundary: .externalState)
        peer.finalVerification = .init(status: .verifiedSuccess, predicates: [.init(
            predicate: .init(type: .textEquals, value: "different"), evaluated: true,
            passed: true, actual: "different", message: "Verified a different predicate")])
        let initial = try begin(engine, verification: spec)
        let record = engine.executionStatus(initial.executionId)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertFalse(record.evidence.outcomeVerified)
        XCTAssertEqual(peer.runs, 1)
        XCTAssertEqual(peer.polls, 1)
    }
}
