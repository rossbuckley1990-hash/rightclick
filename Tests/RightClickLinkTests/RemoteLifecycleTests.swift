import Foundation
import XCTest
import NIOPosix
import NIOCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import RightClickCore
import RightClickProviders
@testable import RightClickLink

private final class PortableDeferredLinkProvider: RCIRExecutionReflector {
    let id = "fixture:portable-link-owner"
    var effects = 0
    var host: RCIRExecutionHost?
    var executionID: String?
    var completeSynchronously = false
    var resultSchema: CapabilitySchema = .integer
    var terminalResult: CapabilityValue = .integer(7)
    var model = RCIRTaskModel(shape: .deferred, maxEvents: 16, maxBytes: 16_384)
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
        let abi = try admissionOwner.abiContract(arguments: .string, result: resultSchema)
        let scope = RCIRScope("urn:link:fixture", .execute)
        return try host.execute(abi: abi, discovery: abi, arguments: .string(item.text ?? ""), scope: scope,
            taskModel: model,
            capability: admissionOwner, executionID: executionID, argumentStrings: arguments, item: item,
            verification: verification, expectedOutput: expectedOutput,
            target: URL(string: "https://fixture.invalid/deferred")!, authority: { [scope] },
            revalidate: revalidate, currentContract: { true }, dispatch: { _, start in
                try start {
                    self.effects += 1
                    _ = try? host.recordActiveTaskEvent(executionID: executionID, event: .accepted, now: Self.stamp())
                    if self.completeSynchronously {
                        _ = try? host.recordActiveTaskEvent(executionID: executionID, event: .completed(self.terminalResult), now: Self.stamp())
                    }
                }
                return .init(executionId: executionID, actionId: capability.id, state: .started, message: "Live portable provider.")
            }, resultValue: { record in
                guard let result = record.result else { throw RightClickError("Live result unavailable.") }
                return result
            })
    }
    func working() throws { _ = try host!.recordActiveTaskEvent(executionID: executionID!, event: .working, now: Self.stamp()) }
    func complete() throws { _ = try host!.recordActiveTaskEvent(executionID: executionID!, event: .completed(terminalResult), now: Self.stamp()) }
    func chunk(_ value: CapabilityValue) throws { _ = try host!.recordActiveTaskEvent(executionID: executionID!, event: .chunk(value), now: Self.stamp()) }
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

private struct RawBrokerTestFrame: Codable {
    let kind: String
    let runtimeID: String
    let routeID: UUID
    let payload: Data?
}
private struct ForgedEncryptedTestPacket: Codable {
    let version: Int
    let sessionID: UUID
    let agreementPublicKey: Data
    let ciphertext: Data
}
private final class EncryptedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: Int64 = 0
    func now() -> Int64 { lock.withLock { Int64(Date().timeIntervalSince1970 * 1000) + offset } }
    func advance(_ milliseconds: Int64) { lock.withLock { offset += milliseconds } }
}
private final class RawBrokerTestResponse: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<Data>
    private var bytes = ByteBufferAllocator().buffer(capacity: 1024)
    private var finished = false
    init(_ promise: EventLoopPromise<Data>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data); bytes.writeBuffer(&incoming)
        guard let length: UInt32 = bytes.getInteger(at: bytes.readerIndex), bytes.readableBytes >= Int(length) + 4 else { return }
        guard length <= 131_072, !finished else { context.close(promise: nil); return }
        bytes.moveReaderIndex(forwardBy: 4); finished = true
        promise.succeed(Data(bytes.readBytes(length: Int(length))!))
    }
    func channelInactive(context: ChannelHandlerContext) { fail(RemoteLinkError.connectionLost) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error); context.close(promise: nil) }
    private func fail(_ error: Error) { if !finished { finished = true; promise.fail(error) } }
}
private func rawBrokerExchange(_ frame: RawBrokerTestFrame, port: Int, group: MultiThreadedEventLoopGroup) async throws -> RawBrokerTestFrame {
    let promise = group.next().makePromise(of: Data.self), response = RawBrokerTestResponse(promise)
    let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(5)).channelInitializer { channel in
        do { try channel.pipeline.syncOperations.addHandler(response); return channel.eventLoop.makeSucceededFuture(()) }
        catch { return channel.eventLoop.makeFailedFuture(error) }
    }.connect(host: "127.0.0.1", port: port).get()
    defer { channel.close(promise: nil) }
    let timeout = channel.eventLoop.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
    defer { timeout.cancel() }
    let data = try RemoteWire.encode(frame)
    var buffer = channel.allocator.buffer(capacity: data.count + 4); buffer.writeInteger(UInt32(data.count)); buffer.writeBytes(data)
    try await channel.writeAndFlush(buffer).get()
    return try RemoteWire.decode(RawBrokerTestFrame.self, await promise.futureResult.get(), maximum: 131_072)
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
    @MainActor func testOversizedAndEscapedExportValuesCannotMakeLifecycleUnobservable() async throws {
        let f = try PortableDeferredLinkFixture(exportsValues: true); try await f.connect()
        f.provider.resultSchema = .string
        f.provider.model = .init(shape: .deferred, maxEvents: 16, maxBytes: 262_144)
        for value in [String(repeating: "x", count: 20_000), String(repeating: "\u{0}", count: 2_000)] {
            f.provider.terminalResult = .string(value)
            let run = try f.request(), initial = try await f.client.send(run)
            try f.provider.complete()
            let id = initial.summary.executionLifecycle!.executionID
            let status = try await f.client.send(f.client.makeStatusRequest(for: run, executionID: id))
            XCTAssertTrue(status.summary.executionLifecycle!.terminal); XCTAssertTrue(status.summary.executionLifecycle!.receiptAvailable)
            XCTAssertNil(status.summary.result)
            XCTAssertEqual(try status.summary.eventPage!.events.last!.value.canonicalData(), try CapabilityValue.null.canonicalData())
            XCTAssertEqual(try f.engine.executionStatus(id).result?.canonicalData(), try CapabilityValue.string(value).canonicalData())
            XCTAssertLessThanOrEqual(try RemoteWire.encode(status.summary).count, RemoteWire.maximumPayloadBytes)
        }
        XCTAssertEqual(f.provider.effects, 2)
    }

    @MainActor func testTerminalRemoteStreamHistoryBeyondOneLocalPageIsRetained() async throws {
        let f = try PortableDeferredLinkFixture(); try await f.connect()
        f.provider.model = .init(shape: .serverStream, element: .integer, maxEvents: 512, maxBytes: 262_144)
        let run = try f.request(), initial = try await f.client.send(run)
        try f.provider.working()
        for index in 0..<450 { try f.provider.chunk(.integer(Int64(index))) }
        try f.provider.complete()
        let id = initial.summary.executionLifecycle!.executionID
        let first = try await f.client.send(f.client.makeStatusRequest(for: run, executionID: id, limit: 256))
        XCTAssertTrue(first.summary.executionLifecycle!.terminal); XCTAssertEqual(first.summary.executionLifecycle!.sequence, 453)
        XCTAssertTrue(first.summary.eventPage!.hasMore)
        let tail = try await f.client.send(f.client.makeStatusRequest(for: run, executionID: id, cursor: 400, limit: 64))
        XCTAssertEqual(tail.summary.eventPage!.events.first!.sequence, 401)
        XCTAssertEqual(tail.summary.eventPage!.events.last!.kind, "completed")
        XCTAssertEqual(tail.summary.eventPage!.nextCursor, 453); XCTAssertFalse(tail.summary.eventPage!.hasMore)
        XCTAssertEqual(f.provider.effects, 1)
    }

    @MainActor func testRemoteFastCompletionRetainedBeforeDelayedCallerInitialRecord() async throws {
        let f = try PortableDeferredLinkFixture(); f.provider.completeSynchronously = true; try await f.connect()
        let registry = RemoteRuntimeRegistry(); try await registry.enroll(f.client, item: "portable")
        let engine = CapabilityEngine(reflectors: [], reflectorSources: [RemoteCapabilitySource(registry: registry)], experience: nil,
            runtimeEnvironment: .init(operatingSystem: .linux, architecture: "arm64"))
        let capability = try XCTUnwrap(engine.capabilities(for: "portable").capabilities.first)
        let initial = try engine.begin(id: capability.id, item: "portable", confirmed: false)
        let final = try await engine.refreshedExecutionStatus(initial.executionId)
        XCTAssertTrue(final.lifecycle!.terminal)
        ExecutionStore.shared.put(initial)
        let retained = engine.executionStatus(initial.executionId)
        XCTAssertTrue(retained.lifecycle!.terminal)
        XCTAssertEqual(try retained.result?.canonicalData(), try CapabilityValue.integer(7).canonicalData())
        XCTAssertEqual(f.provider.effects, 1)
    }

    @MainActor func testForgedEncryptedPacketsAndHandshakeQuotaDoNotDisconnectHostOrExecute() async throws {
        let f = try PortableDeferredLinkFixture(), clock = EncryptedTestClock()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2), broker = EncryptedOutboundLinkBroker(group: group)
        let port = try await broker.start()
        let host = EncryptedOutboundLinkHostSession(dispatcher: f.dispatcher, identity: f.target, group: group, now: clock.now)
        try await host.connect(host: "127.0.0.1", port: port)
        let transport = try EncryptedOutboundLinkTransport(identity: f.caller, trustedRuntimeKey: f.target.publicKey,
            host: "127.0.0.1", port: port, group: group, now: clock.now)
        let client = try RemoteLinkClient(identity: f.caller, trustedRuntimeKey: f.target.publicKey, transport: transport)
        let run = try f.request(), initial = try await client.send(run)
        let id = initial.summary.executionLifecycle!.executionID
        let hello = try await rawBrokerExchange(.init(kind: "hello", runtimeID: f.target.runtimeID,
            routeID: UUID(), payload: Data(repeating: 5, count: 32)), port: port, group: group)
        let certificate = try RemoteWire.decode(SignedRemoteMessage.self, XCTUnwrap(hello.payload), maximum: RemoteWire.maximumWireBytes)
        let certificateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: certificate.payload) as? [String: Any])
        let sessionID = try XCTUnwrap(UUID(uuidString: XCTUnwrap(certificateObject["sessionID"] as? String)))
        let packet = try RemoteWire.encode(ForgedEncryptedTestPacket(version: 1, sessionID: sessionID,
            agreementPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, ciphertext: Data(repeating: 0, count: 32)))
        for _ in 0..<2 {
            let rejected = try await rawBrokerExchange(.init(kind: "exchange", runtimeID: f.target.runtimeID,
                routeID: UUID(), payload: packet), port: port, group: group)
            XCTAssertEqual(rejected.kind, "error"); XCTAssertNil(rejected.payload)
        }
        let stillLive = try await client.send(client.makeStatusRequest(for: run, executionID: id))
        XCTAssertFalse(stillLive.summary.executionLifecycle!.terminal); XCTAssertEqual(f.provider.effects, 1)
        for _ in 0..<32 {
            let certificate = try await rawBrokerExchange(.init(kind: "hello", runtimeID: f.target.runtimeID,
                routeID: UUID(), payload: Data(repeating: 6, count: 32)), port: port, group: group)
            XCTAssertEqual(certificate.kind, "helloResult")
        }
        let overflow = try await rawBrokerExchange(.init(kind: "hello", runtimeID: f.target.runtimeID,
            routeID: UUID(), payload: Data(repeating: 7, count: 32)), port: port, group: group)
        XCTAssertEqual(overflow.kind, "error"); XCTAssertNil(overflow.payload)
        clock.advance(60_001)
        try f.provider.complete()
        let final = try await client.send(client.makeStatusRequest(for: run, executionID: id))
        XCTAssertTrue(final.summary.executionLifecycle!.terminal); XCTAssertEqual(f.provider.effects, 1)
        await host.shutdown(); await broker.shutdown(); try await group.shutdownGracefully()
    }

    @MainActor func testSignedInvalidRemoteCursorDoesNotChangeLiveRouteOrDispatchAgain() async throws {
        let f = try PortableDeferredLinkFixture()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2), broker = EncryptedOutboundLinkBroker(group: group)
        let port = try await broker.start()
        let host = EncryptedOutboundLinkHostSession(dispatcher: f.dispatcher, identity: f.target, group: group)
        try await host.connect(host: "127.0.0.1", port: port)
        let transport = try EncryptedOutboundLinkTransport(identity: f.caller, trustedRuntimeKey: f.target.publicKey,
            host: "127.0.0.1", port: port, group: group)
        let client = try RemoteLinkClient(identity: f.caller, trustedRuntimeKey: f.target.publicKey, transport: transport)
        let registry = RemoteRuntimeRegistry(); try await registry.enroll(client, item: "portable")
        let engine = CapabilityEngine(reflectors: [], reflectorSources: [RemoteCapabilitySource(registry: registry)], experience: nil)
        let capability = try XCTUnwrap(engine.capabilities(for: "portable").capabilities.first)
        let initial = try engine.begin(id: capability.id, item: "portable", confirmed: false)
        let live = try await engine.refreshedExecutionStatus(initial.executionId)
        XCTAssertFalse(live.lifecycle!.terminal)
        await XCTAssertAsyncLinkError(.invalidCursor) { _ = try await engine.refreshedExecutionStatus(initial.executionId, cursor: 99) }
        XCTAssertEqual(registry.registrations().first!.availability, .online)
        XCTAssertEqual(engine.executionStatus(initial.executionId).lifecycle?.terminal, false)
        try f.provider.working()
        let working = try await engine.refreshedExecutionStatus(initial.executionId)
        XCTAssertEqual(working.lifecycle!.phase, .working)
        try f.provider.complete()
        let final = try await engine.refreshedExecutionStatus(initial.executionId)
        XCTAssertTrue(final.lifecycle!.terminal); XCTAssertEqual(f.provider.effects, 1)
        await host.shutdown(); await broker.shutdown(); try await group.shutdownGracefully()
    }

    @MainActor func testRealEncryptedOutboundTransportLifecycleReconnectAndExactlyOneEffect() async throws {
        let f = try PortableDeferredLinkFixture()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let broker = EncryptedOutboundLinkBroker(group: group)
        let port = try await broker.start()
        let host = EncryptedOutboundLinkHostSession(dispatcher: f.dispatcher, identity: f.target, group: group)
        try await host.connect(host: "127.0.0.1", port: port)
        let transport = try EncryptedOutboundLinkTransport(identity: f.caller, trustedRuntimeKey: f.target.publicKey,
            host: "127.0.0.1", port: port, group: group)
        let client = try RemoteLinkClient(identity: f.caller, trustedRuntimeKey: f.target.publicKey, transport: transport)
        let capability = try XCTUnwrap(f.engine.capabilities(for: "portable").capabilities.first)
        let key = UUID()
        func request() throws -> RemoteExecutionRequest {
            client.makeRequest(operation: .run, item: "portable", capabilityID: capability.id,
                capabilityDigest: try RemoteExecutionDispatcher.contractDigest(capability), idempotencyKey: key)
        }
        let run = try request(), live = try await client.send(run)
        XCTAssertFalse(live.summary.executionLifecycle!.terminal)
        let retry = try await client.send(request())
        XCTAssertTrue(retry.reused); XCTAssertEqual(f.provider.effects, 1)
        await host.shutdown()
        do { _ = try await client.send(client.makeStatusRequest(for: run, executionID: live.summary.executionLifecycle!.executionID)); XCTFail("Disconnected host was observed") }
        catch {}
        // Explicitly reconnect infrastructure; observe the same execution. The
        // transport never repeats an uncertain consequential delivery itself.
        try await host.connect(host: "127.0.0.1", port: port)
        try f.provider.working()
        let working = try await client.send(client.makeStatusRequest(for: run, executionID: live.summary.executionLifecycle!.executionID))
        XCTAssertFalse(working.summary.executionLifecycle!.terminal)
        try f.provider.complete()
        let final = try await client.send(client.makeStatusRequest(for: run, executionID: live.summary.executionLifecycle!.executionID))
        XCTAssertTrue(final.summary.executionLifecycle!.terminal)
        XCTAssertEqual(try final.summary.result?.canonicalData(), try CapabilityValue.integer(7).canonicalData())
        XCTAssertEqual(f.provider.effects, 1)
        let wrongKey = try RemoteNodeIdentity(signer: RCIREd25519Signer(rawPrivateKey: Data(repeating: 31, count: 32)))
        let wrongPin = try EncryptedOutboundLinkTransport(identity: f.caller, trustedRuntimeKey: wrongKey.publicKey,
            host: "127.0.0.1", port: port, group: group)
        await XCTAssertAsyncLinkError(.wrongRuntime) { _ = try await wrongPin.exchange(Data(), targetRuntimeID: f.target.runtimeID) }
        await host.shutdown(); await broker.shutdown(); try await group.shutdownGracefully()
        print("REAL LINK SOCKET PROOF: outbound broker+host+caller, pinned Ed25519/X25519/ChaChaPoly, live -> disconnected -> reconnected same execution -> terminal integer7; effects=1")
    }

}

@MainActor private func XCTAssertAsyncLinkError(_ expected: RemoteLinkError, file: StaticString = #filePath, line: UInt = #line,
                                               _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? RemoteLinkError, expected, file: file, line: line) }
}
