@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

    func testLoopbackIPPeersCanonicalizeToLocalhostForTransport()
        throws
    {
        for endpoint in [
            "http://127.0.0.1:8877/mcp",
            "http://[::1]:8877/mcp",
            "http://localhost:8877/mcp",
        ] {
            let peer =
                FederationPeerConfiguration(
                    id:
                        "local",
                    name:
                        "Local RIGHTCLICK",
                    endpoint:
                        endpoint,
                    tokenEnvironment:
                        "RIGHTCLICK_LOCAL_TOKEN"
                )

            XCTAssertEqual(
                peer.endpointURL?.host,
                "localhost"
            )

            XCTAssertEqual(
                peer.endpointURL?.port,
                8877
            )

            XCTAssertEqual(
                peer.endpointURL?.path,
                "/mcp"
            )
        }
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

extension FederationTests {
    func testTypedExecutionResultSurvivesMCPTextWireRoundTrip() throws {
        let original = ExecutionRecord(
            executionId: "wire-execution",
            actionId: "remote:structured-result",
            title: "Remote structured result",
            state: .accepted,
            message: "Provider accepted.",
            output: #"{"id":"wire-001","value":"observed"}"#,
            result: .object([
                "id": .string("wire-001"),
                "value": .string("observed"),
            ]),
            events: [
                "provider accepted",
                "response observed",
            ],
            evidence: OutcomeEvidence(
                type: "provider_returned_text",
                boundary: "Provider response is observable; semantic outcome remains unverified.",
                outcomeVerified: false
            )
        )

        // This is the same JSON encoder used by context_run and
        // context_run_status before the MCP transport wraps it as text.
        let text = RightClickJSON.encode(original)

        let data = try XCTUnwrap(
            text.data(using: .utf8)
        )

        // Federation's production transport ultimately performs this exact
        // ExecutionRecord decode on the text returned by the remote MCP peer.
        let decoded = try JSONDecoder().decode(
            ExecutionRecord.self,
            from: data
        )

        XCTAssertEqual(decoded.executionId, "wire-execution")
        XCTAssertEqual(decoded.actionId, "remote:structured-result")
        XCTAssertEqual(decoded.state, .accepted)
        XCTAssertFalse(decoded.evidence.outcomeVerified)

        guard case let .object(result)? = decoded.result else {
            return XCTFail(
                "Expected typed CapabilityValue result to survive MCP JSON encoding and federation decoding."
            )
        }

        guard case let .string(id)? = result["id"] else {
            return XCTFail("Expected result.id to remain a typed string.")
        }

        guard case let .string(value)? = result["value"] else {
            return XCTFail("Expected result.value to remain a typed string.")
        }

        XCTAssertEqual(id, "wire-001")
        XCTAssertEqual(value, "observed")

        // Bidirectional observability must not promote provider acceptance
        // into semantic success.
        XCTAssertEqual(decoded.state, .accepted)
        XCTAssertFalse(decoded.evidence.outcomeVerified)
    }
}

private final class ObservablePeerReflector: CapabilityReflector {
    let id = "test.observable-peer"

    func capabilities(for item: ContentItem) throws -> [Capability] {
        [
            Capability(
                id: "test:observable-result",
                title: "Return structured result",
                source: .system,
                reflectorID: id,
                provider: CapabilityProvider(
                    name: "Deterministic observable peer"
                ),
                inputs: ["text"],
                output: ["typed structured result"],
                safety: .read,
                invocation: .direct,
                supportLevel: .experimental,
                requiresConfirmation: false
            )
        ]
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws -> ExecutionRecord {
        ExecutionRecord(
            executionId: executionID,
            actionId: capability.id,
            title: capability.title,
            state: .accepted,
            message: "Deterministic peer returned observable structured data.",
            output: #"{"source":"RIGHTCLICK-B","value":"observed"}"#,
            result: .object([
                "source": .string("RIGHTCLICK-B"),
                "value": .string("observed"),
            ]),
            events: [
                "provider accepted",
                "response observed",
            ],
            evidence: OutcomeEvidence(
                type: "provider_returned_text",
                boundary: "Returned provider data is observable; semantic outcome remains unverified.",
                outcomeVerified: false
            )
        )
    }
}

private final class FederationTestResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func result() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class FederationTestEngineReference: @unchecked Sendable {
    let engine: CapabilityEngine

    init(_ engine: CapabilityEngine) {
        self.engine = engine
    }
}

extension FederationTests {
    func testRealLoopbackMCPFederationCarriesTypedResultBetweenRuntimes() throws {
        let token = "rightclick-bidirectional-test-token"

        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let port = UInt16(30_000 + (pid % 20_000))

        // RIGHTCLICK B.
        let remoteEngine = CapabilityEngine(
            reflectors: [
                ObservablePeerReflector()
            ]
        )

        let dispatcher = HTTPRequestDispatcher(
            engine: EngineBox(remoteEngine),
            token: token,
            port: port
        )

        let listener = MCPHTTPListener(
            port: port,
            path: "/mcp"
        ) { request in
            await dispatcher.handle(request)
        }

        try listener.start()

        defer {
            listener.stop()
        }

        let peerEnvironment: [String: String] = [
            FederationPeerConfiguration.environmentKey:
                """
                [
                  {
                    "id": "peer-b",
                    "name": "RIGHTCLICK B",
                    "endpoint": "http://127.0.0.1:\(port)/mcp",
                    "tokenEnvironment": "RIGHTCLICK_B_TEST_TOKEN"
                  }
                ]
                """,
            "RIGHTCLICK_B_TEST_TOKEN": token,
        ]

        let federation = try XCTUnwrap(
            FederationPeerSource.fromEnvironment(peerEnvironment)
        )

        // RIGHTCLICK A.
        let localEngine = CapabilityEngine(
            reflectorSources: [
                federation
            ],
            experience: nil
        )

        let local = FederationTestEngineReference(localEngine)

        // A's federation API is intentionally synchronous. In production A and
        // B are independent runtimes/processes, so A blocking must not block B's
        // main queue. Run A on a worker while XCTest services B's main queue.
        let discoveryFinished = expectation(
            description: "RIGHTCLICK A discovers RIGHTCLICK B"
        )

        let discovery = FederationTestResultBox<Capability?>()

        DispatchQueue.global(qos: .userInitiated).async {
            discovery.store(
                Result {
                    try local.engine
                        .capabilities(for: "hello")
                        .capabilities
                        .first {
                            $0.title == "Return structured result"
                        }
                }
            )

            discoveryFinished.fulfill()
        }

        wait(
            for: [discoveryFinished],
            timeout: 15
        )

        let discovered = try XCTUnwrap(
            discovery.result(),
            "Federation discovery worker produced no result."
        ).get()

        let federatedCapability = try XCTUnwrap(
            discovered,
            "RIGHTCLICK A reached RIGHTCLICK B but did not discover its capability."
        )

        XCTAssertTrue(
            federatedCapability.id.hasPrefix("federation:peer-b:")
        )

        let invocationFinished = expectation(
            description: "RIGHTCLICK A invokes RIGHTCLICK B"
        )

        let invocation = FederationTestResultBox<ExecutionRecord>()

        DispatchQueue.global(qos: .userInitiated).async {
            invocation.store(
                Result {
                    try local.engine.begin(
                        id: federatedCapability.id,
                        item: "hello",
                        confirmed: true
                    )
                }
            )

            invocationFinished.fulfill()
        }

        wait(
            for: [invocationFinished],
            timeout: 15
        )

        let record = try XCTUnwrap(
            invocation.result(),
            "Federation invocation worker produced no result."
        ).get()

        // Real path:
        //
        // RIGHTCLICK A
        // -> FederationPeerTransport
        // -> URLSession
        // -> loopback HTTP
        // -> MCP tools/call
        // -> RIGHTCLICK B
        // -> ExecutionRecord
        // -> MCP text response
        // -> HTTP
        // -> federation decoder
        // -> RIGHTCLICK A.
        XCTAssertEqual(record.state, .accepted)
        XCTAssertFalse(record.evidence.outcomeVerified)

        guard case let .object(result)? = record.result else {
            return XCTFail(
                "Typed provider result did not survive the real RIGHTCLICK-to-RIGHTCLICK MCP/HTTP round trip."
            )
        }

        guard case let .string(source)? = result["source"] else {
            return XCTFail("Expected typed result.source.")
        }

        guard case let .string(value)? = result["value"] else {
            return XCTFail("Expected typed result.value.")
        }

        XCTAssertEqual(source, "RIGHTCLICK-B")
        XCTAssertEqual(value, "observed")

        // A's execution store must retain B's observable result.
        let stored = localEngine.executionStatus(
            record.executionId
        )

        guard case let .object(storedResult)? = stored.result else {
            return XCTFail(
                "RIGHTCLICK A did not retain RIGHTCLICK B's typed result."
            )
        }

        guard case let .string(storedSource)? = storedResult["source"] else {
            return XCTFail("Expected stored typed result.source.")
        }

        guard case let .string(storedValue)? = storedResult["value"] else {
            return XCTFail("Expected stored typed result.value.")
        }

        XCTAssertEqual(storedSource, "RIGHTCLICK-B")
        XCTAssertEqual(storedValue, "observed")

        // Observable provider output is still not semantic verification.
        XCTAssertEqual(stored.state, .accepted)
        XCTAssertFalse(stored.evidence.outcomeVerified)
    }
}


extension FederationTests {
    func testContextRunSchemaAdvertisesResultPathEquals() async throws {
        let token = "rightclick-schema-contract-test-token"

        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let port = UInt16(50_000 + (pid % 10_000))

        let engine = CapabilityEngine(
            reflectors: []
        )

        let dispatcher = HTTPRequestDispatcher(
            engine: EngineBox(engine),
            token: token,
            port: port
        )

        let listener = MCPHTTPListener(
            port: port,
            path: "/mcp"
        ) { request in
            await dispatcher.handle(request)
        }

        try listener.start()

        defer {
            listener.stop()
        }

        let url = try XCTUnwrap(
            URL(
                string:
                    "http://localhost:\(port)/mcp"
            )
        )

        var request = URLRequest(
            url: url
        )

        request.httpMethod = "POST"

        request.httpBody = Data(
            """
            {
              "jsonrpc": "2.0",
              "id": "schema-contract-test",
              "method": "tools/list",
              "params": {}
            }
            """.utf8
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Accept"
        )

        request.setValue(
            "2025-03-26",
            forHTTPHeaderField:
                "MCP-Protocol-Version"
        )

        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField:
                "Authorization"
        )

        let configuration =
            URLSessionConfiguration.ephemeral

        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10

        let session = URLSession(
            configuration: configuration
        )

        defer {
            session.invalidateAndCancel()
        }

        let (
            data,
            response
        ) = try await session.data(
            for: request
        )

        let http = try XCTUnwrap(
            response as? HTTPURLResponse
        )

        XCTAssertEqual(
            http.statusCode,
            200
        )

        let envelope = try XCTUnwrap(
            try JSONSerialization
                .jsonObject(
                    with: data
                ) as? [String: Any]
        )

        let result = try XCTUnwrap(
            envelope["result"]
                as? [String: Any]
        )

        let tools = try XCTUnwrap(
            result["tools"]
                as? [[String: Any]]
        )

        let run = try XCTUnwrap(
            tools.first {
                ($0["name"] as? String)
                    == "context_run"
            }
        )

        let inputSchema = try XCTUnwrap(
            run["inputSchema"]
                as? [String: Any]
        )

        let properties = try XCTUnwrap(
            inputSchema["properties"]
                as? [String: Any]
        )

        let verification = try XCTUnwrap(
            properties["verification"]
                as? [String: Any]
        )

        let verificationProperties =
            try XCTUnwrap(
                verification["properties"]
                    as? [String: Any]
            )

        let predicates = try XCTUnwrap(
            verificationProperties["predicates"]
                as? [String: Any]
        )

        let items = try XCTUnwrap(
            predicates["items"]
                as? [String: Any]
        )

        let predicateProperties =
            try XCTUnwrap(
                items["properties"]
                    as? [String: Any]
            )

        let type = try XCTUnwrap(
            predicateProperties["type"]
                as? [String: Any]
        )

        let values = try XCTUnwrap(
            type["enum"] as? [String]
        )

        XCTAssertTrue(
            values.contains(
                "result_path_equals"
            ),
            """
            context_run must advertise result_path_equals so an agent can
            discover typed-result verification without a new MCP operation.
            """
        )
    }
}

extension FederationTests {
    func testContextRunStatusCarriesTypedRCIREventPageOverRealMCP() async throws {
        let executionID =
            "typed-rcir-status-" + UUID().uuidString

        let original = ExecutionRecord(
            executionId: executionID,
            actionId: "test:typed-rcir-status",
            title: "Typed RCIR status",
            state: .accepted,
            message: "Provider accepted.",
            result: .object([
                "id": .string("mcp-status"),
                "value": .string("observed"),
            ]),
            evidence: OutcomeEvidence(
                type: "provider_returned_value",
                boundary:
                    "Provider response is observable; semantic success remains unverified.",
                outcomeVerified: false
            ),
            rcirEventPage: RCIRExecutionEventPage(
                events: [
                    RCIRExecutionEvent(
                        sequence: 1,
                        time: 1_000,
                        kind: "completed",
                        value: .object([
                            "id": .string("mcp-status"),
                            "value": .string("observed"),
                        ])
                    ),
                ],
                nextCursor: 1,
                hasMore: false,
                terminal: true
            )
        )

        ExecutionStore.shared.put(original)

        let token =
            "rightclick-status-event-test-token"

        let pid =
            Int(ProcessInfo.processInfo.processIdentifier)

        let port =
            UInt16(40_000 + (pid % 20_000))

        let engine = CapabilityEngine(
            reflectors: []
        )

        let dispatcher = HTTPRequestDispatcher(
            engine: EngineBox(engine),
            token: token,
            port: port
        )

        let listener = MCPHTTPListener(
            port: port,
            path: "/mcp"
        ) { request in
            await dispatcher.handle(request)
        }

        try listener.start()

        defer {
            listener.stop()
        }

        let url = try XCTUnwrap(
            URL(
                string:
                    "http"
                    + "://localhost:"
                    + String(port)
                    + "/mcp"
            )
        )

        let body = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "typed-status-event",
                "method": "tools/call",
                "params": [
                    "name": "context_run_status",
                    "arguments": [
                        "executionId": executionID,
                    ],
                ],
            ],
            options: [.sortedKeys]
        )

        var request = URLRequest(
            url: url
        )

        request.httpMethod = "POST"
        request.httpBody = body

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Accept"
        )

        request.setValue(
            "2025-03-26",
            forHTTPHeaderField:
                "MCP-Protocol-Version"
        )

        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField:
                "Authorization"
        )

        let configuration =
            URLSessionConfiguration.ephemeral

        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10

        let session = URLSession(
            configuration: configuration
        )

        defer {
            session.invalidateAndCancel()
        }

        let (responseData, response) =
            try await session.data(
                for: request
            )

        let http = try XCTUnwrap(
            response as? HTTPURLResponse
        )

        XCTAssertEqual(
            http.statusCode,
            200
        )

        let envelope = try XCTUnwrap(
            try JSONSerialization
                .jsonObject(
                    with: responseData
                )
                as? [String: Any]
        )

        let result = try XCTUnwrap(
            envelope["result"]
                as? [String: Any]
        )

        XCTAssertNotEqual(
            result["isError"] as? Bool,
            true
        )

        let content = try XCTUnwrap(
            result["content"]
                as? [[String: Any]]
        )

        let first = try XCTUnwrap(
            content.first
        )

        XCTAssertEqual(
            first["type"] as? String,
            "text"
        )

        let text = try XCTUnwrap(
            first["text"] as? String
        )

        let decoded =
            try JSONDecoder().decode(
                ExecutionRecord.self,
                from: Data(text.utf8)
            )

        XCTAssertEqual(
            decoded.executionId,
            executionID
        )

        XCTAssertEqual(
            decoded.state,
            .accepted
        )

        XCTAssertFalse(
            decoded.evidence.outcomeVerified
        )

        let page = try XCTUnwrap(
            decoded.rcirEventPage,
            "context_run_status lost the typed RCIR event page across real MCP/HTTP."
        )

        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.nextCursor, 1)
        XCTAssertFalse(page.hasMore)
        XCTAssertTrue(page.terminal)

        let event = try XCTUnwrap(
            page.events.first
        )

        XCTAssertEqual(event.sequence, 1)
        XCTAssertEqual(event.time, 1_000)
        XCTAssertEqual(event.kind, "completed")

        guard case let .object(value) = event.value else {
            return XCTFail(
                "Expected typed completed-event value after MCP round trip."
            )
        }

        guard case let .string(id)? = value["id"] else {
            return XCTFail(
                "Expected typed event value.id."
            )
        }

        guard case let .string(returnedValue)? =
            value["value"]
        else {
            return XCTFail(
                "Expected typed event value.value."
            )
        }

        XCTAssertEqual(id, "mcp-status")
        XCTAssertEqual(returnedValue, "observed")

        // Event observability still does not establish semantic success.
        XCTAssertEqual(decoded.state, .accepted)
        XCTAssertFalse(decoded.evidence.outcomeVerified)
    }
}

extension FederationTests {
    func testContextRunStatusSchemaAdvertisesCursorAndLimit() async throws {
        let token = "rightclick-pagination-schema-token"
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let port = UInt16(42_000 + (pid % 20_000))

        let engine = CapabilityEngine(
            reflectors: []
        )

        let dispatcher = HTTPRequestDispatcher(
            engine: EngineBox(engine),
            token: token,
            port: port
        )

        let listener = MCPHTTPListener(
            port: port,
            path: "/mcp"
        ) { request in
            await dispatcher.handle(request)
        }

        try listener.start()
        defer { listener.stop() }

        let url = try XCTUnwrap(
            URL(
                string:
                    "http://localhost:\(port)/mcp"
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        request.httpBody = Data(
            """
            {
              "jsonrpc": "2.0",
              "id": "pagination-schema",
              "method": "tools/list",
              "params": {}
            }
            """.utf8
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        request.setValue(
            "2025-03-26",
            forHTTPHeaderField: "MCP-Protocol-Version"
        )

        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )

        let configuration =
            URLSessionConfiguration.ephemeral

        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10

        let session = URLSession(
            configuration: configuration
        )

        defer {
            session.invalidateAndCancel()
        }

        let (data, response) =
            try await session.data(
                for: request
            )

        let http = try XCTUnwrap(
            response as? HTTPURLResponse
        )

        XCTAssertEqual(
            http.statusCode,
            200
        )

        let envelope = try XCTUnwrap(
            try JSONSerialization
                .jsonObject(with: data)
                as? [String: Any]
        )

        let result = try XCTUnwrap(
            envelope["result"]
                as? [String: Any]
        )

        let tools = try XCTUnwrap(
            result["tools"]
                as? [[String: Any]]
        )

        let statusTool = try XCTUnwrap(
            tools.first {
                ($0["name"] as? String)
                    == "context_run_status"
            }
        )

        let inputSchema = try XCTUnwrap(
            statusTool["inputSchema"]
                as? [String: Any]
        )

        let properties = try XCTUnwrap(
            inputSchema["properties"]
                as? [String: Any]
        )

        let cursor = try XCTUnwrap(
            properties["cursor"]
                as? [String: Any]
        )

        let limit = try XCTUnwrap(
            properties["limit"]
                as? [String: Any]
        )

        XCTAssertEqual(
            cursor["type"] as? String,
            "integer"
        )

        XCTAssertEqual(
            limit["type"] as? String,
            "integer"
        )

        XCTAssertEqual(
            RightClickMCPContract.toolNames().count,
            7
        )
    }

    func testContextRunStatusPagesRetainedHistoryOverRealMCP() async throws {
        let executionID =
            "mcp-pagination-" + UUID().uuidString

        let abi = CapabilityContract(
            capabilityID:
                "fixture:mcp-pagination",
            reflectorID:
                "r:mcp-pagination",
            providerID:
                "fixture",
            arguments:
                .object(
                    properties: [
                        "target": .string
                    ],
                    required: [
                        "target"
                    ]
                ),
            result:
                .integer,
            declaration:
                .string("fixture")
        )

        let contract = RCIRContract(
            abi: abi,
            scopes: [],
            task: .init(
                shape: .serverStream,
                element: .integer,
                maxEvents: 128
            )
        )

        let admission = RCIRAdmission()

        let binding = try admission.publish(
            contract,
            authenticatedPrincipal:
                "principal:mcp-pagination"
        )

        let policy = RCIRPolicy(
            revision: "1",
            principals: [
                "principal:mcp-pagination"
            ],
            scopes: []
        )

        let lease = try admission.issue(
            binding,
            arguments: .object([
                "target":
                    .string("urn:mcp-pagination")
            ]),
            authority: [],
            policy: policy,
            now: 100
        )

        try admission.consume(
            lease,
            arguments: lease.arguments,
            authority: [],
            policy: policy,
            now: 101
        )

        var task = try RCIRTask(
            lease: lease,
            startedAt: 101,
            deadline: 1_000
        )

        try task.record(
            .working,
            sequence: 1,
            now: 102
        )

        for sequence in 2...70 {
            try task.record(
                .chunk(
                    .integer(
                        Int64(sequence)
                    )
                ),
                sequence:
                    Int64(sequence),
                now:
                    Int64(101 + sequence)
            )
        }

        try task.record(
            .completed(.integer(7)),
            sequence: 71,
            now: 172
        )

        let host = RCIRExecutionHost()

        host.retainTerminalHistory(
            task,
            executionID: executionID
        )

        ExecutionStore.shared.put(
            ExecutionRecord(
                executionId: executionID,
                actionId:
                    "fixture:mcp-pagination",
                state: .accepted,
                message:
                    "Provider accepted.",
                evidence: OutcomeEvidence(
                    type:
                        "provider_completion",
                    boundary:
                        "Provider completion is observable but unverified.",
                    outcomeVerified:
                        false
                ),
                rcirEventPage:
                    try task.statusEventPage()
            )
        )

        let engine = CapabilityEngine(
            reflectors: [],
            experience: nil,
            rcirHost: host
        )

        let token =
            "rightclick-pagination-runtime-token"

        let pid =
            Int(
                ProcessInfo
                    .processInfo
                    .processIdentifier
            )

        let port =
            UInt16(
                43_000
                    + (pid % 20_000)
            )

        let dispatcher =
            HTTPRequestDispatcher(
                engine:
                    EngineBox(engine),
                token:
                    token,
                port:
                    port
            )

        let listener =
            MCPHTTPListener(
                port: port,
                path: "/mcp"
            ) { request in
                await dispatcher.handle(
                    request
                )
            }

        try listener.start()
        defer { listener.stop() }

        let url = try XCTUnwrap(
            URL(
                string:
                    "http://localhost:"
                    + String(port)
                    + "/mcp"
            )
        )

        let body =
            try JSONSerialization.data(
                withJSONObject: [
                    "jsonrpc": "2.0",
                    "id":
                        "pagination-runtime",
                    "method":
                        "tools/call",
                    "params": [
                        "name":
                            "context_run_status",
                        "arguments": [
                            "executionId":
                                executionID,
                            "cursor":
                                64,
                            "limit":
                                64,
                        ],
                    ],
                ],
                options: [.sortedKeys]
            )

        var request =
            URLRequest(
                url: url
            )

        request.httpMethod =
            "POST"

        request.httpBody =
            body

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Accept"
        )

        request.setValue(
            "2025-03-26",
            forHTTPHeaderField:
                "MCP-Protocol-Version"
        )

        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField:
                "Authorization"
        )

        let configuration =
            URLSessionConfiguration
                .ephemeral

        configuration
            .timeoutIntervalForRequest = 5

        configuration
            .timeoutIntervalForResource = 10

        let session =
            URLSession(
                configuration:
                    configuration
            )

        defer {
            session
                .invalidateAndCancel()
        }

        let (
            responseData,
            response
        ) =
            try await session.data(
                for: request
            )

        let http = try XCTUnwrap(
            response
                as? HTTPURLResponse
        )

        XCTAssertEqual(
            http.statusCode,
            200
        )

        let envelope =
            try XCTUnwrap(
                try JSONSerialization
                    .jsonObject(
                        with: responseData
                    )
                    as? [String: Any]
            )

        let result =
            try XCTUnwrap(
                envelope["result"]
                    as? [String: Any]
            )

        XCTAssertNotEqual(
            result["isError"]
                as? Bool,
            true
        )

        let content =
            try XCTUnwrap(
                result["content"]
                    as? [[String: Any]]
            )

        let first =
            try XCTUnwrap(
                content.first
            )

        let text =
            try XCTUnwrap(
                first["text"]
                    as? String
            )

        let decoded =
            try JSONDecoder()
                .decode(
                    ExecutionRecord.self,
                    from:
                        Data(text.utf8)
                )

        let page =
            try XCTUnwrap(
                decoded.rcirEventPage
            )

        XCTAssertEqual(
            page.events.count,
            7
        )

        XCTAssertEqual(
            page.nextCursor,
            71
        )

        XCTAssertFalse(
            page.hasMore
        )

        XCTAssertTrue(
            page.terminal
        )

        XCTAssertEqual(
            page.events.first?.sequence,
            65
        )

        XCTAssertEqual(
            page.events.last?.sequence,
            71
        )

        XCTAssertEqual(
            page.events.last?.kind,
            "completed"
        )

        guard
            case let .integer(value)? =
                page.events.last?.value
        else {
            return XCTFail(
                "Expected typed terminal event through paged MCP status."
            )
        }

        XCTAssertEqual(
            value,
            7
        )

        XCTAssertEqual(
            decoded.state,
            .accepted
        )

        XCTAssertFalse(
            decoded
                .evidence
                .outcomeVerified
        )
    }
}

extension FederationTests {
    func testContextRunStatusRejectsInvalidPaginationOverRealMCP() async throws {
        let token =
            "rightclick-pagination-validation-token"

        let pid =
            Int(ProcessInfo.processInfo.processIdentifier)

        let port =
            UInt16(
                44_000
                    + (pid % 20_000)
            )

        let engine = CapabilityEngine(
            reflectors: []
        )

        let dispatcher =
            HTTPRequestDispatcher(
                engine: EngineBox(engine),
                token: token,
                port: port
            )

        let listener =
            MCPHTTPListener(
                port: port,
                path: "/mcp"
            ) { request in
                await dispatcher.handle(request)
            }

        try listener.start()

        defer {
            listener.stop()
        }

        let url = try XCTUnwrap(
            URL(
                string:
                    "http://localhost:"
                    + String(port)
                    + "/mcp"
            )
        )

        let configuration =
            URLSessionConfiguration.ephemeral

        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10

        let session =
            URLSession(
                configuration: configuration
            )

        defer {
            session.invalidateAndCancel()
        }

        func invoke(
            arguments: [String: Any]
        ) async throws -> (Bool?, String) {
            let body =
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": UUID().uuidString,
                        "method": "tools/call",
                        "params": [
                            "name":
                                "context_run_status",
                            "arguments":
                                arguments,
                        ],
                    ],
                    options: [.sortedKeys]
                )

            var request =
                URLRequest(
                    url: url
                )

            request.httpMethod =
                "POST"

            request.httpBody =
                body

            request.setValue(
                "application/json",
                forHTTPHeaderField:
                    "Content-Type"
            )

            request.setValue(
                "application/json",
                forHTTPHeaderField:
                    "Accept"
            )

            request.setValue(
                "2025-03-26",
                forHTTPHeaderField:
                    "MCP-Protocol-Version"
            )

            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField:
                    "Authorization"
            )

            let (
                responseData,
                response
            ) =
                try await session.data(
                    for: request
                )

            let http =
                try XCTUnwrap(
                    response
                        as? HTTPURLResponse
                )

            XCTAssertEqual(
                http.statusCode,
                200
            )

            let envelope =
                try XCTUnwrap(
                    try JSONSerialization
                        .jsonObject(
                            with: responseData
                        )
                        as? [String: Any]
                )

            let result =
                try XCTUnwrap(
                    envelope["result"]
                        as? [String: Any]
                )

            let content =
                try XCTUnwrap(
                    result["content"]
                        as? [[String: Any]]
                )

            let first =
                try XCTUnwrap(
                    content.first
                )

            return (
                result["isError"]
                    as? Bool,
                first["text"]
                    as? String
                    ?? ""
            )
        }

        let negativeCursor =
            try await invoke(
                arguments: [
                    "executionId":
                        "missing",
                    "cursor":
                        -1,
                ]
            )

        XCTAssertEqual(
            negativeCursor.0,
            true
        )

        XCTAssertTrue(
            negativeCursor.1.contains(
                "cursor must be an integer greater than or equal to 0"
            )
        )

        let zeroLimit =
            try await invoke(
                arguments: [
                    "executionId":
                        "missing",
                    "limit":
                        0,
                ]
            )

        XCTAssertEqual(
            zeroLimit.0,
            true
        )

        XCTAssertTrue(
            zeroLimit.1.contains(
                "limit must be an integer from 1 through 256"
            )
        )

        let excessiveLimit =
            try await invoke(
                arguments: [
                    "executionId":
                        "missing",
                    "limit":
                        257,
                ]
            )

        XCTAssertEqual(
            excessiveLimit.0,
            true
        )

        XCTAssertTrue(
            excessiveLimit.1.contains(
                "limit must be an integer from 1 through 256"
            )
        )

        let wrongType =
            try await invoke(
                arguments: [
                    "executionId":
                        "missing",
                    "cursor":
                        "64",
                ]
            )

        XCTAssertEqual(
            wrongType.0,
            true
        )

        XCTAssertTrue(
            wrongType.1.contains(
                "cursor must be an integer greater than or equal to 0"
            )
        )
    }
}


extension FederationTests {
    func testContextRunStatusTransitionsLiveRCIROverRealMCP() async throws {
        let executionID =
            "mcp-live-deferred-"
            + UUID().uuidString

        let abi =
            CapabilityContract(
                capabilityID:
                    "fixture:mcp-live-deferred",
                reflectorID:
                    "r:mcp-live-deferred",
                providerID:
                    "fixture",
                arguments:
                    .object(
                        properties: [
                            "target": .string
                        ],
                        required: [
                            "target"
                        ]
                    ),
                result:
                    .integer,
                declaration:
                    .string(
                        "live deferred MCP fixture"
                    )
            )

        let contract =
            RCIRContract(
                abi: abi,
                scopes: [],
                task:
                    .init(
                        shape: .deferred,
                        maxEvents: 16,
                        maxBytes: 16_384
                    )
            )

        let admission =
            RCIRAdmission()

        let principal =
            "principal:mcp-live-deferred"

        let binding =
            try admission.publish(
                contract,
                authenticatedPrincipal:
                    principal
            )

        let arguments =
            CapabilityValue.object([
                "target":
                    .string(
                        "urn:mcp-live-deferred"
                    )
            ])

        let policy =
            RCIRPolicy(
                revision: "1",
                principals: [
                    principal
                ],
                scopes: []
            )

        let lease =
            try admission.issue(
                binding,
                arguments: arguments,
                authority: [],
                policy: policy,
                now: 100
            )

        try admission.consume(
            lease,
            arguments: arguments,
            authority: [],
            policy: policy,
            now: 101
        )

        let task =
            try RCIRTask(
                lease: lease,
                startedAt: 101,
                deadline: 1_000
            )

        let host =
            RCIRExecutionHost()

        host.now = { 103 }

        try host.registerActiveTask(
            task,
            executionID: executionID
        )

        ExecutionStore.shared.put(
            ExecutionRecord(
                executionId: executionID,
                actionId:
                    "fixture:mcp-live-deferred",
                title:
                    "Live deferred MCP fixture",
                state: .started,
                message:
                    "Execution is still running."
            )
        )

        try host.recordActiveTaskEvent(
            executionID: executionID,
            event: .accepted,
            now: 102
        )

        try host.recordActiveTaskEvent(
            executionID: executionID,
            event: .working,
            now: 103
        )

        let engine =
            CapabilityEngine(
                reflectors: [],
                experience: nil,
                rcirHost: host
            )

        let token =
            "rightclick-live-status-token"

        let pid =
            Int(
                ProcessInfo
                    .processInfo
                    .processIdentifier
            )

        var selectedPort:
            UInt16?

        var selectedListener:
            MCPHTTPListener?

        // Try several deterministic high ports so an unrelated process
        // occupying one port does not make the semantic test flaky.
        for attempt in 0..<12 {
            let candidate =
                UInt16(
                    44_000
                        + (
                            (
                                pid
                                    + attempt
                                        * 997
                            )
                            % 15_000
                        )
                )

            let dispatcher =
                HTTPRequestDispatcher(
                    engine:
                        EngineBox(engine),
                    token:
                        token,
                    port:
                        candidate
                )

            let listener =
                MCPHTTPListener(
                    port: candidate,
                    path: "/mcp"
                ) { request in
                    await dispatcher.handle(
                        request
                    )
                }

            do {
                try listener.start()

                selectedPort =
                    candidate

                selectedListener =
                    listener

                break
            } catch {
                listener.stop()
            }
        }

        let port =
            try XCTUnwrap(
                selectedPort,
                "Could not obtain a free loopback port for the real MCP test."
            )

        let listener =
            try XCTUnwrap(
                selectedListener
            )

        defer {
            listener.stop()
        }

        let url =
            try XCTUnwrap(
                URL(
                    string:
                        "http://localhost:"
                        + String(port)
                        + "/mcp"
                )
            )

        let configuration =
            URLSessionConfiguration
                .ephemeral

        configuration
            .timeoutIntervalForRequest = 5

        configuration
            .timeoutIntervalForResource = 10

        let session =
            URLSession(
                configuration:
                    configuration
            )

        defer {
            session.invalidateAndCancel()
        }

        func status(
            requestID: String
        ) async throws -> ExecutionRecord {
            let body =
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": requestID,
                        "method":
                            "tools/call",
                        "params": [
                            "name":
                                "context_run_status",
                            "arguments": [
                                "executionId":
                                    executionID,
                                "cursor":
                                    0,
                                "limit":
                                    64,
                            ],
                        ],
                    ],
                    options:
                        [.sortedKeys]
                )

            var request =
                URLRequest(
                    url: url
                )

            request.httpMethod =
                "POST"

            request.httpBody =
                body

            request.setValue(
                "application/json",
                forHTTPHeaderField:
                    "Content-Type"
            )

            request.setValue(
                "application/json",
                forHTTPHeaderField:
                    "Accept"
            )

            request.setValue(
                "2025-03-26",
                forHTTPHeaderField:
                    "MCP-Protocol-Version"
            )

            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField:
                    "Authorization"
            )

            let (
                responseData,
                response
            ) =
                try await session.data(
                    for: request
                )

            let http =
                try XCTUnwrap(
                    response
                        as? HTTPURLResponse
                )

            XCTAssertEqual(
                http.statusCode,
                200
            )

            let envelope =
                try XCTUnwrap(
                    try JSONSerialization
                        .jsonObject(
                            with:
                                responseData
                        )
                        as? [String: Any]
                )

            let result =
                try XCTUnwrap(
                    envelope["result"]
                        as? [String: Any]
                )

            XCTAssertNotEqual(
                result["isError"]
                    as? Bool,
                true
            )

            let content =
                try XCTUnwrap(
                    result["content"]
                        as? [[String: Any]]
                )

            let first =
                try XCTUnwrap(
                    content.first
                )

            let text =
                try XCTUnwrap(
                    first["text"]
                        as? String
                )

            return try JSONDecoder()
                .decode(
                    ExecutionRecord.self,
                    from:
                        Data(
                            text.utf8
                        )
                )
        }

        // First real MCP observation: task is genuinely live.
        let live =
            try await status(
                requestID:
                    "live-deferred-status"
            )

        let livePage =
            try XCTUnwrap(
                live.rcirEventPage
            )

        XCTAssertEqual(
            livePage.events.map(\.kind),
            [
                "accepted",
                "working",
            ]
        )

        XCTAssertEqual(
            livePage.nextCursor,
            2
        )

        XCTAssertFalse(
            livePage.hasMore
        )

        XCTAssertFalse(
            livePage.terminal
        )

        XCTAssertNil(
            live.rcir,
            "A live RCIR task must not manufacture terminal receipt evidence."
        )

        // The same execution becomes terminal later.
        let terminalTask =
            try XCTUnwrap(
                host.recordActiveTaskEvent(
                    executionID:
                        executionID,
                    event:
                        .completed(
                            .integer(7)
                        ),
                    now:
                        104
                )
            )

        XCTAssertEqual(
            terminalTask.phase,
            .completed
        )

        XCTAssertNoThrow(
            try terminalTask
                .receiptData()
        )

        // Second real MCP observation: immutable terminal history now wins.
        let terminal =
            try await status(
                requestID:
                    "terminal-deferred-status"
            )

        let terminalPage =
            try XCTUnwrap(
                terminal.rcirEventPage
            )

        XCTAssertEqual(
            terminalPage.events.map(\.kind),
            [
                "accepted",
                "working",
                "completed",
            ]
        )

        XCTAssertEqual(
            terminalPage.nextCursor,
            3
        )

        XCTAssertFalse(
            terminalPage.hasMore
        )

        XCTAssertTrue(
            terminalPage.terminal
        )

        guard
            case let .integer(value)? =
                terminalPage
                    .events
                    .last?
                    .value
        else {
            return XCTFail(
                "Expected typed completed result through the real MCP status wire."
            )
        }

        XCTAssertEqual(
            value,
            7
        )

        // Provider completion alone still does not prove semantic success.
        XCTAssertFalse(
            terminal
                .evidence
                .outcomeVerified
        )
    }
}
