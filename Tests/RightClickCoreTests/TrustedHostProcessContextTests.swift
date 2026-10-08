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
                return wide.withUnsafeBufferPointer { SetEnvironmentVariableW(key.baseAddress, $0.baseAddress) }
            }
            return SetEnvironmentVariableW(key.baseAddress, nil)
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
        let unchangedBinary = beforeBytes == (try CapabilityArtifactSnapshot.read(source: executable, maximum: 8_388_608))
        XCTAssertTrue(unchangedBinary)
        XCTAssertEqual(reports.count, 3)
        let naturalCompletions = reports.filter { $0.started && $0.outcome == .completed && $0.terminationStatus == 0 }.count
        XCTAssertEqual(naturalCompletions, 3)
        XCTAssertTrue(reports.allSatisfy { $0.stdoutBytes <= 32_768 })
        XCTAssertNotEqual(context.identity, TrustedHostProcessContext.isolated.identity)
        XCTAssertEqual(String(reflecting: context), "TrustedHostProcessContext(machineApplicationData)")
        print("TrustedHostContext nativeFoundationCounterfactual minimalBytes=\(minimal.count) explicitBytes=\(selected.count) restoredBytes=\(restored.count) unchangedBinary=\(unchangedBinary) naturalCompletions=\(naturalCompletions)")
    }

    /// Acquisition-only experiment: keep the actual fixture compiler command
    /// and its owned inputs identical while varying only the typed host role.
    /// This does not change pythonClient or any production resolver's context.
    func testActualFoundationNativeCompilerRequiresExplicitSingleLocationAndRestoresIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-compiler-counterfactual-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let context = try TrustedHostProcessContext.resolving(.machineApplicationData)
        let whereTool = URL(fileURLWithPath: try fixedHostValue("ProgramFiles(x86)"))
            .appendingPathComponent("Microsoft Visual Studio/Installer/vswhere.exe")
        let installed = try BoundedCapabilityProcess.run(executable: whereTool,
            arguments: ["-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"],
            timeout: 5, maximumBytes: 32_768, hostContext: context)
        let installation = String(decoding: installed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard TrustedHostProcessContext.isBoundedLocalDirectoryPath(installation) else { throw RCIRError.unavailable }
        let setup = URL(fileURLWithPath: installation).appendingPathComponent("VC/Auxiliary/Build/vcvars64.bat")
        let executable = URL(fileURLWithPath: try fixedHostValue("SystemRoot")).appendingPathComponent("System32/cmd.exe")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = directory.appendingPathComponent("client-launcher.c")
        let header = directory.appendingPathComponent("windows-python-client-paths.h")
        let script = directory.appendingPathComponent("owned-script.py")
        let client = directory.appendingPathComponent("client.exe"), object = directory.appendingPathComponent("client.obj")
        func literal(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        func native(_ file: URL) -> String { file.path.replacingOccurrences(of: "/", with: "\\") }
        let interpreter = try NativeHTTPFixture.python()
        try NativeHTTPFixture.writePrivate(try CapabilityArtifactSnapshot.read(source: repository.appendingPathComponent("Tests/Fixtures/windows-python-client-launcher.c"), maximum: 65_536), to: source)
        try NativeHTTPFixture.writePrivate(Data("raise SystemExit(0)\n".utf8), to: script)
        let declaration = "#define RIGHTCLICK_FIXTURE_PYTHON L\"\(literal(interpreter.path))\"\n#define RIGHTCLICK_FIXTURE_SCRIPT L\"\(literal(script.path))\"\n"
        try NativeHTTPFixture.writePrivate(Data(declaration.utf8), to: header)
        // This is the exact batch/cl command shape in NativeHTTPFixture.
        let command = "call \"\(native(setup))\" > nul && cl /nologo /std:c17 \"\(native(source))\" /Fe:\"\(native(client))\" /Fo:\"\(native(object))\""
        let arguments = ["/d", "/s", "/c", command]
        let inputs = [(executable, 8_388_608), (setup, 1_048_576), (source, 65_536), (header, 32_768), (script, 128)]
        let frozen = try inputs.map { try CapabilityArtifactSnapshot.read(source: $0.0, maximum: $0.1) }
        var reports: [BoundedCapabilityProcess.Diagnostic] = []
        var invokedArguments: [[String]] = []
        var success: [Bool] = [], freshPE: [Bool] = []
        for (index, profile) in [TrustedHostProcessContext.isolated, context, .isolated].enumerated() {
            // Reuse the exact command and path bytes, but never its output.
            for output in [client, object] where FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            guard [client, object].allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else { throw RCIRError.unavailable }
            invokedArguments.append(arguments)
            do {
                _ = try BoundedCapabilityProcess.run(executable: executable, arguments: arguments,
                    timeout: 5, maximumBytes: 16_384, hostContext: profile,
                    diagnostic: { reports.append($0) })
                success.append(true)
            } catch let error as RCIRError {
                guard error == .unavailable else { throw error }
                success.append(false)
            }
            guard reports.count == index + 1 else { throw RCIRError.unavailable }
            let report = reports[index]
            // Never continue into another profile after cancellation, output
            // truncation or failed drain: a late compiler output would destroy
            // the same-input counterfactual. cmd waits for the foreground cl.
            guard report.started, report.terminationStatus != nil,
                  report.outcome == .completed || report.outcome == .childFailed else {
                print("TrustedHostContext nativeCompilerAborted index=\(index) outcome=\(report.outcome.rawValue)")
                throw RCIRError.unavailable
            }
            let emitted = try? CapabilityArtifactSnapshot.read(source: client, maximum: 8_388_608)
            let validPE: Bool
            if let emitted, emitted.count >= 64, emitted.prefix(2).elementsEqual([77, 90]) {
                let offset = (0..<4).reduce(0) { $0 | (Int(emitted[60 + $1]) << (8 * $1)) }
                validPE = offset <= emitted.count - 6 && emitted[offset..<(offset + 6)].elementsEqual([80, 69, 0, 0, 100, 134])
            } else { validPE = false }
            freshPE.append(validPE)
            let outputDigest = emitted.map(CapabilityJSON.digest) ?? "none"
            print("TrustedHostContext nativeCompilerProfile index=\(index) outcome=\(report.outcome.rawValue) started=\(report.started) exit=\(report.terminationStatus.map(String.init) ?? "none") stdoutBytes=\(report.stdoutBytes) elapsedMilliseconds=\(report.elapsedMilliseconds) freshPE=\(validPE) outputSHA256=\(outputDigest)")
        }
        let sameArguments = invokedArguments.count == 3 && invokedArguments.allSatisfy {
            $0.count == arguments.count && zip($0, arguments).allSatisfy { $0.0.utf16.elementsEqual($0.1.utf16) }
        }
        let unchangedInputs = try inputs.enumerated().allSatisfy {
            try CapabilityArtifactSnapshot.read(source: $0.element.0, maximum: $0.element.1) == frozen[$0.offset]
        }
        let isolatedFailures = [0, 2].allSatisfy {
            reports[$0].started && reports[$0].outcome == .childFailed && reports[$0].terminationStatus == 1
        }
        let explicitNaturalCompletion = reports[1].started && reports[1].outcome == .completed && reports[1].terminationStatus == 0
        print("TrustedHostContext nativeCompilerCounterfactual unchangedInputs=\(unchangedInputs) sameArguments=\(sameArguments) isolatedFailures=\(isolatedFailures) explicitNaturalCompletion=\(explicitNaturalCompletion)")
        XCTAssertEqual(success, [false, true, false])
        XCTAssertEqual(freshPE, [false, true, false])
        XCTAssertTrue(unchangedInputs); XCTAssertTrue(sameArguments); XCTAssertTrue(context.isCurrent)
        XCTAssertTrue(isolatedFailures); XCTAssertTrue(explicitNaturalCompletion)
        XCTAssertTrue(reports.allSatisfy { $0.stdoutBytes <= 16_384 })
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

    func testCanonicallyEquivalentDifferentHostPathBytesAtAdmissionPreventLaunch() throws {
        let original = try fixedHostValue("ProgramData")
        defer { try? setMachineData(original) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let composed = directory.appendingPathComponent("caf\u{e9}")
        let decomposed = directory.appendingPathComponent("cafe\u{301}")
        XCTAssertTrue(composed.path == decomposed.path)
        XCTAssertFalse(composed.path.utf16.elementsEqual(decomposed.path.utf16))
        try NativeHTTPFixture.createPrivateDirectory(composed)
        try NativeHTTPFixture.createPrivateDirectory(decomposed)
        try setMachineData(composed.path)
        let context = try TrustedHostProcessContext.resolving(.machineApplicationData)
        let executable = try NativeHTTPFixture.python()
        var report: BoundedCapabilityProcess.Diagnostic?
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: executable,
            arguments: ["-c", "raise SystemExit(77)"], hostContext: context,
            diagnostic: { report = $0 }, admitStart: { start in
                try self.setMachineData(decomposed.path)
                start()
            })) { XCTAssertEqual($0 as? RCIRError, .unavailable) }
        XCTAssertEqual(report?.started, false)
        XCTAssertEqual(report?.outcome, .admissionOrLaunchFailure)
        XCTAssertNil(report?.terminationStatus)
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
