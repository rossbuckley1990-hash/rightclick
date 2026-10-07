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
        let componentBytes = try boundedArtifact(component)
        guard componentBytes.prefix(8) == Data([0, 97, 115, 109, 13, 0, 1, 0]) else {
            throw CapabilityArtifactResolutionError.invalidDescriptor("Expected an actual binary WebAssembly component.")
        }
        let componentDigest = CapabilityJSON.digest(componentBytes)
        let toolsDigest = CapabilityJSON.digest(try boundedArtifact(tools, maximum: 134_217_728))
        let runtimeDigest = CapabilityJSON.digest(try boundedArtifact(runtime, maximum: 268_435_456))
        let wit = try BoundedCapabilityProcess.run(executable: tools, arguments: ["component", "wit", component.path, "--json"])
        guard let json = try JSONSerialization.jsonObject(with: wit) as? [String: Any],
              let worlds = json["worlds"] as? [[String: Any]], worlds.count == 1,
              let world = worlds.first, let imports = world["imports"] as? [String: Any], imports.isEmpty,
              let exports = world["exports"] as? [String: Any], !exports.isEmpty, exports.count <= 256 else {
            throw CapabilityArtifactResolutionError.invalidDescriptor("Only one no-import component world is supported; host imports require an explicit reusable authority model.")
        }
        var parameterNames: [String: [String]] = [:]
        let operations = try exports.keys.sorted().map { name -> CapabilityInterfaceOperation in
            guard name.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
                  let export = exports[name] as? [String: Any], Set(export.keys) == ["function"],
                  let function = export["function"] as? [String: Any], function["kind"] as? String == "freestanding",
                  let parameters = function["params"] as? [[String: Any]], parameters.count <= 32,
                  let resultType = function["result"] as? String else { throw CapabilityABIError.invalidSchema }
            var properties: [String: CapabilitySchema] = [:]; var names: [String] = []
            for parameter in parameters {
                guard let name = parameter["name"] as? String, !name.isEmpty,
                      properties[name] == nil, parameter["type"] as? String == "string" else { throw CapabilityABIError.invalidSchema }
                names.append(name); properties[name] = .string
            }
            let result: CapabilitySchema
            switch resultType { case "string": result = .string; case "u32", "s32": result = .integer
            case "bool": result = .boolean; default: throw CapabilityABIError.invalidSchema }
            parameterNames[name] = names
            return .init(name: name, title: name,
                arguments: .object(properties: properties, required: names), result: result,
                declaration: try CapabilityJSON.value(function))
        }
        func unchanged() -> Bool {
            guard let bytes = try? self.boundedArtifact(component),
                  let toolsBytes = try? self.boundedArtifact(tools, maximum: 134_217_728),
                  let runtimeBytes = try? self.boundedArtifact(runtime, maximum: 268_435_456) else { return false }
            return CapabilityJSON.digest(bytes) == componentDigest && CapabilityJSON.digest(toolsBytes) == toolsDigest
                && CapabilityJSON.digest(runtimeBytes) == runtimeDigest
        }
        return try CapabilityInterfaceReflector(id: "wasm:" + descriptor.id, provider: descriptor.id,
            target: component, substrate: kind, descriptorDigest: CapabilityJSON.digest(wit), operations: operations,
            provenance: ["componentSHA256": componentDigest, "runtimeSHA256": runtimeDigest,
                         "acquisitionRuntimeSHA256": toolsDigest, "runtimeExecutable": runtime.path,
                         "hostImports": "none", "authorityScope": "exact component/export; no host filesystem, network or environment imports"],
            available: unchanged, invoke: { name, input, admit in
                guard unchanged(), case let .object(values) = input, let names = parameterNames[name] else { throw RCIRError.staleBinding }
                let parameters = try names.map { name -> String in
                    guard case let .string(value)? = values[name] else { throw CapabilityABIError.schemaMismatch }
                    // Wasmtime's component argument grammar accepts JSON string
                    // syntax. This is one argv token, never shell interpolation.
                    return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
                }
                let invocation = name + "(" + parameters.joined(separator: ",") + ")"
                let data = try withoutActuallyEscaping(admit) { gate in
                    try BoundedCapabilityProcess.run(executable: runtime,
                        arguments: ["run", "-C", "cache=n", "-W", "timeout=3s,max-memory-size=16777216,fuel=10000000", "--invoke", invocation, component.path],
                        admitStart: gate)
                }
                let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let bytes = trimmed.data(using: .utf8) else { throw CapabilityABIError.invalidWire }
                return try CapabilityJSON.value(JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]))
            })
    }
    private func boundedArtifact(_ url: URL, maximum: Int = 16_777_216) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0, size.int64Value <= maximum else { throw CapabilityABIError.limitExceeded }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximum else { throw CapabilityABIError.limitExceeded }
        return bytes
    }
}
