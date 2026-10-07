import Foundation
import Logging
import MCP

#if !os(Windows)
// The SDK's POSIX adapter already handles partial reads and nonblocking writes.
typealias PortableStdioTransport = StdioTransport
#else
/// Newline-framed MCP on native file handles, including Windows anonymous pipes.
/// A dedicated reader avoids blocking Swift's cooperative executor.
actor PortableStdioTransport: Transport {
    nonisolated let logger = Logger(label: "rightclick.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
    private let input: FileHandle
    private let output: FileHandle
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false

    init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {
        guard !connected else { return }
        connected = true
        let input = self.input
        let continuation = self.continuation
        DispatchQueue(label: "rightclick.stdio.read").async {
            do {
                var pending = Data()
                while let chunk = try input.read(upToCount: 1), !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        guard newline - pending.startIndex <= 2_000_000 else {
                            throw MCPError.invalidRequest("MCP message exceeds the size limit")
                        }
                        let message = Data(pending[..<newline])
                        pending = Data(pending[(newline + 1)...])
                        if !message.isEmpty { continuation.yield(message) }
                    }
                    guard pending.count <= 2_000_000 else {
                        throw MCPError.invalidRequest("MCP message exceeds the size limit")
                    }
                }
                // An unterminated frame is never executed.
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        connected = false
        continuation.finish()
    }

    func receive() -> AsyncThrowingStream<Data, Error> { stream }

    func send(_ data: Data) async throws {
        guard connected else { throw MCPError.internalError("Stdio transport is disconnected") }
        var frame = data
        frame.append(10)
        try output.write(contentsOf: frame)
    }
}

#endif
