import RightClickProtocol
import Foundation

/// Genuine Kafka metadata/produce transport through an operator-selected,
/// integrity-bound SASL client. Topic capabilities are dynamically acquired from
/// the broker under its actual scoped principal, never a static topic catalog.
public final class KafkaCapabilityArtifactResolver: CapabilityArtifactResolver {
    struct Diagnostic: Encodable {
        enum Stage: String, Codable {
            case credentialAcquisition, clientSnapshotAcquisition, metadataAcquisition
            case referenceRevalidation, declarationRevalidation, metadataProcess, produceProcess, observerProcess
            case controlMetadataProcess
        }
        let stage: Stage
        let elapsedMilliseconds: Double
        let succeeded: Bool
        let process: BoundedCapabilityProcess.Diagnostic?
        let recordedAtUptime = ProcessInfo.processInfo.systemUptime
    }
    public let kind = "kafka"
    private let client: URL?
    private let credentialReference: String?
    private let observerReference: String?
    private let diagnostic: ((Diagnostic) -> Void)?
    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(environment: environment, diagnostic: nil)
    }
    init(environment: [String: String], diagnostic: ((Diagnostic) -> Void)?) {
        client = environment["RIGHTCLICK_KAFKA_CLIENT"].map { URL(fileURLWithPath: $0) }
        credentialReference = environment["RIGHTCLICK_KAFKA_PUBLISHER_CONFIG"]
        observerReference = environment["RIGHTCLICK_KAFKA_OBSERVER_CONFIG"]
        self.diagnostic = diagnostic
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
        let report = diagnostic
        func measured<T>(_ stage: Diagnostic.Stage, _ body: () throws -> T) throws -> T {
            let began = ProcessInfo.processInfo.systemUptime
            var succeeded = false
            defer { report?(.init(stage: stage, elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000,
                succeeded: succeeded, process: nil)) }
            let value = try body(); succeeded = true; return value
        }
        func processReport(_ stage: Diagnostic.Stage) -> (BoundedCapabilityProcess.Diagnostic) -> Void {
            { value in report?(.init(stage: stage, elapsedMilliseconds: value.elapsedMilliseconds,
                succeeded: value.outcome == .completed, process: value)) }
        }
        let writer = try measured(.credentialAcquisition) {
            try KafkaCredential(reference: credentialReference, broker: host + ":" + String(port))
        }
        let credentialSnapshot = writer.snapshot
        let reader = try observerReference.map { try KafkaCredential(reference: $0, broker: host + ":" + String(port)) }
        guard reader == nil || (observerReference != credentialReference && reader?.principal != writer.principal) else { throw RCIRError.authorityDenied }
        let clientSnapshot = try measured(.clientSnapshotAcquisition) {
            try CapabilityExecutableSnapshotPool.shared.acquire(executable: client, maximum: 268_435_456)
        }
        let clientDigest = clientSnapshot.sha256
        func topics() throws -> [[String: Any]] {
            try measured(.metadataAcquisition) {
                let data = try BoundedCapabilityProcess.run(executable: clientSnapshot.file,
                    arguments: ["--config", credentialSnapshot.file.path, "topic", "list", "--format", "json"],
                    diagnostic: processReport(.metadataProcess))
                guard let topics = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], topics.count <= 256 else { throw CapabilityABIError.invalidWire }
                return topics.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            }
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
            let began = ProcessInfo.processInfo.systemUptime
            let matches = credentialSnapshot.sourceStillMatches() && FileManager.default.isExecutableFile(atPath: client.path) &&
                clientSnapshot.sourceStillMatches() &&
                (reader?.snapshot.sourceStillMatches() ?? true)
            report?(.init(stage: .referenceRevalidation,
                elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000, succeeded: matches, process: nil))
            guard matches,
                  let currentTopics = try? topics(),
                  let latest = try? JSONSerialization.data(withJSONObject: currentTopics, options: [.sortedKeys]) else { return false }
            let same = CapabilityJSON.digest(latest) == CapabilityJSON.digest(declaration)
            report?(.init(stage: .declarationRevalidation, elapsedMilliseconds: 0, succeeded: same, process: nil))
            return same
        }
        return try CapabilityInterfaceReflector(id: "kafka:" + descriptor.id, provider: descriptor.id, target: endpoint,
            substrate: kind, descriptorDigest: CapabilityJSON.digest(declaration), operations: operations,
            provenance: ["credentialSourceType": "protected_file_reference", "credentialReference": credentialReference,
                         "providerPrincipal": writer.principal, "observerPrincipal": reader?.principal ?? "not_configured",
                         "observerCredentialReference": observerReference ?? "not_configured",
                         "authorityScheme": "SCRAM-SHA-256", "runtimeExecutable": client.path,
                         "executionArtifactBinding": "host-private lifetime-managed read-only client and protected credential snapshots",
                         "runtimeSHA256": clientDigest, "verificationRequirement": "independent consumer of exact topic/partition/offset/key/payload and host-generated invocation header"],
            observerFactory: { name in
                guard let reader, name.hasPrefix("publish."),
                      let metadata = acquired.first(where: { "publish." + ($0["name"] as? String ?? "") == name }),
                      let partitions = metadata["partitions"] as? Int else { return nil }
                let topic = String(name.dropFirst("publish.".count))
                let observerID = "kafka:consume:" + endpoint.absoluteString + ":" + topic + ":" + reader.principal
                let observer = KafkaRecordObserver(observerID: observerID, client: clientSnapshot,
                    credential: reader, topic: topic, partitions: partitions, diagnostic: processReport(.observerProcess))
                return { input in
                    let desired = try KafkaRecord.arguments(input)
                    let fields: [String: [String]] = ["topic": ["topic"], "key": ["key"], "value": ["value"]]
                    let expected = CapabilityValue.object(["topic": .string(topic), "key": .string(desired.key), "value": .string(desired.payload)])
                    return .init(contract: .init(observerID: observerID,
                        schema: .object(properties: ["topic": .string, "key": .string, "value": .string], required: Array(fields.keys)),
                        expected: expected, projection: .init(schema: KafkaRecord.observationSchema, fields: fields),
                        invocationBindingPath: ["invocationID"]),
                        observer: observer,
                        boundary: "Independent exact topic/partition/offset consumer under a distinct host-selected SASL principal; expected topic/key/UTF-8 payload and host invocation marker bound before dispatch; full offset/partition/timestamp/marker retained.")
                }
            }, available: unchanged, boundInvoke: { name, input, binding, admit in
                guard unchanged(), name.hasPrefix("publish."), case let .object(arguments) = input,
                      case let .string(key)? = arguments["key"], case let .string(payload)? = arguments["payload"],
                      !key.isEmpty, key.utf8.count <= 4096, payload.utf8.count <= 131_072 else { throw CapabilityABIError.invalidWire }
                let topic = String(name.dropFirst("publish.".count))
                let value = Data(payload.utf8); var length = UInt32(value.count).bigEndian
                var framed = withUnsafeBytes(of: &length) { Data($0) }; framed.append(value)
                let data = try withoutActuallyEscaping(admit) { gate in
                    try BoundedCapabilityProcess.run(executable: clientSnapshot.file,
                        arguments: ["--config", credentialSnapshot.file.path, "topic", "produce", topic, "--key=" + key,
                                    "--header=rightclick.invocation:" + binding.id,
                                    "--format", "%V{big32}%v", "--output-format", "{\"topic\":\"%t\",\"partition\":%p,\"offset\":%o}\n",
                                    "--acks=-1", "--delivery-timeout=3s"], input: framed,
                        diagnostic: processReport(.produceProcess), admitStart: gate)
                }
                guard let ack = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      ack["topic"] as? String == topic, let partition = ack["partition"] as? Int,
                      let offset = ack["offset"] as? Int64, partition >= 0, offset >= 0 else { throw CapabilityABIError.invalidWire }
                return .object(["topic": .string(topic), "partition": .integer(Int64(partition)), "offset": .integer(offset),
                                "key": .string(key), "value": .string(payload)])
            }, invoke: { _, _, _ in throw RCIRError.invalidContract })
    }
}

private final class KafkaCredential {
    let snapshot: CapabilityArtifactSnapshot
    let principal: String
    init(reference: String, broker: String) throws {
        snapshot = try CapabilityArtifactSnapshot(source: URL(fileURLWithPath: reference), maximum: 65_536, protected: true)
        let bytes = try CapabilityProtectedReference.read(snapshot.file.path)
        guard let configuration = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let rpk = configuration["rpk"] as? [String: Any], let api = rpk["kafka_api"] as? [String: Any],
              let brokers = api["brokers"] as? [String], brokers == [broker],
              let sasl = api["sasl"] as? [String: Any], let principal = sasl["user"] as? String,
              !principal.isEmpty, principal.utf8.count <= 256, sasl["mechanism"] as? String == "SCRAM-SHA-256",
              sasl["password"] is String else { throw RCIRError.authorityDenied }
        self.principal = principal
    }
}

private enum KafkaRecord {
    static let observationSchema = CapabilitySchema.object(properties: ["topic": .string, "partition": .integer,
        "offset": .integer, "key": .string, "value": .string, "timestamp": .integer, "invocationID": .string],
        required: ["topic", "partition", "offset", "key", "value", "timestamp", "invocationID"])
    static func arguments(_ input: CapabilityValue) throws -> (key: String, payload: String) {
        guard case let .object(arguments) = input, Set(arguments.keys) == ["key", "payload"],
              case let .string(key)? = arguments["key"], case let .string(payload)? = arguments["payload"],
              !key.isEmpty, key.utf8.count <= 4096, payload.utf8.count <= 131_072 else { throw CapabilityABIError.invalidWire }
        return (key, payload)
    }
}

private final class KafkaRecordObserver: RCIRObserver {
    let observerID: String
    private let client: CapabilityArtifactSnapshot
    private let credential: KafkaCredential
    private let topic: String
    private let partitions: Int
    private let diagnostic: ((BoundedCapabilityProcess.Diagnostic) -> Void)?
    init(observerID: String, client: CapabilityArtifactSnapshot, credential: KafkaCredential, topic: String, partitions: Int,
         diagnostic: ((BoundedCapabilityProcess.Diagnostic) -> Void)? = nil) {
        self.observerID = observerID; self.client = client; self.credential = credential; self.topic = topic; self.partitions = partitions
        self.diagnostic = diagnostic
    }
    func observe(_ request: RCIRObservationRequest) throws -> CapabilityValue {
        guard credential.snapshot.sourceStillMatches(), client.sourceStillMatches(),
              case let .object(ack)? = request.providerResult, case let .string(ackTopic)? = ack["topic"], ackTopic == topic,
              case let .integer(partition)? = ack["partition"], partition >= 0, partition < Int64(partitions),
              case let .integer(offset)? = ack["offset"], offset >= 0 else { throw RCIRError.unverified }
        _ = try KafkaRecord.arguments(request.arguments)
        // ACK coordinates locate a single record only. They cannot widen the
        // trusted topic or replace the pre-bound expected key/payload/marker.
        let bytes = try BoundedCapabilityProcess.run(executable: client.file,
            arguments: ["--config", credential.snapshot.file.path, "topic", "consume", topic,
                        "-p", String(partition), "-o", String(offset), "-n", "1", "--format", "json", "--pretty-print=false"], timeout: 5,
            diagnostic: diagnostic)
        guard let observed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              observed["topic"] as? String == topic, observed["partition"] as? Int64 == partition,
              observed["offset"] as? Int64 == offset, let key = observed["key"] as? String,
              let value = observed["value"] as? String, let timestamp = observed["timestamp"] as? Int64,
              let headers = observed["headers"] as? [[String: Any]], headers.count <= 256 else { throw RCIRError.unverified }
        let markers = headers.filter { $0["key"] as? String == "rightclick.invocation" }
        guard markers.count == 1, let marker = markers[0]["value"] as? String, marker.utf8.count == 36,
              (try? RCIRInvocationBinding(taskID: marker)) != nil else { throw RCIRError.unverified }
        let result = CapabilityValue.object(["topic": .string(topic), "key": .string(key), "value": .string(value),
            "partition": .integer(partition), "offset": .integer(offset), "timestamp": .integer(timestamp), "invocationID": .string(marker)])
        try KafkaRecord.observationSchema.validate(result); return result
    }
}
