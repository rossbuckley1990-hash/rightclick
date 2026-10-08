import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

final class RCIRStructuredObservationTests: XCTestCase {
    func testExistingUnaryEvidenceInitializerDoesNotRequireTaskEvents() throws {
        let value = RCIRExecutionEvidence(version: 1, taskID: "task", leaseID: "lease", generation: 1,
            leaseConsumed: true, phase: "completed", outcome: "unverified", receipt: nil, signedReceipt: nil,
            observationBoundary: "unverified")
        XCTAssertNil(value.taskEvents)
        let decoded = try JSONDecoder().decode(RCIRExecutionEvidence.self, from: JSONEncoder().encode(value))
        XCTAssertNil(decoded.taskEvents); XCTAssertEqual(decoded.taskID, "task")
    }
    private func contract() -> RCIRVerificationContract {
        .init(observerID: "host:scoped-resource-observer", schema: .object(properties: ["name": .string, "value": .string], required: ["name", "value"]),
            expected: .object(["name": .string("desired"), "value": .string("requested")]),
            projection: .init(schema: .object(properties: ["name": .string, "uid": .string, "resourceVersion": .string,
                "data": .object(properties: ["value": .string], required: ["value"])], required: ["name", "uid", "resourceVersion", "data"]),
                fields: ["name": ["name"], "value": ["data", "value"]]))
    }

    private func task(_ check: RCIRVerificationContract? = nil) throws -> RCIRTask {
        let abi = CapabilityContract(capabilityID: "resource", reflectorID: "reflector", providerID: "provider",
            arguments: .string, result: .string, declaration: .string("resource-interface"))
        let scope = RCIRScope("namespace/disposable", .write)
        let admission = RCIRAdmission()
        let binding = try admission.publish(.init(abi: abi, scopes: [scope], verification: check ?? contract()), authenticatedPrincipal: "scoped-writer")
        let policy = RCIRPolicy(revision: "scoped-policy", principals: ["scoped-writer"], scopes: [scope])
        let lease = try admission.issue(binding, arguments: .string("requested"), authority: [scope], policy: policy, now: 1_000)
        try admission.consume(lease, arguments: .string("requested"), authority: [scope], policy: policy, now: 1_000)
        var task = try RCIRTask(lease: lease, startedAt: 1_000, deadline: 31_000)
        try task.record(.completed(.string("provider-claimed-coordinates")), sequence: 1, now: 1_001)
        return task
    }

    private func observation(_ value: String = "requested") -> CapabilityValue {
        .object(["name": .string("desired"), "uid": .string("independently-assigned-uid"), "resourceVersion": .string("12345"),
            "data": .object(["value": .string(value)])])
    }

    func testArgumentBoundFieldsVerifyWhileAssignedMetadataRemainsInSignedBytes() throws {
        var task = try task()
        try task.verify(observerID: "host:scoped-resource-observer", now: 1_002) { _, _ in self.observation() }
        XCTAssertEqual(task.outcome, .succeeded)
        let receipt = try task.receiptData()
        XCTAssertNotNil(receipt.range(of: Data("independently-assigned-uid".utf8)))
        XCTAssertNotNil(receipt.range(of: Data("12345".utf8)))
        XCTAssertNotNil(receipt.range(of: Data("provider-claimed-coordinates".utf8)))
    }

    func testFullObservationSchemaCannotBeDiscardedByProjection() throws {
        var task = try task()
        XCTAssertThrowsError(try task.verify(observerID: "host:scoped-resource-observer", now: 1_002) { _, _ in
            .object(["name": .string("desired"), "data": .object(["value": .string("requested")])])
        })
        XCTAssertEqual(task.outcome, .unverified)
    }

    func testIndependentMismatchIsVerifiedFailure() throws {
        var task = try task()
        try task.verify(observerID: "host:scoped-resource-observer", now: 1_002) { _, _ in self.observation("different") }
        XCTAssertEqual(task.outcome, .failed)
    }

    func testObserverReceivesProviderCoordinatesAsUntrustedLocatorOnly() throws {
        let task = try task()
        guard case let .string(locator)? = task.observationRequest.providerResult else { return XCTFail("locator missing") }
        XCTAssertEqual(locator, "provider-claimed-coordinates")
        XCTAssertEqual(task.outcome, .unverified)
    }

    func testProjectionRejectsWildcardMissingAndUnboundedContracts() throws {
        let schema = CapabilitySchema.object(properties: ["name": .string], required: ["name"])
        for fields in [["name": ["*"]], ["name": []], ["other": ["name"]], ["name": Array(repeating: "name", count: 33)]] {
            let check = RCIRVerificationContract(observerID: "host:observer", schema: schema, expected: .object(["name": .string("desired")]),
                projection: .init(schema: schema, fields: fields))
            XCTAssertThrowsError(try task(check))
        }
    }
}
