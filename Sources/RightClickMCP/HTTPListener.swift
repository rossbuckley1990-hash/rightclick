import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix

/// Loopback-only HTTP transport shared by macOS, Linux and Windows.
/// Protocol authentication and origin validation remain in the MCP dispatcher.
final class MCPHTTPListener: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let port: UInt16
    private let path: String
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var channel: Channel?

    init(port: UInt16, path: String, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.path = path
        self.handler = handler
    }

    func start() throws {
        let path = self.path
        let handler = self.handler
        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                    channel.pipeline.addHandler(PortableHTTPHandler(path: path, handler: handler))
                }
            }
            .bind(host: "127.0.0.1", port: Int(port)).wait()
    }

    func stop() throws {
        try channel?.close().wait()
        try group.syncShutdownGracefully()
    }
}

private final class PortableHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let path: String
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var head: HTTPRequestHead?
    private var body = Data()
    private var responding = false
    private let maximumBytes = 2_000_000

    init(path: String, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.path = path
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responding else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            let lengths = head.headers["content-length"]
            guard head.headers["transfer-encoding"].isEmpty, lengths.count <= 1,
                  lengths.allSatisfy({ value in
                      !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isNumber }) &&
                      Int(value).map { $0 <= maximumBytes } == true
                  }), head.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 65_536 else {
                reject(context)
                return
            }
            self.head = head
        case .body(let buffer):
            guard body.count + buffer.readableBytes <= maximumBytes else { reject(context); return }
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let head else { reject(context); return }
            responding = true
            let requestPath = String(head.uri.split(separator: "?", maxSplits: 1).first ?? "/")
            let responseHandler = self.handler
            let endpoint = self.path
            var headers: [String: String] = [:]
            for (name, value) in head.headers {
                let key = name.lowercased()
                headers[key] = headers[key].map { $0 + ", " + value } ?? value
            }
            let request = HTTPRequest(method: head.method.rawValue, headers: headers,
                                      body: body.isEmpty ? nil : body, path: requestPath)
            let channel = context.channel
            Task {
                let response = requestPath == endpoint || requestPath == endpoint + "/"
                    ? await responseHandler(request)
                    : HTTPResponse.error(statusCode: 404, .invalidRequest("Not found"))
                await Self.send(response, on: channel)
            }
        }
    }

    private func reject(_ context: ChannelHandlerContext) {
        responding = true
        let channel = context.channel
        Task { await Self.send(.error(statusCode: 400, .invalidRequest("Bad request")), on: channel) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { reject(context) }

    private static func send(_ response: HTTPResponse, on channel: Channel) async {
        do {
            var headers = HTTPHeaders()
            for (name, value) in response.headers where !["content-length", "transfer-encoding", "connection"].contains(name.lowercased()) {
                headers.add(name: name, value: value)
            }
            headers.add(name: "connection", value: "close")
            if case .stream = response {
                headers.add(name: "transfer-encoding", value: "chunked")
            } else {
                headers.add(name: "content-length", value: String(response.bodyData?.count ?? 0))
            }
            let head = HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.statusCode), headers: headers)
            try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
            if case .stream(let stream, _) = response {
                for try await chunk in stream {
                    var buffer = channel.allocator.buffer(capacity: chunk.count)
                    buffer.writeBytes(chunk)
                    try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
                }
            } else if let data = response.bodyData {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
            }
            try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        } catch { }
        try? await channel.close().get()
    }
}
