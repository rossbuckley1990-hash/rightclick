import RightClickProtocol
import Foundation

public protocol DBusTransport: AnyObject {
    var provenance: [String: String] { get }
    func call(destination: String, path: String, interface: String, member: String, signature: String,
              tokens: [String], replySignature: String,
              admitStart: ((_ start: () -> Void) throws -> Void)?) throws -> [CapabilityValue]
    func available() -> Bool
}

final class DBusAcquiredReflector: RCIRExecutionReflector, CapabilityContractRefreshingReflector {
    let id: String
    private let underlying: CapabilityInterfaceReflector
    private let refresh: () throws -> any CapabilityReflector
    // Acquisition always checks current ownership and typed metadata; no hidden
    // persistent owner subscription or second event/lifecycle engine.
    var requiresContractRefresh: Bool { true }
    init(_ underlying: CapabilityInterfaceReflector, refresh: @escaping () throws -> any CapabilityReflector) {
        self.underlying = underlying; self.id = underlying.id; self.refresh = refresh
    }
    func refreshContract() throws -> any CapabilityReflector { try refresh() }
    func capabilities(for item: ContentItem) throws -> [Capability] { try underlying.capabilities(for: item) }
    func providers() -> [ProviderSummary] { underlying.providers() }
    func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
        try underlying.begin(capability: capability, item: item, executionID: executionID)
    }
    func begin(capability: Capability, item: ContentItem, executionID: String, arguments: CapabilityArguments?) throws -> ExecutionRecord {
        try underlying.begin(capability: capability, item: item, executionID: executionID, arguments: arguments)
    }
    func admittedBegin(capability: Capability, admissionOwner: Capability, item: ContentItem, executionID: String,
                       arguments: CapabilityArguments?, verification: VerificationSpec?, expectedOutput: String?,
                       host: RCIRExecutionHost, revalidate: @escaping () -> Bool) throws -> ExecutionRecord {
        try underlying.admittedBegin(capability: capability, admissionOwner: admissionOwner, item: item,
            executionID: executionID, arguments: arguments, verification: verification, expectedOutput: expectedOutput,
            host: host, revalidate: revalidate)
    }
}

public final class DBusCapabilityArtifactResolver: CapabilityArtifactResolver {
    public let kind = "dbus"
    private let transport: (any DBusTransport)?
    private let invocationArgument: String?
    public init(transport: (any DBusTransport)?, invocationArgument: String? = nil) {
        self.transport = transport
        self.invocationArgument = invocationArgument.flatMap { DBusIntrospection.validMember($0) ? $0 : nil }
    }
    public static func discoveryMetadata(_ xml: Data) throws -> (children: [String], hasSupportedMethods: Bool) {
        let compiled = try DBusIntrospection.compile(xml)
        return (compiled.children, !compiled.methods.isEmpty)
    }
    public static func validMember(_ value: String) -> Bool { DBusIntrospection.validMember(value) }
    public static func validInterface(_ value: String) -> Bool { DBusIntrospection.validInterface(value) }
    static func validBusName(_ name: String) -> Bool {
        name.utf8.count <= 255 && name.contains(".") && name.range(of: "^[A-Za-z_][A-Za-z0-9_-]*(\\.[A-Za-z_][A-Za-z0-9_-]*)+$", options: .regularExpression) != nil
    }
    static func validPath(_ path: String) -> Bool {
        path == "/" || (path.utf8.count <= 1024 && path.range(of: "^(/[A-Za-z0-9_]+)+$", options: .regularExpression) != nil)
    }
    public func owner(_ name: String) throws -> String {
        guard let transport else { throw RCIRError.unavailable }
        let values = try transport.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus", member: "GetNameOwner", signature: "s", tokens: [name], replySignature: "s", admitStart: nil)
        guard values.count == 1, case let .string(owner) = values[0],
              owner.range(of: "^:[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { throw CapabilityABIError.invalidWire }
        return owner
    }
    func busID() throws -> String {
        guard let transport else { throw RCIRError.unavailable }
        let values = try transport.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus",
            member: "GetId", signature: "", tokens: [], replySignature: "s", admitStart: nil)
        guard values.count == 1, case let .string(identifier) = values[0],
              identifier.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else { throw CapabilityABIError.invalidWire }
        return identifier
    }
    public func introspect(owner: String, path: String) throws -> Data {
        guard let transport else { throw RCIRError.unavailable }
        let values = try transport.call(destination: owner, path: path, interface: "org.freedesktop.DBus.Introspectable",
            member: "Introspect", signature: "", tokens: [], replySignature: "s", admitStart: nil)
        guard values.count == 1, case let .string(xml) = values[0] else { throw CapabilityABIError.invalidWire }
        return Data(xml.utf8)
    }
    public func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector {
        guard descriptor.kind == kind, descriptor.authorityScheme == nil, descriptor.inlineData == nil,
              descriptor.specificationURL == nil, descriptor.baseURL == nil,
              let raw = descriptor.endpointURL, let target = URL(string: raw),
              let parts = URLComponents(url: target, resolvingAgainstBaseURL: false), parts.scheme == "dbus",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              let name = parts.host, Self.validBusName(name), Self.validPath(parts.path),
              let transport, transport.available() else { throw CapabilityArtifactResolutionError.invalidDescriptor("D-Bus requires a native session and a documented bus/object target") }
        let path = parts.path, busID = try self.busID(), owner = try self.owner(name)
        let xml = try introspect(owner: owner, path: path)
        let acquired = try DBusIntrospection.compile(xml)
        guard !acquired.methods.isEmpty else { throw CapabilityABIError.unknownSchema }
        let uidValues = try transport.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus",
            member: "GetConnectionUnixUser", signature: "s", tokens: [owner], replySignature: "u", admitStart: nil)
        guard uidValues.count == 1, case let .integer(uid) = uidValues[0], uid >= 0, uid <= Int64(UInt32.max),
              try self.owner(name) == owner, try self.busID() == busID else { throw RCIRError.staleBinding }
        let marker = invocationArgument
        let methods = Dictionary(uniqueKeysWithValues: acquired.methods.map { ($0.key, $0) })
        let operations = try acquired.methods.map { try $0.operation(reservedArgument: marker) }
        let digest = CapabilityJSON.digest(try CapabilityValue.object(["xml": .bytes(xml), "owner": .string(owner), "uid": .integer(uid), "busID": .string(busID),
            "hostInvocationArgument": marker.map { .string($0) } ?? .null]).canonicalData())
        func unchanged() -> Bool {
            guard transport.available(), (try? self.busID()) == busID, (try? self.owner(name)) == owner,
                  let current = try? self.introspect(owner: owner, path: path) else { return false }
            return current == xml && (try? self.owner(name)) == owner && (try? self.busID()) == busID
        }
        var provenance = transport.provenance
        provenance.merge(["dbusUniqueOwner": owner, "dbusBusID": busID, "dbusOwnerUnixUID": String(uid), "dbusObjectPath": path,
            "dbusOmittedUnsupportedMethods": acquired.omittedMethods.sorted().joined(separator: ","),
            "nativeDescriptorSHA256": CapabilityJSON.digest(xml),
            "hostInvocationArgument": marker ?? "none",
            "coreTypedInput": "String fields literal; non-string fields bounded CapabilityValue tagged wire JSON",
            "nativeEffectDeclaration": "Introspection does not declare application side effects; RCIR grants exact member execution only, with mandatory confirmation",
            "liveOwnerBinding": "Bus ID, unique owner and exact introspection rechecked at discovery and final transport gate; auto-start disabled"]) { _, value in value }
        let reflector = try CapabilityInterfaceReflector(id: "dbus:" + descriptor.id, provider: name, target: target,
            substrate: kind, descriptorDigest: digest, operations: operations, provenance: provenance,
            argumentEncoding: .taggedNonStrings, runtimeRequirements: .init(operatingSystems: [.linux]), available: unchanged,
            boundInvoke: { key, input, binding, admit in
                guard unchanged(), let method = methods[key], case let .object(values) = input else { throw RCIRError.staleBinding }
                var tokens: [String] = []
                for parameter in method.inputs {
                    let value: CapabilityValue
                    if parameter.name == marker { value = .string(binding.id) }
                    else { guard let supplied = values[parameter.name] else { throw CapabilityABIError.schemaMismatch }; value = supplied }
                    tokens += try parameter.type.tokens(value)
                }
                let reply = try withoutActuallyEscaping(admit) { gate in
                    try transport.call(destination: owner, path: path, interface: method.interface, member: method.member,
                        signature: method.inputSignature, tokens: tokens, replySignature: method.outputSignature, admitStart: gate)
                }
                return try method.result(reply)
            }, invoke: { _, _, _ in throw RCIRError.invalidContract })
        return DBusAcquiredReflector(reflector) { try self.resolve(descriptor) }
    }
    public func names() throws -> [String] {
        guard let transport else { throw RCIRError.unavailable }
        let values = try transport.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus",
            member: "ListNames", signature: "", tokens: [], replySignature: "as", admitStart: nil)
        guard values.count == 1, case let .array(names) = values[0], names.count <= 4096 else { throw CapabilityABIError.invalidWire }
        return names.compactMap { value in guard case let .string(name) = value, Self.validBusName(name), name != "org.freedesktop.DBus" else { return nil }; return name }.sorted()
    }
}
