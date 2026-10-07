import Foundation
import XCTest
@testable import RightClickCore

/// Additional compiler-boundary controls, authored after the frozen real-HTTP
/// RED. They are regressions, not independent eleven-substrate acceptance.
final class RCIRInvocationIsolationTests: XCTestCase {
    private let one = RCIRScope("urn:resource:one", .write)
    private let two = RCIRScope("urn:resource:two", .write)
    private var policy: RCIRPolicy {
        .init(revision: "policy:one", principals: ["principal:one", "principal:two"], scopes: [one, two])
    }
    private func abi(_ declaration: String = "discovered:one", provider: String = "provider:one",
                     arguments: CapabilitySchema = .integer) -> CapabilityContract {
        .init(capabilityID: "fixture:call", reflectorID: "reflector:one", providerID: provider,
              arguments: arguments, result: .integer, declaration: .string(declaration))
    }
    private func contract(_ request: String = "request:one", scopes: Set<RCIRScope>? = nil,
                          task: RCIRTaskModel = .init(), expected: Int64 = 1) -> RCIRContract {
        .init(abi: abi(request), scopes: scopes ?? [one], task: task,
              verification: .init(observerID: "observer:host", schema: .integer, expected: .integer(expected)))
    }
    private func published(_ admission: RCIRAdmission, _ contract: RCIRContract? = nil,
                           discovery: CapabilityContract? = nil, principal: String = "principal:one") throws -> RCIRBinding {
        try admission.publishInvocation(contract ?? self.contract(), discovery: discovery ?? abi(),
                                        authenticatedPrincipal: principal)
    }
    private func issued(_ admission: RCIRAdmission, _ binding: RCIRBinding,
                        argument: Int64 = 1) throws -> RCIRLease {
        try admission.issue(binding, arguments: .integer(argument), authority: [one, two], policy: policy, now: 100)
    }

    func testResourcesAndPostconditionsAreBoundToIndependentLeases() throws {
        let admission = RCIRAdmission()
        let first = try published(admission)
        let firstLease = try issued(admission, first)
        let second = try published(admission, contract("request:two", scopes: [two], expected: 2))
        let secondLease = try issued(admission, second, argument: 2)
        XCTAssertEqual(first.generation, second.generation)
        XCTAssertNotEqual(first.bytes, second.bytes)
        XCTAssertEqual(firstLease.scopes, [one]); XCTAssertEqual(secondLease.scopes, [two])
        XCTAssertThrowsError(try admission.consume(firstLease, arguments: .integer(1), authority: [two], policy: policy, now: 101))
        XCTAssertThrowsError(try admission.consume(firstLease, arguments: .integer(2), authority: [one], policy: policy, now: 101))
        try admission.consume(firstLease, arguments: .integer(1), authority: [one], policy: policy, now: 101)
        try admission.consume(secondLease, arguments: .integer(2), authority: [two], policy: policy, now: 101)
        var task = try RCIRTask(lease: firstLease, startedAt: 101, deadline: 200)
        try task.record(.completed(.integer(1)), sequence: 1, now: 102)
        try task.verify(observerID: "observer:host", now: 103) { _, _ in .integer(2) }
        XCTAssertEqual(task.outcome, .failed, "The second invocation's expected result must not replace the first")
    }

    func testDiscoveryDriftInvalidatesOutstandingInvocation() throws {
        let admission = RCIRAdmission()
        let first = try published(admission); let lease = try issued(admission, first)
        let replacement = try published(admission, discovery: abi("discovered:changed"))
        XCTAssertNotEqual(first.generation, replacement.generation)
        XCTAssertThrowsError(try admission.consume(lease, arguments: .integer(1), authority: [one], policy: policy, now: 101))
    }

    func testEffectKindDriftInvalidatesOutstandingInvocation() throws {
        let admission = RCIRAdmission()
        let first = try published(admission); let lease = try issued(admission, first)
        let replacement = try published(admission, contract(scopes: [.init("urn:resource:one", .read)]))
        XCTAssertNotEqual(first.generation, replacement.generation)
        XCTAssertThrowsError(try admission.consume(lease, arguments: .integer(1), authority: [one], policy: policy, now: 101))
    }

    func testTaskBudgetDriftInvalidatesOutstandingInvocation() throws {
        let admission = RCIRAdmission()
        let first = try published(admission); let lease = try issued(admission, first)
        let replacement = try published(admission, contract(task: .init(maxEvents: 1)))
        XCTAssertNotEqual(first.generation, replacement.generation)
        XCTAssertThrowsError(try admission.consume(lease, arguments: .integer(1), authority: [one], policy: policy, now: 101))
    }

    func testCompilerCannotMixProviderIdentityOrArgumentTypes() throws {
        let admission = RCIRAdmission()
        let original = try published(admission)
        XCTAssertThrowsError(try published(admission, discovery: abi(provider: "provider:other")))
        XCTAssertThrowsError(try published(admission, discovery: abi(arguments: .string)))
        XCTAssertEqual(try published(admission).generation, original.generation)
    }

    func testPrincipalReplacementInvalidatesOutstandingInvocation() throws {
        let admission = RCIRAdmission()
        let first = try published(admission); let lease = try issued(admission, first)
        let replacement = try published(admission, principal: "principal:two")
        XCTAssertNotEqual(first.generation, replacement.generation)
        XCTAssertThrowsError(try admission.consume(lease, arguments: .integer(1), authority: [one], policy: policy, now: 101))
    }

    func testWithdrawalAndReappearanceCannotReviveOldLease() throws {
        let admission = RCIRAdmission()
        let first = try published(admission); let lease = try issued(admission, first)
        admission.withdraw(reflectorID: "reflector:one")
        let replacement = try published(admission)
        XCTAssertNotEqual(first.generation, replacement.generation)
        XCTAssertThrowsError(try admission.consume(lease, arguments: .integer(1), authority: [one], policy: policy, now: 101))
    }

    func testInvocationDoesNotTurnUnknownEffectsIntoAuthority() throws {
        let admission = RCIRAdmission()
        let binding = try published(admission, contract(scopes: [.init("urn:resource:one", .unknown)]))
        XCTAssertThrowsError(try issued(admission, binding))
    }
}
