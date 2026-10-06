import Foundation
import XCTest
@testable import RightClickCLI

final class ClaudeOnboardingRedTests: XCTestCase {
    private struct Fixture {
        let home: URL
        let executable: URL
        let claude: URL
        let log: URL
        let state: URL
        let claudeConfig: URL
        let originalClaudeConfig: Data

        init() throws {
            let fm = FileManager.default

            home = fm.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    "rightclick-claude-red-\(UUID().uuidString)"
                )

            executable = home
                .appendingPathComponent("bin/rightclick")

            claude = home
                .appendingPathComponent(".local/bin/claude")

            log = home
                .appendingPathComponent("claude-invocations.log")

            state = home
                .appendingPathComponent("claude-rightclick-state")

            claudeConfig = home
                .appendingPathComponent(".claude.json")

            originalClaudeConfig = Data(
                #"{"mcpServers":{"other":{"command":"preserve"}},"unrelated":{"keep":true}}"#
                    .utf8
            )

            try fm.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try fm.createDirectory(
                at: claude.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try Data("fixture".utf8)
                .write(to: executable)

            try fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )

            try originalClaudeConfig
                .write(to: claudeConfig)

            let script = """
            #!/bin/sh
            LOG="\(log.path)"
            STATE="\(state.path)"
            RIGHTCLICK="\(executable.path)"

            printf '%s\\n' "$*" >> "$LOG"

            if [ "$1" = "--version" ]; then
              echo "2.1.288 (Claude Code)"
              exit 0
            fi

            if [ "$1" != "mcp" ]; then
              echo "unsupported fake claude command" >&2
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

                  echo "Checking MCP server health…"
                  echo
                  echo "rightclick: $COMMAND mcp - ✔ Connected"
                else
                  echo 'No MCP servers configured. Use `claude mcp add` to add a server.'
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
                  echo "unexpected add contract: $*" >&2
                  exit 22
                fi

                echo "exact" > "$STATE"
                echo "Added stdio MCP server rightclick with command: $RIGHTCLICK mcp to user config"
                exit 0
                ;;

              remove)
                if [ "$3" != "--scope" ] ||
                   [ "$4" != "user" ] ||
                   [ "$5" != "rightclick" ]; then
                  echo "unexpected remove contract: $*" >&2
                  exit 23
                fi

                rm -f "$STATE"
                echo "Removed MCP server rightclick from user config"
                exit 0
                ;;

              *)
                echo "unsupported fake claude mcp command: $*" >&2
                exit 24
                ;;
            esac
            """

            try Data(script.utf8)
                .write(to: claude)

            try fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: claude.path
            )
        }

        func cleanup() {
            try? FileManager.default
                .removeItem(at: home)
        }

        func setState(_ value: String?) throws {
            if let value {
                try Data(value.utf8)
                    .write(to: state)
            } else {
                try? FileManager.default
                    .removeItem(at: state)
            }
        }

        func invocations() -> [String] {
            guard
                let text = try? String(
                    contentsOf: log,
                    encoding: .utf8
                )
            else {
                return []
            }

            return text
                .split(separator: "\n")
                .map(String.init)
        }

        func resetLog() throws {
            try? FileManager.default
                .removeItem(at: log)
        }

        func assertClaudeConfigUnchanged(
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            XCTAssertEqual(
                try Data(contentsOf: claudeConfig),
                originalClaudeConfig,
                file: file,
                line: line
            )
        }
    }

    private func payload(
        _ lines: [String]
    ) throws -> [String: String] {
        let last = try XCTUnwrap(lines.last)

        let data = try XCTUnwrap(
            last.data(using: .utf8)
        )

        return try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: data
            )
            as? [String: String]
        )
    }

    func testOptionsAcceptClaudeAsSecondClient() throws {
        let options =
            try RightClickLocalOnboarding.Options([
                "--client",
                "claude",
                "--dry-run",
            ])

        XCTAssertEqual(
            options.client,
            "claude"
        )

        XCTAssertTrue(
            options.dryRun
        )

        XCTAssertTrue(
            RightClickLocalOnboarding
                .usage
                .contains(
                    "rightclick setup --client claude"
                )
        )
    }

    func testClaudeDryRunUsesNativeInspectionAndNeverMutates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var output: [String] = []
        var probeCount = 0

        let code =
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "claude",
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

        XCTAssertEqual(code, 0)
        XCTAssertEqual(probeCount, 0)

        try fixture
            .assertClaudeConfigUnchanged()

        let calls =
            fixture.invocations()

        XCTAssertTrue(
            calls.contains(
                "mcp get rightclick"
            )
        )

        XCTAssertFalse(
            calls.contains {
                $0.contains("mcp add")
            }
        )

        XCTAssertFalse(
            calls.contains {
                $0.contains("mcp remove")
            }
        )

        let result =
            try payload(output)

        XCTAssertEqual(
            result["client"],
            "claude"
        )

        XCTAssertEqual(
            result["status"],
            "DRY_RUN"
        )

        XCTAssertEqual(
            result["registrationBackend"],
            "claude-native-cli"
        )

        XCTAssertEqual(
            result["registrationScope"],
            "user"
        )

        XCTAssertEqual(
            result["mcpConnection"],
            "NOT_VERIFIED"
        )
    }

    func testClaudeNonInteractiveRequiresConsentWithoutNativeMutation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var output: [String] = []
        var probeCount = 0

        let code =
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "claude",
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

        XCTAssertEqual(code, 3)
        XCTAssertEqual(probeCount, 0)

        let calls =
            fixture.invocations()

        XCTAssertTrue(
            calls.contains(
                "mcp get rightclick"
            )
        )

        XCTAssertFalse(
            calls.contains {
                $0.contains("mcp add")
            }
        )

        XCTAssertFalse(
            calls.contains {
                $0.contains("mcp remove")
            }
        )

        try fixture
            .assertClaudeConfigUnchanged()

        let result =
            try payload(output)

        XCTAssertEqual(
            result["status"],
            "CONSENT_REQUIRED"
        )
    }

    func testClaudeYesUsesFrozenNativeUserScopeBackendAndVerifiesConnection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var output: [String] = []

        let code =
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "claude",
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
                    "PASS: local probe"
                }
            )

        XCTAssertEqual(code, 0)

        let calls =
            fixture.invocations()

        XCTAssertTrue(
            calls.contains(
                "mcp get rightclick"
            )
        )

        XCTAssertTrue(
            calls.contains(
                "mcp add --scope user rightclick -- \(fixture.executable.path) mcp"
            )
        )

        XCTAssertTrue(
            calls.contains(
                "mcp list"
            )
        )

        try fixture
            .assertClaudeConfigUnchanged()

        let result =
            try payload(output)

        XCTAssertEqual(
            result["client"],
            "claude"
        )

        XCTAssertEqual(
            result["status"],
            "CONFIGURED"
        )

        XCTAssertEqual(
            result["configurationChanged"],
            "true"
        )

        XCTAssertEqual(
            result["registrationBackend"],
            "claude-native-cli"
        )

        XCTAssertEqual(
            result["registrationScope"],
            "user"
        )

        XCTAssertEqual(
            result["mcpConnection"],
            "CONNECTED"
        )
    }

    func testClaudeExactExistingRegistrationIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture
            .setState("exact")

        var output: [String] = []

        let code =
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "claude",
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
                    "PASS: local probe"
                }
            )

        XCTAssertEqual(code, 0)

        let calls =
            fixture.invocations()

        XCTAssertFalse(
            calls.contains {
                $0.contains("mcp add")
            }
        )

        XCTAssertTrue(
            calls.contains(
                "mcp list"
            )
        )

        try fixture
            .assertClaudeConfigUnchanged()

        let result =
            try payload(output)

        XCTAssertEqual(
            result["status"],
            "ALREADY_CONFIGURED"
        )

        XCTAssertEqual(
            result["configurationChanged"],
            "false"
        )

        XCTAssertEqual(
            result["mcpConnection"],
            "CONNECTED"
        )
    }

    func testClaudeConflictingRegistrationFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture
            .setState("conflict")

        var output: [String] = []

        let code =
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "claude",
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
                    "SHOULD_NOT_RUN"
                }
            )

        XCTAssertEqual(code, 1)

        let calls =
            fixture.invocations()

        XCTAssertFalse(
            calls.contains {
                $0.contains("mcp add")
            }
        )

        XCTAssertFalse(
            calls.contains {
                $0.contains("mcp remove")
            }
        )

        try fixture
            .assertClaudeConfigUnchanged()

        let result =
            try payload(output)

        XCTAssertEqual(
            result["status"],
            "FAILED"
        )

        XCTAssertTrue(
            result["error"]?
                .lowercased()
                .contains("different rightclick")
            ?? false
        )
    }

    func testClaudeDisconnectUsesNativeUserScopeRemove() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture
            .setState("exact")

        var output: [String] = []

        let code =
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "claude",
                    "--disconnect",
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
                    "SHOULD_NOT_RUN"
                }
            )

        XCTAssertEqual(code, 0)

        let calls =
            fixture.invocations()

        XCTAssertTrue(
            calls.contains(
                "mcp remove --scope user rightclick"
            )
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture.state.path
                )
        )

        try fixture
            .assertClaudeConfigUnchanged()

        let result =
            try payload(output)

        XCTAssertEqual(
            result["status"],
            "DISCONNECTED"
        )

        XCTAssertEqual(
            result["configurationChanged"],
            "true"
        )
    }

    func testClaudeDisconnectRefusesConflictingRegistration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture
            .setState("conflict")

        var output: [String] = []

        let code =
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "claude",
                    "--disconnect",
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
                    "SHOULD_NOT_RUN"
                }
            )

        XCTAssertEqual(code, 1)

        let calls =
            fixture.invocations()

        XCTAssertFalse(
            calls.contains {
                $0.contains("mcp remove")
            }
        )

        XCTAssertTrue(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture.state.path
                )
        )

        try fixture
            .assertClaudeConfigUnchanged()
    }
}
