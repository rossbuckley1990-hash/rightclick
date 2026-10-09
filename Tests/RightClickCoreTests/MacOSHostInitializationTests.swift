#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import RightClickCore

final class MacOSHostInitializationTests: XCTestCase {
    func testBackgroundPortableEnginePreparationThenNativeServiceInFreshProcess() async throws {
        let childMarker = "RIGHTCLICK_TEST_NATIVE_PREPARATION_CHILD"
        if ProcessInfo.processInfo.environment[childMarker] == "1" {
            // A fresh child prevents earlier native tests from hiding first
            // application initialization on a portable worker task.
            await Task.detached {
                XCTAssertFalse(Thread.isMainThread)
                _ = CapabilityEngine(reflectors: [], experience: nil)
            }.value
            try await MainActor.run {
                XCTAssertTrue(Thread.isMainThread)
                let engine = CapabilityEngine(experience: nil)
                let record = try engine.begin(
                    id: "service:com.apple.ChineseTextConverterService:convertTextToFullWidth",
                    item: "RightClick", confirmed: true,
                    verification: .init(predicates: [.init(type: .textEquals, value: "ＲｉｇｈｔＣｌｉｃｋ")],
                        timeoutMilliseconds: 0))
                XCTAssertEqual(record.state, .succeeded)
                XCTAssertEqual(record.verification?.status, .verifiedSuccess)
                XCTAssertTrue(record.evidence.outcomeVerified)
            }
            return
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let bundle = Bundle(for: Self.self).bundleURL
        var environment = ProcessInfo.processInfo.environment
        environment[childMarker] = "1"
        let status = try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("rightclick-native-preparation-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("child.log")
            guard FileManager.default.createFile(atPath: output.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw RightClickError("Native regression log unavailable.") }
            let log = try FileHandle(forWritingTo: output)
            defer { try? log.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-XCTest",
                "RightClickCoreTests.MacOSHostInitializationTests/testBackgroundPortableEnginePreparationThenNativeServiceInFreshProcess",
                bundle.path]
            process.environment = environment
            process.standardOutput = log
            process.standardError = log
            try process.run()
            let deadline = Date().addingTimeInterval(45)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning, Date() < grace { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw RightClickError("Native preparation child exceeded its deadline.")
            }
            process.waitUntilExit()
            let bytes = try Data(contentsOf: output)
            return (process.terminationStatus, String(decoding: bytes.prefix(32_768), as: UTF8.self))
        }.value
        XCTAssertEqual(status.0, 0, "Isolated background preparation/native Service failed: " + status.1)
    }
}
#endif
