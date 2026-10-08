import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum RemoteLinkError: String, Error, Codable {
    case disabled, malformed, inconsistentResult, limitExceeded, unsupportedVersion, unsupportedOperation
    case unauthenticated, unauthorized, wrongRuntime, expired, replay, idempotencyConflict
    case storageUnavailable, clockRollback, unavailable, connectionLost, executionUncertain
}

/// The existing seven operation names remain the protocol vocabulary. v1 admits
/// contextual discovery and execution only; other operations fail closed.
public enum RemoteOperation: String, Codable {
    case runtime = "context_runtime", inspect = "context_inspect", actions = "context_actions"
    case explain = "context_explain", run = "context_run", status = "context_run_status"
    case providers = "context_providers"
}

public struct RemoteExecutionRequest: Codable {
    public var version: Int = 1
    public var requestID: UUID
    public var idempotencyKey: UUID
    public var issuedAtMilliseconds: Int64
    public var expiresAtMilliseconds: Int64
    public var targetRuntimeID: String
    public var targetDeviceID: String
    public var callerID: String
    public var nonce: Data
    public var operation: RemoteOperation
    public var capabilityID: String?
    public var capabilityDigest: String?
    public var executionID: String?
    public var item: String
    public var arguments: CapabilityArguments?
    public var verification: VerificationSpec?

    public init(requestID: UUID = UUID(), idempotencyKey: UUID = UUID(),
                issuedAtMilliseconds: Int64, expiresAtMilliseconds: Int64,
                targetRuntimeID: String, targetDeviceID: String, callerID: String,
                nonce: Data, operation: RemoteOperation, capabilityID: String? = nil,
                capabilityDigest: String? = nil, executionID: String? = nil, item: String,
                arguments: CapabilityArguments? = nil, verification: VerificationSpec? = nil) {
        self.requestID = requestID; self.idempotencyKey = idempotencyKey
        self.issuedAtMilliseconds = issuedAtMilliseconds; self.expiresAtMilliseconds = expiresAtMilliseconds
        self.targetRuntimeID = targetRuntimeID; self.targetDeviceID = targetDeviceID
        self.callerID = callerID; self.nonce = nonce; self.operation = operation
        self.capabilityID = capabilityID; self.capabilityDigest = capabilityDigest; self.executionID = executionID
        self.item = item; self.arguments = arguments; self.verification = verification
    }

    func validate(now: Int64) throws {
        guard version == 1 else { throw RemoteLinkError.unsupportedVersion }
        guard operation == .run || operation == .actions || operation == .runtime || operation == .status else { throw RemoteLinkError.unsupportedOperation }
        guard nonce.count == 32, RemoteWire.isDigest(callerID),
              item.utf8.count <= 8192, (arguments?.count ?? 0) <= 64,
              arguments?.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 8192 }) ?? true
        else { throw RemoteLinkError.malformed }
        if operation == .run || operation == .status {
            guard let capabilityID, RemoteWire.isIdentifier(capabilityID),
                  let capabilityDigest, RemoteWire.isDigest(capabilityDigest) else { throw RemoteLinkError.malformed }
        } else {
            guard capabilityID == nil, capabilityDigest == nil, arguments == nil, verification == nil
            else { throw RemoteLinkError.malformed }
        }
        if operation == .status {
            guard let executionID, UUID(uuidString: executionID)?.uuidString == executionID,
                  arguments == nil, verification == nil else { throw RemoteLinkError.malformed }
        } else if executionID != nil { throw RemoteLinkError.malformed }
        if let verification {
            guard verification.predicates.allSatisfy({ $0.type == .textEquals && $0.key == nil && $0.reference == nil && $0.width == nil && $0.height == nil && $0.bytes == nil && ($0.value?.utf8.count ?? 0) <= 8192 }), (1...16).contains(verification.predicates.count),
                  (0...60_000).contains(verification.timeoutMilliseconds ?? 0) else { throw RemoteLinkError.malformed }
        }
        // Positive bounds prevent subtraction overflow. Host clock is authoritative.
        guard issuedAtMilliseconds > 0, issuedAtMilliseconds <= now,
              expiresAtMilliseconds > now, expiresAtMilliseconds > issuedAtMilliseconds,
              expiresAtMilliseconds - issuedAtMilliseconds <= 60_000 else { throw RemoteLinkError.expired }
    }

    func intentDigest() throws -> String {
        var intent = self
        // Envelope freshness varies on a retry; operation, caller, target, key,
        // contract, inputs and postconditions remain byte-bound to the intent.
        intent.requestID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        intent.nonce = Data(); intent.issuedAtMilliseconds = 0; intent.expiresAtMilliseconds = 0
        return RemoteWire.digest(Data("RIGHTCLICK-LINK-INTENT-1\0".utf8) + (try RemoteWire.encode(intent)))
    }
}

/// A grant is provisioned on the Mac, never read from a relay/request. Public
/// keys authenticate callers; exact capability IDs independently restrict them.
public struct RemoteCallerGrant {
    public let publicKey: Data
    public let operations: Set<RemoteOperation>
    public let capabilityIDs: Set<String>
    public var callerID: String { RemoteWire.digest(publicKey) }

    public init(publicKey: Data, operations: Set<RemoteOperation>, capabilityIDs: Set<String>) throws {
        guard publicKey.count == 32, operations.isSubset(of: [.runtime, .actions, .run, .status]),
              capabilityIDs.count <= 128, capabilityIDs.allSatisfy(RemoteWire.isIdentifier)
        else { throw RemoteLinkError.malformed }
        self.publicKey = publicKey; self.operations = operations; self.capabilityIDs = capabilityIDs
    }
}

public struct RemoteCapabilityDescriptor: Codable {
    public let id: String
    public let contractDigest: String
    public let title: String
    public let safety: CapabilitySafety
    public let invocation: CapabilityInvocation
    public let supportLevel: SupportLevel
    public let runtimeRequirements: RuntimeRequirements?
    public let requiresConfirmation: Bool
    // Only explicitly granted capability declarations enter this projection.
}

public struct RemoteRuntimeDescriptor: Codable {
    public let version: Int
    public let runtimeID: String
    public let deviceID: String
    public let operatingSystem: RuntimeOperatingSystem
    public let architecture: String
    public let operations: [RemoteOperation]
    // Presence belongs to the live transport session, never to a cached descriptor.
}

public enum RemoteLifecycleState: String, Codable {
    case requested, authorized, delivered, executing, providerAccepted, providerRejected
    case verified, unverified, awaitingUser, unknown, discovered
}
public enum RemotePolicyDecision: String, Codable { case evaluated, confirmationRequired, denied, notEvaluated }
public typealias RemoteObservationBoundary = OutcomeObservationBoundary
public enum RemoteProviderAcceptance: String, Codable { case accepted, rejected, notInvoked, unknown }

/// Fixed, privacy-minimized summary. Raw provider output, diagnostics, arguments,
/// observation values and RCIR receipts never enter Link messages or its journal.
public struct RemoteExecutionSummary: Codable {
    public var state: ExecutionState?
    public var policy: RemotePolicyDecision = .notEvaluated
    public var providerAcceptance: RemoteProviderAcceptance = .notInvoked
    public var verification: OutcomeVerificationStatus = .unverified
    public var observationBoundary: RemoteObservationBoundary = .none
    public var runtime: RemoteRuntimeDescriptor?
    public var evidenceExecutionID: String?
    /// Closed RCIR task phase only; no provider task identifiers or receipt bytes.
    public var taskPhase: String? = nil
    public var capabilities: [RemoteCapabilityDescriptor] = []
    public var lifecycle: [RemoteLifecycleState]
    public var error: RemoteLinkError?
    public var completedAtMilliseconds: Int64
}

public struct RemoteExecutionResult: Codable {
    public let version: Int
    public let requestID: UUID
    public let requestDigest: String
    public let callerID: String
    public let runtimeID: String
    public let deviceID: String
    public let idempotencyKey: UUID
    public let reused: Bool
    public let summary: RemoteExecutionSummary
}

/// Ed25519 over exact canonical payload bytes with distinct request/result/hello
/// domains. Embedded key IDs are locators, never trust anchors.
public struct SignedRemoteMessage: Codable {
    public var version: Int = 1
    public var algorithm: String = "Ed25519"
    public var keyID: String
    public var payload: Data
    public var signature: Data

    public static func request(_ request: RemoteExecutionRequest, signer: any RCIRReceiptSigning) throws -> Data {
        try seal(request, domain: RemoteWire.requestDomain, signer: signer)
    }

    public static func verifiedResult(_ data: Data, for request: Data, trustedRuntimeKey: Data) throws -> RemoteExecutionResult {
        let envelope = try RemoteWire.decode(Self.self, data, maximum: RemoteWire.maximumWireBytes)
        try envelope.authenticate(domain: RemoteWire.resultDomain, trustedKey: trustedRuntimeKey)
        let result = try RemoteWire.decode(RemoteExecutionResult.self, envelope.payload)
        try result.summary.validate()
        let requestEnvelope = try RemoteWire.decode(Self.self, request, maximum: RemoteWire.maximumWireBytes)
        let original = try RemoteWire.decode(RemoteExecutionRequest.self, requestEnvelope.payload)
        guard result.version == 1, result.requestID == original.requestID,
              result.requestDigest == RemoteWire.digest(requestEnvelope.payload),
              result.callerID == original.callerID, result.idempotencyKey == original.idempotencyKey,
              result.runtimeID == original.targetRuntimeID, result.deviceID == original.targetDeviceID,
              result.runtimeID == RemoteWire.runtimeID(trustedRuntimeKey),
              result.deviceID == RemoteWire.deviceID(trustedRuntimeKey) else { throw RemoteLinkError.wrongRuntime }
        if original.operation == .status {
            guard result.summary.evidenceExecutionID == original.executionID else { throw RemoteLinkError.inconsistentResult }
        }
        return result
    }

    static func seal<T: Encodable>(_ value: T, domain: Data, signer: any RCIRReceiptSigning) throws -> Data {
        let payload = try RemoteWire.encode(value)
        guard payload.count <= RemoteWire.maximumPayloadBytes, signer.publicKey.count == 32 else { throw RemoteLinkError.limitExceeded }
        let envelope = Self(keyID: RemoteWire.digest(signer.publicKey), payload: payload,
                            signature: try signer.sign(domain + payload))
        return try RemoteWire.encode(envelope)
    }

    func authenticate(domain: Data, trustedKey: Data) throws {
        guard version == 1, algorithm == "Ed25519", trustedKey.count == 32,
              keyID == RemoteWire.digest(trustedKey), signature.count == 64,
              payload.count <= RemoteWire.maximumPayloadBytes,
              try RCIREd25519Verifier().verify(signature: signature, payload: domain + payload, publicKey: trustedKey)
        else { throw RemoteLinkError.unauthenticated }
    }
}

enum RemoteWire {
    static let maximumPayloadBytes = 32_768
    static let maximumWireBytes = 49_152
    static let requestDomain = Data("RIGHTCLICK-LINK-REQUEST-1\0".utf8)
    static let resultDomain = Data("RIGHTCLICK-LINK-RESULT-1\0".utf8)
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func runtimeID(_ key: Data) -> String { "runtime:" + digest(key) }
    static func deviceID(_ key: Data) -> String { "device:" + digest(key) }
    static func isIdentifier(_ value: String) -> Bool {
        (1...512).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func decode<T: Codable>(_ type: T.Type, _ data: Data, maximum: Int = maximumPayloadBytes) throws -> T {
        guard !data.isEmpty, data.count <= maximum else { throw RemoteLinkError.limitExceeded }
        // Bound nesting before invoking Foundation. Canonical round-trip rejects
        // unknown/duplicate fields, ignored consent flags and alternate encodings.
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 16 { throw RemoteLinkError.limitExceeded } }
            else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { throw RemoteLinkError.malformed } }
        }
        guard depth == 0, !quoted else { throw RemoteLinkError.malformed }
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            guard try encode(decoded) == data else { throw RemoteLinkError.malformed }
            return decoded
        } catch let error as RemoteLinkError { throw error }
        catch { throw RemoteLinkError.malformed }
    }
}
