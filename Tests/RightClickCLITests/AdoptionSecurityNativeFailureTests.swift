import Foundation
import XCTest
@testable import RightClickCLI

final class AdoptionSecurityNativeFailureTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let executable: URL
        let registration: URL
        let fault: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("rightclick-adoption-native-failure-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            executable = root.appendingPathComponent("client")
            registration = root.appendingPathComponent("registration")
            fault = root.appendingPathComponent("fault")
            let script = """
            #!/bin/sh
            STATE='\(registration.path)'
            FAULT='\(fault.path)'
            MODE=''
            if [ -f "$FAULT" ]; then MODE="$(cat "$FAULT")"; fi
            case "$1" in
              get)
                if [ ! -f "$STATE" ]; then echo ABSENT; exit 1; fi
                cat "$STATE"
                ;;
              add)
                printf 'RIGHTCLICK=DESIRED\\n' > "$STATE"
                case "$MODE" in
                  fail-add) exit 9 ;;
                  timeout-add) exec /bin/sleep 30 ;;
                  conflict-add) printf 'RIGHTCLICK=USER_CHANGED\\n' > "$STATE"; exit 9 ;;
                esac
                ;;
              remove)
                rm -f "$STATE"
                if [ "$MODE" = 'fail-remove' ]; then exit 7; fi
                ;;
              *) exit 20 ;;
            esac
            """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func setFault(_ value: String) throws { try Data(value.utf8).write(to: fault) }
        var contract: RightClickNativeRegistrationBackend.Contract {
            func command(_ verb: String) -> RightClickNativeRegistrationBackend.Command {
                .init(executable: executable.path, arguments: [verb])
            }
            return .init(backendID: "security-partial-native", scope: "fixture",
                inspect: command("get"), add: command("add"), remove: command("remove"),
                exactInspection: { $0 == "RIGHTCLICK=DESIRED\n" }, absenceMarkers: ["ABSENT"])
        }
    }

    func testFailedNativeAddThatAlreadyMutatedRestoresUnconfiguredState() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let plan = try RightClickNativeRegistrationBackend.plan(contract: fixture.contract, disconnect: false)
        try fixture.setFault("fail-add")
        XCTAssertThrowsError(try RightClickNativeRegistrationBackend.apply(plan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.registration.path),
            "A native command may mutate before its nonzero exit; setup must inspect and undo only its exact partial result.")
    }

    func testFailedNativeRemoveThatAlreadyMutatedRestoresExactRegistration() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let original = Data("RIGHTCLICK=DESIRED\n".utf8)
        try original.write(to: fixture.registration)
        let plan = try RightClickNativeRegistrationBackend.plan(contract: fixture.contract, disconnect: true)
        try fixture.setFault("fail-remove")
        XCTAssertThrowsError(try RightClickNativeRegistrationBackend.apply(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.registration.path))
        if FileManager.default.fileExists(atPath: fixture.registration.path) {
            XCTAssertEqual(try Data(contentsOf: fixture.registration), original)
        }
    }

    func testTimedOutNativeAddThatAlreadyMutatedRestoresUnconfiguredState() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let plan = try RightClickNativeRegistrationBackend.plan(contract: fixture.contract, disconnect: false)
        try fixture.setFault("timeout-add")
        let started = Date()
        XCTAssertThrowsError(try RightClickNativeRegistrationBackend.apply(plan))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.registration.path),
            "Timeout is not evidence that a native mutation never happened.")
    }

    func testFailedNativeAddPreservesNewerConflictingRegistration() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let plan = try RightClickNativeRegistrationBackend.plan(contract: fixture.contract, disconnect: false)
        try fixture.setFault("conflict-add")
        XCTAssertThrowsError(try RightClickNativeRegistrationBackend.apply(plan))
        XCTAssertEqual(try Data(contentsOf: fixture.registration), Data("RIGHTCLICK=USER_CHANGED\n".utf8),
            "Recovery after a failed native add cannot erase a conflicting current registration.")
    }
}
