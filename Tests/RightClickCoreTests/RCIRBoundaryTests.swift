import Foundation
import XCTest
@testable import RightClickCore

final class RCIRBoundaryTests: XCTestCase {
    func fixture() throws -> (RCIRAdmission, RCIRLease, RCIRPolicy, CapabilityValue) {
        let arguments = CapabilityValue.object(["path": .string("urn:fixture:result")])
        let scope = RCIRScope("urn:fixture:result", .read)
        let policy = RCIRPolicy(revision: "policy:1", principals: ["principal:fixture"], scopes: [scope])
        let abi = CapabilityContract(capabilityID: "fixture:read", reflectorID: "reflector:fixture", providerID: "fixture",
                                     arguments: .object(properties: ["path": .string], required: ["path"]),
                                     result: .integer, declaration: .string("test fixture"))
        let contract = RCIRContract(abi: abi, scopes: [scope], task: .init(shape: .serverStream, element: .integer),
                                    verification: .init(observerID: "observer:fixture", schema: .integer, expected: .integer(7)))
        let admission = RCIRAdmission()
        let binding = try admission.publish(contract, authenticatedPrincipal: "principal:fixture")
        let lease = try admission.issue(binding, arguments: arguments, authority: [scope], policy: policy, now: 100)
        return (admission, lease, policy, arguments)
    }
    func testTaskCannotPredateLease() throws {
        let (_, lease, _, _) = try fixture()
        XCTAssertThrowsError(try RCIRTask(lease: lease, startedAt: 99, deadline: 1000))
    }
    func testConcurrentConsumptionHasOneWinner() throws {
        let (admission, lease, policy, arguments) = try fixture()
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var count = 0
            func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
        }
        let winners = Counter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                try admission.consume(lease, arguments: arguments, authority: lease.scopes, policy: policy, now: 101)
                winners.increment()
            } catch {}
        }
        XCTAssertEqual(winners.count, 1)
    }
    func testInvalidObservationCannotSetSemanticSuccess() throws {
        let (_, lease, _, _) = try fixture()
        var task = try RCIRTask(lease: lease, startedAt: 100, deadline: 1000)
        try task.record(.completed(.integer(7)), sequence: 1, now: 101)
        XCTAssertThrowsError(try task.verify(observerID: "observer:fixture", now: 102) { _, _ in .string("7") })
        XCTAssertEqual(task.outcome, .unverified)
    }
    func testRejectedArgumentsDoNotSpendAnOtherwiseValidLease() throws {
        let (admission, lease, policy, arguments) = try fixture()
        XCTAssertThrowsError(try admission.consume(lease, arguments: .object(["path": .string("different")]),
                                                  authority: lease.scopes, policy: policy, now: 101))
        XCTAssertNoThrow(try admission.consume(lease, arguments: arguments, authority: lease.scopes, policy: policy, now: 102))
    }
    func testFailedProviderResultStillDoesNotVerifyAnExternalFailure() throws {
        let (_, lease, _, _) = try fixture()
        var task = try RCIRTask(lease: lease, startedAt: 100, deadline: 1000)
        try task.record(.failed, sequence: 1, now: 101)
        XCTAssertEqual(task.phase, .failed)
        XCTAssertEqual(task.outcome, .unverified)
        XCTAssertNoThrow(try task.receiptData())
    }
}
