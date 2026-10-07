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
        .native(try RightClickNativeRegistrationBackend.plan(
            contract: registrationContract(home: home, recipe: recipe), disconnect: disconnect))
    }

    func registrationContract(home: URL, recipe: RightClickConnectionRecipe) throws -> RightClickNativeRegistrationBackend.Contract {

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
                    exactInspection: { output in
                        registrationMatches(output: output, recipe: recipe)
                    },
                    absenceMarkers: [
                        "No MCP server named \"rightclick\""
                    ],
                    connectedFragments: [
                        "rightclick:",
                        recipe.command,
                        joinedArguments,
                        "Connected",
                    ],
                    exactConnection: { output in
                        let lines = output.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { $0.hasPrefix("rightclick:") }
                        let prefix = "rightclick: \(recipe.command) \(joinedArguments) - "
                        return lines.count == 1 && ["✓ Connected", "✔ Connected", "Connected"].contains {
                            lines[0] == prefix + $0
                        }
                    }
                )

        return contract
    }

    private func claudeExecutable(home: URL) -> String? {
        RightClickClientHost.executable(named: "claude", home: home)
    }

    private func registrationMatches(output: String, recipe: RightClickConnectionRecipe) -> Bool {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "rightclick:" { continue }
            guard let separator = text.firstIndex(of: ":") else { return false }
            let key = String(text[..<separator])
            let value = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard ["Scope", "Status", "Type", "Command", "Args"].contains(key), fields[key] == nil else { return false }
            fields[key] = value
        }
        return ["User config", "User config (available in all your projects)"].contains(fields["Scope"] ?? "")
            && fields["Type"] == "stdio" && fields["Command"] == recipe.command
            && fields["Args"] == recipe.arguments.joined(separator: " ")
    }
}
