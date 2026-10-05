import Foundation
import XCTest
@testable import RightClickCore

final class BonjourRealLifecycleAcceptanceTests:
    XCTestCase
{
    struct RunningProvider {
        let process: Process
        let port: Int
        let portFile: URL
        let logFile: URL
    }

    struct RunningAdvertisement {
        let process: Process
        let logFile: URL
    }

    @MainActor
    func testRealDNSServiceDiscoveryLifecycle()
        throws
    {
        guard
            ProcessInfo.processInfo
                .environment[
                    "NS005_REAL_DNSSD"
                ] == "1"
        else {
            throw XCTSkip(
                "NS005_REAL_DNSSD=1 is required."
            )
        }

        let environment =
            ProcessInfo.processInfo.environment

        let providerScript =
            try XCTUnwrap(
                environment[
                    "NS005_PROVIDER_SCRIPT"
                ]
            )

        let evidenceRoot =
            try XCTUnwrap(
                environment[
                    "NS005_EVIDENCE_DIR"
                ]
            )

        let python =
            try XCTUnwrap(
                environment[
                    "NS005_PYTHON"
                ]
            )

        let dnsSD =
            try XCTUnwrap(
                environment[
                    "NS005_DNSSD"
                ]
            )

        let root =
            URL(
                fileURLWithPath:
                    evidenceRoot,
                isDirectory:
                    true
            )

        try FileManager.default
            .createDirectory(
                at: root,
                withIntermediateDirectories:
                    true
            )

        let suffix =
            UUID()
            .uuidString
            .replacingOccurrences(
                of: "-",
                with: ""
            )
            .lowercased()
            .prefix(10)

        let instance =
            "RightClick-\(suffix)"

        let host =
            "rc\(suffix).local."

        let source =
            BonjourOpenAPISource(
                startBrowsing: true
            )

        let engine =
            CapabilityEngine(
                reflectorSources: [
                    source
                ]
            )

        func matchingCapability()
            throws -> Capability?
        {
            try engine
                .capabilities(
                    for: "hello"
                )
                .capabilities
                .first {
                    capability in

                    capability
                        .metadata[
                            "baseURL"
                        ]?
                        .contains(host)
                        == true
                }
        }

        XCTAssertNil(
            try matchingCapability()
        )

        var provider1: RunningProvider?
        var advert1: RunningAdvertisement?
        var provider2: RunningProvider?
        var advert2: RunningAdvertisement?

        defer {
            if let advert2 {
                stop(
                    advert2.process
                )
            }

            if let provider2 {
                stop(
                    provider2.process
                )
            }

            if let advert1 {
                stop(
                    advert1.process
                )
            }

            if let provider1 {
                stop(
                    provider1.process
                )
            }
        }

        provider1 =
            try startProvider(
                label: "phase1",
                python:
                    python,
                script:
                    providerScript,
                root:
                    root
            )

        advert1 =
            try startAdvertisement(
                label: "phase1",
                dnsSD:
                    dnsSD,
                instance:
                    instance,
                host:
                    host,
                port:
                    try XCTUnwrap(
                        provider1
                    ).port,
                root:
                    root
            )

        XCTAssertTrue(
            try waitUntil(
                timeout: 15
            ) {
                try matchingCapability()
                    != nil
            },
            "Real DNS-SD provider never appeared."
        )

        let first =
            try XCTUnwrap(
                matchingCapability()
            )

        let firstID =
            first.id

        let verified1 =
            try engine.run(
                id:
                    firstID,
                item:
                    "hello",
                confirmed:
                    true,
                verification:
                    VerificationSpec(
                        predicates: [
                            VerificationPredicate(
                                type:
                                    .textEquals,
                                value:
                                    "HELLO"
                            )
                        ]
                    )
            )

        XCTAssertEqual(
            verified1.status,
            .verified
        )

        XCTAssertEqual(
            verified1
                .verification?
                .status,
            .verifiedSuccess
        )

        stop(
            try XCTUnwrap(
                advert1
            ).process
        )

        advert1 = nil

        XCTAssertTrue(
            try waitUntil(
                timeout: 15
            ) {
                try matchingCapability()
                    == nil
            },
            "Capability remained after DNS-SD removal."
        )

        let stale1 =
            try engine.run(
                id:
                    firstID,
                item:
                    "hello",
                confirmed:
                    true
            )

        XCTAssertEqual(
            stale1.status,
            .unavailable
        )

        stop(
            try XCTUnwrap(
                provider1
            ).process
        )

        provider1 = nil

        provider2 =
            try startProvider(
                label: "phase2",
                python:
                    python,
                script:
                    providerScript,
                root:
                    root
            )

        XCTAssertNotEqual(
            try XCTUnwrap(
                provider2
            ).port,
            try portFromFile(
                root
                    .appendingPathComponent(
                        "phase1.port"
                    )
            )
        )

        advert2 =
            try startAdvertisement(
                label: "phase2",
                dnsSD:
                    dnsSD,
                instance:
                    instance,
                host:
                    host,
                port:
                    try XCTUnwrap(
                        provider2
                    ).port,
                root:
                    root
            )

        XCTAssertTrue(
            try waitUntil(
                timeout: 15
            ) {
                guard
                    let capability =
                        try matchingCapability()
                else {
                    return false
                }

                return
                    capability.id
                    != firstID
            },
            "Provider did not reappear with a new identity."
        )

        let second =
            try XCTUnwrap(
                matchingCapability()
            )

        XCTAssertNotEqual(
            firstID,
            second.id
        )

        let staleAfterReplacement =
            try engine.run(
                id:
                    firstID,
                item:
                    "hello",
                confirmed:
                    true
            )

        XCTAssertEqual(
            staleAfterReplacement.status,
            .unavailable
        )

        let verified2 =
            try engine.run(
                id:
                    second.id,
                item:
                    "hello",
                confirmed:
                    true,
                verification:
                    VerificationSpec(
                        predicates: [
                            VerificationPredicate(
                                type:
                                    .textEquals,
                                value:
                                    "HELLO"
                            )
                        ]
                    )
            )

        XCTAssertEqual(
            verified2.status,
            .verified
        )

        XCTAssertEqual(
            verified2
                .verification?
                .status,
            .verifiedSuccess
        )

        stop(
            try XCTUnwrap(
                advert2
            ).process
        )

        advert2 = nil

        XCTAssertTrue(
            try waitUntil(
                timeout: 15
            ) {
                try matchingCapability()
                    == nil
            },
            "Second capability remained after DNS-SD removal."
        )

        let stale2 =
            try engine.run(
                id:
                    second.id,
                item:
                    "hello",
                confirmed:
                    true
            )

        XCTAssertEqual(
            stale2.status,
            .unavailable
        )

        stop(
            try XCTUnwrap(
                provider2
            ).process
        )

        provider2 = nil

        let summary =
            [
                "instance=\(instance)",
                "host=\(host)",
                "first_id=\(firstID)",
                "second_id=\(second.id)",
                "first_status=\(verified1.status.rawValue)",
                "second_status=\(verified2.status.rawValue)",
                "final_stale_status=\(stale2.status.rawValue)",
            ]
            .joined(
                separator: "\n"
            )
            + "\n"

        try summary.write(
            to:
                root.appendingPathComponent(
                    "swift-summary.txt"
                ),
            atomically:
                true,
            encoding:
                .utf8
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        predicate: () throws -> Bool
    ) rethrows -> Bool {
        let deadline =
            Date()
            .addingTimeInterval(
                timeout
            )

        while Date() < deadline {
            if try predicate() {
                return true
            }

            RunLoop.current.run(
                mode: .default,
                before:
                    Date()
                    .addingTimeInterval(
                        0.05
                    )
            )
        }

        return try predicate()
    }

    private func startProvider(
        label: String,
        python: String,
        script: String,
        root: URL
    ) throws -> RunningProvider {
        let portFile =
            root.appendingPathComponent(
                "\(label).port"
            )

        let logFile =
            root.appendingPathComponent(
                "\(label)-provider.jsonl"
            )

        try? FileManager.default
            .removeItem(
                at: portFile
            )

        try Data().write(
            to: logFile
        )

        let process =
            Process()

        process.executableURL =
            URL(
                fileURLWithPath:
                    python
            )

        process.arguments = [
            script,
            portFile.path,
            logFile.path,
        ]

        let stdout =
            root.appendingPathComponent(
                "\(label)-provider.stdout"
            )

        let stderr =
            root.appendingPathComponent(
                "\(label)-provider.stderr"
            )

        FileManager.default
            .createFile(
                atPath:
                    stdout.path,
                contents:
                    Data()
            )

        FileManager.default
            .createFile(
                atPath:
                    stderr.path,
                contents:
                    Data()
            )

        process.standardOutput =
            try FileHandle(
                forWritingTo:
                    stdout
            )

        process.standardError =
            try FileHandle(
                forWritingTo:
                    stderr
            )

        try process.run()

        let deadline =
            Date()
            .addingTimeInterval(5)

        while Date() < deadline {
            if
                FileManager.default
                    .fileExists(
                        atPath:
                            portFile.path
                    ),
                let value =
                    try? portFromFile(
                        portFile
                    )
            {
                return RunningProvider(
                    process:
                        process,
                    port:
                        value,
                    portFile:
                        portFile,
                    logFile:
                        logFile
                )
            }

            if !process.isRunning {
                throw RightClickError(
                    "Provider exited before publishing a port."
                )
            }

            Thread.sleep(
                forTimeInterval:
                    0.05
            )
        }

        stop(process)

        throw RightClickError(
            "Provider did not publish a port."
        )
    }

    private func startAdvertisement(
        label: String,
        dnsSD: String,
        instance: String,
        host: String,
        port: Int,
        root: URL
    ) throws -> RunningAdvertisement {
        let log =
            root.appendingPathComponent(
                "\(label)-dnssd.log"
            )

        FileManager.default
            .createFile(
                atPath:
                    log.path,
                contents:
                    Data()
            )

        let process =
            Process()

        process.executableURL =
            URL(
                fileURLWithPath:
                    dnsSD
            )

        process.arguments = [
            "-P",
            instance,
            "_rightclick._tcp",
            "local.",
            String(port),
            host,
            "127.0.0.1",
            "kind=openapi",
            "scheme=http",
            "spec=/openapi.json",
            "base=/api",
        ]

        let handle =
            try FileHandle(
                forWritingTo:
                    log
            )

        process.standardOutput =
            handle

        process.standardError =
            handle

        try process.run()

        Thread.sleep(
            forTimeInterval:
                0.20
        )

        guard process.isRunning else {
            throw RightClickError(
                "dns-sd proxy advertisement exited immediately."
            )
        }

        return RunningAdvertisement(
            process:
                process,
            logFile:
                log
        )
    }

    private func portFromFile(
        _ url: URL
    ) throws -> Int {
        let raw =
            try String(
                contentsOf:
                    url,
                encoding:
                    .utf8
            )
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard
            let port = Int(raw),
            (1...65_535)
                .contains(port)
        else {
            throw RightClickError(
                "Invalid provider port."
            )
        }

        return port
    }

    private func stop(
        _ process: Process
    ) {
        guard process.isRunning else {
            return
        }

        process.terminate()

        let deadline =
            Date()
            .addingTimeInterval(2)

        while
            process.isRunning,
            Date() < deadline
        {
            Thread.sleep(
                forTimeInterval:
                    0.02
            )
        }

        if process.isRunning {
            kill(
                process.processIdentifier,
                SIGKILL
            )
        }

        process.waitUntilExit()
    }
}
