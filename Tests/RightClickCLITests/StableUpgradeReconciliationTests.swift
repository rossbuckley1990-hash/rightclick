import Foundation
import XCTest
@testable import RightClickCLI

final class StableUpgradeReconciliationTests:
    XCTestCase
{
    private func executable(
        _ url: URL,
        contents: String
    ) throws {
        try FileManager.default
            .createDirectory(
                at:
                    url
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        try contents.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )

        try FileManager.default
            .setAttributes(
                [
                    .posixPermissions:
                        0o755
                ],
                ofItemAtPath:
                    url.path
            )
    }

    private func environment(
        _ body: (
            URL,
            RightClickStableEntrypoint.Layout,
            URL
        ) throws -> Void
    ) throws {
        let root =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-upgrade-\(UUID().uuidString)"
                )

        defer {
            try? FileManager.default
                .removeItem(
                    at: root
                )
        }

        let layout =
            RightClickStableEntrypoint
                .Layout(
                    stableBin:
                        root
                            .appendingPathComponent(
                                "bin/rightclick"
                            )
                            .path,

                    cellarRoot:
                        root
                            .appendingPathComponent(
                                "Cellar/rightclick"
                            )
                            .path
                )

        let state =
            root.appendingPathComponent(
                "setup-state.json"
            )

        try body(
            root,
            layout,
            state
        )
    }

    private func link(
        _ stable: URL,
        to target: URL
    ) throws {
        if FileManager.default
            .fileExists(
                atPath:
                    stable.path
            )
        {
            try FileManager.default
                .removeItem(
                    at:
                        stable
                )
        }

        try FileManager.default
            .createDirectory(
                at:
                    stable
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        try FileManager.default
            .createSymbolicLink(
                at:
                    stable,
                withDestinationURL:
                    target
            )
    }

    func testUpgradeReconcilesSHAAndPreservesTunnelIdentity()
        throws
    {
        try environment {
            root,
            layout,
            stateFile in

            let v1 =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.0.0/bin/rightclick"
                )

            let v2 =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.1.0/bin/rightclick"
                )

            try executable(
                v1,
                contents:
                    "#!/bin/sh\necho v1\n"
            )

            try executable(
                v2,
                contents:
                    "#!/bin/sh\necho v2\n"
            )

            let stable =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )

            try link(
                stable,
                to:
                    v1
            )

            let old =
                try RightClickSetupStateStore
                    .make(
                        executable:
                            stable.path,
                        chatGPTTunnelID:
                            "tunnel_test_identity",
                        tunnelClientPath:
                            "/stable/tunnel-client",
                        tunnelClientVersion:
                            "0.0.15"
                    )

            try RightClickSetupStateStore
                .write(
                    old,
                    to:
                        stateFile
                )

            let oldSHA =
                old.executableSHA256

            try link(
                stable,
                to:
                    v2
            )

            let changed =
                try RightClickBridgeRuntime
                    .reconcileStableSetupStateIfNeeded(
                        invokedExecutable:
                            stable.path,
                        stateFile:
                            stateFile,
                        layouts:
                            [layout]
                    )

            XCTAssertTrue(
                changed
            )

            let current =
                try RightClickSetupStateStore
                    .read(
                        from:
                            stateFile
                    )

            XCTAssertEqual(
                current.executablePath,
                stable.path
            )

            XCTAssertNotEqual(
                current.executableSHA256,
                oldSHA
            )

            XCTAssertEqual(
                current.executableSHA256,
                try RightClickSetupStateStore
                    .sha256File(
                        stable.path
                    )
            )

            XCTAssertEqual(
                current.chatGPTTunnelID,
                "tunnel_test_identity"
            )

            XCTAssertEqual(
                current.tunnelClientPath,
                "/stable/tunnel-client"
            )

            XCTAssertEqual(
                current.tunnelClientVersion,
                "0.0.15"
            )
        }
    }

    func testCurrentStateIsByteIdenticalNoOp()
        throws
    {
        try environment {
            root,
            layout,
            stateFile in

            let v1 =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.0.0/bin/rightclick"
                )

            try executable(
                v1,
                contents:
                    "#!/bin/sh\necho v1\n"
            )

            let stable =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )

            try link(
                stable,
                to:
                    v1
            )

            let state =
                try RightClickSetupStateStore
                    .make(
                        executable:
                            stable.path,
                        chatGPTTunnelID:
                            "tunnel_test_identity",
                        tunnelClientPath:
                            "/stable/tunnel-client",
                        tunnelClientVersion:
                            "0.0.15"
                    )

            try RightClickSetupStateStore
                .write(
                    state,
                    to:
                        stateFile
                )

            let before =
                try Data(
                    contentsOf:
                        stateFile
                )

            let changed =
                try RightClickBridgeRuntime
                    .reconcileStableSetupStateIfNeeded(
                        invokedExecutable:
                            stable.path,
                        stateFile:
                            stateFile,
                        layouts:
                            [layout]
                    )

            let after =
                try Data(
                    contentsOf:
                        stateFile
                )

            XCTAssertFalse(
                changed
            )

            XCTAssertEqual(
                before,
                after
            )
        }
    }

    func testForeignStateIsNeverHijacked()
        throws
    {
        try environment {
            root,
            layout,
            stateFile in

            let stableTarget =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.0.0/bin/rightclick"
                )

            let foreign =
                root.appendingPathComponent(
                    "development/rightclick"
                )

            try executable(
                stableTarget,
                contents:
                    "#!/bin/sh\necho stable\n"
            )

            try executable(
                foreign,
                contents:
                    "#!/bin/sh\necho development\n"
            )

            let stable =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )

            try link(
                stable,
                to:
                    stableTarget
            )

            let foreignState =
                try RightClickSetupStateStore
                    .make(
                        executable:
                            foreign.path,
                        chatGPTTunnelID:
                            "foreign_tunnel",
                        tunnelClientPath:
                            "/foreign/tunnel",
                        tunnelClientVersion:
                            "0.0.15"
                    )

            try RightClickSetupStateStore
                .write(
                    foreignState,
                    to:
                        stateFile
                )

            let before =
                try Data(
                    contentsOf:
                        stateFile
                )

            XCTAssertThrowsError(
                try RightClickBridgeRuntime
                    .reconcileStableSetupStateIfNeeded(
                        invokedExecutable:
                            stable.path,
                        stateFile:
                            stateFile,
                        layouts:
                            [layout]
                    )
            )

            let after =
                try Data(
                    contentsOf:
                        stateFile
                )

            XCTAssertEqual(
                before,
                after
            )
        }
    }

    func testMissingStateIsNeverCreated()
        throws
    {
        try environment {
            root,
            layout,
            stateFile in

            let target =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.0.0/bin/rightclick"
                )

            try executable(
                target,
                contents:
                    "#!/bin/sh\necho stable\n"
            )

            let stable =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )

            try link(
                stable,
                to:
                    target
            )

            XCTAssertFalse(
                FileManager.default
                    .fileExists(
                        atPath:
                            stateFile.path
                    )
            )

            let changed =
                try RightClickBridgeRuntime
                    .reconcileStableSetupStateIfNeeded(
                        invokedExecutable:
                            stable.path,
                        stateFile:
                            stateFile,
                        layouts:
                            [layout]
                    )

            XCTAssertFalse(
                changed
            )

            XCTAssertFalse(
                FileManager.default
                    .fileExists(
                        atPath:
                            stateFile.path
                    )
            )
        }
    }
}
