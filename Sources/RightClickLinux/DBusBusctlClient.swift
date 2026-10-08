import Foundation
import RightClickProtocol
import RightClickProviders
/// Host-selected native client, private immutable executable snapshot and
/// bounded argv/JSON exchange. It cannot start services or select another bus.
final class DBusBusctlClient: DBusTransport {
    private let address: String
    private let executable: CapabilityExecutableProcess
    var provenance: [String: String] {
        ["dbusBusAddress": address, "dbusClientSHA256": executable.sourceSHA256,
         "dbusAuthentication": "native Unix EXTERNAL principal; bus daemon policy independently enforces method rights",
         "authorityBoundary": "Common local lease/policy plus native bus issuer policy; no bearer secret in model inputs",
         "discoveryBoundary": "Documented ListNames/GetNameOwner/Introspect; auto-start disabled"]
    }
    init(address: String, executable: URL) throws {
        guard Self.validAddress(address) else { throw CapabilityArtifactResolutionError.invalidDescriptor("D-Bus requires a single native Unix session address") }
        self.address = address
        self.executable = try CapabilityExecutableProcess(source: executable, maximumExecutableBytes: 16_777_216)
    }
    static func validAddress(_ value: String) -> Bool {
        guard value.utf8.count <= 4096, !value.utf8.contains(0), value.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let endpoint = parts.first,
              (endpoint.hasPrefix("unix:path=/") || endpoint.hasPrefix("unix:abstract=")),
              endpoint.count > (endpoint.hasPrefix("unix:path=") ? 11 : 14), !endpoint.contains(";") else { return false }
        if parts.count == 2 {
            let guid = String(parts[1]); return guid.range(of: "^guid=[a-fA-F0-9]{32}$", options: .regularExpression) != nil
        }
        return true
    }
    func available() -> Bool { executable.isCurrent }
    func call(destination: String, path: String, interface: String, member: String, signature: String,
              tokens: [String], replySignature: String,
              admitStart: ((_ start: () -> Void) throws -> Void)? = nil) throws -> [CapabilityValue] {
        guard available(), destination.utf8.count <= 255, path.utf8.count <= 1024,
              DBusCapabilityArtifactResolver.validInterface(interface), DBusCapabilityArtifactResolver.validMember(member),
              signature.utf8.count <= 255, tokens.count <= 8192,
              tokens.reduce(0, { $0 + $1.utf8.count }) <= 262_144 else { throw RCIRError.invalidLimit }
        let bytes = try executable.run(arguments: ["--address=" + address, "--auto-start=no", "--timeout=1s", "--json=short", "--", "call", destination, path, interface, member, signature] + tokens,
            timeout: 2, maximumOutputBytes: 131_072, admitStart: admitStart)
        guard available() else { throw RCIRError.staleBinding }
        // Empty D-Bus METHOD_RETURN is explicit transport completion, not JSON null.
        if replySignature.isEmpty {
            if bytes.isEmpty || String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        }
        guard let reply = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(reply.keys) == ["type", "data"], reply["type"] as? String == replySignature,
              let values = reply["data"] as? [Any] else { throw CapabilityABIError.invalidWire }
        return try values.map { try CapabilityJSON.value($0) }
    }
}


public extension DBusCapabilityArtifactResolver {
    convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let transport = environment["DBUS_SESSION_BUS_ADDRESS"].flatMap {
            try? DBusBusctlClient(address: $0,
                executable: URL(fileURLWithPath: environment["RIGHTCLICK_DBUS_CLIENT"] ?? "/usr/bin/busctl"))
        }
        self.init(transport: transport, invocationArgument: environment["RIGHTCLICK_DBUS_INVOCATION_ARGUMENT"])
    }
}
