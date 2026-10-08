@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import Foundation
#if os(macOS)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
import XCTest
@testable import RightClickCore

final class OutcomeVerifierTests: XCTestCase {
    private func temporaryFile(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rightclick-outcome-verifier-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        return root.appendingPathComponent(name)
    }

    @discardableResult
    private func run(
        _ executable: String,
        _ arguments: [String]
    ) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output =
            stdout.fileHandleForReading.readDataToEndOfFile()
            + stderr.fileHandleForReading.readDataToEndOfFile()

        let text = String(
            data: output,
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "OutcomeVerifierTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(executable) failed: \(text)"
                ]
            )
        }

        return text
    }

    #if os(macOS)
    private func makeJPEG(
        at url: URL,
        metadataValue: String
    ) throws {
        let width = 2
        let height = 2

        let pixels: [UInt8] = [
            255, 0,   0,   255,
            0,   255, 0,   255,
            0,   0,   255, 255,
            255, 255, 255, 255,
        ]

        let data = Data(pixels)

        guard
            let provider = CGDataProvider(
                data: data as CFData
            )
        else {
            XCTFail("Could not create CGDataProvider")
            return
        }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )

        guard
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            XCTFail("Could not create CGImage")
            return
        }

        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            XCTFail("Could not create JPEG destination")
            return
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFArtist: metadataValue
            ]
        ]

        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )

        XCTAssertTrue(
            CGImageDestinationFinalize(destination)
        )
    }

    #endif

    func testNoPostconditionsCannotBecomeSuccess() throws {
        let item = ContentItem(
            kind: "text",
            display: "hello",
            text: "hello",
            typeIdentifier: "public.plain-text"
        )

        let before = try OutcomeVerifier.snapshot(
            item: item
        )

        let verification = try OutcomeVerifier.verify(
            spec: VerificationSpec(predicates: []),
            item: item,
            before: before,
            returnedText: "provider said something"
        )

        XCTAssertEqual(
            verification.status,
            .unverified
        )

        XCTAssertTrue(
            verification.predicates.isEmpty
        )
    }

    func testExactReturnedTextCanVerifySuccess() throws {
        let item = ContentItem(
            kind: "text",
            display: "RightClick",
            text: "RightClick",
            typeIdentifier: "public.plain-text"
        )

        let before = try OutcomeVerifier.snapshot(
            item: item
        )

        let spec = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .textEquals,
                    value: "ＲｉｇｈｔＣｌｉｃｋ"
                )
            ]
        )

        let verification = try OutcomeVerifier.verify(
            spec: spec,
            item: item,
            before: before,
            returnedText: "ＲｉｇｈｔＣｌｉｃｋ"
        )

        XCTAssertEqual(
            verification.status,
            .verifiedSuccess
        )

        XCTAssertEqual(
            verification.predicates.count,
            1
        )

        XCTAssertEqual(
            verification.predicates.first?.passed,
            true
        )
    }

    #if os(macOS)
    func testXattrRemovalAndUnchangedBytesVerifySuccess() throws {
        let file = try temporaryFile("fixture.jpg")

        try Data("RIGHTCLICK-XATTR-BYTES".utf8)
            .write(to: file)

        let attribute =
            "com.rightclick.northstar003.unit"

        try run(
            "/usr/bin/xattr",
            [
                "-w",
                attribute,
                "RIGHTCLICK-XATTR-VALUE",
                file.path,
            ]
        )

        let item = ContentItem(
            kind: "file",
            display: file.path,
            path: file.path,
            typeIdentifier: "public.data"
        )

        let before = try OutcomeVerifier.snapshot(
            item: item
        )

        try run(
            "/usr/bin/xattr",
            [
                "-d",
                attribute,
                file.path,
            ]
        )

        let spec = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .xattrAbsent,
                    key: attribute
                ),
                VerificationPredicate(
                    type: .fileSHA256Equals,
                    reference: "before"
                ),
            ]
        )

        let verification = try OutcomeVerifier.verify(
            spec: spec,
            item: item,
            before: before,
            returnedText: nil
        )

        XCTAssertEqual(
            verification.status,
            .verifiedSuccess
        )

        XCTAssertEqual(
            verification.predicates.map(\.passed),
            [true, true]
        )
    }

    #endif

    #if os(macOS)
    func testMetadataValueStillPresentIsVerifiedFailure() throws {
        let marker =
            "RIGHTCLICK-NORTHSTAR003-METADATA-UNIT"

        let file = try temporaryFile("metadata.jpg")

        try makeJPEG(
            at: file,
            metadataValue: marker
        )

        let item = ContentItem(
            kind: "image",
            display: file.path,
            path: file.path,
            typeIdentifier: "public.jpeg"
        )

        let before = try OutcomeVerifier.snapshot(
            item: item
        )

        let spec = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .metadataValueAbsent,
                    value: marker
                ),
                VerificationPredicate(
                    type: .fileReadable
                ),
            ]
        )

        // Deliberately do nothing to the JPEG.
        // The metadata postcondition must therefore fail.
        let verification = try OutcomeVerifier.verify(
            spec: spec,
            item: item,
            before: before,
            returnedText: nil
        )

        XCTAssertEqual(
            verification.status,
            .verifiedFailure
        )

        XCTAssertEqual(
            verification.predicates.count,
            2
        )

        XCTAssertEqual(
            verification.predicates[0].passed,
            false
        )

        XCTAssertEqual(
            verification.predicates[1].passed,
            true
        )
    }

    #endif

    func testAnyFalseRequiredPredicateMakesWholeOutcomeFail() throws {
        let file = try temporaryFile("ordinary.txt")

        try Data("unchanged".utf8)
            .write(to: file)

        let item = ContentItem(
            kind: "file",
            display: file.path,
            path: file.path,
            typeIdentifier: "public.plain-text"
        )

        let before = try OutcomeVerifier.snapshot(
            item: item
        )

        let spec = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .fileExists
                ),
                VerificationPredicate(
                    type: .fileSHA256Differs,
                    reference: "before"
                ),
            ]
        )

        let verification = try OutcomeVerifier.verify(
            spec: spec,
            item: item,
            before: before,
            returnedText: nil
        )

        XCTAssertEqual(
            verification.status,
            .verifiedFailure
        )

        XCTAssertEqual(
            verification.predicates.map(\.passed),
            [true, false]
        )
    }

    #if os(Linux)
    func testUnavailableNativeObservationsCannotVerifySuccess() throws {
        let file = try temporaryFile("unobservable.jpg")
        try Data("fixture bytes".utf8).write(to: file)
        let item = ContentItem(kind: "image", display: file.path, path: file.path, typeIdentifier: "public.jpeg")
        let before = try OutcomeVerifier.snapshot(item: item)
        let spec = VerificationSpec(predicates: [
            VerificationPredicate(type: .xattrAbsent, key: "user.rightclick.fixture"),
            VerificationPredicate(type: .dimensionsEqual, width: 2, height: 2),
            VerificationPredicate(type: .metadataValueAbsent, value: "fixture-marker"),
        ])
        let verification = try OutcomeVerifier.verify(spec: spec, item: item, before: before, returnedText: nil)
        XCTAssertEqual(verification.status, .unverified)
        XCTAssertEqual(verification.predicates.count, 3)
        XCTAssertTrue(verification.predicates.allSatisfy { $0.passed == nil })
    }
    #endif

    func testVerificationSpecRoundTripsThroughJSON() throws {
        let original = VerificationSpec(
            predicates: [
                VerificationPredicate(
                    type: .metadataValueAbsent,
                    value: "secret"
                ),
                VerificationPredicate(
                    type: .dimensionsEqual,
                    width: 256,
                    height: 256
                ),
                VerificationPredicate(
                    type: .fileSizeLessThan,
                    bytes: 50_000
                ),
            ]
        )

        let data = try JSONEncoder().encode(original)

        let decoded = try JSONDecoder().decode(
            VerificationSpec.self,
            from: data
        )

        XCTAssertEqual(
            decoded,
            original
        )
    }
}
