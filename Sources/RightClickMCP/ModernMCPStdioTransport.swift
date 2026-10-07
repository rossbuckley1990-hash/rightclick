import Foundation
import Logging
import MCP

/// Compatibility layer for the modern MCP discovery flow used by ChatGPT.
///
/// RIGHTCLICK's current Swift MCP SDK supports the legacy initialize lifecycle
/// through MCP 2025-11-25. ChatGPT Secure MCP Tunnel currently probes stdio
/// servers using the MCP 2026-07-28 self-contained discovery flow:
///
///   server/discover
///   tools/list with request-scoped protocol metadata
///   tools/call with request-scoped protocol metadata
///
/// This transport handles only that compatibility boundary. The existing MCP
/// Server and RIGHTCLICK capability engine remain authoritative for tools.
actor ModernMCPStdioTransport: Transport {
    private static let modernProtocolVersion = "2026-07-28"

    private let base: PortableStdioTransport

    public nonisolated let logger: Logger

    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    /// Request id -> method for modern self-contained requests whose results
    /// need MCP 2026-07-28 completion metadata.
    private var pendingModernRequests: [String: String] = [:]

    init(base: PortableStdioTransport = PortableStdioTransport()) {
        self.base = base
        self.logger = base.logger

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {
        try await base.connect()

        let upstream = await base.receive()

        Task { [weak self] in
            guard let self else { return }

            do {
                for try await data in upstream {
                    try await self.handleIncoming(data)
                }

                await self.finish()
            } catch {
                await self.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        await base.disconnect()
        continuation.finish()
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }

    func send(_ data: Data) async throws {
        let decorated = decorateOutgoing(data)
        try await base.send(decorated)
    }

    private func handleIncoming(_ data: Data) async throws {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            continuation.yield(data)
            return
        }

        let method = object["method"] as? String

        // MCP 2026-07-28 introduces server/discover. The Swift SDK currently
        // does not expose this method, so answer it at the transport boundary.
        if method == "server/discover",
           let requestID = object["id"]
        {
            try await base.send(
                Self.discoveryResponse(requestID: requestID)
            )
            return
        }

        if let requestID = object["id"],
           Self.isModernRequest(object),
           let key = Self.idKey(requestID)
        {
            pendingModernRequests[key] = method ?? ""
        }

        continuation.yield(Self.sdkCompatibleMessage(data))
    }

    /// The pinned SDK decodes experimental client capabilities as string values.
    /// MCP clients may validly offer object-valued extensions. RIGHTCLICK does
    /// not implement or advertise these extensions, so ignore their advertisement
    /// at this SDK boundary while preserving all supported lifecycle fields.
    static func sdkCompatibleMessage(_ data: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "initialize",
              var params = object["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              capabilities["experimental"] is [String: Any] else { return data }
        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        object["params"] = params
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
    }

    private func decorateOutgoing(_ data: Data) -> Data {
        guard
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let responseID = object["id"],
            let key = Self.idKey(responseID),
            let method = pendingModernRequests.removeValue(forKey: key)
        else {
            return data
        }

        // Preserve error responses exactly.
        if object["error"] != nil {
            return data
        }

        guard var result = object["result"] as? [String: Any] else {
            return data
        }

        // MCP 2026-07-28 marks completed results explicitly.
        result["resultType"] = "complete"

        // List results are cacheable in the modern protocol. Keep discovery
        // dynamic: zero TTL means callers should re-query RIGHTCLICK.
        switch method {
        case "tools/list",
             "prompts/list",
             "resources/list",
             "resources/templates/list":
            result["ttlMs"] = 0
            result["cacheScope"] = "private"

        default:
            break
        }

        object["result"] = result

        guard
            JSONSerialization.isValidJSONObject(object),
            let encoded = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        else {
            return data
        }

        return encoded
    }

    private func finish(throwing error: Swift.Error? = nil) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private static func discoveryResponse(requestID: Any) throws -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "result": [
                "resultType": "complete",
                "supportedVersions": [
                    "2026-07-28",
                    "2025-11-25",
                    "2025-06-18",
                    "2025-03-26",
                    "2024-11-05",
                ],
                "capabilities": [
                    "tools": [
                        "listChanged": false,
                    ],
                ],
                "ttlMs": 0,
                "cacheScope": "private",
                "instructions":
                    "RIGHTCLICK discovers and safely invokes capabilities exposed by software and services available on this host.",
            ],
        ]

        return try JSONSerialization.data(
            withJSONObject: response,
            options: [.sortedKeys]
        )
    }

    private static func isModernRequest(_ object: [String: Any]) -> Bool {
        guard
            let params = object["params"] as? [String: Any],
            let metadata = params["_meta"] as? [String: Any],
            let version =
                metadata["io.modelcontextprotocol/protocolVersion"] as? String
        else {
            return false
        }

        return version >= modernProtocolVersion
    }

    private static func idKey(_ id: Any) -> String? {
        let wrapper: [String: Any] = ["id": id]

        guard
            JSONSerialization.isValidJSONObject(wrapper),
            let data = try? JSONSerialization.data(
                withJSONObject: wrapper,
                options: [.sortedKeys]
            )
        else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}
