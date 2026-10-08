import CryptoKit
import Darwin
import Foundation

/// Optional host-owned Actenon authority configuration.
///
/// The proof is deliberately not a model-facing argument. When enabled, the
/// host supplies owner-only intent/proof/key material and a pinned local
/// verifier. RCIR remains the sole owner of replay consumption and dispatch.
struct ActenonHostConfiguration: Codable, Sendable {
    var enabled: Bool?
    var verifierExecutable: String?
    var verifierSHA256: String?
    var intentFile: String?
    var proofFile: String?
    var publicKeyJWKFile: String?
    var audience: String?
    var tenantID: String?
    var subjectType: String?
    var subjectID: String?
    var replayFile: String?

    fileprivate func enforced() throws -> ActenonEnforcedConfiguration? {
        guard enabled == true else { return nil }
        guard let verifierExecutable, verifierExecutable.hasPrefix("/"),
              let verifierSHA256, verifierSHA256.utf8.count == 64,
              verifierSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let intentFile, intentFile.hasPrefix("/"),
              let proofFile, proofFile.hasPrefix("/"),
              let publicKeyJWKFile, publicKeyJWKFile.hasPrefix("/"),
              let audience, !audience.isEmpty, audience.utf8.count <= 4096,
              let tenantID, !tenantID.isEmpty, tenantID.utf8.count <= 4096,
              let subjectType, !subjectType.isEmpty, subjectType.utf8.count <= 4096,
              let subjectID, !subjectID.isEmpty, subjectID.utf8.count <= 4096,
              let replayFile, replayFile.hasPrefix("/") else {
            throw RCIRError.invalidContract
        }
        for value in [audience, tenantID, subjectType, subjectID] {
            guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw RCIRError.invalidContract
            }
        }
        return ActenonEnforcedConfiguration(
            verifierExecutable: verifierExecutable,
            verifierSHA256: verifierSHA256,
            intentFile: intentFile,
            proofFile: proofFile,
            publicKeyJWKFile: publicKeyJWKFile,
            audience: audience,
            tenantID: tenantID,
            subjectType: subjectType,
            subjectID: subjectID,
            replayFile: replayFile
        )
    }
}

private struct ActenonEnforcedConfiguration {
    let verifierExecutable: String
    let verifierSHA256: String
    let intentFile: String
    let proofFile: String
    let publicKeyJWKFile: String
    let audience: String
    let tenantID: String
    let subjectType: String
    let subjectID: String
    let replayFile: String
}

struct ActenonAuthorization: Equatable, Sendable {
    let proofID: String
    let bindingDigest: String
    let argumentsDigest: String
    let proofDigest: String
    let intentDigest: String
}

/// A narrow adapter to Actenon's offline verifier.
///
/// This adapter does not execute the provider and does not own credentials.
/// It verifies proof material before RCIR asks for authority, then consumes the
/// proof id in an owner-only replay ledger immediately before RCIR consumes its
/// own single-use lease and starts the provider transport.
struct ActenonAuthorityGate {
    private static let maximumArtifactBytes = 1_048_576
    private static let maximumVerifierBytes = 67_108_864
    private static let maximumVerifierOutputBytes = 131_072
    private static let verifierTimeoutSeconds: Double = 5

    func verifyIfRequired(
        configuration: ActenonHostConfiguration?,
        capability: Capability,
        binding: RCIRBinding,
        arguments: CapabilityValue,
        scope: RCIRScope,
        requestID: String,
        now: Int64
    ) throws -> ActenonAuthorization? {
        // Read-only RCIR effects preserve existing behavior. Every other known
        // effect is consequential when Actenon enforcement is enabled.
        guard scope.effect != .read else { return nil }
        guard let config = try configuration?.enforced() else { return nil }

        let intent = try RCIRHostConfiguration.protectedRead(
            config.intentFile,
            maximum: Self.maximumArtifactBytes
        )
        let proof = try RCIRHostConfiguration.protectedRead(
            config.proofFile,
            maximum: Self.maximumArtifactBytes
        )
        let publicKey = try RCIRHostConfiguration.protectedRead(
            config.publicKeyJWKFile,
            maximum: Self.maximumArtifactBytes
        )
        let verifier = try Self.protectedExecutable(
            config.verifierExecutable,
            maximum: Self.maximumVerifierBytes
        )
        guard Self.sha256Hex(verifier) == config.verifierSHA256 else {
            throw RCIRError.authorityDenied
        }

        let bindingDigest = Self.sha256Hex(binding.bytes)
        let argumentsDigest = Self.sha256Hex(try arguments.canonicalData())
        let proofDigest = Self.sha256Hex(proof)
        let intentDigest = Self.sha256Hex(intent)
        let verificationTime = Self.rfc3339(milliseconds: now)

        let output = try Self.runVerifier(
            executable: verifier,
            intent: intent,
            proof: proof,
            publicKey: publicKey,
            audience: config.audience,
            requestID: requestID,
            verificationTime: verificationTime
        )
        let result = try Self.object(output)
        guard result["ok"] as? Bool == true,
              let proofID = result["pccb_id"] as? String,
              Self.safeProofID(proofID),
              let verifiedIntentID = result["intent_id"] as? String,
              let verifiedRequestID = result["request_id"] as? String,
              Self.exact(verifiedRequestID, requestID),
              let verifiedAudience = result["audience"] as? [String: Any],
              let audienceType = verifiedAudience["type"] as? String,
              let audienceID = verifiedAudience["id"] as? String,
              let expectedAudience = Self.audience(config.audience),
              Self.exact(audienceType, expectedAudience.type),
              Self.exact(audienceID, expectedAudience.id) else {
            throw RCIRError.authorityDenied
        }

        let intentObject = try Self.object(intent)
        try Self.requireIntentBinding(
            intentObject,
            verifiedIntentID: verifiedIntentID,
            config: config,
            capability: capability,
            binding: binding,
            argumentsDigest: argumentsDigest,
            bindingDigest: bindingDigest,
            scope: scope
        )

        return ActenonAuthorization(
            proofID: proofID,
            bindingDigest: bindingDigest,
            argumentsDigest: argumentsDigest,
            proofDigest: proofDigest,
            intentDigest: intentDigest
        )
    }

    func requireSameAuthorization(
        _ initial: ActenonAuthorization?,
        _ fresh: ActenonAuthorization?
    ) throws {
        guard initial == fresh else { throw RCIRError.authorityDenied }
    }

    func claimReplay(
        _ authorization: ActenonAuthorization,
        configuration: ActenonHostConfiguration?
    ) throws {
        guard let config = try configuration?.enforced() else {
            throw RCIRError.authorityDenied
        }
        try Self.claimProofID(authorization.proofID, replayFile: config.replayFile)
    }

    static func bindingFacts(
        capability: Capability,
        binding: RCIRBinding,
        arguments: CapabilityValue,
        scope: RCIRScope
    ) throws -> [String: String] {
        [
            "rightclick_arguments_sha256": sha256Hex(try arguments.canonicalData()),
            "rightclick_binding_sha256": sha256Hex(binding.bytes),
            "rightclick_effect": scope.effect.rawValue,
            "rightclick_generation": String(binding.generation),
            "rightclick_resource": scope.resource,
        ]
    }

    private static func requireIntentBinding(
        _ intent: [String: Any],
        verifiedIntentID: String,
        config: ActenonEnforcedConfiguration,
        capability: Capability,
        binding: RCIRBinding,
        argumentsDigest: String,
        bindingDigest: String,
        scope: RCIRScope
    ) throws {
        guard let intentID = intent["intent_id"] as? String,
              exact(intentID, verifiedIntentID),
              let contract = intent["contract"] as? [String: Any],
              exact(contract["name"] as? String, "action_intent"),
              exact(contract["version"] as? String, "v1"),
              let tenant = intent["tenant"] as? [String: Any],
              exact(tenant["tenant_id"] as? String, config.tenantID),
              let requester = intent["requester"] as? [String: Any],
              exact(requester["type"] as? String, config.subjectType),
              exact(requester["id"] as? String, config.subjectID),
              let action = intent["action"] as? [String: Any],
              exact(action["name"] as? String, capability.id),
              exact(action["capability"] as? String, capability.id),
              let parameters = action["parameters"] as? [String: Any],
              let target = intent["target"] as? [String: Any],
              exact(target["resource_type"] as? String, "rightclick-rcir-binding"),
              exact(target["resource_id"] as? String, bindingDigest) else {
            throw RCIRError.authorityDenied
        }

        // RIGHTCLICK does not currently interpret Actenon ActionSpec constraint
        // or scope subdocuments. Refuse non-empty values rather than silently
        // treating an unsupported mandatory restriction as enforced.
        if let constraints = action["constraints"] as? [String: Any], !constraints.isEmpty {
            throw RCIRError.authorityDenied
        }
        if let actionScope = action["scope"] as? [String: Any], !actionScope.isEmpty {
            throw RCIRError.authorityDenied
        }

        let expected = [
            "rightclick_arguments_sha256": argumentsDigest,
            "rightclick_binding_sha256": bindingDigest,
            "rightclick_effect": scope.effect.rawValue,
            "rightclick_generation": String(binding.generation),
            "rightclick_resource": scope.resource,
        ]
        guard exactStringObject(parameters, expected) else {
            throw RCIRError.authorityDenied
        }
    }

    private static func runVerifier(
        executable: Data,
        intent: Data,
        proof: Data,
        publicKey: Data,
        audience: String,
        requestID: String,
        verificationTime: String
    ) throws -> Data {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let verifierPath = root + "/actenon-kernel"
        let intentPath = root + "/intent.json"
        let proofPath = root + "/pccb.json"
        let keyPath = root + "/issuer.jwk.json"
        let stdoutPath = root + "/stdout.json"
        let stderrPath = root + "/stderr.txt"

        try writeExclusive(executable, to: verifierPath, mode: 0o500)
        try writeExclusive(intent, to: intentPath, mode: 0o400)
        try writeExclusive(proof, to: proofPath, mode: 0o400)
        try writeExclusive(publicKey, to: keyPath, mode: 0o400)
        try writeExclusive(Data(), to: stdoutPath, mode: 0o600)
        try writeExclusive(Data(), to: stderrPath, mode: 0o600)

        let stdout = open(stdoutPath, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        let stderr = open(stderrPath, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        guard stdout >= 0, stderr >= 0 else {
            if stdout >= 0 { close(stdout) }
            if stderr >= 0 { close(stderr) }
            throw RCIRError.authorityDenied
        }
        defer {
            close(stdout)
            close(stderr)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: verifierPath)
        process.arguments = [
            "verify-proof",
            "--intent", intentPath,
            "--pccb", proofPath,
            "--audience", audience,
            "--verification-time", verificationTime,
            "--request-id", requestID,
            "--public-key-jwk", keyPath,
            "--json",
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
            "PYTHONNOUSERSITE": "1",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle(fileDescriptor: stdout, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: stderr, closeOnDealloc: false)

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            throw RCIRError.authorityDenied
        }
        if terminated.wait(timeout: .now() + Self.verifierTimeoutSeconds) == .timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
            throw RCIRError.authorityDenied
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw RCIRError.authorityDenied
        }
        return try RCIRHostConfiguration.protectedRead(
            stdoutPath,
            maximum: Self.maximumVerifierOutputBytes
        )
    }

    private static func protectedExecutable(_ path: String, maximum: Int) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RCIRError.authorityDenied }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              (info.st_uid == geteuid() || info.st_uid == 0),
              info.st_mode & 0o022 == 0,
              info.st_mode & 0o111 != 0,
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= maximum else {
            throw RCIRError.authorityDenied
        }
        return try read(descriptor, maximum: maximum)
    }

    private static func claimProofID(_ proofID: String, replayFile: String) throws {
        guard safeProofID(proofID) else { throw RCIRError.authorityDenied }
        let descriptor = open(replayFile, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RCIRError.authorityDenied }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= Self.maximumArtifactBytes,
              flock(descriptor, LOCK_EX) == 0 else {
            throw RCIRError.authorityDenied
        }
        defer { flock(descriptor, LOCK_UN) }

        let data = try read(descriptor, maximum: Self.maximumArtifactBytes)
        guard let existing = String(data: data, encoding: .utf8) else {
            throw RCIRError.authorityDenied
        }
        for line in existing.split(separator: "\n", omittingEmptySubsequences: true) {
            if Data(line.utf8) == Data(proofID.utf8) {
                throw RCIRError.leaseUsed
            }
        }

        let entry = Data((proofID + "\n").utf8)
        guard data.count <= Self.maximumArtifactBytes - entry.count,
              lseek(descriptor, 0, SEEK_END) >= 0 else {
            throw RCIRError.invalidLimit
        }
        try writeAll(descriptor, entry)
        guard fsync(descriptor) == 0 else { throw RCIRError.authorityDenied }
    }

    private static func read(_ descriptor: Int32, maximum: Int) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw RCIRError.authorityDenied }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(16_384, maximum + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, buffer.count)
            }
            guard count >= 0 else { throw RCIRError.authorityDenied }
            if count == 0 { break }
            guard result.count <= maximum - count else { throw RCIRError.invalidLimit }
            result.append(buffer, count: count)
        }
        return result
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                guard let base = bytes.baseAddress else { throw RCIRError.authorityDenied }
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard count > 0 else { throw RCIRError.authorityDenied }
                offset += count
            }
        }
    }

    private static func writeExclusive(_ data: Data, to path: String, mode: mode_t) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw RCIRError.authorityDenied }
        defer { close(descriptor) }
        try writeAll(descriptor, data)
        guard fsync(descriptor) == 0 else { throw RCIRError.authorityDenied }
    }

    private static func temporaryDirectory() throws -> String {
        var template = Array((NSTemporaryDirectory() + "rightclick-actenon.XXXXXX").utf8CString)
        let root = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let pointer = mkdtemp(buffer.baseAddress) else { return nil }
            return String(cString: pointer)
        }
        guard let root else { throw RCIRError.authorityDenied }
        return root
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumArtifactBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RCIRError.authorityDenied
        }
        return object
    }

    private static func exactStringObject(_ actual: [String: Any], _ expected: [String: String]) -> Bool {
        let actualKeys = Set(actual.keys.map { Data($0.utf8) })
        let expectedKeys = Set(expected.keys.map { Data($0.utf8) })
        guard actualKeys == expectedKeys else { return false }
        for (key, value) in expected {
            guard let actualValue = actual.first(where: { Data($0.key.utf8) == Data(key.utf8) })?.value as? String,
                  exact(actualValue, value) else {
                return false
            }
        }
        return true
    }

    private static func safeProofID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func audience(_ raw: String) -> (type: String, id: String)? {
        guard let index = raw.firstIndex(of: ":") else {
            return raw.isEmpty ? nil : ("service", raw)
        }
        let type = String(raw[..<index])
        let id = String(raw[raw.index(after: index)...])
        return type.isEmpty || id.isEmpty ? nil : (type, id)
    }

    private static func exact(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return Data(lhs.utf8) == Data(rhs.utf8)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func rfc3339(milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
