import Foundation
import MCP
import Network

final class MCPHTTPListener: @unchecked Sendable {
    private let port: UInt16
    private let path: String
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?

    init(port: UInt16, path: String, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.path = path
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RightClickListenerError("Invalid port \(port).")
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                await self.handle(connection)
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("HTTP listener failed: \(error)\n", stderr)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) async {
        do {
            let raw = try await readRequest(from: connection)
            guard raw.path == path || raw.path == path + "/" else {
                try await send(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8), stream: nil, connection: connection)
                return
            }
            let response = await handler(HTTPRequest(
                method: raw.method,
                headers: raw.headers,
                body: raw.body,
                path: raw.path
            ))
            try await send(
                status: response.statusCode,
                headers: response.headers,
                body: response.bodyData,
                stream: stream(from: response),
                connection: connection
            )
        } catch {
            try? await send(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request".utf8), stream: nil, connection: connection)
        }
    }

    private func stream(from response: HTTPResponse) -> AsyncThrowingStream<Data, Error>? {
        if case .stream(let stream, _) = response { return stream }
        return nil
    }

    private func readRequest(from connection: NWConnection) async throws -> RawHTTPRequest {
        var buffer = Data()
        while !buffer.contains(Data("\r\n\r\n".utf8)) {
            let chunk = try await receive(connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.count > 2_000_000 { throw RightClickListenerError("Request too large.") }
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            throw RightClickListenerError("Incomplete HTTP headers.")
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        var body = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { throw RightClickListenerError("Bad request line.") }
        let method = String(requestLine[0])
        let path = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let parts = line.split(separator: ":", maxSplits: 1)
            headers[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "") ?? 0
        while body.count < length {
            let chunk = try await receive(connection)
            if chunk.isEmpty { break }
            body.append(chunk)
        }
        if body.count > length {
            body = body.prefix(length)
        }
        return RawHTTPRequest(method: method, path: path, headers: headers, body: body.isEmpty ? nil : body)
    }

    private func send(
        status: Int,
        headers: [String: String],
        body: Data?,
        stream: AsyncThrowingStream<Data, Error>?,
        connection: NWConnection
    ) async throws {
        var fields = headers
        let reason = statusReason(status)
        if let stream {
            fields["Transfer-Encoding"] = "chunked"
            var header = "HTTP/1.1 \(status) \(reason)\r\n"
            for (key, value) in fields where key.lowercased() != "content-length" {
                header += "\(key): \(value)\r\n"
            }
            header += "\r\n"
            try await transmit(Data(header.utf8), connection: connection)
            for try await chunk in stream {
                try await transmit(chunked(chunk), connection: connection)
            }
            try await transmit(Data("0\r\n\r\n".utf8), connection: connection)
        } else {
            let payload = body ?? Data()
            fields["Content-Length"] = String(payload.count)
            var header = "HTTP/1.1 \(status) \(reason)\r\n"
            for (key, value) in fields {
                header += "\(key): \(value)\r\n"
            }
            header += "\r\n"
            try await transmit(Data(header.utf8) + payload, connection: connection)
        }
        connection.cancel()
    }

    private func chunked(_ data: Data) -> Data {
        var encoded = Data(String(format: "%X\r\n", data.count).utf8)
        encoded.append(data)
        encoded.append(Data("\r\n".utf8))
        return encoded
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private func transmit(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func statusReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 406: return "Not Acceptable"
        case 415: return "Unsupported Media Type"
        default: return "Status"
        }
    }
}

private struct RawHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data?
}

private struct RightClickListenerError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
