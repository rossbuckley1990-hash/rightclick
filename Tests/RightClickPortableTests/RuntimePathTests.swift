import Foundation
import XCTest
@testable import RightClickCore

extension RuntimePortabilityTests {
    func testPortableHomeExpansionUsesOnlyExplicitHome() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-home")
        XCTAssertEqual(ContentParser.expandHomePath("~", home: home), home.path)
        XCTAssertEqual(ContentParser.expandHomePath("~/child", home: home), home.appendingPathComponent("child").path)
        XCTAssertEqual(ContentParser.expandHomePath("ordinary text", home: home), "ordinary text")
#if os(Windows)
        XCTAssertEqual(ContentParser.expandHomePath("~\\child", home: home), home.appendingPathComponent("child").path)
        XCTAssertEqual(ContentParser.expandHomePath("~another-user", home: home), "~another-user")
#endif
    }

    func testNativeAbsoluteFilePathRoundTrips() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-path-" + UUID().uuidString)
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = try ContentParser.parse(file.path)
        XCTAssertNotNil(item.path)
        XCTAssertEqual(item.byteCount, 7)
        XCTAssertFalse(item.isDirectory)
        XCTAssertThrowsError(try ContentParser.parse(file.path + ".missing"))
    }
}
