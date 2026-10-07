import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MCP
import RightClickCore

struct FederationPeerConfiguration:
    Codable,
    Sendable,
    Equatable
{
    var id: String
    var name: String
    var endpoint: String
    var tokenEnvironment: String

    static let environmentKey =
        "RIGHTCLICK_FEDERATION_PEERS"

    static func load(
        environment:
            [String: String]
    ) -> [FederationPeerConfiguration] {
        guard
            let raw =
                environment[
                    environmentKey
                ],
            let data =
                raw.data(
                    using: .utf8
                ),
            let decoded =
                try? JSONDecoder()
                    .decode(
                        [
                            FederationPeerConfiguration
                        ].self,
                        from:
                            data
                    )
        else {
            return []
        }

        var seen =
            Set<String>()

        return decoded
            .filter {
                peer in

                peer.isValid
                && seen.insert(
                    peer.id
                ).inserted
            }
            .sorted {
                $0.id < $1.id
            }
    }

    var endpointURL: URL? {
        guard
            var components =
                URLComponents(
                    string:
                        endpoint
                ),
            components.scheme?
                .lowercased()
                == "http",
            let rawHost =
                components.host?
                    .lowercased(),
            let host =
                Self.canonicalLoopbackHost(
                    rawHost
                ),
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path
                == "/mcp"
        else {
            return nil
        }

        components.scheme =
            "http"

        // macOS 14+ ATS blocks cleartext URLSession loads to IP
        // addresses. The value above has already been proven to be
        // loopback-only, so canonicalize IP literals to localhost
        // before the MCP HTTP client sees them.
        components.host =
            host == "localhost"
            ? host
            : "localhost"

        return components.url
    }

    private static func canonicalLoopbackHost(
        _ rawHost: String
    ) -> String? {
        let host: String

        if
            rawHost.hasPrefix("["),
            rawHost.hasSuffix("]"),
            rawHost.count >= 2
        {
            host =
                String(
                    rawHost
                        .dropFirst()
                        .dropLast()
                )
        } else {
            host =
                rawHost
        }

        guard
            [
                "localhost",
                "127.0.0.1",
                "::1",
            ].contains(
                host
            )
        else {
            return nil
        }

        return host
    }

    private var isValid: Bool {
        guard
            isIdentifier(
                id
            ),
            !name.isEmpty,
            name.count <= 128,
            name
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                == name,
            name.rangeOfCharacter(
                from:
                    .controlCharacters
            ) == nil,
            isEnvironmentName(
                tokenEnvironment
            ),
            endpointURL != nil
        else {
            return false
        }

        return true
    }

    private func isIdentifier(
        _ value: String
    ) -> Bool {
        guard
            !value.isEmpty,
            value.count <= 64
        else {
            return false
        }

        return value
            .unicodeScalars
            .allSatisfy {
                scalar in

                let raw =
                    scalar.value

                return
                    (raw >= 48
                        && raw <= 57)
                    || (raw >= 65
                        && raw <= 90)
                    || (raw >= 97
                        && raw <= 122)
                    || raw == 45
                    || raw == 46
                    || raw == 95
            }
    }

    private func isEnvironmentName(
        _ value: String
    ) -> Bool {
        guard
            !value.isEmpty,
            value.count <= 128
        else {
            return false
        }

        return value
            .unicodeScalars
            .allSatisfy {
                scalar in

                let raw =
                    scalar.value

                return
                    (raw >= 48
                        && raw <= 57)
                    || (raw >= 65
                        && raw <= 90)
                    || (raw >= 97
                        && raw <= 122)
                    || raw == 95
            }
    }
}

protocol FederationPeerTransport:
    AnyObject
{
    func runtime()
        throws -> RightClickRuntimeIdentity

    func actions(
        item: String
    ) throws -> [CapabilityView]

    func run(
        item: String,
        actionID: String,
        arguments: CapabilityArguments?,
        verification: VerificationSpec?
    ) throws -> ExecutionRecord
}

final class FederationPeerSource:
    CapabilityReflectorSource
{
    let id =
        "federation.mcp"

    typealias TransportFactory =
        (
            FederationPeerConfiguration,
            String
        ) -> any FederationPeerTransport

    private let peers:
        [FederationPeerConfiguration]

    private let environment:
        [String: String]

    private let transportFactory:
        TransportFactory

    init(
        peers:
            [FederationPeerConfiguration],
        environment:
            [String: String],
        transportFactory:
            @escaping TransportFactory
    ) {
        self.peers =
            peers

        self.environment =
            environment

        self.transportFactory =
            transportFactory
    }

    static func fromEnvironment(
        _ environment:
            [String: String] =
                ProcessInfo
                    .processInfo
                    .environment
    ) -> FederationPeerSource? {
        let peers =
            FederationPeerConfiguration
                .load(
                    environment:
                        environment
                )

        guard
            !peers.isEmpty
        else {
            return nil
        }

        return FederationPeerSource(
            peers:
                peers,
            environment:
                environment,
            transportFactory: {
                peer,
                token in

                MCPFederationPeerTransport(
                    peer:
                        peer,
                    token:
                        token
                )
            }
        )
    }

    func reflectors()
        -> [any CapabilityReflector]
    {
        peers.compactMap {
            peer in

            guard
                let token =
                    environment[
                        peer
                            .tokenEnvironment
                    ],
                !token.isEmpty
            else {
                return nil
            }

            return FederatedPeerReflector(
                peer:
                    peer,
                transport:
                    transportFactory(
                        peer,
                        token
                    )
            )
        }
    }
}

final class FederatedPeerReflector:
    CapabilityVerificationReflector
{
    let id: String

    private let peer:
        FederationPeerConfiguration

    private let transport:
        any FederationPeerTransport

    private let stateLock =
        NSLock()

    private var lastCapabilityTitles:
        [String] = []

    init(
        peer:
            FederationPeerConfiguration,
        transport:
            any FederationPeerTransport
    ) {
        self.peer =
            peer

        self.transport =
            transport

        self.id =
            "federation.peer.\(peer.id)"
    }

    func capabilities(
        for item: ContentItem
    ) throws -> [Capability] {
        do {
            let runtime =
                try transport.runtime()

            guard
                runtime.product
                    == "RIGHTCLICK"
            else {
                replaceTitles(
                    []
                )

                return []
            }

            let actions =
                try transport.actions(
                    item:
                        rawItem(
                            item
                        )
                )

            let reflected =
                actions.compactMap {
                    action
                        -> Capability? in

                    guard
                        !action.id
                            .hasPrefix(
                                "federation:"
                            ),
                        action.source
                            != CapabilitySource
                                .sharingService
                                .rawValue,
                        action.invocation
                            != CapabilityInvocation
                                .unsupported
                                .rawValue
                    else {
                        return nil
                    }

                    let safety =
                        CapabilitySafety(
                            rawValue:
                                action.safety
                        )
                        ?? .unknown

                    let invocation =
                        CapabilityInvocation(
                            rawValue:
                                action.invocation
                        )
                        ?? .unsupported

                    return Capability(
                        id:
                            "federation:\(peer.id):\(action.id)",
                        title:
                            action.title,
                        source:
                            .system,
                        reflectorID:
                            id,
                        provider:
                            CapabilityProvider(
                                name:
                                    peer.name
                            ),
                        inputs:
                            action.inputTypes,
                        output:
                            [],
                        safety:
                            safety,
                        invocation:
                            invocation,
                        supportLevel:
                            .experimental,
                        requiresConfirmation:
                            true,
                        metadata: [
                            "federationPeerID":
                                peer.id,

                            "federationRemoteActionID":
                                action.id,

                            "federationRemoteSource":
                                action.source,

                            "federationRuntimeSHA256":
                                runtime
                                    .executableSHA256,
                        ]
                    )
                }

            replaceTitles(
                reflected.map(
                    \.title
                )
            )

            return reflected
        } catch {
            replaceTitles(
                []
            )

            return []
        }
    }

    func providers()
        -> [ProviderSummary]
    {
        stateLock.lock()

        let titles =
            lastCapabilityTitles

        stateLock.unlock()

        return [
            ProviderSummary(
                name:
                    peer.name,
                bundleIdentifier:
                    nil,
                source:
                    "federation",
                capabilityTitles:
                    titles
            )
        ]
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String
    ) throws -> ExecutionRecord {
        try execute(
            capability:
                capability,
            item:
                item,
            executionID:
                executionID,
            arguments:
                nil,
            verification:
                nil
        )
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments: CapabilityArguments?
    ) throws -> ExecutionRecord {
        try execute(
            capability:
                capability,
            item:
                item,
            executionID:
                executionID,
            arguments:
                arguments,
            verification:
                nil
        )
    }

    func begin(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments: CapabilityArguments?,
        verification: VerificationSpec
    ) throws -> ExecutionRecord {
        try execute(
            capability:
                capability,
            item:
                item,
            executionID:
                executionID,
            arguments:
                arguments,
            verification:
                verification
        )
    }

    private func execute(
        capability: Capability,
        item: ContentItem,
        executionID: String,
        arguments: CapabilityArguments?,
        verification: VerificationSpec?
    ) throws -> ExecutionRecord {
        guard
            let remoteActionID =
                capability
                    .metadata[
                        "federationRemoteActionID"
                    ],
            !remoteActionID
                .hasPrefix(
                    "federation:"
                )
        else {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .rejected,
                message:
                    "Federated capability identity is invalid.",
                events: [
                    "federation rejected"
                ]
            )
        }

        do {
            var remote =
                try transport.run(
                    item:
                        rawItem(
                            item
                        ),
                    actionID:
                        remoteActionID,
                    arguments:
                        arguments,
                    verification:
                        verification
                )

            guard
                remote.actionId
                    == remoteActionID
            else {
                return ExecutionRecord(
                    executionId:
                        executionID,
                    actionId:
                        capability.id,
                    title:
                        capability.title,
                    state:
                        .failed,
                    message:
                        "Federated peer returned an execution for a different capability.",
                    events: [
                        "federation peer \(peer.id)",
                        "remote action identity mismatch",
                    ]
                )
            }

            let remoteExecutionID =
                remote.executionId

            remote.executionId =
                executionID

            remote.actionId =
                capability.id

            remote.title =
                capability.title

            remote.events.append(
                "federation peer \(peer.id)"
            )

            remote.events.append(
                "remote execution \(remoteExecutionID)"
            )

            if verification != nil,
               remote.state
                    == .succeeded,
               (
                    remote
                        .verification?
                        .status
                        != .verifiedSuccess
                    || !remote
                        .evidence
                        .outcomeVerified
               )
            {
                remote.state =
                    .accepted

                remote.message =
                    "Federated peer did not return complete verification evidence; semantic success is unverified."

                remote.evidence =
                    OutcomeEvidence(
                        type:
                            "delegated_verification_incomplete",
                        boundary:
                            "Remote execution did not establish VERIFIED_SUCCESS with outcomeVerified=true.",
                        outcomeVerified:
                            false
                    )
            }

            return remote
        } catch {
            return ExecutionRecord(
                executionId:
                    executionID,
                actionId:
                    capability.id,
                title:
                    capability.title,
                state:
                    .unavailable,
                message:
                    "Federated RIGHTCLICK peer is unavailable.",
                events: [
                    "federation peer \(peer.id)",
                    "peer request failed",
                ]
            )
        }
    }

    private func rawItem(
        _ item: ContentItem
    ) -> String {
        item.path
        ?? item.url
        ?? item.text
        ?? item.display
    }

    private func replaceTitles(
        _ titles: [String]
    ) {
        stateLock.lock()

        lastCapabilityTitles =
            titles.sorted()

        stateLock.unlock()
    }
}

private final class MCPFederationPeerTransport:
    FederationPeerTransport,
    @unchecked Sendable
{
    private let peer:
        FederationPeerConfiguration

    private let token: String

    init(
        peer:
            FederationPeerConfiguration,
        token: String
    ) {
        self.peer =
            peer

        self.token =
            token
    }

    func runtime()
        throws -> RightClickRuntimeIdentity
    {
        try callTool(
            name:
                "context_runtime",
            arguments:
                nil
        )
    }

    func actions(
        item: String
    ) throws -> [CapabilityView] {
        let payload:
            FederationActionsPayload =
                try callTool(
                    name:
                        "context_actions",
                    arguments: [
                        "item":
                            .string(
                                item
                            )
                    ]
                )

        return payload.actions
    }

    func run(
        item: String,
        actionID: String,
        arguments: CapabilityArguments?,
        verification: VerificationSpec?
    ) throws -> ExecutionRecord {
        var values:
            [String: Value] = [
                "item":
                    .string(
                        item
                    ),

                "actionId":
                    .string(
                        actionID
                    ),

                "confirmed":
                    .bool(
                        true
                    ),
            ]

        if let arguments {
            values[
                "arguments"
            ] =
                .object(
                    arguments.mapValues {
                        .string(
                            $0
                        )
                    }
                )
        }

        if let verification {
            values[
                "verification"
            ] =
                try Value(
                    verification
                )
        }

        return try callTool(
            name:
                "context_run",
            arguments:
                values
        )
    }

    private func callTool<
        ResultType:
            Decodable & Sendable
    >(
        name: String,
        arguments:
            [String: Value]?
    ) throws -> ResultType {
        guard
            let endpoint =
                peer.endpointURL
        else {
            throw RightClickError(
                "Federation peer endpoint is invalid."
            )
        }

        let body =
            try JSONEncoder()
                .encode(
                    FederationJSONRPCToolRequest(
                        id:
                            UUID()
                                .uuidString,
                        name:
                            name,
                        arguments:
                            arguments
                    )
                )

        var request =
            URLRequest(
                url:
                    endpoint
            )

        request.httpMethod =
            "POST"

        request.httpBody =
            body

        request.timeoutInterval =
            10

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

        return try waitForFederation {
            let configuration =
                URLSessionConfiguration
                    .ephemeral

            configuration
                .timeoutIntervalForRequest =
                    5

            configuration
                .timeoutIntervalForResource =
                    10

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
                try await session
                    .data(
                        for:
                            request
                    )

            guard
                let http =
                    response
                        as? HTTPURLResponse
            else {
                throw RightClickError(
                    "Federated peer returned no HTTP response."
                )
            }

            guard
                http.statusCode
                    == 200
            else {
                throw RightClickError(
                    "Federated peer returned HTTP \(http.statusCode)."
                )
            }

            let envelope =
                try JSONDecoder()
                    .decode(
                        FederationJSONRPCResponse.self,
                        from:
                            responseData
                    )

            if let error =
                envelope.error
            {
                throw RightClickError(
                    "Federated peer JSON-RPC error \(error.code): \(error.message)"
                )
            }

            guard
                let result =
                    envelope.result,
                result.isError
                    != true,
                let first =
                    result.content
                        .first,
                first.type
                    == "text",
                let text =
                    first.text,
                let data =
                    text.data(
                        using:
                            .utf8
                    )
            else {
                throw RightClickError(
                    "Federated peer returned no decodable text result."
                )
            }

            return try JSONDecoder()
                .decode(
                    ResultType.self,
                    from:
                        data
                )
        }
    }
}

private struct FederationJSONRPCToolRequest:
    Encodable
{
    let jsonrpc =
        "2.0"

    let id:
        String

    let method =
        "tools/call"

    let params:
        FederationJSONRPCToolParameters

    init(
        id: String,
        name: String,
        arguments:
            [String: Value]?
    ) {
        self.id =
            id

        self.params =
            FederationJSONRPCToolParameters(
                name:
                    name,
                arguments:
                    arguments
            )
    }
}

private struct FederationJSONRPCToolParameters:
    Encodable
{
    let name:
        String

    let arguments:
        [String: Value]?
}

private struct FederationJSONRPCResponse:
    Decodable
{
    let result:
        FederationJSONRPCToolResult?

    let error:
        FederationJSONRPCError?
}

private struct FederationJSONRPCError:
    Decodable
{
    let code:
        Int

    let message:
        String
}

private struct FederationJSONRPCToolResult:
    Decodable
{
    let content:
        [FederationJSONRPCContent]

    let isError:
        Bool?
}

private struct FederationJSONRPCContent:
    Decodable
{
    let type:
        String

    let text:
        String?
}
private struct FederationActionsPayload:
    Codable,
    Sendable
{
    var actions:
        [CapabilityView]
}

private final class FederationResultBox<
    ValueType
>:
    @unchecked Sendable
{
    private let lock =
        NSLock()

    private let semaphore =
        DispatchSemaphore(
            value:
                0
        )

    private var result:
        Result<
            ValueType,
            Error
        >?

    func finish(
        _ result:
            Result<
                ValueType,
                Error
            >
    ) {
        lock.lock()

        self.result =
            result

        lock.unlock()

        semaphore.signal()
    }

    func wait(
        timeoutSeconds:
            Int
    ) throws -> ValueType {
        let waitResult =
            semaphore.wait(
                timeout:
                    .now()
                    + .seconds(
                        timeoutSeconds
                    )
            )

        guard
            waitResult
                == .success
        else {
            throw RightClickError(
                "Federated peer request timed out."
            )
        }

        lock.lock()

        let result =
            self.result

        lock.unlock()

        guard
            let result
        else {
            throw RightClickError(
                "Federated peer request produced no result."
            )
        }

        return try result.get()
    }
}

private func waitForFederation<
    ValueType:
        Sendable
>(
    _ operation:
        @escaping
        @Sendable
        () async throws
        -> ValueType
) throws -> ValueType {
    let box =
        FederationResultBox<
            ValueType
        >()

    Task.detached {
        do {
            box.finish(
                .success(
                    try await operation()
                )
            )
        } catch {
            box.finish(
                .failure(
                    error
                )
            )
        }
    }

    return try box.wait(
        timeoutSeconds:
            12
    )
}
