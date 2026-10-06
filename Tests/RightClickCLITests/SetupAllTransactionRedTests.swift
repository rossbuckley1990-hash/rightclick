import Foundation
import XCTest

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@testable import RightClickCLI

final class SetupAllTransactionRedTests:
    XCTestCase
{
    private struct Fixture {
        let home: URL
        let executable: URL

        let cursorConfig: URL
        let originalCursorConfig: Data

        let claude: URL
        let claudeState: URL

        let codex: URL
        let codexState: URL
        let codexFailAdd: URL

        let log: URL

        init() throws {
            let fm =
                FileManager.default

            home =
                fm.temporaryDirectory
                    .resolvingSymlinksInPath()
                    .appendingPathComponent(
                        "rightclick-setup-all-red-"
                        + UUID().uuidString
                    )

            executable =
                home.appendingPathComponent(
                    "bin/rightclick"
                )

            cursorConfig =
                home.appendingPathComponent(
                    ".cursor/mcp.json"
                )

            claude =
                home.appendingPathComponent(
                    ".local/bin/claude"
                )

            claudeState =
                home.appendingPathComponent(
                    "claude-rightclick-state"
                )

            codex =
                home.appendingPathComponent(
                    ".local/bin/codex"
                )

            codexState =
                home.appendingPathComponent(
                    "codex-rightclick-state"
                )

            codexFailAdd =
                home.appendingPathComponent(
                    "codex-fail-add"
                )

            log =
                home.appendingPathComponent(
                    "client-invocations.log"
                )

            originalCursorConfig =
                Data(
                    """
                    {"keep":{"exact":true},"mcpServers":{"other":{"command":"preserve"}}}
                    """.utf8
                )

            try fm.createDirectory(
                at:
                    executable
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

            try fm.createDirectory(
                at:
                    cursorConfig
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

            try fm.createDirectory(
                at:
                    claude
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

            try fm.createDirectory(
                at:
                    home.appendingPathComponent(
                        "Applications/Cursor.app"
                    ),
                withIntermediateDirectories:
                    true
            )

            try Data(
                "fixture".utf8
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

            try originalCursorConfig
                .write(
                    to: cursorConfig
                )

            try writeClaude()
            try writeCodex()
        }

        func cleanup() {
            try? FileManager.default
                .removeItem(
                    at: home
                )
        }

        func setClaudeState(
            _ value: String?
        ) throws {
            if let value {
                try Data(
                    value.utf8
                )
                .write(
                    to: claudeState
                )
            } else {
                try? FileManager.default
                    .removeItem(
                        at: claudeState
                    )
            }
        }

        func setCodexState(
            _ value: String?
        ) throws {
            if let value {
                try Data(
                    value.utf8
                )
                .write(
                    to: codexState
                )
            } else {
                try? FileManager.default
                    .removeItem(
                        at: codexState
                    )
            }
        }

        func setCodexAddFailure(
            _ enabled: Bool
        ) throws {
            if enabled {
                try Data(
                    "fail".utf8
                )
                .write(
                    to: codexFailAdd
                )
            } else {
                try? FileManager.default
                    .removeItem(
                        at: codexFailAdd
                    )
            }
        }

        func cursorBytes() throws
            -> Data
        {
            try Data(
                contentsOf:
                    cursorConfig
            )
        }

        func cursorDirectoryListing()
            throws
            -> [String]
        {
            try FileManager.default
                .contentsOfDirectory(
                    atPath:
                        cursorConfig
                            .deletingLastPathComponent()
                            .path
                )
                .sorted()
        }

        private func writeClaude()
            throws
        {
            let script = """
            #!/bin/sh
            LOG="\(log.path)"
            STATE="\(claudeState.path)"
            RIGHTCLICK="\(executable.path)"

            printf 'claude %s\\n' "$*" >> "$LOG"

            if [ "$1" = "--version" ]; then
              echo "2.1.288 (Claude Code)"
              exit 0
            fi

            if [ "$1" != "mcp" ]; then
              echo "unsupported claude command" >&2
              exit 20
            fi

            case "$2" in
              get)
                if [ "$3" != "rightclick" ]; then
                  exit 21
                fi

                if [ ! -f "$STATE" ]; then
                  echo 'No MCP server named "rightclick". Run `claude mcp add` to add one.'
                  exit 1
                fi

                MODE="$(cat "$STATE")"

                if [ "$MODE" = "exact" ]; then
                  COMMAND="$RIGHTCLICK"
                else
                  COMMAND="/different/rightclick"
                fi

                echo "rightclick:"
                echo "  Scope: User config (available in all your projects)"
                echo "  Status: ✔ Connected"
                echo "  Type: stdio"
                echo "  Command: $COMMAND"
                echo "  Args: mcp"
                exit 0
                ;;

              list)
                if [ -f "$STATE" ]; then
                  MODE="$(cat "$STATE")"

                  if [ "$MODE" = "exact" ]; then
                    COMMAND="$RIGHTCLICK"
                  else
                    COMMAND="/different/rightclick"
                  fi

                  echo "rightclick: $COMMAND mcp - ✔ Connected"
                else
                  echo 'No MCP servers configured.'
                fi

                exit 0
                ;;

              add)
                if [ "$3" != "--scope" ] ||
                   [ "$4" != "user" ] ||
                   [ "$5" != "rightclick" ] ||
                   [ "$6" != "--" ] ||
                   [ "$7" != "$RIGHTCLICK" ] ||
                   [ "$8" != "mcp" ]; then
                  echo "unexpected claude add: $*" >&2
                  exit 22
                fi

                echo "exact" > "$STATE"
                echo "Added stdio MCP server rightclick"
                exit 0
                ;;

              remove)
                if [ "$3" != "--scope" ] ||
                   [ "$4" != "user" ] ||
                   [ "$5" != "rightclick" ]; then
                  echo "unexpected claude remove: $*" >&2
                  exit 23
                fi

                rm -f "$STATE"
                echo "Removed MCP server rightclick"
                exit 0
                ;;

              *)
                echo "unsupported claude mcp command" >&2
                exit 24
                ;;
            esac
            """

            try Data(
                script.utf8
            )
            .write(
                to: claude
            )

            try FileManager.default
                .setAttributes(
                    [
                        .posixPermissions:
                            0o700,
                    ],
                    ofItemAtPath:
                        claude.path
                )
        }

        private func writeCodex()
            throws
        {
            let script = """
            #!/bin/sh
            LOG="\(log.path)"
            STATE="\(codexState.path)"
            FAIL_ADD="\(codexFailAdd.path)"
            RIGHTCLICK="\(executable.path)"

            printf 'codex %s\\n' "$*" >> "$LOG"

            if [ "$1" = "--version" ]; then
              echo "codex-cli 0.159.3"
              exit 0
            fi

            if [ "$1" != "mcp" ]; then
              echo "unsupported codex command" >&2
              exit 20
            fi

            case "$2" in
              get)
                if [ "$3" != "rightclick" ] ||
                   [ "$4" != "--json" ]; then
                  echo "unexpected codex get: $*" >&2
                  exit 21
                fi

                if [ ! -f "$STATE" ]; then
                  echo "Error: No MCP server named 'rightclick' found." >&2
                  exit 1
                fi

                MODE="$(cat "$STATE")"

                if [ "$MODE" = "exact" ]; then
                  COMMAND="$RIGHTCLICK"
                else
                  COMMAND="/usr/bin/false"
                fi

                cat <<JSON
            {
              "name": "rightclick",
              "enabled": true,
              "disabled_reason": null,
              "transport": {
                "type": "stdio",
                "command": "$COMMAND",
                "args": ["mcp"],
                "env": null,
                "env_vars": [],
                "cwd": null
              },
              "enabled_tools": null,
              "disabled_tools": null,
              "startup_timeout_sec": null,
              "tool_timeout_sec": null
            }
            JSON
                exit 0
                ;;

              list)
                if [ "$3" != "--json" ]; then
                  echo "unexpected codex list: $*" >&2
                  exit 22
                fi

                if [ ! -f "$STATE" ]; then
                  echo '[]'
                  exit 0
                fi

                MODE="$(cat "$STATE")"

                if [ "$MODE" = "exact" ]; then
                  COMMAND="$RIGHTCLICK"
                else
                  COMMAND="/usr/bin/false"
                fi

                cat <<JSON
            [
              {
                "name": "rightclick",
                "enabled": true,
                "disabled_reason": null,
                "transport": {
                  "type": "stdio",
                  "command": "$COMMAND",
                  "args": ["mcp"],
                  "env": null,
                  "env_vars": [],
                  "cwd": null
                }
              }
            ]
            JSON
                exit 0
                ;;

              add)
                if [ "$3" != "rightclick" ] ||
                   [ "$4" != "--" ] ||
                   [ "$5" != "$RIGHTCLICK" ] ||
                   [ "$6" != "mcp" ]; then
                  echo "unexpected codex add: $*" >&2
                  exit 23
                fi

                if [ -f "$FAIL_ADD" ]; then
                  echo "synthetic codex add failure" >&2
                  exit 42
                fi

                echo "exact" > "$STATE"
                echo "Added global MCP server 'rightclick'."
                exit 0
                ;;

              remove)
                if [ "$3" != "rightclick" ]; then
                  echo "unexpected codex remove: $*" >&2
                  exit 24
                fi

                rm -f "$STATE"
                echo "Removed global MCP server 'rightclick'."
                exit 0
                ;;

              *)
                echo "unsupported codex mcp command" >&2
                exit 25
                ;;
            esac
            """

            try Data(
                script.utf8
            )
            .write(
                to: codex
            )

            try FileManager.default
                .setAttributes(
                    [
                        .posixPermissions:
                            0o700,
                    ],
                    ofItemAtPath:
                        codex.path
                )
        }
    }

    private func withConfigOverrides<T>(
        fixture: Fixture,
        _ body: () throws -> T
    ) rethrows -> T {
        let priorCodex =
            getenv(
                "CODEX_HOME"
            )
            .map {
                String(
                    cString: $0
                )
            }

        let priorClaude =
            getenv(
                "CLAUDE_CONFIG_DIR"
            )
            .map {
                String(
                    cString: $0
                )
            }

        setenv(
            "CODEX_HOME",
            fixture.home
                .appendingPathComponent(
                    ".codex"
                )
                .path,
            1
        )

        setenv(
            "CLAUDE_CONFIG_DIR",
            fixture.home
                .appendingPathComponent(
                    ".claude-isolated"
                )
                .path,
            1
        )

        defer {
            if let priorCodex {
                setenv(
                    "CODEX_HOME",
                    priorCodex,
                    1
                )
            } else {
                unsetenv(
                    "CODEX_HOME"
                )
            }

            if let priorClaude {
                setenv(
                    "CLAUDE_CONFIG_DIR",
                    priorClaude,
                    1
                )
            } else {
                unsetenv(
                    "CLAUDE_CONFIG_DIR"
                )
            }
        }

        return try body()
    }

    private func payload(
        _ output: [String]
    ) throws
        -> [String: Any]
    {
        XCTAssertEqual(
            output.count,
            1,
            "setup --all must emit one aggregate result"
        )

        let line =
            try XCTUnwrap(
                output.last
            )

        let data =
            try XCTUnwrap(
                line.data(
                    using: .utf8
                )
            )

        return try XCTUnwrap(
            JSONSerialization
                .jsonObject(
                    with: data
                )
            as? [String: Any]
        )
    }

    private func detectedClients(
        _ payload: [String: Any]
    ) -> [String] {
        payload[
            "detectedClients"
        ]
        as? [String]
        ?? []
    }

    private func clientRecord(
        _ payload: [String: Any],
        id: String
    ) -> [String: Any]? {
        guard let clients =
            payload["clients"]
            as? [[String: Any]]
        else {
            return nil
        }

        return clients.first {
            $0["client"]
                as? String
                == id
        }
    }

    func testSetupAllOptionIsExplicitAndMutuallyExclusiveWithClient() throws {
        XCTAssertNoThrow(
            try RightClickLocalOnboarding
                .Options([
                    "--all",
                    "--dry-run",
                ])
        )

        XCTAssertNoThrow(
            try RightClickLocalOnboarding
                .Options([
                    "--all",
                    "--yes",
                    "--json",
                ])
        )

        XCTAssertThrowsError(
            try RightClickLocalOnboarding
                .Options([
                    "--all",
                    "--client",
                    "cursor",
                ])
        )

        XCTAssertTrue(
            RightClickLocalOnboarding
                .usage
                .contains(
                    "rightclick setup --all"
                )
        )
    }

    func testSetupAllDryRunPreflightsEveryDetectedClientWithoutMutation() throws {
        let fixture =
            try Fixture()

        defer {
            fixture.cleanup()
        }

        let beforeCursor =
            try fixture.cursorBytes()

        let beforeDirectory =
            try fixture
                .cursorDirectoryListing()

        var output:
            [String] = []

        var probeCount = 0

        let code =
            withConfigOverrides(
                fixture: fixture
            ) {
                RightClickLocalOnboarding
                    .run(
                        args: [
                            "--all",
                            "--dry-run",
                            "--json",
                        ],
                        executable:
                            fixture.executable.path,
                        home:
                            fixture.home,
                        interactive:
                            false,
                        output: {
                            output.append($0)
                        },
                        probe: {
                            probeCount += 1
                            return "SHOULD_NOT_RUN"
                        }
                    )
            }

        XCTAssertEqual(
            code,
            0
        )

        XCTAssertEqual(
            probeCount,
            0
        )

        XCTAssertEqual(
            try fixture.cursorBytes(),
            beforeCursor
        )

        XCTAssertEqual(
            try fixture
                .cursorDirectoryListing(),
            beforeDirectory
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture
                            .claudeState
                            .path
                )
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture
                            .codexState
                            .path
                )
        )

        let result =
            try payload(
                output
            )

        XCTAssertEqual(
            result["client"]
                as? String,
            "all"
        )

        XCTAssertEqual(
            result["status"]
                as? String,
            "DRY_RUN"
        )

        XCTAssertEqual(
            detectedClients(
                result
            ),
            [
                "cursor",
                "claude",
                "codex",
            ]
        )

        for id in [
            "cursor",
            "claude",
            "codex",
        ] {
            let record =
                try XCTUnwrap(
                    clientRecord(
                        result,
                        id: id
                    )
                )

            XCTAssertEqual(
                record["operation"]
                    as? String,
                "CONFIGURED"
            )
        }
    }

    func testSetupAllRequiresOneConsentBeforeAnyMutation() throws {
        let fixture =
            try Fixture()

        defer {
            fixture.cleanup()
        }

        let beforeCursor =
            try fixture.cursorBytes()

        let beforeDirectory =
            try fixture
                .cursorDirectoryListing()

        var output:
            [String] = []

        var probeCount = 0

        let code =
            withConfigOverrides(
                fixture: fixture
            ) {
                RightClickLocalOnboarding
                    .run(
                        args: [
                            "--all",
                            "--json",
                        ],
                        executable:
                            fixture.executable.path,
                        home:
                            fixture.home,
                        interactive:
                            false,
                        output: {
                            output.append($0)
                        },
                        probe: {
                            probeCount += 1
                            return "SHOULD_NOT_RUN"
                        }
                    )
            }

        XCTAssertEqual(
            code,
            3
        )

        XCTAssertEqual(
            probeCount,
            0
        )

        XCTAssertEqual(
            try fixture.cursorBytes(),
            beforeCursor
        )

        XCTAssertEqual(
            try fixture
                .cursorDirectoryListing(),
            beforeDirectory
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture
                            .claudeState
                            .path
                )
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture
                            .codexState
                            .path
                )
        )

        let result =
            try payload(
                output
            )

        XCTAssertEqual(
            result["client"]
                as? String,
            "all"
        )

        XCTAssertEqual(
            result["status"]
                as? String,
            "CONSENT_REQUIRED"
        )

        XCTAssertEqual(
            detectedClients(
                result
            ),
            [
                "cursor",
                "claude",
                "codex",
            ]
        )
    }

    func testSetupAllConfiguresEveryDetectedClientAfterOneProbe() throws {
        let fixture =
            try Fixture()

        defer {
            fixture.cleanup()
        }

        var output:
            [String] = []

        var probeCount = 0

        let code =
            withConfigOverrides(
                fixture: fixture
            ) {
                RightClickLocalOnboarding
                    .run(
                        args: [
                            "--all",
                            "--yes",
                            "--json",
                        ],
                        executable:
                            fixture.executable.path,
                        home:
                            fixture.home,
                        interactive:
                            false,
                        output: {
                            output.append($0)
                        },
                        probe: {
                            probeCount += 1
                            return "PASS: aggregate local probe"
                        }
                    )
            }

        XCTAssertEqual(
            code,
            0
        )

        XCTAssertEqual(
            probeCount,
            1,
            "the shared RIGHTCLICK binary should be probed once"
        )

        let root =
            try XCTUnwrap(
                JSONSerialization
                    .jsonObject(
                        with:
                            fixture.cursorBytes()
                    )
                as? [String: Any]
            )

        let servers =
            try XCTUnwrap(
                root["mcpServers"]
                as? [String: Any]
            )

        let rightclick =
            try XCTUnwrap(
                servers["rightclick"]
                as? [String: Any]
            )

        XCTAssertEqual(
            rightclick["type"]
                as? String,
            "stdio"
        )

        XCTAssertEqual(
            rightclick["command"]
                as? String,
            fixture.executable.path
        )

        XCTAssertEqual(
            rightclick["args"]
                as? [String],
            ["mcp"]
        )

        XCTAssertEqual(
            try String(
                contentsOf:
                    fixture.claudeState,
                encoding: .utf8
            )
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            ),
            "exact"
        )

        XCTAssertEqual(
            try String(
                contentsOf:
                    fixture.codexState,
                encoding: .utf8
            )
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            ),
            "exact"
        )

        let result =
            try payload(
                output
            )

        XCTAssertEqual(
            result["client"]
                as? String,
            "all"
        )

        XCTAssertEqual(
            result["status"]
                as? String,
            "CONFIGURED"
        )

        XCTAssertEqual(
            result["configurationChanged"]
                as? String,
            "true"
        )

        XCTAssertEqual(
            detectedClients(
                result
            ),
            [
                "cursor",
                "claude",
                "codex",
            ]
        )

        let cursor =
            try XCTUnwrap(
                clientRecord(
                    result,
                    id: "cursor"
                )
            )

        let claude =
            try XCTUnwrap(
                clientRecord(
                    result,
                    id: "claude"
                )
            )

        let codex =
            try XCTUnwrap(
                clientRecord(
                    result,
                    id: "codex"
                )
            )

        XCTAssertEqual(
            cursor["mcpConnection"]
                as? String,
            "NOT_VERIFIED"
        )

        XCTAssertEqual(
            claude["mcpConnection"]
                as? String,
            "CONNECTED"
        )

        XCTAssertEqual(
            codex["mcpConnection"]
                as? String,
            "NOT_VERIFIED"
        )
    }

    func testSetupAllPreflightConflictMutatesNothing() throws {
        let fixture =
            try Fixture()

        defer {
            fixture.cleanup()
        }

        try fixture
            .setCodexState(
                "conflict"
            )

        let beforeCursor =
            try fixture.cursorBytes()

        let beforeDirectory =
            try fixture
                .cursorDirectoryListing()

        let beforeCodex =
            try Data(
                contentsOf:
                    fixture.codexState
            )

        var output:
            [String] = []

        var probeCount = 0

        let code =
            withConfigOverrides(
                fixture: fixture
            ) {
                RightClickLocalOnboarding
                    .run(
                        args: [
                            "--all",
                            "--yes",
                            "--json",
                        ],
                        executable:
                            fixture.executable.path,
                        home:
                            fixture.home,
                        interactive:
                            false,
                        output: {
                            output.append($0)
                        },
                        probe: {
                            probeCount += 1
                            return "SHOULD_NOT_RUN"
                        }
                    )
            }

        XCTAssertEqual(
            code,
            1
        )

        XCTAssertEqual(
            probeCount,
            0,
            "all plans must succeed before the shared probe or mutation"
        )

        XCTAssertEqual(
            try fixture.cursorBytes(),
            beforeCursor
        )

        XCTAssertEqual(
            try fixture
                .cursorDirectoryListing(),
            beforeDirectory
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture
                            .claudeState
                            .path
                )
        )

        XCTAssertEqual(
            try Data(
                contentsOf:
                    fixture.codexState
            ),
            beforeCodex
        )

        let result =
            try payload(
                output
            )

        XCTAssertEqual(
            result["status"]
                as? String,
            "FAILED"
        )

        XCTAssertEqual(
            result["failedClient"]
                as? String,
            "codex"
        )

        XCTAssertEqual(
            result["rollbackStatus"]
                as? String,
            "NOT_REQUIRED"
        )

        let error =
            (
                result["error"]
                as? String
                ?? ""
            )
            .lowercased()

        XCTAssertTrue(
            error.contains(
                "different rightclick"
            )
        )
    }

    func testSetupAllApplyFailureRollsBackEarlierClientsExactly() throws {
        let fixture =
            try Fixture()

        defer {
            fixture.cleanup()
        }

        try fixture
            .setCodexAddFailure(
                true
            )

        let beforeCursor =
            try fixture.cursorBytes()

        let beforeDirectory =
            try fixture
                .cursorDirectoryListing()

        var output:
            [String] = []

        var probeCount = 0

        let code =
            withConfigOverrides(
                fixture: fixture
            ) {
                RightClickLocalOnboarding
                    .run(
                        args: [
                            "--all",
                            "--yes",
                            "--json",
                        ],
                        executable:
                            fixture.executable.path,
                        home:
                            fixture.home,
                        interactive:
                            false,
                        output: {
                            output.append($0)
                        },
                        probe: {
                            probeCount += 1
                            return "PASS: aggregate local probe"
                        }
                    )
            }

        XCTAssertEqual(
            code,
            1
        )

        XCTAssertEqual(
            probeCount,
            1
        )

        XCTAssertEqual(
            try fixture.cursorBytes(),
            beforeCursor,
            "Cursor bytes must be restored exactly"
        )

        XCTAssertEqual(
            try fixture
                .cursorDirectoryListing(),
            beforeDirectory,
            "transaction-created backups must not remain after rollback"
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture
                            .claudeState
                            .path
                ),
            "Claude registration created earlier in the transaction must be removed"
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture
                            .codexState
                            .path
                ),
            "failed Codex add must not leave a registration"
        )

        let result =
            try payload(
                output
            )

        XCTAssertEqual(
            result["status"]
                as? String,
            "FAILED"
        )

        XCTAssertEqual(
            result["failedClient"]
                as? String,
            "codex"
        )

        XCTAssertEqual(
            result["rollbackStatus"]
                as? String,
            "RESTORED"
        )

        let error =
            (
                result["error"]
                as? String
                ?? ""
            )
            .lowercased()

        XCTAssertTrue(
            error.contains(
                "native registration failed"
            )
        )
    }
}
