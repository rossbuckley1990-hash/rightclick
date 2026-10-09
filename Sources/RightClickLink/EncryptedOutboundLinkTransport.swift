import Foundation
import NIOCore
import NIOPosix
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Application-layer end-to-end encryption deliberately keeps relay routing
// metadata outside the authenticated execution protocol. Both peers establish
// outbound TCP sessions; the broker cannot read signed execution/status bytes.
private enum EncryptedLinkWire {
    static let maximumFrameBytes = 131_072
    static let helloDomain = Data("RIGHTCLICK-LINK-ENCRYPTED-HELLO-1\0".utf8)
    static let requestInfo = Data("RIGHTCLICK-LINK-ENCRYPTED-CALLER-1\0".utf8)
    static let responseInfo = Data("RIGHTCLICK-LINK-ENCRYPTED-HOST-1\0".utf8)
    static func frame(_ message: BrokerFrame, channel: Channel) throws -> ByteBuffer {
        let data = try RemoteWire.encode(message)
        guard data.count <= maximumFrameBytes else { throw RemoteLinkError.limitExceeded }
        var buffer = channel.allocator.buffer(capacity: data.count + 4)
        buffer.writeInteger(UInt32(data.count)); buffer.writeBytes(data)
        return buffer
    }
    static func write(_ message: BrokerFrame, channel: Channel) {
        do { channel.writeAndFlush(try frame(message, channel: channel), promise: nil) }
        catch { channel.close(promise: nil) }
    }
}

private struct BrokerFrame: Codable {
    enum Kind: String, Codable { case register, registered, hello, helloResult, exchange, result, error }
    var kind: Kind
    var runtimeID: String
    var routeID: UUID
    var payload: Data?
}

private struct EncryptedHello: Codable {
    let version: Int
    let sessionID: UUID
    let challenge: Data
    let runtimeID: String
    let deviceID: String
    let agreementPublicKey: Data
    let expiresAtMilliseconds: Int64
}

private struct EncryptedPacket: Codable {
    let version: Int
    let sessionID: UUID
    let agreementPublicKey: Data
    let ciphertext: Data
}

private struct LinkFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = Data
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex) else { return .needMoreData }
        guard length > 0, length <= EncryptedLinkWire.maximumFrameBytes else { throw RemoteLinkError.limitExceeded }
        guard buffer.readableBytes >= Int(length) + 4 else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        let bytes = buffer.readBytes(length: Int(length))!
        context.fireChannelRead(wrapInboundOut(Data(bytes)))
        return .continue
    }
}

/// A bounded routing broker. It holds no node/provider credentials or plaintext
/// execution messages. Its assertions never establish trust or authorization.
public final class EncryptedOutboundLinkBroker: @unchecked Sendable {
    private struct Pending {
        let caller: Channel
        let target: Channel
        let kind: BrokerFrame.Kind
        let expiry: Scheduled<Void>
    }
    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()
    private var listener: Channel?
    private var hosts: [String: Channel] = [:]
    private var pending: [UUID: Pending] = [:]
    private var connections: [ObjectIdentifier: Channel] = [:]
    public init(group: MultiThreadedEventLoopGroup) { self.group = group }
    public func start(host: String = "127.0.0.1", port: Int = 0) async throws -> Int {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LinkFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(BrokerHandler(self))
                    return channel.eventLoop.makeSucceededFuture(())
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.bind(host: host, port: port).get()
        lock.withLock { listener = channel }
        guard let port = channel.localAddress?.port else { throw RemoteLinkError.unavailable }
        return port
    }
    public func shutdown() async {
        let channels = lock.withLock {
            let channels = Array(connections.values) + [listener].compactMap { $0 }
            for request in pending.values { request.expiry.cancel() }
            listener = nil; hosts = [:]; pending = [:]; connections = [:]
            return channels
        }
        for channel in channels { try? await channel.close().get() }
    }
    fileprivate func admitted(_ channel: Channel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard connections.count < 32 else { return false }
        connections[ObjectIdentifier(channel)] = channel; return true
    }
    fileprivate func closed(_ channel: Channel) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(channel))
        hosts = hosts.filter { $0.value !== channel }
        let failed = pending.filter { $0.value.target === channel || $0.value.caller === channel }
        for (key, request) in failed { request.expiry.cancel(); pending.removeValue(forKey: key) }
        lock.unlock()
        for (id, request) in failed where request.caller !== channel {
            EncryptedLinkWire.write(.init(kind: .error, runtimeID: "", routeID: id), channel: request.caller)
        }
    }
    fileprivate func receive(_ frame: BrokerFrame, from channel: Channel) throws {
        guard RemoteWire.isIdentifier(frame.runtimeID) else { throw RemoteLinkError.malformed }
        lock.lock()
        switch frame.kind {
        case .register:
            guard frame.payload == nil, hosts.count < 16 || hosts[frame.runtimeID] != nil,
                  hosts[frame.runtimeID] == nil else { lock.unlock(); throw RemoteLinkError.unauthorized }
            hosts[frame.runtimeID] = channel; lock.unlock()
            EncryptedLinkWire.write(.init(kind: .registered, runtimeID: frame.runtimeID, routeID: frame.routeID), channel: channel)
        case .hello, .exchange:
            guard pending.count < 16, pending[frame.routeID] == nil,
                  let target = hosts[frame.runtimeID], target !== channel,
                  let payload = frame.payload,
                  frame.kind != .hello || payload.count == 32 else { lock.unlock(); throw RemoteLinkError.unavailable }
            let expiry = channel.eventLoop.scheduleTask(in: .seconds(60)) { [weak self] in self?.expired(frame.routeID); return () }
            pending[frame.routeID] = Pending(caller: channel, target: target, kind: frame.kind, expiry: expiry)
            lock.unlock()
            EncryptedLinkWire.write(frame, channel: target)
        case .helloResult, .result, .error:
            guard let request = pending[frame.routeID], request.target === channel,
                  frame.kind == .error || (request.kind == .hello && frame.kind == .helloResult) ||
                    (request.kind == .exchange && frame.kind == .result)
            else { lock.unlock(); throw RemoteLinkError.unauthorized }
            pending.removeValue(forKey: frame.routeID); request.expiry.cancel(); lock.unlock()
            EncryptedLinkWire.write(frame, channel: request.caller)
        case .registered: lock.unlock(); throw RemoteLinkError.unauthorized
        }
    }
    private func expired(_ id: UUID) {
        lock.lock(); let request = pending.removeValue(forKey: id); lock.unlock()
        if let request { EncryptedLinkWire.write(.init(kind: .error, runtimeID: "", routeID: id), channel: request.caller) }
    }
}

private final class BrokerHandler: ChannelInboundHandler {
    typealias InboundIn = Data
    private let broker: EncryptedOutboundLinkBroker
    init(_ broker: EncryptedOutboundLinkBroker) { self.broker = broker }
    func channelActive(context: ChannelHandlerContext) {
        if !broker.admitted(context.channel) { context.close(promise: nil) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            try broker.receive(RemoteWire.decode(BrokerFrame.self, unwrapInboundIn(data), maximum: EncryptedLinkWire.maximumFrameBytes), from: context.channel)
        } catch { context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { broker.closed(context.channel) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// One opt-in outbound host session. Disconnect does not cancel or retry an
/// admitted execution: durable status/intent ownership stays with the dispatcher.
public final class EncryptedOutboundLinkHostSession: @unchecked Sendable {
    private struct Session {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let certificate: Data
        let expiresAt: Int64
    }
    private let dispatcher: RemoteExecutionDispatcher
    private let identity: RemoteNodeIdentity
    private let group: MultiThreadedEventLoopGroup
    private let now: () -> Int64
    private let lock = NSLock()
    private var channel: Channel?
    private var connecting = false
    private var sessions: [UUID: Session] = [:]
    private var inFlight = 0
    private var registration: (UUID, EventLoopPromise<Void>, Scheduled<Void>)?
    public init(dispatcher: RemoteExecutionDispatcher, identity: RemoteNodeIdentity,
                group: MultiThreadedEventLoopGroup,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.dispatcher = dispatcher; self.identity = identity; self.group = group; self.now = now
    }
    public func connect(host: String, port: Int) async throws {
        let reserved = lock.withLock { () -> Bool in
            guard self.channel == nil, !connecting else { return false }
            connecting = true; return true
        }
        guard reserved else { throw RemoteLinkError.idempotencyConflict }
        defer { lock.withLock { connecting = false } }
        let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(5))
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LinkFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(HostHandler(self))
                    return channel.eventLoop.makeSucceededFuture(())
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.connect(host: host, port: port).get()
        lock.withLock { self.channel = channel }
        let frame = BrokerFrame(kind: .register, runtimeID: identity.runtimeID, routeID: UUID())
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let expiry = channel.eventLoop.scheduleTask(in: .seconds(5)) { [weak self] in
            self?.failRegistration(RemoteLinkError.connectionLost); channel.close(promise: nil)
        }
        lock.withLock { registration = (frame.routeID, promise, expiry) }
        do {
            try await channel.writeAndFlush(EncryptedLinkWire.frame(frame, channel: channel)).get()
            try await promise.futureResult.get()
        } catch { failRegistration(error); channel.close(promise: nil); throw error }
    }
    public func shutdown() async {
        failRegistration(RemoteLinkError.connectionLost)
        let channel = lock.withLock { let channel = self.channel; self.channel = nil; sessions = [:]; return channel }
        try? await channel?.close().get()
    }
    fileprivate func disconnected(_ channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        if self.channel === channel {
            self.channel = nil; sessions = [:]
            let previous = registration; registration = nil; previous?.2.cancel(); previous?.1.fail(RemoteLinkError.connectionLost)
        }
    }
    private func failRegistration(_ error: Error) {
        let previous = lock.withLock { let previous = registration; registration = nil; return previous }
        previous?.2.cancel(); previous?.1.fail(error)
    }
    fileprivate func receive(_ frame: BrokerFrame, channel: Channel) throws {
        guard frame.runtimeID == identity.runtimeID else { throw RemoteLinkError.wrongRuntime }
        switch frame.kind {
        case .registered:
            guard frame.payload == nil else { throw RemoteLinkError.malformed }
            let previous = lock.withLock { () -> (UUID, EventLoopPromise<Void>, Scheduled<Void>)? in
                guard registration?.0 == frame.routeID else { return nil }
                let previous = registration; registration = nil; return previous
            }
            guard let previous else { throw RemoteLinkError.replay }
            previous.2.cancel(); previous.1.succeed(())
        case .hello:
            guard let challenge = frame.payload, challenge.count == 32 else { throw RemoteLinkError.malformed }
            let stamp = now(); guard stamp > 0, stamp <= Int64.max - 60_000 else { throw RemoteLinkError.expired }
            let key = Curve25519.KeyAgreement.PrivateKey(), id = UUID()
            let hello = EncryptedHello(version: 1, sessionID: id, challenge: challenge,
                runtimeID: identity.runtimeID, deviceID: identity.deviceID,
                agreementPublicKey: key.publicKey.rawRepresentation, expiresAtMilliseconds: stamp + 60_000)
            let certificate = try SignedRemoteMessage.seal(hello, domain: EncryptedLinkWire.helloDomain, signer: identity)
            lock.lock(); sessions = sessions.filter { $0.value.expiresAt > stamp }
            guard sessions.count < 32 else { lock.unlock(); throw RemoteLinkError.limitExceeded }
            sessions[id] = Session(privateKey: key, certificate: certificate, expiresAt: hello.expiresAtMilliseconds); lock.unlock()
            EncryptedLinkWire.write(.init(kind: .helloResult, runtimeID: identity.runtimeID, routeID: frame.routeID, payload: certificate), channel: channel)
        case .exchange:
            guard let payload = frame.payload else { throw RemoteLinkError.malformed }
            let packet = try RemoteWire.decode(EncryptedPacket.self, payload, maximum: EncryptedLinkWire.maximumFrameBytes)
            guard packet.version == 1, packet.agreementPublicKey.count == 32,
                  packet.ciphertext.count <= RemoteWire.maximumWireBytes + 28 else { throw RemoteLinkError.limitExceeded }
            lock.lock()
            guard inFlight < 16, let session = sessions.removeValue(forKey: packet.sessionID) else { lock.unlock(); throw RemoteLinkError.replay }
            inFlight += 1; lock.unlock()
            do {
                guard session.expiresAt > now() else { throw RemoteLinkError.expired }
                let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: packet.agreementPublicKey)
                let secret = try session.privateKey.sharedSecretFromKeyAgreement(with: publicKey)
                let requestKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: session.certificate,
                    sharedInfo: EncryptedLinkWire.requestInfo, outputByteCount: 32)
                let responseKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: session.certificate,
                    sharedInfo: EncryptedLinkWire.responseInfo, outputByteCount: 32)
                let bytes = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: packet.ciphertext), using: requestKey,
                    authenticating: session.certificate)
                guard bytes.count <= RemoteWire.maximumWireBytes else { throw RemoteLinkError.limitExceeded }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.finishRequest() }
                    do {
                        let result = try self.dispatcher.handle(bytes)
                        let ciphertext = try ChaChaPoly.seal(result, using: responseKey, authenticating: session.certificate).combined
                        EncryptedLinkWire.write(.init(kind: .result, runtimeID: self.identity.runtimeID,
                            routeID: frame.routeID, payload: ciphertext), channel: channel)
                    } catch {
                        // Never export provider diagnostics. Transport failure may
                        // follow an effect and the client does not retry it.
                        EncryptedLinkWire.write(.init(kind: .error, runtimeID: self.identity.runtimeID,
                            routeID: frame.routeID), channel: channel)
                    }
                }
            } catch { finishRequest(); throw error }
        default: throw RemoteLinkError.unsupportedOperation
        }
    }
    fileprivate func reject(_ frame: BrokerFrame, channel: Channel) {
        EncryptedLinkWire.write(.init(kind: .error, runtimeID: identity.runtimeID,
            routeID: frame.routeID), channel: channel)
    }
    private func finishRequest() { lock.lock(); inFlight -= 1; lock.unlock() }
}

private final class HostHandler: ChannelInboundHandler {
    typealias InboundIn = Data
    private let host: EncryptedOutboundLinkHostSession
    init(_ host: EncryptedOutboundLinkHostSession) { self.host = host }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame: BrokerFrame
        do { frame = try RemoteWire.decode(BrokerFrame.self, unwrapInboundIn(data), maximum: EncryptedLinkWire.maximumFrameBytes) }
        catch { context.close(promise: nil); return }
        do { try host.receive(frame, channel: context.channel) }
        catch {
            if frame.kind == .hello || frame.kind == .exchange { host.reject(frame, channel: context.channel) }
            else { context.close(promise: nil) }
        }
    }
    func channelInactive(context: ChannelHandlerContext) { host.disconnected(context.channel) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

// Mutable request state is confined to the channel's event loop. The only
// cross-thread entry point schedules onto that event loop before accessing it.
private final class CallerResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Data
    private var pending: (UUID, EventLoopPromise<BrokerFrame>, Scheduled<Void>)?
    func request(_ frame: BrokerFrame, channel: Channel) -> EventLoopFuture<BrokerFrame> {
        let promise = channel.eventLoop.makePromise(of: BrokerFrame.self)
        channel.eventLoop.execute {
            guard self.pending == nil else { promise.fail(RemoteLinkError.limitExceeded); return }
            let expiry = channel.eventLoop.scheduleTask(in: .seconds(60)) {
                if self.pending?.0 == frame.routeID {
                    self.pending = nil; promise.fail(RemoteLinkError.connectionLost); channel.close(promise: nil)
                }
            }
            self.pending = (frame.routeID, promise, expiry)
            do {
                channel.writeAndFlush(try EncryptedLinkWire.frame(frame, channel: channel)).whenFailure { error in
                    if self.pending?.0 == frame.routeID { self.fail(error) }
                }
            } catch { self.fail(error) }

        }
        return promise.futureResult
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            let frame = try RemoteWire.decode(BrokerFrame.self, unwrapInboundIn(data), maximum: EncryptedLinkWire.maximumFrameBytes)
            guard let (id, promise, expiry) = pending, id == frame.routeID else { throw RemoteLinkError.unauthenticated }
            pending = nil; expiry.cancel()
            if frame.kind == .error { promise.fail(RemoteLinkError.connectionLost) }
            else { promise.succeed(frame) }
        } catch { fail(error); context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { fail(RemoteLinkError.connectionLost) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error); context.close(promise: nil) }
    private func fail(_ error: Error) { let previous = pending; pending = nil; previous?.2.cancel(); previous?.1.fail(error) }
}

/// Real encrypted outbound transport. Each exchange uses a fresh challenge and
/// ephemeral agreement key, verifies the pinned target before sending plaintext,
/// and makes exactly one delivery attempt. Existing signed Link/ledger semantics
/// independently authenticate caller intent and prevent duplicate effects.
public final class EncryptedOutboundLinkTransport: RemoteLinkTransport, @unchecked Sendable {
    private let identity: RemoteNodeIdentity
    private let target: RemoteNodeIdentityReference
    private let host: String
    private let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let now: () -> Int64
    public init(identity: RemoteNodeIdentity, trustedRuntimeKey: Data, host: String, port: Int,
                group: MultiThreadedEventLoopGroup,
                now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard !host.isEmpty, (1...65535).contains(port) else { throw RemoteLinkError.malformed }
        self.identity = identity; self.target = try .init(publicKey: trustedRuntimeKey)
        self.host = host; self.port = port; self.group = group; self.now = now
    }
    public func exchange(_ request: Data, targetRuntimeID: String) async throws -> Data {
        guard targetRuntimeID == target.runtimeID, request.count <= RemoteWire.maximumWireBytes else { throw RemoteLinkError.wrongRuntime }
        let responseHandler = CallerResponseHandler()
        let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(5))
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LinkFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(responseHandler)
                    return channel.eventLoop.makeSucceededFuture(())
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }
            .connect(host: host, port: port).get()
        defer { channel.close(promise: nil) }
        var random = SystemRandomNumberGenerator()
        let challenge = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        let certificateFrame = try await responseHandler.request(.init(kind: .hello, runtimeID: target.runtimeID,
            routeID: UUID(), payload: challenge), channel: channel).get()
        guard certificateFrame.kind == .helloResult, let certificate = certificateFrame.payload else { throw RemoteLinkError.unauthenticated }
        let envelope = try RemoteWire.decode(SignedRemoteMessage.self, certificate, maximum: RemoteWire.maximumWireBytes)
        try envelope.authenticate(domain: EncryptedLinkWire.helloDomain, trustedKey: target.publicKey)
        let hello = try RemoteWire.decode(EncryptedHello.self, envelope.payload)
        let stamp = now()
        guard stamp > 0, hello.version == 1, hello.challenge == challenge, hello.runtimeID == target.runtimeID,
              hello.deviceID == target.deviceID, hello.agreementPublicKey.count == 32,
              hello.expiresAtMilliseconds > stamp, hello.expiresAtMilliseconds - stamp <= 60_000 else { throw RemoteLinkError.unauthenticated }
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let secret = try agreement.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: hello.agreementPublicKey))
        let requestKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: certificate,
            sharedInfo: EncryptedLinkWire.requestInfo, outputByteCount: 32)
        let responseKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: certificate,
            sharedInfo: EncryptedLinkWire.responseInfo, outputByteCount: 32)
        let packet = EncryptedPacket(version: 1, sessionID: hello.sessionID, agreementPublicKey: agreement.publicKey.rawRepresentation,
            ciphertext: try ChaChaPoly.seal(request, using: requestKey, authenticating: certificate).combined)
        let response = try await responseHandler.request(.init(kind: .exchange, runtimeID: target.runtimeID,
            routeID: UUID(), payload: RemoteWire.encode(packet)), channel: channel).get()
        guard response.kind == .result, let ciphertext = response.payload,
              ciphertext.count <= RemoteWire.maximumWireBytes + 28 else { throw RemoteLinkError.unauthenticated }
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: ciphertext), using: responseKey, authenticating: certificate)
    }
}
