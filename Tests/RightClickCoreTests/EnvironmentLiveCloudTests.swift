import Foundation
import XCTest
import RightClickProtocol
import RightClickProviders

/// Real API observation is opt-in and read-only. This gate deliberately makes
/// no claim about create/bootstrap/nesting: a production TTL guard and approved
/// runtime image must be supplied before that separate acceptance can run.
final class EnvironmentLiveCloudTests: XCTestCase {
    func testOptInFlyAuthenticatedObservation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RIGHTCLICK_NESTED_LIVE_FLY_OBSERVE"] == "1" else {
            throw XCTSkip("Live Fly observation is opt-in; no cloud resource is created by this test.")
        }
        guard let token = environment["FLY_API_TOKEN"], !token.isEmpty,
              let app = environment["RIGHTCLICK_NESTED_FLY_APP"],
              let owner = environment["RIGHTCLICK_NESTED_FLY_OWNER"],
              let image = environment["RIGHTCLICK_NESTED_FLY_IMAGE"],
              let executableSHA = environment["RIGHTCLICK_NESTED_FLY_EXECUTABLE_SHA256"] else {
            XCTFail("Opt-in observation requires node-local credentials and the documented fixed operator profile.")
            return
        }
        let spec = try EnvironmentSpec(profileID: "live-observation", lifetimeMilliseconds: 60_000,
            resources: .init(cpuCount: 1, memoryMiB: 256, maximumCostUnits: 10_000))
        let manifest = try EnvironmentRuntimeManifest(version: "operator-approved", executableSHA256: executableSHA,
            architecture: "x86_64")
        let profile = try FlyEnvironmentProfile(app: app, region: environment["RIGHTCLICK_NESTED_FLY_REGION"] ?? "lhr",
            ownerID: owner, ceiling: spec, manifest: manifest, image: image, maximumMicroUSDPerSecond: 1)
        let provider = FlyEnvironmentProvider(profile: profile, credential: { token })
        XCTAssertFalse(provider.support.supportsCreate)
        XCTAssertFalse(provider.support.enforcesTTL)
        let observations = try provider.list()
        XCTAssertTrue(observations.allSatisfy { $0.presence != .unknown })
    }
}
