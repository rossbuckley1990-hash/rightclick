#if os(Windows)
import Foundation
import Dispatch
import Logging
import MCP

/// Windows pipe adapter only; JSON-RPC and tool dispatch stay in the shared SDK.
/// Native Windows CI is the acceptance boundary, not a source portability claim.
actor WindowsStdioTransport: Transport {
    nonisolated let logger = Logger(label: "rightclick.stdio.windows", factory: { _ in SwiftLogNoOpLogHandler() })
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let readerQueue = DispatchQueue(label: "rightclick.stdio.windows.reader")
    private var connected = false
    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    func connect() async throws {
        guard !connected else { return }
        connected = true
        let input = self.input; let continuation = self.continuation
        readerQueue.async {
            var pending = Data()
            do {
                while let data = try input.read(upToCount: 65_536), !data.isEmpty {
                    pending.append(data)
                    while let end = pending.firstIndex(of: 10) {
                        let frame = Data(pending[..<end])
                        guard frame.count <= 2_000_000 else { throw RightClickWindowsTransportError.frameTooLarge }
                        pending.removeSubrange(...end)
                        if !frame.isEmpty { continuation.yield(frame) }
                    }
                    guard pending.count <= 2_000_000 else { throw RightClickWindowsTransportError.frameTooLarge }
                }
                guard pending.isEmpty else { throw RightClickWindowsTransportError.incompleteFrame }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func disconnect() async {
        connected = false; continuation.finish(); try? input.close()
    }
    func receive() async -> AsyncThrowingStream<Data, Error> { stream }
    func send(_ data: Data) async throws {
        guard connected else { throw RightClickWindowsTransportError.disconnected }
        var framed = data; framed.append(10); try output.write(contentsOf: framed)
    }
}
private enum RightClickWindowsTransportError: Error { case disconnected, frameTooLarge, incompleteFrame }
#endif

