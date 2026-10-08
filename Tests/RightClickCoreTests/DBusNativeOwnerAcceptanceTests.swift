import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

final class DBusNativeOwnerAcceptanceTests: XCTestCase {
#if os(Linux)
    private final class Fixture {
        let directory: URL
        let script: String
        var bus: Process?
        var service: Process?
        init() throws {
            directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("rightclick-dbus-owner-" + UUID().uuidString)
            script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/dbus-private-fixture.py").path
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for path in ["state", "records"] { try FileManager.default.createDirectory(at: directory.appendingPathComponent(path), withIntermediateDirectories: false) }
            try startBus(); try startService()
        }
        var address: String { "unix:path=" + directory.appendingPathComponent("bus").path }
        var environment: [String: String] { ["DBUS_SESSION_BUS_ADDRESS": address, "RIGHTCLICK_DBUS_INVOCATION_ARGUMENT": "invocation"] }
        func wait(_ url: URL, process: Process) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !FileManager.default.fileExists(atPath: url.path) {
                guard process.isRunning, ProcessInfo.processInfo.systemUptime < deadline else { throw RCIRError.unavailable }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        func startBus() throws {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("bus"))
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/dbus-daemon")
            process.arguments = ["--session", "--nofork", "--address=" + address]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); bus = process; try wait(directory.appendingPathComponent("bus"), process: process)
        }
        func startService() throws {
            let ready = directory.appendingPathComponent("state/service-ready"); try? FileManager.default.removeItem(at: ready)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script, directory.path, "service"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); service = process; try wait(ready, process: process)
        }
        func stopService() { if let service, service.isRunning { service.terminate(); service.waitUntilExit() }; service = nil }
        func releaseName() throws {
            try Data().write(to: directory.appendingPathComponent("release-name"))
            guard let service else { throw RCIRError.unavailable }
            try wait(directory.appendingPathComponent("state/service-released"), process: service)
        }
        func restartBusAndOwner() throws {
            stopService(); if let bus, bus.isRunning { bus.terminate(); bus.waitUntilExit() }; bus = nil
            try startBus(); try startService()
        }
        deinit { stopService(); if let bus, bus.isRunning { bus.terminate(); bus.waitUntilExit() }; try? FileManager.default.removeItem(at: directory) }
    }
    private func fixture() throws -> Fixture {
        guard ProcessInfo.processInfo.environment["RIGHTCLICK_TEST_DBUS_NATIVE"] == "1" else {
            throw XCTSkip("Private real D-Bus fixture not requested; this skip is not native Linux proof.")
        }
        return try Fixture()
    }
    func testActualOwnerWithdrawalAtFinalGateCannotConsumeOrMutate() throws {
        let fixture = try fixture(), resolver = DBusCapabilityArtifactResolver(environment: fixture.environment)
        let reflected = try resolver.resolve(.init(id: "actual-owner", kind: "dbus", endpointURL: "dbus://org.rightclick.Pressure/org/rightclick/Pressure")) as! any RCIRExecutionReflector
        let item = try ContentParser.parse("actual owner withdrawal")
        let capability = try reflected.capabilities(for: item).first { $0.title == "Store" }!
        let host = RCIRExecutionHost(); host.configuration = { RCIRHostConfiguration() }
        var reachedFinalGate = false
        let oldOwner = try resolver.owner("org.rightclick.Pressure")
        host.beforeStart = { _, admit, start in
            reachedFinalGate = true
            try fixture.releaseName()
            XCTAssertFalse(try resolver.introspect(owner: oldOwner, path: "/org/rightclick/Pressure").isEmpty)
            XCTAssertThrowsError(try resolver.owner("org.rightclick.Pressure"))
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(start) { enqueue in try permit(enqueue) }
            }
        }
        let result = try reflected.admittedBegin(capability: capability, admissionOwner: capability, item: item,
            executionID: "actual-withdrawal", arguments: ["challenge": String(repeating: "a", count: 32), "value": "no-effect", "enabled": "[\"boolean\",true]"],
            verification: nil, expectedOutput: nil, host: host, revalidate: { true })
        XCTAssertTrue(reachedFinalGate); XCTAssertNotEqual(result.rcir?.leaseConsumed, true)
        XCTAssertEqual(result.state, .rejected); XCTAssertFalse(result.events.contains { $0.contains("RCIR consumed lease=") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("state/effects.jsonl").path))
    }
    func testActualBusRestartReusesOwnerNameButInvalidatesOldAdmission() throws {
        let fixture = try fixture(), resolver = DBusCapabilityArtifactResolver(environment: fixture.environment)
        let reflected = try resolver.resolve(.init(id: "actual-broker", kind: "dbus", endpointURL: "dbus://org.rightclick.Pressure/org/rightclick/Pressure")) as! any RCIRExecutionReflector
        let item = try ContentParser.parse("actual broker incarnation")
        let capability = try reflected.capabilities(for: item).first { $0.title == "Store" }!
        let oldBus = try resolver.busID(), oldOwner = try resolver.owner("org.rightclick.Pressure")
        let host = RCIRExecutionHost(); host.configuration = { RCIRHostConfiguration() }
        var reachedFinalGate = false
        host.beforeStart = { _, admit, start in
            reachedFinalGate = true
            try fixture.restartBusAndOwner()
            XCTAssertEqual(try resolver.owner("org.rightclick.Pressure"), oldOwner)
            XCTAssertNotEqual(try resolver.busID(), oldBus)
            try withoutActuallyEscaping(admit) { permit in
                try withoutActuallyEscaping(start) { enqueue in try permit(enqueue) }
            }
        }
        let result = try reflected.admittedBegin(capability: capability, admissionOwner: capability, item: item,
            executionID: "actual-broker-restart", arguments: ["challenge": String(repeating: "b", count: 32), "value": "no-effect", "enabled": "[\"boolean\",true]"],
            verification: nil, expectedOutput: nil, host: host, revalidate: { true })
        XCTAssertTrue(reachedFinalGate); XCTAssertNotEqual(result.rcir?.leaseConsumed, true)
        XCTAssertEqual(result.state, .rejected); XCTAssertFalse(result.events.contains { $0.contains("RCIR consumed lease=") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("state/effects.jsonl").path))
    }
#endif
}
