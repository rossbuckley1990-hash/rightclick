import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

final class NativeFixtureReadinessTests: XCTestCase {
    private func fixture(_ program: String, exercise: (URL, Process) throws -> Void) throws {
        let directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("native-readiness-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        let marker = directory.appendingPathComponent("port")
        try Data().write(to: marker)
        let process = Process()
        process.executableURL = try NativeHTTPFixture.python()
        process.arguments = ["-c", program, marker.path]
        process.standardOutput = FileHandle.nullDevice
        try NativeHTTPFixture.runFixture(process)
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? NativeHTTPFixture.remove(directory)
        }
        try exercise(marker, process)
    }

    func testEmptyExistingMarkerWaitsForCompleteDecimalPort() throws {
        try fixture("import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); time.sleep(.05); q=p.with_suffix('.tmp'); q.write_text('54321'); q.replace(p); time.sleep(3)") { marker, process in
            let started = ProcessInfo.processInfo.systemUptime
            let port = try NativeHTTPFixture.waitForPort(marker, process: process)
            XCTAssertEqual(port, 54321)
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.04)
            let address = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
            XCTAssertEqual(address.port, 54321)
        }
    }

    func testEmptyMarkerFailsWithinUnchangedBoundInsteadOfInventingReadiness() throws {
        try fixture("import time; time.sleep(3)") { marker, process in
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try NativeHTTPFixture.waitForPort(marker, process: process, timeout: 0.1))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        }
    }

    func testZeroOversizedAndNonDecimalMarkersCannotBecomePorts() throws {
        for value in ["0", "65536", "12345suffix", "-1", "12345\nextra",
                      "65535\r", "65535\r\r\n", "65535\r\nextra"] {
            try fixture("import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_bytes(" + String(reflecting: value) + ".encode('ascii')); time.sleep(3)") { marker, process in
                XCTAssertThrowsError(try NativeHTTPFixture.waitForPort(marker, process: process, timeout: 0.1))
            }
        }
    }

    func testExitedChildCannotPublishReadiness() throws {
        try fixture("import sys; sys.exit(7)") { marker, process in
            process.waitUntilExit()
            XCTAssertThrowsError(try NativeHTTPFixture.waitForPort(marker, process: process)) { error in
                guard case NativeHTTPFixture.ReadinessError.exitedBeforeReadiness = error else {
                    return XCTFail("Expected exited fixture readiness failure.")
                }
            }
        }
    }

    func testMaximumTCPPortWithSingleTerminatingNewlineIsAccepted() throws {
        try fixture("import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('65535\\n'); time.sleep(3)") { marker, process in
            XCTAssertEqual(try NativeHTTPFixture.waitForPort(marker, process: process), 65535)
        }
    }

    func testLFAndCRLFPortMarkersAreAcceptedWithoutTextModeTranslation() throws {
        for value in ["1\n", "65535\n", "1\r\n", "65535\r\n"] {
            try fixture("import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_bytes(" +
                        String(reflecting: value) + ".encode('ascii')); time.sleep(3)") { marker, process in
                let expected: UInt16 = value.hasPrefix("65535") ? 65535 : 1
                XCTAssertEqual(try NativeHTTPFixture.waitForPort(marker, process: process), expected)
            }
        }
    }

    func testReadinessFailureRetainsOnlyBoundedOwnerPrivateStderr() throws {
        let temporary = NativeHTTPFixture.temporaryDirectory
        func retainedDirectories() throws -> Set<URL> {
            Set(try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("rightclick-native-fixture-stderr-") })
        }
        // Readiness failure and asynchronous diagnostic capture are separate
        // observations. A slow child still cannot invent a ready TCP port.
        for startupDelay in [0.0, 0.25] {
            let before = try retainedDirectories()
            try fixture("import os,time; time.sleep(\(startupDelay)); os.write(2,b'fixture-private-canary-'+b'x'*100000); time.sleep(3)") { marker, process in
                XCTAssertThrowsError(try NativeHTTPFixture.waitForPort(marker, process: process, timeout: 0.1))
                let created = try retainedDirectories().subtracting(before)
                XCTAssertEqual(created.count, 1)
                let directory = try XCTUnwrap(created.first)
                defer { try? NativeHTTPFixture.remove(directory) }
                let privateFile = directory.appendingPathComponent("stderr.private")
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                var bytes = Data()
                repeat {
                    let handle = try FileHandle(forReadingFrom: privateFile)
                    bytes = try handle.read(upToCount: 65_537) ?? Data()
                    try handle.close()
                    if bytes.count == 65_536 { break }
                    Thread.sleep(forTimeInterval: min(0.01, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                } while ProcessInfo.processInfo.systemUptime < deadline
                XCTAssertEqual(bytes.count, 65_536)
                XCTAssertTrue(bytes.starts(with: Data("fixture-private-canary-".utf8)))
#if !os(Windows)
                let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
                let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: privateFile.path)[.posixPermissions] as? NSNumber)
                XCTAssertEqual(directoryMode.intValue, 0o700)
                XCTAssertEqual(fileMode.intValue, 0o600)
#endif
            }
        }
    }
}
