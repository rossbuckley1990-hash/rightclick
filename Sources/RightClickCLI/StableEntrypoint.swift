import Foundation

enum RightClickStableEntrypointError:
    LocalizedError
{
    case unsupported(
        invoked: String,
        resolved: String
    )

    var errorDescription: String? {
        switch self {
        case .unsupported(
            let invoked,
            let resolved
        ):
            return """
            RIGHTCLICK was launched from a development or non-stable installation.

            invoked: \(invoked)
            resolved: \(resolved)

            ChatGPT setup only persists the supported Homebrew stable entrypoint.
            """
        }
    }
}

enum RightClickStableEntrypoint {
    struct Layout: Equatable {
        let stableBin: String
        let cellarRoot: String
    }

    static let productionLayouts = [
        Layout(
            stableBin:
                "/opt/homebrew/bin/rightclick",
            cellarRoot:
                "/opt/homebrew/Cellar/rightclick"
        ),

        Layout(
            stableBin:
                "/usr/local/bin/rightclick",
            cellarRoot:
                "/usr/local/Cellar/rightclick"
        ),
    ]

    static func resolve(
        invokedExecutable: String,
        layouts: [Layout] =
            productionLayouts,
        fileManager:
            FileManager = .default
    ) throws -> String {
        guard
            fileManager
                .isExecutableFile(
                    atPath:
                        invokedExecutable
                )
        else {
            throw RightClickStableEntrypointError
                .unsupported(
                    invoked:
                        invokedExecutable,
                    resolved:
                        invokedExecutable
                )
        }

        let invokedReal =
            URL(
                fileURLWithPath:
                    invokedExecutable
            )
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        for layout in layouts {
            guard
                fileManager
                    .isExecutableFile(
                        atPath:
                            layout.stableBin
                    )
            else {
                continue
            }

            let stableReal =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path

            let cellar =
                URL(
                    fileURLWithPath:
                        layout.cellarRoot,
                    isDirectory: true
                )
                .standardizedFileURL
                .path

            let cellarPrefix =
                cellar.hasSuffix("/")
                ? cellar
                : cellar + "/"

            // A stable bin path is trusted for persistence only
            // when Homebrew currently resolves it into the
            // rightclick Cellar and then to bin/rightclick.
            guard
                stableReal
                    .hasPrefix(
                        cellarPrefix
                    ),
                stableReal
                    .hasSuffix(
                        "/bin/rightclick"
                    )
            else {
                continue
            }

            // Direct Cellar invocation is accepted only when
            // that exact binary is also the current stable
            // Homebrew target.
            guard
                stableReal
                    == invokedReal
            else {
                continue
            }

            return URL(
                fileURLWithPath:
                    layout.stableBin
            )
            .standardizedFileURL
            .path
        }

        throw RightClickStableEntrypointError
            .unsupported(
                invoked:
                    invokedExecutable,
                resolved:
                    invokedReal
            )
    }
}
