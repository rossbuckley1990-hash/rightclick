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
        let box = EngineBox(
            CapabilityRuntimeDefaults.makeEngine()
        )
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
        let runtime = RightClickRuntime.identity(transport: transport)
        let stamp = ISO8601DateFormatter().string(from: Date())

        let line = """
        \(stamp) pid=\(runtime.pid) transport=\(runtime.transport) version=\(runtime.version) path=\(runtime.executablePath) realpath=\(runtime.executableRealPath) sha256=\(runtime.executableSHA256)
        """

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Logs/RIGHTCLICK",
                isDirectory: true
            )

        let file = directory.appendingPathComponent("startup.log")

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        guard let data = (line + "\n").data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: file.path),
           let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
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
            version: RightClickVersion.current,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await registerTools(
            on: server,
            engine: engine,
            transport: "stdio"
        )
        let transport = ModernMCPStdioTransport()
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
            version: RightClickVersion.current,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await registerTools(on: server, engine: engine, transport: "http")
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

private func registerTools(
    on server: Server,
    engine: EngineBox,
    transport: String
) async {
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: rightClickTools())
    }
    await server.withMethodHandler(CallTool.self) { params in
        do {
            let text = try handleTool(
                params.name,
                arguments: params.arguments,
                engine: engine,
                transport: transport
            )
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
    let verificationPredicateSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "type": .object([
                "type": .string("string"),
                "description": .string("Provider-independent observable predicate type."),
                "enum": .array([
                    .string("text_equals"),
                    .string("file_exists"),
                    .string("file_readable"),
                    .string("file_sha256_equals"),
                    .string("file_sha256_differs"),
                    .string("file_size_less_than"),
                    .string("dimensions_equal"),
                    .string("xattr_present"),
                    .string("xattr_absent"),
                    .string("metadata_value_present"),
                    .string("metadata_value_absent"),
                ]),
            ]),
            "key": schemaString("Optional key, for example an extended-attribute name."),
            "value": schemaString("Optional expected or forbidden exact value."),
            "reference": schemaString("Optional observation reference. Currently 'before' for before/after predicates."),
            "width": .object([
                "type": .string("integer"),
                "description": .string("Optional expected image width."),
            ]),
            "height": .object([
                "type": .string("integer"),
                "description": .string("Optional expected image height."),
            ]),
            "bytes": .object([
                "type": .string("integer"),
                "description": .string("Optional byte threshold."),
            ]),
        ]),
        "required": .array([.string("type")]),
    ])

    let verificationSchema: Value = .object([
        "type": .string("object"),
        "description": .string("Optional caller-declared semantic postconditions. RIGHTCLICK evaluates them against observable state after invocation; provider acceptance alone is not success."),
        "properties": .object([
            "predicates": .object([
                "type": .string("array"),
                "description": .string("Required provider-independent postconditions."),
                "items": verificationPredicateSchema,
            ]),
            "timeoutMilliseconds": .object([
                "type": .string("integer"),
                "description": .string("Optional bounded wait for observable consequences. RIGHTCLICK caps this at 60000 ms."),
            ]),
        ]),
        "required": .array([.string("predicates")]),
    ])

    let capabilityArgumentsSchema:
        Value = .object([
            "type": .string("object"),
            "description":
                .string(
                    "Optional provider-independent structured capability arguments. Values are strings in the current schema slice."
                ),
            "additionalProperties":
                .object([
                    "type":
                        .string("string")
                ]),
        ])

    let runSchema: [String: Value] = [
        "type": .string("object"),
        "properties": .object([
            "item": schemaString("File path, http(s) URL, or plain text."),
            "actionId": schemaString("Capability id or exact title returned by context_actions."),
            "arguments": capabilityArgumentsSchema,
            "expectedOutput": schemaString("Legacy exact provider-returned-text postcondition. Prefer verification for generic semantic outcomes."),
            "verification": verificationSchema,
            "confirmed": .object([
                "type": .string("boolean"),
                "description": .string("Set true only after the user confirms an action that returns CONFIRMATION_REQUIRED."),
            ]),
        ]),
        "required": .array([.string("item"), .string("actionId")]),
    ]
    return [
        Tool(
            name: "context_runtime",
            description: "Report the exact RIGHTCLICK process serving this MCP connection: product version, invoked and resolved executable paths, executable SHA-256, PID, and transport.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "context_inspect",
            description: "Classify an object the way RIGHTCLICK sees it: kind, UTI, size, and basic metadata.",
            inputSchema: .object(itemSchema)
        ),
        Tool(
            name: "context_actions",
            description: "Ask RIGHTCLICK which discovered contextual capabilities apply to this object right now. Returns applicable capabilities reflected from the current environment.",
            inputSchema: .object(itemSchema)
        ),
        Tool(
            name: "context_explain",
            description: "Explain one contextual capability: provider, compatibility, side effects, confirmation, and support level.",
            inputSchema: .object(explainSchema)
        ),
        Tool(
            name: "context_run",
            description: "Invoke one capability discovered for this object. Provider acceptance is not semantic success. Callers may supply structured provider-independent verification predicates; verified postconditions establish succeeded or failed semantic outcome. Without verification, accepted remains explicitly unverified. External, destructive, and unknown actions stay awaiting_user unless confirmed is true.",
            inputSchema: .object(runSchema)
        ),
        Tool(
            name: "context_run_status",
            description: "Read a context_run execution. States: started, awaiting_user, unsupported, unavailable, rejected, accepted, succeeded, failed, cancelled, unknown. Provider acceptance or a sharing completion callback does not independently verify an external outcome.",
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
            description: "List capability providers currently reflected by RIGHTCLICK from this environment.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
    ]
}

private func handleTool(
    _ name: String,
    arguments: [String: Value]?,
    engine: EngineBox,
    transport: String
) throws -> String {
    let item = arguments?["item"]?.stringValue ?? ""
    switch name {
    case "context_runtime":
        return RightClickJSON.encode(
            RightClickRuntime.identity(transport: transport)
        )
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
        let confirmed =
            arguments?["confirmed"]?
                .boolValue ?? false

        let expectedOutput =
            arguments?["expectedOutput"]?
                .stringValue

        let capabilityArguments:
            CapabilityArguments?

        if let value =
            arguments?["arguments"]
        {
            guard
                let decoded =
                    value.stringMapValue
            else {
                throw RightClickError(
                    "context_run arguments must be an object whose values are strings."
                )
            }

            capabilityArguments =
                decoded
        } else {
            capabilityArguments =
                nil
        }

        let verification: VerificationSpec?

        if let value = arguments?["verification"] {
            do {
                let data = try JSONEncoder().encode(value)
                verification = try JSONDecoder().decode(
                    VerificationSpec.self,
                    from: data
                )
            } catch {
                throw RightClickError(
                    "Invalid verification VerificationSpec: \(error)"
                )
            }
        } else {
            verification = nil
        }

        let record = try engine.call {
            try $0.begin(
                id: action,
                item: item,
                confirmed: confirmed,
                arguments: capabilityArguments,
                expectedOutput: expectedOutput,
                verification: verification
            )
        }

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
        if case .bool(let value) = self {
            return value
        }

        return nil
    }

    var stringMapValue:
        [String: String]?
    {
        guard
            case .object(let object) =
                self
        else {
            return nil
        }

        var result:
            [String: String] = [:]

        for (key, value)
            in object
        {
            guard
                case .string(let string) =
                    value
            else {
                return nil
            }

            result[key] =
                string
        }

        return result
    }
}

public enum RightClickMCPContract {
    public static let schemaVersion = 1

    public static func toolSchemaSHA256() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(rightClickTools()) else {
            return ""
        }

        let digest = SHA256.hash(data: data)

        return digest
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func toolNames() -> [String] {
        rightClickTools()
            .map(\.name)
            .sorted()
    }
}
