import Foundation
import XCTest
import RightClickCore
@testable import RightClickLink

/// Durable observation expiry must never erase executable replay history.
final class RemoteObservationAdversarialTests: XCTestCase {
    private final class Fixture {
        let parent: URL
        let directory: URL
        let runtimeID = "runtime:" + String(repeating: "1", count: 64)
        init() throws {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-observation-test-" + UUID().uuidString)
                .standardizedFileURL.resolvingSymlinksInPath()
            directory = parent.appendingPathComponent("journal")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        deinit { try? FileManager.default.removeItem(at: parent) }
        func open() throws -> RemoteReplayLedger { try .init(directory: directory, runtimeID: runtimeID, maximumRequests: 2) }
        func request(_ operation: RemoteOperation = .runtime, now: Int64 = 1_000) -> RemoteExecutionRequest {
            .init(issuedAtMilliseconds: now, expiresAtMilliseconds: now + 1_000, targetRuntimeID: runtimeID,
                targetDeviceID: "device:" + String(repeating: "2", count: 64), callerID: String(repeating: "3", count: 64),
                nonce: Data(UUID().uuidString.utf8.prefix(32)), operation: operation,
                capabilityID: operation == .run ? "fixture:consequential" : nil,
                capabilityDigest: operation == .run ? String(repeating: "4", count: 64) : nil, item: "")
        }
        func document() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("link.json"))) as? [String: Any])
        }
        func write(_ document: [String: Any]) throws {
            let path = directory.appendingPathComponent("link.json")
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        func key(_ domain: String, _ request: RemoteExecutionRequest, _ value: String) -> String {
            RemoteWire.digest(Data((domain + "\0" + runtimeID + "\0" + request.callerID + "\0" + value).utf8))
        }
    }

    private func error<T>(_ expected: RemoteLinkError, _ operation: @autoclosure () throws -> T,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { XCTAssertEqual($0 as? RemoteLinkError, expected, file: file, line: line) }
    }

    func testObservationWindowIsBoundedAndExpiresWithoutEvictingPermanentRunHistory() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        let first = fixture.request()
        try ledger.reserveObservation(first, now: 1_000)
        for _ in 1..<1_024 { try ledger.reserveObservation(fixture.request(), now: 1_000) }
        let full = try fixture.document()
        XCTAssertEqual((full["observations"] as? [String: Any])?.count, 2_048)
        error(.limitExceeded, try ledger.reserveObservation(fixture.request(), now: 1_000))
        error(.replay, try ledger.reserveObservation(first, now: 1_000))
        let run = fixture.request(.run)
        XCTAssertNil(try ledger.reserve(run, now: 1_000), "Full observational capacity must not consume executable capacity")
        let permanent = try XCTUnwrap(try fixture.document()["seen"] as? [String])
        let reopened = try fixture.open()
        error(.replay, try reopened.reserveObservation(first, now: 1_999))
        error(.limitExceeded, try reopened.reserveObservation(fixture.request(now: 1_999), now: 1_999))
        error(.expired, try reopened.reserveObservation(first, now: 2_000))
        try reopened.reserveObservation(fixture.request(now: 2_000), now: 2_000)
        let expired = try fixture.document()
        XCTAssertEqual((expired["observations"] as? [String: Any])?.count, 2)
        XCTAssertEqual(Set(try XCTUnwrap(expired["seen"] as? [String])), Set(permanent))
        error(.replay, try reopened.reserve(run, now: 2_000))
        let recovered = try reopened.reserve({ var retry = fixture.request(.run, now: 2_000); retry.idempotencyKey = run.idempotencyKey; return retry }(), now: 2_000)
        XCTAssertEqual(recovered?.state, .unknown, "Unresolved run survives observation expiry and cannot be re-executed")
    }

    func testObservationClockRollbackFailsBeforeAndAfterRestartWithoutChangingHistory() throws {
        let fixture = try Fixture(), ledger = try fixture.open(), first = fixture.request(now: 2_000)
        try ledger.reserveObservation(first, now: 2_000)
        let history = try Data(contentsOf: fixture.directory.appendingPathComponent("link.json"))
        error(.clockRollback, try ledger.reserveObservation(fixture.request(now: 1_999), now: 1_999))
        let reopened = try fixture.open()
        error(.clockRollback, try reopened.reserveObservation(fixture.request(now: 1_999), now: 1_999))
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("link.json")), history)
        error(.replay, try reopened.reserveObservation(first, now: 2_000))
    }

    func testMalformedV2ObservationHistoryDeniesActiveAndRestartedLedgers() throws {
        for mutation in 0..<10 {
            let fixture = try Fixture(), ledger = try fixture.open()
            try ledger.reserveObservation(fixture.request(), now: 1_000)
            var document = try fixture.document()
            let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
            switch mutation {
            case 0: document.removeValue(forKey: "observations")
            case 1: document["observations"] = NSNull()
            case 2: document["observations"] = ["invalid-digest": 2_000, b: 2_000]
            case 3: document["observations"] = [a: 0, b: 2_000]
            case 4: document["observations"] = [a: -1, b: 2_000]
            case 5: document["observations"] = [a: 61_001, b: 2_000]
            case 6: document["observations"] = [a: 2_000]
            case 7: document["observations"] = [a: "2000", b: 2_000]
            case 8: document["observations"] = Dictionary(uniqueKeysWithValues: (0..<2_050).map {
                (RemoteWire.digest(Data("malformed-observation-\($0)".utf8)), Int64(2_000))
            })
            default: document["observations"] = [a: Int64.max, b: 2_000]
            }
            try fixture.write(document)
            error(.storageUnavailable, try ledger.reserveObservation(fixture.request(), now: 1_000))
            error(.storageUnavailable, try fixture.open())
        }
    }

    func testValidatedV1MigrationPreservesHistoricalExecutableAndObservationalEntries() throws {
        let fixture = try Fixture(), ledger = try fixture.open(), run = fixture.request(.run)
        XCTAssertNil(try ledger.reserve(run, now: 1_000))
        let completed = RemoteExecutionSummary(state: .accepted, policy: .evaluated, providerAcceptance: .accepted,
            evidenceExecutionID: UUID().uuidString, lifecycle: [.requested, .authorized, .delivered, .executing, .providerAccepted, .unverified],
            completedAtMilliseconds: 1_000)
        try ledger.complete(run, summary: completed)
        var legacy = try fixture.document(); legacy["version"] = 1; legacy.removeValue(forKey: "observations")
        let observation = fixture.request()
        var seen = try XCTUnwrap(legacy["seen"] as? [String])
        seen.append(fixture.key("request", observation, observation.requestID.uuidString))
        seen.append(fixture.key("nonce", observation, observation.nonce.base64EncodedString()))
        var entries = try XCTUnwrap(legacy["entries"] as? [String: Any])
        let discovered = RemoteExecutionSummary(lifecycle: [.requested, .authorized, .delivered, .discovered], completedAtMilliseconds: 1_000)
        entries[fixture.key("intent", observation, observation.idempotencyKey.uuidString)] = [
            "intentDigest": try observation.intentDigest(), "reservedAt": 1_000,
            "originatingRequestID": observation.requestID.uuidString,
            "summary": try JSONSerialization.jsonObject(with: RemoteWire.encode(discovered))]
        legacy["seen"] = seen; legacy["entries"] = entries
        try fixture.write(legacy)
        let reopened = try fixture.open()
        XCTAssertTrue(try reopened.hasSeenEnvelope(observation))
        let migrated = try fixture.document()
        XCTAssertEqual(migrated["version"] as? Int, 2)
        XCTAssertEqual(Set(try XCTUnwrap(migrated["seen"] as? [String])), Set(seen))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(migrated["entries"]), options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]))
        error(.replay, try reopened.reserveObservation(observation, now: 1_000))
        try reopened.reserveObservation(fixture.request(now: 2_000), now: 2_000)
        XCTAssertTrue(try reopened.hasSeenEnvelope(observation), "Historical observations already in v1 permanent seen must never be removed")
        error(.replay, try reopened.reserve(run, now: 2_000))
        XCTAssertEqual(Set(try XCTUnwrap(try fixture.document()["seen"] as? [String])), Set(seen))
    }

    func testNonemptyV1ObservationMapCannotDowngradeReplayProtection() throws {
        let fixture = try Fixture(), ledger = try fixture.open()
        try ledger.reserveObservation(fixture.request(), now: 1_000)
        var document = try fixture.document(); document["version"] = 1
        try fixture.write(document)
        error(.storageUnavailable, try ledger.reserveObservation(fixture.request(), now: 1_000))
        error(.storageUnavailable, try fixture.open())
    }

    @MainActor func testReadOnlyDiscoveryCannotConsumeConsequentialBudgetAcrossRestart() async throws {
        let observer = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 24, count: 32)))
        let observationGrant = try RemoteCallerGrant(publicKey: observer.publicKey, operations: [.runtime, .actions], capabilityIDs: [])
        let fixture = try LifecycleAdversarialFixture(maximumRequests: 2, additionalGrants: [observationGrant])
        try await fixture.connect()
        let observationClient = try RemoteLinkClient(identity: observer, trustedRuntimeKey: fixture.node.publicKey,
            transport: fixture.relay, now: { 1_000 })
        for operation in [RemoteOperation.runtime, .actions, .runtime, .actions, .runtime, .actions] {
            let request = observationClient.makeRequest(operation: operation, item: operation == .actions ? "fixture" : "")
            let result = try await observationClient.send(request)
            XCTAssertEqual(result.summary.lifecycle.last, .discovered)
            XCTAssertEqual(fixture.provider.effects, 0)
        }
        let run = try fixture.run(), live = try await fixture.client.send(run)
        let targetID = try XCTUnwrap(live.summary.executionLifecycle?.executionID)
        XCTAssertEqual(live.summary.executionLifecycle?.terminal, false)
        XCTAssertEqual(fixture.provider.effects, 1)
        try fixture.provider.emit(.completed(.string("retained")))
        let terminal = try await fixture.client.send(fixture.client.makeStatusRequest(for: run, executionID: targetID))
        XCTAssertEqual(terminal.summary.executionLifecycle?.terminal, true)

        // Reopen the protected journal rather than reset its existing entries.
        // Observational refreshes must leave the one remaining executable
        // envelope available for an explicit same-intent terminal retry.
        let reopened = try RemoteReplayLedger(directory: fixture.directory.appendingPathComponent("journal"),
            runtimeID: fixture.node.runtimeID, maximumRequests: 2)
        let runGrant = try RemoteCallerGrant(publicKey: fixture.caller.publicKey, operations: [.run, .status],
            capabilityIDs: [fixture.provider.capability.id])
        let restarted = try RemoteExecutionDispatcher(engine: fixture.engine, identity: fixture.node, ledger: reopened,
            grants: [runGrant, observationGrant], enabled: true, now: { 1_000 })
        try await restarted.establishOutboundConnection(to: fixture.relay)
        for operation in [RemoteOperation.runtime, .actions, .runtime, .actions] {
            _ = try await observationClient.send(observationClient.makeRequest(operation: operation,
                item: operation == .actions ? "fixture" : ""))
        }
        let retained = try await fixture.client.send(fixture.run(key: run.idempotencyKey))
        XCTAssertTrue(retained.reused)
        XCTAssertEqual(retained.summary.executionLifecycle?.executionID, targetID)
        XCTAssertEqual(retained.summary.executionLifecycle?.terminal, true)
        var retainedMetadata = retained.summary, terminalMetadata = terminal.summary
        retainedMetadata.eventPage = nil; terminalMetadata.eventPage = nil
        XCTAssertEqual(try RemoteWire.encode(retainedMetadata), try RemoteWire.encode(terminalMetadata),
            "Durable terminal identity, result, verification, evidence and receipt availability must remain byte-identical")
        let restoredPage = try await fixture.client.send(fixture.client.makeStatusRequest(for: run, executionID: targetID))
        XCTAssertEqual(try RemoteWire.encode(restoredPage.summary.eventPage), try RemoteWire.encode(terminal.summary.eventPage),
            "A fresh owner-bound status must recover the identical terminal event page")
        XCTAssertEqual(try RemoteWire.encode(restoredPage.summary), try RemoteWire.encode(terminal.summary))
        do { _ = try await fixture.client.send(run); XCTFail("Discovery refresh/restart reset a consequential replay") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .replay) }
        XCTAssertEqual(fixture.provider.effects, 1)
    }

    @MainActor func testValidDiscoveryEnvelopeIdentitiesCannotBecomeRunsBeforeOrAfterRestart() async throws {
        let fixture = try LifecycleAdversarialFixture(maximumRequests: 2); try await fixture.connect()
        let observed = fixture.client.makeRequest(operation: .actions, item: "fixture")
        let catalog = try await fixture.client.send(observed)
        XCTAssertEqual(catalog.summary.lifecycle.last, .discovered)
        var requestReuse = try fixture.run(); requestReuse.requestID = observed.requestID
        var nonceReuse = try fixture.run(); nonceReuse.nonce = observed.nonce
        for substituted in [requestReuse, nonceReuse] {
            do { _ = try await fixture.client.send(substituted); XCTFail("Observation envelope identity became executable") }
            catch { XCTAssertEqual(error as? RemoteLinkError, .replay) }
        }
        let reopened = try RemoteReplayLedger(directory: fixture.directory.appendingPathComponent("journal"),
            runtimeID: fixture.node.runtimeID, maximumRequests: 2)
        let grant = try RemoteCallerGrant(publicKey: fixture.caller.publicKey, operations: [.actions, .run],
            capabilityIDs: [fixture.provider.capability.id])
        let restarted = try RemoteExecutionDispatcher(engine: fixture.engine, identity: fixture.node, ledger: reopened,
            grants: [grant], enabled: true, now: { 1_000 })
        try await restarted.establishOutboundConnection(to: fixture.relay)
        for substituted in [requestReuse, nonceReuse] {
            do { _ = try await fixture.client.send(substituted); XCTFail("Restart forgot a still-valid observation envelope") }
            catch { XCTAssertEqual(error as? RemoteLinkError, .replay) }
        }
        do { _ = try await fixture.client.send(observed); XCTFail("Restart accepted the original valid discovery replay") }
        catch { XCTAssertEqual(error as? RemoteLinkError, .replay) }
        XCTAssertEqual(fixture.provider.effects, 0)
    }
}
