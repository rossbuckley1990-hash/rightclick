import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RightClickCLI

final class AdoptionSecurityProcessTests: XCTestCase {
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
            XCTAssertThrowsError(try RightClickClientProcess.run(executable: executable.path,
                arguments: [childPIDFile.path], timeout: 0.2, maximumBytes: 65536))
            descendant = try XCTUnwrap(Int32(String(contentsOf: childPIDFile, encoding: .utf8)))
            // A short observation window permits process reaping after group termination.
            let deadline = Date().addingTimeInterval(0.5)
            while kill(descendant, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertEqual(kill(descendant, 0), -1,
                "A bounded host command must dispose of descendants that inherit its output pipes.")
        }
    }
#endif
}
