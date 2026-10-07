import Foundation
import XCTest
@testable import RightClickCore

final class LiveCapabilityArtifactSourceTests: XCTestCase {
    final class Clock { var now: TimeInterval = 1 }
    final class Resolver: CapabilityArtifactResolver {
        let kind: String
        var received: [CapabilityArtifactDescriptor] = []
        var error: Error?
        var empty = false
        var fixedID: String?
        init(_ kind: String = "graphql") { self.kind = kind }
        func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector {
            received.append(descriptor)
            if let error { throw error }
            return Probe(fixedID ?? descriptor.id, empty: empty)
        }
    }
    final class Probe: CapabilityReflector {
        let id: String
        let empty: Bool
        init(_ id: String, empty: Bool = false) { self.id = "probe:" + id; self.empty = empty }
        func capabilities(for item: ContentItem) throws -> [Capability] {
            empty ? [] : [Capability(id: id + ":read", title: "Probe read", source: .system,
                safety: .read, invocation: .direct, supportLevel: .experimental, requiresConfirmation: false)]
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            ExecutionRecord(executionId: executionID, actionId: capability.id, state: .accepted, message: "probe only")
        }
    }
    func item(_ value: String) -> ContentItem {
        ContentItem(kind: "text", display: value, text: value, typeIdentifier: "public.plain-text")
    }
    func make(_ resolver: Resolver = Resolver(), clock: Clock = Clock(), env: [String: String] = [:]) -> LiveCapabilityArtifactSource {
        LiveCapabilityArtifactSource(registry: CapabilityArtifactResolverRegistry(resolvers: [resolver]),
            environment: env, lifetime: 5, clock: { clock.now })
    }
    func run(_ source: LiveCapabilityArtifactSource, _ value: String = "https://example.test/graphql",
             _ args: [String: String] = ["kind": "graphql", "id": "test"],
             action: String = LiveCapabilityArtifactSource.acquireID) throws -> ExecutionRecord {
        let context = item(value)
        let capability = try XCTUnwrap(source.capabilities(for: context).first { $0.id == action })
        return try source.begin(capability: capability, item: context, executionID: UUID().uuidString, arguments: args)
    }
    func status(_ source: LiveCapabilityArtifactSource) throws -> String {
        try run(source, LiveCapabilityArtifactSource.statusItem, [:], action: LiveCapabilityArtifactSource.statusID).output ?? ""
    }
    func graphIDs(_ source: LiveCapabilityArtifactSource) -> [String] { source.reflectors().map(\.id) }

    func testDiscoveryIsNetworkFreeAndConfirmed() throws {
        let resolver = Resolver(); let source = make(resolver)
        let caps = try source.capabilities(for: item("https://example.test/graphql"))
        XCTAssertEqual(caps.count, 1)
        XCTAssertTrue(caps[0].requiresConfirmation)
        XCTAssertEqual(caps[0].id, LiveCapabilityArtifactSource.acquireID)
        XCTAssertEqual(resolver.received.count, 0)
        _ = source.providers()
        XCTAssertEqual(resolver.received.count, 0)
    }
    func testHTTPSDoesNotGuessGraphQL() throws {
        let resolver = Resolver(); let source = make(resolver)
        let record = try run(source, "https://example.test/graphql", [:])
        XCTAssertEqual(record.state, .failed)
        XCTAssertTrue(record.message.contains("kind_required"))
        XCTAssertTrue(resolver.received.isEmpty)
    }
    func testAcquiresIntoSameSourceWithoutRestart() throws {
        let resolver = Resolver(); let source = make(resolver)
        XCTAssertEqual(graphIDs(source), [source.id])
        let record = try run(source)
        XCTAssertEqual(record.state, .accepted)
        XCTAssertFalse(record.evidence.outcomeVerified)
        XCTAssertEqual(Set(graphIDs(source)), Set([source.id, "probe:test"]))
        XCTAssertEqual(resolver.received.count, 1)
        XCTAssertTrue(try status(source).contains("acquired"))
    }
    func testGRPCSchemeInfersOnlyGRPC() throws {
        let resolver = Resolver("grpc"); let source = make(resolver)
        let record = try run(source, "grpcs://example.test:9001", [:])
        XCTAssertEqual(record.state, .accepted)
        XCTAssertEqual(resolver.received.first?.kind, "grpc")
        XCTAssertEqual(resolver.received.first?.endpointURL, "grpcs://example.test:9001")
    }
    func testGRPCProtocolMismatchDoesNotDispatch() throws {
        let resolver = Resolver(); let source = make(resolver)
        let result = try run(source, "grpcs://example.test:9001")
        XCTAssertTrue(result.message.contains("protocol_mismatch"))
        XCTAssertTrue(resolver.received.isEmpty)
    }
    func testTypedDescriptorAndNoOverrides() throws {
        let source = make()
        let descriptor = #"{"id":"typed","kind":"graphql","endpointURL":"https://example.test/g"}"#
        XCTAssertEqual(try run(source, descriptor, [:]).state, .accepted)
        XCTAssertTrue(try run(source, descriptor, ["kind": "graphql"]).message.contains("descriptor_overrides_forbidden"))
    }
    func testUnknownDescriptorFieldsRejected() throws {
        let resolver = Resolver(); let source = make(resolver)
        let descriptor = #"{"id":"typed","kind":"graphql","endpointURL":"https://example.test/g","token":"SECRET"}"#
        let result = try run(source, descriptor, [:])
        XCTAssertTrue(result.message.contains("invalid_descriptor"))
        XCTAssertFalse((result.output ?? "").contains("SECRET"))
        XCTAssertTrue(resolver.received.isEmpty)
    }
    func testWrongTypedDescriptorValueIsInvalidNotTransportFailure() throws {
        let resolver = Resolver(); let source = make(resolver)
        let descriptor = #"{"id":"typed","kind":"graphql","endpointURL":42}"#
        XCTAssertTrue(try run(source, descriptor, [:]).message.contains("invalid_descriptor"))
        XCTAssertTrue(resolver.received.isEmpty)
    }
    func testActualWebURLContextExposesAcquisition() throws {
        let source = make()
        let web = ContentItem(kind: "web_url", display: "https://example.test/graphql",
                              url: "https://example.test/graphql", typeIdentifier: "public.url")
        XCTAssertEqual(try source.capabilities(for: web).map(\.id), [LiveCapabilityArtifactSource.acquireID])
    }
    func testOpenAPIUsesExistingSpecificationAndBaseURLContract() throws {
        let resolver = Resolver("openapi"); let source = make(resolver)
        let result = try run(source, "https://example.test/openapi.json",
                             ["kind": "openapi", "baseURL": "https://example.test", "id": "rest"])
        XCTAssertEqual(result.state, .accepted)
        XCTAssertEqual(resolver.received.first?.specificationURL, "https://example.test/openapi.json")
        XCTAssertEqual(resolver.received.first?.baseURL, "https://example.test")
        XCTAssertNil(resolver.received.first?.endpointURL)
    }
    func testCredentialBearingLocatorsAreNotCapabilities() throws {
        let source = make()
        for raw in ["https://user:secret@example.test/", "https://example.test/?token=secret", "https://example.test/#secret"] {
            XCTAssertTrue(try source.capabilities(for: item(raw)).isEmpty)
        }
    }
    func testDescriptorCannotHideCredentialInURL() throws {
        let resolver = Resolver(); let source = make(resolver)
        let descriptor = #"{"id":"typed","kind":"graphql","endpointURL":"https://example.test/?token=secret"}"#
        XCTAssertTrue(try run(source, descriptor, [:]).message.contains("unsafe_locator"))
        XCTAssertTrue(resolver.received.isEmpty)
    }
    func testRepeatedURLReusesSessionIdentity() throws {
        let resolver = Resolver(); let source = make(resolver)
        _ = try run(source, "https://example.test/graphql", ["kind": "graphql"])
        _ = try run(source, "https://example.test/graphql", ["kind": "graphql"])
        XCTAssertEqual(resolver.received[0].id, resolver.received[1].id)
        XCTAssertEqual(graphIDs(source).count, 2)
    }
    func testExplicitDuplicateContractRejected() throws {
        let resolver = Resolver(); let source = make(resolver)
        _ = try run(source)
        let result = try run(source, "https://example.test/graphql", ["id": "other", "kind": "graphql"])
        XCTAssertTrue(result.message.contains("duplicate_contract"))
        XCTAssertEqual(resolver.received.count, 1)
    }
    func testDescriptorRebindingRequiresForget() throws {
        let resolver = Resolver(); let source = make(resolver)
        _ = try run(source)
        XCTAssertTrue(try run(source, "https://other.test/graphql").message.contains("descriptor_conflict"))
        XCTAssertEqual(resolver.received.count, 1)
    }
    func testResolverFailureVisibleAndRedacted() throws {
        let resolver = Resolver(); resolver.error = RightClickError("Bearer SECRET https://host/?key=SECRET")
        let source = make(resolver)
        let record = try run(source)
        XCTAssertEqual(record.state, .failed)
        XCTAssertTrue(record.message.contains("resolution_failed"))
        XCTAssertFalse((record.output ?? "").contains("SECRET"))
        XCTAssertTrue(try status(source).contains("resolution_failed"))
        XCTAssertEqual(graphIDs(source), [source.id])
    }
    func testUnsupportedKindIsNotTransportFailure() throws {
        let source = make()
        let record = try run(source, "https://example.test/", ["kind": "missing"])
        XCTAssertTrue(record.message.contains("unsupported_kind"))
    }
    func testEmptyContractIsNotAcquired() throws {
        let resolver = Resolver(); resolver.empty = true; let source = make(resolver)
        XCTAssertTrue(try run(source).message.contains("no_capabilities"))
        XCTAssertEqual(graphIDs(source), [source.id])
    }
    func testMalformedEnvironmentIsVisible() throws {
        let source = make(env: [ConfiguredCapabilityArtifactSource.environmentKey: "not JSON SECRET"])
        let output = try status(source)
        XCTAssertTrue(output.contains("invalid_configuration"))
        XCTAssertFalse(output.contains("SECRET"))
    }
    func testEnvironmentDescriptorsStillResolve() throws {
        let resolver = Resolver()
        let env = #"[{"id":"env","kind":"graphql","endpointURL":"https://example.test/g"}]"#
        let source = make(resolver, env: [ConfiguredCapabilityArtifactSource.environmentKey: env])
        XCTAssertTrue(resolver.received.isEmpty)
        XCTAssertTrue(graphIDs(source).contains("probe:env"))
    }
    func testDuplicateEnvironmentIDsFailClosedWithReason() throws {
        let env = #"[{"id":"a","kind":"graphql"},{"id":"a","kind":"graphql"}]"#
        let resolver = Resolver(); let source = make(resolver, env: [ConfiguredCapabilityArtifactSource.environmentKey: env])
        XCTAssertEqual(graphIDs(source), [source.id])
        XCTAssertTrue(try status(source).contains("duplicate_id"))
        XCTAssertTrue(resolver.received.isEmpty)
    }
    func testRefreshFailureWithdrawsThenRecoveryReacquires() throws {
        let clock = Clock(); let resolver = Resolver(); let source = make(resolver, clock: clock)
        _ = try run(source)
        resolver.error = RightClickError("unavailable"); clock.now += 6
        XCTAssertEqual(graphIDs(source), [source.id])
        XCTAssertTrue(try status(source).contains("resolution_failed"))
        resolver.error = nil; clock.now += 6
        XCTAssertTrue(graphIDs(source).contains("probe:test"))
    }
    func testForgetOnlyChangesCurrentSession() throws {
        let source = make(); _ = try run(source)
        let record = try run(source, LiveCapabilityArtifactSource.statusItem, ["id": "test"], action: LiveCapabilityArtifactSource.forgetID)
        XCTAssertTrue(record.message.contains("forgotten"))
        XCTAssertEqual(graphIDs(source), [source.id])
    }
    func testCapacityBound() throws {
        let source = make()
        for index in 0..<64 {
            XCTAssertEqual(try run(source, "https://example.test/\(index)", ["id": "id\(index)", "kind": "graphql"]).state, .accepted)
        }
        XCTAssertTrue(try run(source, "https://example.test/overflow").message.contains("capacity_reached"))
    }
    func testResolverIdentityConflictReported() throws {
        let resolver = Resolver(); resolver.fixedID = "same"; let source = make(resolver)
        _ = try run(source)
        _ = try run(source, "https://example.test/other", ["id": "second", "kind": "graphql"])
        XCTAssertEqual(graphIDs(source), [source.id])
        XCTAssertTrue(try status(source).contains("identity_conflict"))
    }
    func testNoProviderExecutionOrOutcomeClaimDuringAcquisition() throws {
        let source = make(); let record = try run(source)
        XCTAssertEqual(record.evidence.type, "capability_acquisition")
        XCTAssertFalse(record.evidence.outcomeVerified)
        XCTAssertEqual(record.state, .accepted)
    }
    func testExplicitSnapshotInvalidation() throws {
        let resolver = Resolver(); let source = make(resolver)
        _ = try run(source); resolver.error = RightClickError("unavailable")
        source.invalidateSnapshot()
        XCTAssertEqual(graphIDs(source), [source.id])
    }

#if os(macOS)
    func testEngineConfirmationDenialDoesNotResolve() throws {
        let resolver = Resolver(); let source = make(resolver)
        let engine = CapabilityEngine(reflectors: [], reflectorSources: [source])
        let record = try engine.begin(id: LiveCapabilityArtifactSource.acquireID,
            item: "https://example.test/g", confirmed: false, arguments: ["kind": "graphql"])
        XCTAssertEqual(record.state, .awaitingUser)
        XCTAssertTrue(resolver.received.isEmpty)
    }
    func testOneEngineGainsCapabilityAndRetainsAcquisitionRecord() throws {
        let source = make()
        let engine = CapabilityEngine(reflectors: [], reflectorSources: [source])
        let record = try engine.begin(id: LiveCapabilityArtifactSource.acquireID,
            item: "https://example.test/g", confirmed: true, arguments: ["kind": "graphql", "id": "same-engine"])
        XCTAssertEqual(record.state, .accepted)
        XCTAssertTrue(try engine.capabilities(for: "query remote").capabilities.contains { $0.id == "probe:same-engine:read" })
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(engine.executionStatus(record.executionId)), as: UTF8.self).contains(record.executionId))
    }
#endif
}
