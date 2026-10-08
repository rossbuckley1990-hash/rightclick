import Foundation
import RightClickCore

enum RightClickAuthorityCLI {
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
        input:
            (() -> String?)? = nil,
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
            let parsed =
                try parse(
                    Array(
                        args.dropFirst()
                    ),
                    valueFlags: [
                        "--origin",
                        "--scheme",
                    ],
                    booleanFlags: [
                        "--json"
                    ]
                )

            guard
                let rawOrigin =
                    parsed.values[
                        "--origin"
                    ],
                let rawScheme =
                    parsed.values[
                        "--scheme"
                    ]
            else {
                throw CommandError
                    .usage(
                        usage
                    )
            }

            let origin =
                try OpenAPIAuthorityStore
                    .canonicalBearerOrigin(
                        rawOrigin
                    )

            let scheme =
                try OpenAPIAuthorityStore
                    .canonicalBearerSchemeName(
                        rawScheme
                    )

            let json =
                parsed.booleans
                    .contains(
                        "--json"
                    )

            switch command {
            case "set":
                let reader =
                    input
                    ?? readSecretFromInput

                guard
                    let credential =
                        reader(),
                    !credential.isEmpty
                else {
                    throw CommandError
                        .usage(
                            "No bearer credential was provided on stdin."
                        )
                }

                try OpenAPIAuthorityStore
                    .setBearerToken(
                        credential,
                        origin:
                            origin,
                        schemeName:
                            scheme
                    )

                if json {
                    output(
                        RightClickJSON.encode([
                            "status":
                                "STORED",
                            "kind":
                                "http_bearer",
                            "origin":
                                origin,
                            "scheme":
                                scheme,
                            "credentialStored":
                                "true",
                        ])
                    )
                } else {
                    output(
                        """
                        Provider authority: STORED
                        kind: http_bearer
                        origin: \(origin)
                        scheme: \(scheme)
                        """
                    )
                }

                return 0

            case "status":
                let stored =
                    try OpenAPIAuthorityStore
                        .containsBearerToken(
                            origin:
                                origin,
                            schemeName:
                                scheme
                        )

                if json {
                    output(
                        RightClickJSON.encode([
                            "status":
                                stored
                                ? "STORED"
                                : "NOT_STORED",
                            "kind":
                                "http_bearer",
                            "origin":
                                origin,
                            "scheme":
                                scheme,
                            "credentialStored":
                                stored
                                ? "true"
                                : "false",
                        ])
                    )
                } else {
                    output(
                        """
                        Provider authority: \(stored ? "STORED" : "NOT STORED")
                        kind: http_bearer
                        origin: \(origin)
                        scheme: \(scheme)
                        """
                    )
                }

                return stored
                    ? 0
                    : 1

            case "delete":
                let deleted =
                    try OpenAPIAuthorityStore
                        .deleteBearerToken(
                            origin:
                                origin,
                            schemeName:
                                scheme
                        )

                if json {
                    output(
                        RightClickJSON.encode([
                            "status":
                                deleted
                                ? "DELETED"
                                : "ABSENT",
                            "kind":
                                "http_bearer",
                            "origin":
                                origin,
                            "scheme":
                                scheme,
                            "credentialStored":
                                "false",
                        ])
                    )
                } else {
                    output(
                        """
                        Provider authority: \(deleted ? "DELETED" : "ALREADY ABSENT")
                        kind: http_bearer
                        origin: \(origin)
                        scheme: \(scheme)
                        """
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

        while index
            < args.count
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

            result.values[
                argument
            ] =
                args[index + 1]

            index += 2
        }

        return result
    }

    private static func readSecretFromInput()
        -> String?
    {
#if os(Windows)
        // No terminal echo suppression adapter is available; abstain.
        return nil
#else
        let descriptor =
            fileno(
                stdin
            )

        guard
            isatty(
                descriptor
            ) != 0
        else {
            return readLine(
                strippingNewline:
                    true
            )
        }

        fputs(
            "Bearer credential: ",
            stderr
        )

        fflush(
            stderr
        )

        var original =
            termios()

        guard
            tcgetattr(
                descriptor,
                &original
            ) == 0
        else {
            return readLine(
                strippingNewline:
                    true
            )
        }

        var hidden =
            original

        hidden.c_lflag &=
            ~tcflag_t(
                ECHO
            )

        guard
            tcsetattr(
                descriptor,
                TCSAFLUSH,
                &hidden
            ) == 0
        else {
            return readLine(
                strippingNewline:
                    true
            )
        }

        defer {
            var restored =
                original

            _ =
                tcsetattr(
                    descriptor,
                    TCSAFLUSH,
                    &restored
                )

            fputs(
                "\n",
                stderr
            )

            fflush(
                stderr
            )
        }

        return readLine(
            strippingNewline:
                true
        )
#endif
    }

    private static let usage =
        """
        usage:
          rightclick authority set --origin <https-origin> --scheme <name>
          rightclick authority status --origin <https-origin> --scheme <name>
          rightclick authority delete --origin <https-origin> --scheme <name>

        Credential input for 'set' is read only from stdin/TTY.
        """
}
