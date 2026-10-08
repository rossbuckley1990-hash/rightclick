import Foundation
import RightClickProtocol

/// Implementations establish outbound sessions; they never forward a public
/// socket into localhost MCP. Relay delivery is not an execution outcome.
public protocol RemoteLinkTransport: AnyObject {
    func exchange(_ request: Data, targetRuntimeID: String) async throws -> Data
}

/// Deterministic relay fixture, with no sockets, secrets, or implicit startup.
/// Only the node can attach itself by establishing its outbound connection.
public actor SimulatedLinkRelay: RemoteLinkTransport {
    private var nodes: [String: RemoteExecutionDispatcher] = [:]
    private var dropNextResponse = false
    public init() {}
    func attachOutboundNode(_ node: RemoteExecutionDispatcher, runtimeID: String) {
        nodes[runtimeID] = node
    }
    public func disconnect(runtimeID: String) { nodes.removeValue(forKey: runtimeID) }
    public func loseNextResponse() { dropNextResponse = true }
    public func exchange(_ request: Data, targetRuntimeID: String) async throws -> Data {
        guard request.count <= RemoteWire.maximumWireBytes else { throw RemoteLinkError.limitExceeded }
        guard let node = nodes[targetRuntimeID] else { throw RemoteLinkError.unavailable }
        let response = try await node.handle(request)
        if dropNextResponse { dropNextResponse = false; throw RemoteLinkError.connectionLost }
        return response
    }
}

public final class RemoteLinkClient {
    public let identity: RemoteNodeIdentity
    public let target: RemoteNodeIdentityReference
    private let transport: any RemoteLinkTransport
    private let now: () -> Int64
    private struct ObservedExecution {
        let idempotencyKey: UUID
        let capabilityID: String?
        let capabilityDigest: String?
        var lifecycle: ExecutionLifecycle
        var events: [Int64: String] = [:]
        var resultDigest: String?
        var environmentEvidenceDigest: String?
    }
    private let observationLock = NSLock()
    private var observations: [String: ObservedExecution] = [:]
    public init(identity: RemoteNodeIdentity, trustedRuntimeKey: Data, transport: any RemoteLinkTransport,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        self.identity = identity; self.target = try .init(publicKey: trustedRuntimeKey)
        self.transport = transport; self.now = now
    }
    public func makeRequest(operation: RemoteOperation, item: String = "", capabilityID: String? = nil,
        capabilityDigest: String? = nil, arguments: CapabilityArguments? = nil,
        verification: VerificationSpec? = nil, idempotencyKey: UUID = UUID()) -> RemoteExecutionRequest {
        let stamp = now()
        var random = SystemRandomNumberGenerator()
        return RemoteExecutionRequest(idempotencyKey: idempotencyKey, issuedAtMilliseconds: stamp,
            expiresAtMilliseconds: stamp > Int64.max - 60_000 ? stamp : stamp + 60_000, targetRuntimeID: target.runtimeID,
            targetDeviceID: target.deviceID, callerID: RemoteWire.digest(identity.publicKey),
            nonce: Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }),
            operation: operation, capabilityID: capabilityID, capabilityDigest: capabilityDigest,
            item: item, arguments: arguments, verification: verification)
    }
    public func makeStatusRequest(for original: RemoteExecutionRequest, executionID: String,
        originatingRequestID: UUID? = nil, cursor: Int64 = 0, limit: Int = 64,
        maximumBytes: Int = 16_384) -> RemoteExecutionRequest {
        var request = makeRequest(operation: .status, capabilityID: original.capabilityID,
            capabilityDigest: original.capabilityDigest, idempotencyKey: original.idempotencyKey)
        request.status = .init(originatingRequestID: originatingRequestID ?? original.requestID,
            executionID: executionID, cursor: cursor, limit: limit, maximumBytes: maximumBytes)
        return request
    }
    public func send(_ request: RemoteExecutionRequest) async throws -> RemoteExecutionResult {
        guard request.targetRuntimeID == target.runtimeID, request.targetDeviceID == target.deviceID,
              request.callerID == RemoteWire.digest(identity.publicKey) else { throw RemoteLinkError.wrongRuntime }
        try request.validate(now: now())
        let bytes = try SignedRemoteMessage.request(request, signer: identity)
        let response = try await transport.exchange(bytes, targetRuntimeID: target.runtimeID)
        let result = try SignedRemoteMessage.verifiedResult(response, for: bytes, trustedRuntimeKey: target.publicKey)
        try observe(result.summary, for: request)
        return result
    }
    private func observe(_ summary: RemoteExecutionSummary, for request: RemoteExecutionRequest) throws {
        guard let live = summary.executionLifecycle else { return }
        guard live.runtimeID == target.runtimeID else { throw RemoteLinkError.wrongRuntime }
        observationLock.lock(); defer { observationLock.unlock() }
        guard observations.count < 1024 || observations[live.executionID] != nil else { throw RemoteLinkError.limitExceeded }
        let previous = observations[live.executionID]
        var seen = previous ?? ObservedExecution(idempotencyKey: request.idempotencyKey,
            capabilityID: request.capabilityID, capabilityDigest: request.capabilityDigest, lifecycle: live)
        guard seen.idempotencyKey == request.idempotencyKey, seen.capabilityID == request.capabilityID,
              seen.capabilityDigest == request.capabilityDigest, seen.lifecycle.executionID == live.executionID,
              seen.lifecycle.originatingRequestID == live.originatingRequestID,
              seen.lifecycle.taskID == live.taskID, seen.lifecycle.generation == live.generation,
              seen.lifecycle.runtimeID == live.runtimeID, seen.lifecycle.taskShape == live.taskShape
        else { throw RemoteLinkError.staleGeneration }
        guard live.sequence >= seen.lifecycle.sequence else { throw RemoteLinkError.invalidSequence }
        if previous?.lifecycle.terminal == true {
            guard try RemoteWire.encode(seen.lifecycle) == RemoteWire.encode(live),
                  seen.resultDigest == (try summary.result.map({ RemoteWire.digest(try $0.canonicalData()) })),
                  seen.environmentEvidenceDigest == (try summary.environmentEvidence.map({ RemoteWire.digest(try RemoteWire.encode($0)) }))
            else { throw RemoteLinkError.inconsistentResult }
        }
        for event in summary.eventPage?.events ?? [] {
            let digest = RemoteWire.digest(try event.canonicalData())
            guard seen.events[event.sequence] == nil || seen.events[event.sequence] == digest else { throw RemoteLinkError.invalidSequence }
            seen.events[event.sequence] = digest
        }
        seen.lifecycle = live
        seen.resultDigest = try summary.result.map { RemoteWire.digest(try $0.canonicalData()) }
        seen.environmentEvidenceDigest = try summary.environmentEvidence.map { RemoteWire.digest(try RemoteWire.encode($0)) }
        observations[live.executionID] = seen
    }

}

public struct RemoteNodeIdentityReference {
    public let publicKey: Data
    public var runtimeID: String { RemoteWire.runtimeID(publicKey) }
    public var deviceID: String { RemoteWire.deviceID(publicKey) }
    public init(publicKey: Data) throws {
        guard publicKey.count == 32 else { throw RemoteLinkError.malformed }; self.publicKey = publicKey
    }
}
