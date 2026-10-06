import Foundation
import XCTest
@testable import RightClickCLI

final class StableEntrypointTests:
    XCTestCase
{
    private func makeExecutable(
        _ file: URL,
        contents: String
    ) throws {
        try FileManager.default
            .createDirectory(
                at:
                    file
                        .deletingLastPathComponent(),
                withIntermediateDirectories:
                    true
            )

        try contents.write(
            to: file,
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
                    file.path
            )
    }

    private func isolated(
        _ body: (
            URL,
            RightClickStableEntrypoint.Layout
        ) throws -> Void
    ) throws {
        let root =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "rightclick-stable-\(UUID().uuidString)"
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

        try body(
            root,
            layout
        )
    }

    func testStableBinResolvesToItself()
        throws
    {
        try isolated {
            root,
            layout in

            let cellar =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.0.0/bin/rightclick"
                )

            try makeExecutable(
                cellar,
                contents:
                    "#!/bin/sh\necho one\n"
            )

            let stable =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )

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
                        cellar
                )

            XCTAssertEqual(
                try RightClickStableEntrypoint
                    .resolve(
                        invokedExecutable:
                            stable.path,
                        layouts:
                            [layout]
                    ),
                stable.path
            )
        }
    }

    func testCurrentCellarBinaryCollapsesToStableBin()
        throws
    {
        try isolated {
            root,
            layout in

            let cellar =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.0.0/bin/rightclick"
                )

            try makeExecutable(
                cellar,
                contents:
                    "#!/bin/sh\necho one\n"
            )

            let stable =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )

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
                        cellar
                )

            XCTAssertEqual(
                try RightClickStableEntrypoint
                    .resolve(
                        invokedExecutable:
                            cellar.path,
                        layouts:
                            [layout]
                    ),
                stable.path
            )
        }
    }

    func testDevelopmentBuildIsRejected()
        throws
    {
        try isolated {
            root,
            layout in

            let dev =
                root.appendingPathComponent(
                    "project/.build/release/rightclick"
                )

            try makeExecutable(
                dev,
                contents:
                    "#!/bin/sh\necho dev\n"
            )

            XCTAssertThrowsError(
                try RightClickStableEntrypoint
                    .resolve(
                        invokedExecutable:
                            dev.path,
                        layouts:
                            [layout]
                    )
            )
        }
    }

    func testStableSymlinkCannotPointOutsideCellar()
        throws
    {
        try isolated {
            root,
            layout in

            let dev =
                root.appendingPathComponent(
                    "project/rightclick"
                )

            try makeExecutable(
                dev,
                contents:
                    "#!/bin/sh\necho dev\n"
            )

            let stable =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )

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
                        dev
                )

            XCTAssertThrowsError(
                try RightClickStableEntrypoint
                    .resolve(
                        invokedExecutable:
                            dev.path,
                        layouts:
                            [layout]
                    )
            )
        }
    }

    func testStaleCellarBinaryIsRejectedAfterUpgrade()
        throws
    {
        try isolated {
            root,
            layout in

            let v1 =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.0.0/bin/rightclick"
                )

            let v2 =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.1.0/bin/rightclick"
                )

            try makeExecutable(
                v1,
                contents:
                    "#!/bin/sh\necho one\n"
            )

            try makeExecutable(
                v2,
                contents:
                    "#!/bin/sh\necho two\n"
            )

            let stable =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )

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
                        v2
                )

            XCTAssertThrowsError(
                try RightClickStableEntrypoint
                    .resolve(
                        invokedExecutable:
                            v1.path,
                        layouts:
                            [layout]
                    )
            )

            XCTAssertEqual(
                try RightClickStableEntrypoint
                    .resolve(
                        invokedExecutable:
                            v2.path,
                        layouts:
                            [layout]
                    ),
                stable.path
            )
        }
    }

    func testStableSHAChangesWhenHomebrewRetargetsSymlink()
        throws
    {
        try isolated {
            root,
            layout in

            let v1 =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.0.0/bin/rightclick"
                )

            let v2 =
                root.appendingPathComponent(
                    "Cellar/rightclick/1.1.0/bin/rightclick"
                )

            try makeExecutable(
                v1,
                contents:
                    "#!/bin/sh\necho version-one\n"
            )

            try makeExecutable(
                v2,
                contents:
                    "#!/bin/sh\necho version-two\n"
            )

            let stable =
                URL(
                    fileURLWithPath:
                        layout.stableBin
                )

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
                        v1
                )

            let first =
                try RightClickSetupStateStore
                    .sha256File(
                        stable.path
                    )

            try FileManager.default
                .removeItem(
                    at:
                        stable
                )

            try FileManager.default
                .createSymbolicLink(
                    at:
                        stable,
                    withDestinationURL:
                        v2
                )

            let second =
                try RightClickSetupStateStore
                    .sha256File(
                        stable.path
                    )

            XCTAssertNotEqual(
                first,
                second
            )

            XCTAssertEqual(
                try RightClickStableEntrypoint
                    .resolve(
                        invokedExecutable:
                            stable.path,
                        layouts:
                            [layout]
                    ),
                stable.path
            )
        }
    }
}
