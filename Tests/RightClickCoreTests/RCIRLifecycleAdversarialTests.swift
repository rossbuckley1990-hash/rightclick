import Foundation
import XCTest
@testable import RightClickProtocol
@testable import RightClickProviders

private struct AdversarialUnavailableSigner: RCIRReceiptSigning {
    let publicKey = Data(repeating: 1, count: 32)
    func sign(_ payload: Data) throws -> Data { throw RCIRError.authorityDenied }
}

/// Attacks the portable retention boundary independently of any provider or OS.
final class RCIRLifecycleAdversarialTests: XCTestCase {
    private func event(_ sequence: Int64, value: CapabilityValue = .null) -> RCIRExecutionEvent {
        .init(sequence: sequence, time: 100 + sequence, kind: "working", value: value)
    }

    private func terminal(_ id: String, result: CapabilityValue = .integer(7)) -> ExecutionRecord {
        .init(executionId: id, actionId: "fixture:adversarial", state: .accepted,
            message: "Provider completion is unverified.", result: result,
            lifecycle: .init(executionID: id, originatingRequestID: id, taskID: UUID().uuidString,
                generation: 1, taskShape: .deferred, phase: .completed, semanticOutcome: .unverified,
                sequence: 1, terminal: true, providerAcceptance: .accepted, verification: .unverified,
                observationBoundary: .none, evidenceID: UUID().uuidString, receiptAvailable: true))
    }

    private func admittedTask(maxEvents: Int = 16, maxBytes: Int = 16_384,
                              cancellable: Bool = false) throws -> RCIRTask {
        let abi = CapabilityContract(capabilityID: "fixture:adversarial-deferred",
            reflectorID: "fixture:adversarial", providerID: "fixture:adversarial-provider",
            arguments: .object(properties: [:], required: []), result: .integer,
            declaration: .string("Portable adversarial task"))
        let contract = RCIRContract(abi: abi, scopes: [],
            task: .init(shape: .deferred, cancellable: cancellable, maxEvents: maxEvents, maxBytes: maxBytes))
        let admission = RCIRAdmission(), arguments = CapabilityValue.object([:])
        let binding = try admission.publish(contract, authenticatedPrincipal: "fixture:owner")
        let policy = RCIRPolicy(revision: "1", principals: ["fixture:owner"], scopes: [])
        let lease = try admission.issue(binding, arguments: arguments, authority: [], policy: policy, now: 100)
        try admission.consume(lease, arguments: arguments, authority: [], policy: policy, now: 101)
        return try RCIRTask(lease: lease, startedAt: 101, deadline: 1_000)
    }

    func testTerminalBeforeInitialRecordCannotBeReopenedOrLoseTypedResult() throws {
        let id = UUID().uuidString, store = ExecutionStore()
        let completed = terminal(id)
        try store.putTerminal(completed, events: [event(1, value: .integer(7))])
        store.put(.init(executionId: id, actionId: completed.actionId, title: "Late initial title",
            state: .started, message: "Initial response reached storage after callback."))
        store.update(id) { $0.state = .started; $0.result = nil; $0.lifecycle = nil }
        let retained = try XCTUnwrap(store.get(id))
        XCTAssertEqual(retained.state, .accepted)
        XCTAssertEqual(try retained.result?.canonicalData(), try CapabilityValue.integer(7).canonicalData())
        XCTAssertEqual(retained.lifecycle?.terminal, true)
        XCTAssertEqual(retained.title, "Late initial title")
        XCTAssertEqual(try store.rcirEventPage(executionId: id)?.events.count, 1)
    }

    func testSecondTerminalPublicationCannotSubstituteResultOrHistory() throws {
        let id = UUID().uuidString, store = ExecutionStore()
        let completed = terminal(id)
        try store.putTerminal(completed, events: [event(1, value: .integer(7))])
        var substitution = completed; substitution.result = .integer(8)
        XCTAssertThrowsError(try store.putTerminal(substitution, events: [event(1, value: .integer(8))]))
        XCTAssertThrowsError(try store.putRCIRHistory([event(1, value: .integer(8))], executionId: id))
        XCTAssertEqual(try store.get(id)?.result?.canonicalData(), try CapabilityValue.integer(7).canonicalData())
        XCTAssertEqual(try store.rcirEventPage(executionId: id)?.events.first?.value.canonicalData(), try CapabilityValue.integer(7).canonicalData())
    }

    func testRetainedHistoryRejectsSequenceReplayGapAndZero() throws {
        for history in [[event(0)], [event(2)], [event(1), event(1)], [event(1), event(3)]] {
            let id = UUID().uuidString, store = ExecutionStore()
            XCTAssertThrowsError(try store.putRCIRHistory(history, executionId: id))
            XCTAssertNil(try store.rcirEventPage(executionId: id))
        }
    }

    func testHistoryOverflowIsRejectedBeforeAnyPublication() throws {
        let store = ExecutionStore(), id = UUID().uuidString
        let history = (1...1_025).map { event(Int64($0)) }
        XCTAssertThrowsError(try store.putTerminal(terminal(id), events: history))
        XCTAssertNil(store.get(id))
        XCTAssertNil(try store.rcirEventPage(executionId: id))
    }

    func testHistoryByteOverflowIsRejectedBeforeAnyPublication() throws {
        let store = ExecutionStore(), id = UUID().uuidString
        let history = [event(1, value: .string(String(repeating: "x", count: 262_144)))]
        XCTAssertThrowsError(try store.putTerminal(terminal(id), events: history))
        XCTAssertNil(store.get(id))
        XCTAssertNil(try store.rcirEventPage(executionId: id))
    }

    func testNegativeAheadAndOverflowCursorsFailClosed() throws {
        let store = ExecutionStore(), id = UUID().uuidString
        try store.putRCIRHistory([event(1), event(2)], executionId: id)
        for cursor in [Int64.min, -1, 3, Int64.max] {
            XCTAssertThrowsError(try store.rcirEventPage(executionId: id, after: cursor))
        }
        for limit in [Int.min, 0, 257, Int.max] {
            XCTAssertThrowsError(try store.rcirEventPage(executionId: id, limit: limit))
        }
        for bytes in [Int.min, 0, 262_145, Int.max] {
            XCTAssertThrowsError(try store.rcirEventPage(executionId: id, maximumBytes: bytes))
        }
    }

    func testOldCursorRereadRetainsExactEventsAndTerminalityWithBacklog() throws {
        let store = ExecutionStore(), id = UUID().uuidString
        try store.putRCIRHistory([event(1), event(2), event(3)], executionId: id)
        let first = try XCTUnwrap(store.rcirEventPage(executionId: id, after: 0, limit: 1))
        let reread = try XCTUnwrap(store.rcirEventPage(executionId: id, after: 0, limit: 1))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(reread))
        XCTAssertEqual(first.events.map(\.sequence), [1])
        XCTAssertEqual(first.nextCursor, 1)
        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(first.terminal, "A terminal task remains terminal while its event history has unread pages")
        let rest = try XCTUnwrap(store.rcirEventPage(executionId: id, after: first.nextCursor))
        XCTAssertEqual(rest.events.map(\.sequence), [2, 3])
        XCTAssertFalse(rest.hasMore)
        XCTAssertTrue(rest.terminal)
    }

    func testInsufficientPageBytesDoesNotDropOrRenumberFirstEvent() throws {
        let store = ExecutionStore(), id = UUID().uuidString
        let history = [event(1, value: .string(String(repeating: "x", count: 512))), event(2)]
        try store.putRCIRHistory(history, executionId: id)
        XCTAssertThrowsError(try store.rcirEventPage(executionId: id, maximumBytes: 128))
        let page = try XCTUnwrap(store.rcirEventPage(executionId: id))
        XCTAssertEqual(page.events.map(\.sequence), [1, 2])
        XCTAssertEqual(try page.events.first?.value.canonicalData(), try history.first?.value.canonicalData())
    }

    func testHostOverflowBecomesUnknownAndPreservesAcceptedHistoryWithoutReopening() throws {
        let id = UUID().uuidString, host = RCIRExecutionHost()
        host.now = { 103 }
        try host.registerActiveTask(admittedTask(maxEvents: 1), executionID: id)
        XCTAssertNil(try host.recordActiveTaskEvent(executionID: id, event: .accepted, now: 102))
        XCTAssertThrowsError(try host.recordActiveTaskEvent(executionID: id, event: .working, now: 103))
        XCTAssertNil(try host.activeEventPage(executionID: id))
        let retained = try XCTUnwrap(ExecutionStore.shared.get(id))
        XCTAssertEqual(retained.state, .unknown)
        XCTAssertEqual(retained.lifecycle?.terminal, true)
        XCTAssertEqual(retained.lifecycle?.semanticOutcome, .unknown)
        XCTAssertEqual(retained.rcirEvents?.map(\.kind), ["accepted"])
        XCTAssertNotNil(retained.rcir?.receipt)
        XCTAssertThrowsError(try host.recordActiveTaskEvent(executionID: id, event: .completed(.integer(7)), now: 104))
        XCTAssertEqual(ExecutionStore.shared.get(id)?.state, .unknown)
    }

    func testHostDeadlineMakesUnknownReceiptAndCannotAcceptLateCompletion() throws {
        let id = UUID().uuidString, host = RCIRExecutionHost()
        host.now = { 1_000 }
        try host.registerActiveTask(admittedTask(), executionID: id)
        let status = try XCTUnwrap(host.activeExecutionStatus(executionID: id))
        XCTAssertEqual(status.state, .unknown)
        XCTAssertEqual(status.lifecycle?.terminal, true)
        XCTAssertNotNil(status.rcir?.receipt)
        XCTAssertNil(try host.activeEventPage(executionID: id))
        XCTAssertThrowsError(try host.recordActiveTaskEvent(executionID: id, event: .completed(.integer(7)), now: 1_001))
    }

    func testProviderFailureDoesNotErasePreviouslyRecordedAcceptance() throws {
        let id = UUID().uuidString, host = RCIRExecutionHost()
        host.now = { 103 }
        try host.registerActiveTask(admittedTask(), executionID: id)
        try host.recordActiveTaskEvent(executionID: id, event: .accepted, now: 102)
        try host.recordActiveTaskEvent(executionID: id, event: .failed, now: 103)
        let status = try XCTUnwrap(ExecutionStore.shared.get(id))
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.lifecycle?.providerAcceptance, .accepted)
        XCTAssertEqual(status.lifecycle?.verification, .unverified)
        XCTAssertEqual(status.lifecycle?.semanticOutcome, .unverified)
    }

    func testTerminalSigningFailureCannotLeaveAnOrphanedLiveTask() throws {
        let id = UUID().uuidString, host = RCIRExecutionHost()
        host.now = { 103 }
        try host.registerActiveTask(admittedTask(), executionID: id, signer: AdversarialUnavailableSigner())
        try host.recordActiveTaskEvent(executionID: id, event: .accepted, now: 102)
        _ = try? host.recordActiveTaskEvent(executionID: id, event: .completed(.integer(7)), now: 103)
        XCTAssertNil(try host.activeEventPage(executionID: id), "A completed provider must not remain registered as live because receipt signing failed")
        let status = try XCTUnwrap(ExecutionStore.shared.get(id), "Terminal bookkeeping failure must retain an immutable UNKNOWN record")
        XCTAssertEqual(status.state, .unknown)
        XCTAssertEqual(status.lifecycle?.terminal, true)
        XCTAssertEqual(status.lifecycle?.signedReceiptAvailable, false)
        XCTAssertNotNil(status.rcir?.receipt)
        XCTAssertEqual(status.rcirEvents?.map(\.kind), ["accepted", "completed"])
    }
}
