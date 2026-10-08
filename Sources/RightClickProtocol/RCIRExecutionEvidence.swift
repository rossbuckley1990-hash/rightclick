import Foundation

public struct RCIRExecutionEvidence: Codable, Sendable {
    public let version: Int
    public let taskID: String
    public let leaseID: String
    public let generation: Int64
    public let leaseConsumed: Bool
    public let phase: String
    public let outcome: String
    public let receipt: String
    public let signedReceipt: RCIRReceiptEnvelope?
    public let observationBoundary: String
    public init(version: Int, taskID: String, leaseID: String, generation: Int64, leaseConsumed: Bool, phase: String, outcome: String, receipt: String, signedReceipt: RCIRReceiptEnvelope?, observationBoundary: String) {
        self.version = version
        self.taskID = taskID
        self.leaseID = leaseID
        self.generation = generation
        self.leaseConsumed = leaseConsumed
        self.phase = phase
        self.outcome = outcome
        self.receipt = receipt
        self.signedReceipt = signedReceipt
        self.observationBoundary = observationBoundary
    }
}

public struct RCIRReceiptEnvelope: Codable, Sendable {
    public let version: Int
    public let algorithm: String
    public let payload: String
    public let signature: String
    public let publicKey: String
    public init(version: Int, algorithm: String, payload: String, signature: String, publicKey: String) {
        self.version = version
        self.algorithm = algorithm
        self.payload = payload
        self.signature = signature
        self.signature = signature
        self.publicKey = publicKey
    }
}
