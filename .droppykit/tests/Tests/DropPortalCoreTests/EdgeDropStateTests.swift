import XCTest
@testable import DropPortalCore

/// When the right-edge zone and its light go: nothing may outlive the drag.
final class EdgeDropStateTests: XCTestCase {
    func testBeginShowsOnceAndADropHides() {
        var s = EdgeDropState()
        XCTAssertEqual(s.begin(at: 0), .showZones)
        XCTAssertEqual(s.begin(at: 0.1), .none, "a second begin while shown shows nothing new")
        s.entered(at: 0.2)
        XCTAssertEqual(s.buttonUp(at: 0.3), .none, "button up on the zone waits for the drop")
        XCTAssertTrue(s.visible)
        XCTAssertEqual(s.dropped(), .hide(.dropped))
        XCTAssertFalse(s.visible)
        XCTAssertEqual(s.tick(at: 5, buttonDown: false), .none)
    }

    func testButtonUpAwayHidesAtOnce() {
        var s = EdgeDropState()
        _ = s.begin(at: 0)
        XCTAssertEqual(s.buttonUp(at: 1), .hide(.buttonUpAway))
    }

    func testExitThenButtonUpHides() {
        var s = EdgeDropState()
        _ = s.begin(at: 0)
        s.entered(at: 0.1)
        XCTAssertEqual(s.exited(at: 0.2), .none)
        XCTAssertEqual(s.buttonUp(at: 0.3), .hide(.buttonUpAway))
    }

    func testExitAfterButtonUpHides() {
        var s = EdgeDropState()
        _ = s.begin(at: 0)
        s.entered(at: 0.1)
        _ = s.buttonUp(at: 0.2)
        XCTAssertEqual(s.exited(at: 0.25), .hide(.buttonUpAway))
    }

    func testNoDropAfterButtonUpOnZoneTimesOut() {
        var s = EdgeDropState()
        _ = s.begin(at: 0)
        s.entered(at: 0.1)
        _ = s.buttonUp(at: 1)
        XCTAssertEqual(s.tick(at: 1.5, buttonDown: false), .none)
        XCTAssertEqual(s.tick(at: 1 + EdgeDropState.dropWait, buttonDown: false), .hide(.noDrop))
    }

    func testWatchdogHidesWhenTheWatcherMissesTheEnd() {
        var s = EdgeDropState()
        _ = s.begin(at: 0)
        XCTAssertEqual(s.tick(at: 0.25, buttonDown: true), .none)
        XCTAssertEqual(s.tick(at: 0.5, buttonDown: false), .hide(.buttonUpAway))
    }

    func testWatchdogOnTheZoneWaitsThenHides() {
        var s = EdgeDropState()
        _ = s.begin(at: 0)
        s.entered(at: 0.1)
        XCTAssertEqual(s.tick(at: 0.3, buttonDown: false), .none, "the drop may still land")
        XCTAssertEqual(s.tick(at: 0.31 + EdgeDropState.dropWait, buttonDown: false), .hide(.noDrop))
    }

    func testRestingPointerDimsOnceAndMovementRearms() {
        var s = EdgeDropState()
        _ = s.begin(at: 0)
        XCTAssertEqual(s.tick(at: 1.0, buttonDown: true), .none)
        XCTAssertEqual(s.tick(at: EdgeDropState.stall, buttonDown: true), .dimLight)
        XCTAssertEqual(s.tick(at: 3, buttonDown: true), .none, "dims once")
        XCTAssertTrue(s.visible, "the zone stays while the button is down")
        s.moved(at: 3.1)
        XCTAssertEqual(s.tick(at: 3.11 + EdgeDropState.stall, buttonDown: true), .dimLight)
    }

    func testTearDownAndRefuse() {
        var s = EdgeDropState()
        XCTAssertEqual(s.tearDown(), .none)
        _ = s.begin(at: 0)
        XCTAssertEqual(s.refused(), .hide(.refused))
        _ = s.begin(at: 1)
        XCTAssertEqual(s.tearDown(), .hide(.teardown))
    }
}
