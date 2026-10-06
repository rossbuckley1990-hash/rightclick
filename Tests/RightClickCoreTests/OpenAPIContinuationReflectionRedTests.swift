import Foundation
import XCTest
@testable import RightClickCore

final class OpenAPIContinuationReflectionRedTests:
    XCTestCase
{
    private var capabilities:
        [Capability] = []

    override func setUpWithError()
        throws
    {
        try super.setUpWithError()

        let environment =
            ProcessInfo
                .processInfo
                .environment

        guard
            let specificationPath =
                environment[
                    "RIGHTCLICK_CONTINUATION_SPEC"
                ],
            let baseURLString =
                environment[
                    "RIGHTCLICK_CONTINUATION_BASE_URL"
                ],
            let baseURL =
                URL(
                    string:
                        baseURLString
                )
        else {
            throw XCTSkip(
                "RIGHTCLICK_CONTINUATION_SPEC and RIGHTCLICK_CONTINUATION_BASE_URL are required for the real-contract continuation gate."
            )
        }

        let specification =
            try Data(
                contentsOf:
                    URL(
                        fileURLWithPath:
                            specificationPath
                    )
            )

        let reflector =
            try OpenAPIReflector(
                specificationData:
                    specification,
                baseURL:
                    baseURL,
                session:
                    URLSession(
                        configuration:
                            .ephemeral
                    )
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        capabilities =
            try engine
                .capabilities(
                    for:
                        "RIGHTCLICK continuation reflection RED-007A"
                )
                .capabilities
    }

    private func capability(
        operationID:
            String
    ) -> Capability? {
        capabilities.first(
            where: {
                $0.metadata[
                    "operationId"
                ]
                == operationID
            }
        )
    }

    private func diagnostic(
        name: String,
        capability: Capability?
    ) {
        guard let capability else {
            print(
                "CONTINUATION_RED007A "
                + name
                + " present=false"
            )

            return
        }

        print(
            "CONTINUATION_RED007A "
            + name
            + " present=true"
            + " invocation="
            + String(
                describing:
                    capability
                        .invocation
            )
            + " authority="
            + (
                capability.metadata[
                    "authorityStatus"
                ]
                ?? "nil"
            )
            + " method="
            + (
                capability.metadata[
                    "method"
                ]
                ?? "nil"
            )
            + " path="
            + (
                capability.metadata[
                    "path"
                ]
                ?? "nil"
            )
            + " requestContentType="
            + (
                capability.metadata[
                    "requestContentType"
                ]
                ?? "nil"
            )
            + " parametersPresent="
            + String(
                capability.metadata[
                    "parametersJSON"
                ]
                != nil
            )
            + " securityRequirementsPresent="
            + String(
                capability.metadata[
                    "securityRequirementsJSON"
                ]
                != nil
            )
        )
    }

    func testCreatePublishSessionRemainsAvailable()
        throws
    {
        let reflected =
            capability(
                operationID:
                    "createPublishSession"
            )

        diagnostic(
            name:
                "create",
            capability:
                reflected
        )

        let capability =
            try XCTUnwrap(
                reflected
            )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "anonymous"
        )

        XCTAssertEqual(
            capability.invocation,
            .interactive
        )
    }

    func testUploadContinuationShouldReflectAsUnsupportedCredentialedCapability()
        throws
    {
        let capability =
            capability(
                operationID:
                    "uploadPublishSessionFile"
            )

        diagnostic(
            name:
                "upload",
            capability:
                capability
        )

        XCTAssertNotNil(
            capability,
            "RED_CONTINUATION_UPLOAD_NOT_REFLECTED"
        )

        guard let capability else {
            return
        }

        XCTAssertEqual(
            capability.metadata[
                "method"
            ],
            "PUT"
        )

        XCTAssertEqual(
            capability.metadata[
                "path"
            ],
            "/publish-sessions/{sessionId}/files/{fileId}"
        )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "credential_required"
        )

        XCTAssertEqual(
            capability.invocation,
            .unsupported,
            "RED_CONTINUATION_UPLOAD_PREMATURELY_EXECUTABLE"
        )

        XCTAssertEqual(
            capability.metadata[
                "requestContentType"
            ],
            "application/octet-stream"
        )

        let parameters =
            try XCTUnwrap(
                capability.metadata[
                    "parametersJSON"
                ],
                "RED_CONTINUATION_UPLOAD_PARAMETERS_NOT_RETAINED"
            )

        XCTAssertTrue(
            parameters.contains(
                "sessionId"
            ),
            "RED_CONTINUATION_SESSION_PATH_PARAMETER_MISSING"
        )

        XCTAssertTrue(
            parameters.contains(
                "fileId"
            ),
            "RED_CONTINUATION_FILE_PATH_PARAMETER_MISSING"
        )

        let security =
            try XCTUnwrap(
                capability.metadata[
                    "securityRequirementsJSON"
                ],
                "RED_CONTINUATION_SECURITY_REQUIREMENTS_NOT_RETAINED"
            )

        XCTAssertTrue(
            security.contains(
                "publishSessionToken"
            ),
            "RED_CONTINUATION_SECURITY_SCHEME_MISSING"
        )
    }

    func testFinalizeContinuationShouldReflectAsUnsupportedCredentialedCapability()
        throws
    {
        let capability =
            capability(
                operationID:
                    "finalizePublishSession"
            )

        diagnostic(
            name:
                "finalize",
            capability:
                capability
        )

        XCTAssertNotNil(
            capability,
            "RED_CONTINUATION_FINALIZE_NOT_REFLECTED"
        )

        guard let capability else {
            return
        }

        XCTAssertEqual(
            capability.metadata[
                "method"
            ],
            "POST"
        )

        XCTAssertEqual(
            capability.metadata[
                "path"
            ],
            "/publish-sessions/{sessionId}/finalize"
        )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "credential_required"
        )

        XCTAssertEqual(
            capability.invocation,
            .unsupported
        )

        let parameters =
            try XCTUnwrap(
                capability.metadata[
                    "parametersJSON"
                ]
            )

        XCTAssertTrue(
            parameters.contains(
                "sessionId"
            )
        )

        let security =
            try XCTUnwrap(
                capability.metadata[
                    "securityRequirementsJSON"
                ]
            )

        XCTAssertTrue(
            security.contains(
                "publishSessionToken"
            )
        )
    }

    func testStatusContinuationShouldReflectAsUnsupportedCredentialedCapability()
        throws
    {
        let capability =
            capability(
                operationID:
                    "getPublishSession"
            )

        diagnostic(
            name:
                "status",
            capability:
                capability
        )

        XCTAssertNotNil(
            capability,
            "RED_CONTINUATION_STATUS_NOT_REFLECTED"
        )

        guard let capability else {
            return
        }

        XCTAssertEqual(
            capability.metadata[
                "method"
            ],
            "GET"
        )

        XCTAssertEqual(
            capability.metadata[
                "path"
            ],
            "/publish-sessions/{sessionId}"
        )

        XCTAssertEqual(
            capability.metadata[
                "authorityStatus"
            ],
            "credential_required"
        )

        XCTAssertEqual(
            capability.invocation,
            .unsupported
        )

        let parameters =
            try XCTUnwrap(
                capability.metadata[
                    "parametersJSON"
                ]
            )

        XCTAssertTrue(
            parameters.contains(
                "sessionId"
            )
        )

        let security =
            try XCTUnwrap(
                capability.metadata[
                    "securityRequirementsJSON"
                ]
            )

        XCTAssertTrue(
            security.contains(
                "publishSessionToken"
            )
        )
    }
}
