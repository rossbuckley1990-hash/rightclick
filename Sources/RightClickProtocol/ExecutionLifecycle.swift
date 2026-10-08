import Foundation

/// Provider acceptance is a dispatch observation, never semantic success.
public enum ExecutionProviderAcceptance: String, Codable, Sendable {
    case notInvoked, accepted, rejected, unknown
}

/// Portable execution ownership and lifecycle, shared by local and remote hosts.
/// Credentials, private observations and provider diagnostics never belong here.
public struct ExecutionLifecycle: Codable, Sendable {
    public let version: Int
    public let executionID: String
    public let originatingRequestID: String
    public let runtimeID: String
    public let taskID: String
    public let generation: Int64
    public let taskShape: RCIRTaskShape
    public let phase: RCIRTaskPhase
    public let semanticOutcome: RCIRSemanticOutcome
    public let sequence: Int64
    public let terminal: Bool
    public let providerAcceptance: ExecutionProviderAcceptance
    public let verification: OutcomeVerificationStatus
    public let observationBoundary: OutcomeObservationBoundary
    public let evidenceID: String?
    public let receiptAvailable: Bool
    public let signedReceiptAvailable: Bool

    public init(version: Int = 1, executionID: String, originatingRequestID: String,
                runtimeID: String = "local", taskID: String, generation: Int64,
                taskShape: RCIRTaskShape, phase: RCIRTaskPhase,
                semanticOutcome: RCIRSemanticOutcome, sequence: Int64, terminal: Bool,
                providerAcceptance: ExecutionProviderAcceptance,
                verification: OutcomeVerificationStatus, observationBoundary: OutcomeObservationBoundary,
                evidenceID: String? = nil, receiptAvailable: Bool = false,
                signedReceiptAvailable: Bool = false) {
        self.version = version; self.executionID = executionID
        self.originatingRequestID = originatingRequestID; self.runtimeID = runtimeID
        self.taskID = taskID; self.generation = generation; self.taskShape = taskShape
        self.phase = phase; self.semanticOutcome = semanticOutcome; self.sequence = sequence
        self.terminal = terminal; self.providerAcceptance = providerAcceptance
        self.verification = verification; self.observationBoundary = observationBoundary
        self.evidenceID = evidenceID; self.receiptAvailable = receiptAvailable
        self.signedReceiptAvailable = signedReceiptAvailable
    }
}

/// Infrastructure refresh beneath context_run_status. Location is not an AI tool.
public protocol CapabilityExecutionStatusReflector: CapabilityReflector {
    func executionStatus(executionID: String, cursor: Int64, limit: Int,
                         maximumBytes: Int) async throws -> ExecutionRecord?
}

/// Host-installed durable ownership recovery after the serving process restarts.
/// Ambiguous owners fail closed; this lookup never invokes provider work.
public protocol CapabilityExecutionRecoveryReflector: CapabilityExecutionStatusReflector {
    func ownsExecution(executionID: String) throws -> Bool
}

/// Optional host-installed scope on retained status, including shared caches.
/// nil means the source has no record for this execution; false denies access.
public protocol CapabilityExecutionStatusAccessSource {
    func permitsRetainedStatus(executionID: String) throws -> Bool?
}

/// A node-local source can bind its delegated authority to the actual Link
/// execution endpoint. Incoming client identity remains a separate grant.
public protocol CapabilityExecutionNodeBoundSource {
    var executionNodePublicKey: Data? { get }
    var executionNodeRuntimeID: String? { get }
}
