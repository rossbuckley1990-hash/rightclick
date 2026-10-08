import RightClickProtocol
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if os(Windows)
import WinSDK
#endif

/// A host-selected, immutable snapshot for bounded installed-tool discovery.
/// This does not accept provider configuration or an arbitrary environment.
/// Production capability invocations remain isolated: before adopting a context
/// there, its identity must be bound into discovery, authority and revalidation.
struct TrustedHostProcessContext: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    enum KnownHostLocation: String, Sendable {
        case machineApplicationData
        case systemExecutableSearch
    }

    private let location: KnownHostLocation?
    private let path: String?
    /// Host-only binding material. Never emit the underlying host path.
    let identity: String

    static let isolated = TrustedHostProcessContext(location: nil, path: nil)

    private init(location: KnownHostLocation?, path: String?) {
        self.location = location; self.path = path
        let bytes = Data(("rightclick-trusted-host-context-v1\u{0}" +
            (location?.rawValue ?? "isolated") + "\u{0}" + (path ?? "")).utf8)
        identity = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    var description: String { "TrustedHostProcessContext(\(location?.rawValue ?? "isolated"))" }
    var debugDescription: String { description }

    static func resolving(_ location: KnownHostLocation) throws -> Self {
#if os(Windows)
        let path = try readKnownLocation(location)
        guard isExistingLocalDirectoryWithoutRedirects(path) else { throw RCIRError.unavailable }
        return Self(location: location, path: path)
#else
        throw RCIRError.unavailable
#endif
    }

    /// Values are private and mapped to one fixed key only. The caller owns the
    /// baseline; an isolated context cannot change it.
    func applying(to baseline: [String: String]) throws -> [String: String] {
        guard let location else { return baseline }
#if os(Windows)
        guard let path, isCurrent else { throw RCIRError.unavailable }
        var result = baseline
        switch location {
        case .machineApplicationData: result["ProgramData"] = path
        case .systemExecutableSearch: result["PATH"] = path
        }
        return result
#else
        throw RCIRError.unavailable
#endif
    }

    /// Windows names are case insensitive, but Foundation's ambient search
    /// fallback checks the exact spelling `Path`. Emit one canonical key with
    /// an explicit empty value when the host has granted no search directory.
    /// Reject aliases before dispatch; dictionary iteration cannot choose which
    /// authority-bearing value the native child receives.
    static func canonicalWindowsEnvironment(_ environment: [String: String]) throws -> [String: String] {
        var names = Set<String>(), result: [String: String] = [:]
        for (key, value) in environment {
            guard !value.utf8.contains(0), !key.isEmpty, key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                throw RCIRError.invalidIdentity
            }
            let identity = key.uppercased()
            guard names.insert(identity).inserted else { throw RCIRError.invalidIdentity }
            result[identity == "PATH" ? "Path" : key] = value
        }
        if result["Path"] == nil { result["Path"] = "" }
        return result
    }

    var isCurrent: Bool {
        guard let location else { return true }
#if os(Windows)
        guard let path, let current = try? Self.readKnownLocation(location),
              current.utf16.elementsEqual(path.utf16) else { return false }
        return Self.isExistingLocalDirectoryWithoutRedirects(path)
#else
        return false
#endif
    }

    /// Syntax validation alone confers no context or filesystem authority.
    static func isBoundedLocalDirectoryPath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard (3...4096).contains(bytes.count), path.utf16.count <= 4096,
              bytes.count >= 3, ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])),
              bytes[1] == 58, bytes[2] == 92 || bytes[2] == 47,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.contains("\""), !path.dropFirst(2).contains(":") else { return false }
        let components = path.dropFirst(3).split(whereSeparator: { $0 == "\\" || $0 == "/" })
        let normalized = path.replacingOccurrences(of: "/", with: "\\")
        return !normalized.dropFirst(3).contains("\\\\") &&
            !components.contains(where: { $0 == "." || $0 == ".." || $0.last == "." || $0.last == " " })
    }

    /// A search role carries exactly one directory, never a PATH list.
    static func isBoundedSingleSearchDirectoryPath(_ path: String) -> Bool {
        isBoundedLocalDirectoryPath(path) && !path.contains(";")
    }

#if os(Windows)
    /// Read exactly one reviewed nonsecret host key through the native API.
    /// Never enumerate/copy the ambient environment or read provider credentials.
    private static func readKnownLocation(_ location: KnownHostLocation) throws -> String {
        let keyName: String
        switch location {
        case .machineApplicationData: keyName = "ProgramData"
        case .systemExecutableSearch: keyName = "SystemRoot"
        }
        let name = Array(keyName.utf16) + [0]
        var buffer = [WCHAR](repeating: 0, count: 4097)
        let count = name.withUnsafeBufferPointer { key in
            buffer.withUnsafeMutableBufferPointer { value in
                GetEnvironmentVariableW(key.baseAddress, value.baseAddress, DWORD(value.count))
            }
        }
        guard count > 0, count <= 4096 else { throw RCIRError.unavailable }
        let observed = String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
        guard Array(observed.utf16).elementsEqual(buffer.prefix(Int(count))),
              isBoundedLocalDirectoryPath(observed) else { throw RCIRError.unavailable }
        let path: String
        switch location {
        case .machineApplicationData: path = observed
        case .systemExecutableSearch:
            guard isBoundedSingleSearchDirectoryPath(observed) else { throw RCIRError.unavailable }
            path = observed + "\\System32"
            guard isBoundedSingleSearchDirectoryPath(path) else { throw RCIRError.unavailable }
        }
        return path
    }

    private static func isExistingLocalDirectoryWithoutRedirects(_ path: String) -> Bool {
        guard isBoundedLocalDirectoryPath(path) else { return false }
        let normalized = path.replacingOccurrences(of: "/", with: "\\")
        var current = String(normalized.prefix(3))
        let components = normalized.dropFirst(3).split(separator: "\\")
        let paths = [current] + components.map { part in
            if !current.hasSuffix("\\") { current += "\\" }
            current += part
            return current
        }
        return paths.allSatisfy { candidate in
            let wide = Array(candidate.utf16) + [0]
            let attributes = wide.withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress) }
            return attributes != INVALID_FILE_ATTRIBUTES &&
                attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 &&
                attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
        }
    }
#endif
}
