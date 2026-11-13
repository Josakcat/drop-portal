import Foundation
@testable import DropPortalCore
import XCTest

final class PeekReleaseTests: XCTestCase {
    private func parse(_ object: [String: Any]) throws -> PeekMessage {
        try PeekMessage.parse(JSONSerialization.data(withJSONObject: object))
    }

    func testCommitCarriesTheRelease() throws {
        XCTAssertEqual(try parse(["type": "peek-commit", "id": "p1", "vx": -1800, "vy": 240.5, "exitY": 0.3, "angle": -6]),
                       .commit(id: "p1", release: PeekRelease(vx: -1800, vy: 240.5, exitY: 0.3, angle: -6)))
        // An older page: no release, the Mac flies its own way.
        XCTAssertEqual(try parse(["type": "peek-commit", "id": "p1"]), .commit(id: "p1", release: nil))
        // Junk fields never fail the commit.
        XCTAssertEqual(try parse(["type": "peek-commit", "id": "p1", "vx": "fast", "vy": 1]), .commit(id: "p1", release: nil))
        XCTAssertEqual(try parse(["type": "peek-commit", "id": "p1", "vx": true, "vy": false]), .commit(id: "p1", release: nil))
        // Clamped: exit height 0...1, angle ±90, speed ≤ 20 000 px/s.
        guard case .commit(_, let r?) = try parse(["type": "peek-commit", "id": "p1", "vx": -90000, "vy": 0, "exitY": 4, "angle": 400]) else {
            return XCTFail("no release")
        }
        XCTAssertEqual(r.exitY, 1)
        XCTAssertEqual(r.angle, 90)
        XCTAssertEqual(r.vx, -PeekRelease.maxSpeed, accuracy: 0.001)
        // A zero velocity is still a release (pastEdge drop, no flick).
        XCTAssertEqual(try parse(["type": "peek-commit", "id": "p1", "vx": 0, "vy": 0]),
                       .commit(id: "p1", release: PeekRelease(vx: 0, vy: 0)))
    }

    func testMoveCarriesTheHeight() throws {
        XCTAssertEqual(try parse(["type": "peek-move", "id": "p1", "progress": 0.5, "y": 0.25]), .move(id: "p1", progress: 0.5, y: 0.25))
        XCTAssertEqual(try parse(["type": "peek-move", "id": "p1", "progress": 0.5, "y": -3]), .move(id: "p1", progress: 0.5, y: 0))
        XCTAssertEqual(try parse(["type": "peek-move", "id": "p1", "progress": 0.5]), .move(id: "p1", progress: 0.5, y: nil))
    }

    func testTrackerPassesTheReleaseThrough() {
        var tracker = PeekTracker()
        let t0 = Date()
        _ = tracker.handle(.start(PeekInfo(id: "a", name: "x", kind: .file, size: 1)), now: t0)
        XCTAssertEqual(tracker.handle(.move(id: "a", progress: 0.4, y: 0.7), now: t0), .move(id: "a", progress: 0.4, y: 0.7))
        let release = PeekRelease(vx: -1200, vy: 0, exitY: 0.7)
        XCTAssertEqual(tracker.handle(.commit(id: "a", release: release), now: t0), .commit(id: "a", release: release))
    }

    func testThePageSendsTheRelease() {
        XCTAssertTrue(WebPage.template.contains("type: \"peek-commit\", id: peek.id, vx:"))
        XCTAssertTrue(WebPage.template.contains("exitY"))
    }
}

final class ThrowFlightTests: XCTestCase {
    typealias V = ThrowFlight.Vector
    let from = V(1300, 500), to = V(830, 500)

    func testStartsWithTheReleaseVelocityAndLandsAtRest() {
        let f = ThrowFlight(from: from, to: to, release: V(-1500, 0), base: 0.28)
        XCTAssertEqual(f.position(at: 0).x, from.x, accuracy: 0.001)
        XCTAssertEqual(f.velocity(at: 0).x, f.velocity.x, accuracy: 0.5)
        XCTAssertEqual(f.velocity.x, -1500 * ThrowFlight.gain, accuracy: 0.5)
        XCTAssertEqual(f.position(at: f.duration - 1e-6).x, to.x, accuracy: 0.01)
        XCTAssertEqual(f.velocity(at: f.duration - 1e-4).x, 0, accuracy: 1)
        XCTAssertEqual(f.position(at: f.duration + 1), to)
        XCTAssertEqual(f.progress(at: f.duration), 1)
    }

    func testFastArrivesSoonerSlowDrifts() {
        let fast = ThrowFlight(from: from, to: to, release: V(-3500, 0), base: 0.28)
        let mid = ThrowFlight(from: from, to: to, release: V(-2500, 0), base: 0.28)
        let slow = ThrowFlight(from: from, to: to, release: V(-400, 0), base: 0.28)
        XCTAssertLessThan(fast.duration, mid.duration)
        XCTAssertLessThan(mid.duration, slow.duration)
        // Within the effect's beat.
        for f in [fast, mid, slow] { XCTAssertTrue((0.224 - 1e-9)...0.5801 ~= f.duration, "\(f.duration)") }
        // Slow: never moves backwards.
        var last = slow.position(at: 0).x
        for i in 1...60 {
            let x = slow.position(at: slow.duration * Double(i) / 60).x
            XCTAssertLessThanOrEqual(x, last + 0.001)
            last = x
        }
    }

    func testAHardFlickFliesPastAndComesBackWithinTheCap() {
        let f = ThrowFlight(from: V(1000, 500), to: to, release: V(-12000, 0), base: 0.28)
        let xs = (0...200).map { f.position(at: f.duration * Double($0) / 200).x }
        let past = to.x - xs.min()!
        XCTAssertGreaterThan(past, 5)
        XCTAssertLessThanOrEqual(past, ThrowFlight.maxOvershoot + 2)
    }

    func testDirectionIsKeptInsideTheScreen() {
        // Flicked hard upward: heads up, comes back down, never above the range.
        let f = ThrowFlight(from: V(1300, 600), to: to, release: V(-1500, -2500), base: 0.30, yRange: 150...700)
        XCTAssertGreaterThan(f.velocity.y, 0)
        let ys = (0...100).map { f.position(at: f.duration * Double($0) / 100).y }
        XCTAssertLessThanOrEqual(ys.max()!, 700.5)
        XCTAssertGreaterThanOrEqual(ys.min()!, 149.5)
        // Never more than 55° off straight left, and a rightward release still comes in.
        let back = ThrowFlight(from: from, to: to, release: V(600, 0), base: 0.28)
        XCTAssertLessThan(back.velocity.x, 0)
        let steep = ThrowFlight(from: from, to: to, release: V(-100, 3000), base: 0.28)
        XCTAssertLessThanOrEqual(abs(atan2(steep.velocity.y, -steep.velocity.x)), ThrowFlight.maxAngle + 0.3)
    }

    func testEntryHeight() {
        XCTAssertEqual(ThrowFlight.entryY(exitY: 0, in: 100...700), 700)
        XCTAssertEqual(ThrowFlight.entryY(exitY: 1, in: 100...700), 100)
        XCTAssertEqual(ThrowFlight.entryY(exitY: 0.5, in: 100...700), 400)
    }
}
