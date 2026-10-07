import Foundation
import XCTest

@testable import RightClickCLI

final class ProviderConfigurationCLITests:
    XCTestCase
{
    private func temporaryFile()
        throws -> (
            directory: URL,
            file: URL
        )
    {
        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-provider-cli-"
                    + UUID().uuidString,
                    isDirectory:
                        true
                )

        try FileManager.default
            .createDirectory(
                at:
                    directory,
                withIntermediateDirectories:
                    true
            )

        return (
            directory,
            directory
                .appendingPathComponent(
                    "providers.json"
                )
        )
    }

    func testProviderAddListAndRemoveRoundTrip()
        throws
    {
        let temp =
            try temporaryFile()

        defer {
            try? FileManager.default
                .removeItem(
                    at:
                        temp.directory
                )
        }

        var output:
            [String] = []

        var errors:
            [String] = []

        XCTAssertEqual(
            RightClickProviderCLI.run(
                [
                    "add",
                    "--id",
                    "github-like",
                    "--spec-url",
                    "https://spec.example/openapi.json",
                    "--base-url",
                    "https://api.example",
                    "--auth-scheme",
                    "ExampleBearer",
                    "--json",
                ],
                file:
                    temp.file,
                output: {
                    output.append(
                        $0
                    )
                },
                errorOutput: {
                    errors.append(
                        $0
                    )
                }
            ),
            0
        )

        XCTAssertTrue(
            errors.isEmpty
        )

        let data =
            try Data(
                contentsOf:
                    temp.file
            )

        let root =
            try XCTUnwrap(
                JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as? [String: Any]
            )

        let rows =
            try XCTUnwrap(
                root[
                    "providers"
                ] as? [[String: Any]]
            )

        XCTAssertEqual(
            rows.count,
            1
        )

        XCTAssertEqual(
            rows[0][
                "id"
            ] as? String,
            "github-like"
        )

        XCTAssertNil(
            rows[0][
                "token"
            ]
        )

        output.removeAll()

        XCTAssertEqual(
            RightClickProviderCLI.run(
                [
                    "list",
                    "--json",
                ],
                file:
                    temp.file,
                output: {
                    output.append(
                        $0
                    )
                },
                errorOutput: {
                    errors.append(
                        $0
                    )
                }
            ),
            0
        )

        XCTAssertEqual(
            output.count,
            1
        )

        XCTAssertTrue(
            output[0]
                .contains(
                    "github-like"
                )
        )

        output.removeAll()

        XCTAssertEqual(
            RightClickProviderCLI.run(
                [
                    "remove",
                    "--id",
                    "github-like",
                    "--json",
                ],
                file:
                    temp.file,
                output: {
                    output.append(
                        $0
                    )
                },
                errorOutput: {
                    errors.append(
                        $0
                    )
                }
            ),
            0
        )

        let after =
            try Data(
                contentsOf:
                    temp.file
            )

        let afterRoot =
            try XCTUnwrap(
                JSONSerialization
                    .jsonObject(
                        with:
                            after
                    )
                    as? [String: Any]
            )

        let afterRows =
            try XCTUnwrap(
                afterRoot[
                    "providers"
                ] as? [Any]
            )

        XCTAssertTrue(
            afterRows.isEmpty
        )
    }

    func testProviderCLIRejectsCredentialOptionAndHTTPURL()
        throws
    {
        let temp =
            try temporaryFile()

        defer {
            try? FileManager.default
                .removeItem(
                    at:
                        temp.directory
                )
        }

        var errors:
            [String] = []

        XCTAssertNotEqual(
            RightClickProviderCLI.run(
                [
                    "add",
                    "--id",
                    "unsafe",
                    "--spec-url",
                    "https://spec.example/openapi.json",
                    "--base-url",
                    "https://api.example",
                    "--token",
                    "secret",
                ],
                file:
                    temp.file,
                output: {
                    _ in
                },
                errorOutput: {
                    errors.append(
                        $0
                    )
                }
            ),
            0
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        temp.file.path
                )
        )

        errors.removeAll()

        XCTAssertNotEqual(
            RightClickProviderCLI.run(
                [
                    "add",
                    "--id",
                    "unsafe",
                    "--spec-url",
                    "http://spec.example/openapi.json",
                    "--base-url",
                    "https://api.example",
                ],
                file:
                    temp.file,
                output: {
                    _ in
                },
                errorOutput: {
                    errors.append(
                        $0
                    )
                }
            ),
            0
        )

        XCTAssertFalse(
            FileManager.default
                .fileExists(
                    atPath:
                        temp.file.path
                )
        )
    }
}
