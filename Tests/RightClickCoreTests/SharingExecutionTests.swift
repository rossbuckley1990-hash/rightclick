@testable import RightClickProtocol
@testable import RightClickProviders
#if os(macOS)
@testable import RightClickMacOS
@testable import RightClickMacOSHost
#endif
import XCTest
@testable import RightClickCore

final class SharingExecutionTests: XCTestCase {
    func testPerformReturnWithoutCallbackStaysStarted() {
        var model = SharingExecutionModel()
        model.performEntered()
        model.performReturned()
        XCTAssertEqual(model.state, .started)
        XCTAssertTrue(model.events.contains("perform returned"))
        XCTAssertTrue(model.events.contains("execution still pending"))
        XCTAssertFalse(model.events.contains { $0.contains("failed") })
    }

    func testWillShareItemsDoesNotFailTheExecution() {
        var model = SharingExecutionModel()
        model.performEntered()
        model.willShareItems(count: 1, main: true)
        model.performReturned()
        XCTAssertEqual(model.state, .started)
        XCTAssertTrue(model.events.contains("willShareItems count=1 main=true"))
    }

    func testDidShareItemsReportsAcceptanceWithoutIndependentOutcome() {
        var model = SharingExecutionModel()
        model.performEntered()
        model.performReturned()
        model.didShareItems(count: 1, main: true)
        XCTAssertEqual(model.state, .accepted)
        XCTAssertTrue(model.message.contains("unverified"))
    }

    func testDidFailToShareItemsFails() {
        var model = SharingExecutionModel()
        model.performEntered()
        model.performReturned()
        model.didFailToShareItems("import refused", main: true)
        XCTAssertEqual(model.state, .failed)
    }

    func testDeadlineWithoutCallbackIsUnknown() {
        var model = SharingExecutionModel()
        model.performEntered()
        model.willShareItems(count: 1, main: true)
        model.performReturned()
        model.deadlineExpired()
        XCTAssertEqual(model.state, .unknown)
        XCTAssertNotEqual(model.state, .failed)
    }

    func testDeadlineDoesNotOverrideATerminalCallback() {
        var model = SharingExecutionModel()
        model.didShareItems(count: 1, main: true)
        model.deadlineExpired()
        XCTAssertEqual(model.state, .accepted)
        XCTAssertTrue(model.message.contains("unverified"))
    }
}

