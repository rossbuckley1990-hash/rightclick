import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

final class PortableRuntimeTests: XCTestCase {
    func testNativeJSONBooleanIdentityCannotBecomeNumericLength() throws {
        let payload = Data("[true,false,0,1,-1,1.5]".utf8)
        let values = try JSONSerialization.jsonObject(with: payload) as! [NSNumber]
        XCTAssertEqual(values.map(CapabilityJSONNumber.isBoolean), [true, true, false, false, false, false])
        let typed = try CapabilityJSON.value(values)
        XCTAssertEqual(try typed.canonicalData(), try CapabilityValue.array([.boolean(true), .boolean(false), .integer(0), .integer(1), .integer(-1), .number(1.5)]).canonicalData())
        for number in [NSNumber(value: true), NSNumber(value: false)] {
            XCTAssertThrowsError(try CapabilitySchema.stringContract(["type": "string", "minLength": number]))
            XCTAssertThrowsError(try CapabilitySchema.stringContract(["type": "string", "maxLength": number]))
        }
        for number in [NSNumber(value: Int8(0)), NSNumber(value: UInt8(1)), NSNumber(value: Int64(1))] {
            XCTAssertFalse(CapabilityJSONNumber.isBoolean(number))
            XCTAssertNoThrow(try CapabilitySchema.stringContract(["type": "string", "minLength": number]))
        }
    }

    func testStableTextAndURLClassification() throws {
        let text = try ContentParser.parse("portable 🧭")
        XCTAssertEqual(text.typeIdentifier, "public.plain-text")
        XCTAssertEqual(text.byteCount, "portable 🧭".utf8.count)
        XCTAssertEqual(try ContentParser.parse("https://example.com").typeIdentifier, "public.url")
    }

    func testFilesAndUnknownExtensionsAreConservative() throws {
        let root = NativeHTTPFixture.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let home = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("portable-home")
        let empty = RuntimePlatform.supportDirectory(home: home, environment: [:])
        let relative = RuntimePlatform.supportDirectory(home: home,
            environment: ["XDG_CONFIG_HOME": "relative", "LOCALAPPDATA": "relative"])
        XCTAssertEqual(empty, relative)
#if os(macOS)
        XCTAssertEqual(empty.path, home.appendingPathComponent("Library/Application Support/RIGHTCLICK").path)
#elseif os(Windows)
        XCTAssertEqual(empty.path, home.appendingPathComponent("AppData/Local/RIGHTCLICK").path)
#else
        XCTAssertEqual(empty.path, home.appendingPathComponent(".config/rightclick").path)
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
