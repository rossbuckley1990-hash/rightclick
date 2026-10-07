import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RightClickCore

/// Real sockets exercise native URLSession delegates, including Swift protocol
/// dispatch on Linux and Windows. No URLProtocol or fabricated completion.
final class NativeBoundedHTTPTests: XCTestCase {
    private var directory: URL!
    private var process: Process!
    private var origin: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-bounded-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process = Process(); process.executableURL = try NativeHTTPFixture.python()
        process.arguments = [root.appendingPathComponent("scripts/native-http-transport-fixture.py").path, directory.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let port = directory.appendingPathComponent("port")
        for _ in 0..<300 { if FileManager.default.fileExists(atPath: port.path) { break }; Thread.sleep(forTimeInterval: 0.01) }
        origin = try XCTUnwrap(URL(string: "http://127.0.0.1:" + String(contentsOf: port, encoding: .utf8)))
    }
    override func tearDownWithError() throws {
        if process?.isRunning == true { process.terminate(); process.waitUntilExit() }
        if let directory { try NativeHTTPFixture.remove(directory) }
    }
    private func exchange(_ path: String, deadline: TimeInterval = 2) throws -> Data {
        let request = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
        return try OriginPinnedHTTP.exchange(request, maximumBytes: 64, deadline: deadline).0
    }
    func testNativeCompletionReleasesWaiterAndReturnsExactCap() throws {
        for _ in 0..<3 { XCTAssertEqual(try exchange("/ok"), Data(repeating: 120, count: 64)) }
        let requests = try String(contentsOf: directory.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertEqual(requests.split(separator: "\n").count, 3)
    }
    func testNativeErrorAndPrematureConnectionCloseRemainFailures() throws {
        XCTAssertThrowsError(try exchange("/error"))
        XCTAssertThrowsError(try exchange("/early-close"))
    }
    func testDeclaredAndChunkedOversizeNeverReturnAnAdmittedPrefix() throws {
        XCTAssertThrowsError(try exchange("/declared-oversize"))
        XCTAssertThrowsError(try exchange("/chunked-oversize"))
    }
    func testRedirectNeverReachesNewTarget() throws {
        XCTAssertThrowsError(try exchange("/redirect"))
        let requests = try String(contentsOf: directory.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertEqual(requests, "/redirect\n")
    }
    func testDeadlineCancelsNativeExchangeWithinBound() throws {
        let start = Date()
        XCTAssertThrowsError(try exchange("/slow", deadline: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}
