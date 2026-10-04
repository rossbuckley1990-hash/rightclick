import CryptoKit
import Darwin
import Foundation
import MCP
import RightClickCore

public enum RightClickMCPMain {
    public static func run(_ args: [String]) -> Int {
        let http = args.contains("--http")
        let port = UInt16(flag(args, "--port") ?? "") ?? 8765
        let token = flag(args, "--token") ?? ProcessInfo.processInfo.environment["RIGHTCLICK_MCP_TOKEN"]
        StartupLog.record(transport: http ? "http" : "stdio")
        let box = EngineBox(CapabilityEngine())
        if http {
            guard let token, !token.isEmpty else {
                fputs("HTTP MCP requires --token or RIGHTCLICK_MCP_TOKEN.\n", stderr)
                return 2
            }
            HTTPMCPServer(engine: box, port: port, token: token).run()
            return 0
        }
        StdioMCPServer(engine: box).run()
        return 0
    }

    private static func flag(_ args: [String], _ name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

enum StartupLog {
    static func record(transport: String) {
        let path = executablePath()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) pid=\(getpid()) transport=\(transport) path=\(path) sha256=\(sha256File(path))\n"
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RIGHTCLICK", isDirectory: true)
        let file = directory.appendingPathComponent("startup.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: file.path), let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
    }

    private static func executablePath() -> String {
        let raw = CommandLine.arguments[0]
        if raw.hasPrefix("/") { return raw }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(raw).standardizedFileURL.path
    }

    private static func sha256File(_ path: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "unreadable" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

final class MainResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> T {
        semaphore.wait()
        lock.lock()
        let result = self.result
        lock.unlock()
        guard let result else {
            throw RightClickError("Main-thread capability call produced no result.")
        }
        return try result.get()
    }
}

final class StopFlag: @unchecked Sendable {
    var stop = false
}

final class EngineBox: @unchecked Sendable {
    let engine: CapabilityEngine
    init(_ engine: CapabilityEngine) { self.engine = engine }

    func call<T>(_ body: @escaping (CapabilityEngine) throws -> T) throws -> T {
        // ShareKit creates NSWindows during perform(withItems:). DispatchQueue.main.sync
        // can run that block inline on the MCP worker, which AppKit then aborts.
        if pthread_main_np() != 0 {
            return try body(engine)
        }
        let box = MainResultBox<T>()
        let engine = self.engine
        DispatchQueue.main.async {
            box.finish(Result { try body(engine) })
        }
        return try box.wait()
    }
}

final class StdioMCPServer {
    let engine: EngineBox
    init(engine: EngineBox) { self.engine = engine }

    func run() {
        let engine = self.engine
        let stop = StopFlag()
        Task.detached {
            do {
                try await Self.serve(engine)
            } catch {
                fputs("MCP server failed: \(error)\n", stderr)
            }
            stop.stop = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
        while !stop.stop {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
    }

    private static func serve(_ engine: EngineBox) async throws {
        let server = Server(
            name: "rightclick",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await registerTools(on: server, engine: engine)
        let transport = StdioTransport()
        try await server.start(transport: transport)
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
    }
}

final class HTTPMCPServer {
    let engine: EngineBox
    let port: UInt16
    let token: String

    init(engine: EngineBox, port: UInt16, token: String) {
        self.engine = engine
        self.port = port
        self.token = token
    }

    func run() {
        let engine = self.engine
        let port = self.port
        let token = self.token
        let ready = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await Self.serve(engine: engine, port: port, token: token, ready: ready)
            } catch {
                fputs("HTTP MCP failed: \(error)\n", stderr)
                ready.signal()
            }
        }
        RunLoop.main.run()
    }

    private static func serve(engine: EngineBox, port: UInt16, token: String, ready: DispatchSemaphore) async throws {
        let dispatcher = HTTPRequestDispatcher(engine: engine, token: token, port: port)
        let listener = MCPHTTPListener(port: port, path: "/mcp") { request in
            await dispatcher.handle(request)
        }
        try listener.start()
        fputs("RIGHTCLICK HTTP MCP listening on http://127.0.0.1:\(port)/mcp\n", stderr)
        ready.signal()
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
    }
}

/// Stateless Streamable HTTP. Each request gets a new MCP server and transport.
/// The shared engine keeps execution records across those requests.
private actor HTTPRequestDispatcher {
    private let engine: EngineBox
    private let token: String
    private let resource: URL

    init(engine: EngineBox, token: String, port: UInt16) {
        self.engine = engine
        self.token = token
        self.resource = URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let transport = StatelessHTTPServerTransport(validationPipeline: makePipeline())
        let server = Server(
            name: "rightclick",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await registerTools(on: server, engine: engine)
        do {
            try await server.start(transport: transport)
        } catch {
            return .error(
                statusCode: 500,
                .internalError("Failed to start MCP request: \(error.localizedDescription)")
            )
        }
        let response = await transport.handleRequest(request)
        await server.stop()
        return response
    }

    private func makePipeline() -> StandardValidationPipeline {
        let bearer = BearerTokenValidator(
            resourceMetadataURL: resource,
            resourceIdentifier: resource,
            tokenValidator: { [token] presented, _, _ in
                if presented == token {
                    return .valid(BearerTokenInfo())
                }
                return .invalidToken(errorDescription: "Bearer token was not accepted.")
            }
        )
        return StandardValidationPipeline(validators: [
            bearer,
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
    }
}

private func registerTools(on server: Server, engine: EngineBox) async {
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: rightClickTools())
    }
    await server.withMethodHandler(CallTool.self) { params in
        do {
            let text = try handleTool(params.name, arguments: params.arguments, engine: engine)
            return .init(content: [.text(text)], isError: false)
        } catch {
            return .init(content: [.text(String(describing: error))], isError: true)
        }
    }
}

private func schemaString(_ description: String) -> Value {
    .object([
        "type": .string("string"),
        "description": .string(description),
    ])
}

private func rightClickTools() -> [Tool] {
    let itemSchema: [String: Value] = [
        "type": .string("object"),
        "properties": .object([
            "item": schemaString("File path, http(s) URL, or plain text."),
        ]),
        "required": .array([.string("item")]),
    ]
    let explainSchema: [String: Value] = [
        "type": .string("object"),
        "properties": .object([
            "item": schemaString("File path, http(s) URL, or plain text."),
            "actionId": schemaString("Capability id or exact title returned by context_actions."),
        ]),
        "required": .array([.string("item"), .string("actionId")]),
    ]
    let runSchema: [String: Value] = [
        "type": .string("object"),
        "properties": .object([
            "item": schemaString("File path, http(s) URL, or plain text."),
            "actionId": schemaString("Capability id or exact title returned by context_actions."),
            "confirmed": .object([
                "type": .string("boolean"),
                "description": .string("Set true only after the user confirms an action that returns CONFIRMATION_REQUIRED."),
            ]),
        ]),
        "required": .array([.string("item"), .string("actionId")]),
    ]
    return [
        Tool(
            name: "context_inspect",
            description: "Classify an object the way RIGHTCLICK sees it: kind, UTI, size, and basic metadata.",
            inputSchema: .object(itemSchema)
        ),
        Tool(
            name: "context_actions",
            description: "Ask macOS which contextual capabilities apply to this object right now. Returns only applicable sharing services, Services, and Finder Action extensions.",
            inputSchema: .object(itemSchema)
        ),
        Tool(
            name: "context_explain",
            description: "Explain one contextual capability: provider, compatibility, side effects, confirmation, and support level.",
            inputSchema: .object(explainSchema)
        ),
        Tool(
            name: "context_run",
            description: "Invoke one capability discovered for this object. Sharing actions return immediately with executionId and state started. Services return the NSPerformService result in that same response. External, destructive, and unknown actions stay awaiting_user unless confirmed is true.",
            inputSchema: .object(runSchema)
        ),
        Tool(
            name: "context_run_status",
            description: "Read a context_run execution. States: started, awaiting_user, succeeded, failed, cancelled, unknown.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "executionId": schemaString("executionId returned by context_run."),
                ]),
                "required": .array([.string("executionId")]),
            ])
        ),
        Tool(
            name: "context_providers",
            description: "List the capability providers currently installed on this Mac.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
    ]
}

private func handleTool(_ name: String, arguments: [String: Value]?, engine: EngineBox) throws -> String {
    let item = arguments?["item"]?.stringValue ?? ""
    switch name {
    case "context_inspect":
        let inspected = try engine.call { try $0.inspect(item) }
        return RightClickJSON.encode(inspected)
    case "context_actions":
        let result = try engine.call { try $0.capabilities(for: item) }
        let payload = ContextActionsPayload(
            item: result.item.display,
            kind: result.item.kind,
            contentType: result.item.typeIdentifier ?? "",
            actions: result.capabilities.map(CapabilityView.init)
        )
        return RightClickJSON.encode(payload)
    case "context_providers":
        let rows = try engine.call { $0.providers() }
        return RightClickJSON.encode(rows)
    case "context_explain":
        let action = arguments?["actionId"]?.stringValue ?? ""
        let capability = try engine.call { try $0.describe(id: action, item: item) }
        return RightClickJSON.encode(capability)
    case "context_run":
        let action = arguments?["actionId"]?.stringValue ?? ""
        let confirmed = arguments?["confirmed"]?.boolValue ?? false
        let record = try engine.call { try $0.begin(id: action, item: item, confirmed: confirmed) }
        return RightClickJSON.encode(record)
    case "context_run_status":
        let executionId = arguments?["executionId"]?.stringValue ?? ""
        let record = try engine.call { $0.executionStatus(executionId) }
        return RightClickJSON.encode(record)
    default:
        throw RightClickError("Unknown tool \(name).")
    }
}

private struct ContextActionsPayload: Codable {
    var item: String
    var kind: String
    var contentType: String
    var actions: [CapabilityView]
}

private extension Value {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
