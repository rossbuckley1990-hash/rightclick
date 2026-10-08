import Foundation
import XCTest
@testable import RightClickCore

// Current trusted-host entry points contain no authenticated invoking subject,
// audience, revocable authority handle or aggregate parent invocation budget.
// These tests freeze the missing agency invariants before adding that boundary.
final class LegacyAuthorityGapTests: XCTestCase {
    private let scope = RCIRScope("urn:disposable:resource", .write)
    private var policy: RCIRPolicy { .init(revision: "host-policy", principals: ["provider:fixture"], scopes: [scope]) }
    private func binding(_ admission: RCIRAdmission) throws -> RCIRBinding {
        try admission.publish(.init(abi: .init(capabilityID: "fixture:write", reflectorID: "fixture", providerID: "provider:fixture", arguments: .integer, result: .integer, declaration: .string("fixture")), scopes: [scope]), authenticatedPrincipal: "provider:fixture")
    }
    func testCopiedLeaseMustNotAuthorizeAnotherAgent() throws {
        let admission = RCIRAdmission()
        let lease = try admission.issue(binding(admission), arguments: .integer(1), authority: [scope], policy: policy, now: 100)
        // A copied handle is the only identity presented at the existing consume
        // seam. There is no Alice/Bob or audience value for the ledger to check.
        var unauthorizedStarts = 0
        try? admission.consumeAndStart(lease, arguments: .integer(1), authority: [scope], policy: policy, now: 101) { unauthorizedStarts += 1 }
        XCTAssertEqual(unauthorizedStarts, 0, "Copied lease admitted; invoking subject/audience are not represented")
    }
    func testChildrenMustShareOneParentInvocationBudget() throws {
        let admission = RCIRAdmission(), binding = try binding(admission)
        var starts = 0
        // Both child requests inherit the same parent scope. Current admission
        // only limits each lease to one use; two fresh leases have no aggregate
        // parent limit or ancestry to debit.
        for childArgument in [Int64(1), Int64(2)] {
            let lease = try admission.issue(binding, arguments: .integer(childArgument), authority: [scope], policy: policy, now: 100)
            try admission.consumeAndStart(lease, arguments: .integer(childArgument), authority: [scope], policy: policy, now: 101) { starts += 1 }
        }
        XCTAssertEqual(starts, 1, "Two child invocations exceeded the intended one-use parent budget")
    }
}
