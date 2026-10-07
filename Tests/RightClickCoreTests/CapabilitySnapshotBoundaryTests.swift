import Foundation
import XCTest
@testable import RightClickCore

final class CapabilitySnapshotBoundaryTests: XCTestCase {
    private final class Reflector: CapabilityReflector {
        let id: String
        init(_ id: String) { self.id = id }
        func capabilities(for item: ContentItem) throws -> [Capability] { [] }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            XCTFail("Discovery must not execute the provider")
            return .init(executionId: executionID, actionId: capability.id, state: .failed, message: "Unexpected invocation")
        }
    }

    private final class Resolver: CapabilityArtifactResolver {
        let kind = "fixture"
        var calls = 0
        var available = true
        var currentID = "first"
        var beforeResolve: (() -> Void)?
        func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector {
            calls += 1
            beforeResolve?()
            guard available else { throw URLError(.cannotConnectToHost) }
            return Reflector(currentID)
        }
    }

    private func source(_ resolver: Resolver, lifetime: TimeInterval = 5,
                        clock: @escaping () -> TimeInterval) -> ConfiguredCapabilityArtifactSource {
        .init(descriptors: [.init(id: "proof", kind: "fixture")],
              registry: .init(resolvers: [resolver]), refreshInterval: lifetime, clock: clock)
    }

    func testExpiryWithdrawsProviderAndAllowsChangedReappearance() {
        let resolver = Resolver()
        var now = 100.0
        let source = source(resolver, clock: { now })
        XCTAssertEqual(source.reflectors().map(\.id), ["first"])
        resolver.available = false
        now = 104.999
        XCTAssertEqual(source.reflectors().map(\.id), ["first"])
        XCTAssertEqual(resolver.calls, 1)
        now = 105
        XCTAssertTrue(source.reflectors().isEmpty)
        resolver.available = true
        resolver.currentID = "new-unseen"
        now = 110
        XCTAssertEqual(source.reflectors().map(\.id), ["new-unseen"])
    }

    func testRegressedClockCannotExtendOldSnapshot() {
        let resolver = Resolver()
        var now = 100.0
        let source = source(resolver, clock: { now })
        XCTAssertEqual(source.reflectors().count, 1)
        resolver.available = false
        now = 99
        XCTAssertTrue(source.reflectors().isEmpty)
        XCTAssertEqual(resolver.calls, 2)
    }

    func testInvalidTimesAndLifetimesNeverCreateImmortalSnapshots() {
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            let resolver = Resolver()
            let source = source(resolver, lifetime: invalid, clock: { 100 })
            XCTAssertEqual(source.reflectors().count, 1)
            resolver.available = false
            XCTAssertTrue(source.reflectors().isEmpty)
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            let resolver = Resolver()
            let source = source(resolver, clock: { invalid })
            XCTAssertEqual(source.reflectors().count, 1)
            resolver.available = false
            XCTAssertTrue(source.reflectors().isEmpty)
        }
    }

    func testHostCannotRaiseSnapshotLifetimeAboveFiveMinutes() {
        let resolver = Resolver()
        var now = 100.0
        let source = source(resolver, lifetime: 10_000, clock: { now })
        XCTAssertEqual(source.reflectors().count, 1)
        resolver.available = false
        now = 400
        XCTAssertTrue(source.reflectors().isEmpty)
    }

    func testEngineRefreshInvalidatesGenericSourcesWithoutNewOperations() {
        let first = Resolver()
        let second = Resolver()
        second.currentID = "second"
        let a = source(first, lifetime: 300, clock: { 100 })
        let b = source(second, lifetime: 300, clock: { 100 })
        XCTAssertEqual(a.reflectors().count, 1)
        XCTAssertEqual(b.reflectors().count, 1)
        let engine = CapabilityEngine(reflectorSources: [a, b], experience: nil)
        first.available = false
        second.available = false
        engine.refresh()
        XCTAssertTrue(a.reflectors().isEmpty)
        XCTAssertTrue(b.reflectors().isEmpty)
    }

    func testConcurrentObserversShareOneAcquisition() {
        let resolver = Resolver()
        let source = source(resolver, clock: { 100 })
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            XCTAssertEqual(source.reflectors().count, 1)
        }
        XCTAssertEqual(resolver.calls, 1)
    }

    func testInvalidationCannotBeOverwrittenByAnInFlightAcquisition() {
        let resolver = Resolver()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        resolver.beforeResolve = {
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        let source = source(resolver, clock: { 100 })
        let loadFinished = expectation(description: "acquisition finished")
        DispatchQueue.global().async {
            _ = source.reflectors()
            loadFinished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let invalidated = expectation(description: "snapshot invalidated")
        DispatchQueue.global().async {
            source.invalidateSnapshot()
            invalidated.fulfill()
        }
        release.signal()
        wait(for: [loadFinished, invalidated], timeout: 5)
        resolver.beforeResolve = nil
        resolver.available = false
        XCTAssertTrue(source.reflectors().isEmpty)
        XCTAssertEqual(resolver.calls, 2)
    }
}
