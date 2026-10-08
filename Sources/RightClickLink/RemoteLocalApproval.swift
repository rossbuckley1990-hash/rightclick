import Foundation

/// Supplied only by the execution host's approval UI/service. Neither grants
/// nor relay messages constitute consent. Default absence leaves the engine
/// awaiting_user. A ticket binds the exact request and capability declaration.
public protocol RemoteLocalApproval: AnyObject {
    func approval(for request: RemoteExecutionRequest, capabilityDigest: String) -> RemoteApprovalTicket?
}
public struct RemoteApprovalTicket {
    public let requestDigest: String
    public let capabilityDigest: String
    public let expiresAtMilliseconds: Int64
    /// Call after the local user has reviewed this exact request/declaration.
    public init(approvedRequest: RemoteExecutionRequest, capabilityDigest: String) throws {
        requestDigest = RemoteWire.digest(try RemoteWire.encode(approvedRequest))
        self.capabilityDigest = capabilityDigest
        expiresAtMilliseconds = approvedRequest.expiresAtMilliseconds
    }
    func permits(_ request: RemoteExecutionRequest, capabilityDigest: String, now: Int64) throws -> Bool {
        requestDigest == RemoteWire.digest(try RemoteWire.encode(request)) && self.capabilityDigest == capabilityDigest &&
        expiresAtMilliseconds == request.expiresAtMilliseconds && now < expiresAtMilliseconds
    }
}
