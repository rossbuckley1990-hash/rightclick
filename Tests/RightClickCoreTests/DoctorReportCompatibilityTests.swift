import Foundation
import XCTest
@testable import RightClickProtocol

/// The PR99 wire shape remains readable alongside PR49's portable host fields.
final class DoctorReportCompatibilityTests: XCTestCase {
    private let legacy = Data(#"""
        {"macosVersion":"14.0","macosBuild":"example","sharingDiscovery":"UNAVAILABLE",
         "sharingExecution":"UNAVAILABLE","sharingSupportLevel":"unavailable",
         "servicesDiscovery":"UNAVAILABLE","servicesExecution":"UNAVAILABLE",
         "servicesSupportLevel":"unavailable","quickActionDiscovery":"UNAVAILABLE",
         "quickActionExecution":"UNAVAILABLE","quickActionSupportLevel":"unavailable",
         "serviceRegistrationCount":0,"actionExtensionCount":0,"notes":["Legacy wire fixture"]}
        """#.utf8)

    func testLegacyDoctorReportDoesNotInventRemotePlatformFacts() throws {
        let report = try JSONDecoder().decode(DoctorReport.self, from: legacy)
        XCTAssertEqual(report.platform, "unknown")
        XCTAssertEqual(report.operatingSystemVersion, "unknown")
        XCTAssertEqual(report.macosVersion, "14.0")
        XCTAssertEqual(report.notes, ["Legacy wire fixture"])
    }

    func testExplicitPortableHostFactsSurviveRoundTrip() throws {
        var report = try JSONDecoder().decode(DoctorReport.self, from: legacy)
        report.platform = "Linux"
        report.operatingSystemVersion = "portable-host-version"
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.platform, "Linux")
        XCTAssertEqual(decoded.operatingSystemVersion, "portable-host-version")
        XCTAssertEqual(decoded.notes, ["Legacy wire fixture"])
    }
}
