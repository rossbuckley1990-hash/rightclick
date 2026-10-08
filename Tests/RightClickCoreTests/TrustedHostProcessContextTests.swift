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

    func testSystemSearchRejectsPathListsAndRetainsSingleLocalDirectoryBounds() {
        let invalid = ["C:\\Windows;D:\\Tools", "C:\\Windows;", ";C:\\Windows", "C:\\a\"b", "C:\\a\nb", "\\\\server\\share", "relative"]
        for (index, value) in invalid.enumerated() {
            XCTAssertFalse(TrustedHostProcessContext.isBoundedSingleSearchDirectoryPath(value), "invalid search case \(index)")
        }
        XCTAssertTrue(TrustedHostProcessContext.isBoundedSingleSearchDirectoryPath("C:\\Windows\\System32"))
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

    private func setSystemRoot(_ value: String?) throws {
        let name = Array("SystemRoot".utf16) + [0]
        let okay = name.withUnsafeBufferPointer { key -> Bool in
            if let value {
                let wide = Array(value.utf16) + [0]
                return wide.withUnsafeBufferPointer { SetEnvironmentVariableW(key.baseAddress, $0.baseAddress) }
            }
            return SetEnvironmentVariableW(key.baseAddress, nil)
        }
        guard okay else { throw RCIRError.unavailable }
    }

    /// Exercise actual Foundation/BPC; Python's Windows argv renderer is not
    /// used here. Completion closes the parent and stdout only, not a Job group.
    private func compilerCounterfactual(rendererComparison: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-foundation-compiler-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let script = directory.appendingPathComponent("owned-script.py")
        try NativeHTTPFixture.writePrivate(Data("raise SystemExit(0)\n".utf8), to: script)
        let inputs = try NativeHTTPFixture.compilerInputs(script: script, directory: directory)
        let frozen = try inputs.frozenInputs.map { try CapabilityArtifactSnapshot.read(source: $0.0, maximum: $0.1) }
        let search = try TrustedHostProcessContext.resolving(.systemExecutableSearch)
        let arguments = rendererComparison ? [inputs.packedArguments, inputs.ownedArguments, inputs.packedArguments] :
            [inputs.ownedArguments, inputs.ownedArguments, inputs.ownedArguments]
        let contexts = rendererComparison ? [search, search, search] : [.isolated, search, .isolated]
        let frozenArguments = arguments.map { $0.map { Array($0.utf16) } }
        var reports: [BoundedCapabilityProcess.Diagnostic] = []
        var success: [Bool] = [], freshPE: [Bool] = []
        for index in 0..<3 {
            for output in [inputs.client, inputs.object] where FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            guard [inputs.client, inputs.object].allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }),
                  arguments[index].map({ Array($0.utf16) }) == frozenArguments[index],
                  try inputs.frozenInputs.enumerated().allSatisfy({ try CapabilityArtifactSnapshot.read(source: $0.element.0, maximum: $0.element.1) == frozen[$0.offset] }) else {
                throw RCIRError.unavailable
            }
            do {
                _ = try BoundedCapabilityProcess.run(executable: inputs.executable, arguments: arguments[index],
                    timeout: 10, maximumBytes: 16_384, hostContext: contexts[index], diagnostic: { reports.append($0) })
                success.append(true)
            } catch let error as RCIRError {
                guard error == .unavailable else { throw error }
                success.append(false)
            }
            guard reports.count == index + 1 else { throw RCIRError.unavailable }
            let report = reports[index]
            // Cancellation, failed drain and truncation abort before reusing any
            // output path. Do not treat them as the counterfactual's native RED.
            guard report.started, report.terminationStatus != nil,
                  report.outcome == .completed || report.outcome == .childFailed else {
                print("TrustedHostContext compilerAborted index=\(index) outcome=\(report.outcome.rawValue)")
                throw RCIRError.unavailable
            }
            let emitted: Data?
            if FileManager.default.fileExists(atPath: inputs.client.path) {
                emitted = try CapabilityArtifactSnapshot.read(source: inputs.client, maximum: 8_388_608)
            } else { emitted = nil }
            let validPE = emitted.map(NativeHTTPFixture.isAMD64PE) ?? false
            freshPE.append(validPE)
            Thread.sleep(forTimeInterval: 0.010)
            let stableOutput = emitted == (try? CapabilityArtifactSnapshot.read(source: inputs.client, maximum: 8_388_608))
            let unchangedInputs = try inputs.frozenInputs.enumerated().allSatisfy {
                try CapabilityArtifactSnapshot.read(source: $0.element.0, maximum: $0.element.1) == frozen[$0.offset]
            }
            guard stableOutput, unchangedInputs else { throw RCIRError.unavailable }
            let digest = emitted.map(CapabilityJSON.digest) ?? "none"
            print("TrustedHostContext compilerProfile comparison=\(rendererComparison ? "renderer" : "searchRole") index=\(index) outcome=\(report.outcome.rawValue) started=\(report.started) exit=\(report.terminationStatus.map(String.init) ?? "none") stdoutBytes=\(report.stdoutBytes) elapsedMilliseconds=\(report.elapsedMilliseconds) freshPE=\(validPE) outputSHA256=\(digest) stableOutput=\(stableOutput) unchangedInputs=\(unchangedInputs) parentAndStdoutClosed=true ownedGroupClosureClaimed=false")
        }
        XCTAssertEqual(success, [false, true, false])
        XCTAssertEqual(freshPE, [false, true, false])
        XCTAssertTrue([0, 2].allSatisfy { reports[$0].outcome == .childFailed && reports[$0].terminationStatus != 0 })
        XCTAssertTrue(reports[1].outcome == .completed && reports[1].terminationStatus == 0)
        XCTAssertTrue(reports.allSatisfy { $0.stdoutBytes <= 16_384 })
        XCTAssertTrue(search.isCurrent)
        XCTAssertNotEqual(search.identity, TrustedHostProcessContext.isolated.identity)
        XCTAssertNotEqual(search.identity, try TrustedHostProcessContext.resolving(.machineApplicationData).identity)
        XCTAssertEqual(String(reflecting: search), "TrustedHostProcessContext(systemExecutableSearch)")
    }

    func testActualFoundationCompilerRequiresSingleSystemSearchAndRestoresIsolation() throws {
        try compilerCounterfactual(rendererComparison: false)
    }

    func testActualFoundationCompilerRequiresOwnedBatchAndRestoresPackedRenderer() throws {
        try compilerCounterfactual(rendererComparison: true)
    }

    func testSystemRootExactUnicodeDriftAtAdmissionPreventsLaunch() throws {
        let original = try fixedHostValue("SystemRoot")
        defer { try? setSystemRoot(original) }
        let executable = try NativeHTTPFixture.python()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let composed = directory.appendingPathComponent("caf\u{e9}")
        let decomposed = directory.appendingPathComponent("cafe\u{301}")
        XCTAssertTrue(composed.path == decomposed.path)
        XCTAssertFalse(composed.path.utf16.elementsEqual(decomposed.path.utf16))
        for root in [composed, decomposed] {
            try NativeHTTPFixture.createPrivateDirectory(root)
            try NativeHTTPFixture.createPrivateDirectory(root.appendingPathComponent("System32"))
        }
        try setSystemRoot(composed.path)
        let context = try TrustedHostProcessContext.resolving(.systemExecutableSearch)
        let selected = try context.applying(to: ["fixed": "private-test-canary"])
        XCTAssertEqual(Set(selected.keys), Set(["fixed", "PATH"]))
        var report: BoundedCapabilityProcess.Diagnostic?
        XCTAssertThrowsError(try BoundedCapabilityProcess.run(executable: executable,
            arguments: ["-c", "raise SystemExit(77)"], hostContext: context,
            diagnostic: { report = $0 }, admitStart: { start in
                try self.setSystemRoot(decomposed.path)
                start()
            })) { XCTAssertEqual($0 as? RCIRError, .unavailable) }
        XCTAssertEqual(report?.started, false)
        XCTAssertEqual(report?.outcome, .admissionOrLaunchFailure)
        XCTAssertNil(report?.terminationStatus)
        let changed = try TrustedHostProcessContext.resolving(.systemExecutableSearch)
        XCTAssertNotEqual(context.identity, changed.identity)
        XCTAssertFalse(context.isCurrent); XCTAssertTrue(changed.isCurrent)
        XCTAssertFalse(String(reflecting: changed).contains(decomposed.path))
    }

    func testSystemSearchRejectsMissingAmbiguousAndRedirectedHostRoots() throws {
        let original = try fixedHostValue("SystemRoot")
        defer { try? setSystemRoot(original) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let target = directory.appendingPathComponent("target"), alias = directory.appendingPathComponent("redirect")
        try NativeHTTPFixture.createPrivateDirectory(target)
        try NativeHTTPFixture.createPrivateDirectory(target.appendingPathComponent("System32"))
        try NativeHTTPFixture.junction(alias, target: target)
        let leafRoot = directory.appendingPathComponent("leaf-root")
        try NativeHTTPFixture.createPrivateDirectory(leafRoot)
        try NativeHTTPFixture.junction(leafRoot.appendingPathComponent("System32"), target: target.appendingPathComponent("System32"))
        let fileRoot = directory.appendingPathComponent("file-root")
        try NativeHTTPFixture.createPrivateDirectory(fileRoot)
        try NativeHTTPFixture.writePrivate(Data("not-a-directory".utf8), to: fileRoot.appendingPathComponent("System32"))
        for value in [nil, "relative", "\\\\server\\share", "C:\\a\"b", "C:\\a\nb", "C:\\Windows;D:\\Tools",
                      "C:\\" + String(repeating: "a", count: 4094), alias.path, leafRoot.path, fileRoot.path,
                      directory.appendingPathComponent("absent").path, directory.path] as [String?] {
            try setSystemRoot(value)
            XCTAssertThrowsError(try TrustedHostProcessContext.resolving(.systemExecutableSearch))
        }
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
        XCTAssertThrowsError(try TrustedHostProcessContext.resolving(.systemExecutableSearch)) {
            XCTAssertEqual($0 as? RCIRError, .unavailable)
        }
    }
#endif
}
