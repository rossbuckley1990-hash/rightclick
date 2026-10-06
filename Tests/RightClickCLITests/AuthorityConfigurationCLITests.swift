import Foundation
import XCTest
import RightClickCore
@testable import RightClickCLI

final class AuthorityConfigurationCLITests:
    XCTestCase
{
    private func uniqueHost() -> String {
        "g9-cli-"
        + UUID()
            .uuidString
            .lowercased()
        + ".invalid"
    }

    func testSetStatusDeleteRoundTripNeverDisclosesCredential()
        throws
    {
        let host =
            uniqueHost()

        let rawOrigin =
            "HTTPS://"
            + host.uppercased()
            + ":443/"

        let canonicalOrigin =
            "https://"
            + host

        let scheme =
            "G9CLI"

        let secret =
            "g9-cli-secret-do-not-print"

        var output:
            [String] = []

        var errors:
            [String] = []

        defer {
            _ = try?
                OpenAPIAuthorityStore
                    .deleteBearerToken(
                        origin:
                            canonicalOrigin,
                        schemeName:
                            scheme
                    )
        }

        let setCode =
            RightClickAuthorityCLI
                .run(
                    [
                        "set",
                        "--origin",
                        rawOrigin,
                        "--scheme",
                        scheme,
                        "--json",
                    ],
                    input: {
                        secret
                    },
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
                )

        XCTAssertEqual(
            setCode,
            0
        )

        let storedAfterSet =
            try OpenAPIAuthorityStore
                .containsBearerToken(
                    origin:
                        canonicalOrigin,
                    schemeName:
                        scheme
                )

        XCTAssertTrue(
            storedAfterSet
        )

        var observable =
            (
                output
                + errors
            )
            .joined(
                separator:
                    "\n"
            )

        XCTAssertFalse(
            observable.contains(
                secret
            )
        )

        output.removeAll()
        errors.removeAll()

        let statusCode =
            RightClickAuthorityCLI
                .run(
                    [
                        "status",
                        "--origin",
                        canonicalOrigin,
                        "--scheme",
                        scheme,
                        "--json",
                    ],
                    input: {
                        XCTFail(
                            "status must never read credential input"
                        )

                        return nil
                    },
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
                )

        XCTAssertEqual(
            statusCode,
            0
        )

        observable =
            (
                output
                + errors
            )
            .joined(
                separator:
                    "\n"
            )

        XCTAssertTrue(
            observable.contains(
                canonicalOrigin
            )
        )

        XCTAssertTrue(
            observable.contains(
                scheme
            )
        )

        XCTAssertTrue(
            observable.contains(
                "STORED"
            )
        )

        XCTAssertFalse(
            observable.contains(
                secret
            )
        )

        output.removeAll()
        errors.removeAll()

        let deleteCode =
            RightClickAuthorityCLI
                .run(
                    [
                        "delete",
                        "--origin",
                        canonicalOrigin,
                        "--scheme",
                        scheme,
                        "--json",
                    ],
                    input: {
                        XCTFail(
                            "delete must never read credential input"
                        )

                        return nil
                    },
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
                )

        XCTAssertEqual(
            deleteCode,
            0
        )

        let storedAfterDelete =
            try OpenAPIAuthorityStore
                .containsBearerToken(
                    origin:
                        canonicalOrigin,
                    schemeName:
                        scheme
                )

        XCTAssertFalse(
            storedAfterDelete
        )

        observable =
            (
                output
                + errors
            )
            .joined(
                separator:
                    "\n"
            )

        XCTAssertFalse(
            observable.contains(
                secret
            )
        )
    }

    func testCredentialCommandLineFlagsAreRejectedBeforeInput()
        throws
    {
        let forbiddenFlags =
            [
                "--token",
                "--password",
                "--credential",
                "--api-key",
            ]

        for forbiddenFlag
            in forbiddenFlags
        {
            let host =
                uniqueHost()

            let origin =
                "https://"
                + host

            let scheme =
                "G9NoArgv"

            let secret =
                "g9-forbidden-argv-secret"

            var inputRead =
                false

            var output:
                [String] = []

            var errors:
                [String] = []

            let code =
                RightClickAuthorityCLI
                    .run(
                        [
                            "set",
                            "--origin",
                            origin,
                            "--scheme",
                            scheme,
                            forbiddenFlag,
                            secret,
                        ],
                        input: {
                            inputRead =
                                true

                            return secret
                        },
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
                    )

            XCTAssertNotEqual(
                code,
                0
            )

            XCTAssertFalse(
                inputRead
            )

            let stored =
                try OpenAPIAuthorityStore
                    .containsBearerToken(
                        origin:
                            origin,
                        schemeName:
                            scheme
                    )

            XCTAssertFalse(
                stored
            )

            let observable =
                (
                    output
                    + errors
                )
                .joined(
                    separator:
                        "\n"
                )

            XCTAssertFalse(
                observable.contains(
                    secret
                )
            )
        }
    }

    func testInvalidOriginAndSchemeFailBeforeCredentialRead()
        throws
    {
        var inputCount =
            0

        let input = {
            inputCount += 1

            return
                "must-not-be-read"
        }

        let invalidOriginCode =
            RightClickAuthorityCLI
                .run(
                    [
                        "set",
                        "--origin",
                        "http://provider.example",
                        "--scheme",
                        "BearerAuth",
                    ],
                    input:
                        input,
                    output: {
                        _ in
                    },
                    errorOutput: {
                        _ in
                    }
                )

        XCTAssertNotEqual(
            invalidOriginCode,
            0
        )

        XCTAssertEqual(
            inputCount,
            0
        )

        let invalidSchemeCode =
            RightClickAuthorityCLI
                .run(
                    [
                        "set",
                        "--origin",
                        "https://provider.example",
                        "--scheme",
                        "bad|scheme",
                    ],
                    input:
                        input,
                    output: {
                        _ in
                    },
                    errorOutput: {
                        _ in
                    }
                )

        XCTAssertNotEqual(
            invalidSchemeCode,
            0
        )

        XCTAssertEqual(
            inputCount,
            0
        )
    }

    func testStatusIsBoundToExactOriginAndScheme()
        throws
    {
        let firstHost =
            uniqueHost()

        let secondHost =
            uniqueHost()

        let firstOrigin =
            "https://"
            + firstHost

        let secondOrigin =
            "https://"
            + secondHost

        let scheme =
            "G9Scoped"

        defer {
            _ = try?
                OpenAPIAuthorityStore
                    .deleteBearerToken(
                        origin:
                            firstOrigin,
                        schemeName:
                            scheme
                    )
        }

        try OpenAPIAuthorityStore
            .setBearerToken(
                "g9-scoped-secret",
                origin:
                    firstOrigin,
                schemeName:
                    scheme
            )

        let wrongOriginCode =
            RightClickAuthorityCLI
                .run(
                    [
                        "status",
                        "--origin",
                        secondOrigin,
                        "--scheme",
                        scheme,
                    ],
                    input: {
                        nil
                    },
                    output: {
                        _ in
                    },
                    errorOutput: {
                        _ in
                    }
                )

        XCTAssertEqual(
            wrongOriginCode,
            1
        )

        let wrongSchemeCode =
            RightClickAuthorityCLI
                .run(
                    [
                        "status",
                        "--origin",
                        firstOrigin,
                        "--scheme",
                        "DifferentScheme",
                    ],
                    input: {
                        nil
                    },
                    output: {
                        _ in
                    },
                    errorOutput: {
                        _ in
                    }
                )

        XCTAssertEqual(
            wrongSchemeCode,
            1
        )

        let exactCode =
            RightClickAuthorityCLI
                .run(
                    [
                        "status",
                        "--origin",
                        firstOrigin,
                        "--scheme",
                        scheme,
                    ],
                    input: {
                        nil
                    },
                    output: {
                        _ in
                    },
                    errorOutput: {
                        _ in
                    }
                )

        XCTAssertEqual(
            exactCode,
            0
        )
    }
}
