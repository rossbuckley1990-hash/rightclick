import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class RCIRInvocationJournalTests: XCTestCase {
#if os(macOS) || os(Linux)
    private func directory() throws -> URL {
        let temporaryPath = NativeHTTPFixture.temporaryDirectory.path
        let resolved = try XCTUnwrap(realpath(temporaryPath, nil))
        defer { free(resolved) }
        let path = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("rcir-journal-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock {
            try? FileManager.default.removeItem(at: path)
            let anchor = path.deletingLastPathComponent().appendingPathComponent(
                ".rightclick-invocations-" + CapabilityJSON.digest(Data(path.lastPathComponent.utf8)) + ".initialized")
            try? FileManager.default.removeItem(at: anchor)
        }
        return path
    }
    private func task(secret: String = "private-argument", scope: String = "private-resource",
                      verification: RCIRVerificationContract? = nil) throws -> RCIRTask {
        let scope = RCIRScope(scope, .write)
        let abi = CapabilityContract(capabilityID: "private-capability", reflectorID: "private-reflector", providerID: "private-provider",
            arguments: .string, result: .string, declaration: .string("private-declaration"))
        let admission = RCIRAdmission()
        let binding = try admission.publish(RCIRContract(abi: abi, scopes: [scope], verification: verification), authenticatedPrincipal: "private-principal")
        let policy = RCIRPolicy(revision: "private-policy", principals: ["private-principal"], scopes: [scope])
        let lease = try admission.issue(binding, arguments: .string(secret), authority: [scope], policy: policy, now: 100)
        return try RCIRTask(lease: lease, startedAt: 101, deadline: 1000)
    }
    private func identity(_ task: RCIRTask, id: String = UUID().uuidString) throws -> RCIRInvocationJournal.Identity {
        try .init(executionID: id, task: task)
    }
    private func accepted(_ task: inout RCIRTask, identity: RCIRInvocationJournal.Identity) throws -> ExecutionRecord {
        try task.record(.completed(.string("private-provider-output")), sequence: 1, now: 110)
        let payload = try task.receiptData().base64EncodedString()
        return ExecutionRecord(executionId: identity.executionID.uuidString, actionId: "private-capability", state: .accepted,
            message: "Provider acceptance", output: "private-provider-output", rcir: .init(version: 1,
                taskID: task.id.uuidString, leaseID: task.lease.id.uuidString, generation: task.lease.binding.generation,
                leaseConsumed: true, phase: task.phase.rawValue, outcome: task.outcome.rawValue,
                receipt: payload, signedReceipt: nil, observationBoundary: "private-observer-boundary"))
    }
    private func hostExecute(_ host: RCIRExecutionHost, id: String = UUID().uuidString,
                             currentContract: @escaping () -> Bool = { true },
                             start: @escaping () -> Void) throws -> ExecutionRecord {
        host.now = { 101 }; host.configuration = { RCIRHostConfiguration() }
        let capability = Capability(id: "journal-host", title: "Journal host", source: .system,
            reflectorID: "journal-host", safety: .localReversible, invocation: .direct,
            supportLevel: .publicSupported, requiresConfirmation: false)
        let abi = try capability.abiContract(arguments: .string, result: .string)
        let target = URL(string: "http://127.0.0.1:19433/disposable")!, scope = RCIRScope(target.absoluteString, .execute)
        return try host.execute(abi: abi, discovery: abi, arguments: .string("private-argument"), scope: scope,
            capability: capability, executionID: id, argumentStrings: nil, item: ContentParser.parse("journal"),
            verification: nil, expectedOutput: nil, target: target, authority: { [scope] }, revalidate: { true },
            currentContract: currentContract, dispatch: { _, admit in
                try admit(start)
                return ExecutionRecord(executionId: "provider-cannot-substitute-identity", actionId: "provider-claimed", state: .accepted,
                    message: "Provider ACK", output: "private-output")
            }, resultValue: { .string($0.output ?? "") })
    }

    func testReopenUnfinishedIntentPreservesExactIdentityAndUnknownWithoutAuthority() throws {
        let path = try directory(), task = try task(), id = try identity(task)
        let journal = try RCIRInvocationJournal(directory: path)
        _ = try journal.reserveDispatch(id, now: 102)
        let reopened = try RCIRInvocationJournal(directory: path)
        let status = try XCTUnwrap(reopened.status(id.executionID.uuidString, now: 103))
        XCTAssertEqual(status.state, .unknown); XCTAssertEqual(status.evidence.type, "rcir_recovered_journal")
        XCTAssertFalse(status.evidence.outcomeVerified); XCTAssertNil(status.rcir); XCTAssertNil(status.output)
        XCTAssertTrue(status.events.contains("task=" + task.id.uuidString))
        XCTAssertTrue(status.events.contains("lastDurablePhase=dispatching"))
    }

    func testTerminalSummaryHasReceiptDigestAndNoPrivatePayloadOrCapabilityText() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path)
        var task = try task(); let id = try identity(task)
        let ticket = try journal.reserveDispatch(id, now: 102)
        let record = try accepted(&task, identity: id)
        try journal.checkpoint(ticket, task: task, record: record, now: 111)
        let status = try XCTUnwrap(RCIRInvocationJournal(directory: path).status(id.executionID.uuidString, now: 112))
        XCTAssertEqual(status.state, .accepted); XCTAssertFalse(status.evidence.outcomeVerified)
        XCTAssertNil(status.rcir); XCTAssertNil(status.output)
        XCTAssertTrue(status.events.contains("receiptSHA256=" + CapabilityJSON.digest(try task.receiptData())))
        let stored = try String(contentsOf: path.appendingPathComponent("invocations.json"), encoding: .utf8)
        for privateText in ["private-argument", "private-resource", "private-capability", "private-reflector", "private-provider",
                            "private-declaration", "private-principal", "private-policy", "private-provider-output", "private-observer-boundary"] {
            XCTAssertFalse(stored.contains(privateText), privateText)
        }
    }

    func testDuplicateIdentityCannotReserveOrChangeTerminalHistory() throws {
        let journal = try RCIRInvocationJournal(directory: directory())
        var task = try task(); let id = try identity(task)
        let ticket = try journal.reserveDispatch(id, now: 102)
        XCTAssertThrowsError(try journal.reserveDispatch(id, now: 103))
        let record = try accepted(&task, identity: id)
        try journal.checkpoint(ticket, task: task, record: record, now: 111)
        // completed/unverified may be strengthened by observation, but cannot be
        // relabelled as never dispatched after a transport completion.
        XCTAssertThrowsError(try journal.notDispatched(ticket, now: 112))
        XCTAssertEqual(try journal.status(id.executionID.uuidString, now: 113)?.state, .accepted)
    }

    func testTicketCannotCheckpointAnotherTaskOrExecution() throws {
        let journal = try RCIRInvocationJournal(directory: directory())
        let original = try task(), ticket = try journal.reserveDispatch(identity(original), now: 102)
        var substitute = try task(); let id = try identity(substitute)
        let record = try accepted(&substitute, identity: id)
        XCTAssertThrowsError(try journal.checkpoint(ticket, task: substitute, record: record, now: 112))
    }

    func testUnfinishedIdentityIsNotEvictedForCapacityOrTerminalTTL() throws {
        let journal = try RCIRInvocationJournal(directory: directory(), maximumEntries: 1, maximumAgeMilliseconds: 10)
        let original = try task(), id = try identity(original)
        _ = try journal.reserveDispatch(id, now: 102)
        XCTAssertThrowsError(try journal.reserveDispatch(identity(task()), now: 120))
        XCTAssertEqual(try journal.status(id.executionID.uuidString, now: 100_000)?.state, .unknown)
    }

    func testTerminalUnknownMutationIdentitySurvivesCapacityAndTTL() throws {
        let journal = try RCIRInvocationJournal(directory: directory(), maximumEntries: 1, maximumAgeMilliseconds: 10)
        var task = try task(); let id = try identity(task), ticket = try journal.reserveDispatch(id, now: 102)
        try task.providerDisappeared(now: 110)
        let record = ExecutionRecord(executionId: id.executionID.uuidString, actionId: "private", state: .unknown, message: "Lost provider")
        try journal.checkpoint(ticket, task: task, record: record, now: 111)
        XCTAssertThrowsError(try journal.reserveDispatch(identity(self.task()), now: 100_000))
        XCTAssertEqual(try journal.status(id.executionID.uuidString, now: 100_000)?.state, .unknown)
    }

    func testRecoveredSuccessWithoutArchivedProofIsHistoricalAndUnverified() throws {
        let journal = try RCIRInvocationJournal(directory: directory())
        var task = try task(verification: .init(observerID: "host:independent", schema: .string, expected: .string("private-provider-output")))
        let id = try identity(task), ticket = try journal.reserveDispatch(id, now: 102)
        var record = try accepted(&task, identity: id)
        try task.verify(observerID: "host:independent", now: 111) { _, _ in .string("private-provider-output") }
        record.state = .succeeded
        record.rcir = .init(version: 1, taskID: task.id.uuidString, leaseID: task.lease.id.uuidString,
            generation: task.lease.binding.generation, leaseConsumed: true, phase: task.phase.rawValue,
            outcome: task.outcome.rawValue, receipt: try task.receiptData().base64EncodedString(), signedReceipt: nil,
            observationBoundary: "Independently verified in the original process")
        try journal.checkpoint(ticket, task: task, record: record, now: 112)
        let recovered = try XCTUnwrap(journal.status(id.executionID.uuidString, now: 113))
        XCTAssertEqual(recovered.state, .accepted); XCTAssertFalse(recovered.evidence.outcomeVerified)
        XCTAssertNil(recovered.rcir); XCTAssertNil(recovered.verification)
        XCTAssertTrue(recovered.events.contains("lastDurableOutcome=succeeded"))
        XCTAssertTrue(recovered.events.contains("lastDurableState=succeeded"))
    }

    func testTerminalRetentionExpiresAndCannotExceedByteBudget() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path, maximumAgeMilliseconds: 10)
        var task = try task(); let id = try identity(task), ticket = try journal.reserveDispatch(id, now: 102)
        let record = try accepted(&task, identity: id)
        try journal.checkpoint(ticket, task: task, record: record, now: 111)
        XCTAssertNil(try journal.status(id.executionID.uuidString, now: 122))
        let bounded = try RCIRInvocationJournal(directory: directory(), maximumBytes: 1024)
        _ = try bounded.reserveDispatch(identity(self.task()), now: 102)
        XCTAssertThrowsError(try bounded.reserveDispatch(identity(self.task()), now: 103))
    }

    func testSymlinkedDirectoryParentAndHistoryAreRejected() throws {
        let root = try directory(), real = root.appendingPathComponent("real"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try RCIRInvocationJournal(directory: link))
        XCTAssertThrowsError(try RCIRInvocationJournal(directory: link.appendingPathComponent("nested")))
        let journal = try RCIRInvocationJournal(directory: real)
        let foreign = root.appendingPathComponent("foreign"); try Data("fixture".utf8).write(to: foreign)
        try FileManager.default.removeItem(at: real.appendingPathComponent("invocations.json"))
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("invocations.json"), withDestinationURL: foreign)
        XCTAssertThrowsError(try journal.reserveDispatch(identity(task()), now: 102))
        XCTAssertEqual(try Data(contentsOf: foreign), Data("fixture".utf8))
    }

    func testGroupReadableHistoryHardLinksAndNonprivateDirectoriesAreRejected() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
        _ = try journal.reserveDispatch(id, now: 102)
        let file = path.appendingPathComponent("invocations.json")
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 103))
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(link(file.path, path.appendingPathComponent("hardlink").path), 0)
        XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 103))
        try FileManager.default.removeItem(at: path.appendingPathComponent("hardlink"))
        XCTAssertEqual(chmod(path.path, 0o755), 0)
        XCTAssertThrowsError(try journal.reserveDispatch(identity(task()), now: 104))
    }

#if os(macOS)
    func testDarwinExtendedACLDoesNotBypassPrivateModeBits() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
        _ = try journal.reserveDispatch(id, now: 102)
        let file = path.appendingPathComponent("invocations.json")
        let command = Process(); command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "everyone allow read,write", file.path]
        try command.run(); command.waitUntilExit(); XCTAssertEqual(command.terminationStatus, 0)
        XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 103))
    }
#endif

    func testCorruptAndSignatureFreeUnknownFieldHistoryNeverFallsBackToEmpty() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
        _ = try journal.reserveDispatch(id, now: 102)
        let file = path.appendingPathComponent("invocations.json"), original = try Data(contentsOf: file)
        try Data(original.dropLast()).write(to: file)
        XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 103))
        XCTAssertThrowsError(try RCIRInvocationJournal(directory: path))
        let header = Data("RIGHTCLICK-INVOCATION-JOURNAL-1\n".utf8)
        let payload = Data(original.dropFirst(header.count).dropLast(65))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        document["providerControlledExtra"] = "must-not-be-retained"
        let changed = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try (header + changed + Data(("\n" + CapabilityJSON.digest(changed)).utf8)).write(to: file)
        XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 104))
    }

    func testChecksumValidContradictorySuccessClaimsAreRejected() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
        _ = try journal.reserveDispatch(id, now: 102)
        let file = path.appendingPathComponent("invocations.json"), data = try Data(contentsOf: file)
        let header = Data("RIGHTCLICK-INVOCATION-JOURNAL-1\n".utf8)
        let payload = Data(data.dropFirst(header.count).dropLast(65))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        entries[0]["state"] = "succeeded"
        document["entries"] = entries
        let changed = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try (header + changed + Data(("\n" + CapabilityJSON.digest(changed)).utf8)).write(to: file)
        XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 103))
        XCTAssertThrowsError(try RCIRInvocationJournal(directory: path))
    }

    func testMissingInitializedSnapshotFailsClosedAcrossExistingAndRestartedHandles() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
        _ = try journal.reserveDispatch(id, now: 102)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("initialized").path))
        try FileManager.default.removeItem(at: path.appendingPathComponent("invocations.json"))
        XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 103))
        XCTAssertThrowsError(try journal.reserveDispatch(identity(task()), now: 104))
        XCTAssertThrowsError(try RCIRInvocationJournal(directory: path))
    }

    func testMissingOrReplacedMarkerAndDoubleHistoryLossCannotResetAnInitializedHandle() throws {
        for mode in ["markerOnly", "both", "replacement"] {
            let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
            _ = try journal.reserveDispatch(id, now: 102)
            let marker = path.appendingPathComponent("initialized"), bytes = try Data(contentsOf: marker)
            // Keep the old inode allocated so identical replacement bytes cannot
            // accidentally receive its just-freed inode number in this control.
            try FileManager.default.moveItem(at: marker, to: path.appendingPathComponent("old-marker"))
            if mode == "both" { try FileManager.default.removeItem(at: path.appendingPathComponent("invocations.json")) }
            if mode == "replacement" { try bytes.write(to: marker); XCTAssertEqual(chmod(marker.path, 0o600), 0) }
            XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 103), mode)
            XCTAssertThrowsError(try journal.reserveDispatch(id, now: 104), mode)
            if mode == "markerOnly" { XCTAssertThrowsError(try RCIRInvocationJournal(directory: path)) }
        }
    }

    func testAbandonedStagingSnapshotIsBoundedAndOnlySafePrivateFilesAreRemoved() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
        _ = try journal.reserveDispatch(id, now: 102)
        let staged = path.appendingPathComponent("invocations.tmp")
        try Data(contentsOf: path.appendingPathComponent("invocations.json")).write(to: staged)
        XCTAssertEqual(chmod(staged.path, 0o600), 0)
        let reopened = try RCIRInvocationJournal(directory: path)
        XCTAssertNotNil(try reopened.status(id.executionID.uuidString, now: 103))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let foreign = path.appendingPathComponent("foreign-staged"); try Data("untouched".utf8).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: foreign)
        XCTAssertThrowsError(try reopened.reserveDispatch(identity(task()), now: 104))
        XCTAssertEqual(try Data(contentsOf: foreign), Data("untouched".utf8))
    }

    func testReplacingLockedPathDuringCommitRejectsLostWriterAuthority() throws {
        for unlink in [false, true] {
            let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
            journal.beforeCommit = {
                let lock = path.appendingPathComponent("invocations.lock")
                if unlink { try FileManager.default.removeItem(at: lock) }
                else { try FileManager.default.moveItem(at: lock, to: path.appendingPathComponent("old-lock")) }
                try Data().write(to: lock)
                XCTAssertEqual(chmod(lock.path, 0o600), 0)
            }
            XCTAssertThrowsError(try journal.reserveDispatch(id, now: 102))
            journal.beforeCommit = nil
            // Reconciliation strengthens the candidate contract: a replaced writer
            // identity invalidates storage, including status, instead of looking empty.
            XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 103),
                "Detached writer history must fail closed, not become an empty journal")
        }
    }

    func testDeletedDirectoryCannotBecomeEmptyHistoryAfterRestart() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path)
        _ = try journal.reserveDispatch(identity(task()), now: 102)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try RCIRInvocationJournal(directory: path))
    }

    func testAnchorLostAtCommitCannotPublishOrRecoverAnEmptyJournal() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
        let anchor = path.deletingLastPathComponent().appendingPathComponent(
            ".rightclick-invocations-" + CapabilityJSON.digest(Data(path.lastPathComponent.utf8)) + ".initialized")
        journal.beforeCommit = { try FileManager.default.removeItem(at: anchor) }
        XCTAssertThrowsError(try journal.reserveDispatch(id, now: 102))
        journal.beforeCommit = nil
        XCTAssertThrowsError(try journal.status(id.executionID.uuidString, now: 103))
        XCTAssertThrowsError(try RCIRInvocationJournal(directory: path))
    }

    func testWritableAncestorCannotProvisionDurableExecutionAuthority() throws {
        let parent = try directory()
        XCTAssertEqual(chmod(parent.path, 0o777), 0)
        defer { _ = chmod(parent.path, 0o700) }
        XCTAssertThrowsError(try RCIRInvocationJournal(directory: parent.appendingPathComponent("journal")))
    }

    func testConcurrentWriterLockDeniesWithoutWaitingAndIndependentWritersKeepBothIdentities() throws {
        let path = try directory(), first = try RCIRInvocationJournal(directory: path), second = try RCIRInvocationJournal(directory: path)
        let fd = open(path.appendingPathComponent("invocations.lock").path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { _ = flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let start = Date()
        XCTAssertThrowsError(try first.reserveDispatch(identity(task()), now: 102))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        let a = try identity(task()), b = try identity(task())
        _ = try first.reserveDispatch(a, now: 103); _ = try second.reserveDispatch(b, now: 104)
        XCTAssertNotNil(try first.status(b.executionID.uuidString, now: 105))
        XCTAssertNotNil(try second.status(a.executionID.uuidString, now: 105))
    }

    func testSubstitutedOrLinkedStagingFileCannotBecomeCommittedHistory() throws {
        for mode in ["regular", "symlink", "hardlink"] {
            let path = try directory(), journal = try RCIRInvocationJournal(directory: path), id = try identity(task())
            let committed = path.appendingPathComponent("invocations.json"), before = try Data(contentsOf: committed)
            journal.beforeCommit = {
                let staged = path.appendingPathComponent("invocations.tmp"), foreign = path.appendingPathComponent("foreign")
                if mode == "hardlink" { XCTAssertEqual(link(staged.path, foreign.path), 0); return }
                try FileManager.default.moveItem(at: staged, to: path.appendingPathComponent("old-staged"))
                if mode == "symlink" {
                    try Data("foreign".utf8).write(to: foreign)
                    try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: foreign)
                } else { try Data("foreign".utf8).write(to: staged); XCTAssertEqual(chmod(staged.path, 0o600), 0) }
            }
            XCTAssertThrowsError(try journal.reserveDispatch(id, now: 102), mode)
            journal.beforeCommit = nil
            XCTAssertEqual(try Data(contentsOf: committed), before, mode)
            XCTAssertNil(try journal.status(id.executionID.uuidString, now: 103), mode)
        }
    }

    func testJournalFailureRejectsBeforeActualProviderStartAndFreshContractAfterIntentStillWins() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path), host = RCIRExecutionHost()
        host.invocationJournal = { journal }
        var starts = 0
        XCTAssertEqual(chmod(path.path, 0o755), 0)
        let denied = try hostExecute(host) { starts += 1 }
        XCTAssertEqual(denied.state, .rejected); XCTAssertEqual(starts, 0)
        XCTAssertEqual(chmod(path.path, 0o700), 0)
        let id = UUID().uuidString
        let stale = try hostExecute(host, id: id,
            currentContract: {
                let snapshot = try? String(contentsOf: path.appendingPathComponent("invocations.json"), encoding: .utf8)
                return snapshot.map { !$0.contains(id) } ?? false
            }) { starts += 1 }
        XCTAssertEqual(stale.state, .rejected); XCTAssertEqual(starts, 0)
        XCTAssertEqual(try journal.status(id, now: 102)?.state, .rejected)
    }

    func testPostEffectCheckpointFailurePreservesKnownEvidenceAndRestartRemainsUnknown() throws {
        let path = try directory(), journal = try RCIRInvocationJournal(directory: path), host = RCIRExecutionHost()
        host.invocationJournal = { journal }
        var starts = 0
        let record = try hostExecute(host) { starts += 1; _ = chmod(path.path, 0o755) }
        XCTAssertEqual(starts, 1); XCTAssertEqual(record.state, .accepted); XCTAssertEqual(record.rcir?.outcome, "unverified")
        XCTAssertTrue(record.events.contains(RCIRJournalConfiguration.checkpointFailure))
        XCTAssertEqual(chmod(path.path, 0o700), 0)
        let recovered = try XCTUnwrap(journal.status(record.executionId, now: 102))
        XCTAssertEqual(recovered.state, .unknown); XCTAssertFalse(recovered.evidence.outcomeVerified)
    }

    func testDisabledJournalExplicitlyReportsVolatileExecution() throws {
        let host = RCIRExecutionHost(); host.invocationJournal = { nil }
        var starts = 0
        let result = try hostExecute(host) { starts += 1 }
        XCTAssertEqual(starts, 1); XCTAssertEqual(result.state, .accepted)
        XCTAssertTrue(result.events.contains(RCIRJournalConfiguration.volatileBoundary))
    }
#else
    func testWindowsOrOtherHostDurableModeIsExplicitlyUnsupported() throws {
        XCTAssertThrowsError(try RCIRInvocationJournal(directory: NativeHTTPFixture.temporaryDirectory)) { error in
            guard case RCIRJournalError.unsupportedHost = error else { return XCTFail("Expected unsupported durable backend") }
        }
    }
#endif
}
