import Foundation

/// Genuine Kafka metadata/produce transport through an operator-selected,
/// integrity-bound SASL client. Topic capabilities are dynamically acquired from
/// the broker under its actual scoped principal, never a static topic catalog.
public final class KafkaCapabilityArtifactResolver: CapabilityArtifactResolver {
    public let kind = "kafka"
    private let client: URL?
    private let credentialReference: String?
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        client = environment["RIGHTCLICK_KAFKA_CLIENT"].map { URL(fileURLWithPath: $0) }
        credentialReference = environment["RIGHTCLICK_KAFKA_PUBLISHER_CONFIG"]
    }
    public func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector {
        guard descriptor.kind == kind, descriptor.inlineData == nil, descriptor.authorityScheme == nil,
              descriptor.specificationURL == nil, descriptor.baseURL == nil,
              let raw = descriptor.endpointURL, let endpoint = URL(string: raw),
              endpoint.scheme == "kafka", let host = endpoint.host, let port = endpoint.port,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/", let client, let credentialReference else {
            throw CapabilityArtifactResolutionError.invalidDescriptor("Kafka requires a safe broker endpoint and operator-selected client/credential reference.")
        }
        let credential = try CapabilityProtectedReference.read(credentialReference)
        guard let configuration = try JSONSerialization.jsonObject(with: credential) as? [String: Any],
              let rpk = configuration["rpk"] as? [String: Any], let api = rpk["kafka_api"] as? [String: Any],
              let brokers = api["brokers"] as? [String], brokers == [host + ":" + String(port)],
              let sasl = api["sasl"] as? [String: Any], let principal = sasl["user"] as? String,
              !principal.isEmpty, sasl["mechanism"] as? String == "SCRAM-SHA-256",
              sasl["password"] is String else { throw RCIRError.authorityDenied }
        let fingerprint = CapabilityJSON.digest(credential)
        let clientBytes = try Data(contentsOf: client)
        guard clientBytes.count <= 268_435_456 else { throw CapabilityABIError.limitExceeded }
        let clientDigest = CapabilityJSON.digest(clientBytes)
        func topics() throws -> [[String: Any]] {
            let data = try BoundedCapabilityProcess.run(executable: client,
                arguments: ["--config", credentialReference, "topic", "list", "--format", "json"])
            guard let topics = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], topics.count <= 256 else { throw CapabilityABIError.invalidWire }
            return topics.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        }
        let acquired = try topics()
        let declaration = try JSONSerialization.data(withJSONObject: acquired, options: [.sortedKeys])
        let argumentSchema = CapabilitySchema.object(properties: ["key": .string, "payload": .string], required: ["key", "payload"])
        let resultSchema = CapabilitySchema.object(properties: ["topic": .string, "partition": .integer,
            "offset": .integer, "key": .string, "value": .string], required: ["topic", "partition", "offset", "key", "value"])
        let operations = try acquired.map { topic -> CapabilityInterfaceOperation in
            guard let name = topic["name"] as? String, name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,248}$", options: .regularExpression) != nil,
                  (topic["partitions"] as? Int ?? 0) > 0 else { throw CapabilityABIError.invalidSchema }
            return .init(name: "publish." + name, title: "Publish UTF-8 record to " + name,
                arguments: argumentSchema, result: resultSchema,
                declaration: .object(["topicMetadata": try CapabilityJSON.value(topic), "recordValueEncoding": .string("UTF-8"),
                    "recordFraming": .string("one big-endian UInt32 length followed by exact UTF-8 bytes"),
                    "completionBoundary": .string("Kafka all-replicas acknowledgement; independent consumer verification remains required")]), effect: .publish)
        }
        func unchanged() -> Bool {
            guard let current = try? CapabilityProtectedReference.read(credentialReference),
                  CapabilityJSON.digest(current) == fingerprint,
                  let executable = try? Data(contentsOf: client), executable.count <= 268_435_456,
                  CapabilityJSON.digest(executable) == clientDigest,
                  let currentTopics = try? topics(),
                  let latest = try? JSONSerialization.data(withJSONObject: currentTopics, options: [.sortedKeys]) else { return false }
            return CapabilityJSON.digest(latest) == CapabilityJSON.digest(declaration)
        }
        return try CapabilityInterfaceReflector(id: "kafka:" + descriptor.id, provider: descriptor.id, target: endpoint,
            substrate: kind, descriptorDigest: CapabilityJSON.digest(declaration), operations: operations,
            provenance: ["credentialSourceType": "protected_file_reference", "credentialReference": credentialReference,
                         "providerPrincipal": principal, "authorityScheme": "SCRAM-SHA-256", "runtimeExecutable": client.path,
                         "runtimeSHA256": clientDigest, "verificationRequirement": "independent consumer of exact topic/partition/offset/key/payload"],
            available: unchanged, invoke: { name, input, admit in
                guard unchanged(), name.hasPrefix("publish."), case let .object(arguments) = input,
                      case let .string(key)? = arguments["key"], case let .string(payload)? = arguments["payload"],
                      !key.isEmpty, key.utf8.count <= 4096, payload.utf8.count <= 131_072 else { throw CapabilityABIError.invalidWire }
                let topic = String(name.dropFirst("publish.".count))
                let value = Data(payload.utf8); var length = UInt32(value.count).bigEndian
                var framed = withUnsafeBytes(of: &length) { Data($0) }; framed.append(value)
                let data = try withoutActuallyEscaping(admit) { gate in
                    try BoundedCapabilityProcess.run(executable: client,
                        arguments: ["--config", credentialReference, "topic", "produce", topic, "--key=" + key,
                                    "--format", "%V{big32}%v", "--output-format", "{\"topic\":\"%t\",\"partition\":%p,\"offset\":%o}\n",
                                    "--acks=-1", "--delivery-timeout=3s"], input: framed, admitStart: gate)
                }
                guard let ack = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      ack["topic"] as? String == topic, let partition = ack["partition"] as? Int,
                      let offset = ack["offset"] as? Int64, partition >= 0, offset >= 0 else { throw CapabilityABIError.invalidWire }
                return .object(["topic": .string(topic), "partition": .integer(Int64(partition)), "offset": .integer(offset),
                                "key": .string(key), "value": .string(payload)])
            })
    }
}
