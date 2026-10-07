import CryptoKit
import Foundation
import XCTest
@testable import RightClickCore

final class ExecutionRetentionTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func set(_ value: UInt64) { lock.lock(); self.value = value; lock.unlock() }
        func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    }
    private func record(_ id: String, state: ExecutionState = .succeeded, output: String? = nil) -> ExecutionRecord {
        ExecutionRecord(executionId: id, actionId: "controlled", state: state, message: "Controlled observation", output: output)
    }
    private func assertBounded(_ store: ExecutionStore, count: Int, bytes: Int, file: StaticString = #filePath, line: UInt = #line) {
        let statistics = store.statistics()
        XCTAssertLessThanOrEqual(statistics.records, count, file: file, line: line)
        XCTAssertLessThanOrEqual(statistics.encodedBytes, bytes, file: file, line: line)
        XCTAssertLessThanOrEqual(statistics.reservedBytes, bytes, file: file, line: line)
        XCTAssertGreaterThanOrEqual(statistics.reservedBytes, statistics.encodedBytes, file: file, line: line)
    }
    func testActualLargeEvidenceAndRecordFloodRespectIndependentBounds() throws {
        let store = ExecutionStore(maximumRecords: 10, maximumEncodedBytes: 32_768)
        let large = String(repeating: "observed-effect", count: 4_000)
        for index in 0..<100 {
            var value = record("large-\(index)", output: large)
            value.events = [large]
            value.evidence = OutcomeEvidence(type: "controlled", boundary: large, outcomeVerified: true)
            XCTAssertTrue(store.put(value))
            assertBounded(store, count: 10, bytes: 32_768)
        }
        XCTAssertNil(store.get("large-0"))
        let retained = try XCTUnwrap(store.get("large-99"))
        XCTAssertEqual(retained.state, .succeeded)
        XCTAssertFalse(retained.retention?.fullRecordRetained ?? true)
        XCTAssertNil(retained.output)
        XCTAssertFalse(retained.evidence.outcomeVerified)
        XCTAssertTrue(retained.message.contains("not retained"))
    }
    func testBytePressureEvictsOldestTerminalAndReadsNeverRefreshOrder() throws {
        let value = String(repeating: "x", count: 2_000)
        let size = try JSONEncoder().encode(record("a", output: value)).count
        let store = ExecutionStore(maximumRecords: 20, maximumEncodedBytes: size * 2)
        XCTAssertTrue(store.put(record("a", output: value)))
        XCTAssertTrue(store.put(record("b", output: value)))
        XCTAssertNotNil(store.get("a"))
        XCTAssertTrue(store.put(record("c", output: value)))
        XCTAssertNil(store.get("a")); XCTAssertNotNil(store.get("b")); XCTAssertNotNil(store.get("c"))
        assertBounded(store, count: 20, bytes: size * 2)
    }
    func testUpdateReaccountsLargeAndShrinkingOutputsAndCannotMoveIdentity() throws {
        let store = ExecutionStore(maximumRecords: 4, maximumEncodedBytes: 4_096)
        XCTAssertTrue(store.put(record("active", state: .started)))
        XCTAssertTrue(store.update("active") { value in
            value.executionId = "forged"; value.actionId = "different"
            value.output = String(repeating: "updated", count: 50_000)
            value.state = .awaitingUser
        })
        let compacted = try XCTUnwrap(store.get("active"))
        XCTAssertEqual(compacted.actionId, "controlled"); XCTAssertNil(store.get("forged"))
        XCTAssertEqual(compacted.state, .awaitingUser); XCTAssertNotNil(compacted.retention)
        XCTAssertEqual(store.statistics().activeRecords, 1)
        var callbackRan = false
        XCTAssertTrue(store.update("active") { value in
            callbackRan = true; value.output = "bounded terminal output"; value.state = .accepted
        })
        XCTAssertTrue(callbackRan); XCTAssertEqual(store.statistics().activeRecords, 0)
        XCTAssertEqual(store.get("active")?.output, "bounded terminal output")
        assertBounded(store, count: 4, bytes: 4_096)
    }
    func testStartedReservationsSurviveExpiryAndFloodThenReleaseAtTerminalCallback() {
        let clock = Clock()
        let store = ExecutionStore(maximumRecords: 2, maximumEncodedBytes: 4_096, timeToLiveNanoseconds: 10, clock: { clock.now() })
        XCTAssertTrue(store.put(record("first", state: .started)))
        XCTAssertTrue(store.put(record("second", state: .started)))
        XCTAssertFalse(store.put(record("capacity-refused", state: .started)))
        clock.set(1_000)
        for index in 0..<100 { XCTAssertFalse(store.put(record("history-\(index)"))) }
        XCTAssertTrue(store.update("first") { $0.state = .awaitingUser; $0.events = [String(repeating: "event", count: 20_000)] })
        XCTAssertEqual(store.get("first")?.state, .awaitingUser)
        XCTAssertEqual(store.statistics().activeRecords, 2)
        var released = false
        XCTAssertTrue(store.update("first") { $0.state = .accepted; released = true })
        XCTAssertTrue(released)
        XCTAssertTrue(store.put(record("next", state: .started)))
        XCTAssertNil(store.get("first")); XCTAssertNotNil(store.get("second")); XCTAssertNotNil(store.get("next"))
        assertBounded(store, count: 2, bytes: 4_096)
    }
    func testUnconfirmedAwaitingUserDoesNotReserveActiveCapacity() {
        let clock = Clock()
        let store = ExecutionStore(maximumRecords: 1, maximumEncodedBytes: 2_048, timeToLiveNanoseconds: 10, clock: { clock.now() })
        XCTAssertTrue(store.put(record("unconfirmed", state: .awaitingUser)))
        XCTAssertEqual(store.statistics().activeRecords, 0)
        clock.set(10)
        XCTAssertNil(store.get("unconfirmed"))
        XCTAssertTrue(store.put(record("started", state: .started)))
        XCTAssertEqual(store.statistics().activeRecords, 1)
    }
    func testByteCapacityRefusalPreservesEveryExistingActiveReservation() {
        let probe = ExecutionStore(maximumRecords: 2, maximumEncodedBytes: 4_096)
        XCTAssertTrue(probe.put(record("active", state: .started)))
        let reservationBytes = probe.statistics().reservedBytes
        let store = ExecutionStore(maximumRecords: 100, maximumEncodedBytes: reservationBytes)
        XCTAssertTrue(store.put(record("active", state: .started)))
        XCTAssertFalse(store.put(record("second", state: .started)))
        XCTAssertFalse(store.put(record("terminal")))
        XCTAssertNotNil(store.get("active"))
        XCTAssertTrue(store.update("active") { $0.state = .awaitingUser; $0.output = String(repeating: "huge", count: 40_000) })
        XCTAssertEqual(store.statistics().activeRecords, 1)
        assertBounded(store, count: 100, bytes: reservationBytes)
        XCTAssertFalse(ExecutionStore(maximumRecords: 0).put(record("disabled", state: .started)))
        XCTAssertFalse(ExecutionStore(maximumEncodedBytes: 0).put(record("disabled", state: .started)))
    }
    func testCompactedRCIRAcceptedTaskRetainsPendingOwnershipUntilTerminalSnapshot() throws {
        let clock = Clock()
        let store = ExecutionStore(maximumRecords: 1, maximumEncodedBytes: 2_048, timeToLiveNanoseconds: 10, clock: { clock.now() })
        XCTAssertTrue(store.put(record("async", state: .started)))
        var pending = record("async", state: .accepted)
        pending.rcir = RCIRExecutionEvidence(version: 1, taskID: "async", leaseID: "lease", generation: 1,
            leaseConsumed: true, phase: "working", outcome: "unverified", receipt: "", signedReceipt: nil,
            observationBoundary: String(repeating: "pending event", count: 10_000))
        XCTAssertTrue(store.put(pending))
        clock.set(100)
        let status = try XCTUnwrap(store.get("async"))
        XCTAssertEqual(status.retention?.taskPhase, "working")
        XCTAssertEqual(store.statistics().activeRecords, 1)
        XCTAssertFalse(store.put(record("other", state: .started)))
        var terminal = record("async", state: .accepted)
        terminal.rcir = RCIRExecutionEvidence(version: 1, taskID: "async", leaseID: "lease", generation: 1,
            leaseConsumed: true, phase: "completed", outcome: "unverified", receipt: "", signedReceipt: nil,
            observationBoundary: "Provider ACK only")
        XCTAssertTrue(store.put(terminal)); XCTAssertEqual(store.statistics().activeRecords, 0)
        clock.set(110); XCTAssertNil(store.get("async"))
    }
    func testMonotonicExpiryIgnoresRegressionAndUpdatesReadsDoNotExtendTTL() {
        let clock = Clock(); clock.set(100)
        let store = ExecutionStore(maximumRecords: 3, maximumEncodedBytes: 4_096, timeToLiveNanoseconds: 10, clock: { clock.now() })
        XCTAssertTrue(store.put(record("terminal")))
        clock.set(108); XCTAssertNotNil(store.get("terminal"))
        XCTAssertTrue(store.update("terminal") { $0.message = "Readback update" })
        clock.set(1); XCTAssertTrue(store.put(record("regression")))
        clock.set(110); XCTAssertNil(store.get("terminal")); XCTAssertNotNil(store.get("regression"))
        clock.set(118); XCTAssertNil(store.get("regression"))
        var called = false
        XCTAssertFalse(store.update("terminal") { _ in called = true }); XCTAssertFalse(called)
    }
    func testLargeActualSignedReceiptCompactionRetainsDigestWithoutInventingReceipt() throws {
        let challenge = String(repeating: "actual-observation", count: 20_000)
        let payload = Data(("RIGHTCLICK-RCIR-RECEIPT-1\0" + challenge).utf8)
        let signer = try RCIREd25519Signer(rawPrivateKey: Data(repeating: 7, count: 32))
        let signature = try signer.sign(payload)
        let signed = try RCIRSignedReceipt(payload: payload, signature: signature, publicKey: signer.publicKey)
        try signed.verify(trustedPublicKey: signer.publicKey, using: RCIREd25519Verifier())
        var full = record("receipt", output: challenge)
        full.rcir = RCIRExecutionEvidence(version: 1, taskID: "receipt", leaseID: "lease", generation: 1,
            leaseConsumed: true, phase: "completed", outcome: "unverified", receipt: payload.base64EncodedString(),
            signedReceipt: RCIRReceiptEnvelope(version: 1, algorithm: "Ed25519", payload: payload.base64EncodedString(),
                signature: signature.base64EncodedString(), publicKey: signer.publicKey.base64EncodedString()), observationBoundary: challenge)
        let store = ExecutionStore(maximumRecords: 1, maximumEncodedBytes: 2_048)
        XCTAssertTrue(store.put(full))
        let retained = try XCTUnwrap(store.get("receipt"))
        XCTAssertEqual(retained.retention?.receiptPayloadSHA256, SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(retained.rcir); XCTAssertNil(retained.verification); XCTAssertFalse(retained.evidence.outcomeVerified)
        // Retaining history never mutates the full first record returned by the
        // provider, including the authentic envelope available to its caller.
        XCTAssertEqual(full.rcir?.signedReceipt?.signature, signature.base64EncodedString())
        XCTAssertTrue(store.put(record("later"))); XCTAssertNil(store.get("receipt"))
        assertBounded(store, count: 1, bytes: 2_048)
    }
    func testConcurrentUpdatesKeepSynchronizedAccountingAndActiveCallbacks() {
        let store = ExecutionStore(maximumRecords: 12, maximumEncodedBytes: 32_768)
        for index in 0..<8 { XCTAssertTrue(store.put(record("active-\(index)", state: .started))) }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            _ = store.update("active-\(index % 8)") { $0.output = String(repeating: "parallel", count: index * 100) }
            _ = store.put(record("history-\(index)"))
            _ = store.get("active-\(index % 8)")
        }
        XCTAssertEqual(store.statistics().activeRecords, 8)
        for index in 0..<8 { XCTAssertTrue(store.update("active-\(index)") { $0.state = .cancelled }) }
        XCTAssertEqual(store.statistics().activeRecords, 0)
        assertBounded(store, count: 12, bytes: 32_768)
    }
}
