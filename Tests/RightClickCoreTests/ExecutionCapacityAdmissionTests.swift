import Foundation
import XCTest
@testable import RightClickCore

final class ExecutionCapacityAdmissionTests: XCTestCase {
    private final class CountingReflector: CapabilityReflector {
        let id = "capacity.pressure"
        var starts = 0
        func capabilities(for item: ContentItem) throws -> [Capability] {
            [Capability(id: "capacity:test", title: "Capacity pressure", source: .system,
                        reflectorID: id, safety: .localReversible, invocation: .direct,
                        supportLevel: .publicSupported, requiresConfirmation: false)]
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            starts += 1
            return ExecutionRecord(executionId: executionID, actionId: capability.id,
                                   state: .accepted, message: "Counted start")
        }
    }
    func testFullActiveHistoryRefusesBothEngineEntryPointsBeforeProviderStart() throws {
        let store = ExecutionStore.shared
        let prefix = "capacity-pressure-" + UUID().uuidString + "-"
        var owned: [String] = []
        defer { for id in owned { store.update(id) { $0.state = .cancelled } } }
        for index in 0..<1_025 {
            let id = prefix + String(index)
            if store.put(ExecutionRecord(executionId: id, actionId: "pressure", state: .started, message: "Reserved")) { owned.append(id) }
            else { break }
        }
        XCTAssertFalse(owned.isEmpty)
        let reflector = CountingReflector()
        let engine = CapabilityEngine(reflectors: [reflector], experience: nil)
        let begin = try engine.begin(id: "capacity:test", item: "capacity pressure", confirmed: true)
        let run = try engine.run(id: "capacity:test", item: "capacity pressure", confirmed: true)
        XCTAssertEqual(begin.state, .rejected)
        XCTAssertEqual(run.status, .rejected)
        XCTAssertEqual(begin.evidence.type, "execution_capacity")
        XCTAssertEqual(run.evidence.type, "execution_capacity")
        XCTAssertEqual(reflector.starts, 0)
    }
}
