import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RightClickCore

final class ConnectedProviderStoreTests: XCTestCase {
    private func file() throws -> URL {
#if canImport(Darwin) || canImport(Glibc)
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw RightClickError("The fixture temporary directory could not be canonicalized.")
        }
        defer { free(path) }
        let parent = URL(fileURLWithPath: String(cString: path), isDirectory: true)
#else
        let parent = FileManager.default.temporaryDirectory
#endif
        return parent
            .appendingPathComponent("connected-store-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("providers.json")
    }
    private func provider(_ id: String = "fixture") -> CapabilityArtifactDescriptor {
        CapabilityArtifactDescriptor(id: id, kind: "mcp", endpointURL: "https://provider.example/mcp")
    }
    private final class Resolver: CapabilityArtifactResolver {
        let kind = "mcp"
        func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector { Reflector(id: descriptor.id) }
    }
    private final class Reflector: CapabilityReflector {
        let id: String
        init(id: String) { self.id = id }
        func capabilities(for item: ContentItem) throws -> [Capability] { [] }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord { throw RCIRError.unavailable }
    }

    func testStrictNumericVersionAcceptsOneAndRejectsBoolean() throws {
        let numeric = Data("{\"schemaVersion\":1,\"providers\":[]}".utf8)
        XCTAssertEqual(try ConfiguredArtifactProviderStore.decode(numeric), [])
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.decode(Data("{\"schemaVersion\":true,\"providers\":[]}".utf8)))
    }

    func testUnknownCredentialInlineAndExecutableFieldsRejected() {
        for field in ["token", "inlineData", "executable", "credentialFile"] {
            let raw = "{\"schemaVersion\":1,\"providers\":[{\"id\":\"fixture\",\"kind\":\"mcp\",\"endpointURL\":\"https://provider.example/mcp\",\"" + field + "\":\"secret\"}]}"
            XCTAssertThrowsError(try ConfiguredArtifactProviderStore.decode(Data(raw.utf8)))
        }
    }

#if canImport(Darwin) || canImport(Glibc)
    func testDefaultHomeKeepsCanonicalOperatorPathAndExplicitAliasStillFailsClosed() throws {
        let home = try file().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let destination = ConfiguredArtifactProviderStore.defaultFile(environment: environment)
        XCTAssertTrue(destination.path.hasPrefix(home.path + "/"),
            "Default registry construction must retain the canonical operator HOME spelling.")
        try ConfiguredArtifactProviderStore.upsert(provider(), in: destination)
        XCTAssertEqual(try ConfiguredArtifactProviderStore.read(from: destination), [provider()])
        let before = try Data(contentsOf: destination)

#if os(macOS)
        XCTAssertTrue(home.path.hasPrefix("/private/"), "Native temporary fixture must have a real canonical path.")
        let aliasHome = URL(fileURLWithPath: String(home.path.dropFirst("/private".count)), isDirectory: true)
        let aliasDestination = ConfiguredArtifactProviderStore.defaultFile(home: aliasHome, environment: environment)
        XCTAssertTrue(aliasDestination.path.hasPrefix(aliasHome.path + "/"), "An explicit path must never be silently rewritten.")
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.read(from: aliasDestination))
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.upsert(provider("unexpected"), in: aliasDestination))
        XCTAssertEqual(try Data(contentsOf: destination), before)
#else
        _ = before
#endif
    }

    func testProtectedRoundTripAndRemoval() throws {
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        XCTAssertEqual(try ConfiguredArtifactProviderStore.upsert(provider(), in: destination), [provider()])
        XCTAssertEqual(try ConfiguredArtifactProviderStore.read(from: destination), [provider()])
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: destination.deletingLastPathComponent().path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(try ConfiguredArtifactProviderStore.remove(id: "fixture", from: destination))
        XCTAssertEqual(try ConfiguredArtifactProviderStore.read(from: destination), [])
    }

    func testSymlinkAndHardlinkRegistryRefusedWithoutChangingTarget() throws {
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try ConfiguredArtifactProviderStore.upsert(provider(), in: destination)
        let original = try Data(contentsOf: destination)
        let target = destination.deletingLastPathComponent().appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: destination, to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.upsert(provider("new"), in: destination))
        XCTAssertEqual(try Data(contentsOf: target), original)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.linkItem(at: target, to: destination)
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.read(from: destination))
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.upsert(provider("new"), in: destination))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testLinkedDirectoryAndPublicFileRefused() throws {
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try ConfiguredArtifactProviderStore.upsert(provider(), in: destination)
        let linked = destination.deletingLastPathComponent().appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: destination.deletingLastPathComponent())
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.read(from: linked.appendingPathComponent("providers.json")))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.upsert(provider("new"), in: destination))
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.read(from: destination))
    }

    func testExistingMalformedRegistryIsNeverOverwritten() throws {
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try ConfiguredArtifactProviderStore.upsert(provider(), in: destination)
        let original = Data("invalid-secret".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.upsert(provider("new"), in: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testConcurrentTransactionFailsWithoutPartialPublication() throws {
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try ConfiguredArtifactProviderStore.upsert(provider(), in: destination)
        let before = try Data(contentsOf: destination)
        let lockedDirectory = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lockedDirectory, 0)
        guard lockedDirectory >= 0 else { return }
        defer { _ = flock(lockedDirectory, LOCK_UN); close(lockedDirectory) }
        XCTAssertEqual(flock(lockedDirectory, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try ConfiguredArtifactProviderStore.upsert(provider("new"), in: destination))
        XCTAssertEqual(try Data(contentsOf: destination), before)
    }

    func testSourceReloadsAdditionsAndWithdrawsRemovalAndMalformedConfiguration() throws {
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let source = ConfiguredArtifactProviderSource(configurationFile: destination, registry: CapabilityArtifactResolverRegistry(resolvers: [Resolver()]))
        XCTAssertEqual(source.reflectors().map(\.id), [])
        try ConfiguredArtifactProviderStore.upsert(provider(), in: destination)
        XCTAssertEqual(source.reflectors().map(\.id), ["fixture"])
        try ConfiguredArtifactProviderStore.upsert(provider("second"), in: destination)
        XCTAssertEqual(source.reflectors().map(\.id), ["fixture", "second"])
        try ConfiguredArtifactProviderStore.remove(id: "fixture", from: destination)
        XCTAssertEqual(source.reflectors().map(\.id), ["second"])
        try Data("{}".utf8).write(to: destination)
        XCTAssertEqual(source.reflectors().map(\.id), [])
        try FileManager.default.removeItem(at: destination)
        XCTAssertEqual(source.reflectors().map(\.id), [])
    }
#endif
}
