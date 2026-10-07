import Foundation
#if os(Windows)
import RightClickWindowsCOM

/// Bounded native transport. The MTA owns all COM references; Swift holds only
/// opaque acquisition/call tokens. Timeout permanently quarantines this client.
final class WindowsCOMClient {
    private let client: OpaquePointer
    init() throws { guard let client = rc_com_open() else { throw RCIRError.unavailable }; self.client = client }
    deinit { rc_com_close(client) }
    private func checked(_ status: Int32) throws {
        switch status { case 0: return; case 1: throw RCIRError.staleBinding; case 2: throw CapabilityABIError.invalidWire; default: throw RCIRError.unverified }
    }
    func catalog() throws -> [WindowsCOMTypeLibrary] {
        var bytes: UnsafeMutablePointer<UInt8>?, length = 0
        let status = rc_com_catalog(client, &bytes, &length)
        defer { rc_com_free(bytes) }
        try checked(status)
        guard let bytes, length <= 1_048_576 else { throw CapabilityABIError.invalidWire }
        return try WindowsCOMTypeLibrary.compile(Data(bytes: bytes, count: length))
    }
    func available(_ acquisition: String) -> Bool { acquisition.withCString { rc_com_validate(client, $0) == 0 } }
    func invoke(_ library: WindowsCOMTypeLibrary, member: WindowsCOMMember, input: CapabilityValue,
                admit: (_ start: () -> Void) throws -> Void) throws -> CapabilityValue {
        let arguments = try member.arguments(input)
        var call: OpaquePointer?
        let status = library.acquisition.acquisitionID.withCString { acquisition in
            arguments.withUnsafeBytes { bytes in
                rc_com_prepare(client, acquisition, member.id, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &call)
            }
        }
        try checked(status)
        guard let call else { throw RCIRError.unavailable }
        defer { rc_com_release_call(call) }
        var enqueued: Int32 = 3
        // This closure performs no COM operation or wait under RCIR admission.
        try admit { enqueued = rc_com_enqueue(call) }
        try checked(enqueued)
        var bytes: UnsafeMutablePointer<UInt8>?, length = 0
        let completed = rc_com_wait(call, &bytes, &length)
        defer { rc_com_free(bytes) }
        try checked(completed)
        guard let bytes, length <= 1_048_576 else { throw CapabilityABIError.invalidWire }
        return try member.resultValue(Data(bytes: bytes, count: length))
    }
}
#endif

/// Resolves an already-running native object. Endpoint tokens are acquired in
/// this runtime; descriptors cannot activate classes or substitute a library.
public final class WindowsCOMCapabilityArtifactResolver: CapabilityArtifactResolver {
    public let kind = "windows.com"
#if os(Windows)
    private let client: WindowsCOMClient?
    public init() { client = try? WindowsCOMClient() }
    init(client: WindowsCOMClient) { self.client = client }
    func catalog() throws -> [WindowsCOMTypeLibrary] { guard let client else { throw RCIRError.unavailable }; return try client.catalog() }
    func reflector(_ library: WindowsCOMTypeLibrary) throws -> any CapabilityReflector {
        guard let client, !library.operations.isEmpty,
              let target = URL(string: "windows-com://running/" + library.acquisition.acquisitionID) else { throw RCIRError.unavailable }
        let acquisition = library.acquisition.acquisitionID
        return try CapabilityInterfaceReflector(id: "windows.com:" + acquisition, provider: library.acquisition.moniker,
            target: target, substrate: kind, descriptorDigest: library.digest, operations: library.operations,
            provenance: ["windowsCOMAcquisitionID": acquisition,
                "windowsCOMInterfaceGUID": library.acquisition.declaration.interfaceGUID,
                "windowsCOMTypeLibraryGUID": library.acquisition.declaration.libraryGUID,
                "windowsCOMOmittedUnsupportedMembers": library.omitted.joined(separator: ","),
                "nativeEffectDeclaration": "Native metadata does not declare application effects; exact member execution only, mandatory confirmation",
                "nativeIdentityBoundary": "Retained canonical IUnknown in one MTA, unique equal moniker and exact metadata; observed absence invalidates token; unseen same-object ABA is not proved",
                "nativeAuthorityBoundary": "Common invocation lease/policy plus native COM server access checks; declaration is not an authenticated principal",
                "nativeDiscoveryBoundary": "GetRunningObjectTable/EnumRunning/GetObject/ITypeInfo; no class creation or BindToObject",
                "nativeTransportBoundary": "One-shot admitted queue, final native identity check before Invoke; post-dispatch timeout quarantines without retry; no atomic ROT-check/Invoke guarantee"],
            argumentEncoding: .taggedNonStrings, available: { client.available(acquisition) },
            boundInvoke: { key, input, _, admit in
                guard let member = library.members[key] else { throw RCIRError.staleBinding }
                return try client.invoke(library, member: member, input: input, admit: admit)
            }, invoke: { _, _, _ in throw RCIRError.invalidContract })
    }
#else
    public init() {}
#endif
    public func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector {
        guard descriptor.kind == kind, descriptor.specificationURL == nil, descriptor.baseURL == nil,
              descriptor.inlineData == nil, descriptor.authorityScheme == nil,
              let raw = descriptor.endpointURL, let parts = URLComponents(string: raw),
              parts.scheme == "windows-com", parts.host == "running", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.path.hasPrefix("/"), parts.path.count == 37,
              UUID(uuidString: String(parts.path.dropFirst())) != nil else {
            throw CapabilityArtifactResolutionError.invalidDescriptor("Native Windows COM requires a current runtime-acquired running-object token")
        }
#if os(Windows)
        guard let library = try catalog().first(where: { $0.acquisition.acquisitionID == String(parts.path.dropFirst()) }) else { throw RCIRError.unavailable }
        return try reflector(library)
#else
        throw RCIRError.unavailable
#endif
    }
}
