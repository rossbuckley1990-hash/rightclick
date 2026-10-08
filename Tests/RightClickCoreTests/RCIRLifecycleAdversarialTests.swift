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

    func testDeferredCompletionCannotSilentlyIgnoreAdmissionBoundTypedPostcondition() throws {
        for matches in [true, false] {
            let host = RCIRExecutionHost(), id = UUID().uuidString
            var stamp: Int64 = 101
            host.now = { stamp }; host.configuration = { RCIRHostConfiguration() }
            let capability = Capability(id: "fixture:typed-postcondition", title: "Deferred typed postcondition",
                source: .system, safety: .read, invocation: .direct, supportLevel: .experimental, requiresConfirmation: false)
            let abi = CapabilityContract(capabilityID: capability.id, reflectorID: "fixture:postcondition-owner",
                providerID: "fixture:postcondition-provider", arguments: .string,
                result: .object(properties: ["state": .string], required: ["state"]),
                declaration: .string("Admission-bound typed result fixture"))
            let scope = RCIRScope("urn:rightclick:adversarial:typed-postcondition", .execute)
            let specification = VerificationSpec(predicates: [.init(type: .resultPathEquals, key: "state", value: "wanted")])
            let initial = try host.execute(abi: abi, discovery: abi, arguments: .string("fixture"), scope: scope,
                taskModel: .init(shape: .deferred), capability: capability, executionID: id, argumentStrings: nil,
                item: ContentItem(kind: "text", display: "fixture", text: "fixture"),
                verification: specification, expectedOutput: nil, target: URL(string: "https://example.invalid/fixture")!,
                authority: { [scope] }, revalidate: { true }, currentContract: { true },
                dispatch: { _, start in
                    try start {}
                    return .init(executionId: id, actionId: capability.id, state: .started, message: "Live fixture")
                }, resultValue: { _ in throw RightClickError("A live provider has no terminal result") })
            XCTAssertEqual(initial.lifecycle?.terminal, false)
            stamp = 102
            try host.recordActiveTaskEvent(executionID: id, event: .accepted, now: stamp)
            stamp = 103
            try host.recordActiveTaskEvent(executionID: id,
                event: .completed(.object(["state": .string(matches ? "wanted" : "different")])), now: stamp)
            let deadline = Date().addingTimeInterval(3)
            while ExecutionStore.shared.get(id)?.lifecycle?.terminal != true && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let terminal = try XCTUnwrap(ExecutionStore.shared.get(id))
            XCTAssertEqual(terminal.lifecycle?.terminal, true, "Bounded asynchronous host adjudication must publish terminal evidence")
            XCTAssertEqual(terminal.verification?.status, matches ? .verifiedSuccess : .verifiedFailure)
            XCTAssertEqual(terminal.lifecycle?.verification, matches ? .verifiedSuccess : .verifiedFailure)
            XCTAssertEqual(terminal.lifecycle?.semanticOutcome, matches ? .succeeded : .failed)
            XCTAssertEqual(terminal.lifecycle?.observationBoundary, .returnedValue)
            XCTAssertEqual(terminal.evidence.observationBoundary, .returnedValue)
            XCTAssertEqual(terminal.lifecycle?.providerAcceptance, .accepted)
            XCTAssertEqual(terminal.rcir?.outcome, matches ? "succeeded" : "failed")
        }
    }

    func testPendingIndependentObserverDoesNotBlockCallbacksAndLateSuccessCannotReopenUnknown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-observer-gate-" + UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/rcir-observer-gate-test-provider.py").path,
            "--state-dir", directory.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        func awaitFile(_ name: String) throws {
            let deadline = Date().addingTimeInterval(3), file = directory.appendingPathComponent(name)
            while !FileManager.default.fileExists(atPath: file.path) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Bounded observer fixture did not produce \(name)")
            guard FileManager.default.fileExists(atPath: file.path) else { throw RightClickError("Observer gate fixture failed") }
        }
        try awaitFile("port")
        let port = try String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8)
        let base = "http://127.0.0.1:" + port
        let host = RCIRExecutionHost(), id = UUID().uuidString
        let capability = Capability(id: "fixture:gated-observer", title: "Gated independent observer", source: .system,
            safety: .read, invocation: .direct, supportLevel: .experimental, requiresConfirmation: false)
        let abi = CapabilityContract(capabilityID: capability.id, reflectorID: "fixture:gated-observer-owner",
            providerID: "fixture:gated-observer-provider", arguments: .string, result: .string,
            declaration: .string("Independent gated observer fixture"))
        let scope = RCIRScope("urn:rightclick:adversarial:gated-observer", .execute)
        host.configuration = {
            var config = RCIRHostConfiguration()
            config.observers = [capability.id: .init(urlTemplate: base + "/observe/{expected}", expectedArgument: "expected")]
            return config
        }
        let initial = try host.execute(abi: abi, discovery: abi, arguments: .string("fixture"), scope: scope,
            taskModel: .init(shape: .deferred), capability: capability, executionID: id,
            argumentStrings: ["expected": "wanted"], item: ContentItem(kind: "text", display: "fixture", text: "fixture"),
            verification: nil, expectedOutput: nil, target: URL(string: base + "/invoke")!, authority: { [scope] },
            revalidate: { true }, currentContract: { true }, dispatch: { _, start in
                try start {}
                return .init(executionId: id, actionId: capability.id, state: .started, message: "Live fixture")
            }, resultValue: { _ in throw RightClickError("Live task cannot demand terminal result") })
        XCTAssertEqual(initial.lifecycle?.terminal, false)
        func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
        try host.recordActiveTaskEvent(executionID: id, event: .accepted, now: now())
        try host.recordActiveTaskEvent(executionID: id, event: .working, now: now())
        let start = Date()
        try host.recordActiveTaskEvent(executionID: id, event: .completed(.string("provider response")), now: now())
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Provider callback blocked on the independent observer")
        try awaitFile("observer-started")
        let pending = try XCTUnwrap(host.activeExecutionStatus(executionID: id))
        XCTAssertEqual(pending.lifecycle?.terminal, false)
        XCTAssertEqual(pending.lifecycle?.receiptAvailable, false)
        XCTAssertNil(ExecutionStore.shared.get(id)?.rcir)

        // A second admitted provider callback can proceed while the first task's
        // observer is blocked. No host-wide active-task/admission lock is held.
        let otherID = UUID().uuidString
        let otherInitial = try host.execute(abi: abi, discovery: abi, arguments: .string("second"), scope: scope,
            taskModel: .init(shape: .deferred), capability: capability, executionID: otherID,
            argumentStrings: ["expected": "wanted"], item: ContentItem(kind: "text", display: "second", text: "second"),
            verification: nil, expectedOutput: nil, target: URL(string: base + "/invoke")!, authority: { [scope] },
            revalidate: { true }, currentContract: { true }, dispatch: { _, start in
                try start {}
                return .init(executionId: otherID, actionId: capability.id, state: .started, message: "Unrelated live fixture")
            }, resultValue: { _ in throw RightClickError("Live task cannot demand terminal result") })
        XCTAssertEqual(otherInitial.lifecycle?.terminal, false)
        let otherStart = Date()
        try host.recordActiveTaskEvent(executionID: otherID, event: .accepted, now: now())
        try host.recordActiveTaskEvent(executionID: otherID, event: .working, now: now())
        XCTAssertEqual(host.activeExecutionStatus(executionID: otherID)?.lifecycle?.phase, .working)
        XCTAssertLessThan(Date().timeIntervalSince(otherStart), 1, "Unrelated lifecycle blocked behind observer I/O")

        _ = try host.markActiveTaskUnknown(executionID: id, now: now())
        let unknown = try XCTUnwrap(ExecutionStore.shared.get(id))
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertEqual(unknown.lifecycle?.terminal, true)
        XCTAssertEqual(unknown.lifecycle?.verification, .unverified)
        XCTAssertNotNil(unknown.rcir?.receipt)
        XCTAssertEqual(unknown.rcirEvents?.map(\.kind), ["accepted", "working", "completed"])
        try Data().write(to: directory.appendingPathComponent("release"))
        try awaitFile("observer-finished")
        Thread.sleep(forTimeInterval: 0.15)
        let immutable = try XCTUnwrap(ExecutionStore.shared.get(id))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(immutable), try encoder.encode(unknown), "Late observer success reopened UNKNOWN")
        _ = try host.markActiveTaskUnknown(executionID: otherID, now: now())
    }
}
