import Foundation

struct RightClickClaudeClientAdapter:
    RightClickClientAdapter
{
    let id = "claude"
    let displayName = "Claude Code"

    let setupNotice =
        "Claude Code will use its native user-scope "
        + "MCP registration. RIGHTCLICK does not write "
        + "Claude JSON directly."

    func nextMessage(
        disconnect: Bool
    ) -> String {
        if disconnect {
            return "Claude Code no longer has the "
                + "RIGHTCLICK user-scope MCP registration."
        }

        return "Claude Code reports RIGHTCLICK connected. "
            + "Start a new Claude Code session and ask "
            + "it to use RIGHTCLICK."
    }

    func detected(
        home: URL,
        applications: URL
    ) -> Bool {
        claudeExecutable(
            home: home
        ) != nil
    }

    func configurationFile(
        home: URL
    ) -> URL {
        if let override =
            ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.isEmpty
        {
            return URL(
                fileURLWithPath: override,
                isDirectory: true
            )
            .standardizedFileURL
            .appendingPathComponent(".claude.json")
        }

        return home.appendingPathComponent(".claude.json")
    }

    func connectionRecipe(
        executable: String
    ) throws
        -> RightClickConnectionRecipe
    {
        try .stdio(
            command: executable,
            arguments: ["mcp"]
        )
    }

    func planConfiguration(
        home: URL,
        recipe: RightClickConnectionRecipe,
        disconnect: Bool
    ) throws
        -> RightClickOnboardingMutation
    {
        guard let claude =
            claudeExecutable(
                home: home
            )
        else {
            throw RightClickOnboardingError(
                "Claude Code was selected but its native "
                + "CLI could not be found."
            )
        }

        let joinedArguments =
            recipe.arguments
                .joined(separator: " ")

        let contract =
            RightClickNativeRegistrationBackend
                .Contract(
                    backendID:
                        "claude-native-cli",
                    scope:
                        "user",
                    inspect:
                        .init(
                            executable:
                                claude,
                            arguments: [
                                "mcp",
                                "get",
                                "rightclick",
                            ]
                        ),
                    add:
                        .init(
                            executable:
                                claude,
                            arguments:
                                [
                                    "mcp",
                                    "add",
                                    "--scope",
                                    "user",
                                    "rightclick",
                                    "--",
                                    recipe.command,
                                ]
                                + recipe.arguments
                        ),
                    remove:
                        .init(
                            executable:
                                claude,
                            arguments: [
                                "mcp",
                                "remove",
                                "--scope",
                                "user",
                                "rightclick",
                            ]
                        ),
                    health:
                        .init(
                            executable:
                                claude,
                            arguments: [
                                "mcp",
                                "list",
                            ]
                        ),
                    desiredInspectionFragments: [
                        "Scope: User config",
                        "Type: stdio",
                        "Command: \(recipe.command)",
                        "Args: \(joinedArguments)",
                    ],
                    absenceMarkers: [
                        "No MCP server named \"rightclick\""
                    ],
                    connectedFragments: [
                        "rightclick:",
                        recipe.command,
                        joinedArguments,
                        "Connected",
                    ]
                )

        return .native(
            try RightClickNativeRegistrationBackend
                .plan(
                    contract: contract,
                    disconnect: disconnect
                )
        )
    }

    private func claudeExecutable(
        home: URL
    ) -> String? {
        var candidates: [String] = [
            home
                .appendingPathComponent(
                    ".local/bin/claude"
                )
                .path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]

        if let path =
            ProcessInfo
                .processInfo
                .environment["PATH"]
        {
            candidates.append(
                contentsOf:
                    path
                    .split(separator: ":")
                    .map {
                        String($0)
                        + "/claude"
                    }
            )
        }

        var seen =
            Set<String>()

        for candidate in candidates {
            guard seen.insert(candidate).inserted
            else {
                continue
            }

            if FileManager.default
                .isExecutableFile(
                    atPath: candidate
                )
            {
                return URL(
                    fileURLWithPath:
                        candidate
                )
                .standardizedFileURL
                .path
            }
        }

        return nil
    }
}
