import Foundation
import XCTest
@testable import RightClickCore
#if os(Windows)
/// Same shipping process boundary and owned SDK inputs; only the existing
/// immutable host-selected search role changes between three actual attempts.
final class WindowsCompilerSearchRoleDiagnosticTests: XCTestCase {
    func testSameOwnedCompilerIsolatedSystem32Isolated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rightclick-foundation-compiler-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let script = directory.appendingPathComponent("owned-script.py")
        try NativeHTTPFixture.writePrivate(Data("raise SystemExit(0)\n".utf8), to: script)
        let inputs = try NativeHTTPFixture.compilerInputs(script: script, directory: directory)
        let frozen = try inputs.frozenInputs.map { try CapabilityArtifactSnapshot.read(source: $0.0, maximum: $0.1) }
        let arguments = [inputs.ownedArguments, inputs.ownedArguments, inputs.ownedArguments]
        let search = try TrustedHostProcessContext.resolving(.systemExecutableSearch)
        let contexts = [TrustedHostProcessContext.isolated, search, .isolated]
        let profiles = ["isolatedBefore", "explicitSystemSearch", "isolatedAfter"]
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
                _ = try BoundedCapabilityProcess.runForHostAcquisition(executable: inputs.executable, arguments: arguments[index],
                    timeout: 30, maximumBytes: 16_384, hostContext: contexts[index], diagnostic: { reports.append($0) })
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
            print("TrustedHostContext compilerProfile comparison=nativeSearchRole profile=\(profiles[index]) index=\(index) outcome=\(report.outcome.rawValue) started=\(report.started) exit=\(report.terminationStatus.map(String.init) ?? "none") stdoutBytes=\(report.stdoutBytes) elapsedMilliseconds=\(report.elapsedMilliseconds) freshPE=\(validPE) outputSHA256=\(digest) stableOutput=\(stableOutput) unchangedInputs=\(unchangedInputs) parentAndStdoutClosed=true ownedGroupClosureClaimed=false")
        }
        // This is a diagnostic. Record actual A/B/A rather than assume the
        // previously inherited PATH represented isolated acquisition.
        print("TrustedHostContext compilerSearchClosed success=\(success.map(String.init).joined(separator: ",")) freshPE=\(freshPE.map(String.init).joined(separator: ",")) sameArguments=true unchangedInputs=true searchRoleCurrent=\(search.isCurrent) defaultIsolationRestored=\(TrustedHostProcessContext.isolated.isCurrent) diagnosticOnly=true")
        XCTAssertTrue(reports.allSatisfy { $0.started && $0.stdoutBytes <= 16_384 })
        XCTAssertTrue(search.isCurrent)
        XCTAssertTrue(TrustedHostProcessContext.isolated.isCurrent)
    }
}
#endif
