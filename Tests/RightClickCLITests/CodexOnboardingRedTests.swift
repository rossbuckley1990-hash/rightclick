import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import RightClickCLI

final class CodexOnboardingRedTests: XCTestCase {
    private struct Fixture {
        let home: URL
        let executable: URL
        let codex: URL
        let log: URL
        let state: URL
        let codexHome: URL
        let codexConfig: URL
        let originalCodexConfig: Data

        init() throws {
            let fm = FileManager.default

            home = fm.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    "rightclick-codex-red-\(UUID().uuidString)"
                )

            executable = home
                .appendingPathComponent("bin/rightclick")

            codex = home
                .appendingPathComponent(".local/bin/codex")

            log = home
                .appendingPathComponent("codex-invocations.log")

            state = home
                .appendingPathComponent("codex-rightclick-state")

            codexHome = home
                .appendingPathComponent("isolated-codex-home")

            codexConfig = codexHome
                .appendingPathComponent("config.toml")

            originalCodexConfig = Data(
                """
                model = "preserve-me"

                [unrelated]
                keep = true
                """.utf8
            )

            try fm.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try fm.createDirectory(
                at: codex.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try fm.createDirectory(
                at: codexHome,
                withIntermediateDirectories: true
            )

            try Data("fixture".utf8)
                .write(to: executable)

            try fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )

            try originalCodexConfig
                .write(to: codexConfig)

            let script = """
            #!/bin/sh
            LOG="\(log.path)"
            STATE="\(state.path)"
            RIGHTCLICK="\(executable.path)"

            printf '%s\\n' "$*" >> "$LOG"

            if [ "$1" = "--version" ]; then
              echo "codex-cli 0.159.3"
              exit 0
            fi

            if [ "$1" != "mcp" ]; then
              echo "unsupported fake codex command" >&2
              exit 20
            fi

            case "$2" in
              get)
                if [ "$3" != "rightclick" ] ||
                   [ "$4" != "--json" ]; then
                  echo "unexpected get contract: $*" >&2
                  exit 21
                fi

                if [ ! -f "$STATE" ]; then
                  echo "Error: No MCP server named 'rightclick' found." >&2
                  exit 1
                fi

                MODE="$(cat "$STATE")"

                case "$MODE" in
                  exact)
                    COMMAND="$RIGHTCLICK"
                    ARGS='"mcp"'
                    ;;
                  conflict-command)
                    COMMAND="/different/rightclick"
                    ARGS='"mcp"'
                    ;;
                  conflict-args)
                    COMMAND="$RIGHTCLICK"
                    ARGS='"mcp","extra"'
                    ;;
                  *)
                    echo "unknown fake state: $MODE" >&2
                    exit 22
                    ;;
                esac

                cat <<JSON
            {
              "name": "rightclick",
              "enabled": true,
              "disabled_reason": null,
              "transport": {
                "type": "stdio",
                "command": "$COMMAND",
                "args": [$ARGS],
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
                  echo "unexpected list contract: $*" >&2
                  exit 23
                fi

                if [ ! -f "$STATE" ]; then
                  echo '[]'
                  exit 0
                fi

                MODE="$(cat "$STATE")"

                case "$MODE" in
                  exact)
                    COMMAND="$RIGHTCLICK"
                    ARGS='"mcp"'
                    ;;
                  conflict-command)
                    COMMAND="/different/rightclick"
                    ARGS='"mcp"'
                    ;;
                  conflict-args)
                    COMMAND="$RIGHTCLICK"
                    ARGS='"mcp","extra"'
                    ;;
                  *)
                    exit 24
                    ;;
                esac

                cat <<JSON
            [
              {
                "name": "rightclick",
                "enabled": true,
                "disabled_reason": null,
                "transport": {
                  "type": "stdio",
                  "command": "$COMMAND",
                  "args": [$ARGS],
                  "env": null,
                  "env_vars": [],
                  "cwd": null
                },
                "startup_timeout_sec": null,
                "tool_timeout_sec": null,
                "auth_status": "unsupported"
              }
            ]
            JSON
                exit 0
                ;;

              add)
                if [ "$3" != "rightclick" ] ||
                   [ "$4" != "--" ] ||
                   [ "$5" != "$RIGHTCLICK" ] ||
                   [ "$6" != "mcp" ] ||
                   [ -n "$7" ]; then
                  echo "unexpected add contract: $*" >&2
                  exit 25
                fi

                echo "exact" > "$STATE"
                echo "Added global MCP server 'rightclick'."
                exit 0
                ;;

              remove)
                if [ "$3" != "rightclick" ] ||
                   [ -n "$4" ]; then
                  echo "unexpected remove contract: $*" >&2
                  exit 26
                fi

                rm -f "$STATE"
                echo "Removed global MCP server 'rightclick'."
                exit 0
                ;;

              *)
                echo "unsupported fake codex mcp command: $*" >&2
                exit 27
                ;;
            esac
            """

            try Data(script.utf8)
                .write(to: codex)

            try fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: codex.path
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

        func assertCodexConfigUnchanged(
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            XCTAssertEqual(
                try Data(contentsOf: codexConfig),
                originalCodexConfig,
                file: file,
                line: line
            )
        }
    }

    private func withCodexHome<T>(
        _ fixture: Fixture,
        _ body: () throws -> T
    ) rethrows -> T {
        let prior = getenv("CODEX_HOME")
            .map { String(cString: $0) }

        setenv(
            "CODEX_HOME",
            fixture.codexHome.path,
            1
        )

        defer {
            if let prior {
                setenv(
                    "CODEX_HOME",
                    prior,
                    1
                )
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        return try body()
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

    func testOptionsAcceptCodexAsThirdClient() throws {
        let options =
            try RightClickLocalOnboarding.Options([
                "--client",
                "codex",
                "--dry-run",
            ])

        XCTAssertEqual(
            options.client,
            "codex"
        )

        XCTAssertTrue(options.dryRun)

        XCTAssertTrue(
            RightClickLocalOnboarding
                .usage
                .contains(
                    "rightclick setup --client codex"
                )
        )
    }

    func testCodexDryRunUsesNativeInspectionAndNeverMutates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var output: [String] = []
        var probeCount = 0

        let code = withCodexHome(fixture) {
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "codex",
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

        XCTAssertEqual(code, 0)
        XCTAssertEqual(probeCount, 0)

        try fixture
            .assertCodexConfigUnchanged()

        let calls = fixture.invocations()

        XCTAssertTrue(
            calls.contains(
                "mcp get rightclick --json"
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

        let result = try payload(output)

        XCTAssertEqual(
            result["client"],
            "codex"
        )

        XCTAssertEqual(
            result["status"],
            "DRY_RUN"
        )

        XCTAssertEqual(
            result["configuration"],
            fixture.codexConfig.path
        )

        XCTAssertEqual(
            result["registrationBackend"],
            "codex-native-cli"
        )

        XCTAssertEqual(
            result["registrationScope"],
            "global"
        )

        XCTAssertEqual(
            result["mcpConnection"],
            "NOT_VERIFIED"
        )
    }

    func testCodexNonInteractiveRequiresConsentWithoutMutation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var output: [String] = []
        var probeCount = 0

        let code = withCodexHome(fixture) {
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "codex",
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

        XCTAssertEqual(code, 3)
        XCTAssertEqual(probeCount, 0)

        let calls = fixture.invocations()

        XCTAssertTrue(
            calls.contains(
                "mcp get rightclick --json"
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
            .assertCodexConfigUnchanged()

        let result = try payload(output)

        XCTAssertEqual(
            result["status"],
            "CONSENT_REQUIRED"
        )
    }

    func testCodexYesUsesNativeGlobalBackendWithoutFalseConnectionClaim() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var output: [String] = []

        let code = withCodexHome(fixture) {
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "codex",
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
        }

        XCTAssertEqual(code, 0)

        let calls = fixture.invocations()

        XCTAssertTrue(
            calls.contains(
                "mcp add rightclick -- \(fixture.executable.path) mcp"
            )
        )

        XCTAssertGreaterThanOrEqual(
            calls.filter {
                $0 == "mcp get rightclick --json"
            }.count,
            2
        )

        try fixture
            .assertCodexConfigUnchanged()

        let result = try payload(output)

        XCTAssertEqual(
            result["client"],
            "codex"
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
            "codex-native-cli"
        )

        XCTAssertEqual(
            result["registrationScope"],
            "global"
        )

        // Codex 0.159.3 get/list prove configuration,
        // not a live MCP transport connection.
        XCTAssertEqual(
            result["mcpConnection"],
            "NOT_VERIFIED"
        )
    }

    func testCodexExactExistingRegistrationIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.setState("exact")

        var output: [String] = []

        let code = withCodexHome(fixture) {
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "codex",
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
        }

        XCTAssertEqual(code, 0)

        let calls = fixture.invocations()

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
            .assertCodexConfigUnchanged()

        let result = try payload(output)

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
            "NOT_VERIFIED"
        )
    }

    func testCodexConflictingCommandFailsClosedBeforeNativeAdd() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.setState(
            "conflict-command"
        )

        var output: [String] = []

        let code = withCodexHome(fixture) {
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "codex",
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
        }

        XCTAssertEqual(code, 1)

        let calls = fixture.invocations()

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

        XCTAssertTrue(
            FileManager.default
                .fileExists(
                    atPath:
                        fixture.state.path
                )
        )

        try fixture
            .assertCodexConfigUnchanged()

        let result = try payload(output)

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

    func testCodexSameCommandDifferentArgsAlsoFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.setState(
            "conflict-args"
        )

        var output: [String] = []

        let code = withCodexHome(fixture) {
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "codex",
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
        }

        XCTAssertEqual(code, 1)

        let calls = fixture.invocations()

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
            .assertCodexConfigUnchanged()

        let result = try payload(output)

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

    func testCodexDisconnectUsesNativeGlobalRemove() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.setState("exact")

        var output: [String] = []

        let code = withCodexHome(fixture) {
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "codex",
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
        }

        XCTAssertEqual(code, 0)

        let calls = fixture.invocations()

        XCTAssertTrue(
            calls.contains(
                "mcp remove rightclick"
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
            .assertCodexConfigUnchanged()

        let result = try payload(output)

        XCTAssertEqual(
            result["status"],
            "DISCONNECTED"
        )

        XCTAssertEqual(
            result["configurationChanged"],
            "true"
        )
    }

    func testCodexDisconnectRefusesConflictingRegistration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.setState(
            "conflict-command"
        )

        var output: [String] = []

        let code = withCodexHome(fixture) {
            RightClickLocalOnboarding.run(
                args: [
                    "--client",
                    "codex",
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
        }

        XCTAssertEqual(code, 1)

        let calls = fixture.invocations()

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
            .assertCodexConfigUnchanged()
    }
}
