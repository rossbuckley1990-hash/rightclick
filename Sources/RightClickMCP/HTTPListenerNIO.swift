#if os(Linux)
import Foundation
import MCP
import RightClickCore
import NIOCore
import NIOPosix
import NIOHTTP1

/// Loopback-only Linux HTTP adapter. Execution and authentication remain in the
/// same MCP dispatcher as macOS; this is not an internet-facing server.
final class MCPHTTPListener {
    private let port: UInt16
    private let path: String
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private var channel: Channel?
    init(port: UInt16, path: String, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port; self.path = path; self.handler = handler
    }
    func start() throws {
        let path = self.path; let handler = self.handler
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                    channel.pipeline.addHandler(BoundedHTTPHandler(path: path, handler: handler))
                }
            }.bind(host: "127.0.0.1", port: Int(port)).wait()
    }
    deinit { channel?.close(promise: nil); group.shutdownGracefully { _ in } }
}

private final class BoundedHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let path: String
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var head: HTTPRequestHead?
    private var body = Data()
    private var expected = 0
    private var dispatched = false
    private var deadline: Scheduled<Void>?
    private let maximumBody = 2_000_000
    init(path: String, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.path = path; self.handler = handler
    }
    func channelActive(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: .seconds(60)) { context.close(promise: nil) }
        context.fireChannelActive()
    }
    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel(); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !dispatched else { return }
        switch unwrapInboundIn(data) {
        case .head(let received):
            let lengths = received.headers["content-length"]
            let size = received.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
            guard head == nil, received.headers.count <= 64, size <= 16_384,
                  received.headers["transfer-encoding"].isEmpty, lengths.count <= 1,
                  received.headers["authorization"].count <= 1,
                  received.headers["content-type"].count <= 1 else {
                fail(context, status: .badRequest); return
            }
            let declared = lengths.first ?? "0"
            guard !declared.isEmpty, declared.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(declared), length <= maximumBody else {
                fail(context, status: .badRequest); return
            }
            head = received; expected = length
        case .body(var buffer):
            guard head != nil, buffer.readableBytes <= maximumBody - body.count,
                  body.count + buffer.readableBytes <= expected else {
                fail(context, status: .badRequest); return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head, body.count == expected else { fail(context, status: .badRequest); return }
            let requestPath = String(head.uri.split(separator: "?", maxSplits: 1).first ?? "")
            guard requestPath == path || requestPath == path + "/" else { fail(context, status: .notFound); return }
            dispatched = true
            var headers: [String: String] = [:]
            for entry in head.headers {
                let key = entry.name.lowercased()
                headers[key] = headers[key].map { $0 + ", " + entry.value } ?? entry.value
            }
            let request = HTTPRequest(method: head.method.rawValue, headers: headers,
                body: body.isEmpty ? nil : body, path: requestPath)
            let handler = self.handler
            // Channel supports cross-thread writes. Handler context and mutable
            // request state remain confined to this event loop.
            let channel = context.channel
            Task {
                let response = await handler(request)
                if case .stream(let stream, _) = response {
                    do { try await Self.sendStream(channel, response: response, stream: stream) }
                    catch { channel.close(promise: nil) }
                    return
                }
                let payload = response.bodyData ?? Data()
                guard payload.count <= 4 * 1024 * 1024 else {
                    channel.eventLoop.execute { Self.send(channel, status: .internalServerError, headers: [:], body: Data()) }
                    return
                }
                channel.eventLoop.execute {
                    Self.send(channel, status: HTTPResponseStatus(statusCode: response.statusCode), headers: response.headers, body: payload)
                }
            }
        }
    }
    private func fail(_ context: ChannelHandlerContext, status: HTTPResponseStatus) {
        dispatched = true; Self.send(context.channel, status: status, headers: [:], body: Data())
    }
    private static func sendStream(_ channel: any Channel, response: HTTPResponse,
        stream: AsyncThrowingStream<Data, Error>) async throws {
        var fields = HTTPHeaders()
        for (key, value) in response.headers where !["content-length", "transfer-encoding", "connection"].contains(key.lowercased()) {
            fields.add(name: key, value: value)
        }
        fields.add(name: "Transfer-Encoding", value: "chunked")
        fields.add(name: "Connection", value: "close")
        try await channel.writeAndFlush(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.statusCode), headers: fields))).get()
        var total = 0
        for try await chunk in stream {
            guard chunk.count <= 4 * 1024 * 1024 - total else { throw RightClickError("Stream response limit exceeded.") }
            total += chunk.count
            var buffer = channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
        }
        try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        try await channel.close().get()
    }
    private static func send(_ channel: any Channel, status: HTTPResponseStatus, headers: [String: String], body: Data) {
        var fields = HTTPHeaders()
        for (key, value) in headers where !["content-length", "transfer-encoding", "connection"].contains(key.lowercased()) {
            fields.add(name: key, value: value)
        }
        fields.add(name: "Content-Length", value: String(body.count)); fields.add(name: "Connection", value: "close")
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: fields)), promise: nil)
        if !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count); buffer.writeBytes(body)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }
}
#endif
