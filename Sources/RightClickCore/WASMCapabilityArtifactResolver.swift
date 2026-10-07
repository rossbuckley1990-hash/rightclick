import Foundation

/// Actual component-model WIT acquisition, extracted from the component binary
/// by host-selected wasm-tools, followed by bounded no-import Wasmtime execution.
/// Unsupported imports/types fail closed rather than acquiring ambient rights.
public final class WASMCapabilityArtifactResolver: CapabilityArtifactResolver {
    public let kind = "wasm"
    private let tools: URL?
    private let runtime: URL?
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        tools = environment["RIGHTCLICK_WASM_TOOLS"].map { URL(fileURLWithPath: $0) }
        runtime = environment["RIGHTCLICK_WASM_RUNTIME"].map { URL(fileURLWithPath: $0) }
    }
    public func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector {
        guard descriptor.kind == kind, descriptor.authorityScheme == nil, descriptor.inlineData == nil,
              descriptor.baseURL == nil, descriptor.endpointURL == nil,
              let raw = descriptor.specificationURL, let component = URL(string: raw),
              component.isFileURL, component.host == nil || component.host == "localhost",
              component.query == nil, component.fragment == nil, component.path.hasPrefix("/"),
              let tools, let runtime else {
            throw CapabilityArtifactResolutionError.invalidDescriptor("WASM requires a local component file and operator-selected tools/runtime; imports have no authority grant.")
        }
        let componentSnapshot = try CapabilityArtifactSnapshot(source: component, maximum: 16_777_216)
        let toolsSnapshot = try CapabilityArtifactSnapshot(source: tools, maximum: 134_217_728, executable: true)
        let runtimeSnapshot = try CapabilityArtifactSnapshot(source: runtime, maximum: 268_435_456, executable: true)
        let componentBytes = try CapabilityArtifactSnapshot.read(source: componentSnapshot.file, maximum: 16_777_216)
        guard componentBytes.prefix(8) == Data([0, 97, 115, 109, 13, 0, 1, 0]) else {
            throw CapabilityArtifactResolutionError.invalidDescriptor("Expected an actual binary WebAssembly component.")
        }
        let componentDigest = componentSnapshot.sha256
        let toolsDigest = toolsSnapshot.sha256
        let runtimeDigest = runtimeSnapshot.sha256
        let wit = try BoundedCapabilityProcess.run(executable: toolsSnapshot.file,
            arguments: ["component", "wit", componentSnapshot.file.path, "--json"])
        let compiled = try WITComponentContract.operations(wit)
        let operations = compiled.map(\.interface)
        let indexed = Dictionary(uniqueKeysWithValues: compiled.map { ($0.name, $0) })
        func unchanged() -> Bool {
            componentSnapshot.sourceStillMatches() && toolsSnapshot.sourceStillMatches() && runtimeSnapshot.sourceStillMatches()
        }
        return try CapabilityInterfaceReflector(id: "wasm:" + descriptor.id, provider: descriptor.id,
            target: component, substrate: kind, descriptorDigest: CapabilityJSON.digest(wit), operations: operations,
            provenance: ["componentSHA256": componentDigest, "runtimeSHA256": runtimeDigest,
                         "acquisitionRuntimeSHA256": toolsDigest, "runtimeExecutable": runtime.path,
                         "executionArtifactBinding": "host-private lifetime-managed read-only component/tools/runtime snapshots",
                         "hostImports": "none", "authorityScope": "exact component/export; no host filesystem, network or environment imports"],
            argumentEncoding: .taggedNonStrings,
            available: unchanged, invoke: { name, input, admit in
                guard unchanged(), let operation = indexed[name] else { throw RCIRError.staleBinding }
                // Exact declared values in one argv token. WAVE is distinct
                // from JSON, including record labels and Unicode escapes.
                let invocation = try operation.invocation(input)
                let data = try withoutActuallyEscaping(admit) { gate in
                    try BoundedCapabilityProcess.run(executable: runtimeSnapshot.file,
                        arguments: ["run", "-C", "cache=n", "-W", "timeout=3s,max-memory-size=16777216,fuel=10000000", "--invoke", invocation, componentSnapshot.file.path],
                        admitStart: gate)
                }
                return try operation.returned(data)
            })
    }
}
