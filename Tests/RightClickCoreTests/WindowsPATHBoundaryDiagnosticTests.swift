import Foundation
import XCTest
@testable import RightClickCore
#if os(Windows)
import WinSDK

/// Owned diagnostic only. Shipping Sources and the failed shipping assertion
/// remain unchanged. Native PATH bytes never enter logs or evidence projections.
final class WindowsPATHBoundaryDiagnosticTests: XCTestCase {
    private static let mutationLock = NSLock()
    private struct NativeValue {
        let units: [WCHAR]?
        var digest: String {
            guard let units else { return "none" }
            return units.withUnsafeBytes { CapabilityJSON.digest(Data($0)) }
        }
    }

    private func readPATH() throws -> NativeValue {
        let key = Array("PATH".utf16) + [0]
        SetLastError(DWORD(ERROR_SUCCESS))
        let needed = key.withUnsafeBufferPointer { GetEnvironmentVariableW($0.baseAddress, nil, 0) }
        if needed == 0 {
            let code = GetLastError()
            guard code == DWORD(ERROR_ENVVAR_NOT_FOUND) || code == DWORD(ERROR_SUCCESS) else { throw RCIRError.unavailable }
            return NativeValue(units: code == DWORD(ERROR_ENVVAR_NOT_FOUND) ? nil : [])
        }
        guard needed <= 32_768 else { throw RCIRError.invalidLimit }
        var buffer = [WCHAR](repeating: 0, count: Int(needed))
        SetLastError(DWORD(ERROR_SUCCESS))
        let count = key.withUnsafeBufferPointer { name in
            buffer.withUnsafeMutableBufferPointer { GetEnvironmentVariableW(name.baseAddress, $0.baseAddress, DWORD($0.count)) }
        }
        guard count < needed, count <= 32_767, (count > 0 || GetLastError() == DWORD(ERROR_SUCCESS)) else { throw RCIRError.unavailable }
        return NativeValue(units: Array(buffer.prefix(Int(count))))
    }

    private func setPATH(_ value: NativeValue) throws {
        let key = Array("PATH".utf16) + [0]
        let success = key.withUnsafeBufferPointer { name in
            if let units = value.units {
                return (units + [0]).withUnsafeBufferPointer { SetEnvironmentVariableW(name.baseAddress, $0.baseAddress) }
            }
            return SetEnvironmentVariableW(name.baseAddress, nil)
        }
        guard success else { throw RCIRError.unavailable }
    }

    private func readSystemRoot() throws -> String {
        let key = Array("SystemRoot".utf16) + [0]
        var buffer = [WCHAR](repeating: 0, count: 4097)
        let count = key.withUnsafeBufferPointer { name in
            buffer.withUnsafeMutableBufferPointer { GetEnvironmentVariableW(name.baseAddress, $0.baseAddress, DWORD($0.count)) }
        }
        guard count > 0, count <= 4096 else { throw RCIRError.unavailable }
        let value = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
        guard value.utf16.elementsEqual(buffer.prefix(Int(count))),
              TrustedHostProcessContext.isBoundedSingleSearchDirectoryPath(value) else { throw RCIRError.unavailable }
        return value
    }

    private func requireLocalDirectory(_ directory: URL) throws {
        let path = directory.path.replacingOccurrences(of: "/", with: "\\")
        guard TrustedHostProcessContext.isBoundedSingleSearchDirectoryPath(path) else { throw RCIRError.unavailable }
        var current = String(path.prefix(3))
        let components = path.dropFirst(3).split(separator: "\\")
        let paths = [current] + components.map { part in
            if !current.hasSuffix("\\") { current += "\\" }
            current += part
            return current
        }
        for path in paths {
            let attributes = (Array(path.utf16) + [0]).withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress) }
            guard attributes != INVALID_FILE_ATTRIBUTES,
                  attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
                  attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else { throw RCIRError.unavailable }
        }
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data(), exceeded = false
        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            if bytes.count + data.count > 512 { exceeded = true }
            if bytes.count < 512 { bytes.append(data.prefix(512 - bytes.count)) }
        }
        func snapshot() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (bytes, exceeded) }
    }

    /// This sample changes only the omitted PATH to an explicit empty value in
    /// an otherwise fixed Foundation environment. It does not use a new BPC role.
    private func directFoundationEmptyPATH(_ executable: URL, arguments: [String]) throws -> Data {
        let root = try readSystemRoot()
        let process = Process(), pipe = Pipe(), capture = Capture(), drained = DispatchGroup(), exited = DispatchGroup()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ["SystemRoot": root, "TEMP": FileManager.default.temporaryDirectory.path,
                               "TMP": FileManager.default.temporaryDirectory.path, "PATH": ""]
        process.standardOutput = pipe; process.standardInput = FileHandle.nullDevice
        let stderr = try XCTUnwrap(FileHandle(forWritingAtPath: "\\\\.\\NUL"))
        defer { try? stderr.close() }
        guard GetFileType(stderr._handle) == FILE_TYPE_CHAR else { throw RCIRError.unavailable }
        process.standardError = stderr
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.leave() }
            while true {
                let bytes = pipe.fileHandleForReading.readData(ofLength: 4096)
                if bytes.isEmpty { break }
                capture.append(bytes)
            }
        }
        do { try process.run() } catch { try? pipe.fileHandleForWriting.close(); throw error }
        exited.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.leave()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while exited.wait(timeout: .now()) != .success {
            if DispatchTime.now().uptimeNanoseconds >= deadline || capture.snapshot().1 {
                let cleanupDeadline = DispatchTime.now() + 2
                process.terminate()
                if exited.wait(timeout: .now() + 0.020) != .success { process.terminate() }
                let parentClosed = exited.wait(timeout: .now() + 1) == .success
                try? pipe.fileHandleForWriting.close()
                let drainClosed = drained.wait(timeout: cleanupDeadline) == .success
                print("NativePATHBoundary directEmptyAborted parentClosed=\(parentClosed) stdoutClosed=\(drainClosed) executionBudgetSeconds=5 teardownBudgetSeconds=2 diagnosticOnly=true")
                throw RCIRError.invalidLimit
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        try? pipe.fileHandleForWriting.close()
        guard process.terminationStatus == 0, drained.wait(timeout: .now() + 1) == .success,
              !capture.snapshot().1 else { throw RCIRError.unavailable }
        return capture.snapshot().0
    }

    private func project(_ data: Data, profile: String) throws {
        guard data.count <= 512,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == Set(["present", "empty", "system32Match", "ownedParentMatch", "originalParentMatch", "units", "sha256"]),
              let present = value["present"] as? Bool, let empty = value["empty"] as? Bool,
              let system = value["system32Match"] as? Bool, let owned = value["ownedParentMatch"] as? Bool,
              let original = value["originalParentMatch"] as? Bool,
              let units = value["units"] as? Int, (0...32_767).contains(units),
              let digest = value["sha256"] as? String,
              digest == "none" || (digest.count == 64 && digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })) else { throw RCIRError.unavailable }
        let hexDigest = digest.count == 64 && digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        guard (present ? hexDigest : digest == "none" && units == 0 && !empty && !system && !owned && !original),
              empty == (present && units == 0), !system || present && !empty,
              !owned || present && !empty, !original || present else { throw RCIRError.unavailable }
        print("NativePATHBoundary profile=\(profile) present=\(present) empty=\(empty) system32Match=\(system) ownedParentMatch=\(owned) originalParentMatch=\(original) units=\(units) sha256=\(digest) parentAndStdoutClosed=true ownedGroupClosureClaimed=false")
    }

    func testOwnedNativePATHOriginCounterfactualPreservesShippingSourcesAndParentSnapshot() throws {
        Self.mutationLock.lock(); defer { Self.mutationLock.unlock() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-native-path-origin-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        try requireLocalDirectory(directory)
        let script = directory.appendingPathComponent("fixed-unused-script.py")
        try NativeHTTPFixture.writePrivate(Data("# owned native PATH diagnostic; not executed\n".utf8), to: script)
        let inputs = try NativeHTTPFixture.compilerInputs(script: script, directory: directory)
        try NativeHTTPFixture.replacePrivate(Data(Self.nativeProbe.utf8), at: inputs.source)
        let frozen = try inputs.frozenInputs.map { try CapabilityArtifactSnapshot.read(source: $0.0, maximum: $0.1) }
        let compilerArguments = inputs.ownedArguments.map { Array($0.utf16) }
        guard !FileManager.default.fileExists(atPath: inputs.client.path), !FileManager.default.fileExists(atPath: inputs.object.path) else { throw RCIRError.unavailable }
        var compiler: BoundedCapabilityProcess.Diagnostic?
        _ = try BoundedCapabilityProcess.runForHostAcquisition(executable: inputs.executable,
            arguments: inputs.ownedArguments, timeout: 30, maximumBytes: 16_384, diagnostic: { compiler = $0 })
        let binary = try CapabilityArtifactSnapshot.read(source: inputs.client, maximum: 8_388_608)
        guard NativeHTTPFixture.isAMD64PE(binary), binary == (try CapabilityArtifactSnapshot.read(source: inputs.client, maximum: 8_388_608)),
              let compiler, compiler.started, compiler.outcome == .completed, compiler.terminationStatus == 0,
              compiler.stdoutBytes <= 16_384,
              inputs.ownedArguments.map({ Array($0.utf16) }) == compilerArguments,
              try inputs.frozenInputs.enumerated().allSatisfy({ try CapabilityArtifactSnapshot.read(source: $0.element.0, maximum: $0.element.1) == frozen[$0.offset] }) else { throw RCIRError.unavailable }
        print("NativePATHBoundary compilerCompleted exit=0 elapsedMilliseconds=\(compiler.elapsedMilliseconds) freshPE=true stableOutput=true unchangedInputs=true sameArguments=true outputSHA256=\(CapabilityJSON.digest(binary)) parentAndStdoutClosed=true ownedGroupClosureClaimed=false")
        let owned = directory.appendingPathComponent("parent-search-sentinel")
        try NativeHTTPFixture.createPrivateDirectory(owned); try requireLocalDirectory(owned)
        let original = try readPATH()
        let sentinel = NativeValue(units: Array(owned.path.replacingOccurrences(of: "/", with: "\\").utf16))
        let search = try TrustedHostProcessContext.resolving(.systemExecutableSearch)
        let arguments = [String(decoding: sentinel.units!, as: UTF16.self), original.digest]
        let frozenArguments = arguments.map { Array($0.utf16) }
        try setPATH(sentinel)
        defer {
            do { try setPATH(original); XCTAssertEqual(try readPATH().units, original.units) }
            catch { XCTFail("NativePATHBoundary exact parent restoration failed") }
        }
        let contexts = [TrustedHostProcessContext.isolated, search, .isolated]
        let profiles = ["isolatedBefore", "explicitSystemSearch", "isolatedAfter"]
        for index in 0..<3 {
            guard try readPATH().units == sentinel.units,
                  arguments.map({ Array($0.utf16) }) == frozenArguments,
                  binary == (try CapabilityArtifactSnapshot.read(source: inputs.client, maximum: 8_388_608)) else { throw RCIRError.unavailable }
            var diagnostic: BoundedCapabilityProcess.Diagnostic?
            let output = try BoundedCapabilityProcess.run(executable: inputs.client, arguments: arguments,
                timeout: 5, maximumBytes: 512, hostContext: contexts[index], diagnostic: { diagnostic = $0 })
            guard let diagnostic, diagnostic.started, diagnostic.outcome == .completed,
                  diagnostic.terminationStatus == 0 else { throw RCIRError.unavailable }
            try project(output, profile: profiles[index])
        }
        guard try readPATH().units == sentinel.units else { throw RCIRError.unavailable }
        try project(directFoundationEmptyPATH(inputs.client, arguments: arguments), profile: "directFoundationEmptyPATH")
        guard arguments.map({ Array($0.utf16) }) == frozenArguments,
              binary == (try CapabilityArtifactSnapshot.read(source: inputs.client, maximum: 8_388_608)),
              try inputs.frozenInputs.enumerated().allSatisfy({ try CapabilityArtifactSnapshot.read(source: $0.element.0, maximum: $0.element.1) == frozen[$0.offset] }) else { throw RCIRError.unavailable }
        try setPATH(original)
        XCTAssertEqual(try readPATH().units, original.units)
        print("NativePATHBoundary evidenceClosed unchangedBinary=true unchangedInputs=true sameArguments=true restoredParentExactUTF16=true productionSourcesUnchanged=true diagnosticOnly=true")
    }

    private static let nativeProbe = #"""
    #define WIN32_LEAN_AND_MEAN
    #include <windows.h>
    #include <bcrypt.h>
    #include <stdio.h>
    #include <string.h>
    #include <wchar.h>
    #pragma comment(lib, "bcrypt.lib")
    static int digest_utf16(const WCHAR *value, DWORD count, char hex[65]) {
        BCRYPT_ALG_HANDLE algorithm = NULL; BCRYPT_HASH_HANDLE hash = NULL;
        ULONG length = 0, returned = 0; PUCHAR object = NULL; unsigned char result[32]; int status = 1;
        if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0) goto done;
        if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&length, sizeof(length), &returned, 0) < 0 || returned != sizeof(length) || length > 1048576) goto done;
        object = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, length); if (!object) goto done;
        if (BCryptCreateHash(algorithm, &hash, object, length, NULL, 0, 0) < 0 ||
            BCryptHashData(hash, (PUCHAR)value, count * sizeof(WCHAR), 0) < 0 ||
            BCryptFinishHash(hash, result, sizeof(result), 0) < 0) goto done;
        for (int i = 0; i < 32; ++i) sprintf_s(hex + 2*i, 65 - 2*i, "%02x", result[i]);
        hex[64] = 0; status = 0;
    done:
        if (hash) BCryptDestroyHash(hash); if (object) HeapFree(GetProcessHeap(), 0, object);
        if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0); return status;
    }
    int wmain(int argc, WCHAR **argv) {
        WCHAR value[32768], root[4097], system[4110]; char hex[65] = "none", expected[65];
        if (argc != 3 || wcslen(argv[1]) > 4096 || wcslen(argv[2]) > 64) return 70;
        char control[65];
        if (digest_utf16(L"", 0, control) || strcmp(control, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")) return 76;
        SetLastError(ERROR_SUCCESS); DWORD needed = GetEnvironmentVariableW(L"PATH", NULL, 0), error = GetLastError();
        int present = needed != 0 || error == ERROR_SUCCESS; DWORD count = 0;
        if (needed > 32768 || (!needed && error != ERROR_SUCCESS && error != ERROR_ENVVAR_NOT_FOUND)) return 71;
        if (needed) {
            SetLastError(ERROR_SUCCESS); count = GetEnvironmentVariableW(L"PATH", value, 32768);
            if (count >= 32768 || (!count && GetLastError() != ERROR_SUCCESS)) return 72;
        } else value[0] = 0;
        if (present && digest_utf16(value, count, hex)) return 73;
        DWORD root_count = GetEnvironmentVariableW(L"SystemRoot", root, 4097);
        if (!root_count || root_count > 4096 || wcscpy_s(system, 4110, root) || wcscat_s(system, 4110, L"\\System32")) return 74;
        size_t expected_count = wcslen(argv[2]);
        for (size_t i = 0; i < expected_count; ++i) { if (argv[2][i] > 127) return 75; expected[i] = (char)argv[2][i]; }
        expected[expected_count] = 0;
        printf("{\"present\":%s,\"empty\":%s,\"system32Match\":%s,\"ownedParentMatch\":%s,\"originalParentMatch\":%s,\"units\":%lu,\"sha256\":\"%s\"}\n",
            present ? "true" : "false", present && count == 0 ? "true" : "false",
            present && count == wcslen(system) && memcmp(value, system, count*sizeof(WCHAR)) == 0 ? "true" : "false",
            present && count == wcslen(argv[1]) && memcmp(value, argv[1], count*sizeof(WCHAR)) == 0 ? "true" : "false",
            present && strcmp(hex, expected) == 0 ? "true" : "false", (unsigned long)count, hex);
        return 0;
    }
    """#
}
#endif
