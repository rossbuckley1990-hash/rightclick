import RightClickProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A narrow A2A 0.2.6 text/JSON-RPC compiler. Skill descriptions inform discovery;
/// A2A has no standard method that directly invokes an individual skill.
public final class A2AReflector: RCIRExecutionReflector {
    public let id: String
    private let endpoint: URL
    private let capability: Capability
    private let standaloneHost = RCIRExecutionHost()

    public init(agentCard: Data, source: URL) throws {
        guard agentCard.count <= 1_048_576,
              let card = try JSONSerialization.jsonObject(with: agentCard) as? [String: Any],
              card["protocolVersion"] as? String == "0.2.6",
              let name = card["name"] as? String, !name.isEmpty,
              let rawEndpoint = card["url"] as? String, let endpoint = URL(string: rawEndpoint),
              let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              OriginPinnedHTTP.sameOrigin(source, endpoint),
              (card["defaultInputModes"] as? [String])?.contains("text/plain") == true,
              (card["defaultOutputModes"] as? [String])?.contains("text/plain") == true,
              let skills = card["skills"] as? [[String: Any]], !skills.isEmpty,
              skills.count <= 256,
              card["preferredTransport"] == nil || card["preferredTransport"] as? String == "JSONRPC",
              card["security"] == nil || (card["security"] as? [Any])?.isEmpty == true else { throw RCIRError.invalidContract }
        let schema: [String: Any] = ["type": "object", "additionalProperties": false,
            "required": ["message"], "properties": ["message": ["type": "string"]]]
        let normalized = try JSONSerialization.data(withJSONObject: card, options: [.sortedKeys])
        let digest = SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
        id = "a2a:" + SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        self.endpoint = endpoint
        capability = Capability(id: id + ":delegate", title: "Delegate a task to " + name,
            source: .system, reflectorID: id, provider: CapabilityProvider(name: name),
            inputs: ["public.plain-text"], output: ["public.plain-text"], safety: .externalShare,
            invocation: .direct, supportLevel: .publicSupported, requiresConfirmation: true,
            metadata: ["substrate": "a2a", "executionMode": "deferred", "protocolVersion": "0.2.6",
                "agentCardURL": source.absoluteString, "endpoint": endpoint.absoluteString,
                "descriptorSHA256": digest, "skills": try Self.json(skills),
                "description": card["description"] as? String ?? "",
                "requestJSONSchema": try Self.json(schema), "authority": "public endpoint; exact invocation lease"])
    }

    public func capabilities(for item: ContentItem) throws -> [Capability] {
        item.kind == "text" ? [capability] : []
    }
    public func providers() -> [ProviderSummary] {
        [ProviderSummary(name: capability.provider?.name ?? id, source: "a2a", capabilityTitles: [capability.title])]
    }
    public func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        try begin(capability: capability, item: item, executionID: executionID, arguments: nil)
    }
    public func begin(capability: Capability, item: ContentItem, executionID: String,
                      arguments: CapabilityArguments?) throws -> ExecutionRecord {
        try admittedBegin(capability: capability, admissionOwner: capability, item: item,
            executionID: executionID, arguments: arguments, verification: nil, expectedOutput: nil,
            host: standaloneHost, revalidate: { true })
    }

    public func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem,
                              executionID: String, arguments: CapabilityArguments?, verification: VerificationSpec?,
                              expectedOutput: String?, host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        guard capability.id == self.capability.id,
              let arguments, Set(arguments.keys) == ["message"], let message = arguments["message"],
              !message.isEmpty, message.utf8.count <= 65_536 else { throw RCIRError.invalidContract }
        let input = CapabilityValue.fromLegacyArguments(arguments)!
        let reflected = try admissionOwner.abiContract(arguments: .object(properties: ["message": .string], required: ["message"]), result: .string)
        let body: [String: Any] = ["message": ["kind": "message", "role": "user", "messageId": UUID().uuidString,
            "parts": [["kind": "text", "text": message]]], "configuration": ["blocking": false, "acceptedOutputModes": ["text/plain"]]]
        let encodedBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let invocation = CapabilityContract(capabilityID: reflected.capabilityID, reflectorID: reflected.reflectorID,
            providerID: reflected.providerID, arguments: reflected.arguments, result: reflected.result,
            declaration: .object(["capability": reflected.declaration, "requestBody": .bytes(encodedBody),
                "endpoint": .string(endpoint.absoluteString), "method": .string("message/send")]))
        let scope = RCIRScope(endpoint.absoluteString, .execute)
        var remoteTaskID: String?
        func decode(_ data: Data, expectedTask: String? = nil) throws -> RCIRTaskEvent {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["jsonrpc"] as? String == "2.0", root["error"] == nil,
                  let task = root["result"] as? [String: Any], task["kind"] as? String == "task",
                  let taskID = task["id"] as? String, !taskID.isEmpty, taskID.utf8.count <= 4096,
                  expectedTask == nil || taskID == expectedTask,
                  let status = task["status"] as? [String: Any], let state = status["state"] as? String else { throw RCIRError.invalidContract }
            remoteTaskID = taskID
            switch state {
            case "submitted": return .accepted
            case "working": return .working
            case "input-required": return .inputRequired
            case "failed", "rejected": return .failed
            case "canceled": return .cancelled
            case "completed":
                guard let artifacts = task["artifacts"] as? [[String: Any]], artifacts.count == 1,
                      let parts = artifacts[0]["parts"] as? [[String: Any]], parts.count == 1,
                      parts[0]["kind"] as? String == "text", let text = parts[0]["text"] as? String else { throw RCIRError.invalidContract }
                return .completed(.string(text))
            default: throw RCIRError.unsupportedTaskShape
            }
        }
        let lifecycle = RCIRDeferredLifecycle(initial: { record in
            guard let output = record.output else { throw RCIRError.invalidContract }
            return try decode(Data(output.utf8))
        }, poll: {
            guard let taskID = remoteTaskID else { throw RCIRError.invalidContract }
            let response = try self.rpc(method: "tasks/get", params: ["id": taskID])
            return try decode(response, expectedTask: taskID)
        })
        return try host.execute(abi: invocation, discovery: reflected, arguments: input, scope: scope,
            capability: admissionOwner, executionID: executionID, argumentStrings: arguments,
            item: item, verification: verification, expectedOutput: expectedOutput, target: endpoint,
            authority: { [scope] }, revalidate: revalidate, lifecycle: lifecycle,
            dispatch: { taskID, admit in
                let response = try withoutActuallyEscaping(admit) { start in
                    try self.rpc(method: "message/send", params: body, correlation: taskID, admit: start)
                }
                return ExecutionRecord(executionId: executionID, actionId: capability.id, state: .started,
                    message: "Remote agent returned a task; acceptance is not verification.", output: String(data: response, encoding: .utf8))
            }, resultValue: { .string($0.output ?? "") })
    }

    private func rpc(method: String, params: [String: Any], correlation: String? = nil,
                     admit: ((_ enqueue: () -> Void) throws -> Void)? = nil) throws -> Data {
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        let requestID = UUID().uuidString
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID,
            "method": method, "params": params], options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let correlation { request.setValue(correlation, forHTTPHeaderField: "X-RightClick-Invocation") }
        let data: Data
        if let admit { data = try OriginPinnedHTTP.loadInvocation(request, maximumBytes: 131_072, credentialIsolated: true, admitStart: admit) }
        else { data = try OriginPinnedHTTP.loadObservation(request, maximumBytes: 131_072) }
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["id"] as? String == requestID else { throw RCIRError.invalidContract }
        return data
    }

    private static func json(_ value: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }
}

/// Configuration grants acquisition of specific cards, never arbitrary tool-input
/// URLs. Every snapshot reacquires the card; offline/malformed providers disappear.
public final class ConfiguredA2ASource: CapabilityReflectorSource {
    public let id = "configured.a2a"
    private let file: URL
    public init(configurationFile: URL) { file = configurationFile }
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ConfiguredA2ASource? {
        environment["RIGHTCLICK_A2A_PROVIDERS"].map { .init(configurationFile: URL(fileURLWithPath: $0)) }
    }
    public func reflectors() -> [any CapabilityReflector] {
        guard let data = try? RCIRHostConfiguration.protectedRead(file.path, maximum: 65_536),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "agentCards"], object["version"] as? Int == 1,
              let cards = object["agentCards"] as? [String], cards.count <= 64,
              Set(cards).count == cards.count else { return [] }
        var result: [any CapabilityReflector] = []
        for raw in cards {
            guard let url = URL(string: raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(parts.host ?? "")),
                  let data = try? OriginPinnedHTTP.loadPublicDocument(url), let reflector = try? A2AReflector(agentCard: data, source: url) else { continue }
            result.append(reflector)
        }
        let counts = Dictionary(grouping: result, by: { $0.id }).mapValues { $0.count }
        return result.filter { counts[$0.id] == 1 }
    }
}
