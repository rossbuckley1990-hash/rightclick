import Foundation
import XCTest
@testable import RightClickCore

final class DispatchContractBindingTests: XCTestCase {
    private final class Probe: CapabilityVerificationReflector {
        let id = "probe.dispatch-binding"
        var catalog: [Capability]
        var failDiscovery = false
        var discoveryCalls = 0
        var beginCalls = 0
        var verificationCalls = 0
        var receivedArguments: CapabilityArguments?

        init(_ catalog: [Capability]) { self.catalog = catalog }

        func capabilities(for item: ContentItem) throws -> [Capability] {
            discoveryCalls += 1
            if failDiscovery { throw NSError(domain: "fixture", code: 1) }
            return catalog
        }

        func begin(capability: Capability, item: ContentItem,
                   executionID: String) throws -> ExecutionRecord {
            beginCalls += 1
            return ExecutionRecord(executionId: executionID, actionId: capability.id,
                                   state: .accepted, message: "Fixture accepted.")
        }

        func begin(capability: Capability, item: ContentItem, executionID: String,
                   arguments: CapabilityArguments?) throws -> ExecutionRecord {
            receivedArguments = arguments
            return try begin(capability: capability, item: item, executionID: executionID)
        }

        func begin(capability: Capability, item: ContentItem, executionID: String,
                   arguments: CapabilityArguments?,
                   verification: VerificationSpec) throws -> ExecutionRecord {
            verificationCalls += 1
            return try begin(capability: capability, item: item,
                             executionID: executionID, arguments: arguments)
        }
    }

    private final class ChangingSource: CapabilityReflectorSource {
        let id = "probe.changing-source"
        let before: Probe
        let after: Probe
        var calls = 0
        init(_ before: Probe, _ after: Probe) {
            self.before = before
            self.after = after
        }
        func reflectors() -> [any CapabilityReflector] {
            calls += 1
            return [calls == 1 ? before : after]
        }
    }

    private func capability() -> Capability {
        Capability(id: "probe:write", title: "Write a record", source: .system,
                   provider: CapabilityProvider(name: "Fixture"),
                   inputs: ["public.plain-text"], output: ["public.json"],
                   safety: .localWrite, invocation: .direct,
                   supportLevel: .experimental, requiresConfirmation: true,
                   metadata: ["method": "POST", "path": "/records",
                              "authorityOrigin": "https://api.example.com",
                              "argumentsSchema": "{\"type\":\"object\"}"])
    }

    private func check(_ fresh: [Capability], allowed: Bool,
                       original: Capability? = nil, failDiscovery: Bool = false,
                       confirmed: Bool = true, verification: VerificationSpec? = nil,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        // Exercise both public execution entry points. No network, Keychain,
        // native app mutation or production credential is used by this fixture.
        for asynchronous in [false, true] {
            let selected = original ?? capability()
            let before = Probe([selected])
            let after = Probe(fresh)
            after.failDiscovery = failDiscovery
            let source = ChangingSource(before, after)
            let engine = CapabilityEngine(reflectorSources: [source])
            let arguments = ["title": "unchanged"]
            if asynchronous {
                let result = try engine.begin(id: selected.id, item: "fixture",
                                              confirmed: confirmed, arguments: arguments,
                                              verification: verification)
                XCTAssertEqual(result.state, allowed ? .accepted : .unavailable,
                               file: file, line: line)
                XCTAssertFalse(result.evidence.outcomeVerified, file: file, line: line)
                XCTAssertEqual(engine.executionStatus(result.executionId).state, result.state,
                               file: file, line: line)
            } else {
                let result = try engine.run(id: selected.id, item: "fixture",
                                            confirmed: confirmed, arguments: arguments,
                                            verification: verification)
                XCTAssertEqual(result.status, allowed ? .accepted : .unavailable,
                               file: file, line: line)
                XCTAssertFalse(result.evidence.outcomeVerified, file: file, line: line)
            }
            XCTAssertEqual(before.beginCalls, 0, file: file, line: line)
            XCTAssertEqual(after.beginCalls, allowed ? 1 : 0, file: file, line: line)
            XCTAssertEqual(after.verificationCalls,
                           allowed && verification != nil ? 1 : 0, file: file, line: line)
            if allowed {
                XCTAssertEqual(after.receivedArguments, arguments, file: file, line: line)
            }
        }
    }

    func testEquivalentRecreatedReflectorRemainsUsable() throws {
        try check([capability()], allowed: true)
    }

    func testChangedEndpointIsNotDispatched() throws {
        var changed = capability()
        changed.metadata["path"] = "/admin/records"
        try check([changed], allowed: false)
    }

    func testChangedAuthorityOriginIsNotDispatched() throws {
        var changed = capability()
        changed.metadata["authorityOrigin"] = "https://other.example.com"
        try check([changed], allowed: false)
    }

    func testChangedSchemaOrMethodIsNotDispatched() throws {
        for (key, value) in [("argumentsSchema", "{\"type\":\"string\"}"),
                             ("method", "DELETE"), ("specificationSHA256", "new-spec")] {
            var changed = capability()
            changed.metadata[key] = value
            try check([changed], allowed: false)
        }
    }

    func testSafetyEscalationCannotInheritUnconfirmedRead() throws {
        var read = capability()
        read.safety = .read
        read.requiresConfirmation = false
        var changed = read
        changed.safety = .destructive
        changed.requiresConfirmation = true
        try check([changed], allowed: false, original: read, confirmed: false)
    }

    func testChangedInvocationOrProviderIsNotDispatched() throws {
        var changed = capability()
        changed.invocation = .unsupported
        try check([changed], allowed: false)
        changed = capability()
        changed.provider = CapabilityProvider(name: "Replacement")
        try check([changed], allowed: false)
    }

    func testWithdrawnCapabilityIsNotDispatched() throws {
        try check([], allowed: false)
    }

    func testFailedRevalidationIsNotDispatched() throws {
        try check([capability()], allowed: false, failDiscovery: true)
    }

    func testConflictingDuplicateCannotHideBehindFirstMatch() throws {
        var changed = capability()
        changed.metadata["path"] = "/different"
        try check([capability(), changed], allowed: false)
        try check([changed, capability()], allowed: false)
    }

    func testIdenticalDuplicateDoesNotBreakExistingProviders() throws {
        try check([capability(), capability()], allowed: true)
    }

    func testEngineAssignedOwnershipStillWinsOverProviderMetadata() throws {
        var changed = capability()
        changed.reflectorID = "provider-supplied-owner"
        try check([changed], allowed: true)
    }

    func testMetadataKeyOrderDoesNotInvalidateContract() throws {
        var changed = capability()
        changed.metadata = Dictionary(uniqueKeysWithValues:
            changed.metadata.sorted { $0.key > $1.key })
        try check([changed], allowed: true)
    }

    func testDistinctUnicodeAuthorityBytesAreNotConflated() throws {
        var original = capability()
        original.metadata["path"] = "/caf\u{00e9}"
        var changed = original
        changed.metadata["path"] = "/cafe\u{0301}"
        XCTAssertEqual(original.metadata["path"], changed.metadata["path"])
        try check([changed], allowed: false, original: original)
    }

    func testDelegatedVerificationCannotBypassBinding() throws {
        let verification = VerificationSpec(predicates: [
            VerificationPredicate(type: .textEquals, value: "verified")
        ])
        var changed = capability()
        changed.metadata["path"] = "/different"
        try check([changed], allowed: false, verification: verification)
        try check([capability()], allowed: true, verification: verification)
    }

    func testConfirmationStillStopsBeforeRevalidationOrDispatch() throws {
        for asynchronous in [false, true] {
            let before = Probe([capability()])
            let after = Probe([capability()])
            let source = ChangingSource(before, after)
            let engine = CapabilityEngine(reflectorSources: [source])
            if asynchronous {
                let result = try engine.begin(id: "probe:write", item: "fixture", confirmed: false)
                XCTAssertEqual(result.state, .awaitingUser)
            } else {
                let result = try engine.run(id: "probe:write", item: "fixture", confirmed: false)
                XCTAssertEqual(result.status, .confirmationRequired)
            }
            XCTAssertEqual(source.calls, 1)
            XCTAssertEqual(after.discoveryCalls, 0)
            XCTAssertEqual(before.beginCalls + after.beginCalls, 0)
        }
    }
}
