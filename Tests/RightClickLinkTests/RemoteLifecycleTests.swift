import Foundation
import XCTest
import RightClickCore
import RightClickProviders
@testable import RightClickLink

private final class PortableDeferredLinkProvider: RCIRExecutionReflector {
    let id = "fixture:portable-link-owner"
    var effects = 0
    var host: RCIRExecutionHost?
    var executionID: String?
    var completeSynchronously = false
    var declaration: Capability {
        .init(id: "fixture:portable-link-deferred", title: "Portable deferred Link fixture",
            source: .system, reflectorID: id, safety: .read, invocation: .direct,
            supportLevel: .experimental, requiresConfirmation: false)
    }
    func capabilities(for item: ContentItem) throws -> [Capability] { [declaration] }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        throw RightClickError("Fixture requires RCIR admission.")
    }
    func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem, executionID: String,
        arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?,
        host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        self.host = host; self.executionID = executionID
        let abi = try admissionOwner.abiContract(arguments: .string, result: .integer)
        let scope = RCIRScope("urn:link:fixture", .execute)
        return try host.execute(abi: abi, discovery: abi, arguments: .string(item.text ?? ""), scope: scope,
            taskModel: .init(shape: .deferred, maxEvents: 16, maxBytes: 16_384),
            capability: admissionOwner, executionID: executionID, argumentStrings: arguments, item: item,
            verification: verification, expectedOutput: expectedOutput,
            target: URL(string: "https://fixture.invalid/deferred")!, authority: { [scope] },
            revalidate: revalidate, currentContract: { true }, dispatch: { _, start in
                try start {
                    self.effects += 1
                    _ = try? host.recordActiveTaskEvent(executionID: executionID, event: .accepted, now: Self.stamp())
                    if self.completeSynchronously {
                        _ = try? host.recordActiveTaskEvent(executionID: executionID, event: .completed(.integer(7)), now: Self.stamp())
                    }
                }
                return .init(executionId: executionID, actionId: capability.id, state: .started, message: "Live portable provider.")
            }, resultValue: { record in
                guard let result = record.result else { throw RightClickError("Live result unavailable.") }
                return result
            })
    }
    func working() throws { _ = try host!.recordActiveTaskEvent(executionID: executionID!, event: .working, now: Self.stamp()) }
    func complete() throws { _ = try host!.recordActiveTaskEvent(executionID: executionID!, event: .completed(.integer(7)), now: Self.stamp()) }
    private static func stamp() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

@MainActor private final class PortableDeferredLinkFixture {
    let parent: URL
    let provider = PortableDeferredLinkProvider()
    let caller: RemoteNodeIdentity
    let target: RemoteNodeIdentity
    let engine: CapabilityEngine
    let relay = SimulatedLinkRelay()
    let ledger: RemoteReplayLedger
    var dispatcher: RemoteExecutionDispatcher
    let client: RemoteLinkClient
    let grant: RemoteCallerGrant
    init(exportsValues: Bool = true) throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-lifecycle-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        caller = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 17, count: 32)))
        target = try .init(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 19, count: 32)))
        engine = CapabilityEngine(reflectors: [provider], experience: nil,
            runtimeEnvironment: .init(operatingSystem: .linux, architecture: "x86_64"))
        ledger = try .init(directory: parent.appendingPathComponent("journal"), runtimeID: target.runtimeID)
        grant = try .init(publicKey: caller.publicKey, operations: [.runtime, .actions, .run, .status],
            capabilityIDs: [provider.declaration.id], exportValueCapabilityIDs: exportsValues ? [provider.declaration.id] : [])
        dispatcher = try .init(engine: engine, identity: target, ledger: ledger, grants: [grant], enabled: true)
        client = try .init(identity: caller, trustedRuntimeKey: target.publicKey, transport: relay)
    }
    deinit { try? FileManager.default.removeItem(at: parent) }
    func connect() async throws { try await dispatcher.establishOutboundConnection(to: relay) }
    func request(key: UUID = UUID()) throws -> RemoteExecutionRequest {
        let capability = try engine.capabilities(for: "portable").capabilities[0]
        return client.makeRequest(operation: .run, item: "portable", capabilityID: capability.id,
            capabilityDigest: try RemoteExecutionDispatcher.contractDigest(capability), idempotencyKey: key)
    }
}

final class RemoteLifecycleTests: XCTestCase {
    @MainActor func testPortableRemoteDeferredLifecycleAndTypedTerminalEvidence() async throws {
        let f = try PortableDeferredLinkFixture(); try await f.connect()
        let run = try f.request(), initial = try await f.client.send(run)
        let live = try XCTUnwrap(initial.summary.executionLifecycle)
        XCTAssertFalse(live.terminal); XCTAssertEqual(live.phase, .accepted)
        XCTAssertFalse(live.receiptAvailable); XCTAssertNil(initial.summary.result)
        try f.provider.working()
        let working = try await f.client.send(f.client.makeStatusRequest(for: run, executionID: live.executionID))
        XCTAssertFalse(working.summary.executionLifecycle!.terminal)
        XCTAssertEqual(working.summary.eventPage!.events.map(\.kind), ["accepted", "working"])
        try f.provider.complete()
        let final = try await f.client.send(f.client.makeStatusRequest(for: run, executionID: live.executionID, cursor: 2))
        XCTAssertTrue(final.summary.executionLifecycle!.terminal)
        XCTAssertEqual(final.summary.executionLifecycle!.phase, .completed)
        XCTAssertTrue(final.summary.executionLifecycle!.receiptAvailable)
        XCTAssertEqual(final.summary.verification, .unverified)
        XCTAssertEqual(final.summary.providerAcceptance, .accepted)
        XCTAssertEqual(try final.summary.result?.canonicalData(), try CapabilityValue.integer(7).canonicalData())
        XCTAssertEqual(final.summary.eventPage!.events.map(\.kind), ["completed"])
        let reread = try await f.client.send(f.client.makeStatusRequest(for: run, executionID: live.executionID, cursor: 0, limit: 1))
        XCTAssertTrue(reread.summary.eventPage!.terminal); XCTAssertTrue(reread.summary.eventPage!.hasMore)
        XCTAssertEqual(reread.summary.eventPage!.events.map(\.kind), ["accepted"])
        XCTAssertEqual(f.provider.effects, 1)
        print("PROOF C: signed portable remote live -> working -> completed; typed integer7; receipts retained target; semantic unverified; effects=1")
    }
    @MainActor func testLiveSameIntentRetryAndLostResponseCannotRedispatch() async throws {
        let f = try PortableDeferredLinkFixture(); try await f.connect(); let key = UUID()
        let firstRun = try f.request(key: key)
        await f.relay.loseNextResponse()
        do { _ = try await f.client.send(firstRun); XCTFail("Lost response was accepted") } catch {}
        let retry = try await f.client.send(f.request(key: key))
        XCTAssertTrue(retry.reused); XCTAssertFalse(retry.summary.executionLifecycle!.terminal)
        XCTAssertEqual(retry.summary.executionLifecycle!.originatingRequestID, firstRun.requestID.uuidString)
        XCTAssertEqual(f.provider.effects, 1)
        try f.provider.complete()
        let finalRetry = try await f.client.send(f.request(key: key))
        XCTAssertTrue(finalRetry.reused); XCTAssertTrue(finalRetry.summary.executionLifecycle!.terminal)
        XCTAssertEqual(f.provider.effects, 1)
    }
    @MainActor func testFastCompletionBeforeInitialResponseHasTerminalResultAndHistory() async throws {
        let f = try PortableDeferredLinkFixture(); f.provider.completeSynchronously = true; try await f.connect()
        let run = try f.request(), response = try await f.client.send(run)
        let live = try XCTUnwrap(response.summary.executionLifecycle)
        XCTAssertTrue(live.terminal); XCTAssertTrue(live.receiptAvailable)
        XCTAssertEqual(response.summary.eventPage!.events.map(\.kind), ["accepted", "completed"])
        let status = try await f.client.send(f.client.makeStatusRequest(for: run, executionID: live.executionID))
        XCTAssertTrue(status.summary.executionLifecycle!.terminal); XCTAssertEqual(f.provider.effects, 1)
    }
    @MainActor func testDefaultPrivacyProjectionRetainsTypedKindsAndEvidenceWithoutValues() async throws {
        let f = try PortableDeferredLinkFixture(exportsValues: false); try await f.connect()
        let run = try f.request(), initial = try await f.client.send(run)
        try f.provider.complete()
        let status = try await f.client.send(f.client.makeStatusRequest(for: run, executionID: initial.summary.executionLifecycle!.executionID))
        XCTAssertNil(status.summary.result); XCTAssertTrue(status.summary.executionLifecycle!.receiptAvailable)
        XCTAssertEqual(status.summary.eventPage!.events.map(\.kind), ["accepted", "completed"])
        XCTAssertTrue(try status.summary.eventPage!.events.allSatisfy { try $0.value.canonicalData() == CapabilityValue.null.canonicalData() })
        let encoded = String(decoding: try RemoteWire.encode(status.summary), as: UTF8.self)
        XCTAssertFalse(encoded.contains("signedReceipt\":")); XCTAssertFalse(encoded.contains("\"receipt\":"))
    }
    @MainActor func testPollingCannotSubstituteExecutionCallerContractOrOriginalRequest() async throws {
        let f = try PortableDeferredLinkFixture(); try await f.connect()
        let run = try f.request(), initial = try await f.client.send(run), id = initial.summary.executionLifecycle!.executionID
        var status = f.client.makeStatusRequest(for: run, executionID: id)
        status.status!.originatingRequestID = UUID()
        await XCTAssertAsyncLinkError(.unauthorized) { _ = try await f.client.send(status) }
        status = f.client.makeStatusRequest(for: run, executionID: id); status.capabilityDigest = String(repeating: "a", count: 64)
        await XCTAssertAsyncLinkError(.unauthorized) { _ = try await f.client.send(status) }
        status = f.client.makeStatusRequest(for: run, executionID: UUID().uuidString)
        await XCTAssertAsyncLinkError(.unauthorized) { _ = try await f.client.send(status) }
        status = f.client.makeStatusRequest(for: run, executionID: id)
        _ = try await f.client.send(status)
        await XCTAssertAsyncLinkError(.replay) { _ = try await f.client.send(status) }
        XCTAssertEqual(f.provider.effects, 1)
    }
}

@MainActor private func XCTAssertAsyncLinkError(_ expected: RemoteLinkError, file: StaticString = #filePath, line: UInt = #line,
                                               _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? RemoteLinkError, expected, file: file, line: line) }
}
