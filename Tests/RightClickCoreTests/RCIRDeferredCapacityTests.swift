import Foundation
import XCTest
@testable import RightClickCore

final class RCIRDeferredCapacityTests: XCTestCase {
    private func invoke(_ host: RCIRExecutionHost, starts: @escaping () -> Void) throws -> ExecutionRecord {
        let capability = Capability(id: "capacity", title: "Capacity pressure", source: .system,
            reflectorID: "capacity-owner", safety: .localReversible, invocation: .direct,
            supportLevel: .publicSupported, requiresConfirmation: false, metadata: ["executionMode": "deferred"])
        let abi = try capability.abiContract(arguments: .null, result: .string)
        let target = URL(string: "https://capacity.invalid/tasks")!
        let scope = RCIRScope(target.absoluteString, .execute)
        return try host.execute(abi: abi, discovery: abi, arguments: .null, scope: scope,
            capability: capability, executionID: UUID().uuidString, argumentStrings: nil,
            item: try ContentParser.parse("capacity"), verification: nil, expectedOutput: nil,
            target: target, authority: { [scope] }, revalidate: { true }, dispatch: { _, admit in
                try admit(starts)
                return ExecutionRecord(executionId: "", actionId: "capacity", state: .started, message: "pending")
            }, resultValue: { _ in .string("") })
    }

    func testInFlightReservationsCannotOverrunTheBoundedSessionCapacity() throws {
        let host = RCIRExecutionHost(); host.now = { 1_000 }
        var starts = 0; var nested: [ExecutionRecord] = []
        // Force other invocations into the original check-to-insert window.
        host.beforeConsume = { _ in
            host.beforeConsume = nil
            for _ in 0..<256 { nested.append(try self.invoke(host) { starts += 1 }) }
        }
        let outer = try invoke(host) { starts += 1 }
        XCTAssertEqual(outer.state, .started)
        XCTAssertEqual(nested.filter { $0.state == .started }.count, 255)
        XCTAssertEqual(nested.filter { $0.state == .rejected }.count, 1)
        XCTAssertEqual(starts, 256)
    }

    func testExpiredPendingTasksAreReceiptedAndReapedBeforeNewAdmission() throws {
        let host = RCIRExecutionHost(); var time: Int64 = 1_000; host.now = { time }
        let first = try invoke(host) {}
        for _ in 1..<256 { XCTAssertEqual(try invoke(host) {}.state, .started) }
        XCTAssertEqual(try invoke(host) {}.state, .rejected)
        time += 30_001
        XCTAssertEqual(try invoke(host) {}.state, .started)
        let expired = try XCTUnwrap(ExecutionStore.shared.get(first.executionId))
        XCTAssertEqual(expired.state, .unknown); XCTAssertEqual(expired.rcir?.outcome, "unknown")
        XCTAssertNotNil(expired.rcir?.receipt)
    }
}
