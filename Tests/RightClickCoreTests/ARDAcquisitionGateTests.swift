import XCTest
@testable import RightClickCore

/// G12 preregistration.
///
/// Frozen missing behavior:
/// an ARD SearchResponse containing a supported OpenAPI artifact cannot
/// currently enter RIGHTCLICK's live capability graph.
final class ARDAcquisitionGateTests: XCTestCase {
    func testG12ARDOpenAPIArtifactAcquisitionIsCurrentlyRed() throws {
        XCTFail(
            "G12 RED: RIGHTCLICK has no ARD SearchResponse acquisition path yet."
        )
    }
}
