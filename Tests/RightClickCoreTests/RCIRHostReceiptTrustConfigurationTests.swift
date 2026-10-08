import Foundation
import XCTest
@testable import RightClickCore

final class RCIRHostReceiptTrustConfigurationTests: XCTestCase {
    private let prefix = #"{"version":1,"revision":"fixture","deniedCapabilities":[],"#

    func testReceiptPolicyIsAnOptionalClosedHostReference() throws {
        let legacy = try RCIRHostConfiguration.decode(Data(#"{"version":1,"revision":"fixture","deniedCapabilities":[]}"#.utf8))
        XCTAssertNil(legacy.receiptTrustPolicyFile)
        let current = try RCIRHostConfiguration.decode(Data((prefix + #""signingKeyFile":"/owned/key","receiptTrustPolicyFile":"/owned/trust"}"#).utf8))
        XCTAssertEqual(current.signingKeyFile,"/owned/key")
        XCTAssertEqual(current.receiptTrustPolicyFile,"/owned/trust")
        XCTAssertThrowsError(try RCIRHostConfiguration.decode(Data((prefix + #""providerReceiptPolicy":"/provider/claim"}"#).utf8)))
    }

    func testRawDuplicateReferencesAndEscapedAliasesReject() throws {
        for fields in [
            #""receiptTrustPolicyFile":"/owned/first","receiptTrustPolicyFile":"/owned/second"}"#,
            #""receiptTrustPolicyFile":"/owned/first","receiptTrust\u0050olicyFile":"/owned/second"}"#,
            #""signingKeyFile":"/owned/first","signing\u004beyFile":"/owned/second"}"#,
            #""observers":{"id":{"urlTemplate":"first","urlTemplate":"second"}}}"#,
        ] {
            XCTAssertThrowsError(try RCIRHostConfiguration.decode(Data((prefix + fields).utf8))) { error in
                XCTAssertEqual(error as? RCIRError,.invalidContract)
            }
        }
    }

    func testMalformedTypesAndOverLimitConfigurationReject() throws {
        for value in ["true","17","[]","{}"] {
            XCTAssertThrowsError(try RCIRHostConfiguration.decode(Data((prefix + "\"receiptTrustPolicyFile\":" + value + "}").utf8)))
        }
        XCTAssertThrowsError(try RCIRHostConfiguration.decode(Data(repeating:32,count:65_537))) { error in
            XCTAssertEqual(error as? RCIRError,.invalidLimit)
        }
    }
}
