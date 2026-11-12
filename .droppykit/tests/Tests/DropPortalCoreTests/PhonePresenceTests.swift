@testable import DropPortalCore
import XCTest

/// "Phone connected" is live: on at the first hello, off a grace after the last page closed.
final class PhonePresenceTests: XCTestCase {
    func testConnectsAtOnceAndLeavesAfterGrace() {
        var p = PhonePresence(grace: 3)
        let t0 = Date()
        XCTAssertFalse(p.isConnected)
        XCTAssertTrue(p.opened())
        XCTAssertTrue(p.isConnected)
        p.closed(at: t0)
        XCTAssertFalse(p.tick(at: t0.addingTimeInterval(2.9)), "still within the grace")
        XCTAssertTrue(p.isConnected)
        XCTAssertTrue(p.tick(at: t0.addingTimeInterval(3)))
        XCTAssertFalse(p.isConnected)
        XCTAssertFalse(p.tick(at: t0.addingTimeInterval(10)), "reports the change once")
    }

    func testQuickReconnectDoesNotFlicker() {
        var p = PhonePresence(grace: 3)
        let t0 = Date()
        p.opened()
        p.closed(at: t0)
        XCTAssertFalse(p.opened(), "already connected: no change to report")
        XCTAssertFalse(p.tick(at: t0.addingTimeInterval(5)))
        XCTAssertTrue(p.isConnected)
    }

    func testStaysConnectedWhileAnyPageIsOpen() {
        var p = PhonePresence(grace: 3)
        let t0 = Date()
        p.opened()
        p.opened()
        p.closed(at: t0)
        XCTAssertEqual(p.pages, 1)
        XCTAssertFalse(p.tick(at: t0.addingTimeInterval(60)))
        XCTAssertTrue(p.isConnected)
        p.closed(at: t0.addingTimeInterval(60))
        XCTAssertTrue(p.tick(at: t0.addingTimeInterval(64)))
        XCTAssertFalse(p.isConnected)
    }

    func testResetIsImmediateAndCloseNeverGoesNegative() {
        var p = PhonePresence()
        p.closed()
        XCTAssertEqual(p.pages, 0)
        XCTAssertFalse(p.reset())
        p.opened()
        XCTAssertTrue(p.reset())
        XCTAssertFalse(p.isConnected)
    }

    /// The real socket: a paired page turns it on, closing it turns it off after the grace.
    func testPeekChannelReportsPresence() throws {
        let channel = PeekChannel(port: 18_798)
        channel.token = "secret-token"
        let on = expectation(description: "connected")
        let off = expectation(description: "gone")
        channel.onPresence = { connected in (connected ? on : off).fulfill() }
        channel.start()
        defer { channel.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:18798/")!)
        task.resume()
        task.send(.string(#"{"type":"hello","t":"secret-token"}"#)) { _ in }
        wait(for: [on], timeout: 3)
        task.cancel(with: .goingAway, reason: nil)
        wait(for: [off], timeout: PhonePresence.defaultGrace + 3)
    }
}

/// The widget's "2 min ago".
final class ShortAgeTests: XCTestCase {
    func testShortAge() {
        let now = Date()
        func age(_ s: TimeInterval) -> String { TransferRecord.shortAge(of: now.addingTimeInterval(-s), now: now) }
        XCTAssertEqual(age(0), "just now")
        XCTAssertEqual(age(59), "just now")
        XCTAssertEqual(age(120), "2 min ago")
        XCTAssertEqual(age(3599), "59 min ago")
        XCTAssertEqual(age(7200), "2 h ago")
        XCTAssertEqual(age(3 * 86_400), "3 d ago")
        XCTAssertEqual(TransferRecord.shortAge(of: now.addingTimeInterval(30), now: now), "just now", "a clock skew is never negative")
    }
}
