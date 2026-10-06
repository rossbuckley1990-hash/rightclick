import Foundation
import XCTest
@testable import RightClickCLI

final class NativeMutationLeaseRedTests:
    XCTestCase
{
    private struct Fixture {
        let root: URL
        let executable: URL
        let state: URL
        let log: URL

        init() throws {
            let fm =
                FileManager.default

            root =
                fm.temporaryDirectory
                    .resolvingSymlinksInPath()
                    .appendingPathComponent(
                        "rightclick-native-lease-"
                        + UUID().uuidString
                    )

            executable =
                root.appendingPathComponent(
                    "native-client"
                )

            state =
                root.appendingPathComponent(
                    "state"
                )

            log =
                root.appendingPathComponent(
                    "log"
                )

            try fm.createDirectory(
                at: root,
                withIntermediateDirectories:
                    true
            )

            let script = """
            #!/bin/sh

            STATE="\(state.path)"
            LOG="\(log.path)"

            printf '%s\\n' "$1" >> "$LOG"

            case "$1" in
              get)
                if [ ! -f "$STATE" ]; then
                  echo "ABSENT" >&2
                  exit 1
                fi

                MODE="$(cat "$STATE")"

                if [ "$MODE" = "desired" ]; then
                  echo "RIGHTCLICK=DESIRED"
                  exit 0
                fi

                echo "RIGHTCLICK=CONFLICT"
                exit 0
                ;;

              add)
                # Deliberately models a native client whose
                # add command overwrites a same-name entry.
                echo "desired" > "$STATE"
                echo "ADDED"
                exit 0
                ;;

              remove)
                rm -f "$STATE"
                echo "REMOVED"
                exit 0
                ;;

              *)
                echo "unexpected command" >&2
                exit 20
                ;;
            esac
            """

            try Data(
                script.utf8
            )
            .write(
                to: executable
            )

            try fm.setAttributes(
                [
                    .posixPermissions:
                        0o700,
                ],
                ofItemAtPath:
                    executable.path
            )
        }

        func cleanup() {
            try? FileManager.default
                .removeItem(
                    at: root
                )
        }

        func setState(
            _ value: String?
        ) throws {
            if let value {
                try Data(
                    (value + "\n").utf8
                )
                .write(
                    to: state
                )
            } else {
                try? FileManager.default
                    .removeItem(
                        at: state
                    )
            }
        }

        func stateBytes()
            throws
            -> Data?
        {
            guard
                FileManager.default
                    .fileExists(
                        atPath:
                            state.path
                    )
            else {
                return nil
            }

            return try Data(
                contentsOf:
                    state
            )
        }

        func clearLog() {
            try? FileManager.default
                .removeItem(
                    at: log
                )
        }

        func logLines()
            throws
            -> [String]
        {
            guard
                FileManager.default
                    .fileExists(
                        atPath:
                            log.path
                    )
            else {
                return []
            }

            return try String(
                contentsOf:
                    log,
                encoding:
                    .utf8
            )
            .split(
                whereSeparator:
                    \.isNewline
            )
            .map(
                String.init
            )
        }

        var contract:
            RightClickNativeRegistrationBackend
                .Contract
        {
            .init(
                backendID:
                    "lease-fixture-native",
                scope:
                    "fixture",
                inspect:
                    .init(
                        executable:
                            executable.path,
                        arguments:
                            ["get"]
                    ),
                add:
                    .init(
                        executable:
                            executable.path,
                        arguments:
                            ["add"]
                    ),
                remove:
                    .init(
                        executable:
                            executable.path,
                        arguments:
                            ["remove"]
                    ),
                desiredInspectionFragments:
                    [
                        "RIGHTCLICK=DESIRED",
                    ],
                absenceMarkers:
                    [
                        "ABSENT",
                    ]
            )
        }
    }

    func testConfigureFreshlyInspectsImmediatelyBeforeNativeAdd()
        throws
    {
        let fixture =
            try Fixture()

        defer {
            fixture.cleanup()
        }

        try fixture.setState(
            nil
        )

        let plan =
            try RightClickNativeRegistrationBackend
                .plan(
                    contract:
                        fixture.contract,
                    disconnect:
                        false
                )

        XCTAssertEqual(
            plan.operation,
            "CONFIGURED"
        )

        XCTAssertTrue(
            plan.changed
        )

        fixture.clearLog()

        _ =
            try RightClickNativeRegistrationBackend
                .apply(
                    plan
                )

        let lines =
            try fixture.logLines()

        XCTAssertGreaterThanOrEqual(
            lines.count,
            3
        )

        XCTAssertEqual(
            Array(
                lines.prefix(3)
            ),
            [
                "get",
                "add",
                "get",
            ]
        )
    }

    func testConfigureFailsClosedIfAbsentPlanDriftsToConflictBeforeApply()
        throws
    {
        let fixture =
            try Fixture()

        defer {
            fixture.cleanup()
        }

        try fixture.setState(
            nil
        )

        let plan =
            try RightClickNativeRegistrationBackend
                .plan(
                    contract:
                        fixture.contract,
                    disconnect:
                        false
                )

        try fixture.setState(
            "conflict"
        )

        let before =
            try XCTUnwrap(
                fixture.stateBytes()
            )

        fixture.clearLog()

        XCTAssertThrowsError(
            try RightClickNativeRegistrationBackend
                .apply(
                    plan
                )
        )

        XCTAssertEqual(
            try fixture.stateBytes(),
            before,
            """
            A registration that appeared after preflight
            must remain byte-identical.
            """
        )

        let lines =
            try fixture.logLines()

        XCTAssertEqual(
            lines.first,
            "get"
        )

        XCTAssertFalse(
            lines.contains(
                "add"
            )
        )
    }

    func testDisconnectFreshlyInspectsImmediatelyBeforeNativeRemove()
        throws
    {
        let fixture =
            try Fixture()

        defer {
            fixture.cleanup()
        }

        try fixture.setState(
            "desired"
        )

        let plan =
            try RightClickNativeRegistrationBackend
                .plan(
                    contract:
                        fixture.contract,
                    disconnect:
                        true
                )

        XCTAssertEqual(
            plan.operation,
            "DISCONNECTED"
        )

        XCTAssertTrue(
            plan.changed
        )

        fixture.clearLog()

        _ =
            try RightClickNativeRegistrationBackend
                .apply(
                    plan
                )

        let lines =
            try fixture.logLines()

        XCTAssertGreaterThanOrEqual(
            lines.count,
            3
        )

        XCTAssertEqual(
            Array(
                lines.prefix(3)
            ),
            [
                "get",
                "remove",
                "get",
            ]
        )
    }

    func testDisconnectFailsClosedIfExactPlanDriftsToConflictBeforeApply()
        throws
    {
        let fixture =
            try Fixture()

        defer {
            fixture.cleanup()
        }

        try fixture.setState(
            "desired"
        )

        let plan =
            try RightClickNativeRegistrationBackend
                .plan(
                    contract:
                        fixture.contract,
                    disconnect:
                        true
                )

        try fixture.setState(
            "conflict"
        )

        let before =
            try XCTUnwrap(
                fixture.stateBytes()
            )

        fixture.clearLog()

        XCTAssertThrowsError(
            try RightClickNativeRegistrationBackend
                .apply(
                    plan
                )
        )

        XCTAssertEqual(
            try fixture.stateBytes(),
            before,
            """
            A registration changed after disconnect
            preflight must remain byte-identical.
            """
        )

        let lines =
            try fixture.logLines()

        XCTAssertEqual(
            lines.first,
            "get"
        )

        XCTAssertFalse(
            lines.contains(
                "remove"
            )
        )
    }
}
