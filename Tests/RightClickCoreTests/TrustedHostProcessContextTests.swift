import Foundation
import XCTest
@testable import RightClickCore
#if os(Windows)
import WinSDK
#endif

final class TrustedHostProcessContextTests: XCTestCase {
    func testIsolatedContextPreservesBaselineAndHasStableOpaqueIdentity() throws {
        let baseline = ["fixed": "private-test-canary"]
        XCTAssertEqual(try TrustedHostProcessContext.isolated.applying(to: baseline), baseline)
        XCTAssertTrue(TrustedHostProcessContext.isolated.isCurrent)
        XCTAssertEqual(TrustedHostProcessContext.isolated.identity.count, 64)
        XCTAssertEqual(TrustedHostProcessContext.isolated.identity, TrustedHostProcessContext.isolated.identity)
        XCTAssertEqual(String(describing: TrustedHostProcessContext.isolated), "TrustedHostProcessContext(isolated)")
        XCTAssertEqual(String(reflecting: TrustedHostProcessContext.isolated), "TrustedHostProcessContext(isolated)")
    }

    func testLocalPathValidationRejectsUnboundedAmbiguousAndRemoteInputs() {
        let invalid = ["", "ProgramData", "C:ProgramData", "\\\\server\\share", "\\\\?\\C:\\ProgramData",
            "/ProgramData", "C:\\a\\..\\b", "C:\\a\\.\\b", "C:\\a ", "C:\\a.",
            "C:\\a\u{0}b", "C:\\a\nb", "C:\\a\rb", "C:\\a\"b", "C:\\a:stream",
            "C:\\" + String(repeating: "a", count: 4094)]
        for (index, value) in invalid.enumerated() {
            XCTAssertFalse(TrustedHostProcessContext.isBoundedLocalDirectoryPath(value), "invalid case \(index)")
        }
        XCTAssertTrue(TrustedHostProcessContext.isBoundedLocalDirectoryPath("C:\\ProgramData"))
        XCTAssertTrue(TrustedHostProcessContext.isBoundedLocalDirectoryPath("D:/Machine Data"))
    }

#if os(Windows)
    private func fixedHostValue(_ name: String) throws -> String {
        let wide = Array(name.utf16) + [0]
        var buffer = [WCHAR](repeating: 0, count: 4097)
        let length = wide.withUnsafeBufferPointer { key in
            buffer.withUnsafeMutableBufferPointer { value in
                GetEnvironmentVariableW(key.baseAddress, value.baseAddress, DWORD(value.count))
            }
        }
        guard length > 0, length <= 4096 else { throw RCIRError.unavailable }
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private func setMachineData(_ value: String?) throws {
        let name = Array("ProgramData".utf16) + [0]
        let okay = name.withUnsafeBufferPointer { key -> Bool in
            if let value {
                let wide = Array(value.utf16) + [0]
                return wide.withUnsafeBufferPointer { SetEnvironmentVariableW(key.baseAddress, $0.baseAddress) != 0 }
            }
            return SetEnvironmentVariableW(key.baseAddress, nil) != 0
        }
        guard okay else { throw RCIRError.unavailable }
    }

    func testActualFoundationInstalledDiscoveryRequiresExplicitSingleLocationAndRestoresIsolation() throws {
        let programs = try fixedHostValue("ProgramFiles(x86)")
        let executable = URL(fileURLWithPath: programs).appendingPathComponent("Microsoft Visual Studio/Installer/vswhere.exe")
        let arguments = ["-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"]
        let beforeBytes = try CapabilityArtifactSnapshot.read(source: executable, maximum: 8_388_608)
        let context = try TrustedHostProcessContext.resolving(.machineApplicationData)
        var reports: [BoundedCapabilityProcess.Diagnostic] = []
        let minimal = try BoundedCapabilityProcess.run(executable: executable, arguments: arguments,
            timeout: 5, maximumBytes: 32_768, diagnostic: { reports.append($0) })
        let selected = try BoundedCapabilityProcess.run(executable: executable, arguments: arguments,
            timeout: 5, maximumBytes: 32_768, hostContext: context, diagnostic: { reports.append($0) })
        let restored = try BoundedCapabilityProcess.run(executable: executable, arguments: arguments,
            timeout: 5, maximumBytes: 32_768, diagnostic: { reports.append($0) })
        // Assertions expose only Boolean results, counts and fixed outcomes.
        XCTAssertTrue(minimal.isEmpty); XCTAssertTrue(restored.isEmpty)
        let installation = String(decoding: selected, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(installation.isEmpty)
        XCTAssertTrue(TrustedHostProcessContext.isBoundedLocalDirectoryPath(installation))
        XCTAssertFalse(selected.prefix(3).elementsEqual([239, 187, 191]))
        XCTAssertTrue(beforeBytes == (try CapabilityArtifactSnapshot.read(source: executable, maximum: 8_388_608)))
        XCTAssertEqual(reports.count, 3)
        XCTAssertTrue(reports.allSatisfy { $0.started && $0.outcome == .completed && $0.terminationStatus == 0 })
        XCTAssertTrue(reports.allSatisfy { $0.stdoutBytes <= 32_768 })
        XCTAssertNotEqual(context.identity, TrustedHostProcessContext.isolated.identity)
        XCTAssertEqual(String(reflecting: context), "TrustedHostProcessContext(machineApplicationData)")
        print("TrustedHostContext nativeFoundationCounterfactual minimalBytes=\(minimal.count) explicitBytes=\(selected.count) restoredBytes=\(restored.count) unchangedBinary=true naturalCompletions=3")
    }

    func testFrozenContextDriftAtAdmissionPreventsActualChildLaunch() throws {
        let original = try fixedHostValue("ProgramData")
        defer { try? setMachineData(original) }
        let context = try TrustedHostProcessContext.resolving(.machineApplicationData)
        let changed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(changed)
        defer { try? NativeHTTPFixture.remove(changed) }
        let executable = try NativeHTTPFixture.python()
        var report: BoundedCapabilityProcess.Diagnostic?
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: executable,
            arguments: ["-c", "raise SystemExit(77)"], hostContext: context,
            diagnostic: { report = $0 }, admitStart: { start in
                try self.setMachineData(changed.path)
                start()
            })) { XCTAssertEqual($0 as? RCIRError, .unavailable) }
        XCTAssertEqual(report?.started, false)
        XCTAssertEqual(report?.outcome, .admissionOrLaunchFailure)
        XCTAssertNil(report?.terminationStatus)
    }

    func testMissingInvalidAndRedirectedLocationCannotCreateContext() throws {
        let original = try fixedHostValue("ProgramData")
        defer { try? setMachineData(original) }
        for value in [nil, "relative", "\\\\server\\share", "C:\\a\"b", "C:\\a\nb",
                      "C:\\" + String(repeating: "a", count: 4094)] as [String?] {
            try setMachineData(value)
            XCTAssertThrowsError(try TrustedHostProcessContext.resolving(.machineApplicationData))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let target = directory.appendingPathComponent("target"), alias = directory.appendingPathComponent("redirect")
        try NativeHTTPFixture.createPrivateDirectory(target)
        try NativeHTTPFixture.junction(alias, target: target)
        try setMachineData(alias.path)
        XCTAssertThrowsError(try TrustedHostProcessContext.resolving(.machineApplicationData))
        let nested = target.appendingPathComponent("nested")
        try NativeHTTPFixture.createPrivateDirectory(nested)
        try setMachineData(alias.appendingPathComponent("nested").path)
        XCTAssertThrowsError(try TrustedHostProcessContext.resolving(.machineApplicationData))
        try setMachineData(directory.appendingPathComponent("absent").path)
        XCTAssertThrowsError(try TrustedHostProcessContext.resolving(.machineApplicationData))
        let file = directory.appendingPathComponent("regular-file")
        try NativeHTTPFixture.writePrivate(Data("owned-context-test".utf8), to: file)
        try setMachineData(file.path)
        XCTAssertThrowsError(try TrustedHostProcessContext.resolving(.machineApplicationData))
    }

    func testLocationSnapshotIdentityChangesWithoutExposingPaths() throws {
        let original = try fixedHostValue("ProgramData")
        defer { try? setMachineData(original) }
        let before = try TrustedHostProcessContext.resolving(.machineApplicationData)
        let same = try TrustedHostProcessContext.resolving(.machineApplicationData)
        XCTAssertTrue(before == same)
        let changed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(changed)
        defer { try? NativeHTTPFixture.remove(changed) }
        try setMachineData(changed.path)
        let after = try TrustedHostProcessContext.resolving(.machineApplicationData)
        XCTAssertFalse(before == after); XCTAssertNotEqual(before.identity, after.identity)
        XCTAssertFalse(before.isCurrent); XCTAssertTrue(after.isCurrent)
        XCTAssertFalse(String(describing: after).contains(changed.path))
        XCTAssertFalse(String(reflecting: after).contains(changed.path))
    }
#else
    func testUnavailableHostLocationCannotExpandNonWindowsEnvironment() {
        XCTAssertThrowsError(try TrustedHostProcessContext.resolving(.machineApplicationData)) {
            XCTAssertEqual($0 as? RCIRError, .unavailable)
        }
    }
#endif
}
