import Foundation

/// Only trusted host composition/configuration may register these factories.
/// Descriptor providers and model tool inputs cannot select their own observer.
public struct RCIRHostObservation {
    public let contract: RCIRVerificationContract
    public let observer: any RCIRObserver
    public let boundary: String
    public init(contract: RCIRVerificationContract, observer: any RCIRObserver, boundary: String) {
        self.contract = contract; self.observer = observer; self.boundary = boundary
    }
}
public typealias RCIRHostObserverFactory = (CapabilityValue) throws -> RCIRHostObservation
