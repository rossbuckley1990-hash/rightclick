import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders
@testable import RightClickCore

/// A host-owned maintenance path must not erase its own unexported provenance.
/// This is a lifecycle regression, not live external-provider acceptance proof.
final class RCIRReapedProvenanceTests: XCTestCase {
    private final class State { var effect = false }
    private struct Observer: RCIRObserver {
        let state: State
        let observerID = "host:reaped-provenance"
        func observe(_ request: RCIRObservationRequest) throws -> CapabilityValue {
            .boolean(state.effect)
        }
    }
    func testReapingCompletedDeferredSessionPreservesHostVerifiedStatus() throws {
        let state = State(), host = RCIRExecutionHost()
        host.configuration = { RCIRHostConfiguration() }; host.invocationJournal = { nil }
        let capability = Capability(id: "fixture:reaped-provenance", title: "Fixture effect", source: .system,
            reflectorID: "fixture:reaped-provenance", safety: .localReversible, invocation: .direct,
            supportLevel: .experimental, requiresConfirmation: false,
            metadata: ["executionMode": "deferred"])
        let abi = try capability.abiContract(arguments: .null, result: .boolean)
        let target = try XCTUnwrap(URL(string: "https://fixture.invalid/reaped-provenance"))
        let scope = RCIRScope(target.absoluteString, .execute)
        let lifecycle = RCIRDeferredLifecycle(initial: { _ in .completed(.boolean(true)) }, poll: { nil })
        let observer = Observer(state: state)
        let observation = RCIRHostObservation(contract: .init(observerID: observer.observerID,
            schema: .boolean, expected: .boolean(true)), observer: observer,
            boundary: "Separate fixture state observer")
        let item = try ContentParser.parse("effect")
        func begin(_ executionID: String) throws -> ExecutionRecord {
            try host.execute(abi: abi, discovery: abi, arguments: .null, scope: scope,
                capability: capability, executionID: executionID, argumentStrings: nil, item: item,
                verification: nil, expectedOutput: nil, target: target,
                authority: { [scope] }, revalidate: { true }, lifecycle: lifecycle,
                observerFactory: { _ in observation }, dispatch: { _, admit in
                    try admit { state.effect = true }
                    return .init(executionId: executionID, actionId: capability.id,
                        state: .started, message: "Fixture dispatch accepted")
                }, resultValue: { _ in .boolean(true) })
        }
        let firstID = UUID().uuidString, first = try begin(firstID)
        XCTAssertEqual(first.state, .succeeded)
        XCTAssertTrue(first.locallyAdmittedRCIR)
        ExecutionStore.shared.put(first)
        // Starting another deferred session invokes host maintenance and reaps
        // the terminal first session before reserving the second.
        _ = try begin(UUID().uuidString)
        let engine = CapabilityEngine(reflectors: [], experience: nil, rcirHost: host)
        let status = engine.executionStatus(firstID)
        XCTAssertEqual(status.state, .succeeded)
        XCTAssertTrue(status.evidence.outcomeVerified)
        XCTAssertTrue(status.locallyAdmittedRCIR)
    }
}
