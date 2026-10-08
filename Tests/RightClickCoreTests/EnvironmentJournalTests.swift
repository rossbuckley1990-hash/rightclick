import Foundation
import XCTest
@testable import RightClickCore

final class EnvironmentJournalTests: XCTestCase {
    struct State: Codable { var executions: [String] = [] }
    func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("journal")
    }
    func testReservationsSurviveReopenAndTwoWritersSeeSameHistory() throws {
        let path = try location()
        let first = try EnvironmentJournal(directory: path, identity: "parent", initial: State())
        try first.transaction { $0.executions.append("one") }
        let second = try EnvironmentJournal(directory: path, identity: "parent", initial: State())
        XCTAssertEqual(try second.snapshot().executions, ["one"])
        try second.transaction { $0.executions.append("two") }
        XCTAssertEqual(try first.snapshot().executions, ["one", "two"])
    }
    func testSharedEffectLockSurvivesNestedTransactionsAndBlocksOtherBrokers() throws {
        let path = try location()
        let first = try EnvironmentJournal(directory: path, identity: "parent", initial: State())
        let second = try EnvironmentJournal(directory: path, identity: "parent", initial: State())
        try first.lockEffects()
        try first.transaction { $0.executions.append("intent-before-effect") }
        XCTAssertThrowsError(try second.lockEffects())
        XCTAssertThrowsError(try second.transaction { $0.executions.append("racing-destroy") })
        try first.lockEffects()
        XCTAssertEqual(try first.snapshot().executions, ["intent-before-effect"])
        first.unlockEffects()
        XCTAssertThrowsError(try second.snapshot()) // Nested snapshot did not unlock the outer flock.
        first.unlockEffects()
        try second.lockEffects()
        try second.transaction { $0.executions.append("safe-after-effect") }
        second.unlockEffects()
        XCTAssertEqual(try first.snapshot().executions, ["intent-before-effect", "safe-after-effect"])
    }
    func testEffectLockIsVisibleToAnotherProcessAfterNestedPersistence() throws {
        let path = try location()
        let journal = try EnvironmentJournal(directory: path, identity: "parent", initial: State())
        func childExit() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-c", "import os,fcntl,sys; f=os.open(sys.argv[1],os.O_RDWR|os.O_NOFOLLOW);\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(3)\nsys.exit(0)", path.appendingPathComponent("environment.lock").path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        try journal.lockEffects()
        try journal.transaction { $0.executions.append("durable") }
        XCTAssertEqual(try childExit(), 3)
        _ = try journal.snapshot()
        XCTAssertEqual(try childExit(), 3)
        journal.unlockEffects()
        XCTAssertEqual(try childExit(), 0)
    }
    func testThrowingTransactionDoesNotCommitOrDispatch() throws {
        let journal = try EnvironmentJournal(directory: location(), identity: "parent", initial: State())
        XCTAssertThrowsError(try journal.transaction { state in
            state.executions.append("uncommitted"); throw EnvironmentJournalError.storageUnavailable
        })
        XCTAssertEqual(try journal.snapshot().executions, [])
    }
    func testDeletedHistoryNeverBecomesFreshAuthority() throws {
        let path = try location()
        let journal = try EnvironmentJournal(directory: path, identity: "parent", initial: State())
        try FileManager.default.removeItem(at: path.appendingPathComponent("environment.json"))
        XCTAssertThrowsError(try journal.snapshot())
        XCTAssertThrowsError(try EnvironmentJournal(directory: path, identity: "parent", initial: State()))
    }
    func testWrongOwnerIdentityAndCorruptHistoryFailClosed() throws {
        let path = try location()
        _ = try EnvironmentJournal(directory: path, identity: "parent", initial: State())
        XCTAssertThrowsError(try EnvironmentJournal(directory: path, identity: "different", initial: State()))
        try Data("bad".utf8).write(to: path.appendingPathComponent("environment.json"))
        XCTAssertThrowsError(try EnvironmentJournal(directory: path, identity: "parent", initial: State()))
    }
    func testSymlinkReplacementAndUnsafePermissionsDenied() throws {
        let path = try location()
        let journal = try EnvironmentJournal(directory: path, identity: "parent", initial: State())
        let history = path.appendingPathComponent("environment.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: history.path)
        XCTAssertThrowsError(try journal.snapshot())
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: path.appendingPathComponent("environment.initialized"))
        XCTAssertThrowsError(try journal.snapshot())
    }
    func testDirectoryReplacementCannotResetReplayState() throws {
        let path = try location()
        var journal: EnvironmentJournal<State>? = try EnvironmentJournal(directory: path, identity: "parent", initial: State())
        try journal?.transaction { $0.executions.append("consumed") }
        let previous = path.deletingLastPathComponent().appendingPathComponent("removed")
        try FileManager.default.moveItem(at: path, to: previous)
        XCTAssertThrowsError(try journal?.snapshot())
        journal = nil
        XCTAssertThrowsError(try EnvironmentJournal(directory: path, identity: "parent", initial: State()))
    }
}
