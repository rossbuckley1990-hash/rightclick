import Foundation
import XCTest
@testable import RightClickCore

final class BoundedCapabilityProcessDiagnosticTests: XCTestCase {
    func testTerminalMeasurementsContainNoArgumentsInputOutputOrErrorBytes() throws {
        let secret = "must-never-appear-in-diagnostic-" + UUID().uuidString
        var reports: [BoundedCapabilityProcess.Diagnostic] = []
        let bytes = try BoundedCapabilityProcess.run(executable: NativeHTTPFixture.python(),
            arguments: ["-c", "import sys; sys.stderr.write(sys.argv[1]); sys.stdout.buffer.write(sys.stdin.buffer.read())", secret],
            input: Data(secret.utf8), diagnostic: { reports.append($0) })
        XCTAssertEqual(bytes, Data(secret.utf8)); XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.outcome, .completed); XCTAssertTrue(report.started)
        XCTAssertEqual(report.terminationStatus, 0); XCTAssertEqual(report.stdoutBytes, secret.utf8.count)
        XCTAssertGreaterThanOrEqual(report.elapsedMilliseconds, try XCTUnwrap(report.launchMilliseconds))
        let encoded = try JSONEncoder().encode(report)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["elapsedMilliseconds", "launchMilliseconds", "started", "terminationStatus", "stdoutBytes", "outcome"])
    }

    func testDiagnosticSeparatesRealDeadlineExitAndInvalidInputWithoutChangingErrors() throws {
        var reports: [BoundedCapabilityProcess.Diagnostic] = []
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: NativeHTTPFixture.python(),
            arguments: ["-c", "import time; time.sleep(2)"], timeout: 0.05,
            diagnostic: { reports.append($0) })) { XCTAssertEqual($0 as? RCIRError, .invalidLimit) }
        XCTAssertEqual(reports.last?.outcome, .deadlineExceeded)
        XCTAssertEqual(reports.last?.started, true)
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: NativeHTTPFixture.python(),
            arguments: ["-c", "import sys; sys.stderr.write('private-error'); sys.exit(7)"],
            diagnostic: { reports.append($0) })) { XCTAssertEqual($0 as? RCIRError, .unavailable) }
        XCTAssertEqual(reports.last?.outcome, .childFailed)
        XCTAssertEqual(reports.last?.terminationStatus, 7)
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: NativeHTTPFixture.python(),
            arguments: [], timeout: .nan, diagnostic: { reports.append($0) })) {
            XCTAssertEqual($0 as? RCIRError, .invalidLimit)
        }
        XCTAssertEqual(reports.last?.outcome, .invalidConfiguration)
        XCTAssertEqual(reports.last?.started, false); XCTAssertEqual(reports.count, 3)
    }

    func testDeniedStartReportsNoLaunchAndProducesNoRealEffect() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let effect = directory.appendingPathComponent("effect")
        var report: BoundedCapabilityProcess.Diagnostic?
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: NativeHTTPFixture.python(),
            arguments: ["-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('effect')", effect.path],
            diagnostic: { report = $0 }, admitStart: { _ in throw RCIRError.authorityDenied })) {
            XCTAssertEqual($0 as? RCIRError, .authorityDenied)
        }
        XCTAssertEqual(report?.outcome, .admissionOrLaunchFailure)
        XCTAssertEqual(report?.started, false); XCTAssertNil(report?.launchMilliseconds)
        XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))
    }
}
