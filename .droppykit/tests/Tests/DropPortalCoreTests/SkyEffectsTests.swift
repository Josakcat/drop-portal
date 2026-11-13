import XCTest
@testable import DropPortalCore

final class SkyEffectsTests: XCTestCase {
    // MARK: Curves

    func testCurvesStartAndEndAndMatchTheirShape() {
        for f in [SkyCurve.accelerate, SkyCurve.decelerate] {
            XCTAssertEqual(f(0), 0, accuracy: 1e-6)
            XCTAssertEqual(f(1), 1, accuracy: 1e-6)
        }
        // Accelerate is slow at first, decelerate fast at first.
        XCTAssertLessThan(SkyCurve.accelerate(0.5), 0.25)
        XCTAssertGreaterThan(SkyCurve.decelerate(0.2), 0.7)
        // Monotone.
        var a = 0.0, d = 0.0
        for i in 1...100 {
            let x = Double(i) / 100
            XCTAssertGreaterThanOrEqual(SkyCurve.accelerate(x), a - 1e-9)
            XCTAssertGreaterThanOrEqual(SkyCurve.decelerate(x), d - 1e-9)
            a = SkyCurve.accelerate(x); d = SkyCurve.decelerate(x)
        }
    }

    // MARK: Stardust

    func testReleaseSweepsLeftToRightAndArrivalRightToLeft() {
        XCTAssertLessThan(Stardust.release(x: 0, shape: 0.5, scatter: 0.5), Stardust.release(x: 1, shape: 0.5, scatter: 0.5))
        XCTAssertGreaterThan(Stardust.arrival(x: 0, shape: 0.5, scatter: 0.5), Stardust.arrival(x: 1, shape: 0.5, scatter: 0.5))
        // 0.5x + 0.2·noise + 0.3·rand stays in 0…1.
        XCTAssertEqual(Stardust.release(x: 1, shape: 1, scatter: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(Stardust.release(x: 0, shape: 0, scatter: 0), 0, accuracy: 1e-9)
        for i in 0..<200 {
            let x = SkyHash.unit(UInt32(i)), y = SkyHash.unit(UInt32(i + 999))
            let s = Stardust.shape(x: x, y: y)
            XCTAssert((0...1).contains(s))
        }
    }

    func testEveryMacGrainIsHomeAndFullSizeByTheLanding() {
        let L = Stardust.macFlight
        XCTAssertEqual(L, 0.78, accuracy: 1e-9)
        for i in 0..<2000 {
            let x = SkyHash.unit(UInt32(i)), y = SkyHash.unit(UInt32(i) &+ 7919)
            let r = SkyHash.unit(UInt32(i) &+ 104_729), len = SkyHash.unit(UInt32(i) &+ 1_299_709)
            // Nothing launches during the hold.
            XCTAssertNil(Stardust.macGrain(x: x, y: y, scatter: r, length: len, at: Stardust.holdSeconds - 0.001))
            guard let g = Stardust.macGrain(x: x, y: y, scatter: r, length: len, at: L) else { return XCTFail("grain \(i) not launched") }
            XCTAssertEqual(g.progress, 1, accuracy: 1e-6)
            XCTAssertEqual(g.size, 1, accuracy: 1e-6)
            XCTAssertEqual(g.curl, 0, accuracy: 1e-6)
        }
        // Mid-flight a grain is a dot with some curl left.
        let mid = Stardust.macGrain(x: 1, y: 0.5, scatter: 0, length: 0, at: Stardust.holdSeconds + 0.1)!
        XCTAssertEqual(mid.size, 0)
        XCTAssertGreaterThan(mid.curl, 0)
    }

    func testRightSideLaunchesFirst() {
        let right = Stardust.macGrain(x: 1, y: 0.3, scatter: 0.5, length: 0.5, at: 0.12)
        let left = Stardust.macGrain(x: 0, y: 0.3, scatter: 0.5, length: 0.5, at: 0.12)
        XCTAssertNotNil(right)
        XCTAssertNil(left)
    }

    func testGridScalesDownUnderBudget() {
        let full = Stardust.grid(width: 240, height: 300, step: 1, budget: 200_000)
        XCTAssertEqual(full.columns * full.rows, 72_000)
        let phone = Stardust.grid(width: 280, height: 380, step: 2, budget: 40_000)
        XCTAssertEqual(phone.columns * phone.rows, 140 * 190)
        let tight = Stardust.grid(width: 360, height: 480, step: 1, budget: 50_000)
        XCTAssertLessThanOrEqual(tight.columns * tight.rows, 50_000)
    }

    func testGlintStaysInsideHeadroomAndEnds() {
        XCTAssertEqual(Stardust.glint(at: -0.01, headroom: 4), 1)
        XCTAssertEqual(Stardust.glint(at: Stardust.glintSeconds, headroom: 4), 1)
        var peak = 0.0
        for i in 0..<150 { peak = max(peak, Stardust.glint(at: Double(i) / 1000, headroom: 16)) }
        XCTAssertEqual(peak, Stardust.glintPeak, accuracy: 0.05)
        for i in 0..<150 { XCTAssertLessThanOrEqual(Stardust.glint(at: Double(i) / 1000, headroom: 2), 2 + 1e-9) }
        // An SDR screen gets no glint above white.
        for i in 0..<150 { XCTAssertEqual(Stardust.glint(at: Double(i) / 1000, headroom: 1), 1) }
    }

    // MARK: Lightning bolt

    func testBoltIsPinnedToItsEndsWithTheRightNumberOfPoints() {
        for gens in [5, 6] {
            let bolt = LightningBolt(from: (1000, 400), to: (600, 420), seed: 42, generations: gens, branches: 3)
            XCTAssertEqual(bolt.trunk.points.count, (1 << gens) + 1)
            XCTAssertEqual(bolt.trunk.points.first, .init(x: 1000, y: 400, along: 0))
            XCTAssertEqual(bolt.trunk.points.last, .init(x: 600, y: 420, along: 1))
            XCTAssert((2...4).contains(bolt.branches.count))
            // About 100 to 300 vertices in all.
            let total = bolt.lines.map(\.points.count).reduce(0, +)
            XCTAssert((60...320).contains(total), "\(gens): \(total)")
        }
    }

    func testBranchesLeaveAtAboutThirtyDegreesAndAreThinner() {
        for seed in UInt32(1)...UInt32(40) {
            let bolt = LightningBolt(from: (0, 0), to: (-400, 0), seed: seed, branches: 4)
            for b in bolt.branches {
                XCTAssert((0.4...0.6).contains(b.weight))
                let a = b.points.first!, z = b.points.last!
                let angle = abs(atan2(z.y - a.y, z.x - a.x) * 180 / .pi)
                // Heading left is 180°; a branch is 24° to 36° off it.
                XCTAssert((180 - 37...180 - 23).contains(angle), "seed \(seed): \(angle)")
            }
        }
    }

    func testSameSeedSameBolt() {
        let a = LightningBolt(from: (0, 0), to: (300, 50), seed: 7), b = LightningBolt(from: (0, 0), to: (300, 50), seed: 7)
        XCTAssertEqual(a.trunk.points, b.trunk.points)
        let c = LightningBolt(from: (0, 0), to: (300, 50), seed: 8)
        XCTAssertNotEqual(a.trunk.points, c.trunk.points)
    }

    // MARK: Strike timeline

    func testStrikeTimeline() {
        let all = [true, true]
        // One re-strike: two flashes a strike.
        XCTAssertEqual(LightningStrike.flashesPerStrike, 2)
        XCTAssertEqual(LightningStrike.reveal(at: 0), 0.25)
        XCTAssertEqual(LightningStrike.reveal(at: 0.016), 0.5)
        XCTAssertEqual(LightningStrike.reveal(at: 0.059), 1)
        XCTAssertEqual(LightningStrike.level(at: 0.03, allowed: all).level, LightningStrike.leaderLevel, accuracy: 1e-9)
        let stroke = LightningStrike.level(at: 0.07, allowed: all)
        XCTAssertTrue(stroke.flash)
        XCTAssertEqual(stroke.level, 1)
        XCTAssertFalse(LightningStrike.level(at: 0.12, allowed: all).flash)
        XCTAssertTrue(LightningStrike.level(at: 0.06 + 0.09 + 0.01, allowed: all).flash)
        // Nothing flashes again after the one re-strike (the old second one was at +160 ms).
        XCTAssertFalse(LightningStrike.level(at: 0.06 + 0.16 + 0.01, allowed: all).flash)
        XCTAssertEqual(LightningStrike.level(at: LightningStrike.end, allowed: all).level, 0)
        // The whole strike is 300–450 ms.
        XCTAssert((0.3...0.45).contains(LightningStrike.end))
        // A refused stroke never goes above the leader's level.
        for i in 0..<450 {
            XCTAssertLessThanOrEqual(LightningStrike.level(at: Double(i) / 1000, allowed: [false, false, false]).level, LightningStrike.leaderLevel + 1e-9)
            XCTAssertFalse(LightningStrike.level(at: Double(i) / 1000, allowed: [false, false, false]).flash)
        }
    }

    /// Counts the flashes a run of strikes really draws, sampled at 240 Hz.
    private func flashOnsets(strikes: [Double]) -> [Double] {
        var limiter = FlashLimiter()
        let plans = strikes.map { limiter.plan(strikeAt: $0) }
        var onsets: [Double] = []
        var was = false
        for i in 0..<Int(((strikes.max() ?? 0) + 1) * 240) {
            let t = Double(i) / 240
            var on = false
            for (s, plan) in zip(strikes, plans) where LightningStrike.level(at: t - s, allowed: plan).flash { on = true }
            if on, !was { onsets.append(t) }
            was = on
        }
        return onsets
    }

    func testSecondSendWithinASecondStillFlashes() {
        // Two flicks 0.5 s apart: the second one's stroke is bright.
        let onsets = flashOnsets(strikes: [0, 0.5])
        XCTAssertEqual(onsets.count, 3, "\(onsets)")
        XCTAssert(onsets.contains { $0 >= 0.5 }, "\(onsets)")
    }

    func testNeverMoreThanThreeFlashesInAnySecond() {
        // One strike, a burst of flicks 150 ms apart, and a steady one every 0.4 s.
        for strikes in [[0.0], (0..<8).map { Double($0) * 0.15 }, (0..<10).map { Double($0) * 0.4 }, [0, 0.05, 0.1, 0.9, 1.0, 1.95]] {
            let onsets = flashOnsets(strikes: strikes)
            XCTAssertFalse(onsets.isEmpty)
            for t in onsets {
                let inWindow = onsets.filter { $0 >= t && $0 < t + 1 }.count
                XCTAssertLessThanOrEqual(inWindow, FlashLimiter.maxPerSecond, "strikes \(strikes): \(onsets)")
            }
        }
    }

    func testLimiterSlidingWindow() {
        var l = FlashLimiter()
        XCTAssertTrue(l.allow(at: 10.0))
        XCTAssertTrue(l.allow(at: 10.2))
        XCTAssertTrue(l.allow(at: 10.4))
        XCTAssertFalse(l.allow(at: 10.9))
        XCTAssertEqual(l.count(at: 10.9), 3)
        XCTAssertTrue(l.allow(at: 11.0))
        // A strike right after uses up what is left and dims the rest.
        var m = FlashLimiter()
        XCTAssertEqual(m.plan(strikeAt: 0), [true, true])
        // A second send within the second still flashes once; its re-strike is dimmed.
        XCTAssertEqual(m.plan(strikeAt: 0.3), [true, false])
        // A third one in that second strikes dim.
        XCTAssertEqual(m.plan(strikeAt: 0.6), [false, false])
        XCTAssertEqual(m.plan(strikeAt: 1.5), [true, true])
    }

    // MARK: Colour

    func testLightningIsNeverRed() {
        for hex in ["#FF0000", "#FF2BD0", "#FF5A1F", "#2F6BFF", "#00D4FF", "#FFFFFF", "#E00010"] {
            let c = SkyColor.lightningSafe(PortalRGB(hex: hex)!)
            XCTAssertFalse(SkyColor.isSaturatedRed(c), hex)
            XCTAssertLessThanOrEqual(c.hsv.saturation, 0.5, hex)
        }
        for i in 0..<120 {
            let c = SkyColor.lightningSafe(PortalRGB(hue: Double(i) / 120, saturation: 1, value: 1))
            XCTAssertFalse(SkyColor.isSaturatedRed(c))
        }
    }

    func testNewEffectsAreListed() {
        XCTAssertEqual(PortalEffect(stored: "stardust"), .stardust)
        XCTAssertEqual(PortalEffect(stored: "lightning"), .lightning)
        XCTAssertTrue(PortalEffect.lightning.isSky)
        XCTAssertFalse(PortalEffect.portal.isSky)
    }
}
