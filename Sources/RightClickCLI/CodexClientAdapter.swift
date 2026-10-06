import Foundation

struct RightClickCodexClientAdapter:
    RightClickClientAdapter
{
    let id = "codex"
    let displayName = "Codex"

    func detected(
        home: URL,
        applications: URL
    ) -> Bool {
        codexExecutable(
            home: home
        ) != nil
    }

    func configurationFile(
        home: URL
    ) -> URL {
        if let override =
            ProcessInfo
                .processInfo
                .environment["CODEX_HOME"],
           !override.isEmpty
        {
            return URL(
                fileURLWithPath:
                    override,
                isDirectory: true
            )
            .standardizedFileURL
            .appendingPathComponent(
                "config.toml"
            )
        }

        return home
            .appendingPathComponent(
                ".codex/config.toml"
            )
    }

    func connectionRecipe(
        executable: String
    ) throws
        -> RightClickConnectionRecipe
    {
        try .stdio(
            command:
                executable,
            arguments:
                ["mcp"]
        )
    }

    func planConfiguration(
        home: URL,
        recipe:
            RightClickConnectionRecipe,
        disconnect: Bool
    ) throws
        -> RightClickOnboardingMutation
    {
        guard let codex =
            codexExecutable(
                home: home
            )
        else {
            throw RightClickOnboardingError(
                "Codex was selected but its native "
                + "CLI could not be found."
            )
        }

        let contract =
            RightClickNativeRegistrationBackend
                .Contract(
                    backendID:
                        "codex-native-cli",
                    scope:
                        "global",
                    inspect:
                        .init(
                            executable:
                                codex,
                            arguments: [
                                "mcp",
                                "get",
                                "rightclick",
                                "--json",
                            ]
                        ),
                    add:
                        .init(
                            executable:
                                codex,
                            arguments:
                                [
                                    "mcp",
                                    "add",
                                    "rightclick",
                                    "--",
                                    recipe.command,
                                ]
                                + recipe.arguments
                        ),
                    remove:
                        .init(
                            executable:
                                codex,
                            arguments: [
                                "mcp",
                                "remove",
                                "rightclick",
                            ]
                        ),

                    // Codex 0.159.3 get/list prove
                    // configuration but do not independently
                    // attest a live MCP connection.
                    health:
                        nil,

                    exactInspection: {
                        output in

                        registrationMatches(
                            output:
                                output,
                            recipe:
                                recipe
                        )
                    },

                    absenceMarkers: [
                        "No MCP server named "
                        + "'rightclick' found."
                    ]
                )

        return .native(
            try RightClickNativeRegistrationBackend
                .plan(
                    contract:
                        contract,
                    disconnect:
                        disconnect
                )
        )
    }

    private func codexExecutable(
        home: URL
    ) -> String? {
        var candidates:
            [String] = [
                home
                    .appendingPathComponent(
                        ".local/bin/codex"
                    )
                    .path,
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]

        if let path =
            ProcessInfo
                .processInfo
                .environment["PATH"]
        {
            candidates.append(
                contentsOf:
                    path
                    .split(
                        separator: ":"
                    )
                    .map {
                        String($0)
                        + "/codex"
                    }
            )
        }

        var seen =
            Set<String>()

        for candidate in candidates {
            guard
                seen.insert(
                    candidate
                ).inserted
            else {
                continue
            }

            if FileManager.default
                .isExecutableFile(
                    atPath:
                        candidate
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

    private func registrationMatches(
        output: String,
        recipe:
            RightClickConnectionRecipe
    ) -> Bool {
        guard
            let data =
                output.data(
                    using: .utf8
                ),
            let root =
                try? JSONSerialization
                    .jsonObject(
                        with: data
                    )
                as? [String: Any],
            root["name"] as? String
                == "rightclick",
            root["enabled"] as? Bool
                == true,
            isNull(
                root[
                    "disabled_reason"
                ]
            ),
            let transport =
                root["transport"]
                as? [String: Any],
            transport["type"] as? String
                == "stdio",
            transport["command"] as? String
                == recipe.command,
            let arguments =
                transport["args"]
                as? [String],
            arguments ==
                recipe.arguments,
            isNull(
                transport["env"]
            ),
            let envVars =
                transport["env_vars"]
                as? [String],
            envVars.isEmpty,
            isNull(
                transport["cwd"]
            ),
            isNull(
                root["enabled_tools"]
            ),
            isNull(
                root["disabled_tools"]
            ),
            isNull(
                root[
                    "startup_timeout_sec"
                ]
            ),
            isNull(
                root[
                    "tool_timeout_sec"
                ]
            )
        else {
            return false
        }

        return true
    }

    private func isNull(
        _ value: Any?
    ) -> Bool {
        value is NSNull
    }
}
