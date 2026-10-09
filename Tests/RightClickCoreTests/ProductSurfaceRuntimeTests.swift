@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
import XCTest
@testable import RightClickCore

final class ProductSurfaceRuntimeTests: XCTestCase {
    func testRuntimeIdentityReportsExactExecutableBytes() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rightclick-runtime-\(UUID().uuidString)")

        let bytes = Data("RIGHTCLICK runtime proof\n".utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let runtime = RightClickRuntime.identity(
            transport: "test",
            executablePath: file.path,
            pid: 4242
        )

        XCTAssertEqual(runtime.product, "RIGHTCLICK")
        XCTAssertEqual(runtime.version, RightClickVersion.current)
        XCTAssertEqual(runtime.transport, "test")
        XCTAssertEqual(runtime.pid, 4242)
        XCTAssertEqual(runtime.executablePath, file.path)
        XCTAssertEqual(runtime.executableRealPath, file.path)

        XCTAssertEqual(
            runtime.executableSHA256,
            "d868484895a8878ad9858f1b13b202b1a904148d7458a3ef299278ac52cd564e"
        )
    }
}
