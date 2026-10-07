import Foundation
import XCTest
@testable import RightClickCore

final class PortableRuntimeTests: XCTestCase {
    func testStableTextAndURLClassification() throws {
        let text = try ContentParser.parse("portable 🧭")
        XCTAssertEqual(text.typeIdentifier, "public.plain-text")
        XCTAssertEqual(text.byteCount, "portable 🧭".utf8.count)
        XCTAssertEqual(try ContentParser.parse("https://example.com").typeIdentifier, "public.url")
    }

    func testFilesAndUnknownExtensionsAreConservative() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("unknown type.opaque-rightclick")
        try Data([0, 1, 2]).write(to: path)
        let item = try ContentParser.parse(path.path)
        XCTAssertEqual(item.kind, "file")
        XCTAssertEqual(item.byteCount, 3)
        XCTAssertEqual(try ContentParser.parse(root.path).kind, "directory")
    }

    func testHostStorageDoesNotAcceptRelativeEnvironmentPaths() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("portable-home")
        let empty = RuntimePlatform.supportDirectory(home: home, environment: [:])
        let relative = RuntimePlatform.supportDirectory(home: home,
            environment: ["XDG_STATE_HOME": "relative", "LOCALAPPDATA": "relative"])
        XCTAssertEqual(empty, relative)
#if os(macOS)
        XCTAssertEqual(empty.path, home.appendingPathComponent("Library/Application Support/RIGHTCLICK").path)
#elseif os(Windows)
        XCTAssertEqual(empty.path, home.appendingPathComponent("AppData/Local/RIGHTCLICK").path)
#else
        XCTAssertEqual(empty.path, home.appendingPathComponent(".local/state/rightclick").path)
#endif
    }

    func testNativeCatalogIsAbsentOnOtherHosts() throws {
#if !os(macOS)
        let engine = CapabilityEngine(experience: nil)
        XCTAssertTrue(try engine.capabilities(for: "portable").capabilities.isEmpty)
        XCTAssertEqual(engine.doctor().servicesDiscovery, "UNAVAILABLE")
        XCTAssertEqual(engine.doctor().platform, RuntimePlatform.name)
#endif
    }

    func testPKCEUsesPortableCryptographicRandomness() throws {
        let first = try OAuthPKCE.generate()
        let second = try OAuthPKCE.generate()
        XCTAssertEqual(first.codeVerifier.count, 43)
        XCTAssertNotEqual(first.codeVerifier, second.codeVerifier)
    }

    func testUnavailableSecureStorageAbstains() throws {
#if !canImport(Security)
        XCTAssertThrowsError(try OpenAPIAuthorityStore.setBearerToken("test", origin: "https://example.com", schemeName: "bearer"))
#endif
    }
}
