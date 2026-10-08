import Foundation

/// Bounded signed-v1 claim extraction. This authenticates an issuer assertion
/// when used after signature verification; it is not external truth, a trusted
/// timestamp, authority-ledger consumption or grant-ancestry verification.
public struct RCIRReceiptClaims: Sendable {
    public let taskID: UUID
    public let leaseID: UUID
    public let startedAt: Int64
    public let deadline: Int64
    public let finishedAt: Int64
    public let lastObservationTime: Int64
    public let phase: RCIRTaskPhase
    public let outcome: RCIRSemanticOutcome
    public let providerGeneration: Int64
    public let hasAuthorityAncestry: Bool

    public static func read(_ payload: Data) throws -> Self {
        do { return try extract(payload) }
        catch { throw RCIRReceiptTrustError.malformedReceipt }
    }
    private static func extract(_ payload: Data) throws -> Self {
        var reader = RCIRCanonicalReceiptReader()
        let receipt = try reader.domain(payload, "RECEIPT", maximum: 1_048_576)
        try reader.fields(receipt, ["taskID", "leaseID", "request", "startedAt", "deadline", "finishedAt", "lastObservationTime",
            "phase", "semanticOutcome", "events", "lastSequence", "cancellationRequestedAt", "observation", "observedAt"])
        let task = try reader.identifier(receipt["taskID"]), lease = try reader.identifier(receipt["leaseID"])
        let start = try reader.integer(receipt["startedAt"]), deadline = try reader.integer(receipt["deadline"])
        let finish = try reader.integer(receipt["finishedAt"]), last = try reader.integer(receipt["lastObservationTime"])
        guard start >= 0, deadline > start, deadline - start <= 86_400_000, finish >= start, last >= finish,
              let phase = RCIRTaskPhase(rawValue: try reader.string(receipt["phase"])),
              [.completed, .failed, .cancelled, .unknown].contains(phase),
              let outcome = RCIRSemanticOutcome(rawValue: try reader.string(receipt["semanticOutcome"])) else { throw RCIRReceiptTrustError.malformedReceipt }
        func optionalTime(_ value: CapabilityValue?) throws -> Int64? {
            if case .null? = value { return nil }
            let time = try reader.integer(value)
            guard start <= time, time <= last else { throw RCIRReceiptTrustError.malformedReceipt }
            return time
        }
        _ = try optionalTime(receipt["cancellationRequestedAt"])
        let observed = try optionalTime(receipt["observedAt"])
        let observation: Data?
        if case .null? = receipt["observation"] { observation = nil }
        else { observation = try reader.bytes(receipt["observation"], maximum: 131_072); _ = try reader.value(observation!) }
        guard (observation == nil) == (observed == nil),
              observed.map({ $0 >= finish && $0 < deadline }) ?? true,
              ![.succeeded, .failed].contains(outcome) || (phase == .completed && observation != nil),
              outcome != .unknown || phase == .unknown else { throw RCIRReceiptTrustError.malformedReceipt }
        let events = try reader.array(receipt["events"])
        guard events.count <= 1024, try reader.integer(receipt["lastSequence"]) == Int64(events.count) else { throw RCIRReceiptTrustError.malformedReceipt }
        var previousTime = start, eventBytes = 0, noOutput = false
        for (index, encoded) in events.enumerated() {
            let data = try reader.bytes(encoded, maximum: 262_144)
            guard data.count <= 262_144 - eventBytes else { throw RCIRReceiptTrustError.malformedReceipt }; eventBytes += data.count
            let event = try reader.object(reader.value(data))
            try reader.fields(event, ["sequence", "time", "kind", "value"])
            let time = try reader.integer(event["time"]), kind = try reader.string(event["kind"])
            guard try reader.integer(event["sequence"]) == Int64(index + 1), previousTime <= time, time <= last,
                  ["accepted", "working", "inputRequired", "chunk", "completed", "completedWithoutOutput", "failed", "cancelled"].contains(kind) else { throw RCIRReceiptTrustError.malformedReceipt }
            previousTime = time
            if kind == "completedWithoutOutput" {
                guard case .null? = event["value"], index == events.count - 1, phase == .completed else { throw RCIRReceiptTrustError.malformedReceipt }
                noOutput = true
            }
        }
        let request = try reader.domain(reader.bytes(receipt["request"], maximum: 131_072), "REQUEST", maximum: 131_072)
        let expected = Set(["binding", "arguments", "scopes", "policy", "issuedAt", "expiresAt"])
        guard Set(request.keys) == expected || Set(request.keys) == expected.union(["authority"]) else { throw RCIRReceiptTrustError.malformedReceipt }
        let issued = try reader.integer(request["issuedAt"]), expires = try reader.integer(request["expiresAt"])
        guard issued >= 0, issued <= start, start < expires, expires - issued <= 60_000 else { throw RCIRReceiptTrustError.malformedReceipt }
        _ = try reader.value(reader.bytes(request["arguments"], maximum: 131_072))
        let binding = try reader.domain(reader.bytes(request["binding"], maximum: 140_000), "BINDING", maximum: 140_000)
        let bindingFields = Set(["contract", "principal", "generation"])
        guard Set(binding.keys) == bindingFields || Set(binding.keys) == bindingFields.union(["discovery"]) else { throw RCIRReceiptTrustError.malformedReceipt }
        let principal = try reader.identity(binding["principal"]), generation = try reader.integer(binding["generation"])
        guard generation >= 1 else { throw RCIRReceiptTrustError.malformedReceipt }
        let scopes = try reader.scopes(request["scopes"])
        let policy = try reader.domain(reader.bytes(request["policy"], maximum: 32_768), "POLICY", maximum: 32_768)
        try reader.fields(policy, ["revision", "principals", "scopes"]); _ = try reader.identity(policy["revision"])
        let principals = try reader.array(policy["principals"])
        guard principals.count <= 512 else { throw RCIRReceiptTrustError.malformedReceipt }
        let identities = try principals.map { try reader.identity($0) }
        guard Set(identities.map { Data($0.utf8) }).count == identities.count,
              identities.contains(where: { $0.utf8.elementsEqual(principal.utf8) }),
              scopes.isSubset(of: try reader.scopes(policy["scopes"])) else { throw RCIRReceiptTrustError.malformedReceipt }
        let contract = try reader.domain(reader.bytes(binding["contract"], maximum: 65_536), "CONTRACT", maximum: 65_536)
        try reader.fields(contract, ["abi", "effects", "task", "verification"])
        guard scopes == (try reader.scopes(contract["effects"])) else { throw RCIRReceiptTrustError.malformedReceipt }
        let abiBytes = try reader.bytes(contract["abi"], maximum: 65_536), abiPrefix = Data("RIGHTCLICK-CONTRACT-1\0".utf8)
        guard abiBytes.starts(with: abiPrefix) else { throw RCIRReceiptTrustError.malformedReceipt }
        let abi = try reader.object(reader.value(Data(abiBytes.dropFirst(abiPrefix.count))))
        try reader.fields(abi, ["version", "provider", "reflector", "capability", "arguments", "result", "declaration"])
        guard try reader.integer(abi["version"]) == 1 else { throw RCIRReceiptTrustError.malformedReceipt }
        for name in ["provider", "reflector", "capability"] { _ = try reader.identity(abi[name]) }
        if noOutput {
            guard case .string("unit:no-declared-output") = try reader.value(reader.bytes(abi["result"], maximum: 65_536)) else { throw RCIRReceiptTrustError.malformedReceipt }
        }
        // An ancestry presence flag is honest scope: independent authority
        // attenuation checks belong to the existing authority verifier/ledger.
        if let ancestry = request["authority"] {
            _ = try reader.domain(reader.bytes(ancestry, maximum: 1_048_576), "AUTHORITY", maximum: 1_048_576)
        }
        if let discovery = binding["discovery"] {
            let data = try reader.bytes(discovery, maximum: 65_536)
            if data.starts(with: Data("RIGHTCLICK-RCIR-GRAPH-DECLARATION-1\0".utf8)) {
                let graph = try reader.domain(data, "GRAPH-DECLARATION", maximum: 65_536)
                try reader.fields(graph, ["abi", "effects", "task"])
            } else { _ = try reader.domain(data, "CONTRACT", maximum: 65_536) }
        }
        return .init(taskID: task, leaseID: lease, startedAt: start, deadline: deadline, finishedAt: finish,
            lastObservationTime: last, phase: phase, outcome: outcome, providerGeneration: generation,
            hasAuthorityAncestry: request["authority"] != nil)
    }
}

/// Exact ABI framing only. Opaque bytes are decoded only for named v1 domains.
/// Per-value ABI ceilings plus aggregate parsing ceilings bound retained memory.
private struct RCIRCanonicalReceiptReader {
    private var bytesRemaining = 4_194_304
    private var nodesRemaining = 262_144
    mutating func value(_ data: Data) throws -> CapabilityValue {
        guard data.count <= bytesRemaining else { throw RCIRReceiptTrustError.malformedReceipt }; bytesRemaining -= data.count
        var parser = Parser(data: data)
        let result = try parser.read()
        guard parser.nodes <= nodesRemaining else { throw RCIRReceiptTrustError.malformedReceipt }; nodesRemaining -= parser.nodes
        return result
    }
    mutating func domain(_ data: Data, _ name: String, maximum: Int) throws -> [String: CapabilityValue] {
        let prefix = Data(("RIGHTCLICK-RCIR-" + name + "-1\0").utf8)
        guard data.count <= maximum, data.starts(with: prefix) else { throw RCIRReceiptTrustError.malformedReceipt }
        return try object(value(Data(data.dropFirst(prefix.count))))
    }
    func fields(_ object: [String: CapabilityValue], _ keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw RCIRReceiptTrustError.malformedReceipt }
    }
    func object(_ value: CapabilityValue) throws -> [String: CapabilityValue] {
        guard case let .object(fields) = value else { throw RCIRReceiptTrustError.malformedReceipt }; return fields
    }
    func string(_ value: CapabilityValue?) throws -> String {
        guard case let .string(text)? = value else { throw RCIRReceiptTrustError.malformedReceipt }; return text
    }
    func identity(_ value: CapabilityValue?) throws -> String {
        let text = try string(value)
        guard !text.isEmpty, text.utf8.count <= 4096, !text.contains("*"), text.rangeOfCharacter(from: .controlCharacters) == nil else { throw RCIRReceiptTrustError.malformedReceipt }
        return text
    }
    func identifier(_ value: CapabilityValue?) throws -> UUID {
        let text = try string(value)
        guard let id = UUID(uuidString: text), id.uuidString.utf8.elementsEqual(text.utf8) else { throw RCIRReceiptTrustError.malformedReceipt }; return id
    }
    func integer(_ value: CapabilityValue?) throws -> Int64 {
        guard case let .integer(number)? = value else { throw RCIRReceiptTrustError.malformedReceipt }; return number
    }
    func bytes(_ value: CapabilityValue?, maximum: Int) throws -> Data {
        guard case let .bytes(data)? = value, data.count <= maximum else { throw RCIRReceiptTrustError.malformedReceipt }; return data
    }
    func array(_ value: CapabilityValue?) throws -> [CapabilityValue] {
        guard case let .array(values)? = value else { throw RCIRReceiptTrustError.malformedReceipt }; return values
    }
    func scopes(_ value: CapabilityValue?) throws -> Set<RCIRScope> {
        let values = try array(value); guard values.count <= 512 else { throw RCIRReceiptTrustError.malformedReceipt }
        let scopes = try values.map { value -> RCIRScope in
            let fields = try object(value); try self.fields(fields, ["resource", "effect"])
            guard let effect = RCIREffect(rawValue: try string(fields["effect"])), effect != .unknown else { throw RCIRReceiptTrustError.malformedReceipt }
            return .init(try identity(fields["resource"]), effect)
        }
        guard Set(scopes).count == scopes.count else { throw RCIRReceiptTrustError.malformedReceipt }; return Set(scopes)
    }
    private struct Parser {
        let data: Data
        var position = 0
        var nodes = 0
        mutating func read() throws -> CapabilityValue {
            let prefix = Data("RIGHTCLICK-VALUE-1\0".utf8)
            guard data.count <= 1_048_576, data.starts(with: prefix) else { throw RCIRReceiptTrustError.malformedReceipt }
            position = prefix.count
            let value = try node(depth: 0)
            guard position == data.count, try value.canonicalData() == data else { throw RCIRReceiptTrustError.malformedReceipt }
            return value
        }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - position else { throw RCIRReceiptTrustError.malformedReceipt }
            let result = data.subdata(in: position..<(position + count)); position += count; return result
        }
        mutating func count() throws -> Int {
            var result = 0, digits = 0
            let start = position
            while position < data.count {
                let byte = data[position]; position += 1
                if byte == 58 {
                    guard digits > 0, digits == 1 || data[start] != 48 else { throw RCIRReceiptTrustError.malformedReceipt }; return result
                }
                guard digits < 8, byte >= 48, byte <= 57 else { throw RCIRReceiptTrustError.malformedReceipt }
                result = result * 10 + Int(byte - 48); digits += 1
                guard result <= 1_048_576 else { throw RCIRReceiptTrustError.malformedReceipt }
            }
            throw RCIRReceiptTrustError.malformedReceipt
        }
        mutating func node(depth: Int) throws -> CapabilityValue {
            guard depth <= 32, nodes < 4096 else { throw RCIRReceiptTrustError.malformedReceipt }; nodes += 1
            let tag = try take(1)[0]
            switch tag {
            case 110: return .null
            case 98:
                let byte = try take(1)[0]; guard byte == 48 || byte == 49 else { throw RCIRReceiptTrustError.malformedReceipt }; return .boolean(byte == 49)
            case 105, 115, 120:
                let size = try count(), raw = try take(size)
                if tag == 120 { return .bytes(raw) }
                guard let text = String(data: raw, encoding: .utf8) else { throw RCIRReceiptTrustError.malformedReceipt }
                if tag == 115 { return .string(text) }
                guard size <= 20, let integer = Int64(text), String(integer).utf8.elementsEqual(text.utf8) else { throw RCIRReceiptTrustError.malformedReceipt }; return .integer(integer)
            case 100:
                let bytes = try take(8); var bits: UInt64 = 0
                for byte in bytes { bits = (bits << 8) | UInt64(byte) }
                let number = Double(bitPattern: bits); guard number.isFinite else { throw RCIRReceiptTrustError.malformedReceipt }; return .number(number)
            case 97, 111:
                let size = try count(); guard size <= 4096 else { throw RCIRReceiptTrustError.malformedReceipt }
                if tag == 97 {
                    var values: [CapabilityValue] = []
                    for _ in 0..<size { values.append(try node(depth: depth + 1)) }; return .array(values)
                }
                var values: [String: CapabilityValue] = [:], previous: Data? = nil
                for _ in 0..<size {
                    guard case let .string(key) = try node(depth: depth + 1) else { throw RCIRReceiptTrustError.malformedReceipt }
                    let encoded = Data(key.utf8)
                    guard previous.map({ $0.lexicographicallyPrecedes(encoded) }) ?? true,
                          !values.keys.contains(key) else { throw RCIRReceiptTrustError.malformedReceipt }
                    previous = encoded; values[key] = try node(depth: depth + 1)
                }
                return .object(values)
            default: throw RCIRReceiptTrustError.malformedReceipt
            }
        }
    }
}
