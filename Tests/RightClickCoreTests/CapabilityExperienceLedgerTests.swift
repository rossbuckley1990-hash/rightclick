import Foundation
import XCTest
@testable import RightClickCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class CapabilityExperienceLedgerTests: XCTestCase {
    private let key = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func directory() throws -> URL {
        let url = NativeHTTPFixture.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-experience-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEmptyLedgerHasNoLearnedEvidence() throws {
        XCTAssertTrue(try CapabilityExperienceLedger().entries(now: now).isEmpty)
    }

    func testAcceptanceRemainsUnverified() throws {
        let store = try CapabilityExperienceLedger()
        try store.record(executionID: UUID(), contractKey: key, outcome: .acceptedUnverified, now: now)
        XCTAssertEqual(try store.entries(now: now).first?.outcome, .acceptedUnverified)
    }

    func testDuplicateExecutionIsNotDoubleCounted() throws {
        let store = try CapabilityExperienceLedger()
        let id = UUID()
        for _ in 0..<10 { try store.record(executionID: id, contractKey: key, outcome: .acceptedUnverified, now: now) }
        XCTAssertEqual(try store.entries(now: now).count, 1)
    }

    func testVerificationReplacesAcceptanceRatherThanAddingSuccess() throws {
        let store = try CapabilityExperienceLedger()
        let id = UUID()
        try store.record(executionID: id, contractKey: key, outcome: .acceptedUnverified, now: now)
        try store.record(executionID: id, contractKey: key, outcome: .predicatesVerified, now: now)
        let entries = try store.entries(now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].outcome, .predicatesVerified)
    }

    func testLateAcceptanceDoesNotEraseVerification() throws {
        let store = try CapabilityExperienceLedger()
        let id = UUID()
        try store.record(executionID: id, contractKey: key, outcome: .predicatesVerified, now: now)
        try store.record(executionID: id, contractKey: key, outcome: .acceptedUnverified, now: now)
        XCTAssertEqual(try store.entries(now: now).first?.outcome, .predicatesVerified)
    }

    func testLateAcceptanceDoesNotEraseFailure() throws {
        let store = try CapabilityExperienceLedger()
        let id = UUID()
        try store.record(executionID: id, contractKey: key, outcome: .failed, now: now)
        try store.record(executionID: id, contractKey: key, outcome: .acceptedUnverified, now: now)
        XCTAssertEqual(try store.entries(now: now).first?.outcome, .failed)
    }

    func testExecutionCannotBeReboundToChangedContract() throws {
        let store = try CapabilityExperienceLedger()
        let id = UUID()
        try store.record(executionID: id, contractKey: key, outcome: .acceptedUnverified, now: now)
        XCTAssertThrowsError(try store.record(executionID: id, contractKey: other, outcome: .predicatesVerified, now: now))
        XCTAssertEqual(try store.entries(now: now).first?.contractKey, key)
    }

    func testExpiryDoesNotRefreshOnReadOrRepeatedCallback() throws {
        let store = try CapabilityExperienceLedger(maximumAge: 10)
        let id = UUID()
        try store.record(executionID: id, contractKey: key, outcome: .acceptedUnverified, now: now)
        try store.record(executionID: id, contractKey: key, outcome: .acceptedUnverified, now: now.addingTimeInterval(9))
        XCTAssertEqual(try store.entries(now: now.addingTimeInterval(9)).count, 1)
        XCTAssertTrue(try store.entries(now: now.addingTimeInterval(10)).isEmpty)
    }

    func testFutureDatedEvidenceIsNotReusedAfterClockRollback() throws {
        let store = try CapabilityExperienceLedger()
        try store.record(executionID: UUID(), contractKey: key, outcome: .predicatesVerified, now: now)
        XCTAssertTrue(try store.entries(now: now.addingTimeInterval(-1)).isEmpty)
    }

    func testCapacityEvictsOldestAndPreservesNewest() throws {
        let store = try CapabilityExperienceLedger(maximumEntries: 2)
        for index in 0..<5 {
            try store.record(executionID: UUID(), contractKey: key, outcome: .acceptedUnverified,
                now: now.addingTimeInterval(Double(index)))
        }
        let entries = try store.entries(now: now.addingTimeInterval(4))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.observedAt)), Set([now.addingTimeInterval(3), now.addingTimeInterval(4)]))
    }

    func testInvalidKeysAndBoundsAreRejected() throws {
        let store = try CapabilityExperienceLedger()
        for invalid in ["", "secret", String(repeating: "A", count: 64), key + "x", "../data"] {
            XCTAssertThrowsError(try store.record(executionID: UUID(), contractKey: invalid, outcome: .unknown, now: now))
        }
        XCTAssertThrowsError(try CapabilityExperienceLedger(maximumEntries: 0))
        XCTAssertThrowsError(try CapabilityExperienceLedger(maximumEntries: 1025))
        XCTAssertThrowsError(try CapabilityExperienceLedger(maximumAge: .infinity))
        XCTAssertThrowsError(try CapabilityExperienceLedger(maximumAge: -1))
        XCTAssertThrowsError(try store.entries(now: Date(timeIntervalSince1970: .infinity)))
    }

    func testPersistenceSurvivesNewInstance() throws {
        let url = try directory()
        let id = UUID()
        try CapabilityExperienceLedger(directory: url).record(executionID: id, contractKey: key,
            outcome: .predicatesVerified, now: now)
        let entries = try CapabilityExperienceLedger(directory: url).entries(now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.executionID, id)
    }

    func testTwoInstancesDoNotOverwriteEachOthersEvidence() throws {
        let url = try directory()
        let first = try CapabilityExperienceLedger(directory: url)
        let second = try CapabilityExperienceLedger(directory: url)
        try first.record(executionID: UUID(), contractKey: key, outcome: .acceptedUnverified, now: now)
        try second.record(executionID: UUID(), contractKey: other, outcome: .failed, now: now)
        XCTAssertEqual(try first.entries(now: now).count, 2)
    }

    func testPersistedSchemaHasOnlyAllowlistedFields() throws {
        let url = try directory()
        try CapabilityExperienceLedger(directory: url).record(executionID: UUID(), contractKey: key,
            outcome: .acceptedUnverified, now: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("experience.json"))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "entries"])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(entries[0].keys), ["executionID", "contractKey", "outcome", "observedAt"])
    }

    func testPrivateFilePermissions() throws {
        let url = try directory()
        try CapabilityExperienceLedger(directory: url).record(executionID: UUID(), contractKey: key, outcome: .unknown, now: now)
        for name in ["experience.json", "experience.lock"] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testUnsafeDirectoryPermissionsAreRejected() throws {
        let url = try directory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        XCTAssertThrowsError(try CapabilityExperienceLedger(directory: url))
    }

    func testSymlinkDirectoryIsRejected() throws {
        let parent = try directory()
        let target = try directory()
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try CapabilityExperienceLedger(directory: link))
    }

    func testSymlinkDataAndLockFilesAreRejectedWithoutChangingTarget() throws {
        for name in ["experience.json", "experience.lock"] {
            let url = try directory()
            let target = url.appendingPathComponent("sentinel")
            let data = Data("DO NOT CHANGE".utf8)
            try data.write(to: target)
            try FileManager.default.createSymbolicLink(at: url.appendingPathComponent(name), withDestinationURL: target)
            let store = try CapabilityExperienceLedger(directory: url)
            XCTAssertThrowsError(try store.record(executionID: UUID(), contractKey: key, outcome: .unknown, now: now))
            XCTAssertEqual(try Data(contentsOf: target), data)
        }
    }

    func testHardLinkedFileIsRejected() throws {
        let url = try directory()
        let target = url.appendingPathComponent("sentinel")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.linkItem(at: target, to: url.appendingPathComponent("experience.json"))
        XCTAssertThrowsError(try CapabilityExperienceLedger(directory: url).entries(now: now))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel")
    }

    func testCorruptDataIsRejectedNotSilentlyOverwritten() throws {
        let url = try directory()
        let file = url.appendingPathComponent("experience.json")
        let bad = Data("{truncated".utf8)
        try bad.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try CapabilityExperienceLedger(directory: url).entries(now: now))
        XCTAssertEqual(try Data(contentsOf: file), bad)
    }

    func testOversizedDataIsRejected() throws {
        let url = try directory()
        let file = url.appendingPathComponent("experience.json")
        try Data(repeating: 32, count: 524_289).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try CapabilityExperienceLedger(directory: url).entries(now: now))
    }

    func testUnknownVersionAndDuplicateExecutionIDsAreRejected() throws {
        let url = try directory()
        let file = url.appendingPathComponent("experience.json")
        let store = try CapabilityExperienceLedger(directory: url)
        try store.record(executionID: UUID(), contractKey: key, outcome: .unknown, now: now)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for duplicate in [false, true] {
            var changed = original
            if duplicate {
                let rows = try XCTUnwrap(changed["entries"] as? [Any])
                changed["entries"] = rows + rows
            } else { changed["version"] = 99 }
            try JSONSerialization.data(withJSONObject: changed).write(to: file)
            XCTAssertThrowsError(try store.entries(now: now))
        }
    }

    func testForgetAllPersists() throws {
        let url = try directory()
        let store = try CapabilityExperienceLedger(directory: url)
        try store.record(executionID: UUID(), contractKey: key, outcome: .unknown)
        try store.forgetAll()
        XCTAssertTrue(try CapabilityExperienceLedger(directory: url).entries().isEmpty)
    }

    func testHeldProcessLockFailsPromptlyInsteadOfHanging() throws {
        let url = try directory()
        let store = try CapabilityExperienceLedger(directory: url)
        _ = try store.entries(now: now)
        let fd = open(url.appendingPathComponent("experience.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.entries(now: now))
    }
}
