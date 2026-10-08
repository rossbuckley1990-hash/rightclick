import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum EnvironmentError: String, Error, Codable, Sendable {
    case invalidIdentity, invalidLimits, invalidLineage, invalidObservation, invalidManifest, invalidState
    case unsupported, unavailable, idempotencyConflict, unsafeDuplicate, expired
}

/// Closed, conservative host ceilings. A lease/profile may only reduce them.
public enum EnvironmentLimits {
    public static let maximumDepth = 2
    public static let maximumLifetimeMilliseconds: Int64 = 3_600_000
    public static let maximumCPUCount = 4
    public static let maximumMemoryMiB = 4096
    public static let maximumCostUnits: Int64 = 1_000_000
    public static let maximumChallengeBytes = 256
}

public enum EnvironmentIdentity {
    /// Use the same canonical UUID spelling as existing execution identities.
    public static func isCanonicalID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString == value
    }
    public static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func isRuntimeID(_ value: String) -> Bool {
        value.hasPrefix("runtime:") && isDigest(String(value.dropFirst(8)))
    }
    public static func isName(_ value: String, maximumBytes: Int = 128) -> Bool {
        (1...maximumBytes).contains(value.utf8.count) && value != "." && value != ".." && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
    public static func isResourceID(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count) && value != "." && value != ".." && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }
    public static func uri(environmentID: String) throws -> String {
        guard isCanonicalID(environmentID) else { throw EnvironmentError.invalidIdentity }
        return "rcenv://" + environmentID
    }
    /// No URL normalisation: aliases, percent encoding and URI authority fields reject.
    public static func environmentID(from uri: String) throws -> String {
        guard uri.hasPrefix("rcenv://") else { throw EnvironmentError.invalidIdentity }
        let identifier = String(uri.dropFirst(8))
        guard isCanonicalID(identifier) else { throw EnvironmentError.invalidIdentity }
        return identifier
    }
    public static let factoryURI = "rcenv://fabric"
}

public enum EnvironmentState: String, Codable, Sendable {
    case creating, bootstrapping, ready, running, stopping, destroying, destroyed, failed, unknown

    /// Observation does not authorise a transition; the coordinator must also
    /// enforce admission, lineage, independent presence and teardown ordering.
    public func permitsTransition(to next: Self) -> Bool {
        if self == next { return true }
        switch self {
        case .creating: return [.bootstrapping, .failed, .unknown, .stopping, .destroying].contains(next)
        case .bootstrapping: return [.ready, .failed, .unknown, .stopping, .destroying].contains(next)
        case .ready: return [.running, .failed, .unknown, .stopping, .destroying].contains(next)
        case .running: return [.ready, .failed, .unknown, .stopping, .destroying].contains(next)
        case .stopping: return [.destroying, .failed, .unknown].contains(next)
        case .destroying: return [.destroyed, .failed, .unknown].contains(next)
        case .failed, .unknown: return [.stopping, .destroying, .bootstrapping, .ready, .failed, .unknown].contains(next)
        case .destroyed: return false
        }
    }
}

public struct EnvironmentResources: Codable, Sendable, Equatable {
    public let cpuCount: Int
    public let memoryMiB: Int
    public let maximumCostUnits: Int64
    public let costUnit: String
    public init(cpuCount: Int = 1, memoryMiB: Int = 512, maximumCostUnits: Int64 = 100_000, costUnit: String = "micro-usd") throws {
        guard (1...EnvironmentLimits.maximumCPUCount).contains(cpuCount),
              (128...EnvironmentLimits.maximumMemoryMiB).contains(memoryMiB),
              (1...EnvironmentLimits.maximumCostUnits).contains(maximumCostUnits), costUnit == "micro-usd" else {
            throw EnvironmentError.invalidLimits
        }
        self.cpuCount = cpuCount; self.memoryMiB = memoryMiB
        self.maximumCostUnits = maximumCostUnits; self.costUnit = costUnit
    }
    public func isWithin(_ ceiling: Self) -> Bool {
        costUnit == ceiling.costUnit && cpuCount <= ceiling.cpuCount && memoryMiB <= ceiling.memoryMiB && maximumCostUnits <= ceiling.maximumCostUnits
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case cpuCount, memoryMiB, maximumCostUnits, costUnit }
    public init(from decoder: Decoder) throws {
        try environmentDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(cpuCount: c.decode(Int.self, forKey: .cpuCount), memoryMiB: c.decode(Int.self, forKey: .memoryMiB),
                      maximumCostUnits: c.decode(Int64.self, forKey: .maximumCostUnits), costUnit: c.decode(String.self, forKey: .costUnit))
    }
}

public struct EnvironmentSpec: Codable, Sendable, Equatable {
    public let profileID: String
    public let lifetimeMilliseconds: Int64
    public let resources: EnvironmentResources
    public init(profileID: String, lifetimeMilliseconds: Int64 = 900_000, resources: EnvironmentResources) throws {
        guard EnvironmentIdentity.isName(profileID), (1...EnvironmentLimits.maximumLifetimeMilliseconds).contains(lifetimeMilliseconds) else {
            throw EnvironmentError.invalidLimits
        }
        self.profileID = profileID; self.lifetimeMilliseconds = lifetimeMilliseconds; self.resources = resources
    }
    public func isWithin(_ ceiling: Self) -> Bool {
        Data(profileID.utf8) == Data(ceiling.profileID.utf8) && lifetimeMilliseconds <= ceiling.lifetimeMilliseconds && resources.isWithin(ceiling.resources)
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case profileID, lifetimeMilliseconds, resources }
    public init(from decoder: Decoder) throws {
        try environmentDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(profileID: c.decode(String.self, forKey: .profileID), lifetimeMilliseconds: c.decode(Int64.self, forKey: .lifetimeMilliseconds),
                      resources: c.decode(EnvironmentResources.self, forKey: .resources))
    }
}

public struct EnvironmentLineage: Codable, Sendable, Equatable {
    public let rootEnvironmentID: String
    public let parentEnvironmentID: String?
    public let parentExecutionID: String
    public let parentRuntimeID: String
    public let depth: Int
    public init(rootEnvironmentID: String, parentEnvironmentID: String? = nil, parentExecutionID: String, parentRuntimeID: String, depth: Int) throws {
        guard EnvironmentIdentity.isCanonicalID(rootEnvironmentID), EnvironmentIdentity.isCanonicalID(parentExecutionID),
              EnvironmentIdentity.isRuntimeID(parentRuntimeID), parentEnvironmentID.map(EnvironmentIdentity.isCanonicalID) ?? true,
              (0...EnvironmentLimits.maximumDepth).contains(depth), (depth == 0) == (parentEnvironmentID == nil),
              depth != 1 || parentEnvironmentID == rootEnvironmentID else { throw EnvironmentError.invalidLineage }
        self.rootEnvironmentID = rootEnvironmentID; self.parentEnvironmentID = parentEnvironmentID
        self.parentExecutionID = parentExecutionID; self.parentRuntimeID = parentRuntimeID; self.depth = depth
    }
    public func validate(environmentID: String) throws {
        guard EnvironmentIdentity.isCanonicalID(environmentID), parentEnvironmentID != environmentID,
              (depth == 0) == (rootEnvironmentID == environmentID),
              depth < 2 || parentEnvironmentID != rootEnvironmentID else { throw EnvironmentError.invalidLineage }
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case rootEnvironmentID, parentEnvironmentID, parentExecutionID, parentRuntimeID, depth }
    public init(from decoder: Decoder) throws {
        try environmentDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(rootEnvironmentID: c.decode(String.self, forKey: .rootEnvironmentID), parentEnvironmentID: c.decodeIfPresent(String.self, forKey: .parentEnvironmentID),
                      parentExecutionID: c.decode(String.self, forKey: .parentExecutionID), parentRuntimeID: c.decode(String.self, forKey: .parentRuntimeID), depth: c.decode(Int.self, forKey: .depth))
    }
}

public struct EnvironmentCreateIntent: Codable, Sendable, Equatable {
    public let environmentID: String
    public let correlationID: String
    public let creationExecutionID: String
    public let spec: EnvironmentSpec
    public let lineage: EnvironmentLineage
    public let createdAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public init(environmentID: String, correlationID: String, creationExecutionID: String, spec: EnvironmentSpec,
                lineage: EnvironmentLineage, createdAtMilliseconds: Int64, expiresAtMilliseconds: Int64) throws {
        guard EnvironmentIdentity.isCanonicalID(environmentID), EnvironmentIdentity.isCanonicalID(correlationID),
              EnvironmentIdentity.isCanonicalID(creationExecutionID), createdAtMilliseconds > 0,
              expiresAtMilliseconds > createdAtMilliseconds,
              expiresAtMilliseconds - createdAtMilliseconds == spec.lifetimeMilliseconds else { throw EnvironmentError.invalidIdentity }
        try lineage.validate(environmentID: environmentID)
        self.environmentID = environmentID; self.correlationID = correlationID; self.creationExecutionID = creationExecutionID
        self.spec = spec; self.lineage = lineage; self.createdAtMilliseconds = createdAtMilliseconds; self.expiresAtMilliseconds = expiresAtMilliseconds
    }
    /// ABI canonicalisation, rather than JSON-in-string or a second normaliser.
    public func canonicalData() throws -> Data {
        try environmentCanonical(domain: "RIGHTCLICK-ENVIRONMENT-INTENT-1", value: .object([
            "environmentID": .string(environmentID), "correlationID": .string(correlationID),
            "creationExecutionID": .string(creationExecutionID), "spec": spec.canonicalValue,
            "lineage": lineage.canonicalValue, "createdAt": .integer(createdAtMilliseconds), "expiresAt": .integer(expiresAtMilliseconds)
        ]))
    }
    public func digest() throws -> String { SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined() }
    private enum CodingKeys: String, CodingKey, CaseIterable { case environmentID, correlationID, creationExecutionID, spec, lineage, createdAtMilliseconds, expiresAtMilliseconds }
    public init(from decoder: Decoder) throws {
        try environmentDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(environmentID: c.decode(String.self, forKey: .environmentID), correlationID: c.decode(String.self, forKey: .correlationID),
                      creationExecutionID: c.decode(String.self, forKey: .creationExecutionID), spec: c.decode(EnvironmentSpec.self, forKey: .spec),
                      lineage: c.decode(EnvironmentLineage.self, forKey: .lineage), createdAtMilliseconds: c.decode(Int64.self, forKey: .createdAtMilliseconds),
                      expiresAtMilliseconds: c.decode(Int64.self, forKey: .expiresAtMilliseconds))
    }
}

public struct EnvironmentHandle: Codable, Sendable, Equatable {
    public let environmentID: String
    public let providerID: String
    public let providerResourceID: String
    public let correlationID: String
    public let lineage: EnvironmentLineage
    public let spec: EnvironmentSpec
    public let createdAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public init(environmentID: String, providerID: String, providerResourceID: String, correlationID: String,
                lineage: EnvironmentLineage, spec: EnvironmentSpec, createdAtMilliseconds: Int64, expiresAtMilliseconds: Int64) throws {
        guard EnvironmentIdentity.isCanonicalID(environmentID), EnvironmentIdentity.isCanonicalID(correlationID),
              EnvironmentIdentity.isName(providerID), EnvironmentIdentity.isResourceID(providerResourceID),
              createdAtMilliseconds > 0, expiresAtMilliseconds > createdAtMilliseconds,
              expiresAtMilliseconds - createdAtMilliseconds == spec.lifetimeMilliseconds else { throw EnvironmentError.invalidIdentity }
        try lineage.validate(environmentID: environmentID)
        self.environmentID = environmentID; self.providerID = providerID; self.providerResourceID = providerResourceID; self.correlationID = correlationID
        self.lineage = lineage; self.spec = spec; self.createdAtMilliseconds = createdAtMilliseconds; self.expiresAtMilliseconds = expiresAtMilliseconds
    }
    public var uri: String { "rcenv://" + environmentID }
    private enum CodingKeys: String, CodingKey, CaseIterable { case environmentID, providerID, providerResourceID, correlationID, lineage, spec, createdAtMilliseconds, expiresAtMilliseconds }
    public init(from decoder: Decoder) throws {
        try environmentDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(environmentID: c.decode(String.self, forKey: .environmentID), providerID: c.decode(String.self, forKey: .providerID),
                      providerResourceID: c.decode(String.self, forKey: .providerResourceID), correlationID: c.decode(String.self, forKey: .correlationID),
                      lineage: c.decode(EnvironmentLineage.self, forKey: .lineage), spec: c.decode(EnvironmentSpec.self, forKey: .spec),
                      createdAtMilliseconds: c.decode(Int64.self, forKey: .createdAtMilliseconds), expiresAtMilliseconds: c.decode(Int64.self, forKey: .expiresAtMilliseconds))
    }
}

public struct EnvironmentRuntimeManifest: Codable, Sendable, Equatable {
    public let version: String
    public let executableSHA256: String
    public let operatingSystem: RuntimeOperatingSystem
    public let architecture: String
    public init(version: String, executableSHA256: String, operatingSystem: RuntimeOperatingSystem = .linux, architecture: String) throws {
        guard EnvironmentIdentity.isName(version, maximumBytes: 64), EnvironmentIdentity.isDigest(executableSHA256), operatingSystem == .linux,
              ["x86_64", "arm64"].contains(architecture) else { throw EnvironmentError.invalidManifest }
        self.version = version; self.executableSHA256 = executableSHA256; self.operatingSystem = operatingSystem; self.architecture = architecture
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, executableSHA256, operatingSystem, architecture }
    public init(from decoder: Decoder) throws {
        try environmentDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: c.decode(String.self, forKey: .version), executableSHA256: c.decode(String.self, forKey: .executableSHA256),
                      operatingSystem: c.decode(RuntimeOperatingSystem.self, forKey: .operatingSystem), architecture: c.decode(String.self, forKey: .architecture))
    }
}

public struct EnvironmentRuntimeObservation: Codable, Sendable, Equatable {
    public let manifest: EnvironmentRuntimeManifest
    public let publicKey: Data
    public let observedAtMilliseconds: Int64
    public let observationBoundary: String
    public var runtimeID: String { "runtime:" + SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined() }
    public init(manifest: EnvironmentRuntimeManifest, publicKey: Data, observedAtMilliseconds: Int64, observationBoundary: String) throws {
        guard publicKey.count == 32, observedAtMilliseconds > 0, environmentBoundaryValid(observationBoundary) else { throw EnvironmentError.invalidObservation }
        self.manifest = manifest; self.publicKey = publicKey; self.observedAtMilliseconds = observedAtMilliseconds; self.observationBoundary = observationBoundary
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case manifest, publicKey, observedAtMilliseconds, observationBoundary }
    public init(from decoder: Decoder) throws {
        try environmentDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(manifest: c.decode(EnvironmentRuntimeManifest.self, forKey: .manifest), publicKey: c.decode(Data.self, forKey: .publicKey),
                      observedAtMilliseconds: c.decode(Int64.self, forKey: .observedAtMilliseconds), observationBoundary: c.decode(String.self, forKey: .observationBoundary))
    }
}

public enum EnvironmentPresence: String, Codable, Sendable { case present, absent, unknown }

public struct EnvironmentObservation: Codable, Sendable, Equatable {
    public let environmentID: String
    public let correlationID: String
    public let providerResourceID: String?
    public let presence: EnvironmentPresence
    public let state: EnvironmentState
    public let observedAtMilliseconds: Int64
    public let runtime: EnvironmentRuntimeObservation?
    public let observationBoundary: String
    public init(environmentID: String, correlationID: String, providerResourceID: String? = nil, presence: EnvironmentPresence,
                state: EnvironmentState, observedAtMilliseconds: Int64, runtime: EnvironmentRuntimeObservation? = nil, observationBoundary: String) throws {
        guard EnvironmentIdentity.isCanonicalID(environmentID), EnvironmentIdentity.isCanonicalID(correlationID),
              providerResourceID.map(EnvironmentIdentity.isResourceID) ?? true, observedAtMilliseconds > 0,
              environmentBoundaryValid(observationBoundary), runtime.map({ $0.observedAtMilliseconds <= observedAtMilliseconds }) ?? true else { throw EnvironmentError.invalidObservation }
        switch presence {
        case .present: guard providerResourceID != nil, state != .destroyed else { throw EnvironmentError.invalidObservation }
        case .absent: guard state == .destroyed, runtime == nil else { throw EnvironmentError.invalidObservation }
        case .unknown: guard state == .unknown, runtime == nil else { throw EnvironmentError.invalidObservation }
        }
        self.environmentID = environmentID; self.correlationID = correlationID; self.providerResourceID = providerResourceID
        self.presence = presence; self.state = state; self.observedAtMilliseconds = observedAtMilliseconds; self.runtime = runtime; self.observationBoundary = observationBoundary
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case environmentID, correlationID, providerResourceID, presence, state, observedAtMilliseconds, runtime, observationBoundary }
    public init(from decoder: Decoder) throws {
        try environmentDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(environmentID: c.decode(String.self, forKey: .environmentID), correlationID: c.decode(String.self, forKey: .correlationID),
                      providerResourceID: c.decodeIfPresent(String.self, forKey: .providerResourceID), presence: c.decode(EnvironmentPresence.self, forKey: .presence),
                      state: c.decode(EnvironmentState.self, forKey: .state), observedAtMilliseconds: c.decode(Int64.self, forKey: .observedAtMilliseconds),
                      runtime: c.decodeIfPresent(EnvironmentRuntimeObservation.self, forKey: .runtime), observationBoundary: c.decode(String.self, forKey: .observationBoundary))
    }
}

/// This type intentionally has no success/verified property.
public struct EnvironmentProviderAcceptance: Codable, Sendable, Equatable {
    public let acceptance: ExecutionProviderAcceptance
    public let providerResourceID: String?
    public let message: String
    public init(acceptance: ExecutionProviderAcceptance, providerResourceID: String? = nil, message: String = "") throws {
        guard providerResourceID.map(EnvironmentIdentity.isResourceID) ?? true, message.utf8.count <= 1024,
              message.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw EnvironmentError.invalidObservation }
        self.acceptance = acceptance; self.providerResourceID = providerResourceID; self.message = message
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case acceptance, providerResourceID, message }
    public init(from decoder: Decoder) throws {
        try environmentDecodeKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(acceptance: c.decode(ExecutionProviderAcceptance.self, forKey: .acceptance), providerResourceID: c.decodeIfPresent(String.self, forKey: .providerResourceID), message: c.decode(String.self, forKey: .message))
    }
}

public struct EnvironmentProviderSupport: Codable, Sendable, Equatable {
    public let supportsCreate: Bool
    public let supportsBootstrap: Bool
    public let supportsChallenge: Bool
    public let supportsStop: Bool
    public let supportsDestroy: Bool
    public let enforcesTTL: Bool
    public let nativeCreateIdempotency: Bool
    public init(supportsCreate: Bool = false, supportsBootstrap: Bool = false, supportsChallenge: Bool = false,
                supportsStop: Bool = false, supportsDestroy: Bool = false, enforcesTTL: Bool = false, nativeCreateIdempotency: Bool = false) {
        self.supportsCreate = supportsCreate; self.supportsBootstrap = supportsBootstrap; self.supportsChallenge = supportsChallenge
        self.supportsStop = supportsStop; self.supportsDestroy = supportsDestroy; self.enforcesTTL = enforcesTTL; self.nativeCreateIdempotency = nativeCreateIdempotency
    }
}

/// Operator-installed provider boundary. Credentials and endpoint/image choices
/// remain inside implementations; observations are separate from API acceptance.
public protocol EnvironmentProvider: AnyObject {
    var id: String { get }
    var support: EnvironmentProviderSupport { get }
    func create(_ intent: EnvironmentCreateIntent) throws -> EnvironmentProviderAcceptance
    func observe(correlationID: String) throws -> EnvironmentObservation
    func list() throws -> [EnvironmentObservation]
    func bootstrap(_ handle: EnvironmentHandle, manifest: EnvironmentRuntimeManifest) throws -> EnvironmentProviderAcceptance
    func executeChallenge(_ handle: EnvironmentHandle, executionID: String, challenge: String) throws -> EnvironmentProviderAcceptance
    func observeChallenge(_ handle: EnvironmentHandle, executionID: String) throws -> String?
    func stop(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance
    func destroy(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance
}

private struct EnvironmentDecodeKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func environmentDecodeKeys<Keys: CodingKey & CaseIterable>(_ decoder: Decoder, allowed: Keys.Type) throws {
    let keys = try decoder.container(keyedBy: EnvironmentDecodeKey.self).allKeys.map(\.stringValue)
    guard Set(keys).isSubset(of: Set(Keys.allCases.map(\.stringValue))) else { throw EnvironmentError.invalidObservation }
}
private func environmentBoundaryValid(_ value: String) -> Bool {
    (1...1024).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
}
private func environmentCanonical(domain: String, value: CapabilityValue) throws -> Data {
    Data((domain + "\0").utf8) + (try value.canonicalData(limits: .init(maxDepth: 8, maxNodes: 128, maxBytes: 8192)))
}
private extension EnvironmentSpec {
    var canonicalValue: CapabilityValue { .object([
        "profileID": .string(profileID), "lifetimeMilliseconds": .integer(lifetimeMilliseconds),
        "resources": .object(["cpuCount": .integer(Int64(resources.cpuCount)), "memoryMiB": .integer(Int64(resources.memoryMiB)),
                              "maximumCostUnits": .integer(resources.maximumCostUnits), "costUnit": .string(resources.costUnit)])
    ]) }
}
private extension EnvironmentLineage {
    var canonicalValue: CapabilityValue { .object([
        "rootEnvironmentID": .string(rootEnvironmentID), "parentEnvironmentID": parentEnvironmentID.map(CapabilityValue.string) ?? .null,
        "parentExecutionID": .string(parentExecutionID), "parentRuntimeID": .string(parentRuntimeID), "depth": .integer(Int64(depth))
    ]) }
}
