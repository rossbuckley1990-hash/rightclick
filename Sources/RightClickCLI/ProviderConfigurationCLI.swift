import Foundation
#if os(Windows)
import ucrt
#endif
import RightClickCore

enum RightClickProviderCLI {
    private enum CommandError:
        LocalizedError
    {
        case usage(String)

        var errorDescription:
            String?
        {
            switch self {
            case let .usage(message):
                return message
            }
        }
    }

    private struct ParsedFlags {
        var values:
            [String: String] = [:]

        var booleans =
            Set<String>()
    }

    static func run(
        _ args: [String],
        file:
            URL =
            ConfiguredOpenAPIProviderStore
                .defaultFile(),
        output:
            (String) -> Void = {
                print($0)
            },
        errorOutput:
            (String) -> Void = {
                fputs(
                    $0 + "\n",
                    stderr
                )
            }
    ) -> Int {
        guard
            let command =
                args.first
        else {
            errorOutput(
                usage
            )

            return 2
        }

        do {
            switch command {
            case "list":
                let parsed =
                    try parse(
                        Array(
                            args.dropFirst()
                        ),
                        valueFlags:
                            [],
                        booleanFlags: [
                            "--json"
                        ]
                    )

                let providers =
                    try ConfiguredOpenAPIProviderStore
                        .read(
                            from:
                                file
                        )

                if parsed.booleans
                    .contains(
                        "--json"
                    )
                {
                    output(
                        RightClickJSON
                            .encode(
                                providers
                            )
                    )
                } else if providers.isEmpty {
                    output(
                        "No configured remote providers."
                    )
                } else {
                    let lines =
                        providers.map {
                            provider in

                            var line =
                                provider.id
                                + "  "
                                + provider.baseURL

                            if let authority =
                                provider
                                    .authorityScheme
                            {
                                line +=
                                    "  auth="
                                    + authority
                            }

                            return line
                        }

                    output(
                        lines.joined(
                            separator:
                                "\n"
                        )
                    )
                }

                return 0

            case "add":
                let parsed =
                    try parse(
                        Array(
                            args.dropFirst()
                        ),
                        valueFlags: [
                            "--id",
                            "--spec-url",
                            "--base-url",
                            "--auth-scheme",
                        ],
                        booleanFlags: [
                            "--json"
                        ]
                    )

                guard
                    let id =
                        parsed.values[
                            "--id"
                        ],
                    let specificationURL =
                        parsed.values[
                            "--spec-url"
                        ],
                    let baseURL =
                        parsed.values[
                            "--base-url"
                        ]
                else {
                    throw CommandError
                        .usage(
                            usage
                        )
                }

                let provider =
                    ConfiguredOpenAPIProviderDescriptor(
                        id:
                            id,
                        specificationURL:
                            specificationURL,
                        baseURL:
                            baseURL,
                        authorityScheme:
                            parsed.values[
                                "--auth-scheme"
                            ]
                    )

                let providers =
                    try ConfiguredOpenAPIProviderStore
                        .upsert(
                            provider,
                            in:
                                file
                        )

                if parsed.booleans
                    .contains(
                        "--json"
                    )
                {
                    output(
                        RightClickJSON.encode([
                            "status":
                                "CONFIGURED",
                            "id":
                                id,
                            "configuration":
                                file.path,
                            "providerCount":
                                String(
                                    providers.count
                                ),
                            "credentialStored":
                                "false",
                        ])
                    )
                } else {
                    output(
                        """
                        Configured remote provider: \(id)
                        \(file.path)

                        No credential was stored.
                        """
                    )
                }

                return 0

            case "remove":
                let parsed =
                    try parse(
                        Array(
                            args.dropFirst()
                        ),
                        valueFlags: [
                            "--id"
                        ],
                        booleanFlags: [
                            "--json"
                        ]
                    )

                guard
                    let id =
                        parsed.values[
                            "--id"
                        ]
                else {
                    throw CommandError
                        .usage(
                            usage
                        )
                }

                let removed =
                    try ConfiguredOpenAPIProviderStore
                        .remove(
                            id:
                                id,
                            from:
                                file
                        )

                if parsed.booleans
                    .contains(
                        "--json"
                    )
                {
                    output(
                        RightClickJSON.encode([
                            "status":
                                removed
                                ? "REMOVED"
                                : "ABSENT",
                            "id":
                                id,
                            "configuration":
                                file.path,
                        ])
                    )
                } else {
                    output(
                        removed
                        ? "Removed configured provider: \(id)"
                        : "Configured provider was already absent: \(id)"
                    )
                }

                return 0

            default:
                throw CommandError
                    .usage(
                        usage
                    )
            }

        } catch {
            errorOutput(
                error.localizedDescription
            )

            return 1
        }
    }

    private static func parse(
        _ args: [String],
        valueFlags:
            Set<String>,
        booleanFlags:
            Set<String>
    ) throws -> ParsedFlags {
        var result =
            ParsedFlags()

        var index =
            0

        while
            index < args.count
        {
            let argument =
                args[index]

            if booleanFlags
                .contains(
                    argument
                )
            {
                guard
                    result.booleans
                        .insert(
                            argument
                        )
                        .inserted
                else {
                    throw CommandError
                        .usage(
                            "Duplicate option: \(argument)"
                        )
                }

                index += 1

                continue
            }

            guard
                valueFlags
                    .contains(
                        argument
                    ),
                index + 1
                    < args.count
            else {
                throw CommandError
                    .usage(
                        usage
                    )
            }

            guard
                result.values[
                    argument
                ] == nil
            else {
                throw CommandError
                    .usage(
                        "Duplicate option: \(argument)"
                    )
            }

            let value =
                args[
                    index + 1
                ]

            guard
                !value.hasPrefix(
                    "--"
                )
            else {
                throw CommandError
                    .usage(
                        "Missing value for \(argument)"
                    )
            }

            result.values[
                argument
            ] =
                value

            index += 2
        }

        return result
    }

    private static let usage =
        """
        usage:
          rightclick provider list [--json]
          rightclick provider add --id <id> --spec-url <https-url> --base-url <https-url> [--auth-scheme <scheme>] [--json]
          rightclick provider remove --id <id> [--json]
        """
}
