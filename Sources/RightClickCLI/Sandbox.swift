import Foundation
import RightClickCore
import RightClickMCP
import RightClickHostFiles
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An opt-in disposable provider fixture. Its engine acquires only this
/// declaration; it exposes no host providers, shell or network executors.
/// This capability boundary is not a general operating-system sandbox.
final class RightClickSandbox {
    let directory: URL
    let source: Source
    let engine: CapabilityEngine

    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rightclick-sandbox-" + UUID().uuidString, isDirectory: true)
#if os(Windows)
        guard directory.path.withCString({ rc_host_create_private_directory($0) }) == 0 else {
            throw RightClickError("Could not create a private disposable capability directory.")
        }
#else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
#endif
        do {
            source = try Source(directory: directory)
            engine = CapabilityEngine(reflectors: [], reflectorSources: [source], experience: nil,
                                      rcirHost: .disposable())
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    final class Source: CapabilityReflectorSource {
        let id = "sandbox.declared-fixture"
        private let lock = NSLock()
        private var active = true
        private let reflector: CapabilityInterfaceReflector

        init(directory: URL) throws {
            // An ordinary advertised declaration is compiled through the same
            // closed schema importer and RCIR execution reflector as providers.
            let declaration: [String: Any] = [
                "name": "record_challenge", "title": "Record a disposable challenge",
                "inputSchema": ["type": "object", "additionalProperties": false,
                    "required": ["challenge"], "properties": ["challenge": [
                        "type": "string", "pattern": "^[A-Za-z0-9_-]{1,128}$"]]],
                "outputSchema": ["type": "object", "additionalProperties": false,
                    "required": ["challenge"], "properties": ["challenge": ["type": "string"]]],
            ]
            let bytes = try JSONSerialization.data(withJSONObject: declaration, options: [.sortedKeys])
            let result = try CapabilityJSON.schema(declaration["outputSchema"]!)
            let observed = CapabilitySchema.object(properties: ["challenge": .string, "taskID": .string],
                                                   required: ["challenge", "taskID"])
            let operation = CapabilityInterfaceOperation(name: declaration["name"] as! String,
                title: declaration["title"] as! String,
                arguments: try CapabilityJSON.schema(declaration["inputSchema"]!), result: result,
                declaration: try CapabilityJSON.value(declaration), effect: .write)
            reflector = try CapabilityInterfaceReflector(id: "sandbox:fixture", provider: "Disposable provider fixture",
                target: directory, substrate: "sandbox-fixture", descriptorDigest: CapabilityJSON.digest(bytes),
                operations: [operation], observerFactory: { _ in { input in
                    let observer = Observer(directory: directory)
                    return RCIRHostObservation(contract: .init(observerID: observer.observerID,
                        schema: result, expected: input,
                        projection: .init(schema: observed, fields: ["challenge": ["challenge"]]),
                        invocationBindingPath: ["taskID"]), observer: observer,
                        boundary: "Host-selected private-file read-back bound to this invocation; disposable local fixture.")
                } }, available: { true }, boundInvoke: { _, input, binding, admit in
                    guard case let .object(fields) = input, case let .string(challenge)? = fields["challenge"] else {
                        throw CapabilityABIError.schemaMismatch
                    }
                    let file = directory.appendingPathComponent("effect-" + binding.id + ".json")
                    let value: [String: String] = ["challenge": challenge, "taskID": binding.id]
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                    var failure: Error?
                    try admit {
                        do { try Self.create(data, at: file) } catch { failure = error }
                    }
                    if let failure { throw failure }
                    return input
                }, invoke: { _, _, _ in throw RCIRError.unavailable })
        }
        func reflectors() -> [any CapabilityReflector] {
            lock.lock(); defer { lock.unlock() }
            return active ? [reflector] : []
        }
        func withdraw() { lock.lock(); active = false; lock.unlock() }
        func invalidateSnapshot() {}

        private static func create(_ data: Data, at file: URL) throws {
#if os(Windows)
            let status = data.withUnsafeBytes { bytes in
                // Effects are mutable private fixture files, like POSIX mode
                // 0600. Immutable snapshot attributes prevent Windows cleanup.
                file.path.withCString { rc_host_write_private_config($0,
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
            }
            guard status == 0 else { throw RCIRError.unavailable }
#else
            let handle = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard handle >= 0 else { throw RCIRError.unavailable }
            defer { close(handle) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(handle, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw RCIRError.unavailable }
                    offset += count
                }
            }
            guard fsync(handle) == 0 else { throw RCIRError.unavailable }
#endif
        }
    }

    private struct Observer: RCIRObserver {
        let directory: URL
        var observerID: String { "sandbox:private-file-observer" }
        func observe(_ request: RCIRObservationRequest) throws -> CapabilityValue {
            let file = directory.appendingPathComponent("effect-" + request.taskID.uuidString + ".json")
            let data: Data
#if os(Windows)
            var buffer: UnsafeMutablePointer<UInt8>?, count = 0
            guard file.path.withCString({ rc_host_read_file($0, 4096, 1, &buffer, &count) }) == 0,
                  let buffer else { throw RCIRError.unverified }
            defer { rc_host_free(buffer) }
            data = Data(bytes: buffer, count: count)
#else
            let handle = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard handle >= 0 else { throw RCIRError.unverified }
            defer { close(handle) }
            var info = stat()
            guard fstat(handle, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
                  info.st_size > 0, info.st_size <= 4096 else { throw RCIRError.unverified }
            var bytes = [UInt8](repeating: 0, count: 4097)
            let count = read(handle, &bytes, bytes.count)
            guard count > 0, count <= 4096, count == info.st_size else { throw RCIRError.unverified }
            data = Data(bytes.prefix(count))
#endif
            return try CapabilityJSON.value(JSONSerialization.jsonObject(with: data))
        }
    }
}

enum RightClickSandboxCLI {
    static func run(_ args: [String], output: (String) -> Void = { print($0) }) -> Int {
        guard args.allSatisfy({ ["--json", "--mcp"].contains($0) }), Set(args).count == args.count else {
            output("usage: rightclick sandbox [--json | --mcp]"); return 2
        }
        do {
            let sandbox = try RightClickSandbox()
            if args.contains("--mcp") {
                return withExtendedLifetime(sandbox) { RightClickMCPMain.run([], engine: sandbox.engine) }
            }
            let challenge = "sandbox_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let actions = try sandbox.engine.capabilities(for: challenge).capabilities
            guard actions.count == 1, let action = actions.first else { throw RCIRError.unavailable }
            let blocked = try sandbox.engine.begin(id: action.id, item: challenge, confirmed: false,
                arguments: ["challenge": challenge])
            guard blocked.state == .awaitingUser,
                  try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path).isEmpty else {
                throw RCIRError.policyDenied
            }
            let record = try sandbox.engine.begin(id: action.id, item: challenge, confirmed: true,
                arguments: ["challenge": challenge])
            guard record.state == .succeeded, let receipt = record.rcir?.receipt,
                  let payload = Data(base64Encoded: receipt) else { throw RCIRError.unverified }
            let signer = try RCIREd25519Signer(rawPrivateKey: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
            let signature = try signer.sign(payload)
            guard try RCIREd25519Verifier().verify(signature: signature, payload: payload, publicKey: signer.publicKey) else {
                throw RCIRReceiptError.invalidSignature
            }
            sandbox.source.withdraw()
            guard try sandbox.engine.capabilities(for: challenge).capabilities.isEmpty else { throw RCIRError.staleBinding }
            let envelope = RCIRReceiptEnvelope(version: 1, algorithm: "Ed25519", payload: receipt,
                signature: signature.base64EncodedString(), publicKey: signer.publicKey.base64EncodedString())
            struct Report: Encodable {
                let scope = "Disposable local provider fixture; capability-scoped environment"
                let status = "VERIFIED"
                let operationCount = RightClickMCPContract.toolNames().count
                let policyDeniedBeforeConfirmation = true
                let providerWithdrawalObserved = true
                let signingTrust = "Ephemeral sandbox key; not production receipt trust"
                let execution: ExecutionRecord
                let signedReceipt: RCIRReceiptEnvelope
            }
            output(RightClickJSON.encode(Report(execution: record, signedReceipt: envelope)))
            return 0
        } catch {
            output(RightClickJSON.encode(["status": "FAILED", "error": String(describing: error),
                "scope": "Disposable provider fixture"])); return 1
        }
    }
}
