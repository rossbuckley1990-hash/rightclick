import Dispatch
import Foundation
import XCTest
import RightClickCore
@testable import RightClickLink

final class RemoteReplayLedgerTests: XCTestCase {
    private final class Fixture {
        let parent: URL
        let directory: URL
        let runtimeID = "runtime:" + String(repeating: "1", count: 64)

        init() throws {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("rightclick-ledger-test-" + UUID().uuidString)
                .standardizedFileURL.resolvingSymlinksInPath()
            directory = parent.appendingPathComponent("journal")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        }

        deinit { try? FileManager.default.removeItem(at: parent) }

        func open(maximumRequests: Int = 1024) throws -> RemoteReplayLedger {
            try RemoteReplayLedger(directory: directory, runtimeID: runtimeID, maximumRequests: maximumRequests)
        }

        func request(key: UUID = UUID(), now: Int64 = 1_000) -> RemoteExecutionRequest {
            RemoteExecutionRequest(idempotencyKey: key, issuedAtMilliseconds: now,
                expiresAtMilliseconds: now + 1_000, targetRuntimeID: runtimeID,
                targetDeviceID: "device:" + String(repeating: "2", count: 64),
                callerID: String(repeating: "3", count: 64),
                nonce: Data(UUID().uuidString.utf8.prefix(32)), operation: .run,
                capabilityID: "fixture:consequential", capabilityDigest: String(repeating: "4", count: 64),
                item: "perform once", arguments: ["payload": "original"])
        }

        func child(_ name: String) -> URL { directory.appendingPathComponent(name) }

        func anchor() throws -> URL {
            let names = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".rightclick-link-") && $0.pathExtension == "initialized" }
            return try XCTUnwrap(names.count == 1 ? names.first : nil)
        }

        func writePrivate(_ data: Data, to url: URL) throws {
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private final class Attempt: @unchecked Sendable {
        let ledger: RemoteReplayLedger
        let request: RemoteExecutionRequest
        init(_ ledger: RemoteReplayLedger, _ request: RemoteExecutionRequest) {
            self.ledger = ledger; self.request = request
        }
    }

    private final class RaceResults: @unchecked Sendable {
        private let lock = NSLock()
        private var winners = 0
        private var summaries: [RemoteExecutionSummary] = []
        private var errors: [RemoteLinkError] = []
        private var unexpectedErrors: [String] = []

        func record(_ result: RemoteExecutionSummary?) {
            lock.lock(); defer { lock.unlock() }
            if let result { summaries.append(result) } else { winners += 1 }
        }

        func record(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            if let error = error as? RemoteLinkError { errors.append(error) }
            else { unexpectedErrors.append(String(describing: error)) }
        }

        func snapshot() -> (Int, [RemoteExecutionSummary], [RemoteLinkError], [String]) {
            lock.lock(); defer { lock.unlock() }
            return (winners, summaries, errors, unexpectedErrors)
        }
    }

    private func acceptedSummary(at now: Int64 = 1_001) -> RemoteExecutionSummary {
        RemoteExecutionSummary(state: .accepted, policy: .evaluated, providerAcceptance: .accepted,
            evidenceExecutionID: UUID().uuidString,
            lifecycle: [.requested, .authorized, .delivered, .executing, .providerAccepted, .unverified],
            completedAtMilliseconds: now)
    }

    private func assertError<T>(_ expected: RemoteLinkError, _ body: @autoclosure () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? RemoteLinkError, expected, file: file, line: line)
        }
    }

    private func assertStorageDenied(_ fixture: Fixture, active: RemoteReplayLedger,
                                     file: StaticString = #filePath, line: UInt = #line) {
        assertError(.storageUnavailable, try active.reserve(fixture.request(), now: 1_001), file: file, line: line)
        assertError(.storageUnavailable, try fixture.open(), file: file, line: line)
    }

    func testPendingReservationSurvivesRestartAsUnknown() throws {
        let fixture = try Fixture(), key = UUID()
        var ledger: RemoteReplayLedger? = try fixture.open()
        XCTAssertNil(try ledger?.reserve(fixture.request(key: key), now: 1_000))
        ledger = nil
        let reopened = try fixture.open()
        let retry = try XCTUnwrap(reopened.reserve(fixture.request(key: key, now: 1_001), now: 1_001))
        XCTAssertEqual(retry.state, .unknown)
        XCTAssertEqual(retry.providerAcceptance, .unknown)
        XCTAssertEqual(retry.verification, .unverified)
        XCTAssertEqual(retry.error, .executionUncertain)
        XCTAssertEqual(retry.completedAtMilliseconds, 1_000)
        print("LEDGER EVIDENCE: durable reservation -> restart -> UNKNOWN; retry cannot win execution")
    }

    func testCompletedAcceptanceSurvivesRestartWithoutVerificationPromotion() throws {
        let fixture = try Fixture(), request = fixture.request(), summary = acceptedSummary()
        var ledger: RemoteReplayLedger? = try fixture.open()
        XCTAssertNil(try ledger?.reserve(request, now: 1_000))
        try ledger?.complete(request, summary: summary)
        ledger = nil
        let retry = try XCTUnwrap(fixture.open().reserve(fixture.request(key: request.idempotencyKey), now: 1_002))
        XCTAssertEqual(try RemoteWire.encode(retry), try RemoteWire.encode(summary))
        XCTAssertEqual(retry.state, .accepted)
        XCTAssertEqual(retry.verification, .unverified)
    }

    func testCompletedVerifiedEvidenceSurvivesRestartExactly() throws {
        let fixture = try Fixture(), request = fixture.request()
        let summary = RemoteExecutionSummary(state: .succeeded, policy: .evaluated, providerAcceptance: .accepted,
            verification: .verifiedSuccess, observationBoundary: .externalState, evidenceExecutionID: UUID().uuidString,
            lifecycle: [.requested, .authorized, .delivered, .executing, .providerAccepted, .verified],
            completedAtMilliseconds: 1_001)
        var ledger: RemoteReplayLedger? = try fixture.open()
        XCTAssertNil(try ledger?.reserve(request, now: 1_000))
        try ledger?.complete(request, summary: summary)
        ledger = nil
        let retry = try XCTUnwrap(fixture.open().reserve(fixture.request(key: request.idempotencyKey), now: 1_002))
        XCTAssertEqual(try RemoteWire.encode(retry), try RemoteWire.encode(summary))
        XCTAssertEqual(retry.evidenceExecutionID, summary.evidenceExecutionID)
        print("LEDGER EVIDENCE: completed VERIFIED -> restart -> exact cached evidence; no new execution winner")
    }

    func testCompletedRequestAndNonceReplayRemainRejectedAfterRestart() throws {
        let fixture = try Fixture(), request = fixture.request()
        var ledger: RemoteReplayLedger? = try fixture.open()
        XCTAssertNil(try ledger?.reserve(request, now: 1_000))
        try ledger?.complete(request, summary: acceptedSummary())
        ledger = nil
        let reopened = try fixture.open()
        assertError(.replay, try reopened.reserve(request, now: 1_001))
        var nonceReplay = fixture.request()
        nonceReplay.nonce = request.nonce
        assertError(.replay, try reopened.reserve(nonceReplay, now: 1_001))
        var identityReplay = fixture.request()
        identityReplay.requestID = request.requestID
        assertError(.replay, try reopened.reserve(identityReplay, now: 1_001))
    }

    func testChangedIntentWithSameIdempotencyKeyRemainsRejectedAfterRestart() throws {
        let fixture = try Fixture(), request = fixture.request()
        var ledger: RemoteReplayLedger? = try fixture.open()
        XCTAssertNil(try ledger?.reserve(request, now: 1_000))
        ledger = nil
        let reopened = try fixture.open()
        var changed = fixture.request(key: request.idempotencyKey)
        changed.arguments = ["payload": "substituted"]
        assertError(.idempotencyConflict, try reopened.reserve(changed, now: 1_001))
        changed = fixture.request(key: request.idempotencyKey)
        changed.capabilityID = "fixture:other"
        assertError(.idempotencyConflict, try reopened.reserve(changed, now: 1_001))
    }

    func testIndependentInstancesSimultaneousSameIdempotencyHaveExactlyOneWinner() throws {
        for iteration in 0..<16 {
            let fixture = try Fixture(), key = UUID()
            let first = try fixture.open(), second = try fixture.open()
            let attempts = [Attempt(first, fixture.request(key: key)), Attempt(second, fixture.request(key: key))]
            let results = RaceResults(), ready = DispatchSemaphore(value: 0), start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            for attempt in attempts {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    ready.signal(); start.wait()
                    do { results.record(try attempt.ledger.reserve(attempt.request, now: 1_000)) }
                    catch { results.record(error) }
                }
            }
            XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
            start.signal(); start.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
            let (winners, summaries, errors, unexpected) = results.snapshot()
            XCTAssertEqual(winners, 1, "Two independent instances admitted the same consequential intent; iteration \(iteration)")
            XCTAssertEqual(summaries.count + errors.count, 1)
            XCTAssertTrue(unexpected.isEmpty)
            XCTAssertTrue(errors.allSatisfy { $0 == .storageUnavailable })
            XCTAssertTrue(summaries.allSatisfy { $0.state == .unknown && $0.error == .executionUncertain })
            let retry = try XCTUnwrap(second.reserve(fixture.request(key: key), now: 1_001))
            XCTAssertEqual(retry.state, .unknown)
        }
        print("LEDGER EVIDENCE: 16 simultaneous independent-instance races; exactly one admission per intent")
    }

    func testClockRollbackFailsClosedBeforeAndAfterRestart() throws {
        let fixture = try Fixture(), key = UUID()
        var ledger: RemoteReplayLedger? = try fixture.open()
        XCTAssertNil(try ledger?.reserve(fixture.request(key: key, now: 2_000), now: 2_000))
        assertError(.clockRollback, try ledger!.reserve(fixture.request(now: 1_999), now: 1_999))
        ledger = nil
        let reopened = try fixture.open()
        assertError(.clockRollback, try reopened.reserve(fixture.request(now: 1_999), now: 1_999))
        XCTAssertEqual(try reopened.reserve(fixture.request(key: key, now: 2_001), now: 2_001)?.state, .unknown)
    }

    func testCapacityFailsClosedWithoutEvictingCompletedIntent() throws {
        let fixture = try Fixture(), request = fixture.request()
        var ledger: RemoteReplayLedger? = try fixture.open(maximumRequests: 2)
        XCTAssertNil(try ledger?.reserve(request, now: 1_000))
        let summary = acceptedSummary()
        try ledger?.complete(request, summary: summary)
        XCTAssertEqual(try RemoteWire.encode(ledger!.reserve(fixture.request(key: request.idempotencyKey), now: 1_001)),
            try RemoteWire.encode(Optional(summary)))
        assertError(.limitExceeded, try ledger!.reserve(fixture.request(), now: 1_002))
        assertError(.replay, try ledger!.reserve(request, now: 1_002))
        ledger = nil
        let reopened = try fixture.open(maximumRequests: 2)
        assertError(.limitExceeded, try reopened.reserve(fixture.request(), now: 1_003))
        assertError(.replay, try reopened.reserve(request, now: 1_003))
    }

    func testCorruptHistoryDeniesActiveAndRestartedLedger() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        XCTAssertNil(try ledger.reserve(fixture.request(), now: 1_000))
        try fixture.writePrivate(Data("{corrupt".utf8), to: fixture.child("link.json"))
        assertStorageDenied(fixture, active: ledger)
    }

    func testMissingHistoryDeniesActiveAndRestartedLedger() throws {
        let fixture = try Fixture(), ledger = try fixture.open(), request = fixture.request()
        XCTAssertNil(try ledger.reserve(request, now: 1_000))
        try ledger.complete(request, summary: acceptedSummary())
        try FileManager.default.removeItem(at: fixture.child("link.json"))
        assertStorageDenied(fixture, active: ledger)
    }

    func testOversizedHistoryDeniesActiveAndRestartedLedger() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        try fixture.writePrivate(Data(repeating: 32, count: 2_097_153), to: fixture.child("link.json"))
        assertStorageDenied(fixture, active: ledger)
    }

    func testInvalidPersistedVersionIdentityClockAndReplayShapeFailClosed() throws {
        for field in ["version", "runtimeID", "lastTime", "seen", "entries"] {
            let fixture = try Fixture(), ledger = try fixture.open()
            XCTAssertNil(try ledger.reserve(fixture.request(), now: 1_000))
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.child("link.json"))) as? [String: Any])
            switch field {
            case "version": document[field] = Int.max
            case "runtimeID": document[field] = "runtime:substituted"
            case "lastTime": document[field] = -1
            case "seen": document[field] = [String(repeating: "a", count: 64)]
            default: document[field] = ["invalid-digest": ["intentDigest": "invalid", "reservedAt": 1_000]]
            }
            try fixture.writePrivate(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), to: fixture.child("link.json"))
            assertStorageDenied(fixture, active: ledger)
        }
    }

    func testDeletedMarkerCannotResetReplayProtection() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        XCTAssertNil(try ledger.reserve(fixture.request(), now: 1_000))
        try FileManager.default.removeItem(at: fixture.child("link.initialized"))
        assertStorageDenied(fixture, active: ledger)
    }

    func testDeletedAnchorCannotResetReplayProtection() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        XCTAssertNil(try ledger.reserve(fixture.request(), now: 1_000))
        try FileManager.default.removeItem(at: fixture.anchor())
        assertStorageDenied(fixture, active: ledger)
    }

    func testDeletedJournalCannotBeProvisionedAgainUnderExistingAnchor() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        XCTAssertNil(try ledger.reserve(fixture.request(), now: 1_000))
        try FileManager.default.removeItem(at: fixture.directory)
        assertStorageDenied(fixture, active: ledger)
    }

    func testReplacedJournalIsNotTheAnchoredJournal() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        XCTAssertNil(try ledger.reserve(fixture.request(), now: 1_000))
        let moved = fixture.parent.appendingPathComponent("original-journal")
        try FileManager.default.moveItem(at: fixture.directory, to: moved)
        try FileManager.default.copyItem(at: moved, to: fixture.directory)
        assertStorageDenied(fixture, active: ledger)
    }

    func testReplacedLockCannotCreateASecondAdmissionDomain() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        XCTAssertNil(try ledger.reserve(fixture.request(), now: 1_000))
        try FileManager.default.moveItem(at: fixture.child("link.lock"), to: fixture.child("original.lock"))
        try fixture.writePrivate(Data(), to: fixture.child("link.lock"))
        assertStorageDenied(fixture, active: ledger)
    }

    func testSubstitutedMarkerAndAnchorFailClosed() throws {
        for name in ["marker", "anchor"] {
            let fixture = try Fixture(), ledger = try fixture.open()
            let target = try name == "marker" ? fixture.child("link.initialized") : fixture.anchor()
            try fixture.writePrivate(Data("substituted".utf8), to: target)
            assertStorageDenied(fixture, active: ledger)
        }
    }

    func testSymlinkHistoryMarkerLockAndAnchorAreDenied() throws {
        for name in ["link.json", "link.initialized", "link.lock", "anchor"] {
            let fixture = try Fixture(), ledger = try fixture.open()
            let target = try name == "anchor" ? fixture.anchor() : fixture.child(name)
            let outside = fixture.parent.appendingPathComponent("outside-" + UUID().uuidString)
            try fixture.writePrivate(Data(contentsOf: target), to: outside)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            assertStorageDenied(fixture, active: ledger)
        }
    }

    func testSymlinkJournalDoesNotWriteIntoDestination() throws {
        let fixture = try Fixture(), destination = fixture.parent.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: destination)
        assertError(.storageUnavailable, try fixture.open())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testPermissiveHistoryMarkerLockAndAnchorAreDenied() throws {
        for name in ["link.json", "link.initialized", "link.lock", "anchor"] {
            let fixture = try Fixture(), ledger = try fixture.open()
            let target = try name == "anchor" ? fixture.anchor() : fixture.child(name)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
            assertStorageDenied(fixture, active: ledger)
        }
    }

    func testPermissiveJournalIsDeniedBeforeAndAfterRestart() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
        assertStorageDenied(fixture, active: ledger)
    }

    func testNonStickyWorldWritableParentIsDeniedAtProvisioning() throws {
        let fixture = try Fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.parent.path)
        assertError(.storageUnavailable, try fixture.open())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testParentBecomingWorldWritableDeniesExistingAndRestartedLedger() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        XCTAssertNil(try ledger.reserve(fixture.request(), now: 1_000))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.parent.path)
        assertStorageDenied(fixture, active: ledger)
    }

    func testUnsafeAncestorCannotBeHiddenByPrivateImmediateParent() throws {
        let fixture = try Fixture(), middle = fixture.parent.appendingPathComponent("private-child")
        try FileManager.default.createDirectory(at: middle, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: middle.path)
        let nested = middle.appendingPathComponent("journal")
        let ledger = try RemoteReplayLedger(directory: nested, runtimeID: fixture.runtimeID)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.parent.path)
        assertError(.storageUnavailable, try ledger.reserve(fixture.request(), now: 1_000))
        assertError(.storageUnavailable, try RemoteReplayLedger(directory: nested, runtimeID: fixture.runtimeID))
    }

    func testUnsafeStagingFileCannotBeRemovedOrFollowed() throws {
        for symlink in [false, true] {
            let fixture = try Fixture(), ledger = try fixture.open()
            let staging = fixture.child("link.staging"), protected = fixture.parent.appendingPathComponent("protected")
            let marker = Data("DO-NOT-MODIFY".utf8)
            try fixture.writePrivate(marker, to: protected)
            if symlink {
                try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: protected)
            } else {
                try fixture.writePrivate(marker, to: staging)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staging.path)
            }
            assertError(.storageUnavailable, try ledger.reserve(fixture.request(), now: 1_000))
            let reopened = try fixture.open()
            assertError(.storageUnavailable, try reopened.reserve(fixture.request(), now: 1_001))
            XCTAssertEqual(try Data(contentsOf: protected), marker)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        }
    }

    func testHardLinkedHistoryMarkerLockAndAnchorAreDenied() throws {
        for name in ["link.json", "link.initialized", "link.lock", "anchor"] {
            let fixture = try Fixture(), ledger = try fixture.open()
            let target = try name == "anchor" ? fixture.anchor() : fixture.child(name)
            try FileManager.default.linkItem(at: target, to: fixture.parent.appendingPathComponent("extra-link"))
            assertStorageDenied(fixture, active: ledger)
        }
    }

    func testCompletionRequiresReservedMatchingIntentAndValidEvidence() throws {
        let fixture = try Fixture(), ledger = try fixture.open(), request = fixture.request()
        assertError(.storageUnavailable, try ledger.complete(request, summary: acceptedSummary()))
        XCTAssertNil(try ledger.reserve(request, now: 1_000))
        var changed = request
        changed.item = "substituted"
        assertError(.storageUnavailable, try ledger.complete(changed, summary: acceptedSummary()))
        assertError(.storageUnavailable, try ledger.complete(request, summary: acceptedSummary(at: 999)))
        var contradictory = acceptedSummary()
        contradictory.state = .succeeded
        assertError(.inconsistentResult, try ledger.complete(request, summary: contradictory))
        let summary = acceptedSummary()
        try ledger.complete(request, summary: summary)
        assertError(.storageUnavailable, try ledger.complete(request, summary: summary))
        XCTAssertEqual(try ledger.reserve(fixture.request(key: request.idempotencyKey), now: 1_002)?.state, .accepted)
    }
}
