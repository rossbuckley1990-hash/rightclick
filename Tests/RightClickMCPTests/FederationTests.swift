import XCTest
@testable import RightClickCore
@testable import RightClickMCP

final class FederationTests:
    XCTestCase
{
    final class FakeTransport:
        FederationPeerTransport
    {
        var runtimeIdentity =
            RightClickRuntimeIdentity(
                product:
                    "RIGHTCLICK",
                version:
                    "test",
                executablePath:
                    "/tmp/rightclick-b",
                executableRealPath:
                    "/tmp/rightclick-b",
                executableSHA256:
                    "peer-sha",
                pid:
                    2,
                transport:
                    "http"
            )

        var actionViews:
            [CapabilityView] = []

        var runRecord =
            ExecutionRecord(
                executionId:
                    "remote",
                actionId:
                    "remote:action",
                state:
                    .accepted,
                message:
                    "accepted"
            )

        var lastArguments:
            CapabilityArguments?

        var lastVerification:
            VerificationSpec?

        func runtime()
            throws
            -> RightClickRuntimeIdentity
        {
            runtimeIdentity
        }

        func actions(
            item: String
        ) throws -> [CapabilityView] {
            actionViews
        }

        func run(
            item: String,
            actionID: String,
            arguments:
                CapabilityArguments?,
            verification:
                VerificationSpec?
        ) throws -> ExecutionRecord {
            lastArguments =
                arguments

            lastVerification =
                verification

            var record =
                runRecord

            record.actionId =
                actionID

            return record
        }
    }

    func testPeerConfigurationFailsClosedOutsideLoopback()
        throws
    {
        let raw =
            """
            [
              {
                "id": "remote",
                "name": "Remote RIGHTCLICK",
                "endpoint": "https://example.com/mcp",
                "tokenEnvironment": "RIGHTCLICK_REMOTE_TOKEN"
              },
              {
                "id": "local",
                "name": "Local RIGHTCLICK",
                "endpoint": "http://127.0.0.1:8877/mcp",
                "tokenEnvironment": "RIGHTCLICK_LOCAL_TOKEN"
              }
            ]
            """

        let peers =
            FederationPeerConfiguration
                .load(
                    environment: [
                        FederationPeerConfiguration
                            .environmentKey:
                                raw
                    ]
                )

        XCTAssertEqual(
            peers.map(
                \.id
            ),
            [
                "local"
            ]
        )
    }

    func testFederatedCapabilityAppearsAndDisappearsLive()
        throws
    {
        let transport =
            FakeTransport()

        let reflector =
            makeReflector(
                transport
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    reflector
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "hello"
                )
                .capabilities
                .isEmpty
        )

        transport.actionViews = [
            remoteView(
                id:
                    "remote:action",
                title:
                    "Remote action"
            )
        ]

        let appeared =
            try engine
                .capabilities(
                    for:
                        "hello"
                )
                .capabilities

        XCTAssertEqual(
            appeared.map(
                \.id
            ),
            [
                "federation:peer-b:remote:action"
            ]
        )

        XCTAssertTrue(
            appeared[0]
                .requiresConfirmation
        )

        transport.actionViews =
            []

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "hello"
                )
                .capabilities
                .isEmpty
        )
    }

    func testFederationDoesNotReexportFederatedCapability()
        throws
    {
        let transport =
            FakeTransport()

        transport.actionViews = [
            remoteView(
                id:
                    "federation:peer-c:remote",
                title:
                    "Already federated"
            )
        ]

        let engine =
            CapabilityEngine(
                reflectors: [
                    makeReflector(
                        transport
                    )
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "hello"
                )
                .capabilities
                .isEmpty
        )
    }

    func testNonRightClickPeerContributesNoCapabilities()
        throws
    {
        let transport =
            FakeTransport()

        transport.runtimeIdentity.product =
            "NOT_RIGHTCLICK"

        transport.actionViews = [
            remoteView(
                id:
                    "remote:action",
                title:
                    "Remote action"
            )
        ]

        let engine =
            CapabilityEngine(
                reflectors: [
                    makeReflector(
                        transport
                    )
                ]
            )

        XCTAssertTrue(
            try engine
                .capabilities(
                    for:
                        "hello"
                )
                .capabilities
                .isEmpty
        )
    }

    func testExplicitVerificationRunsAtRemoteBoundary()
        throws
    {
        let transport =
            FakeTransport()

        transport.actionViews = [
            remoteView(
                id:
                    "remote:verified",
                title:
                    "Remote verified action"
            )
        ]

        let predicate =
            VerificationPredicate(
                type:
                    .fileExists
            )

        let spec =
            VerificationSpec(
                predicates: [
                    predicate
                ]
            )

        transport.runRecord =
            ExecutionRecord(
                executionId:
                    "remote-execution",
                actionId:
                    "remote:verified",
                title:
                    "Remote verified action",
                state:
                    .succeeded,
                message:
                    "Remote postcondition verified.",
                output:
                    nil,
                evidence:
                    OutcomeEvidence(
                        type:
                            "generic_postcondition",
                        boundary:
                            "Observed on runtime B.",
                        outcomeVerified:
                            true
                    ),
                verification:
                    OutcomeVerification(
                        status:
                            .verifiedSuccess,
                        predicates: [
                            PredicateVerification(
                                predicate:
                                    predicate,
                                evaluated:
                                    true,
                                passed:
                                    true,
                                actual:
                                    "true",
                                message:
                                    "Observed on runtime B."
                            )
                        ]
                    )
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    makeReflector(
                        transport
                    )
                ]
            )

        let result =
            try engine.run(
                id:
                    "federation:peer-b:remote:verified",
                item:
                    "hello",
                confirmed:
                    true,
                arguments: [
                    "example":
                        "value"
                ],
                verification:
                    spec
            )

        XCTAssertEqual(
            result.status,
            .verified
        )

        XCTAssertEqual(
            result
                .verification?
                .status,
            .verifiedSuccess
        )

        XCTAssertTrue(
            result
                .evidence
                .outcomeVerified
        )

        XCTAssertEqual(
            transport
                .lastArguments?[
                    "example"
                ],
            "value"
        )

        XCTAssertEqual(
            transport
                .lastVerification,
            spec
        )
    }

    func testIncompleteRemoteVerificationIsDowngraded()
        throws
    {
        let transport =
            FakeTransport()

        transport.actionViews = [
            remoteView(
                id:
                    "remote:claim",
                title:
                    "Remote claim"
            )
        ]

        transport.runRecord =
            ExecutionRecord(
                executionId:
                    "remote-execution",
                actionId:
                    "remote:claim",
                state:
                    .succeeded,
                message:
                    "claimed success",
                evidence:
                    OutcomeEvidence(
                        type:
                            "provider_acceptance",
                        boundary:
                            "No postcondition.",
                        outcomeVerified:
                            false
                    )
            )

        let engine =
            CapabilityEngine(
                reflectors: [
                    makeReflector(
                        transport
                    )
                ]
            )

        let result =
            try engine.run(
                id:
                    "federation:peer-b:remote:claim",
                item:
                    "hello",
                confirmed:
                    true,
                verification:
                    VerificationSpec(
                        predicates: [
                            VerificationPredicate(
                                type:
                                    .fileExists
                            )
                        ]
                    )
            )

        XCTAssertEqual(
            result.status,
            .accepted
        )

        XCTAssertFalse(
            result
                .evidence
                .outcomeVerified
        )
    }

    func testModelFacingToolSurfaceRemainsSevenGenericOperations()
    {
        XCTAssertEqual(
            RightClickMCPContract
                .toolNames(),
            [
                "context_actions",
                "context_explain",
                "context_inspect",
                "context_providers",
                "context_run",
                "context_run_status",
                "context_runtime",
            ]
        )
    }

    private func makeReflector(
        _ transport:
            FakeTransport
    ) -> FederatedPeerReflector {
        FederatedPeerReflector(
            peer:
                FederationPeerConfiguration(
                    id:
                        "peer-b",
                    name:
                        "Peer B",
                    endpoint:
                        "http://127.0.0.1:8877/mcp",
                    tokenEnvironment:
                        "RIGHTCLICK_PEER_B_TOKEN"
                ),
            transport:
                transport
        )
    }

    private func remoteView(
        id: String,
        title: String
    ) -> CapabilityView {
        CapabilityView(
            Capability(
                id:
                    id,
                title:
                    title,
                source:
                    .system,
                provider:
                    CapabilityProvider(
                        name:
                            "Remote provider"
                    ),
                inputs: [
                    "public.plain-text"
                ],
                output: [
                    "public.json"
                ],
                safety:
                    .read,
                invocation:
                    .direct,
                supportLevel:
                    .publicSupported,
                requiresConfirmation:
                    false
            )
        )
    }
}
