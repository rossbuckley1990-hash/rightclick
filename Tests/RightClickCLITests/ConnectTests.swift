import Foundation
import XCTest
import RightClickCore
@testable import RightClickCLI

final class ConnectTests: XCTestCase {
    private final class Resolver: CapabilityArtifactResolver {
        let kind: String
        var received: [CapabilityArtifactDescriptor] = []
        var failure = false
        init(_ kind: String) { self.kind = kind }
        func resolve(_ descriptor: CapabilityArtifactDescriptor) throws -> any CapabilityReflector {
            received.append(descriptor)
            if failure { throw RightClickError("provider-secret-must-not-appear") }
            return Reflector()
        }
    }
    private final class Reflector: CapabilityReflector {
        let id = "fixture.current-declaration"
        func capabilities(for item: ContentItem) throws -> [Capability] {
            [Capability(id: "fixture.action", title: "Declared action", source: .system, safety: .read,
                        invocation: .direct, supportLevel: .publicSupported, requiresConfirmation: false)]
        }
        func begin(capability: Capability, item: ContentItem, executionID: String) throws -> ExecutionRecord {
            XCTFail("Connection must never invoke a capability")
            throw RightClickError("Unexpected execution")
        }
    }
    private let declaration = Data("""
        {"openapi":"3.0.3","info":{"title":"Fixture","version":"1"},"servers":[{"url":"https://provider.example/api"}],"paths":{"/current":{"get":{"operationId":"current","responses":{"200":{"description":"ok","content":{"application/json":{"schema":{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}}}}}}}}}
        """.utf8)

    private func file() throws -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("connect-tests-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("providers.json")
    }
    private func remove(_ file: URL) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    func testDirectOpenAPICompilesRealDeclarationBeforeDurableRegistration() throws {
        let destination = try file(); defer { remove(destination) }
        var output: [String] = []
        let registry = CapabilityArtifactResolverRegistry(resolvers: [OpenAPICapabilityArtifactResolver(specificationLoader: { _ in
            XCTFail("CLI must compile its acquired current bytes, not reacquire arbitrary data")
            return self.declaration
        })])
        let code = RightClickConnectCLI.run(["https://provider.example/openapi.json", "--id", "fixture", "--json"], file: destination,
            registry: registry, documentLoader: { _ in (self.declaration, 200) }, output: { output.append($0) })
        XCTAssertEqual(code, 0)
        let providers = try ConfiguredArtifactProviderStore.read(from: destination)
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].kind, "openapi")
        XCTAssertEqual(providers[0].specificationURL, "https://provider.example/openapi.json")
        XCTAssertNil(providers[0].inlineData)
        XCTAssertNil(providers[0].authorityScheme)
        XCTAssertTrue(output.joined().contains("CONNECTED"))
        XCTAssertTrue(output.joined().contains("NOT_RUN"))
    }

    func testOriginFindsSingleStandardManifestLink() throws {
        let destination = try file(); defer { remove(destination) }
        var fetched: [String] = []
        let resolver = Resolver("openapi")
        let code = RightClickConnectCLI.run(["https://provider.example", "--id", "fixture"], file: destination,
            registry: CapabilityArtifactResolverRegistry(resolvers: [resolver]), documentLoader: { url in
                fetched.append(url.absoluteString)
                if url.path == "/.well-known/rightclick" { return (Data("{\"schemaVersion\":1,\"links\":[{\"kind\":\"openapi\",\"url\":\"/openapi.json\"}]}".utf8), 200) }
                return (self.declaration, 200)
            }, output: { _ in })
        XCTAssertEqual(code, 0)
        XCTAssertEqual(fetched, ["https://provider.example/.well-known/rightclick", "https://provider.example/openapi.json"])
        XCTAssertEqual(resolver.received.count, 1)
        XCTAssertEqual(resolver.received[0].inlineData, declaration)
    }

    func testOriginFallbackOnlyAfterAbsentManifest() throws {
        let destination = try file(); defer { remove(destination) }
        var fetched: [URL] = []
        XCTAssertEqual(RightClickConnectCLI.run(["https://provider.example"], file: destination,
            registry: CapabilityArtifactResolverRegistry(resolvers: [Resolver("openapi")]), documentLoader: { url in
                fetched.append(url); return url.path == "/.well-known/rightclick" ? (Data(), 404) : (self.declaration, 200)
            }, output: { _ in }), 0)
        XCTAssertEqual(fetched.count, 2)
    }

    func testCredentialURLsRejectedBeforeAcquisitionAndNeverEchoed() throws {
        for target in ["https://user:password-secret@provider.example/openapi.json", "https://provider.example/openapi.json?token=query-secret", "https://provider.example/openapi.json#fragment-secret", "http://provider.example/openapi.json"] {
            let destination = try file(); defer { remove(destination) }
            var called = false; var output: [String] = []
            XCTAssertEqual(RightClickConnectCLI.run([target, "--json"], file: destination, documentLoader: { _ in
                called = true; return (self.declaration, 200)
            }, output: { output.append($0) }), 2)
            XCTAssertFalse(called)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertFalse(output.joined().contains("-secret"))
        }
    }

    func testCrossOriginServerAndManifestLinksDoNotRegisterOrFetchEscapedTarget() throws {
        for data in [Data("{\"schemaVersion\":1,\"links\":[{\"kind\":\"openapi\",\"url\":\"https://attacker.example/api\"}]}".utf8),
                     Data("{\"schemaVersion\":1,\"links\":[{\"kind\":\"openapi\",\"url\":\"/spec?token=secret\"}]}".utf8),
                     Data("{\"schemaVersion\":1,\"links\":[{\"kind\":\"wasm\",\"url\":\"file:///usr/bin/sh\"}]}".utf8)] {
            let destination = try file(); defer { remove(destination) }
            var requests = 0
            XCTAssertEqual(RightClickConnectCLI.run(["https://provider.example"], file: destination, documentLoader: { _ in
                requests += 1; return (data, 200)
            }, output: { _ in }, errorOutput: { _ in }), 2)
            XCTAssertEqual(requests, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        let destination = try file(); defer { remove(destination) }
        let escaped = Data(String(data: declaration, encoding: .utf8)!.replacingOccurrences(of: "https://provider.example/api", with: "https://attacker.example/api").utf8)
        XCTAssertEqual(RightClickConnectCLI.run(["https://provider.example/spec"], file: destination, documentLoader: { _ in (escaped, 200) }, output: { _ in }, errorOutput: { _ in }), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRedirectOversizeAndHTTPFailuresLeaveExistingRegistryIntact() throws {
        let destination = try file(); defer { remove(destination) }
        try ConfiguredArtifactProviderStore.upsert(CapabilityArtifactDescriptor(id: "old", kind: "mcp", endpointURL: "https://provider.example/mcp"), in: destination)
        let before = try Data(contentsOf: destination)
        for response in [(Data(), 302), (Data(repeating: 0, count: 1_048_577), 200), (Data(), 401)] {
            XCTAssertEqual(RightClickConnectCLI.run(["https://provider.example/spec"], file: destination, documentLoader: { _ in response }, output: { _ in }, errorOutput: { _ in }), 2)
            XCTAssertEqual(try Data(contentsOf: destination), before)
        }
    }

    func testCompilationFailureIsSanitizedAndPreservesRegistry() throws {
        let destination = try file(); defer { remove(destination) }
        let resolver = Resolver("openapi"); resolver.failure = true
        var output: [String] = []
        XCTAssertEqual(RightClickConnectCLI.run(["https://provider.example/spec", "--json"], file: destination,
            registry: CapabilityArtifactResolverRegistry(resolvers: [resolver]), documentLoader: { _ in (self.declaration, 200) }, output: { output.append($0) }), 2)
        XCTAssertFalse(output.joined().contains("provider-secret"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testGraphQLAndMCPUseGenericLiveResolverWithoutGETOrSecrets() throws {
        for kind in ["graphql", "mcp"] {
            let destination = try file(); defer { remove(destination) }
            let resolver = Resolver(kind)
            XCTAssertEqual(RightClickConnectCLI.run(["https://provider.example/" + kind, "--id", kind], file: destination,
                registry: CapabilityArtifactResolverRegistry(resolvers: [resolver]), documentLoader: { _ in
                    XCTFail("Live introspection/MCP negotiation belongs to the generic resolver"); return (Data(), 500)
                }, output: { _ in }), 0)
            let stored = try ConfiguredArtifactProviderStore.read(from: destination)
            XCTAssertEqual(stored.first?.kind, kind)
            XCTAssertNil(stored.first?.authorityScheme)
            XCTAssertEqual(resolver.received.count, 1)
        }
    }

    func testExplicitGRPCUsesGenericReflectionAndRejectsRemotePlaintext() throws {
        let destination = try file(); defer { remove(destination) }
        let resolver = Resolver("grpc")
        XCTAssertEqual(RightClickConnectCLI.run(["grpcs://provider.example:443", "--id", "grpc"], file: destination,
            registry: CapabilityArtifactResolverRegistry(resolvers: [resolver]), output: { _ in }), 0)
        XCTAssertEqual(resolver.received.first?.kind, "grpc")
        XCTAssertEqual(RightClickConnectCLI.run(["grpc://provider.example:443", "--id", "grpc"], file: destination,
            registry: CapabilityArtifactResolverRegistry(resolvers: [resolver]), output: { _ in }, errorOutput: { _ in }), 2)
        XCTAssertEqual(resolver.received.count, 1)
    }

    func testUnknownFlagsDuplicateFlagsAndUnsupportedStandardsFailBeforeAcquisition() throws {
        for suffix in [["--token", "secret"], ["--kind", "a2a"], ["--json", "--json"], ["--id", "bad/path"]] {
            let destination = try file(); defer { remove(destination) }
            XCTAssertEqual(RightClickConnectCLI.run(["https://provider.example/spec"] + suffix, file: destination, documentLoader: { _ in
                XCTFail("Invalid input must fail before acquisition"); return (self.declaration, 200)
            }, output: { _ in }, errorOutput: { _ in }), 2)
        }
    }

    func testRealMCPTransportConnectsDurablyAndIsDiscoverableInNewSource() throws {
        let destination = try file(); defer { remove(destination) }
        let evidence = destination.deletingLastPathComponent().appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        // The fixture directory is not the protected registry parent; establish
        // that parent's operator ownership before connection, as a real install
        // would do when creating its private Connections directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.deletingLastPathComponent().path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/acceptance-adoption-mcp-fixture.py").path, evidence.path, "connect-fixture-cookie"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let portFile = evidence.appendingPathComponent("port")
        let deadline = Date().addingTimeInterval(4)
        while !FileManager.default.fileExists(atPath: portFile.path) && process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let endpoint = "http://127.0.0.1:\(port)/mcp"
        var output: [String] = []
        XCTAssertEqual(RightClickConnectCLI.run([endpoint, "--id", "real-mcp", "--json"], file: destination, output: { output.append($0) }), 0)
        XCTAssertEqual(try ConfiguredArtifactProviderStore.read(from: destination).first?.endpointURL, endpoint)
        let source = ConfiguredArtifactProviderSource(configurationFile: destination)
        let reflectors = source.reflectors()
        XCTAssertEqual(reflectors.count, 1)
        let item = ContentItem(kind: "text", display: "connect acceptance", text: "connect acceptance", typeIdentifier: "public.plain-text")
        XCTAssertEqual(try reflectors.first?.capabilities(for: item).count, 1)
        XCTAssertTrue(output.joined().contains("CONNECTED"))
        XCTAssertTrue(try ConfiguredArtifactProviderStore.remove(id: "real-mcp", from: destination))
        XCTAssertTrue(source.reflectors().isEmpty, "A retained runtime must observe removal without restart.")
    }
}
