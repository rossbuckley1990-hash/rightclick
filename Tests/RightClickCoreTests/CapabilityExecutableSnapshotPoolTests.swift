import Foundation
import XCTest
@testable import RightClickCore

final class CapabilityExecutableSnapshotPoolTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        try body(directory)
    }
    private func executableBytes(_ value: String = "host-selected-executable") throws -> Data {
#if os(Windows)
        // Windows checks the executable format, not just the filename. Preserve
        // a real host-selected PE and vary an appended canary outside its image.
        let interpreter = try NativeHTTPFixture.python()
        guard FileManager.default.isExecutableFile(atPath: interpreter.path) else { throw RCIRError.unavailable }
        var bytes = try CapabilityArtifactSnapshot.read(source: interpreter, maximum: 1_048_576)
        bytes.append(Data(value.utf8))
        return bytes
#else
        return Data(value.utf8)
#endif
    }
    private func executable(_ directory: URL, _ name: String = "host.exe", value: String = "host-selected-executable") throws -> URL {
        let file = directory.appendingPathComponent(name)
#if os(Windows)
        try NativeHTTPFixture.writePrivate(executableBytes(value), to: file)
#else
        try Data(value.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
#endif
        return file
    }
    func testReusesExactPrivateIncarnationWhileReadingCurrentByteIdentity() throws {
        try fixture { directory in
            let source = try executable(directory)
            let bytes = try Data(contentsOf: source), maximum = bytes.count
            let pool = CapabilityExecutableSnapshotPool()
            let one = try pool.acquire(executable: source, maximum: maximum)
            let two = try pool.acquire(executable: source, maximum: maximum)
            XCTAssertTrue(one === two); XCTAssertNotEqual(one.file, source)
            XCTAssertEqual(try Data(contentsOf: one.file), bytes)
            let timestamp = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate]
            try NativeHTTPFixture.replacePrivate(self.executableBytes("HOST-selected-executable"), at: source)
            if let timestamp {
#if os(Windows)
                // replacePrivate seals the owned source read-only. Foundation
                // requests GENERIC_WRITE to restore its modification date.
                XCTAssertThrowsError(try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)) {
                    XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoPermission)
                }
                try NativeHTTPFixture.release(source)
                do {
                    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
                } catch {
                    try? NativeHTTPFixture.protect(source)
                    throw error
                }
                try NativeHTTPFixture.protect(source)
#else
                try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
#endif
            }
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: source.path))
            let changed = try pool.acquire(executable: source, maximum: maximum)
            XCTAssertFalse(one === changed); XCTAssertNotEqual(one.sha256, changed.sha256)
            XCTAssertFalse(one.sourceStillMatches())
            XCTAssertEqual(try Data(contentsOf: one.file), bytes)
#if os(Windows)
            let invalid = directory.appendingPathComponent("not-a-native-executable.exe")
            try NativeHTTPFixture.writePrivate(Data("arbitrary-text-is-not-a-PE".utf8), to: invalid)
            XCTAssertFalse(FileManager.default.isExecutableFile(atPath: invalid.path))
            XCTAssertThrowsError(try pool.acquire(executable: invalid, maximum: maximum)) {
                XCTAssertEqual($0 as? RCIRError, .unavailable)
            }
#endif
        }
    }
    func testSourceWithdrawalAndRestorationCannotReturnWithdrawnCacheEntry() throws {
        try fixture { directory in
            let source = try executable(directory)
            let pool = CapabilityExecutableSnapshotPool()
            let maximum = try Data(contentsOf: source).count
            let original = try pool.acquire(executable: source, maximum: maximum)
            try NativeHTTPFixture.release(source)
            try FileManager.default.removeItem(at: source)
            XCTAssertThrowsError(try pool.acquire(executable: source, maximum: maximum))
            XCTAssertEqual(pool.retainedBudget.entries, 0); XCTAssertFalse(original.sourceStillMatches())
            _ = try executable(directory)
            let restored = try pool.acquire(executable: source, maximum: maximum)
            XCTAssertFalse(original === restored); XCTAssertEqual(original.sha256, restored.sha256)
        }
    }
    func testReturnRaceRechecksWholeBytesAndDoesNotEvictConcurrentNewIncarnation() throws {
        try fixture { directory in
            let source = try executable(directory), pool = CapabilityExecutableSnapshotPool()
            let maximum = try Data(contentsOf: source).count
            let original = try pool.acquire(executable: source, maximum: maximum)
            var replacement: CapabilityArtifactSnapshot?
            XCTAssertThrowsError(try pool.acquire(executable: source, maximum: maximum, beforeReturn: {
                try! NativeHTTPFixture.replacePrivate(self.executableBytes("other-executable-bytes"), at: source)
                replacement = try! pool.acquire(executable: source, maximum: maximum)
            })) { XCTAssertEqual($0 as? RCIRError, .unavailable) }
            let current = try pool.acquire(executable: source, maximum: maximum)
            XCTAssertTrue(current === replacement); XCTAssertFalse(current === original)
            XCTAssertEqual(pool.retainedBudget.entries, 1)
            XCTAssertThrowsError(try pool.acquire(executable: source, maximum: maximum, beforeReturn: {
                try! NativeHTTPFixture.release(source)
                try! FileManager.default.removeItem(at: source)
            })) { XCTAssertEqual($0 as? RCIRError, .unavailable) }
            XCTAssertEqual(pool.retainedBudget.entries, 0)
        }
    }
    func testEntryByteAndAbsoluteRetentionBudgetsDoNotGrowOnReuse() throws {
        try fixture { directory in
            var now: TimeInterval = 0
            let a = try executable(directory, "a.exe"), b = try executable(directory, "b.exe"), c = try executable(directory, "c.exe")
            let maximum = try Data(contentsOf: a).count, budget = maximum * 2
            let pool = CapabilityExecutableSnapshotPool(maximumEntries: 2, maximumBytes: budget, retention: 1, clock: { now })
            let first = try pool.acquire(executable: a, maximum: maximum)
            _ = try pool.acquire(executable: b, maximum: maximum)
            now = 0.5; XCTAssertTrue(first === (try pool.acquire(executable: a, maximum: maximum)))
            _ = try pool.acquire(executable: c, maximum: maximum)
            XCTAssertLessThanOrEqual(pool.retainedBudget.entries, 2); XCTAssertLessThanOrEqual(pool.retainedBudget.bytes, budget)
            now = 1.1; XCTAssertFalse(first === (try pool.acquire(executable: a, maximum: maximum)))
            XCTAssertLessThanOrEqual(pool.retainedBudget.entries, 2)
            XCTAssertThrowsError(try pool.acquire(executable: a, maximum: 4))
            XCTAssertThrowsError(try CapabilityExecutableSnapshotPool(maximumEntries: 0).acquire(executable: a, maximum: maximum))
            XCTAssertThrowsError(try CapabilityExecutableSnapshotPool(retention: .infinity).acquire(executable: a, maximum: maximum))
        }
    }
    func testIdleRetentionCleanupReleasesOnlyThePoolReference() throws {
        try fixture { directory in
            let source = try executable(directory)
            let maximum = try Data(contentsOf: source).count
            let pool = CapabilityExecutableSnapshotPool(retention: 0.02)
            let active = try pool.acquire(executable: source, maximum: maximum)
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while pool.retainedBudget.entries > 0, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertEqual(pool.retainedBudget.entries, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: active.file.path))
            XCTAssertTrue(active.sourceStillMatches())
        }
    }
#if !os(Windows)
    func testPooledExecutableReplacementAtFinalRCIRGateBlocksActualChildEffect() throws {
        try fixture { directory in
            let source = directory.appendingPathComponent("native-effect"), code = directory.appendingPathComponent("effect.c")
            try Data("#include <stdio.h>\nint main(int n,char **v){if(n!=2)return 2;FILE*f=fopen(v[1],\"wb\");if(!f)return 3;fputs(\"actual-effect\",f);return fclose(f);}\n".utf8).write(to: code)
            let compilerPath = try XCTUnwrap(["/usr/bin/cc", "/usr/bin/clang"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }, "A native C fixture compiler must be installed.")
            let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: compilerPath)
            compiler.arguments = ["-x", "c", code.path, "-o", source.path]
            compiler.standardOutput = FileHandle.nullDevice; compiler.standardError = FileHandle.nullDevice
            try compiler.run(); compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0, "Native fixture compiler must be provisioned; no child-effect proof without a runnable host fixture.")
            let snapshot = try CapabilityExecutableSnapshotPool().acquire(executable: source, maximum: 268_435_456)
            let effect = directory.appendingPathComponent("actual-effect")
            var processReport: BoundedCapabilityProcess.Diagnostic?
            let reflector = try CapabilityInterfaceReflector(id: "pooled-executable", provider: "host-native",
                target: URL(string: "process://pooled-native/evidence")!, substrate: "host-native",
                descriptorDigest: snapshot.sha256,
                operations: [.init(name: "write", title: "Write native evidence", arguments: .object(properties: [:], required: []),
                    result: .unit, declaration: .string("host-selected native fixture"))],
                available: { snapshot.sourceStillMatches() }, invoke: { _, _, admit in
                    _ = try withoutActuallyEscaping(admit) { gate in
                        try BoundedCapabilityProcess.run(executable: snapshot.file,
                            arguments: [effect.path], diagnostic: { processReport = $0 },
                            admitStart: gate)
                    }
                    return .null
                })
            let item = try ContentParser.parse("pooled native executable"), host = RCIRExecutionHost()
            host.configuration = { RCIRHostConfiguration() }
            let capability = try XCTUnwrap(try reflector.capabilities(for: item).first)
            let positive = try reflector.admittedBegin(capability: capability, admissionOwner: capability, item: item,
                executionID: "pooled-positive", arguments: nil, verification: nil, expectedOutput: nil,
                host: host, revalidate: { snapshot.sourceStillMatches() })
            XCTAssertEqual(positive.state, .accepted, "\(positive.message); child=\(String(describing: processReport))")
            XCTAssertTrue(FileManager.default.fileExists(atPath: effect.path))
            try FileManager.default.removeItem(at: effect)
            var reachedFinalGate = false
            host.beforeStart = { _, admit, enqueue in
                reachedFinalGate = true
                var bytes = try Data(contentsOf: source); bytes[0] ^= 1; try bytes.write(to: source)
                try withoutActuallyEscaping(admit) { gate in
                    try withoutActuallyEscaping(enqueue) { start in try gate(start) }
                }
            }
            let result = try reflector.admittedBegin(capability: capability, admissionOwner: capability, item: item,
                executionID: "pooled-withdrawal", arguments: nil, verification: nil, expectedOutput: nil,
                host: host, revalidate: { snapshot.sourceStillMatches() })
            XCTAssertTrue(reachedFinalGate); XCTAssertEqual(result.state, .rejected)
            XCTAssertNotEqual(result.rcir?.leaseConsumed, true)
            XCTAssertFalse(result.events.contains { $0.contains("RCIR consumed lease=") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))
        }
    }
#endif
#if !os(Windows)
    func testNonExecutableSecretReferenceAndPermissionWithdrawalFailClosed() throws {
        try fixture { directory in
            let source = try executable(directory), pool = CapabilityExecutableSnapshotPool()
            let maximum = try Data(contentsOf: source).count
            _ = try pool.acquire(executable: source, maximum: maximum)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            XCTAssertThrowsError(try pool.acquire(executable: source, maximum: maximum))
            XCTAssertEqual(pool.retainedBudget.entries, 0)
            XCTAssertThrowsError(try pool.acquire(executable: source, maximum: maximum, beforeReturn: {}))
        }
    }
#endif
}
