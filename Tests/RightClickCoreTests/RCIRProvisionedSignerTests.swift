#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

final class RCIRProvisionedSignerTests: XCTestCase {
    func testWithdrawalAtPostSignatureBoundaryReturnsNoSignature() throws {
        let directory = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("rcir-signing-race-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        defer { try? NativeHTTPFixture.remove(directory) }
        let file = directory.appendingPathComponent("key.raw")
        try NativeHTTPFixture.writePrivate(Curve25519.Signing.PrivateKey().rawRepresentation, to: file)
        var checks = 0
        let signer = try RCIRProvisionedSigner(path:file.path, currentReference: {
            checks += 1
            if checks == 2 {
                try? NativeHTTPFixture.release(file); try? FileManager.default.removeItem(at:file)
            }
            return file.path
        })
        XCTAssertThrowsError(try signer.sign(Data("bounded post-signature control".utf8))) { error in
            XCTAssertEqual(error as? RCIRError, .authorityDenied)
        }
        XCTAssertEqual(checks, 2); XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
}
