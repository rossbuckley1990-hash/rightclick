import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RightClickCLI

final class AdoptionSecurityProcessTests: XCTestCase {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var failure: Error?

        func finish(_ error: Error?) {
            lock.lock(); defer { lock.unlock() }
            failure = error
            finished = true
        }

        func snapshot() -> (finished: Bool, failure: Error?) {
            lock.lock(); defer { lock.unlock() }
            return (finished, failure)
        }
    }

    private func script(_ text: String, _ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-adoption-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("native-client")
        try Data(("#!/bin/sh\n" + text).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try body(executable, root)
    }

    func testNativeOutputLargerThanPipeBufferCompletesWithoutDeadlock() throws {
        try script("/usr/bin/head -c 262144 /dev/zero\n") { executable, _ in
            let started = Date()
            let result = try RightClickClientProcess.run(executable: executable.path,
                arguments: [], timeout: 3, maximumBytes: 524288)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.output.utf8.count, 262144)
            XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        }
    }

    func testNativeProcessDeadlineReturnsAndDoesNotEchoSecretOutput() throws {
        try script("printf 'adoption-secret-process-82c\\n'\nexec /bin/sleep 30\n") { executable, _ in
            let started = Date()
            XCTAssertThrowsError(try RightClickClientProcess.run(executable: executable.path,
                arguments: [], timeout: 0.1, maximumBytes: 65536)) { error in
                XCTAssertFalse(String(describing: error).contains("adoption-secret-process-82c"))
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 3,
                "A native command deadline must not depend on child exit or pipe EOF.")
        }
    }

    func testExcessNativeOutputIsBoundedAndDoesNotEchoSecretOutput() throws {
        try script("exec /usr/bin/yes adoption-secret-process-65b\n") { executable, _ in
            let started = Date()
            XCTAssertThrowsError(try RightClickClientProcess.run(executable: executable.path,
                arguments: [], timeout: 2, maximumBytes: 65536)) { error in
                XCTAssertFalse(String(describing: error).contains("adoption-secret-process-65b"))
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        }
    }

#if canImport(Darwin) || canImport(Glibc)
    func testTimedOutNativeCommandDoesNotLeaveDescendantRunning() throws {
        try script("/bin/sleep 30 &\nprintf '%s' \"$!\" > \"$1\"\nwait\n") { executable, root in
            let childPIDFile = root.appendingPathComponent("descendant.pid")
            var descendant: Int32 = 0
            defer { if descendant > 0 { _ = kill(descendant, SIGKILL) } }
            let completion = Completion(), worker = DispatchGroup()
            worker.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { worker.leave() }
                do {
                    _ = try RightClickClientProcess.run(executable: executable.path,
                        arguments: [childPIDFile.path], timeout: 2, maximumBytes: 65536)
                    completion.finish(nil)
                } catch { completion.finish(error) }
            }

            // Establish that a descendant exists before assessing disposal.
            // A 0.2 second deadline could kill a cold shell before this write.
            let readinessDeadline = Date().addingTimeInterval(1)
            while Date() < readinessDeadline {
                if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
                   let observedPID = Int32(text), observedPID > 0 {
                    descendant = observedPID
                    break
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            XCTAssertGreaterThan(descendant, 0,
                "The fixture must acknowledge a live descendant before the disposal check.")
            XCTAssertEqual(worker.wait(timeout: .now() + 4), .success,
                "The bounded native runner must finish independently of descendant pipe EOF.")
            let result = completion.snapshot()
            XCTAssertTrue(result.finished)
            XCTAssertNotNil(result.failure, "The long-running native fixture must hit its deadline.")
            if let failure = result.failure {
                XCTAssertTrue(String(describing: failure).contains("time or output limit"))
            }
            // A readiness failure remains a failing test; it cannot prove the
            // containment invariant and must not be treated as a skipped gate.
            guard descendant > 0 else { return }
            // A short observation window permits process reaping after group termination.
            let deadline = Date().addingTimeInterval(0.5)
            while kill(descendant, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertEqual(kill(descendant, 0), -1,
                "A bounded host command must dispose of descendants that inherit its output pipes.")
        }
    }
#endif
}
