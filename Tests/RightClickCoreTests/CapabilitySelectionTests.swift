import Foundation
import XCTest
@testable import RightClickCore

final class CapabilitySelectionTests: XCTestCase {
    func testExactID() throws {
        XCTAssertEqual(try CapabilitySelection.resolve("capability:alpha", from: [semanticFixture()]).id, "capability:alpha")
    }
    func testUniqueTitleRetainsCompatibility() throws {
        XCTAssertEqual(try CapabilitySelection.resolve("Publish report", from: [semanticFixture()]).id, "capability:alpha")
    }
    func testAmbiguousTitleIsRejected() {
        let rows = [semanticFixture(), semanticFixture(id: "capability:beta", owner: "reflector:beta")]
        XCTAssertThrowsError(try CapabilitySelection.resolve("Publish report", from: rows)) {
            XCTAssertEqual($0 as? CapabilitySelectionError, .ambiguousTitle)
        }
    }
    func testExactIDWinsOverSpoofedTitleRegardlessOfOrder() throws {
        let real = semanticFixture()
        let fake = semanticFixture(id: "capability:fake", title: real.id, owner: "reflector:fake")
        for rows in [[fake, real], [real, fake]] {
            XCTAssertEqual(try CapabilitySelection.resolve(real.id, from: rows).id, real.id)
        }
    }
    func testConflictAcrossReflectorOwnersIsQuarantined() {
        XCTAssertTrue(CapabilitySelection.unambiguous([semanticFixture(), semanticFixture(owner: "reflector:other")]).isEmpty)
    }
    func testConflictingIDCannotBeSelectedDirectly() {
        XCTAssertThrowsError(try CapabilitySelection.resolve("capability:alpha", from: [semanticFixture(), semanticFixture(owner: "other")])) {
            XCTAssertEqual($0 as? CapabilitySelectionError, .conflictingIdentity)
        }
    }
    func testConflictCannotBeHiddenBehindDifferentTitle() {
        let rows = [semanticFixture(), semanticFixture(title: "Something else", owner: "other")]
        XCTAssertThrowsError(try CapabilitySelection.resolve("Publish report", from: rows))
    }
    func testIdenticalDuplicateRemainsAvailable() throws {
        let one = semanticFixture()
        XCTAssertEqual(CapabilitySelection.unambiguous([one, one]).count, 1)
        XCTAssertEqual(try CapabilitySelection.resolve(one.title, from: [one, one]).id, one.id)
    }
    func testLaterRepeatDoesNotHealConflictingID() {
        let one = semanticFixture()
        XCTAssertTrue(CapabilitySelection.unambiguous([one, semanticFixture(owner: "other"), one]).isEmpty)
    }
    func testUnrelatedCapabilitiesSurviveAConflict() {
        let rows = [semanticFixture(), semanticFixture(owner: "other"), semanticFixture(id: "good")]
        XCTAssertEqual(CapabilitySelection.unambiguous(rows).map(\.id), ["good"])
    }
    func testChangesToAuthorityMetadataAreConflicts() {
        var a = semanticFixture(); var b = a
        a.metadata["authorityOrigin"] = "https://first.example"
        b.metadata["authorityOrigin"] = "https://second.example"
        XCTAssertTrue(CapabilitySelection.unambiguous([a, b]).isEmpty)
    }
    func testUnicodeEquivalentMetadataBytesDoNotCollapse() {
        var a = semanticFixture(); var b = a
        a.metadata["authorityScheme"] = "caf\u{e9}"
        b.metadata["authorityScheme"] = "cafe\u{301}"
        XCTAssertEqual(a.metadata["authorityScheme"], b.metadata["authorityScheme"])
        XCTAssertTrue(CapabilitySelection.unambiguous([a, b]).isEmpty)
    }
    func testUnicodeEquivalentIDsRemainByteDistinct() throws {
        let a = semanticFixture(id: "cap:caf\u{e9}", owner: "first")
        let b = semanticFixture(id: "cap:cafe\u{301}", owner: "second")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(CapabilitySelection.unambiguous([a, b]).count, 2)
        XCTAssertEqual(try CapabilitySelection.resolve(a.id, from: [b, a]).reflectorID, "first")
        XCTAssertEqual(try CapabilitySelection.resolve(b.id, from: [a, b]).reflectorID, "second")
    }
    func testTitleMatchingIsByteExact() {
        let a = semanticFixture(title: "caf\u{e9}")
        XCTAssertThrowsError(try CapabilitySelection.resolve("cafe\u{301}", from: [a]))
    }
    func testCaseIsNotSilentlyChanged() {
        XCTAssertThrowsError(try CapabilitySelection.resolve("CAPABILITY:ALPHA", from: [semanticFixture()]))
    }
    func testDictionaryInsertionOrderDoesNotCreateConflict() {
        var a = semanticFixture(); var b = a
        a.metadata = ["x": "one", "y": "two"]
        b.metadata = ["y": "two", "x": "one"]
        XCTAssertEqual(CapabilitySelection.unambiguous([a, b]).count, 1)
    }
    func testComputedPinsAndReservedExperienceCannotCreateConflicts() throws {
        let a = semanticFixture(); var b = a
        b.contractSHA256 = String(repeating: "0", count: 64)
        b.metadata["experience.status"] = "provider-forged"
        b.metadata["experience.predicatesVerified"] = "99999"
        XCTAssertEqual(CapabilitySelection.unambiguous([a, b]).count, 1)
        XCTAssertEqual(try CapabilitySelection.resolve(a.id, from: [a, b]).id, a.id)
        b.metadata["policyEpoch"] = "different"
        XCTAssertTrue(CapabilitySelection.unambiguous([a, b]).isEmpty)
    }
    func testConfirmationDriftCreatesConflict() {
        let a = semanticFixture(); var b = a; b.requiresConfirmation = false
        XCTAssertTrue(CapabilitySelection.unambiguous([a, b]).isEmpty)
    }
    func testUnsupportedAndExecutableSameTitleRequiresExactID() {
        let a = semanticFixture(); var b = semanticFixture(id: "extension:alpha")
        b.invocation = .unsupported
        XCTAssertThrowsError(try CapabilitySelection.resolve(a.title, from: [a, b]))
    }
    func testRemovalDoesNotResurrectPriorCapability() throws {
        _ = try CapabilitySelection.resolve("capability:alpha", from: [semanticFixture()])
        XCTAssertThrowsError(try CapabilitySelection.resolve("capability:alpha", from: []))
    }
    func testEmptyIdentityAndSelectorAreRejected() {
        XCTAssertTrue(CapabilitySelection.unambiguous([semanticFixture(id: "")]).isEmpty)
        XCTAssertThrowsError(try CapabilitySelection.resolve("", from: [semanticFixture(id: "")]))
    }
}
