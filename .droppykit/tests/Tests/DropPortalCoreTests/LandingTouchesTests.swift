import XCTest
@testable import DropPortalCore

/// The landing touches' numbers (LandingTouches.swift): springs, sparks, the kinetic name.
final class LandingTouchesTests: XCTestCase {
    // MARK: Springs

    func testSpringConstantsMatchTheSpec() {
        XCTAssertEqual(LandSpring.settle.stiffness, 322.3, accuracy: 0.1)
        XCTAssertEqual(LandSpring.settle.damping, 32.31, accuracy: 0.01)
        XCTAssertEqual(LandSpring.settle.dampingRatio, 0.90, accuracy: 0.005)
        XCTAssertEqual(LandSpring.tilt.stiffness, 631.7, accuracy: 0.1)
        XCTAssertEqual(LandSpring.tilt.damping, 50.27, accuracy: 0.01)
        XCTAssertEqual(LandSpring.tilt.dampingRatio, 1, accuracy: 1e-9)
    }

    func testSettleIsNotBouncy() {
        // Overshoot (remaining below 0) stays under 1 %, and it is home by 0.45 s (the land's length).
        var lowest = 1.0
        for i in 0...450 { lowest = min(lowest, LandSpring.settle.remaining(at: Double(i) / 1000)) }
        XCTAssertGreaterThan(lowest, -0.01)
        XCTAssertLessThan(abs(LandSpring.settle.remaining(at: 0.38)), 0.01)
        // Critically damped tilt never crosses.
        for i in 0...500 { XCTAssertGreaterThanOrEqual(LandSpring.tilt.remaining(at: Double(i) / 1000), -1e-9) }
    }

    func testStepFollowsTheClosedForm() {
        var x = 1.0, v = 0.0
        let s = LandSpring.settle
        for _ in 0..<(240 / 4) { s.step(value: &x, velocity: &v, target: 0, dt: 1.0 / 240) }
        XCTAssertEqual(x, s.remaining(at: 0.25), accuracy: 0.02)
    }

    // MARK: Sparks

    func testSparkRingIsAroundThePerimeterAndOver() {
        let size = CGSize(width: 240, height: 268)
        let ring = SparkRing(count: 20, size: size)
        XCTAssertEqual(ring.sparks.count, 20)
        for s in ring.sparks {
            // On the rounded rectangle: never inside it by more than the rounding, never outside.
            XCTAssertLessThanOrEqual(abs(s.start.x), 120.001)
            XCTAssertLessThanOrEqual(abs(s.start.y), 134.001)
            XCTAssertTrue(abs(abs(s.start.x) - 120) < 0.01 || abs(abs(s.start.y) - 134) < 0.01 || (abs(s.start.x) > 102 && abs(s.start.y) > 116))
            XCTAssertTrue(SparkRing.lifeRange.contains(s.life))
            XCTAssertTrue(SparkRing.speedRange.contains(s.speed))
            XCTAssertTrue(SparkRing.sizeRange.contains(s.size))
            // Outward.
            XCTAssertGreaterThan((s.start * s.direction).sum(), 0)
            XCTAssertNil(SparkRing.state(s, at: 0.71))
            let mid = SparkRing.state(s, at: 0.2)!
            XCTAssertLessThan(mid.alpha, 1)
            XCTAssertLessThanOrEqual(((mid.position - s.start) * (mid.position - s.start)).sum().squareRoot(), SparkRing.reach)
        }
        XCTAssertEqual(SparkRing(size: size).sparks, ring.sparks, "same seed, same ring")
        XCTAssertEqual(SparkRing.count(lowPower: true), 14)
    }

    // MARK: Kinetic name

    func testStaggerIsCappedSoFortyLettersFinishInTime() {
        XCTAssertEqual(KineticName.stagger(count: 10), 0.025, accuracy: 1e-9)
        XCTAssertEqual(KineticName.stagger(count: 40), 0.0075, accuracy: 1e-9)
        for n in [1, 5, 12, 40, 80, 240] {
            XCTAssertLessThanOrEqual(KineticName.total(count: n), KineticName.cap, "n = \(n)")
        }
    }

    func testGlyphGoesFromBlurredAndLowToSharpAndHome() {
        let start = KineticName.glyph(0, of: 10, at: 0)
        XCTAssertEqual(start.opacity, 0)
        XCTAssertEqual(start.blur, KineticName.blur, accuracy: 1e-9)
        XCTAssertEqual(start.drop, KineticName.rise, accuracy: 1e-9)
        XCTAssertTrue((2...4).contains(start.blur))
        XCTAssertTrue((4...6).contains(start.drop))
        let end = KineticName.glyph(9, of: 10, at: KineticName.total(count: 10))
        XCTAssertEqual(end.opacity, 1)
        XCTAssertEqual(end.blur, 0, accuracy: 1e-9)
        XCTAssertLessThan(abs(end.drop), 0.15)
        // The rise overshoots at most 10 % (bounce ≤ 0.1).
        var lowest = 0.0
        for i in 0...400 { lowest = min(lowest, KineticName.glyph(0, of: 1, at: Double(i) / 1000).drop) }
        XCTAssertGreaterThan(lowest, -KineticName.rise * 0.1)
        // A later letter has not started yet.
        XCTAssertEqual(KineticName.glyph(5, of: 10, at: 0.1).opacity, 0)
        XCTAssertEqual(KineticName.calmOpacity(at: 0.1), 0.5, accuracy: 1e-9)
    }

    func testMiddleTruncationKeepsTheExtension() {
        let width: (String) -> Double = { Double($0.count) }
        let name = "IMG_4821 summer trip to the beach.HEIC"
        let cut = KineticName.truncate(name, maxWidth: 20, width: width)
        XCTAssertLessThanOrEqual(cut.count, 20)
        XCTAssertTrue(cut.hasSuffix(".HEIC"))
        XCTAssertTrue(cut.hasPrefix("IMG_48"))
        XCTAssertTrue(cut.contains("…"))
        XCTAssertFalse(cut.contains(" …") || cut.contains("… "), "no space hugs the ellipsis: \(cut)")
        XCTAssertEqual(KineticName.truncate("short.pdf", maxWidth: 20, width: width), "short.pdf")
        // No extension: cut in the middle all the same.
        let plain = KineticName.truncate("A very long name without any dot in it", maxWidth: 16, width: width)
        XCTAssertTrue((14...16).contains(plain.count), plain)
        XCTAssertTrue(plain.hasPrefix("A very"))
        // Too narrow even for "….ext": what fits.
        XCTAssertLessThanOrEqual(KineticName.truncate(name, maxWidth: 3, width: width).count, 3)
        XCTAssertEqual(KineticName.extensionStart(in: cut), cut.count - 5)
        XCTAssertNil(KineticName.extensionStart(in: ".bashrc"))
        XCTAssertEqual(KineticName.splitExtension("archive.tar.gz").ext, ".gz")
        XCTAssertEqual(KineticName.splitExtension("Version 2. final").ext, "")
    }
}
