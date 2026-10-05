import Foundation
import XCTest
@testable import RightClickCLI

final class BridgeRuntimeTests:
    XCTestCase
{
    func testRuntimeAPIKeyValidation() {
        for value in [
            "runtime-key_123",
            "sk-test_ABC-123",
        ] {
            XCTAssertNoThrow(
                try RightClickBridgeRuntime
                    .validateRuntimeAPIKey(
                        value
                    )
            )
        }

        for value in [
            "",
            " key",
            "key ",
            "key\n",
            "key/value",
            "key:value",
        ] {
            XCTAssertThrowsError(
                try RightClickBridgeRuntime
                    .validateRuntimeAPIKey(
                        value
                    ),
                value
            )
        }
    }

    func testChildConfigurationKeepsSecretOutOfArguments()
        throws
    {
        let secret =
            "runtime-secret_123"

        let config =
            try RightClickBridgeRuntime
                .childConfiguration(
                    tunnelClientPath:
                        "/opt/homebrew/bin/tunnel-client",
                    profileFile: URL(
                        fileURLWithPath:
                            "/tmp/rightclick.yaml"
                    ),
                    runtimeAPIKey:
                        secret,
                    baseEnvironment: [
                        "HOME":
                            "/Users/example",
                    ]
                )

        XCTAssertEqual(
            config.arguments,
            [
                "run",
                "--profile-file",
                "/tmp/rightclick.yaml",
            ]
        )

        XCTAssertFalse(
            config.arguments
                .contains {
                    $0.contains(secret)
                }
        )

        XCTAssertEqual(
            config.environment[
                "CONTROL_PLANE_API_KEY"
            ],
            secret
        )
    }

    func testTunnelClientResolutionPrefersExplicitOverride()
        throws
    {
        let root =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-tunnel-client-\(UUID().uuidString)",
                    isDirectory: true
                )

        defer {
            try? FileManager.default
                .removeItem(at: root)
        }

        try FileManager.default
            .createDirectory(
                at: root,
                withIntermediateDirectories:
                    true
            )

        let executable =
            root.appendingPathComponent(
                "tunnel-client"
            )

        try Data(
            "#!/bin/sh\nexit 0\n".utf8
        ).write(
            to: executable
        )

        try FileManager.default
            .setAttributes(
                [
                    .posixPermissions:
                        0o755,
                ],
                ofItemAtPath:
                    executable.path
            )

        let resolved =
            RightClickBridgeRuntime
                .resolveTunnelClient(
                    environment: [
                        RightClickBridgeRuntime
                            .tunnelClientOverride:
                            executable.path,
                    ],
                    state: nil,
                    fallbackPaths: []
                )

        XCTAssertEqual(
            resolved,
            executable.path
        )
    }

    func testTunnelClientResolutionDoesNotAcceptNonExecutableFile()
        throws
    {
        let root =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-tunnel-client-\(UUID().uuidString)",
                    isDirectory: true
                )

        defer {
            try? FileManager.default
                .removeItem(at: root)
        }

        try FileManager.default
            .createDirectory(
                at: root,
                withIntermediateDirectories:
                    true
            )

        let file =
            root.appendingPathComponent(
                "tunnel-client"
            )

        try Data(
            "not executable".utf8
        ).write(
            to: file
        )

        XCTAssertNil(
            RightClickBridgeRuntime
                .resolveTunnelClient(
                    environment: [
                        RightClickBridgeRuntime
                            .tunnelClientOverride:
                            file.path,
                    ],
                    state: nil,
                    fallbackPaths: []
                )
        )
    }
}
